## VN-M5 — the counterexample session panel.
##
## Sibling of `isonim_verification_view.nim`, and deliberately its opposite:
## that view exists to *withhold* the vocabulary of replay, because VN-M3's
## text tier may promise none. This one may use it, because a payload that
## opens `hasSteppableCounterexample` describes an execution — and it must
## then say, on every surface, **whose** execution it is.
##
## Three things the markup insists on, each of them a deliverable:
##
## * **Provenance travels with the row, not with the panel.** The root carries
##   `data-ct-counterexample-recorded="false"` and the banner, and so does
##   every step row. A row lifted into a hover or a copied selection takes its
##   provenance with it. Deliverable 5 is about what a developer can see, and a
##   banner two panes away is not visible on the row.
##
## * **An unknown position never renders as a real one.** A step with a source
##   position gets `data-ct-counterexample-line` with a number in it; a step
##   without one gets **no such attribute at all** and the words
##   `position not recorded`. Not `?`, not `-`, not `1`. The suite asserts this
##   over the rendered tree rather than over the model, because the model being
##   right and the markup being wrong is exactly the failure this guards
##   against: a real file's line 1 exists and looks plausible.
##
## * **The loop control is the flow panel's control.** Same three affordances,
##   same names, same arithmetic (`ui/flow_loop_math`) — see
##   `counterexample_session_vm`. There is no second slider.
##
## One `template …Impl` materialised per renderer, so the headless Mock tree
## and the browser DOM are the same tree.

import std/options

import isonim/dsl/ui
import isonim/core/computation
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/counterexample_session_vm

proc takenLabel(taken: Option[bool]): string =
  if taken.isNone: ""
  elif taken.get: "branch taken"
  else: "branch not taken"

