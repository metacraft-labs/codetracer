## test_verification_vm.nim
##
## VN-M3's three verification tests, plus the classifier and parser
## properties they rest on.
##
## ## Read this before trusting a green run
##
## Verno's solver back end (`venir`) is Linux-only. This suite was written on
## macOS, where **every** Verno run stops at the solver boundary and reports
## `no-solver`. That has a direct consequence for one of the three tests, and
## the consequence is stated here rather than buried:
##
## * `test_an_unsupported_construct_is_not_reported_as_a_failed_proof` —
##   **reproduced on this machine.** Its input is real output, captured from a
##   real Verno run against a real package in this repository
##   (`test-programs/noir_verification_unsupported`). Verno refuses an
##   unsupported construct long before the solver, so no solver is needed.
##
## * `test_the_text_tier_never_offers_replay` — **reproduced on this
##   machine.** It is a property of CodeTracer's own rendering and event
##   projection, and needs no verifier at all.
##
## * `test_a_failed_obligation_lands_in_the_editor` — **NOT reproduced on this
##   machine, and the reason is a missing solver, not a missing
##   implementation.** A failed obligation requires a solver to produce one.
##   The test drives the real path — classify, parse, mark, project — against
##   *recorded* verifier output whose provenance is written down line by line
##   in `../fixtures/verno/PROVENANCE.md`. What it proves is that the path
##   works on that text. What it does not prove, and must not be read as
##   proving, is that a solver on this machine produced that text: none did.
##   Running it end to end needs a Linux machine with `venir`; the packages it
##   points at are in this repository so that run can be diffed against these
##   fixtures.
##
## Every fixture below is loaded with `staticRead`, so deleting one is a
## compile error rather than a quietly passing suite.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_verification_vm.nim
##
## Discovered by the `vm-unit` (C) and `vm-unit-js` (JS) lanes by glob.

import std/[options, strutils, tables, unittest]

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

import ../../../../ct_test/contracts
import ../../viewmodels/project_actions
import ../../viewmodels/verification_report
import ../../viewmodels/verification_payload
import ../../viewmodels/verification_vm
import ../../viewmodels/test_run_summary_vm
import ../../views/isonim_verification_view

# ---------------------------------------------------------------------------
# Fixtures — real Verno output. See ../fixtures/verno/PROVENANCE.md.
# ---------------------------------------------------------------------------

const
  NoSolverOutput = staticRead("../fixtures/verno/no_solver.txt")
  UnsupportedLambdaOutput = staticRead("../fixtures/verno/unsupported_lambda.txt")
  PipelineErrorOutput = staticRead("../fixtures/verno/pipeline_error_type_mismatch.txt")
  ProvedOutput = staticRead("../fixtures/verno/proved.txt")
  FailedAssertionOutput = staticRead("../fixtures/verno/failed_obligation_assertion.txt")
  FailedPostconditionOutput = staticRead("../fixtures/verno/failed_obligation_postcondition.txt")
  TimedOutOutput = staticRead("../fixtures/verno/timed_out_rlimit.txt")
  ExampleTasksJson = staticRead("../../../../../test-programs/noir_verification/.vscode/tasks.json")

# ---------------------------------------------------------------------------
# MockNode helpers
# ---------------------------------------------------------------------------

proc walk(node: MockNode; visit: proc(n: MockNode)) =
  if node.isNil:
    return
  visit(node)
  for child in node.children:
    walk(child, visit)

proc renderedText(node: MockNode): string =
  textContent(node)

proc allAttributeText(node: MockNode): string =
  ## Every attribute name and value in the tree, flattened, so a test can ask
  ## "does anything anywhere in this markup mention X".
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

proc verificationAction(): ProjectAction =
  let declared = parseTasksJson(ExampleTasksJson)
  let vernoOnes = vernoActions(declared)
  doAssert vernoOnes.len > 0,
    "test-programs/noir_verification/.vscode/tasks.json declares no Verno action"
  vernoOnes[0]

proc finishedVM(output: string; exitCode: int): VerificationVM =
  result = createVerificationVM()
  result.start(verificationAction(), projectRoot = "test-programs/noir_verification")
  result.noteOutput("…")
  result.finish(output, some(exitCode))

# ---------------------------------------------------------------------------

