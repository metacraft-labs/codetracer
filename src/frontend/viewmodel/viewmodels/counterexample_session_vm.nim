## NOT-A-TEST-LANE-FILE: production ViewModel-layer code. It declares no
## `suite`/`test` blocks; its behaviour is asserted by
## `src/frontend/viewmodel/tests/unit/test_counterexample_session.nim`.

## viewmodels/counterexample_session_vm.nim
##
## VN-M5 — the rendering half. A `SolverCounterexampleTrace` that VN-M4's
## decoder accepted, turned into something a developer walks through with the
## debugger's ordinary controls.
##
## VN-M5's supply half landed first and separately: a solver's model now
## crosses four repositories into `verification_payload.nim`, and
## `hasSteppableCounterexample` answers `true` for a real payload. Nothing
## rendered it. This module is the consumer of that gate and nothing else — it
## decodes nothing, classifies nothing, and invents no value the payload did
## not carry.
##
## ## The constraint that shapes the whole file
##
## **A program point carries values and no source position.** The
## snapshot-to-span map is `SnapPos`, built inside `vir`/`rust_verify`, and it
## does not cross the `venir` boundary. Every step of the one real model this
## campaign has reports `hasLocation == false`, and both the producer and the
## consumer assert that absence deliberately so a renderer can tell *unknown*
## from *line 1*.
##
## So this module never lets an unknown position render as a real one, and it
## does that structurally rather than by remembering to:
##
## * `StepPosition`'s **zero value is `pkUnknown`**, and its `line` is `0` in
##   that state — not `1`. A renderer that forgets to set the knowledge field
##   gets "unknown", which is the safe answer, and a line number that is not a
##   line number in any file.
## * `positionLabel` returns `UnknownPositionText` for an unknown position, and
##   that string **contains no digit**, so no test and no reader can mistake it
##   for coordinates.
## * A location that arrives with a line below 1 is *demoted to unknown* with
##   its own reason, rather than trusted. This is not hypothetical: a sibling
##   milestone caught a producer resolving a span at byte 0 against an empty
##   line table and getting "line 1 of a file whose text was absent". Line 1 of
##   a real file exists and looks plausible, which is what makes it the
##   dangerous default rather than a harmless one.
## * `editorAnchors` follows `verification_report.editorMarkers`'s rule
##   exactly — "a finding with `hasLocation == false` produces no marker at all
##   rather than one at line 1" — and produces `VerificationMarker`s, the type
##   the editor already consumes, rather than a second marker type.
##
## ## Loops
##
## Deliverable 4 says a bounded model's loop iterations are driven "through the
## **existing** loop controls, not a parallel mechanism". So the arithmetic
## here is not written here: `activeIterationForTicks`, `nextIteration` and
## `previousIteration` are imported from `ui/flow_loop_math`, which is the
## module the Omniscience flow panel's loop slider uses, and `flow_vm` calls
## the same three procs for the same three jobs. There is one implementation of
## "which iteration am I in" and of "what does the next-iteration arrow do" in
## this repository, and a change to it moves both panels — which is the only
## way to say "not a parallel mechanism" that a test can check.
##
## What differs is only the *coordinate*: the flow panel's loop is indexed by
## trace ticks (`rrTicksForIterations`), and a counterexample's is indexed by
## step index. Both are strictly increasing lists of interval starts, which is
## the only property `activeIterationForTicks` needs.
##
## **No producer emits a loop step yet.** `air`'s snapshots do not distinguish
## an unrolled iteration from any other program point, so Verno emits neither
## `StepKind::LoopIteration` nor `iteration`, and `loops` is empty for every
## document this campaign can produce today. That is a producer-side gap, it is
## named in the milestone, and it is why the loop checks in the suite carry a
## fixture of their own and assert its size before asserting anything about its
## members.

import std/options

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../../ui/flow_loop_math
import ../../../ct_test/contracts
import ./verification_report
import ./verification_payload

# ---------------------------------------------------------------------------
# Positions
# ---------------------------------------------------------------------------

