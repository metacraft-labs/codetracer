## test_counterexample_session.nim
##
## VN-M5's **rendering** half. The supply half — a solver's model crossing four
## repositories into the decoder — is asserted by
## `test_verification_payload.nim`'s `VN-M5 the solver's model survives the
## producer boundary` suite, and this file assumes it rather than repeating it.
##
## ## What each check may and may not claim
##
## Nothing here needs a solver, and nothing here has one. Every input is a
## document that already exists in the repository, and the three of them are
## deliberately from **three different origins**, because a renderer checked
## only against a fixture written next to it agrees with itself:
##
## 1. `verno_emitted_solver_model.json` — **Verno's own emitter produced it and
##    a real z3 4.15.1 produced the model inside it.** Neither half was written
##    on this side. Every one of its steps carries values and *no* source
##    position, which is the state this milestone's renderer exists to handle
##    honestly.
##
## 2. `not_proved_with_model.json` — hand-authored, but **not here and not for
##    this**: it is part of the shared conformance corpus, tied by a SHA-256
##    manifest that is byte-identical in `blocksense-network/verno`, and it
##    predates this renderer by a milestone. It is the only document in the
##    repository whose steps are **mixed** — two with a source position and two
##    without — which makes it the control arm for every "unknown position"
##    assertion below. Without it, "every step renders as unknown" would be
##    satisfied by a renderer that renders everything as unknown.
##
## 3. `bounded_loop_model.json` — authored for this milestone, and the only one
##    of the three that is. It exists because **no producer emits a loop step**:
##    `air`'s snapshots do not distinguish an unrolled iteration from any other
##    program point, so Verno emits neither `StepKind::LoopIteration` nor
##    `iteration`, and deliverable 4's consumer half would otherwise be
##    untestable over an empty set. Its *arithmetic* is not trusted to it: the
##    loop checks cross every answer against `ui/flow_loop_math`, which is the
##    flow panel's own module and was written for a different panel years of
##    commits earlier.
##
## ## The counted-assertion rule
##
## `unittest` has no assertion counter, which is why VN-M5's first harness
## reported a count read off the source rather than one a run verified. This
## suite adds one: `ck` wraps `check` and increments `asserted`, `expectCount`
## fails the test when the number does not match the number written at the end
## of it. A check that stopped asserting is a failure here rather than a
## smaller green — the property the three Rust harnesses have and the Nim one
## did not.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_counterexample_session.nim
##
## Mutation harness: `run-vnm5-render-mutations.py`, beside this file.
##
## Discovered by the `vm-unit` (C) and `vm-unit-js` (JS) lanes by glob.

import std/[algorithm, json, options, strutils, tables, unittest]

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

import ../../../../ct_test/contracts
import ../../../ui/flow_loop_math
import ../../viewmodels/project_actions
import ../../viewmodels/verification_report
import ../../viewmodels/verification_payload
import ../../viewmodels/verification_vm
import ../../viewmodels/counterexample_session_vm
import ../../viewmodels/test_run_summary_vm
import ../../views/isonim_verification_view
import ../../views/isonim_counterexample_view

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const
  SolverModelPayload =
    staticRead("../fixtures/verno/counterexample/verno_emitted_solver_model.json")
  LoopModelPayload =
    staticRead("../fixtures/verno/counterexample/bounded_loop_model.json")
  MixedPositionsPayload =
    staticRead("../fixtures/verno/payload/not_proved_with_model.json")
  NoModelPayload =
    staticRead("../fixtures/verno/payload/not_proved_assertion.json")
  FailedAssertionOutput =
    staticRead("../fixtures/verno/failed_obligation_assertion.txt")

# ---------------------------------------------------------------------------
# A counted `check`
# ---------------------------------------------------------------------------

var asserted = 0

template ck(condition: untyped) =
  ## `check`, counted. Every assertion in this file goes through it.
  inc asserted
  check condition

template expectCount(expected: int) =
  ## Fails the test when it did not make the number of assertions written for
  ## it. `asserted` is reset by `startCount` at the top of each test.
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template startCount() =
  asserted = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc decoded(text: string): VerificationPayload =
  let result0 = decodeVerificationPayload(text)
  doAssert result0.ok, "fixture did not decode: " & $result0.problems
  result0.payload

proc verificationAction(): ProjectAction =
  ProjectAction(
    id: "test:verify",
    label: "Verify with Verno",
    command: "verno",
    args: @["verify"])

