## IsoNim view of CodeTracer's tab bar with Agent Harbor initiatives as tabs,
## over `InitiativeTabStripVM` (nim-agents-isonim-viewmodels, the sessions
## family's initiative-tab-bar variant).
##
## Built from CodeTracer's own session tab strip (`session_tabs.styl`), in the
## caption bar, left to right:
##
## - Previous / Next session (`‹ 2 of 5 ›`) and the auto-switch toggle: they
##   walk the sessions waiting for the operator, switching tabs;
## - one tab per active initiative: its state mark (needs input, working,
##   blocked, idle, ended), its name and `n/m` milestones; the active one
##   carries the recording switcher's numbered buttons for the replays loaded
##   for it (`isonim_recording_switcher_view.nim`); hovering one shows its
##   progress popup (executive summary, milestones by status, current
##   milestone, its sessions);
## - a tab per open session launched for no initiative;
## - `[N agent harbor sessions]`: the sessions started elsewhere, a menu from
##   which one is opened as a tab;
## - "+".
##
## What a tab says is the viewmodel's; the view draws it.

import std/strutils
when defined(js):
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import nim_agents_isonim_viewmodels/agent_harbor/initiative_tabs_vm
import ./isonim_session_tabs_view
import ./isonim_recording_switcher_view
import ./isonim_agent_harbor_initiatives_view

export signals, computation, components, initiative_tabs_vm

const
  InitiativeTabBarClass* = "session-tab-bar ah-tab-strip ah-initiative-tab-bar"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc stateClass*(state: InitiativeState): string = "ah-ist-" & $state

proc countsLine*(counts: array[MilestoneStatusClass, int]): string =
  var parts: seq[string]
  for status in MilestoneStatusClass:
    if counts[status] > 0: parts.add $counts[status] & " " & $status
  parts.join(" \xC2\xB7 ")

proc renderPopupSession[R](r: R; item: SessionItem): auto =
  ui(r):
    tdiv(class = "ah-initiative-session ah-att-" & $item.attention, title = item.tooltip):
      span(class = "ah-tab-mark"):
        discard
      span(class = "ah-initiative-session-title"):
        text item.title
      span(class = "ah-initiative-session-status"):
        text item.statusLabel

proc renderPopup[R](r: R; popup: InitiativePopup): auto =
  ## The initiative's progress popup, under its tab.
  var sessions, barHost: typeof(r.createElement("div"))
  let node = ui(r):
    tdiv(class = "ah-initiative-popup " & stateClass(popup.state), role = "tooltip"):
      tdiv(class = "ah-popup-head"):
        span(class = "ah-tab-mark"):
          discard
        span(class = "ah-popup-title"):
          text popup.title
        span(class = "ah-popup-state ah-popup-state-" & $popup.state):
          text stateWord(popup.state)
      tdiv(class = "ah-popup-headline"):
        text popup.headline
      tdiv(ref = barHost, class = "ah-initiative-bar-host")
      if popup.currentMilestone.len > 0:
        tdiv(class = "ah-initiative-current"):
          span(class = "ah-initiative-label"):
            text "Current"
          span(class = "ah-initiative-current-text"):
            text popup.currentMilestone
      if popup.executiveSummary.len > 0:
        tdiv(class = "ah-popup-summary"):
          text popup.executiveSummary
      tdiv(ref = sessions, class = "ah-popup-sessions")
  r.appendRendered(barHost, renderMilestoneBar(r, popup.statusCounts, labelled = true))
  for item in popup.sessions:
    r.appendRendered(sessions, renderPopupSession(r, item))
  node

