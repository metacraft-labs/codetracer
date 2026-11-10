## tui/agent_harbor/ah_tui_session_views.nim — CTF-P1b. The terminal views
## of the Agent Harbor sessions as CodeTracer's session tabs, over
## `SessionTabStripVM` (nim-agents-isonim-viewmodels): the strip on one line or
## several, and the same tabs as a list — in the sidebar (collapsible to a
## rail of marks) or docked as a panel.
##
## The same parts, order and words as the web prototype
## (`viewmodel/views/isonim_agent_harbor_session_tabs_view.nim`) and the GPUI
## views (`gpui/agent_harbor/ah_session_views.nim`); the words come from
## `viewmodel/views/agent_harbor_words.nim`. Which tabs one line shows, every
## state, and what each tab says are the viewmodel's. In the terminal's
## style (few borders, areas told apart by background): the active tab and row are told by their ground, groups are
## bands, nothing is boxed, and a group folds with a click on its line.
##
## Widths: the viewmodel is told the strip's width in CSS pixels (`cols *
## CellPx`), so its single-line rule keeps the tabs the web keeps at the
## same size; the tabs are then drawn in cells (`cellsOf` of the
## stylesheet's widths).

import std/strutils
import isonim/core/signals
import nim_agents_isonim_viewmodels/agent_harbor/session_tabs_vm
from ../../viewmodel/views/agent_harbor_words import
  tabLabelOf, countsText, metaOf, AgentHarborTabsLoadingText,
  AgentHarborTabsErrorText, AgentHarborTabsEmptyText

import ./ah_tui_canvas

export session_tabs_vm, ah_tui_canvas

const
  TabMinCells* = TabMinWidthPx div CellPx        ## 10rem
  TabMaxCells* = 192 div CellPx                  ## 12rem
  ActiveTabCells* = (TabMinWidthPx + ActiveTabExtraPx) div CellPx  ## 14rem
  WrapTabCells* = 176 div CellPx                 ## several lines: 11rem
  AddCells* = 3                                  ## " + "
  SidebarMaxCells* = 448 div CellPx              ## 28rem
  RailCells* = 40 div CellPx                     ## 2.5rem collapsed
  DockedColumnsFromPx = 768                      ## the docked grid's breakpoint
  AgeCells = 64 div CellPx                       ## the docked age column, 4rem
  MenuMinCells* = 220 div CellPx                 ## a dropdown's min-width

# ---------------------------------------------------------------------------
# Shared by both bars
# ---------------------------------------------------------------------------

proc fitCells*(widths: seq[int]; budget, minCells, gap: int;
               fixed: seq[bool] = @[]; mins: seq[int] = @[]): seq[int] =
  ## A row of shrinkable tabs that overflows `budget`: every tab gives up
  ## room in proportion to its width, none below its minimum, a `fixed` one
  ## never (CSS Flexbox §9.7, https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths,
  ## in whole cells; the cells left over go to the largest remainders).
  result = widths
  var floorOf = newSeq[int](widths.len)
  var frozen = newSeq[bool](widths.len)
  for i in 0 ..< widths.len:
    floorOf[i] = if i < mins.len: min(mins[i], widths[i]) else: min(minCells, widths[i])
    frozen[i] = (i < fixed.len and fixed[i]) or widths[i] <= floorOf[i]
  for _ in 0 .. widths.len:
    var total = gap * max(0, widths.len - 1)
    var basis = 0
    for i, w in result:
      total += w
      if not frozen[i]: basis += widths[i]
    let deficit = total - budget
    if deficit <= 0 or basis == 0: break
    var clamped = false
    for i in 0 ..< result.len:
      if frozen[i]: continue
      if result[i] * basis - deficit * widths[i] <= floorOf[i] * basis:
        result[i] = floorOf[i]
        frozen[i] = true
        clamped = true
    if clamped: continue
    var given = 0
    var shares = newSeq[int](result.len)
    for i in 0 ..< result.len:
      if not frozen[i]:
        shares[i] = deficit * widths[i] div basis
        given += shares[i]
    var i = 0
    while given < deficit and i < result.len:
      if not frozen[i] and result[i] - shares[i] - 1 >= floorOf[i]:
        inc shares[i]
        inc given
      inc i
    for k in 0 ..< result.len:
      if not frozen[k]: result[k] -= shares[k]
    break

