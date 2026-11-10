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


import ../../../common/pointer_shape
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
  TabTitlePx = BodyLargePx    ## the bar's 1rem, as the session strip's
  TabMinPx = 128              ## every initiative tab's `min-width: 8rem`
  InactiveTabMaxPx = 256      ## an inactive tab's `max-width: 16rem`
  InitiativeTabMaxPx = 384    ## the active one's (24rem): it holds its recordings
  RecordingButtonGapPx = 2
  PopupWidthPx = 384          ## `.ah-initiative-popup`: 24rem, at most 80vw
  ElsewhereMenuPx = 608       ## `.ah-elsewhere-menu`: 38rem, at most 100vw - 1rem
  BarGapPx = 4
  BarChipGapPx = 8            ## the bar's `+N` chip: 6px margin, "+" 2px more
  InboxStepPx = 25
  InboxPositionPx = 72        ## `.ah-inbox-position` min-width: 4.5rem
  InboxPositionPadPx = 4      ## and its `padding: 0 0.25rem`, inside that minimum
  ControlsGapPx = 4           ## `.ah-bar-controls` gap: 0.25rem
  ElsewhereMarginPx = 4       ## `.ah-elsewhere` margin-right: 0.25rem

proc recordingButtonWidth(rb: RecordingButton): int =
  ## Its number in tabular figures (`.ah-rec-button`), 4px in on each side.
  max(18, 8 + textPx($rb.number & stateSuffix(rb.state), CaptionPx, tabular = true))

proc recordingsWidth(buttons: RecordingButtons): int =
  if buttons.buttons.len == 0: return 0
  result = TabInnerGapPx
  for rb in buttons.buttons: result += recordingButtonWidth(rb) + RecordingButtonGapPx
  if buttons.hidden > 0: result += textPx("+" & $buttons.hidden, CaptionPx) + 4

proc initiativeTabContent(vm: InitiativeTabStripVM; tab: StripTab): int =
  ## Its content's width, unclamped: what a browser takes as its flex base
  ## size, and so what it shrinks in proportion to.
  result = 2 * TabPadPx + MarkPx + TabInnerGapPx + textPx(tab.title, TabTitlePx)
  if tab.kind == stkInitiative:
    result += TabInnerGapPx + textPx(tab.progressText, CaptionPx, tabular = true)
    if tab.active: result += recordingsWidth(vm.recordingButtonsOf(tab.id))
  elif tab.session.originShort.len > 0:
    result += TabInnerGapPx + textPx(tab.session.originShort, CaptionPx)

proc initiativeTabWidth*(vm: InitiativeTabStripVM; tab: StripTab; barPx = 0): int =
  ## Its content, from 8rem to 16rem (the active one to 24rem).
  let w = initiativeTabContent(vm, tab)
  # A stacked bar's active tab leaves its line room for the chip and "+"
  # (`max-width: calc(100% - 88px)`).
  let activeMax = if vm.stacked and barPx > 0: min(InitiativeTabMaxPx, barPx - 88)
                  else: InitiativeTabMaxPx
  clamp(w, TabMinPx, if tab.active: max(TabMinPx, activeMax) else: InactiveTabMaxPx)

proc initiativeTabMinWidth(vm: InitiativeTabStripVM; tab: StripTab): int =
  ## The narrowest a tab shrinks to when the bar is full: its name at its
  ## `min-width: 4.5rem` beside everything else it holds, and never under
  ## `min-width: 8rem`.
  result = 2 * TabPadPx + MarkPx + TabInnerGapPx + 72
  if tab.kind == stkInitiative:
    result += TabInnerGapPx + textPx(tab.progressText, CaptionPx, tabular = true)
    if tab.active: result += recordingsWidth(vm.recordingButtonsOf(tab.id))
  result = max(result, TabMinPx)