proc vmWith(payloadText: string): VerificationVM =
  ## A finished `not-proved` run with `payloadText` attached.
  ##
  ## The text half is real captured Verno output, so the attachment goes
  ## through `attachPayload`'s real agreement rules rather than around them: a
  ## payload that disagreed with this text would be *rejected* here, and the
  ## offers would be empty for a reason this suite would then have to explain.
  let payload = decoded(payloadText)
  result = createVerificationVM()
  result.start(verificationAction(), projectRoot = "test-programs/noir_verification")
  result.finish(FailedAssertionOutput, some(1), payloadText = payloadText,
                runStartedAtUnixMs = payload.startedAtUnixMs)

proc sessionOn(payloadText, findingId: string): CounterexampleSessionVM =
  result = createCounterexampleSessionVM()
  doAssert result.openCounterexample(decoded(payloadText), findingId),
    "fixture " & findingId & " did not open"

proc walk(node: MockNode; visit: proc(n: MockNode)) =
  if node.isNil:
    return
  visit(node)
  for child in node.children:
    walk(child, visit)

proc renderedText(node: MockNode): string =
  textContent(node)

proc allAttributeText(node: MockNode): string =
  var acc = ""
  walk(node, proc(n: MockNode) =
    acc.add " " & n.tag
    for name, value in n.attributes:
      acc.add " " & name & "=" & value)
  acc

proc nodesWithAttribute(node: MockNode; name: string): seq[MockNode] =
  var acc: seq[MockNode] = @[]
  walk(node, proc(n: MockNode) =
    if name in n.attributes:
      acc.add n)
  acc

proc attributeValues(node: MockNode; name: string): seq[string] =
  for found in nodesWithAttribute(node, name):
    result.add found.attributes[name]

proc nodesWithAttributeValue(node: MockNode; name, value: string): seq[MockNode] =
  for found in nodesWithAttribute(node, name):
    if found.attributes[name] == value:
      result.add found

proc containsDigit(text: string): bool =
  for c in text:
    if c in {'0' .. '9'}:
      return true
  false

proc renderSessionLive(vm: CounterexampleSessionVM): MockNode =
  var renderer: MockRenderer
  renderCounterexampleSessionLive(renderer, vm)

proc renderPanelLive(vm: VerificationVM;
                     session: CounterexampleSessionVM): MockNode =
  var renderer: MockRenderer
  renderVerificationPanelLive(renderer, vm, session)

proc renderSession(model: CounterexampleSessionModel): MockNode =
  var renderer: MockRenderer
  renderCounterexampleSession(renderer, model)

proc renderPanel(model: VerificationPanelModel): MockNode =
  var renderer: MockRenderer
  renderVerificationPanel(renderer, model)

# ---------------------------------------------------------------------------