proc drawPlus*(c: var AhCanvas; parent: AhNode; row, col: int) =
  ## "+", on its own round ground (`session-tab-add`).
  discard c.put(row, col, " + ", c.p.addText, bg = c.tone.chip)
  discard c.node(parent, row, col, AddCells, 1, [("add", "+")])

proc chipWidth*(hidden: int; waits: bool): int =
  ## `+N`, a space either side, and the warning mark when a hidden tab waits.
  widthOf("+" & $hidden) + 2 + (if waits: 2 else: 0)

proc drawOverflowChip*(c: var AhCanvas; parent: AhNode; row, col, hidden, waits: int;
                       open: bool; onClick: proc()): int =
  ## `+N`: the tabs one line has no room for; a waiting one marks it. No
  ## ground at rest (the web's chip has none), the chip's ground while its
  ## menu is open.
  let w = chipWidth(hidden, waits > 0)
  let n = c.node(parent, row, col, w, 1, [("overflow", $hidden),
                                          ("overflow-waits", $waits)])
  if open: c.fill(row, col, w, 1, c.tone.chip)
  var at = col + 1
  if waits > 0:
    discard c.mark(n, row, at, c.p.markOf(saNeedsInput))
    at += 2
  discard c.put(row, at, "+" & $hidden, if open: c.p.textBody else: c.p.textLabel)
  c.target(row, col, w, 1, onClick)
  w

proc drawMenu*(c: var AhCanvas; parent: AhNode; row, col, width, height: int;
               kind: string): AhNode =
  ## A dropdown, on the card ground over whatever is under it.
  c.area("menu:" & kind, row, col, width, height, c.tone.menu)
  c.node(parent, row, col, width, height, [("menu", kind)])

const
  MenuInset* = 1
    ## The cells a menu keeps clear at each side (its mark sits after one).
  MenuOriginGap* = 2
    ## The cells a menu item keeps clear before its right-hand column, so a
    ## cut title's "…" never touches the origin.

proc trailingCells*(trailing: openArray[(string, string)]): int =
  ## The cells an item's trailing words take, one space apart.
  for (word, _) in trailing: result += widthOf(word) + 1
  result = max(0, result - 1)

proc drawMenuItem*(c: var AhCanvas; menu: AhNode; row, col, width: int;
                   m: MarkStyle; title, key: string; active: bool;
                   trailing: openArray[(string, string)] = [];
                   onClick: proc() = nil; trailColumn = -1): AhNode =
  ## One line of a dropdown: a mark, the title, then quieter facts at its
  ## end, right-aligned in a column `trailColumn` cells wide (the menu's
  ## widest; this item's own by default) that ends one cell in from the
  ## menu's edge, with `MenuOriginGap` cells between it and the title.
  result = c.node(menu, row, col, width, 1, [("menu-item", key)])
  if active: c.fill(row, col, width, 1, c.p.activeTab)
  discard c.mark(result, row, col + 1, m)
  let tail = trailingCells(trailing)
  let column = max(tail, trailColumn)
  let columnAt = col + width - MenuInset - column
  let titleRoom = columnAt - (if column > 0: MenuOriginGap else: MenuInset) - (col + 3)
  discard c.text(result, row, col + 3, max(1, titleRoom), title,
                 if active: c.p.activeTabText else: c.p.textBody, fact = "title")
  var at = columnAt + column - tail
  if tail > 0:
    discard c.node(result, row, at, tail, 1, [("menu-trailing", key)])
  for (word, colour) in trailing:
    discard c.put(row, at, word, colour)
    at += widthOf(word) + 1
  if onClick != nil: c.target(row, col, width, 1, onClick)

# ---------------------------------------------------------------------------
# The strip
# ---------------------------------------------------------------------------