proc renderInitiativeTab[R](r: R; vm: InitiativeTabStripVM; tab: StripTab): auto =
  let key = initiativeKey(tab.id)
  let id = tab.id
  var node, switchHost: typeof(r.createElement("div"))
  let res = ui(r):
    tdiv(ref = node, class = tabClass(tab.active) & " ah-tab ah-initiative-tab " &
                             stateClass(tab.state),
         title = tab.tooltip, role = "button", tabindex = "0",
         onclick = proc() = discard vm.activate(key)):
      span(class = "ah-tab-mark"):
        discard
      span(class = SessionTabLabelClass):
        text tab.title
      span(class = "ah-tab-progress"):
        text tab.progressText
      tdiv(ref = switchHost, class = "ah-tab-recordings")
  if tab.active:
    let buttons = vm.recordingButtonsOf(id)
    if buttons.buttons.len > 0:
      let target = vm
      r.appendRendered(switchHost, renderRecordingSwitcher[R, typeof(node)](r, buttons,
        proc(recordingId: string) = discard target.selectRecording(id, recordingId)))
  when defined(js):
    when typeof(node) is isonim_dom.Element:
      let target = vm
      isonim_dom.addEventListener(isonim_dom.Node(node), cstring"mouseenter",
        proc(ev: isonim_dom.Event) = target.popupId.val = id)
      isonim_dom.addEventListener(isonim_dom.Node(node), cstring"mouseleave",
        proc(ev: isonim_dom.Event) =
          if target.popupId.val == id: target.popupId.val = "")
  if vm.popupId.val == id:
    r.appendRendered(node, renderPopup(r, vm.popupOf(id)))
  res

proc renderSessionTab[R](r: R; vm: InitiativeTabStripVM; tab: StripTab): auto =
  let key = sessionKey(tab.id)
  ui(r):
    tdiv(class = tabClass(tab.active) & " ah-tab ah-att-" & $tab.session.attention,
         title = tab.tooltip, role = "button", tabindex = "0",
         onclick = proc() = discard vm.activate(key)):
      span(class = "ah-tab-mark"):
        discard
      span(class = SessionTabLabelClass):
        text tab.title
      if tab.session.originShort.len > 0:
        span(class = "ah-tab-origin", title = "started from " & tab.session.originLabel):
          text tab.session.originShort

proc renderOverflowTab[R](r: R; vm: InitiativeTabStripVM; tab: StripTab): auto =
  let key = if tab.kind == stkInitiative: initiativeKey(tab.id) else: sessionKey(tab.id)
  let cls = if tab.kind == stkInitiative: stateClass(tab.state)
            else: "ah-att-" & $tab.session.attention
  ui(r):
    tdiv(class = SessionTabOverflowItemClass & " ah-tab-overflow-item " & cls,
         title = tab.tooltip, onclick = proc() = discard vm.activate(key)):
      span(class = "ah-tab-mark"):
        discard
      span(class = "ah-tab-overflow-title"):
        text tab.title
      if tab.progressText.len > 0:
        span(class = "ah-tab-progress"):
          text tab.progressText

proc renderElsewhereItem[R](r: R; vm: InitiativeTabStripVM; entry: ElsewhereSession): auto =
  let id = entry.item.id
  ui(r):
    tdiv(class = SessionTabOverflowItemClass & " ah-tab-overflow-item ah-att-" &
                 $entry.item.attention,
         title = entry.item.tooltip, onclick = proc() = discard vm.openSession(id)):
      span(class = "ah-tab-mark"):
        discard
      span(class = "ah-tab-overflow-title"):
        text entry.item.title
      span(class = "ah-elsewhere-status"):
        text entry.item.statusLabel
      if entry.item.originShort.len > 0:
        span(class = "ah-tab-origin", title = "started from " & entry.item.originLabel):
          text entry.item.originShort

