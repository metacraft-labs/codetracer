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

type
  CounterexampleHandlers* = object
    ## What the panel's controls do when clicked.
    ##
    ## An object of closures rather than a `vm` parameter on the template, so
    ## that **one** tree serves both entry points: the pure model-based render
    ## that the suite asserts, and the live VM-driven one that gets mounted.
    ## Two trees would drift, and the drift would be invisible — the tests
    ## would keep asserting the tree nobody mounts.
    ##
    ## Every field may be nil. `handler` below is what makes that safe, and it
    ## is why the model-based overload needs no stub closures.
    onStepForward*: proc()
    onStepBackward*: proc()
    onContinue*: proc()
    onIterationForward*: proc()
    onIterationBackward*: proc()

proc handler(p: proc()): proc() =
  ## Nil-safe: a control rendered without a handler is inert rather than a
  ## crash. The pure render path deliberately has no handlers, and a panel
  ## rendered from a plain model must still be a legal tree.
  result = proc() =
    if not p.isNil:
      p()

proc handlersFor*(vm: CounterexampleSessionVM): CounterexampleHandlers =
  ## The live wiring: the debugger's ordinary controls, bound to the session.
  CounterexampleHandlers(
    onStepForward: proc() = vm.stepForward(),
    onStepBackward: proc() = vm.stepBackward(),
    onContinue: proc() = vm.continueExecution(),
    onIterationForward: proc() = vm.stepIterationForward(),
    onIterationBackward: proc() = vm.stepIterationBackward())

proc takenLabel(taken: Option[bool]): string =
  if taken.isNone: ""
  elif taken.get: "branch taken"
  else: "branch not taken"

template renderCounterexampleSessionImpl(r, mdl, hnd: untyped): untyped =
  ui(r):
    tdiv(class = "ct-counterexample",
         `data-ct-counterexample` = "true",
         `data-ct-counterexample-open` = $mdl.isOpen,
         `data-ct-counterexample-trace` = mdl.traceId,
         `data-ct-counterexample-finding` = mdl.findingId,
         `data-ct-counterexample-recorded` = $mdl.isRecordedExecution,
         `data-ct-counterexample-trust` = mdl.trustLabel,
         `data-ct-counterexample-steps` = $mdl.stepCount,
         `data-ct-counterexample-positions-known` = $mdl.positionsKnown,
         `data-ct-counterexample-positions-unknown` = $mdl.positionsUnknown):
      # Deliverable 5, first thing in the tree and unconditional: the panel
      # says what it is before it says anything it contains.
      tdiv(class = "ct-counterexample-provenance",
           `data-ct-counterexample-provenance` = "solver-derived"):
        text mdl.provenance
      if mdl.isOpen:
        tdiv(class = "ct-counterexample-title",
             `data-ct-counterexample-obligation-kind` = mdl.obligationKindLabel):
          text mdl.title
        tdiv(class = "ct-counterexample-obligation-position",
             `data-ct-counterexample-obligation-position-known` =
               $mdl.obligationPosition.isKnown):
          text mdl.obligationPositionText
        tdiv(class = "ct-counterexample-model-status",
             `data-ct-counterexample-model-status` = mdl.modelStatusLabel):
          text mdl.modelStatusLabel
        if mdl.modelAbsentReason.len > 0:
          tdiv(class = "ct-counterexample-model-absent-reason"):
            text mdl.modelAbsentReason
        tdiv(class = "ct-counterexample-position-summary",
             `data-ct-counterexample-position-summary` = "true"):
          text positionSummary(mdl)

        # The debugger's ordinary controls, spelled as `debug_controls_vm`
        # spells them. A disabled arrow is still an arrow: the end stops are
        # reported rather than the controls being removed, because a control
        # that disappears at the end of a trace reads as a broken panel.
        tdiv(class = "ct-counterexample-controls",
             `data-ct-counterexample-controls` = "true"):
          button(class = "ct-counterexample-step-backward",
                 `data-ct-counterexample-action` = "step-backward",
                 `data-ct-counterexample-enabled` = $mdl.canStepBackward,
                 onclick = handler(hnd.onStepBackward),
                 `aria-label` = "Previous step of this counterexample"):
            text "Step back"
          button(class = "ct-counterexample-step-forward",
                 `data-ct-counterexample-action` = "step-forward",
                 `data-ct-counterexample-enabled` = $mdl.canStepForward,
                 onclick = handler(hnd.onStepForward),
                 `aria-label` = "Next step of this counterexample"):
            text "Step"
          button(class = "ct-counterexample-continue",
                 `data-ct-counterexample-action` = "continue",
                 onclick = handler(hnd.onContinue),
                 `aria-label` = "Run to the violated obligation"):
            text "Continue to the violation"

        # Deliverable 4. Rendered only when the mdl actually contains an
        # unrolled loop, which no producer emits yet — so this is absent from
        # every document this campaign can produce today, and the suite asserts
        # both arms rather than only the one it can reach.
        if mdl.currentLoop >= 0 and mdl.iterationCount > 0:
          tdiv(class = "ct-counterexample-loop flow-loop-slider",
               `data-ct-counterexample-loop` = $mdl.currentLoop,
               `data-ct-counterexample-iteration` = $mdl.currentIteration,
               `data-ct-counterexample-iteration-count` = $mdl.iterationCount):
            button(class = "ct-counterexample-iteration-backward",
                   `data-ct-counterexample-action` = "iteration-backward",
                   onclick = handler(hnd.onIterationBackward),
                   `aria-label` = "Previous loop iteration"):
              text "‹"
            span(class = "iteration-label"):
              text "iteration " & $(mdl.currentIteration + 1) & " of " &
                $mdl.iterationCount
            button(class = "ct-counterexample-iteration-forward",
                   `data-ct-counterexample-action` = "iteration-forward",
                   onclick = handler(hnd.onIterationForward),
                   `aria-label` = "Next loop iteration"):
              text "›"

        # Deliverable 2, as far as the payload allows it. A mdl binding may
        # carry the span where its variable was declared even when no step
        # knows where it is, and that span is the only place in this campaign
        # where a solver's value can be put against real source. Where there is
        # no span the value is still shown — with the words, never with a line.
        tdiv(class = "ct-counterexample-model",
             `data-ct-counterexample-model-bindings` = $mdl.modelBindings.len):
          for bindingIndex in 0 ..< mdl.modelBindings.len:
            let binding = mdl.modelBindings[bindingIndex]
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
             `data-ct-counterexample-step-rows` = $mdl.rows.len):
          for rowIndex in 0 ..< mdl.rows.len:
            let row = mdl.rows[rowIndex]
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
                   `data-ct-counterexample-recorded` = $mdl.isRecordedExecution,
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
                   `data-ct-counterexample-recorded` = $mdl.isRecordedExecution,
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
  ## The pure render, from a plain record. No handlers: the controls are in the
  ## tree and inert, which is what lets the suite assert the *markup* without
  ## a live session behind it.
  renderCounterexampleSessionImpl(r, model, CounterexampleHandlers())

