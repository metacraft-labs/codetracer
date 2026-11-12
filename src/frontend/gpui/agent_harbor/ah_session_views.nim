## gpui/agent_harbor/ah_session_views.nim — CTF-P1b. The GPUI views of the
## Agent Harbor sessions as CodeTracer's session tabs, over
## `SessionTabStripVM` (nim-agents-isonim-viewmodels): the strip in the
## caption bar, on one line or several, and the same tabs as a list, in the
## sidebar (collapsible to a rail of marks) or docked as a panel.
##
## The web prototype is `viewmodel/views/isonim_agent_harbor_session_tabs_view.nim`
## (styled by `agent_harbor.styl` and `session_tabs.styl`); this module draws
## the same parts in the same order with the same words, which both take from
## `viewmodel/views/agent_harbor_words.nim` (`tabLabelOf`, `countsText`, `metaOf`,
## the notices) so the two cannot say different things. What a tab says, and which
## tabs one line shows, is the viewmodel's (`tabs`, `groups`, `singleLine`):
## the width the view reports (`stripWidthPx`) is in pixels on both.
##
## The one thing this module decides that the web leaves to CSS is the
## several-line strip's line breaks: there is no `flex-wrap` in GPUI, so the
## tabs are packed with the viewmodel's own rule (`packTabRows`) over their
## measured widths.


import std/math

import ../../../common/pointer_shape
import isonim/core/[signals, computation]
import nim_agents_isonim_viewmodels/agent_harbor/session_tabs_vm
from ../../viewmodel/views/agent_harbor_words import
  tabLabelOf, countsText, metaOf, AgentHarborTabsLoadingText,
  AgentHarborTabsErrorText, AgentHarborTabsEmptyText

import ./ah_theme

export session_tabs_vm, ah_theme

const
  TabPadPx = 10            ## a tab's side padding (0.625em)
  TabInnerGapPx = 6        ## between a tab's mark, title, origin and close
  TabTitlePx = BodyLargePx ## the strip's 1rem (`.session-tab`; the title inherits it)
  TabOriginPx = CaptionPx  ## `.ah-tab-origin`: the caption size (measured 12px)
  TabClosePx = 10
  TabMaxPx = 192           ## 12rem
  ActiveTabPx = TabMinWidthPx + ActiveTabExtraPx
    ## 14rem: the session strip's active tab is exactly the width the
    ## viewmodel counts for it (`agent_harbor.styl`, `flex: 0 0 14rem`).
  WrapTabPx = 176          ## several lines: `flex: 0 1 11rem; max-width: 11rem`
  StripGapPx = session_tabs_vm.TabGapPx
  StripTopPx* = 4
    ## The caption bar's top padding above a strip line (`#menu`'s 6px, less
    ## the line's own 2px above its 26px tab), so a tab sits 6px down as on
    ## the web.
  AddButtonPx = 26
  ChipGapPx* = 12          ## `.ah-tab-overflow-count` margin-right: 0.75rem
  MenuGapPx* = 6           ## DROPDOWN_TRIGGER_GAP: a menu hangs 6px below its bar
  MenuMinPx* = 220         ## `.session-tab-overflow-menu` min-width: 13.75em
  MenuItemPx* = 28         ## `.session-tab-overflow-item` min-height: 1.75rem
  MenuItemPadPx* = 10
  MenuItemTextPx* = BodyPx ## 0.875rem
  SidebarMaxPx* = 448      ## `.ah-session-list-sidebar` max-width: 28rem
  RailPx* = 40             ## collapsed: 2.5rem
  DockedColumnsFromPx = 768  ## `@container ah-session-list (min-width: 48rem)`
  DockedAgePx = 64           ## the docked grid's age column: 4rem

# ---------------------------------------------------------------------------
# The strip
# ---------------------------------------------------------------------------

proc tabContentWidth*(tab: SessionItem; closable: bool): int =
  ## A single-line tab's content width (its max-content: padding, mark,
  ## title, origin and, active, the close control), unclamped: the FLEX
  ## BASE SIZE of a `flex: 0 1 auto` tab (CSS Flexbox §9.2 step 3,
  ## https://www.w3.org/TR/css-flexbox-1/#algo-main-item), which the shrink
  ## starts from, not the width its min/max clamp it to.
  result = 2 * TabPadPx + MarkPx + TabInnerGapPx + textPx(tabLabelOf(tab), TabTitlePx)
  if tab.originShort.len > 0: result += TabInnerGapPx + textPx(tab.originShort, TabOriginPx)
  if closable and tab.active: result += TabInnerGapPx + TabClosePx

proc tabWidth*(tab: SessionItem; closable: bool; wrapped = false): int =
  ## A tab's width as the web strip sizes it when nothing shrinks: the
  ## active tab exactly 14rem (it holds the close control); on several
  ## lines every other tab 11rem; on one line every other tab its content,
  ## between 10rem and 12rem (its hypothetical main size).
  if tab.active: return ActiveTabPx
  if wrapped: return WrapTabPx
  clamp(tabContentWidth(tab, closable), TabMinWidthPx, TabMaxPx)