type
  PositionKnowledge* = enum
    ## Two states, and the *first* one is the default.
    ##
    ## Ordering is load-bearing in the same way `PayloadTrustClass`'s is: the
    ## zero value of `StepPosition` must be the claim that asserts least, so a
    ## field nobody filled in cannot read as coordinates.
    pkUnknown = "unknown"
    pkKnown = "known"

  StepPosition* = object
    knowledge*: PositionKnowledge
    file*: string
    line*: int
      ## One-based when `knowledge == pkKnown`. **Zero** when it is not — never
      ## 1, because 1 is a line that exists in every file.
    column*: int
    reason*: string
      ## Why there is no position. Required whenever `knowledge == pkUnknown`,
      ## and it is the producer's reason where the producer gave one.

const
  UnknownPositionText* = "position not recorded"
    ## What a step with no source position renders as.
    ##
    ## Deliberately free of digits and of `:`, so that neither a reader nor a
    ## test can confuse it with `file:line:column`. Asserted character by
    ## character in the suite.

  NoSnapPosReason* = "the prover recorded values here but not which line " &
    "they belong to"
    ## The one reason that applies to every step of every model this campaign
    ## has produced.

  ImplausibleLineReason* = "the payload carried a location whose line number " &
    "is not a line number, so it is reported as unknown rather than trusted"
    ## A location with a line below 1 is a fabricated position, not a position.
    ## Demoting it is the difference between "we do not know" and "line 1".

proc unknownPosition*(reason: string): StepPosition =
  StepPosition(knowledge: pkUnknown, line: 0, column: 0, reason: reason)

proc positionOf*(hasLocation: bool; location: PayloadLocation;
                 absentReason = NoSnapPosReason): StepPosition =
  ## The single place a payload location becomes something renderable.
  ##
  ## Every path that produces a `StepPosition` goes through here, so the
  ## demotion rule below cannot be bypassed by a caller that reads
  ## `location.range.startLine` directly.
  if not hasLocation:
    return unknownPosition(absentReason)
  if location.range.startLine < 1:
    return unknownPosition(ImplausibleLineReason)
  StepPosition(
    knowledge: pkKnown,
    file: location.file,
    line: location.range.startLine,
    column: location.range.startColumn,
    reason: "")

proc isKnown*(position: StepPosition): bool =
  position.knowledge == pkKnown

proc positionLabel*(position: StepPosition): string =
  ## What a view prints next to a step.
  ##
  ## The unknown branch returns a sentence, not a placeholder like `?:?` or
  ## `-:-`, because a placeholder in the shape of coordinates is read as
  ## coordinates.
  if position.isKnown:
    position.file & ":" & $position.line & ":" & $position.column
  else:
    UnknownPositionText

# ---------------------------------------------------------------------------
# The render plan
# ---------------------------------------------------------------------------

