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
  TabTitlePx = BodyPx
  TabOriginPx = 10
  TabClosePx = 10
  TabMaxPx = 192           ## 12rem
  ActiveTabMaxPx = TabMinWidthPx + ActiveTabExtraPx
  StripGapPx = session_tabs_vm.TabGapPx
  AddButtonPx = 26
  ChipPx = 46
  OverflowMenuPx* = 320
  SidebarMaxPx* = 448      ## `.ah-session-list-sidebar` max-width: 28rem
  RailPx* = 40             ## collapsed: 2.5rem
  DockedColumnsFromPx = 768  ## `@container ah-session-list (min-width: 48rem)`
  DockedRowMaxPx = 1024
  RowAgePx = 40

# ---------------------------------------------------------------------------
# The strip
# ---------------------------------------------------------------------------

proc tabWidth*(tab: SessionItem; closable: bool): int =
  ## A tab's width as the web strip sizes it: its content, between 10rem and
  ## 12rem (14rem for the active tab, which also holds the close control).
  var w = 2 * TabPadPx + MarkPx + TabInnerGapPx + textPx(tabLabelOf(tab), TabTitlePx)
  if tab.originShort.len > 0: w += TabInnerGapPx + textPx(tab.originShort, TabOriginPx)
  if closable and tab.active: w += TabInnerGapPx + TabClosePx
  clamp(w, TabMinWidthPx, if tab.active: ActiveTabMaxPx else: TabMaxPx)

proc fitWidths*(widths: seq[int]; budget, minPx, gap: int): seq[int] =
  ## Shrinks tabs that are wider than `minPx` until the row fits `budget`
  ## (CSS `flex: 0 1 auto` over `min-width`): the widest give first, none
  ## below its minimum. A row that cannot fit at the minimum keeps it.
  result = widths
  var total = gap * max(0, widths.len - 1)
  for w in widths: total += w
  while total > budget:
    var widest = -1
    for i, w in result:
      if w > minPx and (widest < 0 or w > result[widest]): widest = i
    if widest < 0: break
    dec result[widest]
    dec total

proc drawTab(r: GpuiRenderer; p: AhPalette; vm: SessionTabStripVM;
             tab: SessionItem; closable: bool; widthPx = -1): GpuiElement =
  let id = tab.id
  let w = if widthPx > 0: widthPx else: tabWidth(tab, closable)
  result = r.box(pairs = [("width", $w & "px"), ("height", $StripTabPx & "px"),
                          ("items", "center"), ("gap", $TabInnerGapPx & "px"),
                          ("padding-left", $TabPadPx & "px"),
                          ("padding-right", $TabPadPx & "px"),
                          ("rounded", $ControlRadiusPx & "px"),
                          ("flex-shrink", "0"), ("cursor", "pointer")])
  if tab.active: r.setStyle(result, "background", p.hover)
  elif vm.isInFocus(tab): r.setStyle(result, "background", p.tertiary)
  r.tag(result, "tab", id)
  r.tag(result, "attention", $tab.attention)
  r.tag(result, "active", $tab.active)
  r.tag(result, "tooltip", tab.tooltip)
  r.appendChild(result, r.mark(p.markOf(tab.attention)))
  let title = r.text(tabLabelOf(tab), TabTitlePx,
                     if tab.active: p.textBody else: p.textCaption,
                     pairs = [("flex-grow", "1")])
  r.tag(title, "label", tabLabelOf(tab))
  r.appendChild(result, title)
  if tab.originShort.len > 0:
    let origin = r.text(tab.originShort, TabOriginPx, p.textCaption, shrink = false)
    r.tag(origin, "origin", tab.originShort)
    r.appendChild(result, origin)
  if closable and tab.active:
    let close = r.text("\xC3\x97", BodyPx, p.textCaption, shrink = false,
                       pairs = [("cursor", "pointer")])
    r.tag(close, "close", id)
    r.addEventListener(close, "click", proc() = discard vm.close(id))
    r.appendChild(result, close)
  r.addEventListener(result, "click", proc() = discard vm.activate(id))

proc drawStatusTab(r: GpuiRenderer; p: AhPalette; vm: SessionTabStripVM;
                   message, kind: string; retry: bool): GpuiElement =
  ## A tab-shaped notice in place of the tabs: loading, empty, or an error
  ## with its Retry.
  result = r.box(pairs = [("height", $StripTabPx & "px"), ("items", "center"),
                          ("gap", "8px"), ("padding-left", $TabPadPx & "px"),
                          ("padding-right", $TabPadPx & "px"),
                          ("rounded", $ControlRadiusPx & "px"),
                          ("background", p.tertiary), ("flex-shrink", "1")])
  r.tag(result, "notice", kind)
  let words = r.text(message, TabTitlePx,
                     if kind == "error": p.textError else: p.textCaption)
  if kind == "error": r.tag(words, "error", message)
  r.appendChild(result, words)
  if retry:
    let target = vm
    r.appendChild(result, r.button(p, "Retry", proc() = target.load()))

