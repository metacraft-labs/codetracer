## gpui/agent_harbor/ah_initiative_tab_bar.nim — CTF-P1b. The GPUI view of
## CodeTracer's tab bar with Agent Harbor initiatives as tabs, over
## `InitiativeTabStripVM` (nim-agents-isonim-viewmodels).
##
## The web prototype is `viewmodel/views/isonim_agent_harbor_initiative_tabs_view.nim`.
## Left to right, as there: one tab per initiative (state mark, name, `n/m`;
## the active one with the recording switcher's numbered buttons), a tab per
## open session of no initiative, the `+N` chip and "+"; then, at the bar's
## end, the sessions started elsewhere (a count badge and its label, the
## badge alone when compact) and Previous / Next with the inbox position and
## the auto-switch toggle. A stacked bar puts that group on a line of its
## own. The hovered initiative's progress popup drops from its tab; the
## overflow and elsewhere menus drop from the bar.
##
## Which tabs fit, which recordings show, what the popup and the menus hold,
## and every word on the bar are the viewmodel's; the recording buttons'
## state suffixes are the web switcher's (`agent_harbor_words.stateSuffix`).


import isonim/core/[signals, computation]
import nim_agents_isonim_viewmodels/agent_harbor/initiative_tabs_vm
from ../../viewmodel/views/agent_harbor_words import stateSuffix

import ./ah_theme
import ./ah_session_views
import ./ah_initiative_panels

export initiative_tabs_vm, ah_theme

const
  TabPadPx = 10
  TabInnerGapPx = 6
  TabTitlePx = BodyPx
  InitiativeTabMaxPx = 320   ## 20rem: the active tab with its recordings
  RecordingButtonGapPx = 2
  PopupWidthPx = 384
  ElsewhereMenuPx = 420
  BarGapPx = 4

proc recordingButtonWidth(rb: RecordingButton): int =
  max(18, 8 + textPx($rb.number & stateSuffix(rb.state), CaptionPx))

proc recordingsWidth(buttons: RecordingButtons): int =
  if buttons.buttons.len == 0: return 0
  result = TabInnerGapPx
  for rb in buttons.buttons: result += recordingButtonWidth(rb) + RecordingButtonGapPx
  if buttons.hidden > 0: result += textPx("+" & $buttons.hidden, CaptionPx) + 4

proc initiativeTabWidth*(vm: InitiativeTabStripVM; tab: StripTab): int =
  ## Its content, from 12rem (`InitiativeTabMinWidthPx`) to 20rem.
  var w = 2 * TabPadPx + MarkPx + TabInnerGapPx + textPx(tab.title, TabTitlePx)
  if tab.kind == stkInitiative:
    w += TabInnerGapPx + textPx(tab.progressText, CaptionPx)
    if tab.active: w += recordingsWidth(vm.recordingButtonsOf(tab.id))
  elif tab.session.originShort.len > 0:
    w += TabInnerGapPx + textPx(tab.session.originShort, 10)
  let low = vm.tabMinWidth
  let high = if tab.active: InitiativeTabMaxPx else: low + 16
  clamp(w, low, max(low, high))

proc drawRecordingButton(r: GpuiRenderer; p: AhPalette; vm: InitiativeTabStripVM;
                         initiativeId: string; rb: RecordingButton): GpuiElement =
  let id = rb.id
  result = r.box(pairs = [("height", "18px"), ("min-width", "18px"), ("items", "center"),
                          ("justify", "center"), ("padding-left", "4px"),
                          ("padding-right", "4px"), ("rounded", "4px"),
                          ("flex-shrink", "0"), ("cursor", "pointer")])
  r.tag(result, "recording", $rb.number)
  r.tag(result, "recording-state", $rb.state)
  r.tag(result, "recording-active", $rb.active)
  r.tag(result, "tooltip", rb.tooltip)
  var colour = p.textLabel
  case rb.state
  of rsReady: discard
  of rsLoading:
    r.styles(result, [("border-width", "1px"), ("border-color", p.borderPrimary)])
  of rsFailed:
    colour = p.textError
    r.styles(result, [("border-width", "1px"), ("border-color", p.iconError)])
  of rsMissing:
    colour = p.textWarning
    r.styles(result, [("border-width", "1px"), ("border-color", p.iconWarning)])
  if rb.active:
    r.setStyle(result, "background", p.action)
    colour = p.onAction
  r.appendChild(result, r.text($rb.number & stateSuffix(rb.state), CaptionPx, colour,
                               shrink = false))
  let target = vm
  r.addEventListener(result, "click",
                     proc() = discard target.selectRecording(initiativeId, id))

