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
## One `template …Impl` materialised per renderer, so the headless Mock tree
## and the browser DOM are the same tree.

import isonim/dsl/ui
import isonim/core/computation
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/verification_report
import ../viewmodels/verification_payload
import ../viewmodels/verification_vm
import ../viewmodels/counterexample_session_vm

type
  VerificationPanelHandlers* = object
    ## What the panel's one action does when clicked. Same arrangement, and
    ## same reason, as `CounterexampleHandlers`: one tree, two entry points.
    onOpenCounterexample*: proc(findingId: string)

proc openHandler(handlers: VerificationPanelHandlers;
                 findingId: string): proc() =
  ## Nil-safe, so the pure model-based render is a legal tree with no session
  ## behind it.
  let f = handlers.onOpenCounterexample
  let id = findingId
  result = proc() =
    if not f.isNil:
      f(id)

proc verificationHandlersFor*(vm: VerificationVM;
                              session: CounterexampleSessionVM):
                              VerificationPanelHandlers =
  ## The live wiring for deliverable 1: one click, from the failed obligation
  ## to a session on the first step of its counterexample.
  VerificationPanelHandlers(
    onOpenCounterexample: proc(findingId: string) =
      discard vm.openCounterexample(session, findingId))

proc noModelNote(model: VerificationPanelModel): string =
  ## The sentence shown when a payload arrived, was believed, and carries no
  ## model to walk.
  ##
  ## A proc rather than a condition inline in the tree, following
  ## `correctnessNote` below: the `ui` DSL does not take a multi-line `and`
  ## condition, and a condition it silently declines to render is worse than
  ## one it rejects.
  if model.counterexampleOffers.len > 0:
    return ""
  if model.modelAbsentReason.len == 0:
    return ""
  "No counterexample to step through: " & model.modelAbsentReason

proc correctnessNote(model: VerificationPanelModel): string =
  ## The sentence that keeps four of the six outcomes from reading as a
  ## verdict on the program.
  if not model.hasReport:
    return ""
  if model.answersCorrectness:
    return ""
  "Nothing was proved or disproved about this program."

template renderVerificationPanelImpl(r, mdl, hnd: untyped): untyped =
  ui(r):
    tdiv(class = "ct-verification-panel",
         `data-ct-verification` = "true",
         `data-ct-verification-phase` = $mdl.phase,
         `data-ct-verification-running` = $mdl.running,
         `data-ct-verification-outcome` = mdl.outcomeText,
         `data-ct-verification-tier` = "text-fallback",
         `data-ct-verification-answers-correctness` = $mdl.answersCorrectness):
      tdiv(class = "ct-verification-status",
           `data-ct-verification-status` = "true",
           `data-ct-verification-elapsed` = mdl.elapsed):
        text mdl.statusText
      tdiv(class = "ct-verification-command",
           `data-ct-verification-command` = "true",
           title = mdl.commandLine):
        text mdl.commandLine
      if mdl.cancellable:
        button(class = "ct-verification-cancel",
               `data-ct-verification-action` = "cancel",
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
                   onclick = openHandler(hnd, offer.findingId),
                   `aria-label` = "Step through the counterexample for this " &
                     offer.kindLabel):
              text "Step through the counterexample"
      tdiv(class = "ct-verification-findings",
           `data-ct-verification-findings` = $mdl.rows.len):
        for rowIndex in 0 ..< mdl.rows.len:
          let row = mdl.rows[rowIndex]
          tdiv(class = "ct-verification-row ct-verification-row-" & $row.kind,
               `data-ct-verification-row` = "true",
               `data-ct-verification-kind` = $row.kind,
               `data-ct-verification-is-failure` = $row.isFailure,
               `data-ct-verification-location` = row.location):
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

proc renderVerificationPanel*(r: MockRenderer;
                              model: VerificationPanelModel): MockNode =
  renderVerificationPanelImpl(r, model, VerificationPanelHandlers())

proc renderVerificationPanelLive*(r: MockRenderer; vm: VerificationVM;
                                  session: CounterexampleSessionVM): MockNode =
  ## `panelModel(vm)` as an *expression*, so the DSL re-evaluates it inside
  ## each reactive scope and the panel follows the run.
  let m = panelModel(vm)
  let h = verificationHandlersFor(vm, session)
  renderVerificationPanelImpl(r, m, h)

when defined(js):
  proc renderVerificationPanel*(r: WebRenderer;
                                model: VerificationPanelModel):
                                isonim_dom.Element =
    renderVerificationPanelImpl(r, model, VerificationPanelHandlers())

  proc renderVerificationPanelLive*(r: WebRenderer; vm: VerificationVM;
                                    session: CounterexampleSessionVM):
                                    isonim_dom.Element =
    let m = panelModel(vm)
    let h = verificationHandlersFor(vm, session)
    renderVerificationPanelImpl(r, m, h)

  proc mountIsoNimVerificationPanel*(container: isonim_dom.Element;
                                     vm: VerificationVM;
                                     session: CounterexampleSessionVM) =
    ## Mount the verification panel as a child of `container`. VN-M3 shipped
    ## this view with no mount proc at all, which is the whole of why nothing
    ## in a running window could open it.
    createEffect proc() =
      let panel = renderVerificationPanelLive(WebRenderer(), vm, session)
      let containerNode = isonim_dom.Node(container)
      while not isonim_dom.isNodeNil(containerNode.firstChild):
        discard isonim_dom.removeChild(containerNode, containerNode.firstChild)
      isonim_dom.appendChild(containerNode, isonim_dom.Node(panel))