proc drawRecordingButton(r: GpuiRenderer; p: AhPalette; vm: InitiativeTabStripVM;
                         initiativeId: string; rb: RecordingButton): GpuiElement =
  let id = rb.id
  result = r.box(pairs = [("height", "18px"), ("min-width", "18px"), ("items", "center"),
                          ("justify", "center"), ("padding-left", "4px"),
                          ("padding-right", "4px"), ("rounded", "4px"),
                          ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
  r.tag(result, "recording", $rb.number)
  r.tag(result, "recording-state", $rb.state)
  r.tag(result, "recording-active", $rb.active)
  r.tag(result, "tooltip", rb.tooltip)
  # Every recording button is outlined (`.ah-rec-button`, 1px in the
  # primary border role); loading dashes it, a failed one is outlined in
  # the error role (Light: its text colour), a missing one in the warning
  # icon role; the active one is filled with the action role
  # (`by-mode(surface-action-primary, border-action)`) in on-action text.
  var colour = p.textLabel
  var border = p.borderPrimary
  case rb.state
  of rsReady: discard
  of rsLoading:
    border = if p.mode == dmDark: p.textCaption else: p.textLabel
    r.setStyle(result, "border-style", "dashed")
  of rsFailed:
    colour = p.textError
    border = if p.mode == dmDark: p.borderError else: p.textError
  of rsMissing:
    colour = p.textWarning
    border = p.iconWarning
  if rb.active:
    let fill = if p.mode == dmDark: p.action else: p.borderAction
    r.setStyle(result, "background", fill)
    if rb.state != rsLoading: border = fill
    colour = p.onAction
  r.styles(result, [("border-width", "1px"), ("border-color", border)])
  r.appendChild(result, r.text($rb.number & stateSuffix(rb.state), CaptionPx, colour,
                               shrink = false, tabular = true))
  let target = vm
  r.addEventListener(result, "click",
                     proc() = discard target.selectRecording(initiativeId, id))

proc drawBarTab(r: GpuiRenderer; p: AhPalette; vm: InitiativeTabStripVM;
                tab: StripTab; widthPx, minPx, basisPx: int): GpuiElement =
  let key = if tab.kind == stkInitiative: initiativeKey(tab.id) else: sessionKey(tab.id)
  let id = tab.id
  # `flex: 0 1 auto` over the tab's natural width, down to `min-width:
  # 8rem`: the bar's own flex layout shrinks a full bar's tabs (in
  # proportion to their widths, CSS Flexbox §9.7), as the web bar does; the
  # name keeps 4.5rem of itself (its own `min-width`).
  # The flex basis is the content's whole width, the cap its `max-width`.
  result = r.box(pairs = [("flex-basis", $basisPx & "px"), ("max-width", $widthPx & "px"),
                          ("min-width", $minPx & "px"),
                          ("height", $StripTabPx & "px"), ("items", "center"),
                          ("gap", $TabInnerGapPx & "px"),
                          ("padding-left", $TabPadPx & "px"),
                          ("padding-right", $TabPadPx & "px"),
                          ("rounded", $ControlRadiusPx & "px"), ("flex-shrink", "1"),
                          ("overflow", "hidden"), ("cursor", cursorOf(hkControl))])
  if tab.active: r.setStyle(result, "background", p.activeTab)
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
  let title = r.text(tab.title, TabTitlePx,
                     if tab.active: p.activeTabText else: p.textCaption,
                     pairs = [("flex-grow", "1"), ("min-width", "72px")])
  r.tag(title, "label", tab.title)
  r.appendChild(result, title)
  if tab.kind == stkInitiative:
    # The active tab's figures, readable on Light's raised fill:
    # `by-mode(caption, label)`; tabular (`.ah-tab-progress`).
    let progress = r.text(tab.progressText, CaptionPx,
                          if tab.active: p.activeRowQuiet else: p.textCaption,
                          shrink = false, tabular = true)
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
          # The recordings that did not fit: a count in a recording
          # button's outline (`.ah-rec-more`: the label role, outlined
          # `by-mode(border-primary, text-primary-caption)` so it shows on
          # the active tab's fill in Light too).
          let moreBorder = if p.mode == dmDark: p.borderPrimary else: p.textCaption
          let more = r.box(pairs = [("height", "18px"), ("items", "center"),
                                    ("padding-left", "4px"), ("padding-right", "4px"),
                                    ("rounded", "4px"), ("border-width", "1px"),
                                    ("border-color", moreBorder), ("flex-shrink", "0")])
          r.appendChild(more, r.text("+" & $buttons.hidden, CaptionPx, p.textLabel,
                                     shrink = false))
          r.tag(more, "recordings-hidden", $buttons.hidden)
          r.appendChild(switcher, more)
        r.appendChild(result, switcher)
  elif tab.session.originShort.len > 0:
    r.appendChild(result, r.text(tab.session.originShort, CaptionPx, p.textCaption, shrink = false))

proc drawPopup(r: GpuiRenderer; p: AhPalette; popup: InitiativePopup; widthPx: int;
               left, top: int): GpuiElement =
  ## The initiative's progress popup, dropped from its tab.
  result = r.box(column = true, pairs = [
    ("position", "absolute"), ("left", $left & "px"), ("top", $top & "px"),
    ("width", $widthPx & "px"), ("background", p.ground), ("gap", "6px"),
    ("padding-top", "10px"), ("padding-bottom", "10px"), ("padding-left", "12px"),
    ("padding-right", "12px"), ("border-width", "1px"), ("border-color", p.borderPrimary),
    ("rounded", $ControlRadiusPx & "px")])
  r.tag(result, "popup", popup.id)
  # `.ah-popup-head`: the title semibold at 14px and the state at 12px, on
  # the face's normal line heights (21px and 18px), the state in the label
  # role unless it names a status (`.ah-popup-state-*`).
  let head = r.box(pairs = [("gap", "8px"), ("items", "center"), ("height", "21px")])
  r.appendChild(head, r.mark(p.markOf(popup.state)))
  let title = r.text(popup.title, BodyPx, p.textBody, bold = true,
                     pairs = [("flex-grow", "1"), ("line-height", "21px")])
  r.tag(title, "title", popup.title)
  r.appendChild(head, title)
  let stateColour = case popup.state
                    of isNeedsInput, isWorking, isBlocked: p.stateWordColour(popup.state)
                    else: p.textLabel
  let state = r.text(stateWord(popup.state), CaptionPx, stateColour,
                     shrink = false, pairs = [("line-height", "18px")])
  r.tag(state, "state", stateWord(popup.state))
  r.appendChild(head, state)
  r.appendChild(result, head)
  # `.ah-popup-headline`: caption text in the caption role, on an 18px line.
  let headline = r.text(popup.headline, CaptionPx, p.textCaption,
                        pairs = [("line-height", "18px")])
  r.tag(headline, "headline", popup.headline)
  r.appendChild(result, headline)
  # Inside the popup's 12px padding and 1px border.
  r.appendChild(result, r.drawMilestoneBar(p, popup.statusCounts, labelled = true,
                                           availPx = widthPx - 2 * 12 - 2))
  if popup.currentMilestone.len > 0:
    r.appendChild(result, r.drawCurrent(p, popup.currentMilestone))
  if popup.executiveSummary.len > 0:
    let summary = r.text(popup.executiveSummary, CaptionPx, p.textBody, shrink = false,
                         pairs = [("white-space", "normal"), ("line-height", "16px")])
    r.tag(summary, "executive-summary", popup.executiveSummary)
    r.appendChild(result, summary)
  # `.ah-popup-sessions`: under a hairline, 6px down, the lines 1px apart.
  let sessions = r.box(column = true, pairs = [("padding-top", "6px"), ("gap", "1px")])
  r.styles(sessions, [("border-top-width", "1px"), ("border-color", p.borderSecondary)])
  for item in popup.sessions: r.appendChild(sessions, r.drawSessionLine(p, item))
  r.appendChild(result, sessions)

proc autoLabel(vm: InitiativeTabStripVM): string =
  (if vm.compact: "Auto: " else: "Auto-switch: ") & (if vm.autoSwitch.val: "on" else: "off")

proc inboxPositionText(vm: InitiativeTabStripVM): string =
  if vm.inboxPosition.len == 0: "inbox empty" else: vm.inboxPosition

proc inboxSlotWidth(vm: InitiativeTabStripVM): int =
  ## The position's slot as the browser sizes `.ah-inbox-position` (a
  ## border box): at least 4.5rem, padding included, and wider when its
  ## words and their 0.25rem padding on either side need more (measured:
  ## 72px for `4 waiting`, 81px for `inbox empty`).
  max(InboxPositionPx,
      textPx(inboxPositionText(vm), CaptionPx, tabular = true) + 2 * InboxPositionPadPx)

proc inboxWidth(vm: InitiativeTabStripVM): int =
  ## How wide `drawInbox` draws (no margins: `.ah-bar-controls .ah-inbox`
  ## zeroes them): the two steps, the position's slot (`inboxSlotWidth`), the
  ## toggle 4px further off (6px in, no border, and when on the action mark
  ## 6px before its words), all 2px apart.
  result = 2 * InboxStepPx + 2 * 2 + 4 + 12 + textPx(autoLabel(vm), CaptionPx)
  if vm.autoSwitch.val: result += MarkPx + 6
  if not vm.compact: result += 2 + inboxSlotWidth(vm)

proc elsewhereWidth(vm: InitiativeTabStripVM): int =
  ## How wide `drawElsewhere` draws, its 4px right margin included: 6px in,
  ## its count badge, and (unless compact) its label 6px after it.
  result = ElsewhereMarginPx + 12 +
           max(18, 8 + textPx($vm.elsewhereCount, CaptionPx - 1, tabular = true))
  if not vm.compact: result += 6 + textPx(vm.elsewhereLabel, CaptionPx)

proc inboxStep(r: GpuiRenderer; p: AhPalette; arrow: string; onClick: proc();
               disabled = false): GpuiElement =
  ## Previous or Next (`.ah-inbox-step`): a 16px arrow, 6px in, 24px high,
  ## 25px wide as the browser sets it (the arrow's advance in the
  ## interface face; GPUI may set the glyph from a fallback face).
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("width", $InboxStepPx & "px"),
                          ("justify", "center"), ("padding-left", "6px"),
                          ("padding-right", "6px"), ("flex-shrink", "0"),
                          ("rounded", $ControlRadiusPx & "px"), ("cursor", cursorOf(hkControl))])
  # With nothing waiting the step has nowhere to go: the disabled role at
  # full opacity, as the browser draws it; the label role otherwise.
  let ink = inboxStepInk(p, disabled)
  r.appendChild(result, r.text(arrow, BodyLargePx, ink, shrink = false))
  r.tag(result, "ink", ink)
  r.tag(result, "button", arrow)
  r.tag(result, "step", if disabled: "disabled" else: "enabled")
  r.addEventListener(result, "click", onClick)