proc drawBarTab(r: GpuiRenderer; p: AhPalette; vm: InitiativeTabStripVM;
                tab: StripTab; widthPx: int): GpuiElement =
  let key = if tab.kind == stkInitiative: initiativeKey(tab.id) else: sessionKey(tab.id)
  let id = tab.id
  result = r.box(pairs = [("width", $widthPx & "px"),
                          ("height", $StripTabPx & "px"), ("items", "center"),
                          ("gap", $TabInnerGapPx & "px"),
                          ("padding-left", $TabPadPx & "px"),
                          ("padding-right", $TabPadPx & "px"),
                          ("rounded", $ControlRadiusPx & "px"), ("flex-shrink", "0"),
                          ("cursor", "pointer")])
  if tab.active: r.setStyle(result, "background", p.hover)
  r.tag(result, "tab", key)
  r.tag(result, "active", $tab.active)
  r.tag(result, "tooltip", tab.tooltip)
  let target = vm
  r.addEventListener(result, "click", proc() = discard target.activate(key))
  if tab.kind == stkInitiative:
    r.tag(result, "state", $tab.state)
    r.appendChild(result, r.mark(p.markOf(tab.state)))
    # Hovering shows the progress popup, as `mouseenter` does on the web.
    r.addEventListener(result, "mouseenter", proc() = target.popupId.val = id)
    r.addEventListener(result, "mouseleave", proc() =
      if target.popupId.val == id: target.popupId.val = "")
  else:
    r.tag(result, "attention", $tab.session.attention)
    r.appendChild(result, r.mark(p.markOf(tab.session.attention)))
  let title = r.text(tab.title, TabTitlePx, if tab.active: p.textBody else: p.textCaption,
                     pairs = [("flex-grow", "1")])
  r.tag(title, "label", tab.title)
  r.appendChild(result, title)
  if tab.kind == stkInitiative:
    let progress = r.text(tab.progressText, CaptionPx, p.textCaption, shrink = false)
    r.tag(progress, "progress", tab.progressText)
    r.appendChild(result, progress)
    if tab.active:
      let buttons = vm.recordingButtonsOf(id)
      if buttons.buttons.len > 0:
        let switcher = r.box(pairs = [("gap", $RecordingButtonGapPx & "px"),
                                      ("items", "center"), ("flex-shrink", "0")])
        r.tag(switcher, "recordings", $buttons.buttons.len)
        for rb in buttons.buttons: r.appendChild(switcher, r.drawRecordingButton(p, vm, id, rb))
        if buttons.hidden > 0:
          let more = r.text("+" & $buttons.hidden, CaptionPx, p.textCaption, shrink = false)
          r.tag(more, "recordings-hidden", $buttons.hidden)
          r.appendChild(switcher, more)
        r.appendChild(result, switcher)
  elif tab.session.originShort.len > 0:
    r.appendChild(result, r.text(tab.session.originShort, 10, p.textCaption, shrink = false))