suite "VN-M5 a counterexample opens from the obligation it explains":

  test "one action turns a failed obligation into a session on its first step":
    # Deliverable 1. Asserted over **two** documents from different origins so
    # that "it opened" is not a property of one fixture's shape: the one Verno
    # emitted for a real z3 model, and the one in the shared conformance corpus.
    startCount()
    for (name, text, findingId, steps) in [
        ("verno-emitted", SolverModelPayload, "f1", 4),
        ("shared-corpus", MixedPositionsPayload, "f0", 4)]:
      checkpoint(name)
      let vm = vmWith(text)
      ck vm.payloadStatus.val == psAttached

      # The offer, and there is exactly one of it. A count, not "at least one":
      # both documents have more than one finding and only one of them has a
      # model, so `>= 1` would pass over an offer attached to the wrong
      # obligation (`Verification-Harness-Traps.md`, trap 4b).
      let offers = counterexampleOffers(vm)
      ck offers.len == 1
      ck offers[0].findingId == findingId
      ck offers[0].stepCount == steps

      # One call. Not "load then open".
      let session = createCounterexampleSessionVM()
      ck vm.openCounterexample(session, findingId)
      ck session.isOpen.val
      ck session.findingId.val == findingId
      ck session.currentStep.val == 0
      ck session.stepCount.val == steps
      ck session.refusalReason.val == ""

      # And the panel model carries the same offer, so the button a developer
      # clicks and the session it opens are gated by one predicate.
      ck panelModel(vm).counterexampleOffers.len == 1
      ck panelModel(vm).counterexampleOffers[0].findingId == findingId
    expectCount(24)

  test "nothing is offered where there is nothing to walk, and the refusal says so":
    # The other half of deliverable 1, and the half that decides whether the
    # first half is a promise or a lie. Three states, each of which has a
    # counterexample-shaped thing in it somewhere.
    startCount()

    # 1. No payload at all — the ordinary text-tier run.
    let noPayload = createVerificationVM()
    noPayload.start(verificationAction())
    noPayload.finish(FailedAssertionOutput, some(1))
    ck noPayload.payloadStatus.val == psAbsent
    ck counterexampleOffers(noPayload).len == 0
    let session = createCounterexampleSessionVM()
    ck not noPayload.openCounterexample(session, "f0")
    ck not session.isOpen.val
    ck session.refusalReason.val.len > 0

    # 2. A payload attached, with a counterexample whose model is unavailable.
    #    Positive control first: this document really does carry a trace, and
    #    really does name a finding — so "no offer" is a decision about the
    #    model rather than an empty set nobody looked at.
    let unavailable = vmWith(NoModelPayload)
    let payload = decoded(NoModelPayload)
    ck unavailable.payloadStatus.val == psAttached
    ck payload.counterexampleTraces.len == 1
    ck payload.counterexampleTraces[0].findingId == "f0"
    ck payload.findings.len == 1
    ck payload.counterexampleTraces[0].model.status == pmsUnavailable
    ck counterexampleOffers(unavailable).len == 0
    ck not unavailable.openCounterexample(session, "f0")
    ck session.refusalReason.val == NoStepsToOpenReason

    # 3. An attached payload that does have a model, asked for a finding that
    #    is not the one it explains. The offer is per finding, not per run.
    let real = vmWith(SolverModelPayload)
    ck decoded(SolverModelPayload).findings.len == 2
    ck not real.openCounterexample(session, "f0")
    ck real.openCounterexample(session, "f1")

    # And a refusal closes what was open rather than leaving the previous
    # obligation's counterexample under a click on a different one.
    ck session.isOpen.val
    ck not real.openCounterexample(session, "f0")
    ck not session.isOpen.val
    ck session.stepCount.val == 0
    expectCount(20)

  test "the session walks with the debugger's ordinary controls, and end-stops":
    # `stepForward` / `stepBackward` / `continueExecution` / `reverseContinue`
    # are `debug_controls_vm`'s names, used here for the same four jobs. The
    # milestone's goal is explicit that this is "the debugger's ordinary
    # controls rather than a verification-specific viewer".
    startCount()
    let session = sessionOn(SolverModelPayload, "f1")
    ck session.stepCount.val == 4
    ck session.currentStep.val == 0
    ck not session.canStepBackward.val
    ck session.canStepForward.val

    session.stepForward()
    ck session.currentStep.val == 1
    session.stepForward()
    session.stepForward()
    ck session.currentStep.val == 3
    ck not session.canStepForward.val
    # Past the end is a no-op, not a wrap and not a crash.
    session.stepForward()
    ck session.currentStep.val == 3

    session.stepBackward()
    ck session.currentStep.val == 2
    session.reverseContinue()
    ck session.currentStep.val == 0
    session.stepBackward()
    ck session.currentStep.val == 0

    # `continueExecution` runs to the violated obligation, which is the only
    # breakpoint a counterexample has.
    session.continueExecution()
    ck session.currentStep.val == 3
    ck session.violationStep.val == 3
    ck sessionModel(session).rows[3].isViolation

    # The same walk over the shared-corpus document, whose steps have a
    # different shape entirely.
    let other = sessionOn(MixedPositionsPayload, "f0")
    other.continueExecution()
    ck other.currentStep.val == 3
    ck sessionModel(other).rows[other.currentStep.val].isViolation
    other.reverseContinue()
    ck other.currentStep.val == 0
    expectCount(17)