proc renderInbox[R](r: R; vm: InitiativeTabStripVM): auto =
  ## Previous / Next session and auto-switch; a compact bar drops the
  ## position (the Next button's tooltip gives it) and shortens the toggle to
  ## `Auto: on|off`, its state always on the button.
  let target = vm
  let position = vm.inboxPosition
  let none = position.len == 0
  let auto = vm.autoSwitch.val
  let compact = vm.compact
  let positionText = if none: "inbox empty" else: position
  let autoLabel = (if compact: "Auto: " else: "Auto-switch: ") & (if auto: "on" else: "off")
  ui(r):
    tdiv(class = "ah-inbox" & (if none: " ah-inbox-empty" else: ""), role = "group",
         title = "Sessions waiting for you"):
      button(class = "ah-inbox-step", title = "Previous session (inbox)",
             onclick = proc() = discard target.stepInbox(-1)):
        text "\xE2\x86\x90"
      if not compact:
        span(class = "ah-inbox-position"):
          text positionText
      button(class = "ah-inbox-step", title = "Next session (inbox)" &
                     (if compact and not none: ": " & positionText else: ""),
             onclick = proc() = discard target.stepInbox(1)):
        text "\xE2\x86\x92"
      button(class = "ah-inbox-auto" & (if auto: " ah-inbox-auto-on" else: ""),
             title = (if auto: "Auto-switch is on: after your instruction the next waiting session comes up"
                      else: "Auto-switch is off: turn it on to go to the next waiting session after each instruction"),
             onclick = proc() = target.autoSwitch.val = not target.autoSwitch.val):
        text autoLabel