proc drawPopup(r: GpuiRenderer; p: AhPalette; popup: InitiativePopup; widthPx: int;
               left, top: int): GpuiElement =
  ## The initiative's progress popup, dropped from its tab.
  result = r.box(column = true, pairs = [
    ("position", "absolute"), ("left", $left & "px"), ("top", $top & "px"),
    ("width", $widthPx & "px"), ("background", p.menu), ("gap", "6px"),
    ("padding", "12px"), ("border-width", "1px"), ("border-color", p.borderPrimary),
    ("rounded", $ControlRadiusPx & "px")])
  r.tag(result, "popup", popup.id)
  let head = r.box(pairs = [("gap", "8px"), ("items", "center")])
  r.appendChild(head, r.mark(p.markOf(popup.state)))
  let title = r.text(popup.title, BodyPx, p.textBody, bold = true, pairs = [("flex-grow", "1")])
  r.tag(title, "title", popup.title)
  r.appendChild(head, title)
  let state = r.text(stateWord(popup.state), CaptionPx, p.stateWordColour(popup.state),
                     shrink = false)
  r.tag(state, "state", stateWord(popup.state))
  r.appendChild(head, state)
  r.appendChild(result, head)
  let headline = r.text(popup.headline, CaptionPx, p.textLabel)
  r.tag(headline, "headline", popup.headline)
  r.appendChild(result, headline)
  r.appendChild(result, r.drawMilestoneBar(p, popup.statusCounts, labelled = true))
  if popup.currentMilestone.len > 0:
    r.appendChild(result, r.drawCurrent(p, popup.currentMilestone))
  if popup.executiveSummary.len > 0:
    let summary = r.text(popup.executiveSummary, CaptionPx, p.textBody, shrink = false,
                         pairs = [("white-space", "normal")])
    r.tag(summary, "executive-summary", popup.executiveSummary)
    r.appendChild(result, summary)
  let sessions = r.box(column = true, pairs = [("padding-top", "6px")])
  r.styles(sessions, [("border-top-width", "1px"), ("border-color", p.borderSecondary)])
  for item in popup.sessions: r.appendChild(sessions, r.drawSessionLine(p, item))
  r.appendChild(result, sessions)

proc drawInbox(r: GpuiRenderer; p: AhPalette; vm: InitiativeTabStripVM): GpuiElement =
  ## Previous / Next over the waiting sessions, and auto-switch; compact, no
  ## position and `Auto: on|off`.
  let target = vm
  let position = vm.inboxPosition
  let compact = vm.compact
  let auto = vm.autoSwitch.val
  result = r.box(pairs = [("gap", "4px"), ("items", "center"), ("flex-shrink", "0")])
  r.tag(result, "inbox", if position.len == 0: "inbox empty" else: position)
  r.appendChild(result, r.button(p, "\xE2\x86\x90", proc() = discard target.stepInbox(-1),
                                 outlined = false))
  if not compact:
    let pos = r.text(if position.len == 0: "inbox empty" else: position, CaptionPx,
                     p.textLabel, shrink = false)
    r.tag(pos, "inbox-position", if position.len == 0: "inbox empty" else: position)
    r.appendChild(result, pos)
  r.appendChild(result, r.button(p, "\xE2\x86\x92", proc() = discard target.stepInbox(1),
                                 outlined = false))
  let label = (if compact: "Auto: " else: "Auto-switch: ") & (if auto: "on" else: "off")
  let toggle = r.button(p, label, proc() = target.autoSwitch.val = not target.autoSwitch.val,
                        outlined = false)
  r.tag(toggle, "auto-switch", $auto)
  if auto: r.setStyle(toggle, "background", p.hover)
  r.appendChild(result, toggle)

proc drawElsewhere(r: GpuiRenderer; p: AhPalette; vm: InitiativeTabStripVM): GpuiElement =
  ## The count badge of the sessions started elsewhere, and its label.
  let target = vm
  result = r.box(pairs = [("gap", "6px"), ("items", "center"), ("height", $ControlPx & "px"),
                          ("padding-left", "4px"), ("padding-right", "6px"),
                          ("rounded", $ControlRadiusPx & "px"), ("cursor", "pointer"),
                          ("flex-shrink", "0")])
  if vm.elsewhereOpen.val: r.setStyle(result, "background", p.hover)
  r.tag(result, "elsewhere", $vm.elsewhereCount)
  r.tag(result, "tooltip", vm.elsewhereTooltip)
  let badge = r.box(pairs = [("min-width", "18px"), ("height", "18px"), ("rounded", "9px"),
                             ("items", "center"), ("justify", "center"),
                             ("background", p.tertiary), ("padding-left", "4px"),
                             ("padding-right", "4px")])
  r.appendChild(badge, r.text($vm.elsewhereCount, CaptionPx - 1, p.textBody, bold = true,
                              shrink = false))
  r.appendChild(result, badge)
  if not vm.compact:
    let label = r.text(vm.elsewhereLabel, CaptionPx, p.textLabel, shrink = false)
    r.tag(label, "elsewhere-label", vm.elsewhereLabel)
    r.appendChild(result, label)
  r.addEventListener(result, "click",
                     proc() = target.elsewhereOpen.val = not target.elsewhereOpen.val)

