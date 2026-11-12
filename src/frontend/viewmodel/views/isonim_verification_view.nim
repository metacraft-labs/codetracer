## VN-M3 — the text-fallback verification panel.
##
## `SMT-Counterexample-And-Prover-State-Visualization.md` defines exactly what
## this tier may claim, in its own test name: `SolverViz.TextFallback` — "a
## producer without structured model data still shows the textual diagnostic
## **without claiming trace replay support**."
##
## So this view is deliberately, visibly poorer than the panes around it.
## There is no trace link, no model-value table, no proof-goal tree, and no
## disabled control hinting that one is coming. The whole vocabulary of replay
## is absent from the markup — not greyed out, absent — because a disabled
## affordance is still a promise, and VN-M3 is the milestone that promises
## nothing about replay. VN-M4 earns the payload and VN-M5 earns the
## affordance.
##
## **VN-M5 added exactly one thing, and it is data-gated.** A "Step through the
## counterexample" button is rendered per entry of
## `VerificationPanelModel.counterexampleOffers`, and that sequence is empty
## unless a payload was *attached* and carries a counterexample with steps and
## a model that is not `unavailable`. Every state the text tier can reach — no
## payload, a refused payload, a payload whose model is absent — still renders
## the markup the paragraph above describes, which is why
## `test_the_text_tier_never_offers_replay` passes unchanged. The suite pairs
## that negative with a positive over the same code path: the same renderer,
## over a payload that opens the gate, *does* produce the button. A "must not
## contain" check whose scanner cannot see is green forever
## (`Testing/Verification-Harness-Traps.md`, trap 4a).
##
## Two things the markup does insist on:
##
## * **every row states its kind in words** (`data-ct-verification-kind` and a
##   visible `kindLabel`), so a limitation cannot be mistaken for a failed
##   obligation by anyone reading the rendered page — including a test;
## * **a run in flight renders**, with its elapsed time and last output line,
##   so a long proof attempt is visibly working rather than visibly stuck.
##
## One generic tree for every renderer (Shared-DOM-Front-Ends D6), so the
## headless Mock tree and the browser DOM are the same tree.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  # The browser instantiation needs the WebRenderer procs in scope.
  import isonim/web/web_renderer

import ../viewmodels/verification_report
import ../viewmodels/verification_payload
import ../viewmodels/verification_vm
import ../viewmodels/counterexample_session_vm
import ./isonim_counterexample_view

export signals, computation, components

type
  VerificationPanelHandlers* = object
    ## What the panel's controls do when clicked. Same arrangement, and
    ## same reason, as `CounterexampleHandlers`: one tree, two entry points.
    onOpenCounterexample*: proc(findingId: string)
    onActivate*: proc(key: string)
      ## PLAT-63: a press on a finding or an offer (`activateLine`).
    onRun*: proc()
    onStop*: proc()

proc openHandler(handlers: VerificationPanelHandlers;
                 findingId: string): proc() =
  ## Nil-safe, so the pure model-based render is a legal tree with no session
  ## behind it.
  let f = handlers.onOpenCounterexample
  let id = findingId
  result = proc() =
    if not f.isNil:
      f(id)

# A finding's press is the pointer row `verification.go-to-source`, performed
# by the front-end on the row's `data-ct-verification-key` (on the desktop
# `ui/verification.nim`'s procedure, by `VerificationPanelHandlers.onActivate`).

proc plainHandler(f: proc()): proc() =
  result = proc() =
    if not f.isNil:
      f()

var verificationSourceOpener*: proc(activation: VerificationActivation;
                                    candidates: seq[string])
  ## PLAT-63: how the HOST goes to a finding's source (the desktop's
  ## `ui/verification.nim` installs `openLocation`). Nil in a headless render,
  ## where a press still selects and opens counterexamples.

var verificationRunRequest*: proc()
  ## How the HOST runs the project's declared Verno action when the pane's
  ## Run is pressed (the desktop's `ui/verification.nim` installs it; the
  ## native front-ends draw their own pane and call their host directly).
  ## Nil in a headless render, where Run does nothing.