suite "VN-M5 an unknown position never renders as a real one":

  test "a step with no source position renders as words, with no digits in them":
    # The whole reason this suite exists. `SnapPos` is built inside
    # `vir`/`rust_verify` and does not cross the `venir` boundary, so every
    # step of the one real model this campaign has knows *what* the values are
    # and not *where*. "Line 1" is the dangerous default: a real file's line 1
    # exists and looks plausible, and a sibling milestone caught exactly that
    # — a span at byte 0 resolving against an empty line table.
    startCount()
    let session = sessionOn(SolverModelPayload, "f1")
    let model = sessionModel(session)

    # Positive control on the set before quantifying over it. Trap 4: "every
    # step has no position" is satisfied by a trace with no steps.
    ck model.stepCount == 4
    ck model.rows.len == 4
    ck model.positionsUnknown == 4
    ck model.positionsKnown == 0

    for row in model.rows:
      ck not row.position.isKnown
      ck row.position.line == 0        # not 1
      ck row.positionText == UnknownPositionText
      ck row.position.reason.len > 0

    # The label itself. A placeholder shaped like coordinates is read as
    # coordinates, so this string carries neither a digit nor a colon.
    ck not containsDigit(UnknownPositionText)
    ck ':' notin UnknownPositionText

    # And now the rendered tree, which is where the failure would actually
    # reach a developer. A model that is right and markup that is wrong is the
    # case a model-level assertion cannot see.
    # The model's five bindings have no declaration span either, and they are
    # counted before being quantified over for the same trap-4 reason.
    ck model.modelBindings.len == 5
    for binding in model.modelBindings:
      ck not binding.position.isKnown
      ck binding.position.line == 0

    let node = renderSession(model)
    ck nodesWithAttribute(node, "data-ct-counterexample-line").len == 0
    ck nodesWithAttribute(node, "data-ct-counterexample-file").len == 0
    ck nodesWithAttribute(node, "data-ct-counterexample-binding-line").len == 0
    ck nodesWithAttributeValue(node, "data-ct-counterexample-position-known",
                               "false").len == 4
    ck nodesWithAttributeValue(node, "data-ct-counterexample-position-known",
                               "true").len == 0
    let rendered = renderedText(node)
    ck rendered.contains(UnknownPositionText)
    ck not rendered.contains(":1:1")
    ck not rendered.contains("line 1")
    ck model.obligationPositionText == UnknownPositionText
    ck positionSummary(model).contains("no step has a source position")
    expectCount(43)

  test "a position that IS there renders as itself — the control arm":
    # The positive twin of the check above, over the same code path, and this
    # is the pairing that makes both of them mean something
    # (`Verification-Harness-Traps.md` 4a: "a 'must not contain' check paired
    # with a 'must contain' over the same scanner is self-controlling").
    #
    # Without it, a renderer that returned `pkUnknown` unconditionally would
    # pass every assertion above. The document is the shared corpus's, so the
    # mixture was not arranged here: steps 0 and 3 carry spans, steps 1 and 2
    # do not.
    startCount()
    let session = sessionOn(MixedPositionsPayload, "f0")
    let model = sessionModel(session)
    ck model.stepCount == 4
    ck model.positionsKnown == 2
    ck model.positionsUnknown == 2

    ck model.rows[0].position.isKnown
    ck model.rows[0].position.line == 6
    ck model.rows[0].positionText == "src/main.nr:6:1"
    ck not model.rows[1].position.isKnown
    ck model.rows[1].positionText == UnknownPositionText
    ck not model.rows[2].position.isKnown
    ck model.rows[3].position.isKnown
    ck model.rows[3].position.line == 15

    # Deliverable 2, as far as the payload allows. A *model* binding may carry
    # the span where its variable was declared even when no step knows where it
    # is, and this document is the only one in the repository that carries that
    # shape: `x1` has a span, `n` does not. Both arms in one list, from a
    # source that predates this renderer. Positive control on the size first.
    ck model.modelBindings.len == 2
    ck model.modelBindings[0].name == "x1"
    ck model.modelBindings[0].position.isKnown
    ck model.modelBindings[0].position.line == 7
    ck not model.modelBindings[1].position.isKnown
    ck model.rows[1].bindings.len == 1
    ck model.rows[1].bindings[0].name == "x2"
    ck not model.rows[1].bindings[0].position.isKnown

    let node = renderSession(model)
    let lines = attributeValues(node, "data-ct-counterexample-line")
    ck lines.len == 2
    ck lines == @["6", "15"]
    ck attributeValues(node, "data-ct-counterexample-binding-line") == @["7"]
    ck nodesWithAttributeValue(node, "data-ct-counterexample-position-known",
                               "true").len == 2
    ck nodesWithAttributeValue(node, "data-ct-counterexample-position-known",
                               "false").len == 2
    ck renderedText(node).contains("src/main.nr:6:1")
    ck renderedText(node).contains("x1 = 10  (src/main.nr:7:15)")
    ck renderedText(node).contains(UnknownPositionText)
    ck positionSummary(model) == "2 of 4 steps have no source position"
    expectCount(28)

  test "a location whose line is not a line number is demoted, not trusted":
    # The fabricated-position failure, reproduced deliberately. A span that
    # resolves against an empty line table yields line 0 or line 1 depending on
    # which end the producer clamps at; a consumer that trusts either one puts
    # a value against code that did not produce it.
    #
    # The unmutated document is decoded in the same test, so a renderer that
    # demoted *everything* would fail the first three assertions.
    startCount()
    let control = sessionModel(sessionOn(MixedPositionsPayload, "f0"))
    ck control.positionsKnown == 2
    ck control.rows[0].position.isKnown
    ck control.rows[0].position.line == 6

    var doc = parseJson(MixedPositionsPayload)
    doc["counterexample_traces"][0]["steps"][0]["location"]["start_line"] = %0
    let mutatedText = $doc
    let mutated = sessionModel(sessionOn(mutatedText, "f0"))
    ck mutated.stepCount == 4                    # it still decoded
    ck mutated.positionsKnown == 1               # one fewer than the control
    ck mutated.positionsUnknown == 3
    ck not mutated.rows[0].position.isKnown
    ck mutated.rows[0].position.line == 0
    ck mutated.rows[0].positionText == UnknownPositionText
    ck mutated.rows[0].position.reason == ImplausibleLineReason
    ck mutated.rows[3].position.isKnown          # the untouched one is intact

    # And it does not reach the markup as a line either.
    let node = renderSession(mutated)
    ck attributeValues(node, "data-ct-counterexample-line") == @["15"]
    expectCount(12)