type
  BindingRow* = object
    ## One model assignment, reduced to strings.
    name*: string
    value*: string
    typeName*: string
    position*: StepPosition
      ## A binding may know where its variable was declared even when the step
      ## does not know where it is — `not_proved_with_model.json` carries
      ## exactly that shape. So this is derived separately and not inherited.

  StepRow* = object
    index*: int
    kind*: CounterexampleStepKind
    kindLabel*: string
      ## The kind in words. `verification_vm.VerificationPanelRow` states its
      ## kind in words for the same reason: a row distinguished from its
      ## neighbour only by colour is not distinguished for everyone.
    description*: string
    position*: StepPosition
    positionText*: string
      ## `positionLabel(position)`, materialised so a view cannot render the
      ## fields itself and get the unknown case wrong.
    bindings*: seq[BindingRow]
    isViolation*: bool
    isCurrent*: bool
    pathCondition*: string
    taken*: Option[bool]
    iteration*: Option[int]
    loopIndex*: int
      ## Index into `CounterexampleSessionModel.loops`, or -1.
    isSolverDerived*: bool
      ## Always true. Carried per row rather than only on the container so that
      ## a row lifted out of its panel — into a tooltip, a hover, a copied
      ## selection — takes its provenance with it. Deliverable 5 is about what
      ## a developer can see, and a banner two panes away is not visible on the
      ## row.

  CounterexampleLoop* = object
    ## A run of consecutive `loop-iteration` steps, described the way
    ## `flow_vm.FlowLoopInfo` describes a flow window's loop.
    ##
    ## `stepForIterations` is the analogue of `rrTicksForIterations`: the
    ## position at which each iteration *starts*. Both are strictly increasing
    ## lists of interval starts, which is all `activeIterationForTicks` needs,
    ## and using that proc rather than a second search is the whole of
    ## "existing loop controls, not a parallel mechanism".
    firstStep*: int
    lastStep*: int
    hasLine*: bool
    line*: int
      ## The source line the loop control attaches to — `flow_vm`'s
      ## `registeredLine`. Zero when unknown, and `hasLine` says which.
    stepForIterations*: seq[int]
    iterationLabels*: seq[int]
      ## The producer's own `iteration` numbers, in order, kept verbatim. A
      ## bounded unrolling may start at 0 or at 1 and may skip, and renumbering
      ## it would make the slider disagree with the source.

  CounterexampleSessionModel* = object
    ## The whole session as a plain record, so the view is a pure function of
    ## it and both renderers paint the same tree — the same arrangement
    ## `VerificationPanelModel` uses.
    isOpen*: bool
    traceId*: string
    findingId*: string
    title*: string
    obligationText*: string
    obligationKindLabel*: string
    obligationPosition*: StepPosition
    obligationPositionText*: string
    modelStatusLabel*: string
    modelAbsentReason*: string
    provenance*: string
    isRecordedExecution*: bool
      ## Always false. Present on the model rather than assumed by the view so
      ## that the view can *state* it in the markup.
    trustLabel*: string
    trustReason*: string
    stepCount*: int
    currentStep*: int
    canStepForward*: bool
    canStepBackward*: bool
    positionsKnown*: int
    positionsUnknown*: int
      ## Counted and shown. A session in which nothing has a position says so
      ## in a number, which is a much harder thing to overlook than an absence.
    rows*: seq[StepRow]
    modelBindings*: seq[BindingRow]
      ## The trace's whole model, separate from the per-step assignments.
      ##
      ## Worth its own field because it is the **only** place in this campaign
      ## where a value can be put against a real source line: a binding may
      ## carry the span where its variable was *declared* even when no step
      ## knows where it is, and `not_proved_with_model.json` carries exactly
      ## that shape. That is as close to deliverable 2's "inline with the
      ## source" as anything gets until `SnapPos` crosses the `venir` boundary,
      ## and it is a real position rather than a guessed one.
    loops*: seq[CounterexampleLoop]
    currentLoop*: int
    currentIteration*: int
    iterationCount*: int
    anchors*: seq[VerificationMarker]

const
  SolverDerivedProvenance* =
    "These values come from the prover, not from a run. Nothing executed " &
    "this program to produce them."
    ## Deliverable 5's sentence. It is a constant so the two renderers and the
    ## tests cannot drift, and so that deleting it is a compile error rather
    ## than a quieter panel.

  NoStepsToOpenReason* =
    "this finding has no counterexample with values to step through"

proc stepKindLabel*(kind: CounterexampleStepKind): string =
  case kind
  of cskAssumption: "assumption"
  of cskAssignment: "assignment"
  of cskBranch: "branch"
  of cskLoopIteration: "loop iteration"
  of cskCall: "call"
  of cskViolation: "violated obligation"

proc obligationKindLabel*(kind: ObligationKind): string =
  case kind
  of pokPrecondition: "precondition"
  of pokPostcondition: "postcondition"
  of pokAssertion: "assertion"
  of pokLoopInvariant: "loop invariant"
  of pokLoopDecreases: "loop decreases measure"
  of pokArithmeticOverflow: "arithmetic overflow"
  of pokOther: "obligation"

proc modelStatusLabel*(status: ModelStatus): string =
  case status
  of pmsComplete: "complete"
  of pmsPartial: "partial"
  of pmsUnavailable: "unavailable"

proc trustLabel*(class: PayloadTrustClass): string =
  case class
  of ptcDiagnosticOnly: "diagnostic only"
  of ptcSolverOracle: "solver oracle"
  of ptcProofReconstructed: "proof reconstructed"
  of ptcCheckedByTrustedCore: "checked by trusted core"

# ---------------------------------------------------------------------------
# Loops
# ---------------------------------------------------------------------------

