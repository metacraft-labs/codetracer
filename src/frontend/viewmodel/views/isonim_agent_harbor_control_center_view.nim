## IsoNim view of the control center, over `ControlCenterVM`
## (nim-agents-isonim-viewmodels): the tab titled `Control Center` that fills
## the window, as the Welcome Page does, to launch tasks and initiatives and
## to show every initiative with the sessions waiting for the operator. GPUI
## (`gpui/agent_harbor/ah_control_center.nim`) and the terminal
## (`tui/agent_harbor/ah_tui_control_center.nim`) draw the same viewmodel;
## what the three decide alike is in `agent_harbor_control_center_words`.
##
## Two columns (`agent_harbor_control_center.styl`), one below 720px,
## launching first:
##
## - **Launch**: `LAUNCH`; the mode toggles `New task` / `New initiative`;
##   `For`: no initiative or one of them; the instruction's field; the
##   composer's own launch or initiative form (`renderLaunchForm`,
##   `renderInitiativeForm`, the composer view's, so the two never differ)
##   and its send line; Agent Harbor's answer to the last launch; `RECENT
##   LAUNCHES`.
## - **Overview**: the Initiatives panel, the same view every other host of
##   it draws (`renderAgentHarborInitiativesPanel`, unchanged; with an empty
##   fleet, `No initiatives yet.` in its place), and `WAITING FOR YOU`: one
##   row per waiting session, in inbox order -- its title, its state word in
##   its role, its initiative and how long it has waited, and why it waits.
##   A row draws no dot and no pie of its own; its pie's words are its
##   accessible name (`aria-label`).
##
## Presses and keys are routed (Input-Routing-And-Keymaps.md §5.1, the
## `input-routing-gate`): the root is the `controlCenter` scope and the
## launch column the `composer` scope inside it; each element a press acts
## on carries its operation (`data-ct-operation`) and its target
## (`data-ah-target`). The view keeps one listener, the instruction field's
## text input (the operator's typing, not a press).

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/ui
import ./ah_cut_text
from ../keymap/scope_path import ControlCenterScope, ComposerScope
from ../input/element_press import OperationAttribute