proc drawAddButton(r: GpuiRenderer; p: AhPalette): GpuiElement =
  ## "+", a round ghost control (`session-tab-add`).
  result = r.box(pairs = [("width", $AddButtonPx & "px"), ("height", $AddButtonPx & "px"),
                          ("rounded", $(AddButtonPx div 2) & "px"), ("items", "center"),
                          ("justify", "center"), ("background", p.tertiary),
                          ("flex-shrink", "0")])
  r.tag(result, "add", "+")
  r.appendChild(result, r.text("+", BodyLargePx, p.textCaption, shrink = false))

proc drawOverflowChip*(r: GpuiRenderer; p: AhPalette; hidden, hiddenWaits: int;
                       onClick: proc()): GpuiElement =
  ## `+N`: the tabs one line has no room for; a waiting one marks it.
  result = r.box(pairs = [("height", $StripTabPx & "px"), ("min-width", "32px"),
                          ("items", "center"), ("justify", "center"), ("gap", "4px"),
                          ("padding-left", "6px"), ("padding-right", "6px"),
                          ("rounded", $ControlRadiusPx & "px"), ("flex-shrink", "0"),
                          ("cursor", "pointer")])
  r.tag(result, "overflow", $hidden)
  r.tag(result, "overflow-waits", $hiddenWaits)
  if hiddenWaits > 0: r.appendChild(result, r.mark(p.markOf(saNeedsInput)))
  r.appendChild(result, r.text("+" & $hidden, CaptionPx,
                               if hiddenWaits > 0: p.textWarning else: p.textCaption,
                               shrink = false))
  if onClick != nil: r.addEventListener(result, "click", onClick)

proc drawMenu*(r: GpuiRenderer; p: AhPalette; top, left, width: int;
               kind: string): GpuiElement =
  ## A dropdown under the strip (`session-tab-overflow-menu`).
  result = r.box(column = true, pairs = [
    ("position", "absolute"), ("top", $top & "px"), ("left", $left & "px"),
    ("width", $width & "px"), ("background", p.menu), ("padding", "4px"),
    ("border-width", "1px"), ("border-color", p.borderPrimary),
    ("rounded", $ControlRadiusPx & "px"), ("gap", "2px")])
  r.tag(result, "menu", kind)

proc drawMenuItem*(r: GpuiRenderer; p: AhPalette; markStyle: MarkStyle;
                   title, key: string; active: bool;
                   trailing: openArray[(string, string)] = [];
                   onClick: proc() = nil): GpuiElement =
  ## One item of a dropdown: a mark, a title, then quieter facts.
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("gap", "8px"), ("padding-left", "8px"),
                          ("padding-right", "8px"), ("rounded", "4px"),
                          ("cursor", "pointer")])
  if active: r.setStyle(result, "background", p.hover)
  r.tag(result, "menu-item", key)
  r.appendChild(result, r.mark(markStyle))
  r.appendChild(result, r.text(title, CaptionPx + 1, p.textBody,
                               pairs = [("flex-grow", "1")]))
  for (word, colour) in trailing:
    r.appendChild(result, r.text(word, CaptionPx, colour, shrink = false))
  if onClick != nil: r.addEventListener(result, "click", onClick)