proc loopsOf*(steps: openArray[CounterexampleStep]): seq[CounterexampleLoop] =
  ## Group consecutive `loop-iteration` steps into loops.
  ##
  ## A loop ends at the first step that is not a loop iteration. Two loops
  ## separated by an ordinary step are two loops, which is what a bounded
  ## unrolling of two sibling loops looks like.
  ##
  ## An iteration boundary is a *change* in the producer's `iteration` number.
  ## A step inside a loop that carries no number belongs to the iteration in
  ## progress rather than starting a new one: the producer knows the unrolling
  ## and we do not, so inventing a boundary here would put the slider at a
  ## position the model never described.
  var index = 0
  while index < steps.len:
    if steps[index].kind != cskLoopIteration:
      inc index
      continue
    var loop = CounterexampleLoop(firstStep: index, lastStep: index)
    var lastIteration = low(int)
    while index < steps.len and steps[index].kind == cskLoopIteration:
      let step = steps[index]
      if step.iteration.isSome and step.iteration.get != lastIteration:
        lastIteration = step.iteration.get
        loop.stepForIterations.add index
        loop.iterationLabels.add lastIteration
      elif loop.stepForIterations.len == 0:
        # A loop whose steps carry no iteration number at all is still one
        # iteration, not zero. Zero would make `maxIteration` negative and the
        # arrows dead, which reads as "there is no loop here".
        loop.stepForIterations.add index
        loop.iterationLabels.add 0
      if not loop.hasLine:
        let position = positionOf(step.hasLocation, step.location)
        if position.isKnown:
          loop.hasLine = true
          loop.line = position.line
      loop.lastStep = index
      inc index
    result.add loop

proc loopIndexForStep*(loops: openArray[CounterexampleLoop]; step: int): int =
  ## Which loop a step is inside, or -1.
  for loopIndex, loop in loops:
    if step >= loop.firstStep and step <= loop.lastStep:
      return loopIndex
  -1

proc maxIteration*(loop: CounterexampleLoop): int =
  ## Highest selectable iteration index, or -1 when there is no loop.
  ##
  ## Same definition as `flow_vm.maxIteration`, and for the same reason stated
  ## there: the counter's total, the arrows' clamp and their end-stop state
  ## must all agree, so there is one of it.
  loop.stepForIterations.len - 1

proc iterationForStep*(loop: CounterexampleLoop; step: int): int =
  ## Which iteration of `loop` contains `step`.
  ##
  ## This is `flow_loop_math.activeIterationForTicks`, unchanged and unwrapped.
  ## The flow panel asks it "which iteration contains this trace tick"; this
  ## asks it "which iteration contains this step index". Both are a search for
  ## the last interval start at or before a point, and there is one of that
  ## search in this repository.
  activeIterationForTicks(loop.stepForIterations, step)

# ---------------------------------------------------------------------------
# The ViewModel
# ---------------------------------------------------------------------------

type
  CounterexampleSessionVM* = ref object of ViewModel
    ## One open counterexample. Not a panel of many: the affordance is "open
    ## *this* obligation's counterexample", so the session's identity is the
    ## finding it came from.
    isOpen*: Signal[bool]
    findingId*: Signal[string]
    trace*: Signal[SolverCounterexampleTrace]
    currentStep*: Signal[int]
    refusalReason*: Signal[string]
      ## Why the last `open` did nothing. Never empty after a refused open, and
      ## cleared by a successful one — a button that does nothing and says
      ## nothing is worse than no button.

    steps*: Memo[seq[CounterexampleStep]]
    loops*: Memo[seq[CounterexampleLoop]]
    stepCount*: Memo[int]
    canStepForward*: Memo[bool]
    canStepBackward*: Memo[bool]
    violationStep*: Memo[int]
    currentLoop*: Memo[int]
    currentIteration*: Memo[int]