proc drawInbox(r: GpuiRenderer; p: AhPalette; vm: InitiativeTabStripVM): GpuiElement =
  ## Previous / Next over the waiting sessions, and auto-switch; compact, no
  ## position and `Auto: on|off`. `.ah-inbox`: its parts 2px apart, no
  ## margins inside the bar's controls; the position at least 4.5rem,
  ## centred, so the steps do not move as it changes; the toggle without an
  ## outline, with the action mark while on.
  let target = vm
  let position = vm.inboxPosition
  let compact = vm.compact
  let auto = vm.autoSwitch.val
  result = r.box(pairs = [("gap", "2px"), ("items", "center"), ("flex-shrink", "0")])
  r.tag(result, "inbox", if position.len == 0: "inbox empty" else: position)
  r.appendChild(result, r.inboxStep(p, "\xE2\x86\x90", proc() = discard target.stepInbox(-1),
                                   disabled = position.len == 0))
  if not compact:
    # A minimum, not a width: the slot grows with its words and their
    # padding past the 4.5rem (`inboxSlotWidth`).
    let slot = r.box(pairs = [("min-width", $InboxPositionPx & "px"),
                              ("padding-left", $InboxPositionPadPx & "px"),
                              ("padding-right", $InboxPositionPadPx & "px"),
                              ("justify", "center"), ("items", "center"),
                              ("flex-shrink", "0")])
    r.tag(slot, "inbox-slot", "true")
    # `.ah-inbox-position` in the label role (the stylesheet's later rule),
    # in tabular figures.
    let pos = r.text(if position.len == 0: "inbox empty" else: position, CaptionPx,
                     p.textLabel, shrink = false, tabular = true)
    r.tag(pos, "inbox-position", if position.len == 0: "inbox empty" else: position)
    r.appendChild(slot, pos)
    r.appendChild(result, slot)
  r.appendChild(result, r.inboxStep(p, "\xE2\x86\x92", proc() = discard target.stepInbox(1),
                                   disabled = position.len == 0))
  let toggle = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                              ("gap", "6px"), ("padding-left", "6px"),
                              ("padding-right", "6px"), ("margin-left", "4px"),
                              ("flex-shrink", "0"), ("rounded", $ControlRadiusPx & "px"),
                              ("cursor", cursorOf(hkControl))])
  # No outline in the bar, on or off (`.ah-initiative-tab-bar .ah-inbox-auto`:
  # `border-width: 0`, and while on `box-shadow: none`): "on" is told by the
  # action mark and the body colour.
  # The "on" dot is in the action BORDER role in both modes
  # (`.ah-inbox-auto-on::before`: `colors-ui-border-action`); the action
  # surface is Light's pale selection fill, on which the dot vanishes.
  if auto: r.appendChild(toggle, r.mark(MarkStyle(colour: p.borderAction)))
  r.appendChild(toggle, r.text(autoLabel(vm), CaptionPx,
                               if auto: p.textBody else: p.textLabel, shrink = false))
  r.tag(toggle, "button", autoLabel(vm))
  r.tag(toggle, "auto-switch", $auto)
  r.addEventListener(toggle, "click", proc() = target.autoSwitch.val = not target.autoSwitch.val)
  r.appendChild(result, toggle)

