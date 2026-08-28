## VN-M3 — the text-fallback verification panel.
##
## `SMT-Counterexample-And-Prover-State-Visualization.md` defines exactly what
## this tier may claim, in its own test name: `SolverViz.TextFallback` — "a
## producer without structured model data still shows the textual diagnostic
## **without claiming trace replay support**."
##
## So this view is deliberately, visibly poorer than the panes around it.
## There is no "step through this counterexample" button, no trace link, no
## model-value table, no proof-goal tree, and no disabled control hinting that
## one is coming. The whole vocabulary of replay is absent from the markup —
## not greyed out, absent — because a disabled affordance is still a promise,
## and VN-M3 is the milestone that promises nothing about replay. VN-M4 earns
## the payload and VN-M5 earns the affordance.
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
import ../viewmodels/verification_vm

proc correctnessNote(model: VerificationPanelModel): string =
  ## The sentence that keeps four of the six outcomes from reading as a
  ## verdict on the program.
  if not model.hasReport:
    return ""
  if model.answersCorrectness:
    return ""
  "Nothing was proved or disproved about this program."

template renderVerificationPanelImpl(r, model: untyped): untyped =
  ui(r):
    tdiv(class = "ct-verification-panel",
         `data-ct-verification` = "true",
         `data-ct-verification-phase` = $model.phase,
         `data-ct-verification-running` = $model.running,
         `data-ct-verification-outcome` = model.outcomeText,
         `data-ct-verification-tier` = "text-fallback",
         `data-ct-verification-answers-correctness` = $model.answersCorrectness):
      tdiv(class = "ct-verification-status",
           `data-ct-verification-status` = "true",
           `data-ct-verification-elapsed` = model.elapsed):
        text model.statusText
      tdiv(class = "ct-verification-command",
           `data-ct-verification-command` = "true",
           title = model.commandLine):
        text model.commandLine
      if model.cancellable:
        button(class = "ct-verification-cancel",
               `data-ct-verification-action` = "cancel",
               `aria-label` = "Stop this verification run"):
          text "Stop"
      if correctnessNote(model).len > 0:
        tdiv(class = "ct-verification-correctness-note",
             `data-ct-verification-note` = "no-verdict"):
          text correctnessNote(model)
      tdiv(class = "ct-verification-findings",
           `data-ct-verification-findings` = $model.rows.len):
        for rowIndex in 0 ..< model.rows.len:
          let row = model.rows[rowIndex]
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
  renderVerificationPanelImpl(r, model)

when defined(js):
  proc renderVerificationPanel*(r: WebRenderer;
                                model: VerificationPanelModel):
                                isonim_dom.Element =
    renderVerificationPanelImpl(r, model)