proc fitWidths*(widths: seq[int]; budget, minPx, gap: int;
                fixed: seq[bool] = @[]; mins: seq[int] = @[];
                maxes: seq[int] = @[]): seq[int] =
  ## The widths a row of `flex: 0 1 auto` tabs takes in `budget` pixels, as
  ## CSS Flexbox §9.7 resolves them ("Resolving Flexible Lengths",
  ## https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths).
  ## `widths` are the FLEX BASE SIZES (each tab's content width, unclamped);
  ## each tab is held between its minimum (`mins[i]` when given, its
  ## min-content, never above its base; else `minPx`) and its maximum
  ## (`maxes[i]`; none when not given). A `fixed` tab never flexes (the
  ## session strip's active tab, `flex: 0 0 14rem`).
  ##
  ## 1. Each tab's hypothetical size is its base clamped to its min / max;
  ##    a row whose hypothetical sizes fit is laid out at them.
  ## 2. Otherwise it shrinks. A fixed tab, and one whose base is below its
  ##    hypothetical size (raised to its minimum), is frozen at its
  ##    hypothetical size. The rest share the deficit IN PROPORTION TO
  ##    THEIR BASE SIZES (the scaled flex shrink factor, shrink 1 × base),
  ##    measured from the bases, not from the clamped sizes: so a long
  ##    title (base above the maximum) still gives up the most.
  ## 3. Each round, a tab whose share takes it past its minimum or maximum
  ##    is clamped; when the clamps add up to a net growth the tabs clamped
  ##    to their minimum are frozen, a net shrink freezes those clamped to
  ##    their maximum, none freezes all; the rest share what is left
  ##    again.
  ##
  ## The widths are whole pixels and a browser's are not, so the result is
  ## rounded so the row keeps the browser's total: each tab the floor of
  ## its exact width, and the pixels that leaves go one each to the tabs
  ## with the largest remainders (on a tie, the first), never past a tab's
  ## maximum.
  let n = widths.len
  var lo, hi = newSeq[float](n)
  var hyp = newSeq[float](n)
  var frozen = newSeq[bool](n)
  for i in 0 ..< n:
    lo[i] = float(if i < mins.len: min(mins[i], widths[i]) else: minPx)
    hi[i] = if i < maxes.len: float(maxes[i]) else: Inf
    hyp[i] = if i < fixed.len and fixed[i]: float(widths[i])
             else: clamp(float(widths[i]), lo[i], max(lo[i], hi[i]))
  let gaps = float(gap * max(0, n - 1))
  var total = gaps
  for v in hyp: total += v
  var target = hyp
  if total > float(budget):
    for i in 0 ..< n:
      frozen[i] = (i < fixed.len and fixed[i]) or float(widths[i]) < hyp[i]
    while true:
      var anyOpen = false
      var used = gaps
      var basis = 0.0
      for i in 0 ..< n:
        if frozen[i]: used += target[i]
        else:
          anyOpen = true
          used += float(widths[i])
          basis += float(widths[i])
      if not anyOpen or basis <= 0: break
      let free = float(budget) - used
      var violation = 0.0
      var clampedTo = newSeq[float](n)   # >0 grew to a min, <0 cut to a max
      for i in 0 ..< n:
        if frozen[i]: continue
        let t = if free < 0: float(widths[i]) + free * float(widths[i]) / basis
                else: float(widths[i])
        let c = clamp(t, lo[i], max(lo[i], hi[i]))
        target[i] = c
        clampedTo[i] = c - t
        violation += c - t
      for i in 0 ..< n:
        if frozen[i]: continue
        if violation > 1e-9:
          if clampedTo[i] > 1e-9: frozen[i] = true
        elif violation < -1e-9:
          if clampedTo[i] < -1e-9: frozen[i] = true
        else: frozen[i] = true
  # Whole pixels, keeping the exact total.
  result = newSeq[int](n)
  var exactSum = 0.0
  var given = 0
  for i in 0 ..< n:
    result[i] = int(floor(target[i] + 1e-9))
    exactSum += target[i]
    given += result[i]
  var left = int(round(exactSum)) - given
  while left > 0:
    var best = -1
    var bestRem = -1.0
    for i in 0 ..< n:
      let rem = target[i] - float(result[i])
      if float(result[i] + 1) > max(lo[i], hi[i]) + 1e-9: continue
      if rem > bestRem + 1e-9:
        best = i
        bestRem = rem
    if best < 0 or bestRem <= 1e-9: break
    inc result[best]
    dec left