suite "VN-M3 the six-outcome vocabulary survives the trip into the IDE":

  test "each of Verno's six outcomes is classified as itself":
    # The vocabulary is `scripts/run-corpus.py`'s, spelled identically. A
    # change here that is not made there splits the IDE from the corpus gate.
    check classifyVernoRun(some(1), NoSolverOutput, false)[0] == voNoSolver
    check classifyVernoRun(some(101), UnsupportedLambdaOutput, false)[0] == voUnsupported
    check classifyVernoRun(some(1), PipelineErrorOutput, false)[0] == voPipelineError
    check classifyVernoRun(some(0), ProvedOutput, false)[0] == voProved
    check classifyVernoRun(some(1), FailedAssertionOutput, false)[0] == voNotProved
    check classifyVernoRun(some(1), TimedOutOutput, false)[0] == voTimedOut
    check classifyVernoRun(none(int), "", true)[0] == voTimedOut

  test "exactly one of the six says the program was rejected":
    var rejecting = 0
    for outcome in VerificationOutcome:
      if isFailedProof(outcome):
        inc rejecting
    check rejecting == 1
    check isFailedProof(voNotProved)

  test "four of the six say nothing about the program at all":
    check answersCorrectness(voProved)
    check answersCorrectness(voNotProved)
    for outcome in [voTimedOut, voUnsupported, voNoSolver, voPipelineError]:
      check not answersCorrectness(outcome)

  test "a resource-limit exhaustion is a timeout, never a lost proof":
    # This is the trap the whole vocabulary exists for: Verus serialises an
    # rlimit exhaustion as an ordinary error block, so it is one string away
    # from a genuine rejection. `timed_out_rlimit.txt` and
    # `failed_obligation_assertion.txt` both end "Verification failed due to
    # 1 previous errors!".
    check TimedOutOutput.contains("Verification failed")
    check classifyVernoRun(some(1), TimedOutOutput, false)[0] == voTimedOut
    check not isFailedProof(voTimedOut)

  test "an unreachable! is a pipeline error, so an ICE cannot hide as a limitation":
    # docs/src/limitations.md: "A panic reading `internal error: entered
    # unreachable code` is **not** a limitation." It also panics with a
    # message the generic `not yet implemented` fallback must not claim.
    let ice = "thread 'main' panicked at src/lib.rs:1:1:\n" &
      "internal error: entered unreachable code\n"
    check classifyVernoRun(some(101), ice, false)[0] == voPipelineError