proc tabCells*(tab: SessionItem; closable: bool; wrapped = false): int =
  ## A tab's width: the active one exactly 14rem (it holds the close); on
  ## several lines every other one 11rem; on one line its content, 10–12rem.
  if tab.active: return ActiveTabCells
  if wrapped: return WrapTabCells
  var w = 1 + 2 + widthOf(tabLabelOf(tab)) + 1
  if tab.originShort.len > 0: w += 1 + widthOf(tab.originShort)
  clamp(w, TabMinCells, TabMaxCells)

proc drawTab(c: var AhCanvas; parent: AhNode; vm: SessionTabStripVM;
             tab: SessionItem; closable: bool; row, col, width: int) =
  let id = tab.id
  let n = c.node(parent, row, col, width, 1,
                 [("tab", id), ("attention", $tab.attention),
                  ("active", $tab.active), ("tooltip", tab.tooltip)])
  if tab.active: c.fill(row, col, width, 1, c.p.activeTab)
  c.target(row, col, width, 1, proc() = discard vm.activate(id))
  discard c.mark(n, row, col + 1, c.p.markOf(tab.attention))
  var right = col + width - 1
  # On the active tab the origin and the close take the active row's quiet
  # role: on Light's tan the caption role reads at about 2:1 (the web's
  # `.ah-session-row-active` makes the same move for the same reason).
  let quietOnActive = if c.p.mode == dmDark: c.p.activeTabOrigin else: c.p.activeRowQuiet
  if closable and tab.active:
    right -= 2
    discard c.put(row, right + 1, "\xE2\x9C\x95", quietOnActive)
    discard c.node(n, row, right + 1, 1, 1, [("close", id)])
    c.target(row, right + 1, 1, 1, proc() = discard vm.close(id))
  if tab.originShort.len > 0:
    right -= widthOf(tab.originShort) + 1
    discard c.text(n, row, right + 1, widthOf(tab.originShort), tab.originShort,
                   if tab.active: quietOnActive else: c.p.textCaption,
                   fact = "origin")
  let label = tabLabelOf(tab)
  discard c.text(n, row, col + 3, max(1, right - (col + 3)), label,
                 if tab.active: c.p.activeTabText else: c.p.textCaption, fact = "label")
  if vm.isInFocus(tab):
    # The focused initiative's tabs: an underline in the action role under
    # the tab (SGR 58 gives it its own colour, the web's 2px action line),
    # never a fill — a fill reads as the active tab.
    n.tag("in-focus", "true")
    let ink = c.p.borderAction
    c.grid.restyle(row, col + 1, width - 2, proc(s: CellStyle): CellStyle =
      result = s
      result.underline = true
      result.underlineColor = ink)

proc noticeGround*(p: AhPalette): string =
  ## A notice in a tab bar: tab-shaped by a ground of its own (the web
  ## draws a dashed outline there), a visible step off the bar's — Dark
  ## `surface/primary/secondary-hover` (1.36:1 on the bar), Light
  ## `surface/base/card` (1.34:1) — and never the active tab's grey, so it
  ## cannot read as the active tab. The steps nearer the active tab's own
  ## (1.56:1, 2.04:1) are the active grey itself in Dark and, in Light, a
  ## ground the notice's caption and error text read on at about 2.6:1.
  if p.mode == dmDark: p.hover else: p.menu

proc noticeGround*(c: AhCanvas): string = noticeGround(c.p)

proc drawStripNotice*(c: var AhCanvas; parent: AhNode; row, col, width: int;
                      message, kind: string; retry: proc()): int =
  ## A notice in place of the tabs: loading, empty, or an error and Retry,
  ## on the notice's own ground. Returns the cells it takes, so "+" can
  ## follow it directly.
  let error = kind == "error"
  let room = max(1, width - (if retry != nil: 8 else: 0) - 2)
  let w = min(widthOf(message), room)
  let n = c.node(parent, row, col, w + 2, 1, [("notice", kind)])
  c.area("notice", row, col, w + 2, 1, c.noticeGround)
  discard c.text(n, row, col + 1, room, message,
                 if error: c.p.textError else: c.p.textCaption,
                 fact = if error: "error" else: "message")
  result = w + 2
  if retry != nil:
    let at = col + result + 1
    discard c.put(row, at, " Retry ", c.p.textLabel, bg = c.tone.chip)
    discard c.node(n, row, at + 1, 5, 1, [("button", "Retry")])
    c.target(row, at, 7, 1, retry)
    result += 8