var verificationStopRequest*: proc()
  ## How the HOST stops the run in flight (Stop). Nil in a headless render.

proc verificationHandlersFor*(vm: VerificationVM;
                              session: CounterexampleSessionVM):
                              VerificationPanelHandlers =
  ## The live wiring for deliverable 1: one click, from the failed obligation
  ## to a session on the first step of its counterexample; and PLAT-63's
  ## press on a finding, to its source.
  VerificationPanelHandlers(
    onOpenCounterexample: proc(findingId: string) =
      discard vm.openCounterexample(session, findingId),
    onActivate: proc(key: string) =
      let done = vm.activateLine(session, key)
      if done.kind == vakSource and not verificationSourceOpener.isNil:
        verificationSourceOpener(done, vm.sourceCandidates(done.file)),
    onRun: proc() =
      if not verificationRunRequest.isNil:
        verificationRunRequest(),
    onStop: proc() =
      if not verificationStopRequest.isNil:
        verificationStopRequest())

when defined(js):
  import isonim/web/dom_api as isonim_dom
  import kdom
  from ./context_menu_bridge import showContextMenu
  from ../../context_menu_item import ContextMenuItem
  proc preventMenuDefault(ev: isonim_dom.Event) {.importjs: "#.preventDefault()".}
  proc stopMenuPropagation(ev: isonim_dom.Event) {.importjs: "#.stopPropagation()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importjs: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importjs: "(#.clientY || 0)".}
  proc writeClipboard(text: cstring) {.importjs: """
    (function(t){ try { navigator.clipboard.writeText(t); } catch (e) {} })(#)""".}

  var liveVerificationVM: VerificationVM
  var liveCounterexampleVM: CounterexampleSessionVM
    ## The pair the mounted pane draws, for the row menu's handlers.

  proc rowMenuHandler(key: string;
                      action: VerificationMenuAction): proc(ev: kdom.Event) =
    ## A row menu's entry, done by the ViewModel (`runRowMenu`).
    result = proc(ev: kdom.Event) =
      let vm = liveVerificationVM
      let session = liveCounterexampleVM
      if vm.isNil:
        return
      let outcome = vm.runRowMenu(session, key, action)
      if outcome.copied.len > 0:
        writeClipboard(cstring(outcome.copied))
      if outcome.activation.kind == vakSource and
         not verificationSourceOpener.isNil:
        verificationSourceOpener(outcome.activation,
          vm.sourceCandidates(outcome.activation.file))

  proc wireRowMenu(row: isonim_dom.Element; key: string) =
    ## A right press selects the line and opens its menu: the ViewModel's
    ## entries (`VerificationVM.rowMenu`), the terminal's and GPUI's too.
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"contextmenu",
      proc(ev: isonim_dom.Event) =
        ev.preventMenuDefault()
        ev.stopMenuPropagation()
        let vm = liveVerificationVM
        if vm.isNil:
          return
        vm.selectLine(key)
        var items: seq[ContextMenuItem] = @[]
        for e in vm.rowMenu(liveCounterexampleVM, key):
          items.add ContextMenuItem(name: cstring(e.label), hint: cstring"",
            disabled: not e.enabled, disabledReason: cstring(e.reason),
            handler: rowMenuHandler(key, e.action))
        showContextMenu(items, ev.eventClientX(), ev.eventClientY()))

proc noModelNote(model: VerificationPanelModel): string =
  ## The sentence shown when a payload arrived, was believed, and carries no
  ## model to walk (`verification_vm.noModelNoteText`, every front-end's).
  noModelNoteText(model)

proc correctnessNote(model: VerificationPanelModel): string =
  ## The sentence that keeps four of the six outcomes from reading as a
  ## verdict on the program (`verification_vm.correctnessNoteText`).
  correctnessNoteText(model)

proc rowClass(row: VerificationPanelRow; selected: bool): string =
  result = "ct-verification-row ct-verification-row-" & $row.kind
  if selected:
    result.add " ct-verification-row-selected"

proc renderVerificationPanelTree[R, N](r: R; mdl: VerificationPanelModel;
                                      hnd: VerificationPanelHandlers): N =
  ## PLAT-63: the findings are drawn BY KIND (`mdl.groups`, in
  ## `FindingGroupOrder`), each group under its heading, as the terminal's
  ## pane and the GPUI leaf draw `mdl.lines`; a press on a row is
  ## `activateLine` (its source, or why none), its right press the shared
  ## row menu.
  mixin appendChild
  var findings: N
  result = ui(r):
    tdiv(class = "ct-verification-panel",
         `data-ct-verification` = "true",
         `data-ct-verification-phase` = $mdl.phase,
         `data-ct-verification-running` = $mdl.running,
         `data-ct-verification-outcome` = mdl.outcomeText,
         `data-ct-verification-tier` = "text-fallback",
         `data-ct-verification-payload` = $mdl.payloadStatus,
         `data-ct-verification-answers-correctness` = $mdl.answersCorrectness):
      tdiv(class = "ct-verification-status",
           `data-ct-verification-status` = "true",
           `data-ct-verification-elapsed` = mdl.elapsed):
        text mdl.statusText
      tdiv(class = "ct-verification-command",
           `data-ct-verification-command` = "true",
           title = mdl.commandLine):
        text mdl.commandLine
      # PLAT-63: a host that runs the project's verifier offers it here; one
      # that runs nothing (a browser tab, a headless render) draws none.
      if mdl.canRun:
        button(class = "ct-verification-run",
               `data-ct-verification-action` = "run",
               onclick = plainHandler(hnd.onRun),
               `aria-label` = "Run " & mdl.runLabel):
          text mdl.runLabel
      if mdl.cancellable:
        button(class = "ct-verification-cancel",
               `data-ct-verification-action` = "cancel",
               onclick = plainHandler(hnd.onStop),
               `aria-label` = "Stop this verification run"):
          text "Stop"
      if correctnessNote(mdl).len > 0:
        tdiv(class = "ct-verification-correctness-note",
             `data-ct-verification-note` = "no-verdict"):
          text correctnessNote(mdl)
      # The case that is wrong if anything is: a payload arrived, was believed,
      # and carries no mdl. There is no button — and there is a *sentence*,
      # in the producer's own words, saying why. An absent affordance with no
      # explanation reads as a missing feature; this reads as what it is.
      if noModelNote(mdl).len > 0:
        tdiv(class = "ct-verification-no-model",
             `data-ct-verification-no-model` = "true"):
          text noModelNote(mdl)
      # VN-M5 deliverable 1. Rendered only when the payload carries a
      # counterexample with values to walk; `counterexampleOffers` is empty in
      # every state VN-M3's tier can reach, so the paragraph above about this
      # view promising nothing still describes it whenever there is nothing to
      # promise. There is no disabled variant of this control on purpose.
      if mdl.counterexampleOffers.len > 0:
        tdiv(class = "ct-verification-counterexamples",
             `data-ct-verification-counterexamples` = $mdl.counterexampleOffers.len):
          for offerIndex in 0 ..< mdl.counterexampleOffers.len:
            let offer = mdl.counterexampleOffers[offerIndex]
            button(class = "ct-verification-open-counterexample",
                   `data-ct-verification-action` = "open-counterexample",
                   `data-ct-verification-finding` = offer.findingId,
                   `data-ct-verification-counterexample-steps` = $offer.stepCount,
                   `data-ct-verification-counterexample-model` = offer.modelStatusLabel,
                   `data-ct-verification-counterexample-location` = offer.location,
                   `data-ct-verification-key` = offerKey(offer.findingId),
                   onclick = openHandler(hnd, offer.findingId),
                   `aria-label` = "Step through the counterexample for this " &
                     offer.kindLabel):
              text OpenCounterexampleLabel
      tdiv(ref = findings, class = "ct-verification-findings",
           `data-ct-verification-findings` = $mdl.rows.len):
        for groupIndex in 0 ..< mdl.groups.len:
          let group = mdl.groups[groupIndex]
          tdiv(class = "ct-verification-group ct-verification-group-" & $group.kind,
               `data-ct-verification-group` = $group.kind,
               `data-ct-verification-group-count` = $group.rows.len):
            tdiv(class = "ct-verification-group-heading",
                 `data-ct-verification-group-heading` = "true"):
              text group.heading
            for member in 0 ..< group.rows.len:
              let rowIndex = group.rows[member]
              let row = mdl.rows[rowIndex]
              let key = findingKey(rowIndex)
              tdiv(class = rowClass(row, key == mdl.selectedKey),
                   `data-ct-verification-row` = "true",
                   `data-ct-verification-key` = key,
                   `data-ct-verification-selected` = $(key == mdl.selectedKey),
                   `data-ct-verification-kind` = $row.kind,
                   `data-ct-verification-is-failure` = $row.isFailure,
                   `data-ct-verification-location` = row.location,
                   `data-ct-verification-target` = "finding"):
                span(class = "ct-verification-row-kind"):
                  text row.kindLabel
                span(class = "ct-verification-row-title"):
                  text row.title
                span(class = "ct-verification-row-message"):
                  text row.message
                if row.detail.len > 0:
                  span(class = "ct-verification-row-detail"):
                    text row.detail
                if row.excerpt.len > 0:
                  pre(class = "ct-verification-row-excerpt",
                      `data-ct-verification-excerpt` = "true"):
                    text row.excerpt
  when defined(js):
    when N is isonim_dom.Element:
      # The rows' right press: the shared menu, wired on the DOM rows (the
      # headless tree has no events to wire).
      if not findings.isNil:
        for g in 0 ..< findings.childNodes.len:
          let group = findings.childNodes[g]
          for i in 1 ..< group.childNodes.len:
            let row = isonim_dom.Element(group.childNodes[i])
            let key = $row.getAttribute(cstring"data-ct-verification-key")
            if key.len > 0:
              wireRowMenu(row, key)

proc renderVerificationPanel*[R, N](r: R; model: VerificationPanelModel): N =
  ## The pure render, from a plain record, with inert controls.
  renderVerificationPanelTree[R, N](r, model, VerificationPanelHandlers())

proc renderVerificationPanelLive*[R, N](r: R; vm: VerificationVM;
                                        session: CounterexampleSessionVM): N =
  ## The run as it is now, with the one action wired to `session`. Read once,
  ## like `renderCounterexampleSessionLive`; `renderVerificationPane` keeps it
  ## current.
  let m = panelModel(vm, session)
  let h = verificationHandlersFor(vm, session)
  when defined(js):
    liveVerificationVM = vm
    liveCounterexampleVM = session
  renderVerificationPanelTree[R, N](r, m, h)

proc renderVerificationPane*[R, N](r: R; vm: VerificationVM;
                                   session: CounterexampleSessionVM): N =
  ## The Verification pane: the run, then what its counterexample says.
  ##
  ## Two hosts in reading order, each rebuilt by its own effect, so a step
  ## through the counterexample repaints only the counterexample and a run's
  ## progress repaints only the run. The run's tree is rebuilt whole because
  ## it branches over the model (see `renderVerificationPanelLive`).
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild
  var runHost: N
  let pane = ui(r):
    tdiv(class = "ct-verification-pane"):
      tdiv(ref = runHost, class = "ct-verification-run-host")
  createRenderEffect proc() =
    let panel = renderVerificationPanelLive[R, N](r, vm, session)
    r.clearChildren(runHost)
    r.appendChild(runHost, panel)
  r.appendChild(pane, renderCounterexamplePane[R, N](r, session))
  pane