proc drawSessionTabStrip*(r: GpuiRenderer; host: GpuiElement;
                          vm: SessionTabStripVM; p: AhPalette; widthPx: int) =
  ## The strip into `host` (its children replaced), `widthPx` wide: one line
  ## or several by `vm.mode`.
  r.clearChildren(host)
  r.styles(host, [("position", "relative"), ("background", p.ground),
                  ("width", $widthPx & "px")])
  r.tag(host, "surface", "agent-harbor-session-tabs")
  r.tag(host, "mode", $vm.mode.val)
  r.tag(host, "state", stateName(vm.state.val))
  let tabs = vm.tabs
  var lines: seq[GpuiElement]
  proc newLine(): GpuiElement =
    result = r.box(pairs = [("height", $StripLinePx & "px"), ("items", "center"),
                            ("gap", $StripGapPx & "px"), ("padding-left", "4px")])
    lines.add result
  var line = newLine()
  var overflow: seq[int]
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(line, r.drawStatusTab(p, vm, AgentHarborTabsLoadingText, "loading", false))
  of asError:
    r.appendChild(line, r.drawStatusTab(p, vm, AgentHarborTabsErrorText & ": " &
                                        vm.error.val, "error", true))
  of asReady:
    if tabs.len == 0:
      r.appendChild(line, r.drawStatusTab(p, vm, AgentHarborTabsEmptyText, "empty", false))
    else:
      let closable = tabs.len > 1
      if vm.mode.val == tsmMultiLine:
        var widths: seq[int]
        for tab in tabs: widths.add tabWidth(tab, closable)
        # The last line also holds "+".
        let budget = max(TabMinWidthPx, widthPx - 8 - AddButtonPx - StripGapPx)
        let rows = packTabRows(widths, budget, StripGapPx)
        for ri, row in rows:
          if ri > 0: line = newLine()
          for i in row: r.appendChild(line, r.drawTab(p, vm, tabs[i], closable))
      else:
        let layout = vm.singleLine
        overflow = layout.overflow
        var widths: seq[int]
        for i in layout.visible: widths.add tabWidth(tabs[i], closable)
        let controls = AddButtonPx + StripGapPx +
                       (if overflow.len > 0: ChipPx + StripGapPx else: 0)
        let fitted = fitWidths(widths, widthPx - 8 - controls, TabMinWidthPx, StripGapPx)
        for k, i in layout.visible:
          r.appendChild(line, r.drawTab(p, vm, tabs[i], closable, fitted[k]))
  if overflow.len > 0:
    var waits = 0
    for i in overflow:
      if tabs[i].attention == saNeedsInput: inc waits
    let target = vm
    r.appendChild(line, r.drawOverflowChip(p, overflow.len, waits,
                                           proc() = target.toggleOverflow()))
  r.appendChild(line, r.drawAddButton(p))
  for l in lines: r.appendChild(host, l)
  r.tag(host, "lines", $lines.len)
  if overflow.len > 0 and vm.overflowOpen.val:
    let menuW = min(OverflowMenuPx, max(160, widthPx - 8))
    let menu = r.drawMenu(p, lines.len * StripLinePx,
                          max(0, widthPx - menuW - 4), menuW, "overflow")
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
                 tab: SessionItem; collapsed, columns: bool): GpuiElement =
  let id = tab.id
  result = r.box(pairs = [("gap", "8px"), ("padding-top", "5px"),
                          ("padding-bottom", "5px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("items", "start"),
                          ("cursor", "pointer"), ("flex-shrink", "0")])
  if tab.active: r.setStyle(result, "background", p.hover)
  elif vm.isInFocus(tab): r.setStyle(result, "background", p.tertiary)
  r.tag(result, "row", id)
  r.tag(result, "attention", $tab.attention)
  r.tag(result, "active", $tab.active)
  r.tag(result, "tooltip", tab.tooltip)
  r.addEventListener(result, "click", proc() = discard vm.activate(id))
  let markHolder = r.box(pairs = [("height", "20px"), ("items", "center")])
  r.appendChild(markHolder, r.mark(p.markOf(tab.attention)))
  r.appendChild(result, markHolder)
  if collapsed:
    r.setStyle(result, "justify", "center")
    return
  let detail = if tab.failureText.len > 0: tab.failureText
               elif tab.activity.len > 0: tab.activity[0].lineText
               else: ""
  let title = r.text(tab.title, BodyPx, p.textBody)
  r.tag(title, "title", tab.title)
  let status = r.text(tab.statusLabel, CaptionPx, p.statusWordColour(tab.attention),
                      shrink = false)
  r.tag(status, "status", tab.statusLabel)
  let metaText = r.text(metaOf(tab), CaptionPx, p.textCaption)
  r.tag(metaText, "meta", metaOf(tab))
  let meta = r.box(pairs = [("gap", "6px"), ("items", "center")])
  r.appendChild(meta, status)
  r.appendChild(meta, metaText)
  var detailEl: GpuiElement
  if detail.len > 0:
    detailEl = r.text(detail, CaptionPx,
                      if tab.failureText.len > 0: p.textError else: p.textCaption)
    r.tag(detailEl, "detail", detail)
  let age = r.text(tab.ageLabel, CaptionPx, p.textCaption, shrink = false,
                   pairs = [("width", $RowAgePx & "px"), ("text-align", "right")])
  r.tag(age, "age", tab.ageLabel)
  if columns:
    # Docked along the bottom of a wide window: title, then status and meta,
    # then the age on one line; the activity under the title.
    r.setStyle(result, "max-width", $DockedRowMaxPx & "px")
    let main = r.box(column = true, pairs = [("flex-grow", "1"), ("gap", "1px")])
    let top = r.box(pairs = [("gap", "12px"), ("items", "center")])
    r.setStyle(title, "max-width", "512px")
    r.appendChild(top, title)
    r.setStyle(meta, "flex-grow", "1")
    r.appendChild(top, meta)
    r.appendChild(main, top)
    if detailEl != nil: r.appendChild(main, detailEl)
    r.appendChild(result, main)
  else:
    let main = r.box(column = true, pairs = [("flex-grow", "1"), ("gap", "1px"),
                                             ("overflow", "hidden")])
    r.appendChild(main, title)
    r.appendChild(main, meta)
    if detailEl != nil: r.appendChild(main, detailEl)
    r.appendChild(result, main)
  r.appendChild(result, age)

proc drawGroupHeader(r: GpuiRenderer; p: AhPalette; vm: SessionTabStripVM;
                     group: SessionTabGroup): GpuiElement =
  ## An initiative's node of the tree: fold control, state mark, name,
  ## `n/m` milestones and its sessions' counts.
  let planId = group.planId
  result = r.box(pairs = [("gap", "8px"), ("items", "center"), ("height", "28px"),
                          ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"),
                          ("cursor", "pointer"), ("flex-shrink", "0")])
  r.rule(result, p.borderSecondary)
  if planId.len > 0 and planId == vm.focusedPlan.val:
    r.setStyle(result, "background", p.tertiary)
  r.tag(result, "group", planId)
  r.tag(result, "folded", $group.collapsed)
  r.tag(result, "state", $group.state)
  r.appendChild(result, r.text(if group.collapsed: "\xE2\x96\xB8" else: "\xE2\x96\xBE",
                               CaptionPx, p.textCaption, shrink = false))
  if planId.len > 0: r.appendChild(result, r.mark(p.markOf(group.state)))
  let title = r.text(group.title, CaptionPx, p.textBody, bold = true)
  r.tag(title, "title", group.title)
  r.appendChild(result, title)
  if group.progressText.len > 0:
    r.appendChild(result, r.text(group.progressText, CaptionPx, p.textCaption,
                                 shrink = false))
  let counts = r.text(countsText(group.counts), CaptionPx, p.textCaption)
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
                                           ("gap", "2px"), ("flex-shrink", "0")])
  r.rule(head, p.borderSecondary)
  let titleLine = r.box(pairs = [("items", "center"), ("height", $ControlPx & "px"),
                                 ("justify", if collapsed: "center" else: "space-between")])
  if not collapsed:
    r.appendChild(titleLine, r.text("SESSIONS", CaptionPx, p.textBody, bold = true,
                                    shrink = false))
  if sidebar:
    let target = vm
    let toggle = r.box(pairs = [("width", $ControlPx & "px"), ("height", $ControlPx & "px"),
                                ("items", "center"), ("justify", "center"),
                                ("rounded", $ControlRadiusPx & "px"), ("cursor", "pointer")])
    r.tag(toggle, "collapse", if collapsed: "expand" else: "collapse")
    r.appendChild(toggle, r.text(if collapsed: "\xC2\xBB" else: "\xC2\xAB", BodyPx,
                                 p.textLabel, shrink = false))
    r.addEventListener(toggle, "click",
                       proc() = target.collapsed.val = not target.collapsed.val)
    r.appendChild(titleLine, toggle)
  r.appendChild(head, titleLine)
  if not collapsed and vm.state.val == asReady:
    let summary = r.text(vm.summaryText, CaptionPx, p.textCaption)
    r.tag(summary, "summary", vm.summaryText)
    r.appendChild(head, summary)
  r.appendChild(host, head)
  if not collapsed and vm.sourceLabel.len > 0:
    let source = r.box(pairs = [("padding-top", "4px"), ("padding-bottom", "4px"),
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
      for group in vm.groups:
        let showHeader = vm.grouped.val and not collapsed
        if showHeader: r.appendChild(list, r.drawGroupHeader(p, vm, group))
        if not (group.collapsed and showHeader):
          for tab in group.tabs:
            r.appendChild(list, r.drawListRow(p, vm, tab, collapsed, columns))
      r.appendChild(host, list)

proc mountSessionList*(r: GpuiRenderer; host: GpuiElement; vm: SessionTabStripVM;
                       p: AhPalette; widthPx: int) =
  createRenderEffect proc() =
    drawSessionList(r, host, vm, p, widthPx)