proc drawSessionTabStrip*(c: var AhCanvas; vm: SessionTabStripVM; row, col, width: int) =
  ## The strip at (`row`, `col`), `width` cells wide: one line, or several
  ## by `vm.mode`.
  let host = c.node(nil, row, col, width, 1,
                    [("surface", "agent-harbor-session-tabs"), ("mode", $vm.mode.val),
                     ("state", stateName(vm.state.val))])
  # The strip is the caption bar's: on the window's own ground, not an area
  # of its own.
  c.fill(row, col, width, 1, c.tone.frame)
  let tabs = vm.tabs
  var lines = 1
  var at = col
  var overflow: seq[int]
  # A notice takes the tabs' place; "+" comes directly after it, as after
  # the last tab.
  case vm.state.val
  of asIdle, asLoading:
    at = col + c.drawStripNotice(host, row, col, width - AddCells - 1,
                                 AgentHarborTabsLoadingText, "loading", nil) + 1
  of asError:
    let target = vm
    at = col + c.drawStripNotice(host, row, col, width - AddCells - 1,
                                 AgentHarborTabsErrorText & ": " & vm.error.val, "error",
                                 proc() = target.load()) + 1
  of asReady:
    if tabs.len == 0:
      at = col + c.drawStripNotice(host, row, col, width - AddCells - 1,
                                   AgentHarborTabsEmptyText, "empty", nil) + 1
    else:
      let closable = tabs.len > 1
      if vm.mode.val == tsmMultiLine:
        var widths: seq[int]
        for tab in tabs: widths.add tabCells(tab, closable, wrapped = true)
        let rowsOf = packTabRows(widths, max(TabMinCells, width - AddCells - 1), 1)
        lines = rowsOf.len
        c.fill(row, col, width, lines, c.tone.frame)
        for ri, line in rowsOf:
          at = col
          for i in line:
            c.drawTab(host, vm, tabs[i], closable, row + ri, at, widths[i])
            at += widths[i] + 1
      else:
        let layout = vm.singleLine
        overflow = layout.overflow
        var widths: seq[int]
        var fixed: seq[bool]
        for i in layout.visible:
          widths.add tabCells(tabs[i], closable)
          fixed.add tabs[i].active
        var waits = 0
        for i in overflow:
          if tabs[i].attention == saNeedsInput: inc waits
        let controls = AddCells + 1 +
          (if overflow.len > 0: chipWidth(overflow.len, waits > 0) + 1 else: 0)
        let fitted = fitCells(widths, width - controls, TabMinCells, 1, fixed)
        for k, i in layout.visible:
          c.drawTab(host, vm, tabs[i], closable, row, at, fitted[k])
          at += fitted[k] + 1
  # The last line holds `+N` and "+", after its last tab.
  let lastRow = row + lines - 1
  if overflow.len > 0:
    var waits = 0
    for i in overflow:
      if tabs[i].attention == saNeedsInput: inc waits
    let target = vm
    at += c.drawOverflowChip(host, lastRow, at, overflow.len, waits, vm.overflowOpen.val,
                             proc() = target.toggleOverflow()) + 1
  c.drawPlus(host, lastRow, min(at, col + width - AddCells))
  host.height = lines
  host.tag("lines", $lines)
  if overflow.len > 0 and vm.overflowOpen.val:
    # The menu holds each title whole with two cells before its origin, and
    # keeps a row of its own ground above and below its items (the web's
    # dropdown padding), so it does not sit against the strip.
    var column = 0
    for i in overflow: column = max(column, widthOf(tabs[i].originShort))
    var widest = MenuMinCells
    for i in overflow:
      widest = max(widest, 3 + widthOf(tabs[i].title) + MenuOriginGap + column + MenuInset)
    let menuW = min(widest, width - 1)
    let menuCol = col + max(0, width - 1 - menuW)
    let menu = c.drawMenu(host, lastRow + 1, menuCol, menuW,
                          min(overflow.len + 2, c.rows - lastRow - 1), "overflow")
    for k, i in overflow:
      if lastRow + 2 + k >= c.rows: break
      let id = tabs[i].id
      let target = vm
      var trailing: seq[(string, string)]
      if tabs[i].originShort.len > 0: trailing.add (tabs[i].originShort, c.p.textCaption)
      discard c.drawMenuItem(menu, lastRow + 2 + k, menuCol, menuW,
                             c.p.markOf(tabs[i].attention), tabs[i].title, id,
                             tabs[i].active, trailing, proc() = discard target.activate(id),
                             trailColumn = column)