suite "VN-M5 the violated obligation is marked where it can be marked":

  test "anchors are the editor's own marker type, and only where a position exists":
    # Deliverable 3. `VerificationMarker` is the type `editorMarkers` already
    # produces from the text tier, so a counterexample's marks go through the
    # editor's existing gutter rather than a second one — and the rule is that
    # module's own: "a finding with `hasLocation == false` produces no marker
    # at all rather than one at line 1".
    startCount()
    let located = sessionOn(MixedPositionsPayload, "f0")
    let anchors = located.editorAnchors()
    # Two: the violated obligation at line 15, and the one non-violation step
    # that carries a span, at line 6. Counted, because "at least one" would be
    # satisfied by the obligation alone.
    ck anchors.len == 2
    ck anchors[0].kind == vmkFailedObligation
    ck anchors[0].range.startLine == 15
    ck anchors[0].file == "src/main.nr"
    ck anchors[0].severity == dsError
    ck anchors[1].range.startLine == 6
    for anchor in anchors:
      ck anchor.range.startLine >= 1
      ck anchor.file.len > 0
      ck anchor.hoverText.contains(SolverDerivedProvenance)
    ck sessionModel(located).anchors.len == 2

    # The real model marks nothing, and the session says why rather than
    # rendering an empty gutter and letting it read as "nothing is wrong".
    let unlocated = sessionOn(SolverModelPayload, "f1")
    ck unlocated.stepCount.val == 4              # positive control
    ck unlocated.trace.val.hasViolatedObligation # there IS an obligation
    ck not unlocated.trace.val.violatedObligation.hasLocation
    ck unlocated.editorAnchors().len == 0
    ck positionSummary(sessionModel(unlocated)).contains("no step has a source position")

    # The obligation is still identified, exactly once and last, whether or not
    # it can be marked — deliverable 3's "identified and located" half.
    var violations = 0
    for row in sessionModel(unlocated).rows:
      if row.isViolation:
        inc violations
    ck violations == 1
    ck sessionModel(unlocated).rows[^1].isViolation
    ck sessionModel(unlocated).obligationKindLabel == "assertion"
    expectCount(21)