proc createCounterexampleSessionVM*(): CounterexampleSessionVM =
  withViewModel proc(dispose: proc()): CounterexampleSessionVM =
    let isOpen = createSignal(false)
    let findingId = createSignal("")
    let trace = createSignal(SolverCounterexampleTrace())
    let currentStep = createSignal(0)
    let refusalReason = createSignal("")

    let steps = createMemo[seq[CounterexampleStep]] proc(): seq[CounterexampleStep] =
      if isOpen.val: trace.val.steps else: @[]

    let loops = createMemo[seq[CounterexampleLoop]] proc(): seq[CounterexampleLoop] =
      loopsOf(steps.val)

    let stepCount = createMemo[int] proc(): int =
      steps.val.len

    let canStepForward = createMemo[bool] proc(): bool =
      isOpen.val and currentStep.val + 1 < steps.val.len

    let canStepBackward = createMemo[bool] proc(): bool =
      isOpen.val and currentStep.val > 0

    let violationStep = createMemo[int] proc(): int =
      # The *first* violation, which the contract makes the only one. Searching
      # forward rather than taking the last step means a producer that stops
      # emitting the trailing violation cannot silently redirect this to
      # whatever step happens to be last.
      for index, step in steps.val:
        if step.kind == cskViolation:
          return index
      -1

    let currentLoop = createMemo[int] proc(): int =
      loopIndexForStep(loops.val, currentStep.val)

    let currentIteration = createMemo[int] proc(): int =
      let loopIndex = currentLoop.val
      if loopIndex < 0:
        return -1
      iterationForStep(loops.val[loopIndex], currentStep.val)

    CounterexampleSessionVM(
      isOpen: isOpen,
      findingId: findingId,
      trace: trace,
      currentStep: currentStep,
      refusalReason: refusalReason,
      steps: steps,
      loops: loops,
      stepCount: stepCount,
      canStepForward: canStepForward,
      canStepBackward: canStepBackward,
      violationStep: violationStep,
      currentLoop: currentLoop,
      currentIteration: currentIteration,
      disposeProc: dispose,
    )

# ---------------------------------------------------------------------------
# Deliverable 1 — one action, from the failed obligation
# ---------------------------------------------------------------------------

proc canOpenCounterexample*(payload: VerificationPayload;
                            findingId: string): bool =
  ## Whether an "open the counterexample" affordance may be offered for this
  ## finding.
  ##
  ## The same rule `hasSteppableCounterexample` applies to a whole payload,
  ## narrowed to one finding — and narrowed *here* rather than in the view, so
  ## the button and the session cannot disagree about what is openable. A
  ## counterexample with no steps or an unavailable model is a located
  ## obligation and nothing more; offering to step through it would promise a
  ## walk the payload does not describe.
  let trace = counterexampleFor(payload, findingId)
  trace.isSome and trace.get.steps.len > 0 and
    trace.get.model.status != pmsUnavailable

proc close*(vm: CounterexampleSessionVM) =
  vm.isOpen.val = false
  vm.findingId.val = ""
  vm.trace.val = SolverCounterexampleTrace()
  vm.currentStep.val = 0

proc openCounterexample*(vm: CounterexampleSessionVM;
                         payload: VerificationPayload;
                         findingId: string): bool {.discardable.} =
  ## **Deliverable 1.** One call, from a failed obligation to a session sitting
  ## on the first step of the counterexample.
  ##
  ## Returns whether a session opened. It refuses, with a reason, rather than
  ## opening an empty one: a session showing nothing is indistinguishable from
  ## a session that failed to load, and the developer clicked the button either
  ## way.
  ##
  ## A refusal also *closes* whatever was open. Leaving the previous finding's
  ## counterexample on screen under a click on a different obligation is the
  ## stale-green shape `VerificationVM.start` clears the previous report for.
  if not canOpenCounterexample(payload, findingId):
    vm.close()
    vm.refusalReason.val = NoStepsToOpenReason
    return false
  let trace = counterexampleFor(payload, findingId).get
  vm.refusalReason.val = ""
  vm.findingId.val = findingId
  vm.trace.val = trace
  vm.currentStep.val = 0
  vm.isOpen.val = true
  true

# ---------------------------------------------------------------------------
# The debugger's ordinary controls
# ---------------------------------------------------------------------------
#
# Named as `debug_controls_vm` names them. A counterexample walked with
# `stepForward` / `stepBackward` / `continueExecution` / `reverseContinue` is
# walked with the vocabulary the rest of the product already uses, which is
# what the milestone's goal asks for: "using the debugger's ordinary controls
# rather than a verification-specific viewer".