proc mountSessionTabStrip*(vm: SessionTabStripVM; cols: int) =
  ## Tell the viewmodel the strip's width, in the unit its layout counts.
  if cols > 0 and vm.stripWidthPx.val != cols * CellPx: vm.stripWidthPx.val = cols * CellPx

# ---------------------------------------------------------------------------
# The list: sidebar (collapsible to a rail) and docked
# ---------------------------------------------------------------------------

proc drawListRow(c: var AhCanvas; parent: AhNode; vm: SessionTabStripVM;
                 tab: SessionItem; row, col, width: int;
                 collapsed, columns: bool): int =
  ## One session; returns the rows it takes. A row below the panel's foot is
  ## drawn into the tree and clipped off the grid, as the web's
  ## `overflow: hidden` clips it.
  let id = tab.id
  let detail = if tab.failureText.len > 0: tab.failureText
               elif tab.activity.len > 0: tab.activity[0].lineText
               else: ""
  let height = if collapsed: 1
               elif columns: (if detail.len > 0: 2 else: 1)
               else: (if detail.len > 0: 3 else: 2)
  let n = c.node(parent, row, col, width, height,
                 [("row", id), ("attention", $tab.attention), ("active", $tab.active),
                  ("tooltip", tab.tooltip)])
  if tab.active:
    c.area("active-row", row, col, width, height, c.p.activeRow)
  c.target(row, col, width, height, proc() = discard vm.activate(id))
  if collapsed:
    discard c.mark(n, row, col + width div 2, c.p.markOf(tab.attention))
    return 1
  if vm.isInFocus(tab):
    n.tag("in-focus", "true")
    for r in row ..< row + height: discard c.put(r, col, BarGlyph, c.p.borderAction)
  discard c.mark(n, row, col + 1, c.p.markOf(tab.attention))
  let quiet = if tab.active: c.p.activeRowQuiet else: c.p.textCaption
  let ageW = widthOf(tab.ageLabel)
  if columns:
    let column = max(4, (width - 3 - AgeCells - 3) div 2)
    discard c.text(n, row, col + 3, column, tab.title,
                   if tab.active: c.p.activeTabText else: c.p.textBody, fact = "title")
    let metaCol = col + 3 + column + 1
    let sw = c.text(n, row, metaCol, column, tab.statusLabel,
                    c.p.statusWordColour(tab.attention), fact = "status")
    discard c.text(n, row, metaCol + sw + 1, max(1, column - sw - 1), metaOf(tab), quiet,
                   fact = "meta")
    discard c.text(n, row, col + width - 1 - AgeCells, AgeCells, tab.ageLabel,
                   c.p.textBodySubtle, fact = "age", alignRight = true)
    if detail.len > 0:
      discard c.text(n, row + 1, col + 3, column, detail,
                     if tab.failureText.len > 0: c.p.textError else: c.p.rowDetail,
                     fact = "detail")
    return height
  discard c.text(n, row, col + 3, max(1, width - 3 - ageW - 2), tab.title,
                 if tab.active: c.p.activeTabText else: c.p.textBody, fact = "title")
  discard c.text(n, row, col + width - 1 - ageW, ageW, tab.ageLabel, c.p.textBodySubtle,
                 fact = "age")
  let sw = c.text(n, row + 1, col + 3, max(1, width - 4), tab.statusLabel,
                  c.p.statusWordColour(tab.attention), fact = "status")
  if width - 4 - sw - 1 > 0:
    discard c.text(n, row + 1, col + 3 + sw + 1, width - 4 - sw - 1, metaOf(tab), quiet,
                   fact = "meta")
  if detail.len > 0:
    discard c.text(n, row + 2, col + 3, max(1, width - 4), detail,
                   if tab.failureText.len > 0: c.p.textError else: c.p.rowDetail,
                   fact = "detail")
  height