const
  ElsewhereInitiativePx = 144 ## the menu's initiative column: `minmax(0, 9rem)`
  ElsewhereStatusPx = 88      ## its state column: 5.5rem
  ElsewhereOriginPx = 28      ## its origin column: 1.75rem
  ElsewhereColumnGapPx = 10   ## `column-gap: 0.625rem`
  ElsewhereStackedPx = 49     ## a stacked row: two lines, 4px above and below

proc drawElsewhereItem(r: GpuiRenderer; p: AhPalette; entry: ElsewhereSession;
                       stacked: bool; onClick: proc()): GpuiElement =
  ## One row of the sessions-started-elsewhere menu, laid out as the web lays
  ## it out (`.ah-elsewhere-menu .ah-tab-overflow-item`, a grid): the mark,
  ## the title, then the initiative, the state and the front-end of origin
  ## in columns of their own, so every row's initiative and state start at
  ## one x. The initiative is in the label role (a session of no initiative
  ## says so in the caption role); the state and the origin are in the
  ## caption role -- the menu does not colour the state, the mark carries it.
  ## On a stacked bar each row takes two lines: the title and its origin,
  ## then the initiative and the state under the title, both right ends
  ## aligned.
  let noInitiative = entry.initiativeTitle.len == 0
  let initiative = r.text(if noInitiative: "no initiative" else: entry.initiativeTitle,
                          CaptionPx, if noInitiative: p.textCaption else: p.textLabel)
  let status = r.text(entry.item.statusLabel, CaptionPx, p.textCaption, shrink = false)
  let title = r.text(entry.item.title, MenuItemTextPx, p.textBody,
                     pairs = [("flex-grow", "1"), ("flex-basis", "0px"), ("min-width", "0px")])
  var origin: GpuiElement = nil
  if entry.item.originShort.len > 0:
    origin = r.text(entry.item.originShort, CaptionPx, p.textCaption, shrink = false)
  result = r.box(pairs = [("padding-left", $MenuItemPadPx & "px"),
                          ("padding-right", $MenuItemPadPx & "px"),
                          ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
  r.tag(result, "menu-item", entry.item.id)
  if not stacked:
    r.styles(result, [("height", $MenuItemPx & "px"), ("items", "center"),
                      ("gap", $ElsewhereColumnGapPx & "px")])
    r.appendChild(result, r.mark(p.markOf(entry.item.attention)))
    r.appendChild(result, title)
    r.styles(initiative, [("width", $ElsewhereInitiativePx & "px"),
                          ("min-width", $ElsewhereInitiativePx & "px"), ("flex-shrink", "0")])
    r.appendChild(result, initiative)
    r.styles(status, [("width", $ElsewhereStatusPx & "px"),
                      ("min-width", $ElsewhereStatusPx & "px")])
    r.appendChild(result, status)
    # The origin column ends at the row's right edge (`justify-self: end`).
    let originCell = r.box(pairs = [("width", $ElsewhereOriginPx & "px"),
                                    ("min-width", $ElsewhereOriginPx & "px"),
                                    ("flex-shrink", "0"), ("justify", "end")])
    if origin != nil: r.appendChild(originCell, origin)
    r.appendChild(result, originCell)
  else:
    # Two grid lines, 2px apart, between 4px insets; the mark sits on the
    # title's line, the initiative under the title, and the third column
    # (as wide as its widest cell) holds the origin over the state, both at
    # its right end.
    r.styles(result, [("height", $ElsewhereStackedPx & "px"), ("flex-direction", "column"),
                      ("justify", "center"), ("gap", "2px")])
    # The third column (`auto`) is as wide as the wider of its two cells.
    let thirdPx = max(textPx(entry.item.originShort, CaptionPx),
                      textPx(entry.item.statusLabel, CaptionPx))
    proc third(cell: GpuiElement): GpuiElement =
      result = r.box(pairs = [("width", $thirdPx & "px"), ("min-width", $thirdPx & "px"),
                              ("flex-shrink", "0"), ("justify", "end")])
      if cell != nil: r.appendChild(result, cell)
    let first = r.box(pairs = [("items", "center"), ("gap", $ElsewhereColumnGapPx & "px")])
    r.appendChild(first, r.mark(p.markOf(entry.item.attention)))
    r.appendChild(first, title)
    r.appendChild(first, third(origin))
    let second = r.box(pairs = [("items", "center"), ("gap", $ElsewhereColumnGapPx & "px"),
                                ("padding-left", $(MarkPx + ElsewhereColumnGapPx) & "px")])
    r.styles(initiative, [("flex-grow", "1"), ("flex-basis", "0px"), ("min-width", "0px")])
    r.appendChild(second, initiative)
    r.appendChild(second, third(status))
    r.appendChild(result, first)
    r.appendChild(result, second)
  if onClick != nil: r.addEventListener(result, "click", onClick)

proc drawElsewhere(r: GpuiRenderer; p: AhPalette; vm: InitiativeTabStripVM): GpuiElement =
  ## The count badge of the sessions started elsewhere, and its label.
  let target = vm
  result = r.box(pairs = [("gap", "6px"), ("items", "center"), ("height", $ControlPx & "px"),
                          ("padding-left", "6px"), ("padding-right", "6px"),
                          ("rounded", $ControlRadiusPx & "px"), ("cursor", cursorOf(hkControl)),
                          ("flex-shrink", "0"), ("margin-right", $ElsewhereMarginPx & "px")])
  # The tertiary surface while its menu is open (`.ah-elsewhere-open`).
  if vm.elsewhereOpen.val: r.setStyle(result, "background", p.tertiary)
  r.tag(result, "elsewhere", $vm.elsewhereCount)
  r.tag(result, "tooltip", vm.elsewhereTooltip)
  let badge = r.box(pairs = [("min-width", "18px"), ("height", "18px"), ("rounded", "9px"),
                             ("items", "center"), ("justify", "center"),
                             ("background", p.tertiary), ("padding-left", "4px"),
                             ("padding-right", "4px")])
  # `.ah-elsewhere-count`: tabular figures.
  r.appendChild(badge, r.text($vm.elsewhereCount, CaptionPx - 1, p.textBody, bold = true,
                              shrink = false, tabular = true))
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
                  ("flex-direction", "column"), ("padding-top", $StripTopPx & "px")])
  r.tag(host, "surface", "agent-harbor-initiative-tabs")
  let ready = vm.state.val == asReady
  r.tag(host, "state", if ready and vm.tabs.len == 0: "empty" else: stateName(vm.state.val))
  r.tag(host, "compact", $vm.compact)
  r.tag(host, "stacked", $vm.stacked)
  # The tabs start at the bar's left edge, as `.session-tab-bar` does; the
  # bar ends 8px short of the window.
  let line = r.box(pairs = [("height", $StripLinePx & "px"), ("items", "center"),
                            ("gap", $BarGapPx & "px"), ("padding-right", "8px")])
  let controls = r.box(pairs = [("gap", $ControlsGapPx & "px"), ("items", "center"),
                                ("flex-shrink", "0")])
  r.tag(controls, "controls", "bar controls")
  var x = 0
  var popupLeft = -1
  var elsewhereRight = -1
  let tabs = vm.tabs
  var overflow: seq[int]
  case vm.state.val
  of asIdle, asLoading:
    let n = r.stripNotice(p, "Loading initiatives" & Ellipsis, "loading", TabTitlePx)
    if vm.stacked: r.setStyle(n, "max-width", $(widthPx - 8 - 40) & "px")
    r.appendChild(line, n)
  of asError:
    let message = "Initiatives unavailable: " & vm.error.val
    let n = r.stripNotice(p, message, "error", TabTitlePx)
    # Stacked, the notice gives way first, keeping "+" on its line
    # (`max-width: calc(100% - 2.5rem)`).
    if vm.stacked: r.setStyle(n, "max-width", $(widthPx - 8 - 40) & "px")
    let target = vm
    r.appendChild(n, r.stripRetry(p, proc() = target.load()))
    r.appendChild(line, n)
  of asReady:
    if tabs.len == 0:
      let n = r.stripNotice(p, "No initiative is running.", "empty", TabTitlePx)
      if vm.stacked: r.setStyle(n, "max-width", $(widthPx - 8 - 40) & "px")
      r.appendChild(line, n)
    let layout = vm.singleLine
    overflow = layout.overflow
    # The tabs shrink toward their narrowest to leave the controls their room
    # (`flex: 0 1 auto`), as the viewmodel's capacity rule assumes.
    var widths, mins: seq[int]
    for i in layout.visible:
      widths.add initiativeTabWidth(vm, tabs[i], widthPx - 8)
      mins.add initiativeTabMinWidth(vm, tabs[i])
    # The bar's controls at its end never shrink (`.ah-bar-controls`), so
    # the tabs get what they leave.
    # What the rest of the line takes, as drawn here: "+", the chip with its
    # 12px, and -- unless the bar is stacked -- the controls group (the
    # elsewhere control and the inbox), 4px apart.
    var controlsPx = 26 + BarGapPx
    if overflow.len > 0: controlsPx += overflowChipWidth(overflow.len, true) + BarChipGapPx
    if not vm.stacked:
      controlsPx += inboxWidth(vm)
      if vm.elsewhereCount > 0: controlsPx += ControlsGapPx + elsewhereWidth(vm)
    # Where each tab will end up (the popup and the overflow menu hang from
    # them): the same proportional shrink the layout applies.
    let fitted = fitWidths(widths, widthPx - 8 - controlsPx, TabMinPx, BarGapPx,
                           mins = mins)
    for k, i in layout.visible:
      if tabs[i].kind == stkInitiative and vm.popupId.val == tabs[i].id: popupLeft = x
      r.appendChild(line, r.drawBarTab(p, vm, tabs[i], widths[k], min(TabMinPx, widths[k]),
                                       initiativeTabContent(vm, tabs[i])))
      x += fitted[k] + BarGapPx
    if overflow.len > 0:
      var waits = 0
      for i in overflow:
        if tabs[i].kind == stkInitiative and tabs[i].state == isNeedsInput or
            tabs[i].kind == stkSession and tabs[i].session.attention == saNeedsInput:
          inc waits
      let target = vm
      # 8px from "+"; filled only while its menu is open.
      let chip = r.drawOverflowChip(p, overflow.len, waits, proc() =
        target.overflowOpen.val = not target.overflowOpen.val, open = vm.overflowOpen.val)
      r.setStyle(chip, "margin-right", $(BarChipGapPx - BarGapPx) & "px")
      r.appendChild(line, chip)
      x += 28 + BarChipGapPx
    if vm.elsewhereCount > 0:
      r.appendChild(controls, r.drawElsewhere(p, vm))
      # Where the elsewhere control's anchor ends (the chip and its 4px
      # margin, the controls' gap before the inbox): its menu hangs
      # right-aligned under it (`right: 0`), unless the bar is stacked.
      elsewhereRight = widthPx - 8 -
        (if vm.state.val in {asReady, asError}: inboxWidth(vm) + ControlsGapPx else: 0)
  # "+" right after the last tab.
  let add = r.box(pairs = [("width", "26px"), ("height", "26px"), ("rounded", "13px"),
                           ("items", "center"), ("justify", "center"),
                           ("background", p.tertiary), ("flex-shrink", "0")])
  r.tag(add, "add", "+")
  r.appendChild(add, r.plusIcon(p))
  r.appendChild(line, add)
  if vm.state.val in {asReady, asError}: r.appendChild(controls, r.drawInbox(p, vm))
  if vm.stacked:
    r.appendChild(host, line)
    # Stacked, the controls take the second line's width (`.ah-bar-stacked
    # .ah-bar-controls`), their parts from its start.
    let second = r.box(pairs = [("height", $StripLinePx & "px"), ("items", "center"),
                                ("padding-right", "8px")])
    r.setStyle(controls, "flex-grow", "1")
    r.appendChild(second, controls)
    r.appendChild(host, second)
  else:
    # The controls at the bar's end (`margin-left: auto`): right after "+"
    # when the tabs fill the bar.
    r.appendChild(line, r.box(pairs = [("flex-grow", "1")]))
    r.setStyle(controls, "margin-left", "-" & $(2 * BarGapPx) & "px")
    r.appendChild(line, controls)
    r.appendChild(host, line)
  # A menu or the popup hangs 6px below the line it drops from.
  let tabBottom = StripTopPx + (StripLinePx + StripTabPx) div 2
  let below = (if vm.stacked: 2 else: 1) * StripLinePx + StripTopPx + MenuGapPx - 2
  if ready and popupLeft >= 0:
    let popupW = min(PopupWidthPx, widthPx * 4 div 5)
    let left = min(popupLeft, max(0, widthPx - popupW))
    r.appendChild(host, drawPopup(r, p, vm.popupOf(vm.popupId.val), popupW, left,
                                  tabBottom + MenuGapPx))
  if ready and overflow.len > 0 and vm.overflowOpen.val:
    var widest = 0
    for i in overflow:
      widest = max(widest, menuItemWidth(tabs[i].title,
                                         if tabs[i].progressText.len > 0: @[tabs[i].progressText]
                                         else: @[], tabular = true))
    let menuW = clamp(widest, MenuMinPx, max(MenuMinPx, widthPx - 12))
    let menu = r.drawMenu(p, tabBottom + MenuGapPx,
                          max(0, min(x - 28 - BarChipGapPx, widthPx - 12 - menuW)), menuW,
                          "overflow")
    for i in overflow:
      let tab = tabs[i]
      let key = if tab.kind == stkInitiative: initiativeKey(tab.id) else: sessionKey(tab.id)
      let m = if tab.kind == stkInitiative: p.markOf(tab.state)
              else: p.markOf(tab.session.attention)
      let target = vm
      r.appendChild(menu, r.drawMenuItem(p, m, tab.title, key, tab.active,
        (if tab.progressText.len > 0: @[(tab.progressText, p.textCaption)] else: @[]),
        proc() = discard target.activate(key), tabular = true))
    r.appendChild(host, menu)
  if ready and vm.elsewhereCount > 0 and vm.elsewhereOpen.val:
    let elsewhereW = if vm.stacked: widthPx - 16 else: min(ElsewhereMenuPx, widthPx - 16)
    let left = if vm.stacked: 0 else: max(0, elsewhereRight - elsewhereW)
    let menu = r.drawMenu(p, below, left, elsewhereW, "elsewhere")
    for entry in vm.elsewhere:
      let id = entry.item.id
      let target = vm
      r.appendChild(menu, r.drawElsewhereItem(p, entry, vm.stacked,
                                              proc() = discard target.openSession(id)))
    r.appendChild(host, menu)

proc mountInitiativeTabBar*(r: GpuiRenderer; host: GpuiElement;
                            vm: InitiativeTabStripVM; p: AhPalette; widthPx: int) =
  ## Tells the viewmodel how wide the bar is, as the web mount does, and
  ## redraws whenever it moves.
  if widthPx > 0 and vm.stripWidth.val != widthPx: vm.stripWidth.val = widthPx
  createRenderEffect proc() =
    drawInitiativeTabBar(r, host, vm, p, widthPx)