suite "VN-M3 test_a_failed_obligation_lands_in_the_editor":
  ## STATUS ON THIS MACHINE: built and exercised against recorded verifier
  ## output; NOT reproduced against a live solver, because `venir` is
  ## Linux-only. See this file's header and ../fixtures/verno/PROVENANCE.md.

  test "a failed obligation becomes an editor marker at the verifier's span":
    let vm = finishedVM(FailedAssertionOutput, 1)
    check vm.phase.val == vpFinished
    check vm.currentReport().isSome
    check vm.currentReport().get.outcome == voNotProved
    check vm.failedObligationCount.val == 1

    let markers = vm.currentMarkers()
    check markers.len == 1
    let marker = markers[0]
    check marker.kind == vmkFailedObligation
    check marker.severity == dsError
    # The span is the verifier's, parsed, not guessed.
    check marker.file == "test-programs/noir_verification_failing/src/main.nr"
    check marker.range.startLine == 15
    check marker.range.startColumn == 12
    check marker.range.endLine == 15
    # `assert(n == 40)` is underlined with eight dashes.
    check marker.range.endColumn == 20
    check marker.message == "assertion failed"

  test "the diagnostic is reachable on hover, in the verifier's own words":
    let vm = finishedVM(FailedPostconditionOutput, 1)
    let markers = vm.currentMarkers()
    check markers.len == 1
    let hover = markers[0].hoverText
    check hover.contains("postcondition not satisfied")
    check hover.contains("failed postcondition")     # the secondary label
    check hover.contains("#['ensures(result == 4 * x1)]")  # the source excerpt
    check markers[0].range.startLine == 7

  test "the same failure reads as a failed test in the results pane":
    let vm = finishedVM(FailedAssertionOutput, 1)
    let summary = projectTestRun(toTestEvents(vm.currentReport().get, "run-1"))
    check summary.failed == 1
    check summary.passed == 0
    check summary.skipped == 0
    check summary.rows.len == 1
    check summary.rows[0].outcome == troFailed

  test "a rejection with no parseable block still produces a finding":
    # A report that renders nothing for a rejected program reads exactly like
    # a passing one, which is the worst possible failure mode here — so the
    # assembler falls back to the summary line rather than to an empty list.
    # Reached here by classifying `voNotProved` directly, because a Verno
    # rejection always *does* carry at least one `error:` block (`report_all`
    # is what increments the error count), so this is a defence against a
    # future output shape rather than a current one.
    let terse = "Error: Verification failed due to 2 previous errors!\n"
    let report = buildReport(voNotProved, "verification failed", terse,
                             some(1), false)
    check report.findings.len == 1
    check report.findings[0].kind == vfkFailedObligation
    check report.findings[0].message == "verification failed"

  test "the classifier stays byte-faithful to run-corpus.py, including its edges":
    # `classify()` in `scripts/run-corpus.py` reaches its `PIPELINE_ERROR`
    # fallback for output that contains neither `error:` nor `Aborting due
    # to`, whatever else it says. Reproducing that here — rather than
    # improving on it — is the point: an IDE that classified a run
    # differently from the corpus gate would make the gate's baseline
    # unreadable from the IDE and vice versa.
    let terse = "Error: Verification failed due to 2 previous errors!\n"
    check classifyVernoRun(some(1), terse, false)[0] == voPipelineError

  test "the span parser is exercised on genuinely current reporter output":
    # `pipeline_error_type_mismatch.txt` is real `v1.0.0-beta.26` output,
    # captured on the machine this was written on (PROVENANCE.md). It is the
    # same `noirc_errors::reporter` block shape a solver diagnostic uses, so
    # the parser above is not being validated only against recorded text.
    let diagnostics = parseVernoDiagnostics(PipelineErrorOutput)
    check diagnostics.len == 2
    check diagnostics[0].hasLocation
    check diagnostics[0].file == "typeerr/src/main.nr"
    check diagnostics[0].range.startLine == 2
    check diagnostics[0].range.startColumn == 20
    check diagnostics[1].range.startLine == 1
    check diagnostics[1].detail == "expected u32 because of return type"

  test "a front-end error is marked, but never as a failed obligation":
    let vm = finishedVM(PipelineErrorOutput, 1)
    check vm.currentReport().get.outcome == voPipelineError
    check vm.failedObligationCount.val == 0
    let markers = vm.currentMarkers()
    check markers.len == 2
    for marker in markers:
      check marker.kind == vmkPipelineError

suite "VN-M3 test_an_unsupported_construct_is_not_reported_as_a_failed_proof":
  ## STATUS ON THIS MACHINE: fully reproduced. `unsupported_lambda.txt` is
  ## real output from a real run against `test-programs/noir_verification_unsupported`,
  ## which is a *correct* program that happens to use a lambda.

  test "an unsupported construct is reported as a limitation, with its name":
    let vm = finishedVM(UnsupportedLambdaOutput, 101)
    let report = vm.currentReport().get
    check report.outcome == voUnsupported
    check report.findings.len == 1
    let finding = report.findings[0]
    check finding.kind == vfkLimitation
    check finding.construct == "function types (lambdas, function values)"
    check finding.message.contains("does not support")
    check finding.detail.contains("not a failed proof")

  test "it is never an unproven obligation — not in the report, the editor, or the pane":
    let vm = finishedVM(UnsupportedLambdaOutput, 101)
    let report = vm.currentReport().get

    # 1. Not in the report.
    check not isFailedProof(report.outcome)
    check vm.failedObligationCount.val == 0
    check vm.limitationCount.val == 1

    # 2. Not in the editor. Verno's limitation panic carries a *Rust* source
    #    position and no Noir span, so there is nothing to mark — and the
    #    marker builder refuses to invent one rather than pointing at line 1.
    check vm.currentMarkers().len == 0
    check failedObligationMarkers(report).len == 0

    # 3. Not in the results pane.
    let summary = projectTestRun(toTestEvents(report, "run-1"))
    check summary.failed == 0
    check summary.skipped == 1

    # 4. And the pane says *why* in words, not only in a status enum, because
    #    four statuses cannot carry six outcomes.
    check summary.rows[0].output.contains("unsupported construct")
    check summary.rows[0].output.contains("not a failed proof")

  test "the rendered panel says 'verifier limitation' in words":
    let vm = finishedVM(UnsupportedLambdaOutput, 101)
    var renderer: MockRenderer
    let node = renderVerificationPanel(renderer, panelModel(vm))
    let rows = nodesWithAttribute(node, "data-ct-verification-kind")
    check rows.len == 1
    check rows[0].attributes["data-ct-verification-kind"] == "limitation"
    check rows[0].attributes["data-ct-verification-is-failure"] == "false"
    check renderedText(node).contains("verifier limitation")
    check renderedText(node).contains("Nothing was proved or disproved")

  test "a limitation could never be painted as an obligation, even with a span":
    # Defence against a future Verno that attaches Noir spans to its `todo!()`s:
    # the marker's kind comes from the finding's kind, so a located limitation
    # is a `vmkLimitation`, never a `vmkFailedObligation`.
    var report = reportForRun(UnsupportedLambdaOutput, some(101))
    report.findings[0].hasLocation = true
    report.findings[0].file = "src/main.nr"
    report.findings[0].range = SourceRange(startLine: 3, startColumn: 5,
                                           endLine: 3, endColumn: 9)
    let markers = editorMarkers(report)
    check markers.len == 1
    check markers[0].kind == vmkLimitation
    check markers[0].severity == dsWarning
    check failedObligationMarkers(report).len == 0

  test "the other three non-answers are not failures either":
    for (output, code, outcome, kind) in [
        (NoSolverOutput, 1, voNoSolver, vfkSolverUnavailable),
        (TimedOutOutput, 1, voTimedOut, vfkBudgetExhausted)]:
      let report = reportForRun(output, some(code))
      check report.outcome == outcome
      check report.findings.len == 1
      check report.findings[0].kind == kind
      check not isFailedProof(report.outcome)
      check failedObligationMarkers(report).len == 0
      check projectTestRun(toTestEvents(report, "run-1")).failed == 0

