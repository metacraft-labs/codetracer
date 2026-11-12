## IsoNim view of CodeTracer's tab bar with Agent Harbor initiatives as tabs,
## over `InitiativeTabStripVM` (nim-agents-isonim-viewmodels, the sessions
## family's initiative-tab-bar variant).
##
## Built from CodeTracer's own session tab strip (`session_tabs.styl`), in the
## caption bar, left to right:
##
## - one tab per active initiative: its state mark (needs input, working,
##   blocked, idle, ended), its name and `n/m` milestones; the active one
##   carries the recording switcher's numbered buttons for the replays loaded
##   for it (`isonim_recording_switcher_view.nim`); hovering one shows its
##   progress popup (executive summary, milestones by status, current
##   milestone, its sessions);
## - a tab per open session launched for no initiative;
## - the `+N` overflow chip, its menu hanging from it (`hangOverflowMenu`),
##   and "+" right after the last tab;
## - at the bar's end, as ghost controls (no fill until hovered): the
##   sessions started elsewhere, a count badge and `agent harbor sessions`
##   (on a compact bar the badge alone, its label in the tooltip), a menu
##   listing each with its initiative and state, from which one is brought
##   into view; then Previous / Next session (`← 2 of 5 →`) and the
##   auto-switch toggle, which walk the sessions waiting for the operator.
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
      # Its initiative beside its state: where it opens (inside that
      # initiative's tab, or as a tab of its own).
      span(class = "ah-elsewhere-initiative" &
                   (if entry.initiativeTitle.len == 0: " ah-elsewhere-no-initiative" else: ""),
           title = (if entry.initiativeTitle.len > 0: "initiative: " & entry.initiativeTitle
                    else: "launched for no initiative")):
        text (if entry.initiativeTitle.len > 0: entry.initiativeTitle else: "no initiative")
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

proc renderElsewhere[R, N](r: R; vm: InitiativeTabStripVM; anchor: N) =
  ## The sessions started elsewhere: a count badge and its label (a compact
  ## bar keeps the badge and moves the label into the tooltip), and the
  ## menu that drops from it.
  mixin setAttribute
  let target = vm
  let compact = vm.compact
  let tooltip = vm.elsewhereTooltip
  var item: N
  let itemNode = ui(r):
    tdiv(ref = item, class = "ah-elsewhere" &
                             (if vm.elsewhereOpen.val: " ah-elsewhere-open" else: "") &
                             (if compact: " ah-elsewhere-compact" else: ""),
         role = "button", tabindex = "0", title = tooltip,
         onclick = proc() = target.elsewhereOpen.val = not target.elsewhereOpen.val):
      span(class = "ah-elsewhere-count"):
        text $vm.elsewhereCount
      if not compact:
        span(class = "ah-elsewhere-label"):
          text vm.elsewhereLabel
  r.setAttribute(item, "aria-label", tooltip)
  r.appendRendered(anchor, itemNode)
  if vm.elsewhereOpen.val:
    var menu: N
    let menuNode = ui(r):
      tdiv(ref = menu, class = SessionTabOverflowMenuClass & " ah-elsewhere-menu")
    for entry in vm.elsewhere:
      r.appendRendered(menu, renderElsewhereItem(r, vm, entry))
    r.appendRendered(anchor, menuNode)