suite "VN-M5 a bounded loop is driven by the flow panel's own loop control":

  test "the loop control moves the session, and its arithmetic is flow_loop_math's":
    # Deliverable 4's consumer half. "Not a parallel mechanism" is checked the
    # only way it can be: every answer this VM gives about iterations is
    # cross-asserted against `ui/flow_loop_math`, the module `flow_vm` calls
    # for the Omniscience loop slider. Break that module and both panels move —
    # which the mutation harness demonstrates rather than assumes.
    startCount()
    let session = sessionOn(LoopModelPayload, "f0")
    let model = sessionModel(session)

    # Positive control on the set: this document really does contain a loop,
    # with a known number of iterations. Every assertion below quantifies over
    # it, and over an empty `loops` they would all pass.
    ck model.loops.len == 1
    let loop = model.loops[0]
    ck loop.stepForIterations == @[1, 2, 4]
    ck loop.iterationLabels == @[0, 1, 2]
    ck loop.firstStep == 1
    ck loop.lastStep == 4
    ck loop.hasLine
    ck loop.line == 4
    ck loop.maxIteration() == 2

    # Cross-assertion 1: against `flow_loop_math` directly, over every step of
    # the loop. `iterationForStep` must BE `activeIterationForTicks` and not
    # merely agree with it on the cases this fixture happens to contain.
    var crossed = 0
    for step in loop.firstStep .. loop.lastStep:
      ck iterationForStep(loop, step) ==
        activeIterationForTicks(loop.stepForIterations, step)
      inc crossed
    ck crossed == 4

    # Cross-assertion 2: against a table worked out by hand from the fixture.
    # Step 3 carries no `iteration` of its own and belongs to iteration 1 — the
    # mid-iteration case, which is exactly the regression `activeIterationForTicks`
    # was written for (#593).
    ck iterationForStep(loop, 1) == 0
    ck iterationForStep(loop, 2) == 1
    ck iterationForStep(loop, 3) == 1
    ck iterationForStep(loop, 4) == 2

    # The control drives the position, as the flow panel's slider does.
    session.goToStep(1)
    ck session.currentIteration.val == 0
    ck session.iterationCount() == 3
    session.selectIteration(2)
    ck session.currentStep.val == 4
    ck session.currentIteration.val == 2

    # One click is one iteration, never two (#595), and it end-stops rather
    # than wrapping — `nextIteration`'s contract, asserted against
    # `nextIteration` itself.
    session.selectIteration(0)
    session.stepIterationForward()
    ck session.currentIteration.val == nextIteration(0, loop.maxIteration())
    ck session.currentStep.val == 2
    session.stepIterationForward()
    ck session.currentIteration.val == 2
    session.stepIterationForward()
    ck session.currentIteration.val == 2          # end stop
    session.stepIterationBackward()
    ck session.currentIteration.val == previousIteration(2, loop.maxIteration())
    session.stepIterationBackward()
    session.stepIterationBackward()
    ck session.currentIteration.val == 0          # end stop

    # Outside the loop there is no loop control at all, rather than a control
    # showing iteration 0 of 0.
    session.goToStep(0)
    ck session.currentLoop.val == -1
    ck session.currentIteration.val == -1
    ck session.iterationCount() == 0
    session.selectIteration(2)
    ck session.currentStep.val == 0               # a no-op, not a jump
    expectCount(31)

  test "no producer emits a loop step, so the real payloads render no slider":
    # Stated as a check rather than as a comment, because it is the honest
    # half of deliverable 4 and it will stop being true. `air`'s snapshots do
    # not distinguish an unrolled iteration from any other program point, so
    # Verno emits neither `StepKind::LoopIteration` nor `iteration`.
    #
    # A green here is *not* evidence the loop code works — that is the check
    # above. This one only pins that the slider is absent when the data has no
    # loop, and its positive controls are the step counts.
    startCount()
    for (name, text, findingId, steps) in [
        ("verno-emitted", SolverModelPayload, "f1", 4),
        ("shared-corpus", MixedPositionsPayload, "f0", 4)]:
      checkpoint(name)
      let model = sessionModel(sessionOn(text, findingId))
      ck model.stepCount == steps               # positive control
      ck model.loops.len == 0
      ck model.currentLoop == -1
      ck model.iterationCount == 0
      var loopSteps = 0
      for row in model.rows:
        if row.kind == cskLoopIteration:
          inc loopSteps
        ck row.iteration.isNone
      ck loopSteps == 0
      let node = renderSession(model)
      ck nodesWithAttribute(node, "data-ct-counterexample-loop").len == 0

    # And the arm that proves the absence above is a fact about the data: the
    # same renderer over the loop document does draw one, once the session is
    # inside the loop. The control follows the position, exactly as the flow
    # panel's `focusedLoop` does — a slider for a loop the debugger is not in
    # would be a slider with nothing to move.
    let loopSession = sessionOn(LoopModelPayload, "f0")
    let atEntry = renderSession(sessionModel(loopSession))
    ck nodesWithAttribute(atEntry, "data-ct-counterexample-loop").len == 0
    loopSession.goToStep(1)
    let loopNode = renderSession(sessionModel(loopSession))
    ck nodesWithAttribute(loopNode, "data-ct-counterexample-loop").len == 1
    ck renderedText(loopNode).contains("iteration 1 of 3")
    expectCount(23)