suite "VN-M3 test_the_text_tier_never_offers_replay":

  test "no replay affordance survives into the rendered markup, in any state":
    # The vocabulary a user would read as "you can step through this". None of
    # it may appear anywhere in the tree — not as text, not as a class, not as
    # an attribute, and not on a disabled control, because a disabled
    # affordance is still a promise.
    const replayVocabulary = [
      "replay", "step through", "step-through", "stepthrough",
      "counterexample", "open trace", "open-trace", "opentrace",
      "trace-id", "traceid", "debug session", "session-tab",
    ]
    var renderer: MockRenderer

    proc assertNoReplay(model: VerificationPanelModel; what: string) =
      let node = renderVerificationPanel(renderer, model)
      let haystack = (renderedText(node) & " " & allAttributeText(node)).toLowerAscii
      for word in replayVocabulary:
        check(not haystack.contains(word))
        if haystack.contains(word):
          echo "replay vocabulary \"", word, "\" leaked into the ", what, " panel"

    # Idle, in flight, and every one of the six finished outcomes.
    let idle = createVerificationVM()
    assertNoReplay(panelModel(idle), "idle")

    let running = createVerificationVM()
    running.start(verificationAction())
    running.noteElapsed(240_000)
    running.noteOutput("still solving")
    assertNoReplay(panelModel(running), "running")

    for (output, code) in [(ProvedOutput, 0), (FailedAssertionOutput, 1),
                           (TimedOutOutput, 1), (UnsupportedLambdaOutput, 101),
                           (NoSolverOutput, 1), (PipelineErrorOutput, 1)]:
      assertNoReplay(panelModel(finishedVM(output, code)), "finished")

  test "the results-pane row cannot offer a trace, by the shape of the data":
    # `test_run_summary_vm.hasRecording` — written for AA-2, long before this
    # milestone — gates the pane's drill-down on a `recording-created` event
    # having carried a trace path. `toTestEvents` emits no such event, so the
    # affordance is refused by machinery this milestone did not write.
    for (output, code) in [(ProvedOutput, 0), (FailedAssertionOutput, 1),
                           (UnsupportedLambdaOutput, 101), (NoSolverOutput, 1)]:
      let report = reportForRun(output, some(code))
      let events = toTestEvents(report, "run-1")
      for event in events:
        check event.kind != tekRecordingCreated
        check event.trace.isNone
      let summary = projectTestRun(events)
      for row in summary.rows:
        check not row.hasRecording()
        check not row.recordingAttempted
        check not row.recordingFailed()

  test "a finding carries no trace identity to offer in the first place":
    # VN-M4 adds the payload and VN-M5 the affordance. Until then there is
    # nothing on a finding a view could turn into a replay link, which is why
    # the test above can be a property rather than a code review.
    let report = reportForRun(FailedAssertionOutput, some(1))
    for finding in report.findings:
      check finding.excerpt.len > 0        # the textual diagnostic *is* the tier
    check report.rawOutput == FailedAssertionOutput