proc renderAgentHarborInitiativeTabBar*[R, N](r: R; vm: InitiativeTabStripVM): N =
  mixin clearChildren, setAttribute
  var bar, controls: N
  let host = ui(r):
    tdiv(class = "ah-tab-strip-host"):
      tdiv(ref = bar, id = SessionTabBarId, class = InitiativeTabBarClass)
  createRenderEffect proc() =
    r.clearChildren(bar)
    # The right-hand group -- the sessions started elsewhere, Previous/Next
    # with auto-switch, and "+" -- is one unit that never shrinks, so "+"
    # stays in view; a stacked bar puts it on a line of its own.
    let controlsNode = ui(r):
      tdiv(ref = controls, class = "ah-bar-controls")
    case vm.state.val
    of asIdle, asLoading:
      let notice = ui(r):
        tdiv(class = SessionTabClass & " ah-tab-notice ah-tab-loading"):
          span(class = SessionTabLabelClass):
            text "Loading initiatives\xE2\x80\xA6"
      r.appendRendered(bar, notice)
    of asError:
      let target = vm
      let message = "Initiatives unavailable: " & vm.error.val
      let notice = ui(r):
        tdiv(class = SessionTabClass & " ah-tab-notice ah-tab-error", title = message):
          span(class = SessionTabLabelClass):
            text message
          button(class = "ah-tab-retry", onclick = proc() = target.load()):
            text "Retry"
      r.appendRendered(bar, notice)
    of asReady:
      let tabs = vm.tabs
      if tabs.len == 0:
        let notice = ui(r):
          tdiv(class = SessionTabClass & " ah-tab-notice ah-tab-empty"):
            span(class = SessionTabLabelClass):
              text "No initiative is running."
        r.appendRendered(bar, notice)
      # One line: the tabs that fit, the active one always among them, and
      # the rest behind a +N chip (the session strip's rule).
      let line = vm.singleLine
      for i in line.visible:
        if tabs[i].kind == stkInitiative:
          r.appendRendered(bar, renderInitiativeTab(r, vm, tabs[i]))
        else:
          r.appendRendered(bar, renderSessionTab(r, vm, tabs[i]))
      if line.overflow.len > 0:
        let target = vm
        # A hidden tab that needs the reader marks the chip, as in the
        # session strip.
        var hiddenWaits = 0
        for i in line.overflow:
          if tabs[i].kind == stkInitiative and tabs[i].state == isNeedsInput or
              tabs[i].kind == stkSession and tabs[i].session.attention == saNeedsInput:
            inc hiddenWaits
        let chip = ui(r):
          tdiv(class = SessionTabOverflowClass & " ah-tab-overflow-count" &
                       (if hiddenWaits > 0: " ah-att-needs-input" else: ""),
               title = $line.overflow.len & " more tabs" &
                       (if hiddenWaits > 0: ", " & $hiddenWaits & " needing input" else: ""),
               onclick = proc() = target.overflowOpen.val = not target.overflowOpen.val):
            text "+" & $line.overflow.len
        r.appendRendered(bar, chip)
        if vm.overflowOpen.val:
          var menu: N
          let menuNode = ui(r):
            tdiv(ref = menu, class = SessionTabOverflowMenuClass & " ah-overflow-menu")
          for i in line.overflow:
            r.appendRendered(menu, renderOverflowTab(r, vm, tabs[i]))
          r.appendRendered(bar, menuNode)
      let fullLabel = vm.elsewhereLabel
      # A compact bar names the count only; the tooltip says the rest.
      let label = if vm.compact and fullLabel.len > 0: "[" & $vm.elsewhere.len & "]" else: fullLabel
      if label.len > 0:
        let target = vm
        var item, anchor: N
        # The chip and its menu share an anchor, so the menu drops from the
        # chip; the anchor starts the bar's right-hand group.
        let anchorNode = ui(r):
          tdiv(ref = anchor, class = "ah-elsewhere-anchor")
        let itemNode = ui(r):
          tdiv(ref = item, class = "ah-elsewhere" &
                                   (if vm.elsewhereOpen.val: " ah-elsewhere-open" else: ""),
               role = "button", tabindex = "0",
               title = fullLabel & ": sessions started elsewhere; choose one to open it as a tab",
               onclick = proc() = target.elsewhereOpen.val = not target.elsewhereOpen.val):
            text label
        r.appendRendered(anchor, itemNode)
        if vm.elsewhereOpen.val:
          var menu: N
          let menuNode = ui(r):
            tdiv(ref = menu, class = SessionTabOverflowMenuClass & " ah-elsewhere-menu")
          for entry in vm.elsewhere:
            r.appendRendered(menu, renderElsewhereItem(r, vm, entry))
          r.appendRendered(anchor, menuNode)
        r.appendRendered(controls, anchorNode)
    # Previous / Next and auto-switch at the right, beside the sessions
    # started elsewhere, so the initiative tabs start at the left edge as
    # CodeTracer's tabs do.
    if vm.state.val in {asReady, asError}:
      r.appendRendered(controls, renderInbox(r, vm))
    let add = ui(r):
      button(class = "ct-button-image-sm-secondary ct-button-no-border session-tab-add",
             title = SessionTabAddTitle):
        discard
    r.appendRendered(controls, add)
    r.appendRendered(bar, controlsNode)
    let overflowing = vm.state.val == asReady and vm.singleLine.overflow.len > 0
    r.setAttribute(bar, "class", InitiativeTabBarClass &
      (if overflowing: " has-overflow" else: "") &
      (if vm.compact: " ah-bar-compact" else: "") &
      (if vm.stacked: " ah-bar-stacked" else: "") &
      # Each menu marks the bar with its own class, so opening one does not
      # draw the other's chip as pressed.
      (if vm.overflowOpen.val: " overflow-open" else: "") &
      (if vm.elsewhereOpen.val: " ah-elsewhere-open-bar" else: "") &
      (if vm.popupId.val.len > 0: " ah-popup-open" else: ""))
  host

when defined(js):
  proc measureWidth(el: isonim_dom.Element): int {.importjs: "(#.getBoundingClientRect().width | 0)".}
  proc onResize(cb: proc()) {.importjs: "window.addEventListener('resize', #)".}

  proc mountAgentHarborInitiativeTabBar*(container: isonim_dom.Element;
                                         vm: InitiativeTabStripVM) =
    ## Mounts the bar into `container` (the caption bar) and keeps the
    ## viewmodel told how wide it is, so one line knows what fits.
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborInitiativeTabBar[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    let measure = proc() =
      let width = measureWidth(container)
      if width > 0 and width != vm.stripWidth.val: vm.stripWidth.val = width
    measure()
    onResize(measure)