proc goToStep*(vm: CounterexampleSessionVM; index: int) =
  ## Clamped at both ends, like `flow_vm.selectIteration`, so a stale view
  ## whose closure captured an older index cannot drive the session out of
  ## range.
  if not vm.isOpen.val:
    return
  let last = vm.steps.val.len - 1
  if last < 0:
    return
  vm.currentStep.val = max(0, min(index, last))

proc stepForward*(vm: CounterexampleSessionVM) =
  vm.goToStep(vm.currentStep.val + 1)

proc stepBackward*(vm: CounterexampleSessionVM) =
  vm.goToStep(vm.currentStep.val - 1)

proc continueExecution*(vm: CounterexampleSessionVM) =
  ## Run to the violated obligation — the counterexample's only breakpoint,
  ## and the reason the trace exists.
  let target = vm.violationStep.val
  if target >= 0:
    vm.goToStep(target)
  else:
    vm.goToStep(vm.steps.val.len - 1)

proc reverseContinue*(vm: CounterexampleSessionVM) =
  vm.goToStep(0)

# ---------------------------------------------------------------------------
# Deliverable 4 — the flow panel's loop control, over a counterexample
# ---------------------------------------------------------------------------

proc currentLoopInfo*(vm: CounterexampleSessionVM): Option[CounterexampleLoop] =
  let index = vm.currentLoop.val
  if index < 0: none(CounterexampleLoop) else: some(vm.loops.val[index])

proc iterationCount*(vm: CounterexampleSessionVM): int =
  let loop = vm.currentLoopInfo()
  if loop.isNone: 0 else: loop.get.stepForIterations.len

proc selectIteration*(vm: CounterexampleSessionVM; iteration: int) =
  ## The loop slider. Moving it moves the session, exactly as moving the flow
  ## panel's slider moves the debugger — the control drives the position, it
  ## does not merely label it.
  let loop = vm.currentLoopInfo()
  if loop.isNone:
    return
  let info = loop.get
  let clamped =
    if iteration < 0: 0
    elif iteration > info.maxIteration(): max(info.maxIteration(), 0)
    else: iteration
  if info.stepForIterations.len == 0:
    return
  vm.goToStep(info.stepForIterations[clamped])

proc stepIterationForward*(vm: CounterexampleSessionVM) =
  ## The "next iteration" arrow. `nextIteration` is `ui/flow_loop_math`'s, the
  ## same proc `flow_vm.stepIterationForward` calls: one click is one
  ## iteration, never two (#595), and it end-stops rather than wrapping.
  let loop = vm.currentLoopInfo()
  if loop.isNone:
    return
  vm.selectIteration(nextIteration(vm.currentIteration.val,
                                   loop.get.maxIteration()))

proc stepIterationBackward*(vm: CounterexampleSessionVM) =
  let loop = vm.currentLoopInfo()
  if loop.isNone:
    return
  vm.selectIteration(previousIteration(vm.currentIteration.val,
                                       loop.get.maxIteration()))

# ---------------------------------------------------------------------------
# Deliverable 3 — marking the violated obligation where it can be marked
# ---------------------------------------------------------------------------

proc editorAnchors*(vm: CounterexampleSessionVM): seq[VerificationMarker] =
  ## Gutter markers for the parts of this counterexample that have a place to
  ## sit, in the type the editor already consumes.
  ##
  ## The rule is `verification_report.editorMarkers`'s, restated because it is
  ## the one that matters most here: **a step with no location produces no
  ## marker at all rather than one at line 1**, because a marker on an
  ## arbitrary line is a claim about code that made no such claim. Against the
  ## one real model this campaign has, that means this returns an empty
  ## sequence — and the session says so in `positionsUnknown` rather than
  ## rendering an empty gutter and letting it read as "nothing is wrong".
  if not vm.isOpen.val:
    return @[]
  let trace = vm.trace.val
  if trace.hasViolatedObligation:
    let position = positionOf(trace.violatedObligation.hasLocation,
                              trace.violatedObligation.location)
    if position.isKnown:
      result.add VerificationMarker(
        kind: vmkFailedObligation,
        file: position.file,
        range: trace.violatedObligation.location.range,
        message: trace.violatedObligation.message,
        hoverText: obligationKindLabel(trace.violatedObligation.kind) & ": " &
          trace.violatedObligation.rawKind & "\n\n" & SolverDerivedProvenance,
        severity: dsError)
  for step in trace.steps:
    if step.kind == cskViolation:
      continue
    let position = positionOf(step.hasLocation, step.location)
    if not position.isKnown:
      continue
    result.add VerificationMarker(
      kind: vmkFailedObligation,
      file: position.file,
      range: step.location.range,
      message: step.description,
      hoverText: stepKindLabel(step.kind) & ": " & step.description & "\n\n" &
        SolverDerivedProvenance,
      severity: dsError)