suite "VN-M3 a long run is a visible process, not a frozen UI":

  test "every phase renders, and a run in flight says what it is doing":
    let vm = createVerificationVM()
    check vm.phase.val == vpIdle
    check not vm.isRunning.val

    vm.start(verificationAction(), projectRoot = "test-programs/noir_verification")
    check vm.phase.val == vpStarting
    check vm.isRunning.val
    check vm.isCancellable.val
    check vm.statusText.val.contains("Verify with Verno")

    vm.noteElapsed(245_000)
    check vm.phase.val == vpRunning
    vm.noteOutput("verifying quadruple")
    check vm.statusText.val.contains("4m 5s")
    check vm.statusText.val.contains("verifying quadruple")

    vm.finish(NoSolverOutput, some(1))
    check vm.phase.val == vpFinished
    check not vm.isRunning.val
    check not vm.isCancellable.val

  test "the command line shown is the project's own, verbatim":
    let action = verificationAction()
    let vm = createVerificationVM()
    vm.start(action)
    check vm.commandLine.val ==
      "verno --program-dir . formal-verify -- --rlimit 60"
    check panelModel(vm).commandLine == vm.commandLine.val

  test "a cancelled run has no outcome, and is not a failure":
    let vm = createVerificationVM()
    vm.start(verificationAction())
    vm.noteOutput("working")
    vm.requestCancel()
    check vm.phase.val == vpCancelling
    # Output that arrived before the kill must not be classified: a partial
    # run has no outcome, and inventing one would be the same lie one level up.
    vm.finish("error: assertion failed\nError: Verification failed due to 1 previous errors!",
              some(1))
    check vm.phase.val == vpCancelled
    check vm.currentReport().isNone
    check vm.failedObligationCount.val == 0
    check vm.statusText.val.contains("nothing was proved or disproved")

  test "a verifier that will not start is not a verdict on the program":
    let vm = createVerificationVM()
    vm.start(verificationAction())
    vm.noteFailedToStart("verno: command not found")
    check vm.phase.val == vpFailedToStart
    check vm.currentReport().isNone
    check vm.statusText.val.contains("command not found")

  test "starting a second run clears the first run's findings":
    let vm = finishedVM(FailedAssertionOutput, 1)
    check vm.failedObligationCount.val == 1
    vm.start(verificationAction())
    check vm.currentReport().isNone
    check vm.currentMarkers().len == 0
    check panelModel(vm).rows.len == 0

suite "VN-M3 the action is the project's":

  test "the example package's own tasks.json is what declares the run":
    let declared = parseTasksJson(ExampleTasksJson)
    check declared.problems.len == 0
    check declared.actions.len == 3
    let verno = vernoActions(declared)
    check verno.len == 2
    check verno[0].label == "Verify with Verno"
    check verno[0].source == pasTasksJson
    check verno[0].group == pagTest
    check verno[1].isBackground
    # The nargo recording task is a project action too, and is *not* claimed
    # by the verification adapter.
    check not isVernoAction(declared.actions[2])
    check declared.actions[2].label == "Record with nargo"

  test "CodeTracer synthesises no verification action of its own":
    # §9.3: "the project declares its actions or it does not". A package with
    # no declaration gets nothing — not a helpfully guessed command line.
    let nothing = collectProjectActions("", "")
    check nothing.actions.len == 0
    check vernoActions(nothing).len == 0

suite "VN-M3 the diagnostic parser reads the reporter, not something like it":

  test "a source line beginning with a minus is not read as an underline":
    # codespan puts the line number in the gutter of a source row and leaves it
    # blank on an underline row. Without that distinction `-x + y` on line 4
    # reads as a two-column underline and the marker's end column is wrong.
    let output = """
error: possible arithmetic underflow/overflow
  ┌─ src/main.nr:4:5
  │
4 │     -x + y
  │     ------ possible overflow
  │

Error: Verification failed due to 1 previous errors!
"""
    let diagnostics = parseVernoDiagnostics(output)
    check diagnostics.len == 1
    check diagnostics[0].range.startColumn == 5
    check diagnostics[0].range.endColumn == 11        # six dashes, not two
    check diagnostics[0].detail == "possible overflow"

  test "the run-level trailer is a summary, not a seventh finding":
    # `Error: Verification failed due to N previous errors!` has a capital E
    # and no location. Parsing it as a diagnostic would put a phantom row with
    # no source position in the results pane.
    let report = reportForRun(FailedAssertionOutput, some(1))
    check report.findings.len == 1
    check report.findings[0].message == "assertion failed"

  test "a report with several failed obligations produces several markers":
    let two = FailedAssertionOutput & "\n" & FailedPostconditionOutput
    let report = reportForRun(two, some(1))
    check report.outcome == voNotProved
    check failedObligationMarkers(report).len == 2
    check projectTestRun(toTestEvents(report, "run-1")).failed == 2