when defined(js):
  proc hangOverflowMenu(within: isonim_dom.Element) {.importjs: """
    (function(el) {
      var bar = el.classList.contains('ah-initiative-tab-bar') ? el
                : el.querySelector('.ah-initiative-tab-bar');
      if (!bar || !bar.isConnected) return;
      var chip = bar.querySelector(':scope > .ah-tab-overflow-count');
      var menu = bar.querySelector(':scope > .ah-overflow-menu');
      if (!chip || !menu) return;
      menu.style.left = menu.style.right = menu.style.width = '';
      var w = menu.getBoundingClientRect().width;
      if (w === 0) return;
      var view = document.documentElement.clientWidth;
      var left = Math.max(0, Math.min(chip.getBoundingClientRect().right - w, view - w));
      var b = bar.getBoundingClientRect();
      menu.style.right = 'auto';
      menu.style.width = w + 'px';
      menu.style.left = (left - b.left - bar.clientLeft) + 'px';
    })(#)""".}
    ## The `+N` menu hangs from its chip: its right edge on the chip's
    ## right edge, shifted only as far as it must be to stay inside the
    ## window on either side. The menu is the strip's
    ## `session-tab-overflow-menu`, placed in the bar (its containing block,
    ## so its height under the caption bar is the strip's), whose rule
    ## right-aligns it under the bar's end; where the chip is cannot be
    ## said in CSS, so it is measured. The width is measured where the
    ## stylesheet puts it and kept, so moving the menu never rewraps it.
    ## Nothing happens until the bar is in the document with the menu
    ## open: the mount places it again once it is (and when the window's
    ## size or its fonts move the chip).

proc renderAgentHarborInitiativeTabBar*[R, N](r: R; vm: InitiativeTabStripVM): N =
  mixin clearChildren, setAttribute
  var bar, controls: N
  let host = ui(r):
    tdiv(class = "ah-tab-strip-host"):
      tdiv(ref = bar, id = SessionTabBarId, class = InitiativeTabBarClass)
  createRenderEffect proc() =
    r.clearChildren(bar)
    # Left to right, as CodeTracer's own strip: the tabs, the overflow chip
    # and "+" right after the last tab; then, at the bar's end, the
    # right-hand group -- the sessions started elsewhere and Previous/Next
    # with auto-switch -- as ghost controls, one unit that never shrinks. A
    # stacked bar puts the group on a line of its own.
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
      if vm.elsewhereCount > 0:
        # The badge and its menu share an anchor, so the menu drops from the
        # badge; the anchor starts the right-hand group.
        var anchor: N
        let anchorNode = ui(r):
          tdiv(ref = anchor, class = "ah-elsewhere-anchor")
        renderElsewhere(r, vm, anchor)
        r.appendRendered(controls, anchorNode)
    # "+" directly after the last tab (or the notice), as in CodeTracer's
    # strip.
    let add = ui(r):
      button(class = "ct-button-image-sm-secondary ct-button-no-border session-tab-add",
             title = SessionTabAddTitle):
        discard
    r.appendRendered(bar, add)
    # Previous / Next and auto-switch at the right, beside the sessions
    # started elsewhere, so the initiative tabs start at the left edge as
    # CodeTracer's tabs do.
    if vm.state.val in {asReady, asError}:
      r.appendRendered(controls, renderInbox(r, vm))
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
    # Open, the menu is drawn only now (the bar's `overflow-open`), so it is
    # placed only now.
    when defined(js):
      when N is isonim_dom.Element:
        if vm.overflowOpen.val: hangOverflowMenu(bar)
  host

when defined(js):
  proc measureWidth(el: isonim_dom.Element): int {.importjs: "(#.getBoundingClientRect().width | 0)".}
  proc onResize(cb: proc()) {.importjs: "window.addEventListener('resize', #)".}
  proc onFontsLoaded(cb: proc()) {.importjs: """
    (function(cb) {
      if (!document.fonts) return;
      document.fonts.ready.then(cb);
      document.fonts.addEventListener('loadingdone', cb);
    })(#)""".}
    ## A face that arrives after the bar is drawn changes the tabs' widths,
    ## and with them where the `+N` chip is.

  proc mountAgentHarborInitiativeTabBar*(container: isonim_dom.Element;
                                         vm: InitiativeTabStripVM) =
    ## Mounts the bar into `container` (the caption bar) and keeps the
    ## viewmodel told how wide it is, so one line knows what fits.
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborInitiativeTabBar[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
    let measure = proc() =
      let width = measureWidth(container)
      if width > 0 and width != vm.stripWidth.val: vm.stripWidth.val = width
      hangOverflowMenu(container)
    measure()
    onResize(measure)
    onFontsLoaded(proc() = hangOverflowMenu(container))