# ---------------------------------------------------------------------------
# The whole session, as a record
# ---------------------------------------------------------------------------

proc bindingRows(bindings: openArray[ModelBinding]): seq[BindingRow] =
  for binding in bindings:
    result.add BindingRow(
      name: binding.name,
      value: binding.value,
      typeName: binding.typeName,
      position: positionOf(binding.hasLocation, binding.location))

proc sessionModel*(vm: CounterexampleSessionVM): CounterexampleSessionModel =
  ## Everything the view needs, already reduced. No signal is read twice and
  ## no field is computed in the view.
  result.isOpen = vm.isOpen.val
  result.provenance = SolverDerivedProvenance
  result.currentLoop = -1
  result.currentIteration = -1
  if not result.isOpen:
    return

  let trace = vm.trace.val
  result.traceId = trace.id
  result.findingId = vm.findingId.val
  result.isRecordedExecution = trace.isRecordedExecution
  result.trustLabel = trustLabel(trace.trust.class)
  result.trustReason = trace.trust.reason
  result.modelStatusLabel = modelStatusLabel(trace.model.status)
  result.modelAbsentReason = trace.model.absentReason
  result.stepCount = vm.stepCount.val
  result.currentStep = vm.currentStep.val
  result.canStepForward = vm.canStepForward.val
  result.canStepBackward = vm.canStepBackward.val
  result.loops = vm.loops.val
  result.currentLoop = vm.currentLoop.val
  result.currentIteration = vm.currentIteration.val
  result.iterationCount = vm.iterationCount()
  result.modelBindings = bindingRows(trace.model.bindings)
  result.anchors = vm.editorAnchors()

  if trace.hasViolatedObligation:
    result.obligationText = trace.violatedObligation.message
    result.obligationKindLabel = obligationKindLabel(trace.violatedObligation.kind)
    result.obligationPosition = positionOf(
      trace.violatedObligation.hasLocation, trace.violatedObligation.location)
  else:
    result.obligationKindLabel = "obligation"
    result.obligationPosition = unknownPosition(NoSnapPosReason)
  result.obligationPositionText = positionLabel(result.obligationPosition)
  result.title =
    if result.obligationText.len > 0:
      result.obligationKindLabel & " — " & result.obligationText
    else:
      "counterexample " & trace.id

  for index, step in vm.steps.val:
    let position = positionOf(step.hasLocation, step.location)
    if position.isKnown:
      inc result.positionsKnown
    else:
      inc result.positionsUnknown
    result.rows.add StepRow(
      index: index,
      kind: step.kind,
      kindLabel: stepKindLabel(step.kind),
      description: step.description,
      position: position,
      positionText: positionLabel(position),
      bindings: bindingRows(step.bindings),
      isViolation: step.kind == cskViolation,
      isCurrent: index == result.currentStep,
      pathCondition: step.pathCondition,
      taken: step.taken,
      iteration: step.iteration,
      loopIndex: loopIndexForStep(result.loops, index),
      isSolverDerived: true)

# ---------------------------------------------------------------------------
# The one summary line a panel shows when it cannot show a walk
# ---------------------------------------------------------------------------

proc positionSummary*(model: CounterexampleSessionModel): string =
  ## Says, in words and in numbers, how much of this trace can be put against
  ## source.
  ##
  ## This exists because "no gutter markers appeared" and "this trace has no
  ## source positions" look identical on screen, and only one of them is a
  ## fact about the payload.
  if not model.isOpen:
    return ""
  if model.positionsUnknown == 0:
    return "every step has a source position"
  if model.positionsKnown == 0:
    return "no step has a source position — " & $model.stepCount &
      " of " & $model.stepCount & " unknown"
  $model.positionsUnknown & " of " & $model.stepCount &
    " steps have no source position"