proc drawInitiativeTabBar*(r: GpuiRenderer; host: GpuiElement;
                           vm: InitiativeTabStripVM; p: AhPalette; widthPx: int) =
  r.clearChildren(host)
  r.styles(host, [("position", "relative"), ("background", p.ground),
                  ("width", $widthPx & "px"), ("display", "flex"),
                  ("flex-direction", "column")])
  r.tag(host, "surface", "agent-harbor-initiative-tabs")
  let ready = vm.state.val == asReady
  r.tag(host, "state", if ready and vm.tabs.len == 0: "empty" else: stateName(vm.state.val))
  r.tag(host, "compact", $vm.compact)
  r.tag(host, "stacked", $vm.stacked)
  let line = r.box(pairs = [("height", $StripLinePx & "px"), ("items", "center"),
                            ("gap", $BarGapPx & "px"), ("padding-left", "4px"),
                            ("padding-right", "4px")])
  let controls = r.box(pairs = [("gap", "8px"), ("items", "center"), ("flex-shrink", "0")])
  r.tag(controls, "controls", "")
  var x = 4
  var popupLeft = -1
  let tabs = vm.tabs
  var overflow: seq[int]
  case vm.state.val
  of asIdle, asLoading:
    let n = r.box(pairs = [("height", $StripTabPx & "px"), ("items", "center"),
                           ("padding-left", "10px"), ("padding-right", "10px"),
                           ("rounded", $ControlRadiusPx & "px"), ("background", p.tertiary)])
    r.tag(n, "notice", "loading")
    r.appendChild(n, r.text("Loading initiatives" & Ellipsis, TabTitlePx, p.textCaption))
    r.appendChild(line, n)
  of asError:
    let message = "Initiatives unavailable: " & vm.error.val
    let n = r.box(pairs = [("height", $StripTabPx & "px"), ("items", "center"),
                           ("gap", "8px"), ("padding-left", "10px"),
                           ("padding-right", "10px"), ("flex-shrink", "1"),
                           ("rounded", $ControlRadiusPx & "px"), ("background", p.tertiary)])
    r.tag(n, "notice", "error")
    let t = r.text(message, TabTitlePx, p.textError)
    r.tag(t, "error", message)
    r.appendChild(n, t)
    let target = vm
    r.appendChild(n, r.button(p, "Retry", proc() = target.load()))
    r.appendChild(line, n)
  of asReady:
    if tabs.len == 0:
      let n = r.box(pairs = [("height", $StripTabPx & "px"), ("items", "center"),
                             ("padding-left", "10px"), ("padding-right", "10px"),
                             ("rounded", $ControlRadiusPx & "px"), ("background", p.tertiary)])
      r.tag(n, "notice", "empty")
      r.appendChild(n, r.text("No initiative is running.", TabTitlePx, p.textCaption))
      r.appendChild(line, n)
    let layout = vm.singleLine
    overflow = layout.overflow
    # The tabs shrink toward their narrowest to leave the controls their room
    # (`flex: 0 1 auto`), as the viewmodel's capacity rule assumes.
    var widths: seq[int]
    for i in layout.visible: widths.add initiativeTabWidth(vm, tabs[i])
    let controlsPx =
      if vm.stacked: InitiativeBarChipPx
      elif vm.compact: InitiativeBarCompactControlsPx
      else: vm.controlsWidth
    let fitted = fitWidths(widths, widthPx - 8 - controlsPx, vm.tabMinWidth, BarGapPx)
    for k, i in layout.visible:
      if tabs[i].kind == stkInitiative and vm.popupId.val == tabs[i].id: popupLeft = x
      r.appendChild(line, r.drawBarTab(p, vm, tabs[i], fitted[k]))
      x += fitted[k] + BarGapPx
    if overflow.len > 0:
      var waits = 0
      for i in overflow:
        if tabs[i].kind == stkInitiative and tabs[i].state == isNeedsInput or
            tabs[i].kind == stkSession and tabs[i].session.attention == saNeedsInput:
          inc waits
      let target = vm
      r.appendChild(line, r.drawOverflowChip(p, overflow.len, waits, proc() =
        target.overflowOpen.val = not target.overflowOpen.val))
    if vm.elsewhereCount > 0: r.appendChild(controls, r.drawElsewhere(p, vm))
  # "+" right after the last tab.
  let add = r.box(pairs = [("width", "26px"), ("height", "26px"), ("rounded", "13px"),
                           ("items", "center"), ("justify", "center"),
                           ("background", p.tertiary), ("flex-shrink", "0")])
  r.tag(add, "add", "+")
  r.appendChild(add, r.text("+", BodyLargePx, p.textCaption, shrink = false))
  r.appendChild(line, add)
  if vm.state.val in {asReady, asError}: r.appendChild(controls, r.drawInbox(p, vm))
  if vm.stacked:
    r.appendChild(host, line)
    let second = r.box(pairs = [("height", $StripLinePx & "px"), ("items", "center"),
                                ("padding-left", "4px"), ("padding-right", "4px")])
    r.appendChild(second, controls)
    r.appendChild(host, second)
  else:
    r.appendChild(line, r.box(pairs = [("flex-grow", "1")]))
    r.appendChild(line, controls)
    r.appendChild(host, line)
  let below = (if vm.stacked: 2 else: 1) * StripLinePx
  if ready and popupLeft >= 0:
    let popupW = min(PopupWidthPx, max(160, widthPx - 8))
    let left = min(popupLeft, max(0, widthPx - popupW - 4))
    r.appendChild(host, drawPopup(r, p, vm.popupOf(vm.popupId.val), popupW, left, below + 4))
  if ready and overflow.len > 0 and vm.overflowOpen.val:
    let menuW = min(OverflowMenuPx, max(160, widthPx - 8))
    let menu = r.drawMenu(p, below, max(0, min(x, widthPx - menuW - 4)), menuW, "overflow")
    for i in overflow:
      let tab = tabs[i]
      let key = if tab.kind == stkInitiative: initiativeKey(tab.id) else: sessionKey(tab.id)
      let m = if tab.kind == stkInitiative: p.markOf(tab.state)
              else: p.markOf(tab.session.attention)
      let target = vm
      r.appendChild(menu, r.drawMenuItem(p, m, tab.title, key, tab.active,
        (if tab.progressText.len > 0: @[(tab.progressText, p.textCaption)] else: @[]),
        proc() = discard target.activate(key)))
    r.appendChild(host, menu)
  if ready and vm.elsewhereCount > 0 and vm.elsewhereOpen.val:
    let elsewhereW = min(ElsewhereMenuPx, max(160, widthPx - 8))
    let menu = r.drawMenu(p, below, max(0, widthPx - elsewhereW - 4), elsewhereW,
                          "elsewhere")
    for entry in vm.elsewhere:
      let id = entry.item.id
      let where = if entry.initiativeTitle.len > 0: entry.initiativeTitle
                  else: "no initiative"
      var trailing = @[(where, p.textCaption),
                       (entry.item.statusLabel, p.statusWordColour(entry.item.attention))]
      if entry.item.originShort.len > 0: trailing.add (entry.item.originShort, p.textCaption)
      let target = vm
      r.appendChild(menu, r.drawMenuItem(p, p.markOf(entry.item.attention), entry.item.title,
                                         id, false, trailing,
                                         proc() = discard target.openSession(id)))
    r.appendChild(host, menu)

proc mountInitiativeTabBar*(r: GpuiRenderer; host: GpuiElement;
                            vm: InitiativeTabStripVM; p: AhPalette; widthPx: int) =
  ## Tells the viewmodel how wide the bar is, as the web mount does, and
  ## redraws whenever it moves.
  if widthPx > 0 and vm.stripWidth.val != widthPx: vm.stripWidth.val = widthPx
  createRenderEffect proc() =
    drawInitiativeTabBar(r, host, vm, p, widthPx)