suite "VN-M5 a counterexample is visibly a solver's, never a recording":

  test "the provenance travels with the panel and with every row":
    # Deliverable 5's "visibly" half. The data rule was already enforced end to
    # end by VN-M4/VN-M5's supply half; what was missing is that nothing was
    # visible. A banner on the container is not enough: a row lifted into a
    # hover or a copied selection leaves the banner behind, so every step row
    # carries the claim too.
    startCount()
    let session = sessionOn(SolverModelPayload, "f1")
    let model = sessionModel(session)
    ck not model.isRecordedExecution
    ck model.trustLabel == "diagnostic only"
    ck model.trustReason.len > 0
    ck model.provenance == SolverDerivedProvenance
    ck model.stepCount == 4                      # positive control

    let node = renderSession(model)
    # Once on the root and once on each of the four rows.
    ck nodesWithAttributeValue(node, "data-ct-counterexample-recorded",
                               "false").len == 5
    ck nodesWithAttributeValue(node, "data-ct-counterexample-recorded",
                               "true").len == 0
    ck nodesWithAttribute(node, "data-ct-counterexample-provenance").len == 1
    ck renderedText(node).contains("not a recorded execution")
    ck renderedText(node).contains(SolverDerivedProvenance)
    ck allAttributeText(node).contains("diagnostic only")
    for row in model.rows:
      ck row.isSolverDerived

    # The machinery VN-M3 relies on is untouched: a verification run still
    # projects no `recording-created` event, so the results pane still cannot
    # offer a trace drill-down. VN-M5 adds a panel, not a recording.
    let report = reportForRun(FailedAssertionOutput, some(1))
    let events = toTestEvents(report, "run-1")
    ck events.len > 0                            # positive control
    for event in events:
      ck event.kind != tekRecordingCreated
      ck event.trace.isNone
    ck ReplayIsNotOfferedHere
    ck CounterexampleIsOfferedOnlyWhenSteppable
    expectCount(32)

  test "the text tier still offers nothing, and the same renderer offers when it may":
    # The trap-4a pairing, applied to VN-M3's own invariant. Its
    # `test_the_text_tier_never_offers_replay` asserts a vocabulary is absent
    # from this markup; that check is green over a renderer whose offer section
    # never renders for any reason at all. So the positive twin runs here,
    # through the same `renderVerificationPanel`.
    startCount()

    # Negative: no payload.
    let textTier = createVerificationVM()
    textTier.start(verificationAction())
    textTier.finish(FailedAssertionOutput, some(1))
    let textNode = renderPanel(panelModel(textTier))
    let textHaystack =
      (renderedText(textNode) & " " & allAttributeText(textNode)).toLowerAscii
    ck textHaystack.len > 0                      # positive control on the scan
    ck not textHaystack.contains("counterexample")
    ck not textHaystack.contains("step through")
    ck nodesWithAttributeValue(textNode, "data-ct-verification-action",
                               "open-counterexample").len == 0

    # Negative: a payload whose model is unavailable. Attached, decoded,
    # believed — and still no offer.
    let noModel = vmWith(NoModelPayload)
    ck noModel.payloadStatus.val == psAttached
    let noModelNode = renderPanel(panelModel(noModel))
    ck nodesWithAttributeValue(noModelNode, "data-ct-verification-action",
                               "open-counterexample").len == 0

    # Positive: the same renderer, the same panel, a payload that opens the
    # gate.
    let withModel = vmWith(SolverModelPayload)
    let node = renderPanel(panelModel(withModel))
    let buttons = nodesWithAttributeValue(node, "data-ct-verification-action",
                                          "open-counterexample")
    ck buttons.len == 1
    ck buttons[0].attributes["data-ct-verification-finding"] == "f1"
    ck buttons[0].attributes["data-ct-verification-counterexample-steps"] == "4"
    ck renderedText(node).toLowerAscii.contains("step through the counterexample")
    expectCount(10)

# ---------------------------------------------------------------------------
# Reachability — the panel a user can actually get to
# ---------------------------------------------------------------------------