template renderCounterexampleSessionImpl(r, model: untyped): untyped =
  ui(r):
    tdiv(class = "ct-counterexample",
         `data-ct-counterexample` = "true",
         `data-ct-counterexample-open` = $model.isOpen,
         `data-ct-counterexample-trace` = model.traceId,
         `data-ct-counterexample-finding` = model.findingId,
         `data-ct-counterexample-recorded` = $model.isRecordedExecution,
         `data-ct-counterexample-trust` = model.trustLabel,
         `data-ct-counterexample-steps` = $model.stepCount,
         `data-ct-counterexample-positions-known` = $model.positionsKnown,
         `data-ct-counterexample-positions-unknown` = $model.positionsUnknown):
      # Deliverable 5, first thing in the tree and unconditional: the panel
      # says what it is before it says anything it contains.
      tdiv(class = "ct-counterexample-provenance",
           `data-ct-counterexample-provenance` = "solver-derived"):
        text model.provenance
      if model.isOpen:
        tdiv(class = "ct-counterexample-title",
             `data-ct-counterexample-obligation-kind` = model.obligationKindLabel):
          text model.title
        tdiv(class = "ct-counterexample-obligation-position",
             `data-ct-counterexample-obligation-position-known` =
               $model.obligationPosition.isKnown):
          text model.obligationPositionText
        tdiv(class = "ct-counterexample-model-status",
             `data-ct-counterexample-model-status` = model.modelStatusLabel):
          text model.modelStatusLabel
        if model.modelAbsentReason.len > 0:
          tdiv(class = "ct-counterexample-model-absent-reason"):
            text model.modelAbsentReason
        tdiv(class = "ct-counterexample-position-summary",
             `data-ct-counterexample-position-summary` = "true"):
          text positionSummary(model)

        # The debugger's ordinary controls, spelled as `debug_controls_vm`
        # spells them. A disabled arrow is still an arrow: the end stops are
        # reported rather than the controls being removed, because a control
        # that disappears at the end of a trace reads as a broken panel.
        tdiv(class = "ct-counterexample-controls",
             `data-ct-counterexample-controls` = "true"):
          button(class = "ct-counterexample-step-backward",
                 `data-ct-counterexample-action` = "step-backward",
                 `data-ct-counterexample-enabled` = $model.canStepBackward,
                 `aria-label` = "Previous step of this counterexample"):
            text "Step back"
          button(class = "ct-counterexample-step-forward",
                 `data-ct-counterexample-action` = "step-forward",
                 `data-ct-counterexample-enabled` = $model.canStepForward,
                 `aria-label` = "Next step of this counterexample"):
            text "Step"
          button(class = "ct-counterexample-continue",
                 `data-ct-counterexample-action` = "continue",
                 `aria-label` = "Run to the violated obligation"):
            text "Continue to the violation"

        # Deliverable 4. Rendered only when the model actually contains an
        # unrolled loop, which no producer emits yet — so this is absent from
        # every document this campaign can produce today, and the suite asserts
        # both arms rather than only the one it can reach.
        if model.currentLoop >= 0 and model.iterationCount > 0:
          tdiv(class = "ct-counterexample-loop flow-loop-slider",
               `data-ct-counterexample-loop` = $model.currentLoop,
               `data-ct-counterexample-iteration` = $model.currentIteration,
               `data-ct-counterexample-iteration-count` = $model.iterationCount):
            button(class = "ct-counterexample-iteration-backward",
                   `data-ct-counterexample-action` = "iteration-backward",
                   `aria-label` = "Previous loop iteration"):
              text "‹"
            span(class = "iteration-label"):
              text "iteration " & $(model.currentIteration + 1) & " of " &
                $model.iterationCount
            button(class = "ct-counterexample-iteration-forward",
                   `data-ct-counterexample-action` = "iteration-forward",
                   `aria-label` = "Next loop iteration"):
              text "›"

        # Deliverable 2, as far as the payload allows it. A model binding may
        # carry the span where its variable was declared even when no step
        # knows where it is, and that span is the only place in this campaign
        # where a solver's value can be put against real source. Where there is
        # no span the value is still shown — with the words, never with a line.
        tdiv(class = "ct-counterexample-model",
             `data-ct-counterexample-model-bindings` = $model.modelBindings.len):
          for bindingIndex in 0 ..< model.modelBindings.len:
            let binding = model.modelBindings[bindingIndex]
            if binding.position.isKnown:
              span(class = "ct-counterexample-model-binding",
                   `data-ct-counterexample-binding` = binding.name,
                   `data-ct-counterexample-binding-position-known` = "true",
                   `data-ct-counterexample-binding-file` = binding.position.file,
                   `data-ct-counterexample-binding-line` = $binding.position.line):
                text binding.name & " = " & binding.value & "  (" &
                  positionLabel(binding.position) & ")"
            else:
              span(class = "ct-counterexample-model-binding " &
                     "ct-counterexample-model-binding-unlocated",
                   `data-ct-counterexample-binding` = binding.name,
                   `data-ct-counterexample-binding-position-known` = "false"):
                text binding.name & " = " & binding.value & "  (" &
                  positionLabel(binding.position) & ")"
        tdiv(class = "ct-counterexample-steps",
             `data-ct-counterexample-step-rows` = $model.rows.len):
          for rowIndex in 0 ..< model.rows.len:
            let row = model.rows[rowIndex]
            # The position attribute exists ONLY when the position is known.
            # `whenKnown` is not a formatting choice: an attribute present with
            # a placeholder value is an attribute a reader and a test will
            # parse, and the placeholder they will read is a number.
            if row.position.isKnown:
              tdiv(class = "ct-counterexample-step ct-counterexample-step-" & $row.kind,
                   `data-ct-counterexample-step` = $row.index,
                   `data-ct-counterexample-step-kind` = $row.kind,
                   `data-ct-counterexample-step-current` = $row.isCurrent,
                   `data-ct-counterexample-step-violation` = $row.isViolation,
                   `data-ct-counterexample-recorded` = $model.isRecordedExecution,
                   `data-ct-counterexample-position-known` = "true",
                   `data-ct-counterexample-file` = row.position.file,
                   `data-ct-counterexample-line` = $row.position.line,
                   `data-ct-counterexample-column` = $row.position.column):
                span(class = "ct-counterexample-step-kind"):
                  text row.kindLabel
                span(class = "ct-counterexample-step-position"):
                  text row.positionText
                span(class = "ct-counterexample-step-description"):
                  text row.description
                if takenLabel(row.taken).len > 0:
                  span(class = "ct-counterexample-step-taken"):
                    text takenLabel(row.taken)
                if row.pathCondition.len > 0:
                  span(class = "ct-counterexample-step-path-condition"):
                    text row.pathCondition
                for bindingIndex in 0 ..< row.bindings.len:
                  let binding = row.bindings[bindingIndex]
                  span(class = "ct-counterexample-binding",
                       `data-ct-counterexample-binding` = binding.name,
                       `data-ct-counterexample-binding-position-known` =
                         $binding.position.isKnown):
                    text binding.name & " = " & binding.value
            else:
              tdiv(class = "ct-counterexample-step ct-counterexample-step-" & $row.kind &
                     " ct-counterexample-step-unlocated",
                   `data-ct-counterexample-step` = $row.index,
                   `data-ct-counterexample-step-kind` = $row.kind,
                   `data-ct-counterexample-step-current` = $row.isCurrent,
                   `data-ct-counterexample-step-violation` = $row.isViolation,
                   `data-ct-counterexample-recorded` = $model.isRecordedExecution,
                   `data-ct-counterexample-position-known` = "false",
                   `data-ct-counterexample-position-absent-reason` = row.position.reason):
                span(class = "ct-counterexample-step-kind"):
                  text row.kindLabel
                span(class = "ct-counterexample-step-position",
                     `data-ct-counterexample-position-unknown` = "true"):
                  text row.positionText
                span(class = "ct-counterexample-step-description"):
                  text row.description
                if takenLabel(row.taken).len > 0:
                  span(class = "ct-counterexample-step-taken"):
                    text takenLabel(row.taken)
                if row.pathCondition.len > 0:
                  span(class = "ct-counterexample-step-path-condition"):
                    text row.pathCondition
                for bindingIndex in 0 ..< row.bindings.len:
                  let binding = row.bindings[bindingIndex]
                  span(class = "ct-counterexample-binding",
                       `data-ct-counterexample-binding` = binding.name,
                       `data-ct-counterexample-binding-position-known` =
                         $binding.position.isKnown):
                    text binding.name & " = " & binding.value
      else:
        tdiv(class = "ct-counterexample-closed",
             `data-ct-counterexample-closed` = "true"):
          text "No counterexample is open."

proc renderCounterexampleSession*(r: MockRenderer;
                                  model: CounterexampleSessionModel): MockNode =
  renderCounterexampleSessionImpl(r, model)

when defined(js):
  proc renderCounterexampleSession*(r: WebRenderer;
                                    model: CounterexampleSessionModel):
                                    isonim_dom.Element =
    renderCounterexampleSessionImpl(r, model)