proc renderCounterexampleSessionLive*(r: MockRenderer;
                                      vm: CounterexampleSessionVM): MockNode =
  ## The live render: the same tree, with the session's own controls behind its
  ## buttons.
  ##
  ## **One render, not a reactive tree, and the reason is a constraint of the
  ## DSL rather than a choice.** `ui`'s attribute parser requires the template's
  ## arguments to substitute as idents; passing `sessionModel(vm)` as the model
  ## *expression* — which is what would make each attribute re-evaluate — makes
  ## it reject the tree with "DSL attribute name must be an ident … got
  ## nnkCall". So the model is bound once here, and freshness is the mount's
  ## job: `mountIsoNimCounterexampleSession` re-runs this inside a
  ## `createEffect`, so every signal `sessionModel` reads is tracked and the
  ## panel is rebuilt when any of them changes.
  ##
  ## The alternative — a second, VM-reading tree written the way
  ## `isonim_flow_view` writes one — was rejected: two trees drift, and the
  ## drift is invisible because the suite would keep asserting the tree nobody
  ## mounts.
  let m = sessionModel(vm)
  let h = handlersFor(vm)
  renderCounterexampleSessionImpl(r, m, h)

when defined(js):
  proc renderCounterexampleSession*(r: WebRenderer;
                                    model: CounterexampleSessionModel):
                                    isonim_dom.Element =
    renderCounterexampleSessionImpl(r, model, CounterexampleHandlers())

  proc renderCounterexampleSessionLive*(r: WebRenderer;
                                        vm: CounterexampleSessionVM):
                                        isonim_dom.Element =
    let m = sessionModel(vm)
    let h = handlersFor(vm)
    renderCounterexampleSessionImpl(r, m, h)

  proc mountIsoNimCounterexampleSession*(container: isonim_dom.Element;
                                         vm: CounterexampleSessionVM) =
    ## Mount the counterexample panel as a child of `container`, and keep it
    ## current.
    ##
    ## Coarse-grained on purpose: the whole panel is rebuilt inside a
    ## `createEffect`, so every signal `sessionModel` touches — `isOpen`, the
    ## trace, the current step, and the memos over them — is tracked, and any
    ## of them changing repaints. `mountIsoNimFlow` gets finer granularity by
    ## reading its VM inside the tree; this panel cannot (see
    ## `renderCounterexampleSessionLive`), and a counterexample is a handful of
    ## rows, so a full rebuild per step is the cheaper trade against a second
    ## tree that would drift.
    createEffect proc() =
      let panel = renderCounterexampleSessionLive(WebRenderer(), vm)
      let containerNode = isonim_dom.Node(container)
      while not isonim_dom.isNodeNil(containerNode.firstChild):
        discard isonim_dom.removeChild(containerNode, containerNode.firstChild)
      isonim_dom.appendChild(containerNode, isonim_dom.Node(panel))