type
  GroupColumns* = object
    ## Where a list's group headers put their parts, the same for every
    ## header of the list so `n/m` stands in one column: the title's slot,
    ## then `n/m` right-aligned in its own, then the counts' slot at the end.
    ## `flush`: the docked panel's wide layout, where every header's counts
    ## are right-aligned to the panel's end, flush with the rows' ages.
    titleAt*, titleW*, progressW*, countsW*: int
    flush*: bool

  GroupHeaderPlace* = object
    ## One header's parts, in absolute columns: the title's width, where
    ## `n/m` and the counts start and how many cells the counts get (none
    ## when fewer than two would show), and whether the header flowed
    ## inline (`n/m` two cells after its title) rather than in the columns.
    titleW*, progressAt*, countsAt*, countsW*: int
    inline*: bool

const
  GroupCountsShare = 40
    ## The counts take at most 40% of a header (`.ah-session-group-counts`:
    ## `max-width: 40%`).
  GroupCountsMin = 8
    ## What the title slot leaves the counts at least (`2 failed`, `1 idle…`:
    ## the counts are cut only between their parts, so a slot that holds no
    ## whole first part shows none).
  GroupInlineGap = 2
    ## Between a title and the `n/m` that flows after it.

proc groupColumns*(vm: SessionTabStripVM; width: int; flush = false): GroupColumns =
  ## The columns of `vm`'s group headers in a list `width` cells wide: the
  ## title's slot as wide as the widest title, but leaving `n/m` its column
  ## and the counts at least `GroupCountsMin` cells; `n/m` right-aligned in
  ## a column as wide as the widest `n/m`; the counts the rest (at most 40%
  ## of the line). A title longer than its slot takes room from its own
  ## header's counts (`groupHeaderPlace`): the counts are cut before the
  ## title is (`.ah-session-group-counts` shrinks a hundred times faster).
  ## `flush` (the docked panel's wide layout): the counts' slot is the
  ## widest counts, ending at the panel's end, and `n/m` stands just left of
  ## it.
  result.titleAt = 5   # fold, a space, the mark, a space
  result.flush = flush
  var widestCounts, widestProgress, widestTitle = 0
  for g in vm.groups:
    widestCounts = max(widestCounts, widthOf(countsText(g.counts)))
    widestProgress = max(widestProgress, widthOf(g.progressText))
    widestTitle = max(widestTitle, widthOf(g.title))
  let line = width - result.titleAt - 1
  let pw = if widestProgress > 0: widestProgress + 1 else: 0
  result.progressW = widestProgress
  if flush:
    result.countsW = min(widestCounts, line * GroupCountsShare div 100)
    result.titleW = max(4, line - pw - 1 - result.countsW)
    return
  result.titleW = max(4, min(max(widestTitle, line - pw - 1 -
                                 min(widestCounts, line * GroupCountsShare div 100)),
                             line - pw - 1 - GroupCountsMin))
  result.countsW = max(0, line - result.titleW - pw - 1)