import ./agent_harbor_control_center_words
import ./isonim_agent_harbor_composer_view
import ./isonim_agent_harbor_initiatives_view

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

  proc setInputValue(node: isonim_dom.Node; value: cstring) {.importjs: "#.value = #".}
  proc inputValueOf(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc widthOfNode(node: isonim_dom.Node): int {.importjs: "(#.getBoundingClientRect().width | 0)".}
  proc observeWidth(node: isonim_dom.Node; cb: proc()) {.importjs: """
    (function (n, cb) {
      if (typeof ResizeObserver !== 'undefined') new ResizeObserver(function () { cb(); }).observe(n);
    })(#, #)""".}

export agent_harbor_control_center_words

static:
  doAssert OperationAttribute == "data-ct-operation"
  doAssert ComposerTargetAttribute == "data-ah-target"

const
  AgentHarborControlCenterClass* = "ah-control-center"
  HeadBandStrut = "\xE2\x80\x8B"
    ## A zero-width space in the head band's source slot, where the
    ## Initiatives panel's band has its source: the slot sets the band's line
    ## box (its `overflow: hidden` puts its baseline at its foot), so every
    ## band of the tab is the panel's height and the heads line up.

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc tagFacts[R, N](r: R; node: N; facts: openArray[(string, string)]) =
  mixin setAttribute
  for (k, v) in facts: r.setAttribute(node, "data-ah-" & k, v)

proc sectionLabel[R](r: R; words: string): auto =
  ui(r):
    tdiv(class = "ah-composer-section-label ah-cc-section-label"):
      text words

proc toggle[R](r: R; label, operation, target: string; on: bool): auto =
  ## One of a row of toggles, the composer form's own (`ah-composer-toggle`),
  ## carrying its operation.
  ui(r):
    button(class = "ah-composer-toggle" & (if on: " active" else: ""),
           `aria-pressed` = (if on: "true" else: "false"),
           `data-ct-operation` = operation, `data-ah-target` = target):
      text label

proc renderWaitingRow[R, N](r: R; row: WaitingRow; focused: bool): N =
  ## A waiting session: its title, then its state word (its role), its
  ## initiative and age, then why it waits.
  let role = stateRole(row.item.attention)
  let why = row.waitingWhy
  result = ui(r):
    tdiv(class = "ah-cc-waiting-row" & (if focused: " ah-cc-waiting-focused" else: ""),
         role = "option", `aria-selected` = (if focused: "true" else: "false"),
         `aria-label` = row.item.title & ", " & row.words,
         title = row.words,
         `data-ct-operation` = ControlCenterOpenSessionOperation,
         `data-ah-target` = row.item.id):
      tdiv(`data-ah-cut` = "line", class = "ah-cc-waiting-title"):
        text row.item.title
      tdiv(class = "ah-cc-waiting-meta"):
        span(class = "ah-cc-waiting-state ah-role-" & role):
          text row.stateWordOf
        span(`data-ah-cut` = "line", class = "ah-cc-waiting-where"):
          text row.waitingMeta
      if why.len > 0:
        tdiv(class = "ah-cc-waiting-why"):
          text why
  r.tagFacts(result, row.waitingFacts(focused))

proc renderAgentHarborControlCenter*[R, N](r: R; vm: ControlCenterVM;
                                           widthOf: proc(): int = nil): N =
  ## The control center for every renderer. `widthOf` answers the width it
  ## is laid out at (its two-column rule); nil: two columns.
  mixin clearChildren, setAttribute
  var launch, modes, forRow, field, form, send, notice, recent, overview,
      initiativesHost, emptyHost, waiting: N
  let root = ui(r):
    tdiv(class = AgentHarborControlCenterClass, `data-ct-pane` = ControlCenterScope,
         role = "region", `aria-label` = ControlCenterTitle):
      tdiv(class = "ah-cc-launch", `data-ct-pane` = ComposerScope):
        # The head band every panel of the tab has (the Initiatives panel's
        # own, `.ah-fleet-section-header`), so the columns' heads line up.
        tdiv(class = "ah-fleet-head"):
          tdiv(class = "ah-fleet-section-header"):
            span(class = "ah-fleet-title"):
              text LaunchHeading
            span(class = "ah-fleet-source"):
              text HeadBandStrut
        tdiv(ref = launch, class = "ah-cc-launch-body")
  let launchBody = ui(r):
    tdiv(class = "ah-cc-launch-parts"):
        tdiv(ref = modes, class = "ah-composer-toggles ah-cc-modes", role = "radiogroup",
             `aria-label` = "What to start")
        tdiv(ref = forRow, class = "ah-composer-field ah-composer-field-wide ah-cc-for")
        tdiv(class = "ah-composer-field ah-composer-field-wide ah-cc-instruction"):
          span(class = "ah-composer-field-label"):
            text InstructionLabel
          input(ref = field, class = "ah-cc-input ah-composer-field-value",
                `aria-label` = "Instruction", spellcheck = "false")
        tdiv(ref = form, class = "ah-composer-form-grid ah-cc-form")
        tdiv(ref = send, class = "ah-cc-send")
        tdiv(ref = notice, class = "ah-cc-notice")
        tdiv(ref = recent, class = "ah-cc-recent")
  r.appendRendered(launch, launchBody)
  # The overview: what waits for the operator first, as tall as its rows
  # (at most 45%), then every initiative, the panel filling the rest
  # (study D73).
  let overviewNode = ui(r):
    tdiv(ref = overview, class = "ah-cc-overview"):
      tdiv(ref = waiting, class = "ah-cc-waiting", role = "listbox",
           `aria-label` = WaitingHeading)
      tdiv(ref = initiativesHost, class = "ah-cc-initiatives")
      tdiv(ref = emptyHost, class = "ah-cc-empty")
  r.appendRendered(root, overviewNode)
  # The Initiatives panel, drawn once: it redraws itself as its viewmodel
  # moves.
  r.appendRendered(initiativesHost,
    renderAgentHarborInitiativesPanel[R, N](r, vm.initiatives))
  when defined(js):
    when N is isonim_dom.Element:
      let target = vm
      isonim_dom.addEventListener(isonim_dom.Node(field), cstring"input",
        proc(ev: isonim_dom.Event) =
          target.composer.setText($inputValueOf(isonim_dom.Node(field))))
  let width = createSignal(if widthOf.isNil: 1440 else: widthOf())
  when defined(js):
    when N is isonim_dom.Element:
      if widthOf != nil:
        observeWidth(isonim_dom.Node(root), proc() = width.val = widthOf())
  createRenderEffect proc() =
    # The facts and the columns.
    discard vm.revision.val
    discard vm.composer.revision.val
    discard vm.launchFor.val
    discard vm.focused.val
    let w = width.val
    for (k, v) in vm.centerFacts(w): r.setAttribute(root, "data-ah-" & k, v)
    r.setAttribute(root, "data-ah-columns", $vm.layoutFor(w))
  createRenderEffect proc() =
    # The mode and what the launch is for.
    discard vm.composer.revision.val
    discard vm.launchFor.val
    r.clearChildren(modes)
    for (_, label, operation, on) in vm.modeChoices:
      r.appendRendered(modes, toggle(r, label, operation, "", on))
    r.clearChildren(forRow)
    let forLabel = ui(r):
      span(class = "ah-composer-field-label"):
        text ForLabel
    r.appendRendered(forRow, forLabel)
    var toggles: N
    let togglesNode = ui(r):
      tdiv(ref = toggles, class = "ah-composer-toggles", role = "radiogroup",
           `aria-label` = ForLabel)
    r.appendRendered(forRow, togglesNode)
    for choice in vm.launchChoices:
      r.appendRendered(toggles, toggle(r, choice.title, ControlCenterLaunchForOperation,
                                       choice.id, choice.chosen))
  createRenderEffect proc() =
    # The field, the form, the send line and the notice.
    discard vm.composer.revision.val
    discard vm.composer.scheduleOpen.val
    let c = vm.composer
    let whole = c.text
    when defined(js):
      when N is isonim_dom.Element:
        if $inputValueOf(isonim_dom.Node(field)) != whole:
          setInputValue(isonim_dom.Node(field), cstring(whole))
    r.setAttribute(field, "value", whole)
    r.setAttribute(field, "placeholder", vm.instructionPlaceholder)
    r.clearChildren(form)
    r.clearChildren(send)
    r.clearChildren(notice)
    r.setAttribute(form, "data-ah-form", $c.intent)
    if c.showsForm:
      if c.intent == riLaunchTask: renderLaunchForm(r, c, form)
      else: renderInitiativeForm(r, c, form)
    if c.showsSendLine:
      let sending = c.phase == cpSending
      let canSend = c.canSend and not sending
      let (hint, more, blocked) = c.sendHint
      var button: N
      let line = ui(r):
        tdiv(class = "ah-composer-send" & (if blocked: " ah-composer-send-blocked" else: "")):
          span(`data-ah-cut` = "line", class = "ah-composer-send-hint"):
            text hint
          span(class = "ah-composer-send-more"):
            text more
          button(ref = button, class = "ah-composer-send-button",
                 `data-ct-operation` = ComposerSendOperation,
                 title = launchForLabel(vm.launchForTitle)):
            text c.sendLabel
      if not canSend: r.setAttribute(button, "disabled", "true")
      r.appendRendered(send, line)
    let (words, failed, pending) = vm.launchNotice
    if words.len > 0:
      let n = ui(r):
        tdiv(class = "ah-cc-notice-line" & (if failed: " ah-role-error"
                                            elif pending: " ah-role-caption" else: ""),
             role = "status"):
          text words
      r.appendRendered(notice, n)
  createRenderEffect proc() =
    # Recent launches.
    discard vm.composer.revision.val
    r.clearChildren(recent)
    r.appendRendered(recent, sectionLabel(r, RecentLaunchesLabel))
    let launches = vm.recent
    if launches.len == 0:
      let none = ui(r):
        tdiv(class = "ah-cc-none"):
          text NoRecentLaunchesWords
      r.appendRendered(recent, none)
    for each in launches:
      let launch = each
      let row = ui(r):
        tdiv(class = "ah-cc-recent-row" & (if launch.failed: " ah-cc-recent-failed" else: "")):
          span(`data-ah-cut` = "line", class = "ah-cc-recent-text"):
            text launch.text
          span(`data-ah-cut` = "line", class = "ah-cc-recent-line"):
            text recentLine(launch)
      r.tagFacts(row, launch.recentFacts)
      r.appendRendered(recent, row)
  createRenderEffect proc() =
    # The waiting sessions, and the empty fleet's line in the panel's place.
    discard vm.revision.val
    let focused = vm.focused.val
    let state = vm.state
    r.clearChildren(waiting)
    r.clearChildren(emptyHost)
    if vm.isEmptyFleet:
      # The panel's place keeps a panel's head band, as every column of the
      # tab: the Initiatives panel's title and source, then the line.
      let none = ui(r):
        tdiv(class = "ah-cc-empty-panel"):
          tdiv(class = "ah-fleet-head"):
            tdiv(class = "ah-fleet-section-header"):
              span(class = "ah-fleet-title"):
                text "Initiatives"
              span(class = "ah-fleet-source"):
                text vm.initiatives.sourceLabel
          tdiv(class = "ah-cc-empty-line"):
            text NoInitiativesWords
      r.appendRendered(emptyHost, none)
    if state != asReady: return
    let rows = vm.waiting
    var list: N
    let head = ui(r):
      tdiv(class = "ah-fleet-head"):
        tdiv(class = "ah-fleet-section-header"):
          span(class = "ah-fleet-title"):
            text WaitingHeading
          span(class = "ah-fleet-source"):
            text HeadBandStrut
          span(class = "ah-cc-waiting-count"):
            text waitingCountText(rows.len)
    let body = ui(r):
      tdiv(ref = list, class = "ah-cc-waiting-rows")
    r.appendRendered(waiting, head)
    r.appendRendered(waiting, body)
    if rows.len == 0:
      let none = ui(r):
        tdiv(class = "ah-cc-none"):
          text NothingWaitingWords
      r.appendRendered(list, none)
    for row in rows:
      r.appendRendered(list, renderWaitingRow[R, N](r, row, row.item.id == focused))
  root

when defined(js):
  proc mountAgentHarborControlCenter*(container: isonim_dom.Element; vm: ControlCenterVM) =
    var node: isonim_dom.Element
    node = renderAgentHarborControlCenter[WebRenderer, isonim_dom.Element](WebRenderer(), vm,
      proc(): int = (if node.isNil: 1440 else: widthOfNode(isonim_dom.Node(node))))
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(node))