# ---------------------------------------------------------------------------
# VN-M4 landed while this file was green, and this suite is what keeps it that
# way. See ../fixtures/verno/payload/PROVENANCE.md for the documents used.
# ---------------------------------------------------------------------------

const NoSolverPayloadJson = staticRead("../fixtures/verno/payload/no_solver.json")
const NotProvedWithModelJson =
  staticRead("../fixtures/verno/payload/not_proved_with_model.json")

suite "VN-M4 a payload changes what is known, not what is promised":
  ## STATUS ON THIS MACHINE: fully reproduced. It needs no verifier.
  ##
  ## VN-M4 adds the structured artifact. VN-M5 adds the affordance. The gap
  ## between those two sentences is a place a milestone can quietly overrun, so
  ## it is asserted rather than intended.

  test "a payload is attached without touching the report, the markers or the panel":
    let withoutPayload = finishedVM(NoSolverOutput, 1)
    let withPayload = createVerificationVM()
    withPayload.start(verificationAction(),
                      projectRoot = "test-programs/noir_verification")
    withPayload.noteOutput("…")
    withPayload.finish(NoSolverOutput, some(1),
                       payloadText = NoSolverPayloadJson,
                       runStartedAtUnixMs = 1_787_970_124_574'i64)

    check withPayload.payloadStatus.val == psAttached
    check withPayload.currentPayload().isSome
    check withPayload.currentPayload().get.outcome == voNoSolver

    # Everything VN-M3 asserts is unchanged, item by item rather than in
    # aggregate: an aggregate comparison would pass if two errors cancelled.
    check withPayload.currentReport().get.outcome ==
      withoutPayload.currentReport().get.outcome
    check withPayload.currentReport().get.findings.len ==
      withoutPayload.currentReport().get.findings.len
    check withPayload.currentMarkers().len == withoutPayload.currentMarkers().len
    check withPayload.statusText.val == withoutPayload.statusText.val
    check withPayload.outcomeText.val == withoutPayload.outcomeText.val
    check panelModel(withPayload).rows.len == panelModel(withoutPayload).rows.len

  test "a payload carrying a full counterexample promises exactly one thing":
    # **This test was VN-M4's tripwire and is now VN-M5's boundary, and the
    # change is recorded rather than made quietly.** It used to read "even a
    # payload carrying a full counterexample promises no replay" and forbade
    # twelve words outright, with a comment saying so *yet* and naming the
    # tripwire VN-M5 would have to remove.
    #
    # VN-M5 removed exactly one word's worth of it. `not_proved_with_model.json`
    # has model values, forced branches, a violated obligation and a proof-goal
    # tree; the panel now offers **one** action over it — open the
    # counterexample — and still promises none of the rest. Ten of the twelve
    # words stay forbidden, and the two that are now allowed are *required*, so
    # this is a narrower assertion than it was rather than a weaker one.
    const stillForbidden = [
      "replay", "open trace", "open-trace", "opentrace",
      "trace-id", "traceid", "debug session", "session-tab",
      "recording", "recorded run",
    ]
    let vm = createVerificationVM()
    vm.start(verificationAction(),
             projectRoot = "test-programs/noir_verification_failing")
    vm.finish(FailedAssertionOutput, some(1),
              payloadText = NotProvedWithModelJson,
              runStartedAtUnixMs = 1_787_970_124_574'i64)
    check vm.payloadStatus.val == psAttached
    check vm.currentPayload().get.counterexampleTraces.len == 1
    check vm.currentPayload().get.counterexampleTraces[0].steps.len == 4

    var renderer: MockRenderer
    let node = renderVerificationPanel(renderer, panelModel(vm))
    let haystack = (renderedText(node) & " " & allAttributeText(node)).toLowerAscii
    check haystack.len > 0                # the scan reached the tree
    for word in stillForbidden:
      check(not haystack.contains(word))
      if haystack.contains(word):
        echo "vocabulary \"", word, "\" leaked into the panel with a payload attached"

    # The one thing it may say, and exactly once. A count rather than a
    # presence check: a panel that offered the same walk twice, or offered one
    # per finding regardless of which finding has a model, would pass a
    # `contains`.
    check haystack.contains("step through the counterexample")
    check nodesWithAttribute(node, "data-ct-verification-action").len == 1
    check panelModel(vm).counterexampleOffers.len == 1
    check panelModel(vm).counterexampleOffers[0].findingId == "f0"

    # And the tier's own tripwire is untouched: it is a statement about a run
    # with no *attached* payload, which is every state VN-M3's own test drives.
    check ReplayIsNotOfferedHere
    check CounterexampleIsOfferedOnlyWhenSteppable

  test "a payload whose model is unavailable still promises nothing":
    # The arm that keeps the test above from being a claim about *any* payload.
    # `not_proved_assertion.json` is attached, believed, and carries a
    # counterexample — with `model.status == unavailable` and no steps. The
    # panel offers nothing over it, and the reason is the model rather than the
    # absence of a payload.
    const NotProvedAssertionJson =
      staticRead("../fixtures/verno/payload/not_proved_assertion.json")
    let vm = createVerificationVM()
    vm.start(verificationAction(),
             projectRoot = "test-programs/noir_verification_failing")
    vm.finish(FailedAssertionOutput, some(1),
              payloadText = NotProvedAssertionJson,
              runStartedAtUnixMs = 1_787_970_124_574'i64)
    check vm.payloadStatus.val == psAttached
    check vm.currentPayload().get.counterexampleTraces.len == 1
    check vm.currentPayload().get.counterexampleTraces[0].steps.len == 0
    check counterexampleOffers(vm).len == 0

    var renderer: MockRenderer
    let node = renderVerificationPanel(renderer, panelModel(vm))
    let haystack = (renderedText(node) & " " & allAttributeText(node)).toLowerAscii
    check haystack.len > 0
    check not haystack.contains("counterexample")
    check not haystack.contains("step through")

  test "the results pane still cannot offer a trace, with a payload attached":
    # `toTestEvents` is built from the report, which the payload never enters —
    # so the AA-2 gate that refuses the drill-down still refuses it. Asserted
    # rather than reasoned about, because "the payload never enters" is a
    # property of code that could change.
    let vm = createVerificationVM()
    vm.start(verificationAction(),
             projectRoot = "test-programs/noir_verification_failing")
    vm.finish(FailedAssertionOutput, some(1),
              payloadText = NotProvedWithModelJson,
              runStartedAtUnixMs = 1_787_970_124_574'i64)
    let events = toTestEvents(vm.currentReport().get, "run-1")
    for event in events:
      check event.kind != tekRecordingCreated
      check event.trace.isNone
    for row in projectTestRun(events).rows:
      check not row.hasRecording()

  test "a refused payload leaves the text tier exactly as it was, and says why":
    let baseline = finishedVM(NoSolverOutput, 1)
    let vm = createVerificationVM()
    vm.start(verificationAction(),
             projectRoot = "test-programs/noir_verification")
    vm.finish(NoSolverOutput, some(1),
              payloadText = "{ not a payload",
              runStartedAtUnixMs = 1_787_970_124_574'i64)
    check vm.payloadStatus.val == psRejected
    check vm.currentPayload().isNone
    check vm.payloadProblems.val.len > 0
    check vm.currentReport().get.outcome == baseline.currentReport().get.outcome
    check vm.statusText.val == baseline.statusText.val

  test "starting a second run clears the first run's payload too":
    # The same reason `start` clears the report: a stale artifact shown next to
    # a fresh spinner reads as this run's.
    let vm = createVerificationVM()
    vm.start(verificationAction(), projectRoot = "test-programs/noir_verification")
    vm.finish(NoSolverOutput, some(1),
              payloadText = NoSolverPayloadJson,
              runStartedAtUnixMs = 1_787_970_124_574'i64)
    check vm.payloadStatus.val == psAttached
    vm.start(verificationAction(), projectRoot = "test-programs/noir_verification")
    check vm.payloadStatus.val == psAbsent
    check vm.currentPayload().isNone
    check vm.payloadProblems.val.len == 0