proc groupHeaderPlace*(cols: GroupColumns; col, width: int; title, progress,
                       counts: string): GroupHeaderPlace =
  ## One header's layout. The columns are a preference, not a constraint:
  ## the title whole when the line can hold it beside `n/m` (taking its
  ## counts' room first), cut only when it cannot; the counts what is left
  ## of their slot. A header whose counts the columns would cut, but which
  ## would show them whole with `n/m` two cells after its title, flows
  ## inline instead (as the web's header always does), so a short title
  ## never costs its own counts; the other headers keep the column. On the
  ## docked panel's wide layout (`cols.flush`) the counts end at the panel's
  ## end, flush with the rows' ages.
  let titleAt = col + cols.titleAt
  let lineEnd = col + width - 1             # exclusive: one cell of inset
  let line = width - cols.titleAt - 1
  let pw = if cols.progressW > 0: cols.progressW + 1 else: 0
  let natural = widthOf(title)
  let cw = widthOf(counts)
  result.titleW = cols.titleW
  result.countsW = min(cols.countsW, cw)
  if natural > cols.titleW:
    result.titleW = min(natural, line - pw)
    result.countsW = min(cw, max(0, line - pw - result.titleW - 1))
  let progressEnd = max(titleAt + result.titleW + 1 + cols.progressW,
                        lineEnd - (if cols.countsW > 0: cols.countsW + 1 else: 0))
  result.progressAt = progressEnd - widthOf(progress)
  result.countsAt = if cols.flush: lineEnd - result.countsW else: progressEnd + 1
  if not cols.flush and result.countsW < cw:
    let progressCells = if progress.len > 0: widthOf(progress) + 1 else: 0
    if titleAt + natural + GroupInlineGap + progressCells + cw <= lineEnd:
      result = GroupHeaderPlace(titleW: natural, inline: true,
                                progressAt: titleAt + natural + GroupInlineGap,
                                countsAt: titleAt + natural + GroupInlineGap + progressCells,
                                countsW: cw)
  if result.countsW < 2: result.countsW = 0

proc drawGroupHeader(c: var AhCanvas; parent: AhNode; vm: SessionTabStripVM;
                     group: SessionTabGroup; cols: GroupColumns;
                     index, row, col, width: int) =
  ## An initiative's node of the tree: ▸/▾ (a click folds it), its mark,
  ## title, `n/m` and counts, on the group band. The focused initiative's
  ## node carries the action role's bar at its left edge (the web fills it;
  ## a fill here would collide with the band's two grounds). The title has
  ## priority over the counts, and `n/m` stands in the list's one column
  ## unless this header's title needs its place or its counts are whole
  ## only inline (`groupHeaderPlace`).
  let planId = group.planId
  let focused = planId.len > 0 and planId == vm.focusedPlan.val
  c.area("group", row, col, width, 1, c.tone.group[index mod 2])
  if focused: discard c.put(row, col, BarGlyph, c.p.borderAction)
  let n = c.node(parent, row, col, width, 1, [("group", planId),
                                              ("folded", $group.collapsed),
                                              ("state", $group.state)])
  let target = vm
  c.target(row, col, width, 1, proc() = target.toggleGroup(planId))
  discard c.put(row, col + 1, if group.collapsed: FoldedGlyph else: UnfoldedGlyph,
                c.p.textLabel)
  if planId.len > 0:
    discard c.mark(n, row, col + 3, c.p.markOf(group.state))
  let titleAt = col + cols.titleAt
  let counts = countsText(group.counts)
  let progress = group.progressText
  let place = groupHeaderPlace(cols, col, width, group.title, progress, counts)
  if place.inline: n.tag("inline", "true")
  discard c.text(n, row, titleAt, place.titleW, group.title, c.p.textLabel, bold = true,
                 fact = "title")
  if progress.len > 0:
    discard c.text(n, row, place.progressAt, widthOf(progress), progress,
                   c.p.textCaption, fact = "progress")
  # The counts are cut only between their parts (`2 need input…`, never
  # `2 need…`); where not even the first part fits they are left out.
  if place.countsW > 0 and elideParts(counts, place.countsW).len > 0:
    discard c.text(n, row, place.countsAt, place.countsW, counts, c.p.textCaption,
                   fact = "counts", alignRight = cols.flush, byParts = true)
  else:
    discard c.node(n, row, place.countsAt, 0, 1, [("counts-hidden", counts)])