proc drawTab(r: GpuiRenderer; p: AhPalette; vm: SessionTabStripVM;
             tab: SessionItem; closable: bool; widthPx = -1): GpuiElement =
  let id = tab.id
  let w = if widthPx > 0: widthPx else: tabWidth(tab, closable)
  result = r.box(pairs = [("width", $w & "px"), ("height", $StripTabPx & "px"),
                          ("items", "center"), ("gap", $TabInnerGapPx & "px"),
                          ("padding-left", $TabPadPx & "px"),
                          ("padding-right", $TabPadPx & "px"),
                          ("rounded", $ControlRadiusPx & "px"),
                          ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
  if tab.active: r.setStyle(result, "background", p.activeTab)
  r.tag(result, "tab", id)
  r.tag(result, "session-tab", id)
  r.tag(result, "attention", $tab.attention)
  r.tag(result, "active", $tab.active)
  r.tag(result, "tooltip", tab.tooltip)
  r.appendChild(result, r.mark(p.markOf(tab.attention)))
  let title = r.text(tabLabelOf(tab), TabTitlePx,
                     if tab.active: p.activeTabText else: p.textCaption,
                     pairs = [("flex-grow", "1")])
  r.tag(title, "label", tabLabelOf(tab))
  r.appendChild(result, title)
  if tab.originShort.len > 0:
    let origin = r.text(tab.originShort, TabOriginPx,
                        if tab.active: p.activeTabOrigin else: p.textCaption,
                        shrink = false)
    r.tag(origin, "origin", tab.originShort)
    r.appendChild(result, origin)
  if closable and tab.active:
    # The layout's close image (`.session-tab-close`), not a glyph.
    let close = r.tabCloseIcon(p)
    r.setStyle(close, "cursor", cursorOf(hkControl))
    r.tag(close, "close", id)
    r.addEventListener(close, "click", proc() = discard vm.close(id))
    r.appendChild(result, close)
  if vm.isInFocus(tab):
    # The focused initiative's tabs: a flat 2px underline in the action
    # role, inside the tab's corners (`.ah-tab-in-focus::after`), never a
    # fill -- a fill reads as the active tab.
    r.setStyle(result, "position", "relative")
    r.appendChild(result, r.underline(p.borderAction, 8, w))
    r.tag(result, "in-focus", "true")
  r.addEventListener(result, "click", proc() = discard vm.activate(id))

proc drawStatusTab(r: GpuiRenderer; p: AhPalette; vm: SessionTabStripVM;
                   message, kind: string; retry: bool; widthPx: int): GpuiElement =
  ## A tab-shaped notice in place of the tabs: loading, empty, or an error
  ## with its Retry. At most what the line leaves beside "+" INSIDE the
  ## strip's 8px right inset (the tabs' budget, `widthPx - 8`), so "+"
  ## keeps the inset as it does beside tabs.
  result = r.stripNotice(p, message, kind, TabTitlePx)
  r.setStyle(result, "max-width", $max(0, widthPx - 8 - AddButtonPx - StripGapPx) & "px")
  if retry:
    let target = vm
    r.appendChild(result, r.stripRetry(p, proc() = target.load()))

proc drawAddButton(r: GpuiRenderer; p: AhPalette): GpuiElement =
  ## "+", a round ghost control (`session-tab-add`).
  result = r.box(pairs = [("width", $AddButtonPx & "px"), ("height", $AddButtonPx & "px"),
                          ("rounded", $(AddButtonPx div 2) & "px"), ("items", "center"),
                          ("justify", "center"), ("background", p.tertiary),
                          ("flex-shrink", "0")])
  r.tag(result, "add", "+")
  r.appendChild(result, r.plusIcon(p))

proc overflowChipWidth*(hidden: int; waits: bool): int =
  ## How wide `drawOverflowChip` draws: 8px in on either side, the warning
  ## mark and its 4px when a hidden tab waits, `+N`; at least 28px.
  max(28, 16 + textPx("+" & $hidden, CaptionPx) + (if waits: MarkPx + 4 else: 0))

proc drawOverflowChip*(r: GpuiRenderer; p: AhPalette; hidden, hiddenWaits: int;
                       onClick: proc(); open = false): GpuiElement =
  ## `+N`: the tabs one line has no room for; a waiting one marks it.
  # A chip the shape of "+" beside it (`.ah-tab-overflow-count`): 24px
  # high on the secondary-hover surface, 12px clear of "+".
  result = r.box(pairs = [("height", "24px"), ("min-width", "28px"),
                          ("items", "center"), ("justify", "center"), ("gap", "4px"),
                          ("padding-left", "8px"), ("padding-right", "8px"),
                          ("rounded", $ControlRadiusPx & "px"), ("flex-shrink", "0"),
                          ("cursor", cursorOf(hkControl))])
  # At rest no fill and no outline, its words in the label role -- a hidden
  # tab that waits is told by the warning mark, not by the colour; while its
  # menu is open the tertiary surface and the body colour
  # (`.ah-tab-strip .ah-tab-overflow-count`, `.overflow-open`).
  if open: r.setStyle(result, "background", p.tertiary)
  r.tag(result, "overflow", $hidden)
  r.tag(result, "overflow-waits", $hiddenWaits)
  if hiddenWaits > 0: r.appendChild(result, r.mark(p.markOf(saNeedsInput)))
  r.appendChild(result, r.text("+" & $hidden, CaptionPx,
                               if open: p.textBody else: p.textLabel, shrink = false))
  if onClick != nil: r.addEventListener(result, "click", onClick)

proc menuItemWidth*(title: string; trailing: seq[string]; tabular = false): int =
  ## The width a dropdown takes for one item set on one line: the menu's own
  ## padding and border, the item's padding, its mark, title and quieter
  ## words, 8px apart (`tabular`: the words in tabular figures).
  result = 2 * 4 + 2 + 2 * MenuItemPadPx + MarkPx + 8 + textPx(title, MenuItemTextPx)
  for word in trailing: result += 8 + textPx(word, CaptionPx, tabular)

func hangMenuLeft*(chipRight, menuW, widthPx: int): int =
  ## Where a `+N` menu `menuW` wide starts when it hangs from the chip
  ## ending at `chipRight`, as the web's (`hangOverflowMenu`): its right
  ## edge on the chip's, shifted only as far as it must be to stay inside
  ## the `widthPx` window on either side.
  max(0, min(chipRight - menuW, widthPx - menuW))

proc drawMenu*(r: GpuiRenderer; p: AhPalette; top, left, width: int;
               kind: string): GpuiElement =
  ## A dropdown under the strip (`session-tab-overflow-menu`).
  ## The dropdown surface is the window's own (`dropdown-surface()`:
  ## surface-primary-default), outlined.
  result = r.box(column = true, pairs = [
    ("position", "absolute"), ("top", $top & "px"), ("left", $left & "px"),
    ("width", $width & "px"), ("background", p.ground), ("padding", "4px"),
    ("border-width", "1px"), ("border-color", p.borderPrimary),
    ("rounded", $ControlRadiusPx & "px")])
  r.tag(result, "menu", kind)

proc drawMenuItem*(r: GpuiRenderer; p: AhPalette; markStyle: MarkStyle;
                   title, key: string; active: bool;
                   trailing: openArray[(string, string)] = [];
                   onClick: proc() = nil; twoLines = false;
                   tabular = false): GpuiElement =
  ## One item of a dropdown: a mark, a title, then quieter facts -- on the
  ## title's line, or `twoLines`, under it (a stacked bar's full-width
  ## menu, 4px by 10px in). `tabular`: the facts in tabular figures (an
  ## initiative's `n/m`, `.ah-tab-progress`).
  result = r.box(pairs = [("height", (if twoLines: "49" else: $MenuItemPx) & "px"),
                          ("items", "center"),
                          ("gap", "8px"), ("padding-left", $MenuItemPadPx & "px"),
                          ("padding-right", $MenuItemPadPx & "px"),
                          ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
  if active: r.setStyle(result, "background", p.activeTab)
  r.tag(result, "menu-item", key)
  r.appendChild(result, r.mark(markStyle))
  let titleEl = r.text(title, MenuItemTextPx,
                       if active: p.activeTabText else: p.textBody,
                       pairs = [("flex-grow", "1")])
  if twoLines:
    let column = r.box(column = true, pairs = [("flex-grow", "1"), ("min-width", "0px"),
                                               ("gap", "2px")])
    r.appendChild(column, titleEl)
    let facts = r.box(pairs = [("gap", "8px"), ("items", "center")])
    for (word, colour) in trailing:
      r.appendChild(facts, r.text(word, CaptionPx, colour, shrink = false,
                                  tabular = tabular))
    r.appendChild(column, facts)
    r.appendChild(result, column)
  else:
    r.appendChild(result, titleEl)
    for (word, colour) in trailing:
      r.appendChild(result, r.text(word, CaptionPx, colour, shrink = false,
                                   tabular = tabular))
  if onClick != nil: r.addEventListener(result, "click", onClick)

proc drawSessionTabStrip*(r: GpuiRenderer; host: GpuiElement;
                          vm: SessionTabStripVM; p: AhPalette; widthPx: int) =
  ## The strip into `host` (its children replaced), `widthPx` wide: one line
  ## or several by `vm.mode`.
  r.clearChildren(host)
  r.styles(host, [("position", "relative"), ("background", p.ground),
                  ("width", $widthPx & "px"), ("display", "flex"),
                  ("flex-direction", "column"), ("padding-top", $StripTopPx & "px")])
  r.tag(host, "surface", "agent-harbor-session-tabs")
  # The caption bar the strip stands for (the web's `.ah-tab-caption`): its
  # height is a layout region checked in pixels.
  r.tag(host, "caption", "session-tabs")
  r.tag(host, "mode", $vm.mode.val)
  r.tag(host, "state", stateName(vm.state.val))
  let tabs = vm.tabs
  var lines: seq[GpuiElement]
  proc newLine(): GpuiElement =
    # The tabs start at the bar's left edge, as `.session-tab-bar` does.
    result = r.box(pairs = [("height", $StripLinePx & "px"), ("items", "center"),
                            ("gap", $StripGapPx & "px")])
    lines.add result
  var line = newLine()
  var overflow: seq[int]
  # Where the `+N` chip starts (one line: the overflow menu hangs from it).
  var chipLeft = 0
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(line, r.drawStatusTab(p, vm, AgentHarborTabsLoadingText, "loading", false,
                                        widthPx))
  of asError:
    r.appendChild(line, r.drawStatusTab(p, vm, AgentHarborTabsErrorText & ": " &
                                        vm.error.val, "error", true, widthPx))
  of asReady:
    if tabs.len == 0:
      r.appendChild(line, r.drawStatusTab(p, vm, AgentHarborTabsEmptyText, "empty", false,
                                          widthPx))
    else:
      let closable = tabs.len > 1
      if vm.mode.val == tsmMultiLine:
        var widths: seq[int]
        for tab in tabs: widths.add tabWidth(tab, closable, wrapped = true)
        # The last line also holds "+".
        let budget = max(TabMinWidthPx, widthPx - 8 - AddButtonPx - StripGapPx)
        let rows = packTabRows(widths, budget, StripGapPx)
        for ri, row in rows:
          if ri > 0: line = newLine()
          for i in row: r.appendChild(line, r.drawTab(p, vm, tabs[i], closable, widths[i]))
      else:
        let layout = vm.singleLine
        overflow = layout.overflow
        # Each tab's flex base size is its content width, unclamped, and
        # its maximum 12rem (`fitWidths`, §9.7): a long title shrinks from
        # its whole width, so short titles are not narrowed to make room.
        var widths, maxes: seq[int]
        var fixed: seq[bool]
        for i in layout.visible:
          widths.add(if tabs[i].active: ActiveTabPx else: tabContentWidth(tabs[i], closable))
          maxes.add(if tabs[i].active: ActiveTabPx else: TabMaxPx)
          fixed.add tabs[i].active
        # "+" and, when tabs overflow, the `+N` chip as `drawOverflowChip`
        # draws it, 12px clear of "+".
        var waits = 0
        for i in overflow:
          if tabs[i].attention == saNeedsInput: inc waits
        let controls = AddButtonPx + StripGapPx +
                       (if overflow.len > 0: overflowChipWidth(overflow.len, waits > 0) + ChipGapPx
                        else: 0)
        let fitted = fitWidths(widths, widthPx - 8 - controls, TabMinWidthPx, StripGapPx,
                               fixed, maxes = maxes)
        for k, i in layout.visible:
          r.appendChild(line, r.drawTab(p, vm, tabs[i], closable, fitted[k]))
          chipLeft += fitted[k] + StripGapPx
  var chipRight = -1
  if overflow.len > 0:
    var waits = 0
    for i in overflow:
      if tabs[i].attention == saNeedsInput: inc waits
    let target = vm
    let chip = r.drawOverflowChip(p, overflow.len, waits, proc() = target.toggleOverflow(),
                                  open = vm.overflowOpen.val)
    # 12px clear of "+" (the strip's 4px gap plus the chip's 8px margin).
    r.setStyle(chip, "margin-right", $(ChipGapPx - StripGapPx) & "px")
    r.tag(chip, "strip-overflow", $overflow.len)
    r.appendChild(line, chip)
    chipRight = chipLeft + overflowChipWidth(overflow.len, waits > 0)
  r.appendChild(line, r.drawAddButton(p))
  for l in lines: r.appendChild(host, l)
  r.tag(host, "lines", $lines.len)
  if vm.mode.val == tsmMultiLine:
    # Wrapped, the caption grows with its lines and keeps 6px under the last
    # tab (`#menu.ah-tab-caption-multiline`, `padding-bottom: 0.375rem`):
    # the last line's 30px hold the tab 2px down, so 4px more.
    r.setStyle(host, "padding-bottom", $(6 - (StripLinePx - StripTabPx) div 2) & "px")
  if overflow.len > 0 and vm.overflowOpen.val:
    # As wide as its widest item, from 13.75em to the window less 0.75rem,
    # 6px below the bar, hung from the `+N` chip as the web's
    # (`hangOverflowMenu`).
    var widest = 0
    for i in overflow:
      widest = max(widest, menuItemWidth(tabs[i].title,
                                         if tabs[i].originShort.len > 0: @[tabs[i].originShort]
                                         else: @[]))
    let menuW = clamp(widest, MenuMinPx, max(MenuMinPx, widthPx - 12))
    let menu = r.drawMenu(p, StripTopPx + lines.len * StripLinePx + MenuGapPx,
                          hangMenuLeft(chipRight, menuW, widthPx), menuW, "overflow")
    r.tag(menu, "strip-menu", "overflow")
    for i in overflow:
      let id = tabs[i].id
      var trailing: seq[(string, string)]
      if tabs[i].originShort.len > 0: trailing.add (tabs[i].originShort, p.textCaption)
      let target = vm
      r.appendChild(menu, r.drawMenuItem(p, p.markOf(tabs[i].attention), tabs[i].title,
                                         id, tabs[i].active, trailing,
                                         proc() = discard target.activate(id)))
    r.appendChild(host, menu)

proc mountSessionTabStrip*(r: GpuiRenderer; host: GpuiElement;
                           vm: SessionTabStripVM; p: AhPalette; widthPx: int) =
  ## Tells the viewmodel how wide the strip is (as the web mount measures
  ## its container) and redraws whenever the viewmodel moves.
  if widthPx > 0 and vm.stripWidthPx.val != widthPx: vm.stripWidthPx.val = widthPx
  createRenderEffect proc() =
    drawSessionTabStrip(r, host, vm, p, widthPx)

# ---------------------------------------------------------------------------
# The list: sidebar and docked
# ---------------------------------------------------------------------------

proc drawListRow(r: GpuiRenderer; p: AhPalette; vm: SessionTabStripVM;
                 tab: SessionItem; collapsed, columns: bool; widthPx = 0): GpuiElement =
  let id = tab.id
  result = r.box(pairs = [("gap", "8px"), ("padding-top", "5px"),
                          ("padding-bottom", "5px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("items", "start"),
                          ("cursor", cursorOf(hkControl)), ("flex-shrink", "0")])
  # The active session: the strip's active tab, as a row
  # (`.ah-session-row-active`). The focused initiative's rows: a 2px bar in
  # the action role down the left edge (`.ah-session-row.ah-tab-in-focus`),
  # never a fill.
  if tab.active: r.setStyle(result, "background", p.activeRow)
  r.setStyle(result, "position", "relative")
  if vm.isInFocus(tab) and not collapsed:
    r.appendChild(result, r.insetBar(p.borderAction, 2))
    r.tag(result, "in-focus", "true")
  r.tag(result, "row", id)
  r.tag(result, "attention", $tab.attention)
  r.tag(result, "active", $tab.active)
  r.tag(result, "tooltip", tab.tooltip)
  r.addEventListener(result, "click", proc() = discard vm.activate(id))
  if collapsed:
    # A rail row (`.ah-session-row-rail`): the mark alone, 8px above and
    # below it -- 24px.
    r.styles(result, [("justify", "center"), ("padding-top", "8px"),
                      ("padding-bottom", "8px")])
    r.appendChild(result, r.mark(p.markOf(tab.attention)))
    return
  let markHolder = r.box(pairs = [("height", "20px"), ("items", "center")])
  r.appendChild(markHolder, r.mark(p.markOf(tab.attention)))
  r.appendChild(result, markHolder)
  let detail = if tab.failureText.len > 0: tab.failureText
               elif tab.activity.len > 0: tab.activity[0].lineText
               else: ""
  let quiet = if tab.active: p.activeRowQuiet else: p.textCaption
  # 16px lines throughout (`type-ui-lineheight-body-sm` and `-caption-md`),
  # so a row is as tall as the web's: 5px, three 16px lines 1px apart, 5px.
  let lh = ("line-height", "16px")
  let title = r.text(tab.title, BodyPx, if tab.active: p.activeTabText else: p.textBody,
                     pairs = [lh])
  r.tag(title, "title", tab.title)
  # The status word keeps its status colour on the active row too
  # (`.ah-att-* .ah-session-row-status`): "needs input" stays the warning
  # colour there; only the meta and the detail turn quiet.
  let status = r.text(tab.statusLabel, CaptionPx, p.statusWordColour(tab.attention),
                      shrink = false, pairs = [lh])
  r.tag(status, "status", tab.statusLabel)
  let metaText = r.text(metaOf(tab), CaptionPx, quiet, pairs = [lh])
  r.tag(metaText, "meta", metaOf(tab))
  let meta = r.box(pairs = [("gap", "6px"), ("items", "center"), ("height", "16px")])
  r.appendChild(meta, status)
  r.appendChild(meta, metaText)
  var detailEl: GpuiElement
  if detail.len > 0:
    # A failure keeps the error role, on the active row too
    # (`.ah-session-row-detail.ah-session-row-failure`); any other detail is
    # `by-mode(caption, label)`, active or not.
    detailEl = r.text(detail, CaptionPx,
                      if tab.failureText.len > 0: p.textError else: p.rowDetail,
                      pairs = [lh])
    r.tag(detailEl, "detail", detail)
  # The age is the row's last grid column, sized to its text (`auto`), in
  # tabular figures (`.ah-session-row-age`).
  let age = r.text(tab.ageLabel, CaptionPx, p.textBodySubtle, shrink = false,
                   tabular = true, pairs = [("text-align", "right"), lh])
  r.tag(age, "age", tab.ageLabel)
  if columns:
    # Docked along the bottom of a wide window, a grid (`.ah-session-list-
    # docked .ah-session-row`): the mark, the title, the status and its meta,
    # then the age at the end of a 4rem column, 8px apart -- title and meta
    # columns sharing what is left equally -- and the activity under the
    # title, with no gap: 5px, two 16px lines, 5px.
    let column = max(0, (widthPx - 2 * InsetPx - MarkPx - DockedAgePx - 3 * 8) div 2)
    let main = r.box(column = true, pairs = [("width", $column & "px"),
                                             ("flex-shrink", "0"), ("min-width", "0px")])
    r.appendChild(main, title)
    if detailEl != nil: r.appendChild(main, detailEl)
    r.appendChild(result, main)
    r.styles(meta, [("width", $column & "px"), ("flex-shrink", "0"), ("min-width", "0px")])
    r.appendChild(result, meta)
    let ageCell = r.box(pairs = [("width", $DockedAgePx & "px"), ("justify", "end"),
                                 ("flex-shrink", "0")])
    r.appendChild(ageCell, age)
    r.appendChild(result, ageCell)
    return
  else:
    let main = r.box(column = true, pairs = [("flex-grow", "1"), ("gap", "1px"),
                                             ("overflow", "hidden")])
    r.appendChild(main, title)
    r.appendChild(main, meta)
    if detailEl != nil: r.appendChild(main, detailEl)
    r.appendChild(result, main)
  r.appendChild(result, age)

proc drawGroupHeader(r: GpuiRenderer; p: AhPalette; vm: SessionTabStripVM;
                     group: SessionTabGroup; widthPx: int): GpuiElement =
  ## An initiative's node of the tree: fold control, state mark, name,
  ## `n/m` milestones and its sessions' counts.
  let planId = group.planId
  # `.ah-session-group-header`: 6px above, 4px below a 24px line, over a
  # hairline.
  result = r.box(pairs = [("gap", "8px"), ("items", "center"), ("height", "35px"),
                          ("padding-top", "6px"), ("padding-bottom", "4px"),
                          ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"),
                          ("cursor", cursorOf(hkControl)), ("flex-shrink", "0")])
  r.rule(result, p.borderSecondary)
  if planId.len > 0 and planId == vm.focusedPlan.val:
    r.setStyle(result, "background", p.tertiary)
  r.tag(result, "group", planId)
  r.tag(result, "folded", $group.collapsed)
  r.tag(result, "state", $group.state)
  # `.ah-session-group-fold` (12px) and `.ah-session-group-title` in the
  # label role.
  r.appendChild(result, r.text(if group.collapsed: "\xE2\x96\xB8" else: "\xE2\x96\xBE",
                               CaptionPx, p.textLabel, shrink = false,
                               pairs = [("width", "12px")]))
  if planId.len > 0: r.appendChild(result, r.mark(p.markOf(group.state)))
  let countWords = countsText(group.counts)
  # The title and the counts share the line as the stylesheet has them
  # share it, and GPUI's flex layout (Taffy, CSS Flexbox §9.7,
  # https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths) resolves
  # it from the faces' real widths: the title `flex: 1 1 auto` and
  # `min-width: 50%`, the counts `flex: 0 100 auto` and `max-width: 50%`
  # (`.ah-session-group-title`, `.ah-session-group-counts`). An overfull line
  # shrinks each in proportion to factor times content, so the counts give
  # way a hundred times faster, the title never below half the line.
  let half = $((widthPx - 2 * InsetPx) div 2) & "px"
  let title = r.text(group.title, CaptionPx, p.textLabel, bold = true,
                     pairs = [("flex-grow", "1"), ("flex-shrink", "1"),
                              ("min-width", half)])
  r.tag(title, "title", group.title)
  r.appendChild(result, title)
  if group.progressText.len > 0:
    # `n/m` (`.ah-tab-progress`): tabular figures.
    r.appendChild(result, r.text(group.progressText, CaptionPx, p.textCaption,
                                 shrink = false, tabular = true))
  let counts = r.text(countWords, CaptionPx, p.textCaption,
                      pairs = [("flex-shrink", "100"), ("min-width", "0px"),
                               ("max-width", half)])
  r.tag(counts, "counts", countsText(group.counts))
  r.appendChild(result, counts)
  let target = vm
  r.addEventListener(result, "click", proc() = target.toggleGroup(planId))

proc drawSessionList*(r: GpuiRenderer; host: GpuiElement; vm: SessionTabStripVM;
                      p: AhPalette; widthPx: int) =
  ## The sidebar (`tsmSidebar`) or docked (`tsmDocked`) layout into `host`.
  r.clearChildren(host)
  let sidebar = vm.mode.val == tsmSidebar
  let collapsed = sidebar and vm.collapsed.val
  let w = if collapsed: RailPx elif sidebar: min(widthPx, SidebarMaxPx) else: widthPx
  let columns = not sidebar and w >= DockedColumnsFromPx
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $w & "px"), ("height", "100%"), ("background", p.panel),
                  ("overflow", "hidden")])
  if sidebar:
    r.styles(host, [("border-right-width", "1px"), ("border-color", p.borderSecondary)])
  r.tag(host, "surface", "agent-harbor-session-list")
  r.tag(host, "mode", $vm.mode.val)
  r.tag(host, "collapsed", $collapsed)
  r.tag(host, "state", stateName(vm.state.val))
  # The head: SESSIONS, the summary, and the sidebar's collapse control.
  let head = r.box(column = true, pairs = [("padding-top", "4px"), ("padding-bottom", "4px"),
                                           ("padding-left", (if collapsed: "0" else: $InsetPx) & "px"),
                                           ("padding-right", (if collapsed: "0" else: $InsetPx) & "px"),
                                           ("gap", "8px"), ("flex-shrink", "0")])
  r.tag(head, "head", "sessions")
  r.rule(head, p.borderSecondary)
  let titleLine = r.box(pairs = [("items", "center"), ("height", $ControlPx & "px"),
                                 ("justify", if collapsed: "center" else: "space-between")])
  if not collapsed:
    r.appendChild(titleLine, r.tracked(r.text("SESSIONS", CaptionPx, p.textBody,
                                              bold = true, shrink = false)))
  if sidebar:
    let target = vm
    let toggle = r.box(pairs = [("width", $ControlPx & "px"), ("height", $ControlPx & "px"),
                                ("items", "center"), ("justify", "center"),
                                ("rounded", $ControlRadiusPx & "px"), ("cursor", cursorOf(hkControl))])
    r.tag(toggle, "collapse", if collapsed: "expand" else: "collapse")
    r.appendChild(toggle, r.text(if collapsed: "\xC2\xBB" else: "\xC2\xAB", BodyPx,
                                 p.textLabel, shrink = false))
    r.addEventListener(toggle, "click",
                       proc() = target.collapsed.val = not target.collapsed.val)
    r.appendChild(titleLine, toggle)
  r.appendChild(head, titleLine)
  if not collapsed and vm.state.val == asReady:
    let summary = r.text(vm.summaryText, CaptionPx, p.textCaption,
                         pairs = [("line-height", "24px")])
    r.tag(summary, "summary", vm.summaryText)
    r.tag(summary, "list-summary", "true")
    if sidebar or not columns:
      r.appendChild(head, summary)
    else:
      # Docked across a wide window, the head is one line: the label, then
      # the summary beside it, 16px off (the head's 8px gap and the
      # summary's own `margin-left: 0.5rem`).
      r.styles(titleLine, [("justify", "start"), ("gap", "8px")])
      r.setStyle(summary, "margin-left", "8px")
      r.appendChild(titleLine, summary)
  elif not collapsed and (sidebar or not columns):
    # Loading or failed: the web still lays out the (empty) summary on its
    # own line under the title (`.ah-session-list-summary`, `flex: 1 1
    # 100%`), so the head keeps its 8px row gap and is as tall as when
    # ready, minus the words. An empty line of no height keeps that gap.
    let summary = r.box(pairs = [("height", "0px")])
    r.tag(summary, "summary-empty", "true")
    r.appendChild(head, summary)
  r.appendChild(host, head)
  if not collapsed and vm.sourceLabel.len > 0:
    let source = r.box(pairs = [("padding-top", "4px"), ("padding-bottom", "4px"),
                                ("height", "33px"), ("items", "center"),
                                ("padding-left", $InsetPx & "px"),
                                ("padding-right", $InsetPx & "px"),
                                ("flex-shrink", "0")])
    r.rule(source, p.borderSecondary)
    let s = r.text(vm.sourceLabel, CaptionPx, p.textCaption)
    r.tag(s, "source", vm.sourceLabel)
    r.appendChild(source, s)
    r.appendChild(host, source)
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(host, r.notice(p, if collapsed: Ellipsis else: AgentHarborTabsLoadingText,
                                 "loading"))
  of asError:
    let target = vm
    r.appendChild(host, r.errorBlock(p, "Could not load the sessions", vm.error.val,
                                     proc() = target.load()))
  of asReady:
    if vm.tabs.len == 0:
      r.appendChild(host, r.notice(p, AgentHarborTabsEmptyText, "empty"))
    else:
      let list = r.box(column = true, pairs = [("flex-grow", "1"), ("overflow", "hidden")])
      r.tag(list, "rows", "list")
      for group in vm.groups:
        let showHeader = vm.grouped.val and not collapsed
        if showHeader: r.appendChild(list, r.drawGroupHeader(p, vm, group, w))
        if not (group.collapsed and showHeader):
          for tab in group.tabs:
            r.appendChild(list, r.drawListRow(p, vm, tab, collapsed, columns, w))
      r.appendChild(host, list)

proc mountSessionList*(r: GpuiRenderer; host: GpuiElement; vm: SessionTabStripVM;
                       p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawSessionList(r, host, vm, p, widthPx)