suite "VN-M5 the panel is reachable, and only where the data allows":

  test "clicking the offer in the rendered panel opens the session":
    # The chain deliverable 1 names, exercised through the markup rather than
    # through the API: render the verification panel, find the button a
    # developer would click, dispatch a click on it, and require a session.
    #
    # Asserting `openCounterexample` directly (which the first suite does)
    # proves the *call* works. It cannot prove the button is wired to it, and a
    # button wired to nothing is exactly what "built and unreachable" looks
    # like from the user's side.
    startCount()
    let vm = vmWith(SolverModelPayload)
    let session = createCounterexampleSessionVM()
    ck not session.isOpen.val

    let node = renderPanelLive(vm, session)
    let buttons = nodesWithAttributeValue(node, "data-ct-verification-action",
                                          "open-counterexample")
    ck buttons.len == 1                        # positive control on the scan
    fireEvent(buttons[0], "click")

    ck session.isOpen.val
    ck session.findingId.val == "f1"
    ck session.currentStep.val == 0
    ck session.stepCount.val == 4

    # And the *pure* render's button is inert rather than absent: the tree is
    # the same tree, the handler is nil, and dispatching on it must neither
    # open a session nor raise. That is what makes one template safe to serve
    # both entry points.
    let inert = createCounterexampleSessionVM()
    let pureNode = renderPanel(panelModel(vm))
    let pureButtons = nodesWithAttributeValue(
      pureNode, "data-ct-verification-action", "open-counterexample")
    ck pureButtons.len == 1
    fireEvent(pureButtons[0], "click")
    ck not inert.isOpen.val
    expectCount(8)

  test "clicking the controls walks the session, and a repaint follows it":
    # The other half of reachable: the controls in the mounted markup move the
    # session. `mountIsoNimCounterexampleSession` re-runs the render inside a
    # `createEffect`, so what a browser shows after a click is what a re-render
    # shows here.
    startCount()
    let session = sessionOn(SolverModelPayload, "f1")
    let first = renderSessionLive(session)
    ck nodesWithAttributeValue(first, "data-ct-counterexample-step-current",
                               "true").len == 1
    ck first.nodesWithAttribute("data-ct-counterexample-step").len == 4

    proc click(node: MockNode; action: string) =
      let hits = nodesWithAttributeValue(node,
        "data-ct-counterexample-action", action)
      doAssert hits.len == 1, action & ": expected exactly one control"
      fireEvent(hits[0], "click")

    click(first, "step-forward")
    ck session.currentStep.val == 1
    # The repaint: the current row moved with the session.
    let second = renderSessionLive(session)
    let current = nodesWithAttributeValue(second,
      "data-ct-counterexample-step-current", "true")
    ck current.len == 1
    ck current[0].attributes["data-ct-counterexample-step"] == "1"

    click(second, "continue")
    ck session.currentStep.val == 3
    let third = renderSessionLive(session)
    ck nodesWithAttributeValue(third, "data-ct-counterexample-step-current",
                               "true")[0]
        .attributes["data-ct-counterexample-step"] == "3"
    ck nodesWithAttributeValue(third, "data-ct-counterexample-step-violation",
                               "true").len == 1

    click(third, "step-backward")
    ck session.currentStep.val == 2
    expectCount(9)

  test "a payload with no model at all offers nothing, and says why":
    # The case most likely to be wrong, so it is asserted rather than reasoned
    # about. `not_proved_assertion.json` is attached and believed and its
    # counterexample has `model.status == unavailable`.
    #
    # What a developer sees: no button, and a sentence carrying the producer's
    # own recorded reason. An absent affordance with no explanation reads as a
    # missing feature; this reads as what it is.
    startCount()
    let vm = vmWith(NoModelPayload)
    let session = createCounterexampleSessionVM()
    ck vm.payloadStatus.val == psAttached      # positive control: it IS here
    let reason = modelIsAbsentBecause(decoded(NoModelPayload))
    ck reason.len > 0
    ck reason.contains("venir")                # the producer's own words

    let node = renderPanelLive(vm, session)
    ck nodesWithAttributeValue(node, "data-ct-verification-action",
                               "open-counterexample").len == 0
    ck nodesWithAttribute(node, "data-ct-verification-no-model").len == 1
    ck renderedText(node).contains(reason)
    ck renderedText(node).contains("No counterexample to step through")

    # The contrast arm, through the same renderer: a payload that DOES carry a
    # model has the button and no such sentence. Without this the check above
    # would pass over a panel that always prints the sentence.
    let withModel = renderPanelLive(vmWith(SolverModelPayload),
                                    createCounterexampleSessionVM())
    ck nodesWithAttribute(withModel, "data-ct-verification-no-model").len == 0
    ck nodesWithAttributeValue(withModel, "data-ct-verification-action",
                               "open-counterexample").len == 1
    expectCount(9)

  test "the live tree carries the same attribute NAMES as the pure one":
    # This check exists because of a bug it caught, and the bug was silent.
    #
    # `renderVerificationPanelImpl`'s parameters used to be named `model` and
    # `handlers`. Nim substitutes an `untyped` template argument wherever the
    # parameter's *identifier* appears — **including inside an accent-quoted
    # attribute name**, where `data-ct-verification-no-model` contains `model`
    # as a whole token. So the pure render (whose argument was itself called
    # `model`) emitted `data-ct-verification-no-model`, and the live render
    # (whose argument is a local called `m`) emitted
    # `data-ct-verification-no-m`.
    #
    # Nothing failed. Both trees rendered, both carried the right *text*, and
    # only an assertion on the attribute in the *live* tree could see it. The
    # parameters are now `mdl`/`hnd`, which are tokens no attribute name
    # contains — but the rename is a convention, and this check is what makes
    # it enforced.
    startCount()
    proc attributeNames(node: MockNode): seq[string] =
      var acc: seq[string] = @[]
      walk(node, proc(n: MockNode) =
        for name, _ in n.attributes:
          if name.startsWith("data-ct-") and name notin acc:
            acc.add name)
      acc.sort()
      acc

    # The verification panel, in the state that has every conditional block:
    # an attached payload with a steppable counterexample.
    let vm = vmWith(SolverModelPayload)
    let pureNames = attributeNames(renderPanel(panelModel(vm)))
    let liveNames = attributeNames(
      renderPanelLive(vm, createCounterexampleSessionVM()))
    ck pureNames.len > 0                       # positive control on the scan
    ck liveNames == pureNames

    # And the counterexample panel, whose template has the same hazard in
    # `data-ct-counterexample-model-status` and
    # `data-ct-counterexample-model-bindings`.
    let session = sessionOn(SolverModelPayload, "f1")
    let purePanel = attributeNames(renderSession(sessionModel(session)))
    let livePanel = attributeNames(renderSessionLive(session))
    ck purePanel.len > 0
    ck livePanel == purePanel
    ck "data-ct-counterexample-model-status" in livePanel
    ck "data-ct-counterexample-model-bindings" in livePanel

    # The no-model panel is a separate state and has its own block.
    let noModel = vmWith(NoModelPayload)
    ck "data-ct-verification-no-model" in
      attributeNames(renderPanelLive(noModel, createCounterexampleSessionVM()))
    expectCount(7)