proc drawSessionList*(c: var AhCanvas; vm: SessionTabStripVM; row, col, width, height: int) =
  ## The list at (`row`, `col`): `width` × `height` cells for a docked panel;
  ## a sidebar takes at most 28rem of it, or a 2.5rem rail when collapsed.
  let sidebar = vm.mode.val == tsmSidebar
  let collapsed = sidebar and vm.collapsed.val
  let w = if collapsed: RailCells elif sidebar: min(width, SidebarMaxCells) else: width
  let columns = not sidebar and w * CellPx >= DockedColumnsFromPx
  let host = c.node(nil, row, col, w, height,
                    [("surface", "agent-harbor-session-list"), ("mode", $vm.mode.val),
                     ("collapsed", $collapsed), ("state", stateName(vm.state.val))])
  c.area("list", row, col, w, height, c.tone.body)
  # The head: SESSIONS, the collapse toggle in a sidebar, the summary and
  # the source, on the head band. The summary and the source wrap rather
  # than being cut: at sidebar width the web's proportional line holds them
  # where a terminal line does not.
  let showSummary = not collapsed and vm.state.val == asReady
  let showSource = not collapsed and vm.sourceLabel.len > 0
  # Beside SESSIONS, two cells after it as every head's parts are.
  let besideTitle = showSummary and not sidebar and columns and
                    11 + widthOf(vm.summaryText) <= w - 2
  let summaryLines = if showSummary and not besideTitle: wrapCells(vm.summaryText, w - 2).len
                     else: 0
  let sourceLines = if showSource: wrapCells(vm.sourceLabel, w - 2).len else: 0
  let headRows = 1 + summaryLines + sourceLines
  c.area("head", row, col, w, headRows, c.tone.head)
  let head = c.node(host, row, col, w, headRows, [("head", "sessions")])
  if not collapsed:
    discard c.put(row, col + 1, "SESSIONS", c.p.textBody, bold = true)
  if sidebar:
    let toggle = if collapsed: "\xC2\xBB" else: "\xC2\xAB"
    let tc = if collapsed: col + w div 2 else: col + w - 2
    discard c.put(row, tc, toggle, c.p.textLabel)
    discard c.node(head, row, tc, 1, 1, [("collapse", if collapsed: "expand" else: "collapse")])
    let target = vm
    c.target(row, tc - 1, 3, 1, proc() = target.collapsed.val = not target.collapsed.val)
  var r = row + 1
  if showSummary:
    if besideTitle:
      discard c.text(head, row, col + 11, w - 13, vm.summaryText, c.p.textCaption,
                     fact = "summary")
    else:
      r += c.para(head, r, col + 1, w - 2, vm.summaryText, c.p.textCaption, fact = "summary")
  if showSource:
    r += c.para(head, r, col + 1, w - 2, vm.sourceLabel, c.p.textCaption, fact = "source")
  let bodyTop = row + headRows
  let bodyH = height - headRows
  case vm.state.val
  of asIdle, asLoading:
    c.notice(host, bodyTop, col, w, bodyH,
             if collapsed: Ellipsis else: AgentHarborTabsLoadingText, "loading")
  of asError:
    let target = vm
    c.errorBlock(host, bodyTop, col, w, bodyH, "Could not load the sessions",
                 vm.error.val, proc() = target.load())
  of asReady:
    if vm.tabs.len == 0:
      c.notice(host, bodyTop, col, w, bodyH, AgentHarborTabsEmptyText, "empty")
      return
    let list = c.node(host, bodyTop, col, w, bodyH, [("rows", "list")])
    r = bodyTop
    let groupCols = groupColumns(vm, w, flush = columns)
    for gi, group in vm.groups:
      let showHeader = vm.grouped.val and not collapsed
      if showHeader:
        c.drawGroupHeader(list, vm, group, groupCols, gi, r, col, w)
        inc r
      if not (group.collapsed and showHeader):
        for tab in group.tabs:
          r += c.drawListRow(list, vm, tab, r, col, w, collapsed, columns)
