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

proc drawMenuItem*(c: var AhCanvas; menu: AhNode; row, col, width: int;
                   m: MarkStyle; title, key: string; active: bool;
                   trailing: openArray[(string, string)] = [];
                   onClick: proc() = nil): AhNode =
  ## One line of a dropdown: a mark, the title, then quieter facts at its end.
  result = c.node(menu, row, col, width, 1, [("menu-item", key)])
  if active: c.fill(row, col, width, 1, c.p.activeTab)
  discard c.mark(result, row, col + 1, m)
  var tail = 0
  for (word, _) in trailing: tail += widthOf(word) + 1
  discard c.text(result, row, col + 3, max(1, width - 4 - tail), title,
                 if active: c.p.activeTabText else: c.p.textBody)
  var at = col + width - 1 - tail
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
  if closable and tab.active:
    right -= 2
    discard c.put(row, right + 1, "\xE2\x9C\x95", c.p.activeTabOrigin)
    discard c.node(n, row, right + 1, 1, 1, [("close", id)])
    c.target(row, right + 1, 1, 1, proc() = discard vm.close(id))
  if tab.originShort.len > 0:
    right -= widthOf(tab.originShort) + 1
    discard c.text(n, row, right + 1, widthOf(tab.originShort), tab.originShort,
                   if tab.active: c.p.activeTabOrigin else: c.p.textCaption,
                   fact = "origin")
  let label = tabLabelOf(tab)
  discard c.text(n, row, col + 3, max(1, right - (col + 3)), label,
                 if tab.active: c.p.activeTabText else: c.p.textCaption, fact = "label")
  if vm.isInFocus(tab):
    # The focused initiative's tabs: an underline in the action role under
    # the tab, never a fill — a fill reads as the active tab.
    n.tag("in-focus", "true")
    c.grid.restyle(row, col + 1, width - 2, proc(s: CellStyle): CellStyle =
      result = s
      result.underline = true)

proc drawStripNotice(c: var AhCanvas; parent: AhNode; row, col, width: int;
                     message, kind: string; retry: proc()) =
  ## A notice in place of the tabs: loading, empty, or an error and Retry.
  ## Never filled, so it cannot read as the active tab.
  let error = kind == "error"
  let n = c.node(parent, row, col, width, 1, [("notice", kind)])
  let room = width - (if retry != nil: 9 else: 0) - 2
  discard c.text(n, row, col + 1, room, message,
                 if error: c.p.textError else: c.p.textCaption,
                 fact = if error: "error" else: "")
  if retry != nil:
    let at = col + 1 + min(widthOf(message), room) + 1
    discard c.put(row, at, " Retry ", c.p.textLabel, bg = c.tone.chip)
    discard c.node(n, row, at + 1, 5, 1, [("button", "Retry")])
    c.target(row, at, 7, 1, retry)

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
  case vm.state.val
  of asIdle, asLoading:
    c.drawStripNotice(host, row, col, width - AddCells - 1, AgentHarborTabsLoadingText,
                      "loading", nil)
  of asError:
    let target = vm
    c.drawStripNotice(host, row, col, width - AddCells - 1,
                      AgentHarborTabsErrorText & ": " & vm.error.val, "error",
                      proc() = target.load())
  of asReady:
    if tabs.len == 0:
      c.drawStripNotice(host, row, col, width - AddCells - 1, AgentHarborTabsEmptyText,
                        "empty", nil)
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
  if vm.state.val != asReady or tabs.len == 0:
    at = col + width - AddCells - 1
  c.drawPlus(host, lastRow, min(at, col + width - AddCells))
  host.height = lines
  host.tag("lines", $lines)
  if overflow.len > 0 and vm.overflowOpen.val:
    var widest = MenuMinCells
    for i in overflow:
      widest = max(widest, 4 + widthOf(tabs[i].title) + 1 +
                   (if tabs[i].originShort.len > 0: widthOf(tabs[i].originShort) + 1 else: 0))
    let menuW = min(widest, width - 1)
    let menuCol = col + max(0, width - 1 - menuW)
    let menu = c.drawMenu(host, lastRow + 1, menuCol, menuW,
                          min(overflow.len, c.rows - lastRow - 1), "overflow")
    for k, i in overflow:
      if lastRow + 1 + k >= c.rows: break
      let id = tabs[i].id
      let target = vm
      var trailing: seq[(string, string)]
      if tabs[i].originShort.len > 0: trailing.add (tabs[i].originShort, c.p.textCaption)
      discard c.drawMenuItem(menu, lastRow + 1 + k, menuCol, menuW,
                             c.p.markOf(tabs[i].attention), tabs[i].title, id,
                             tabs[i].active, trailing, proc() = discard target.activate(id))

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

proc drawGroupHeader(c: var AhCanvas; parent: AhNode; vm: SessionTabStripVM;
                     group: SessionTabGroup; index, row, col, width: int) =
  ## An initiative's node of the tree: ▸/▾ (a click folds it), its mark,
  ## title, `n/m` and counts, on the group band. The focused initiative's
  ## node carries the action role's bar at its left edge (the web fills it;
  ## a fill here would collide with the band's two grounds).
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
  var at = col + 3
  if planId.len > 0:
    discard c.mark(n, row, at, c.p.markOf(group.state))
    at += 2
  let counts = countsText(group.counts)
  let progress = group.progressText
  var tail = 0
  if progress.len > 0: tail += widthOf(progress) + 1
  let half = max(4, (width - (at - col)) div 2)
  let countsW = min(widthOf(counts), max(0, width - (at - col) - tail - half - 2))
  let titleW = max(4, width - (at - col) - tail - countsW - 2)
  let tw = c.text(n, row, at, titleW, group.title, c.p.textLabel, bold = true,
                  fact = "title")
  at += max(tw, min(titleW, widthOf(group.title))) + 1
  at = max(at, col + width - 1 - tail - countsW - (if countsW > 0: 1 else: 0))
  if progress.len > 0:
    discard c.put(row, at, progress, c.p.textCaption)
    at += widthOf(progress) + 1
  if countsW > 0:
    discard c.text(n, row, at, countsW, counts, c.p.textCaption, fact = "counts")
  else:
    discard c.node(n, row, at, 0, 1, [("counts-hidden", counts)])

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
  # the source, on the head band.
  let showSummary = not collapsed and vm.state.val == asReady
  let summaryOwnLine = showSummary and (sidebar or not columns)
  let showSource = not collapsed and vm.sourceLabel.len > 0
  let headRows = 1 + (if summaryOwnLine: 1 else: 0) + (if showSource: 1 else: 0)
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
    if summaryOwnLine:
      discard c.text(head, r, col + 1, w - 2, vm.summaryText, c.p.textCaption,
                     fact = "summary")
      inc r
    else:
      discard c.text(head, row, col + 10, w - 12, vm.summaryText, c.p.textCaption,
                     fact = "summary")
  if showSource:
    discard c.text(head, r, col + 1, w - 2, vm.sourceLabel, c.p.textCaption, fact = "source")
    inc r
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
    for gi, group in vm.groups:
      let showHeader = vm.grouped.val and not collapsed
      if showHeader:
        c.drawGroupHeader(list, vm, group, gi, r, col, w)
        inc r
      if not (group.collapsed and showHeader):
        for tab in group.tabs:
          r += c.drawListRow(list, vm, tab, r, col, w, collapsed, columns)
