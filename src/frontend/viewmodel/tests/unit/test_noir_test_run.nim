## Headless tests for `nargo test` IN THE BROWSER — the wire shape, the event
## conversion, and what the two panes end up showing.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_noir_test_run.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_noir_test_run.nim
##
## ## THE ONE FAILURE THIS SUITE EXISTS AGAINST
##
## `#[test(should_fail)]` inverts the verdict: an assertion that FIRES is a
## pass, and a test that runs clean is a failure. Get it backwards and the pane
## reports the suite in reverse — every green row red and every red row green —
## which is worse than not running the tests at all, because a user acts on it.
##
## A tally cannot catch that. Two passes and two failures is also what a runner
## that inverted BOTH attributes reports, and what one that inverted neither
## reports over a different program. So every case below asserts PER TEST, by
## name, and the fixture is deliberately four-way: pass, fail, expected-fail,
## and unexpected-pass. `compiler/wasm/src/test_vfs.rs` asserts the same four
## shapes against the real compiler, in Rust; this suite asserts that nothing
## between that module and the pane re-decides them.
##
## The fixture JSON is the real module's own output. It was captured by
## instantiating `noir_wasm.wasm` (16438462 bytes, sha256 24ae65251edbf069) in
## node with every import stubbed to throw and calling `nv_test_vfs` over a
## four-test program — which is why `message` is the bare `"Failed assertion"`
## and the user's own string is in `diagnostic.message`. A hand-written fixture
## would have put the assertion text in `message`, because that is where a
## reader expects it, and the pane would then have shown "Failed assertion" for
## every failure in production while this suite stayed green.

import std/[options, strutils, unittest]

import isonim/core/[signals, computation]
import std/json

import ../../backend/backend_service
import ../../backend/replay_session_service
import ../../platform/noir_build
import ../../platform/process
import ../../store/replay_data_store
import ../../store/types
import ../../viewmodels/build_vm
import ../../viewmodels/noir_build_producer
import ../../viewmodels/noir_test_run
import ../../viewmodels/test_results_vm
import ../../../../ct_test/contracts
import ../../../../ct_test/frameworks/noir_test_syntax

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 169
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Fixtures — the module's own answers, captured
# ---------------------------------------------------------------------------

const FourWays = """
{"ok":true,"tests":[
 {"name":"fails","status":"fail","message":"Failed assertion","should_fail":false,
  "has_arguments":false,"file":"app/src/main.nr","line":10,"column":4,
  "diagnostic":{"message":"Assertion failed: one is not two","file":"app/src/main.nr",
                "line":11,"column":5,"end_line":11,"end_column":30,
                "start":120,"end":145,"severity":"error"}},
 {"name":"fails_as_asked","status":"pass","should_fail":true,
  "has_arguments":false,"file":"app/src/main.nr","line":15,"column":4},
 {"name":"passes","status":"pass","should_fail":false,
  "has_arguments":false,"file":"app/src/main.nr","line":5,"column":4},
 {"name":"passes_when_it_should_not","status":"fail",
  "message":"error: Test passed when it should have failed","should_fail":true,
  "has_arguments":false,"file":"app/src/main.nr","line":20,"column":4}
],"passed":2,"failed":2,"skipped":0}
"""
  ## `nv_test_vfs` over a program with one of each. Note what is ABSENT: a
  ## passing test carries no `message` and no `diagnostic` key at all
  ## (`skip_serializing_if` on the Rust side), so a decoder that indexed rather
  ## than probed would raise on the two green rows.

const ShouldFailWith = """
{"ok":true,"tests":[
 {"name":"right_message","status":"pass","should_fail":true,
  "expected_failure":"not two","has_arguments":false,
  "file":"app/src/main.nr","line":5,"column":4},
 {"name":"wrong_message","status":"fail","should_fail":true,
  "expected_failure":"some other reason","has_arguments":false,
  "message":"\nerror: Test failed with the wrong message. \nExpected: some other reason \nGot: one is not two",
  "file":"app/src/main.nr","line":10,"column":4}
],"passed":1,"failed":1,"skipped":0}
"""

const CheckRefused = """
{"ok":false,"stage":"check","kind":"check-error",
 "message":"the project did not compile: 1 diagnostic(s)",
 "diagnostics":[{"message":"cannot find `no_such_function` in this scope",
                 "file":"app/src/main.nr","line":5,"column":5,
                 "end_line":5,"end_column":21,"start":40,"end":56,
                 "severity":"error"}],
 "passed":0,"failed":0,"skipped":0}
"""

const MissingManifest = """
{"ok":false,"stage":"resolve","kind":"missing-manifest",
 "message":"no Nargo.toml at app/Nargo.toml","manifest":"app/Nargo.toml",
 "passed":0,"failed":0,"skipped":0}
"""

const FuzzHarness = """
{"ok":true,"tests":[
 {"name":"takes_an_argument","status":"skipped","should_fail":false,
  "output":"skipped: this test takes arguments, so `nargo test` fuzzes it.\n",
  "has_arguments":true,"file":"app/src/main.nr","line":5,"column":4}
],"passed":0,"failed":0,"skipped":1}
"""

const NoTests = """{"ok":true,"passed":0,"failed":0,"skipped":0}"""

const Recorded = """
{"ok":true,"passed":0,"failed":0,"skipped":0,
 "artifact":{"noir_version":"1.0.0","hash":123,"abi":{"parameters":[]},
             "bytecode":"H4sI","debug_symbols":"eJw","file_map":{}}}
"""
  ## `nv_test_vfs` with `record` set. NO `tests` KEY AT ALL — a recording runs
  ## nothing — and an `artifact` where a run has none. The two shapes have to be
  ## told apart by which field is present, not by `ok`, which is `true` for both.

const RecordRefused = """
{"ok":false,"stage":"request","kind":"no-such-test",
 "message":"`no_such_test` is not a test in this package",
 "passed":0,"failed":0,"skipped":0}
"""

const RecordedWithoutArtifact = """
{"ok":true,"passed":0,"failed":0,"skipped":0}
"""
  ## THE PROTOCOL FAULT: the module says the compile succeeded and answers
  ## nothing to trace. Indistinguishable from `NoTests` in every field, which is
  ## why the producer has to know which PHASE it is in — and why a caller that
  ## went on to trace `null` would fail one layer down with a message naming the
  ## tracer instead of this.

proc stubStore(): ReplayDataStore =
  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) = resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut
  createReplayDataStore(BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard))

proc fixture(): NoirBuildProducer =
  newNoirBuildProducer(createBuildVM(stubStore()),
                       projectRoot = "/app", packageDir = "app")

proc runPhase(producer: NoirBuildProducer; phase: NoirBuildPhase;
              stdout: string; exitCode: int): NoirPhaseVerdict =
  producer.beginPhase(phase, "nargo test", 1000.0)
  if stdout.len > 0:
    producer.onOutput(ProcessOutputChunk(stream: psStdout, text: stdout))
  producer.onExit(ProcessExit(exitCode: exitCode, signalled: false))

proc runTestPhase(producer: NoirBuildProducer; stdout: string;
                  exitCode: int): NoirPhaseVerdict =
  producer.beginPhase(nbpTest, "nargo test", 1000.0)
  if stdout.len > 0:
    producer.onOutput(ProcessOutputChunk(stream: psStdout, text: stdout))
  producer.onExit(ProcessExit(exitCode: exitCode, signalled: false))

proc outcomeNamed(response: NoirTestResponse; name: string): NoirTestOutcome =
  for outcome in response.tests:
    if outcome.name == name: return outcome
  raise newException(ValueError, "no outcome named " & name)

proc rowNamed(vm: TestResultsVM; selector: string): TestResultsRow =
  for row in vm.rows.val:
    if row.selector == selector or row.testId.endsWith("::" & selector):
      return row
  raise newException(ValueError, "no row for " & selector)

proc paneText(producer: NoirBuildProducer): string =
  var parts: seq[string] = @[]
  for line in producer.vm.output.val:
    parts.add line.htmlText
  parts.join("\n")

# ---------------------------------------------------------------------------

suite "the request the wasm module is given":

  test "a test request carries the tree, the package and no mode":
    # `mode` is `nv_compile_vfs`'s field and MUST NOT appear here: `nargo test`
    # compiles with `CompileOptions::default()`, and a request that asked for
    # `debug` would run an instrumented program — a different program from the
    # one the user tests locally, and two runners disagreeing about one suite
    # is the outcome this whole path exists to avoid.
    let files = @[
      NoirSourceEntry(path: "app/Nargo.toml", content: "[package]\n"),
      NoirSourceEntry(path: "app/src/main.nr", content: "fn main() {}\n")]
    let request = noirTestRequest(files, "app")
    counted request["package_dir"].getStr == "app"
    counted request["files"]["app/src/main.nr"].getStr == "fn main() {}\n"
    counted request["files"].len == 2
    counted not request.hasKey("mode")
    counted request["tests"].len == 0

    # A SELECTION is exact names — `nargo test --exact`'s own strings.
    let one = noirTestRequest(files, "app", @["tests::test_main"])
    counted one["tests"].len == 1
    counted one["tests"][0].getStr == "tests::test_main"

    # The args route the worker. One non-flag token, which is what
    # `args.find(a => !a.startsWith('-'))` selects on both workers.
    counted noirTestArgs() == @["test"]
    counted noirTestSubcommand == "test"
    counted noirTestArgs() != noirCompileArgs()
    counted noirTestArgs() != noirTraceArgs()

suite "decoding what the module answered":

  test "the four verdicts survive decoding, per test and not as a tally":
    let response = parseNoirTestResponse(FourWays)
    counted response.decoded
    counted response.ok
    counted response.tests.len == 4
    counted response.passed == 2
    counted response.failed == 2
    counted response.skipped == 0

    counted outcomeNamed(response, "passes").status == ntsPass
    counted outcomeNamed(response, "fails").status == ntsFail

    # THE INVERSION, BOTH DIRECTIONS. A `should_fail` test whose assertion
    # fired is a PASS; one that ran clean is a FAILURE. Decoded, never
    # recomputed — there is no arm anywhere below `nargo::ops` that reads
    # `shouldFail` to decide a status.
    let asked = outcomeNamed(response, "fails_as_asked")
    counted asked.status == ntsPass
    counted asked.shouldFail
    let unexpected = outcomeNamed(response, "passes_when_it_should_not")
    counted unexpected.status == ntsFail
    counted unexpected.shouldFail
    counted "should have failed" in unexpected.message

    # ABSENT-NOT-EMPTY, probed rather than indexed. A passing test carries no
    # `message` and no `diagnostic`, and the decoder must survive that.
    counted outcomeNamed(response, "passes").message.len == 0
    counted not outcomeNamed(response, "passes").hasDiagnostic

    # The user's own assertion text is in the DIAGNOSTIC and not in `message`.
    # That asymmetry is nargo's; a pane that read only `message` would show
    # "Failed assertion" for every failure in the product.
    let failed = outcomeNamed(response, "fails")
    counted failed.message == "Failed assertion"
    counted failed.hasDiagnostic
    counted "one is not two" in failed.diagnostic.message
    counted failed.diagnostic.line == 11
    counted failed.line == 10
    counted failed.diagnostic.line != failed.line

    # And `noirTestFailureText` joins them, so neither half is lost.
    counted "Failed assertion" in noirTestFailureText(failed)
    counted "one is not two" in noirTestFailureText(failed)

  test "a should_fail_with mismatch is a failure and says the message was wrong":
    let response = parseNoirTestResponse(ShouldFailWith)
    counted response.ok
    let right = outcomeNamed(response, "right_message")
    counted right.status == ntsPass
    counted right.expectedFailure == "not two"
    counted noirTestExpectationNote(right) == "expected to fail with `not two`"

    let wrong = outcomeNamed(response, "wrong_message")
    counted wrong.status == ntsFail
    counted "wrong message" in wrong.message
    # The distinction a runner that only checked "did it fail" would lose: this
    # test DID fail, and it still does not pass.
    counted wrong.shouldFail

  test "a refused run is not an empty green run":
    # `ok` means THE SUITE RAN. A response with `ok: false` and zero tests must
    # never read as "everything passed"; it is the outcome a pane most needs to
    # tell apart from a red suite.
    let refused = parseNoirTestResponse(CheckRefused)
    counted refused.decoded
    counted not refused.ok
    counted refused.stage == "check"
    counted refused.kind == "check-error"
    counted refused.diagnostics.len == 1
    counted refused.diagnostics[0].line == 5
    counted refused.tests.len == 0

    let missing = parseNoirTestResponse(MissingManifest)
    counted not missing.ok
    counted missing.stage == "resolve"
    counted missing.manifest == "app/Nargo.toml"

    # A GREEN suite and a REFUSED one differ in `ok`, not only in the tally.
    let green = parseNoirTestResponse(NoTests)
    counted green.ok
    counted green.tests.len == 0
    counted green.ok != refused.ok

  test "a response that is not a test response is reported as undecodable":
    # Third outcome, and it exists because a `VfsResponse` from a `compile`
    # would otherwise decode here as a green run of zero tests.
    let compileResponse = parseNoirTestResponse(
      """{"ok":true,"plan":{},"artifact":{}}""")
    counted not compileResponse.decoded
    counted not compileResponse.ok
    counted compileResponse.raw.len > 0
    counted not parseNoirTestResponse("not json at all").decoded
    counted not parseNoirTestResponse("").decoded
    # CONTROL: the real shape does decode, so the check above is about the
    # shape and not about the decoder refusing everything.
    counted parseNoirTestResponse(FourWays).decoded

suite "what the BUILD pane shows":

  test "every verdict reaches the pane, and a failure carries its position":
    let producer = fixture()
    let verdict = runTestPhase(producer, FourWays, exitCode = 1)
    # A red suite is `npvRefused` — the toolchain answered and the user has
    # something to fix — and never `npvFaulted`, which means nothing was
    # established.
    counted verdict == npvRefused

    let text = paneText(producer)
    for name in ["passes", "fails", "fails_as_asked",
                 "passes_when_it_should_not"]:
      counted name in text
    counted "one is not two" in text
    counted "2 passed, 2 failed" in text

    # `expected to fail` is SAID, not silently applied: a green row under that
    # attribute means the opposite of what a green row usually means.
    counted "expected to fail" in text

    # The failing assertion is a PROBLEM with a jump target, through the same
    # path a compile diagnostic takes — the reason this pane was chosen rather
    # than a new one.
    let problems = producer.vm.problems.val
    counted problems.len >= 1
    var foundAssertion = false
    for problem in problems:
      if "one is not two" in problem.message:
        foundAssertion = true
        counted problem.path == "/app/src/main.nr"
        counted problem.line == 11
        counted problem.severity == blsError
    counted foundAssertion

  test "a green suite succeeds and a suite with no tests says so":
    let producer = fixture()
    let verdict = runTestPhase(producer, ShouldFailWith, exitCode = 1)
    counted verdict == npvRefused
    counted producer.lastTests.failed == 1

    let green = fixture()
    let greenVerdict = runTestPhase(green, NoTests, exitCode = 0)
    counted greenVerdict == npvSucceeded
    # A PROJECT WITH NO TESTS IS NOT A GREEN SUITE, and a tally of zeroes
    # renders identically to one. The pane says which it was.
    counted "declares no tests" in paneText(green)
    counted "0 passed" notin paneText(green)

  test "a refused run paints the refusal, not an empty pane":
    let producer = fixture()
    let verdict = runTestPhase(producer, CheckRefused, exitCode = 1)
    counted verdict == npvRefused
    let text = paneText(producer)
    counted "no_such_function" in text
    counted "did not compile" in text
    counted producer.lastTests.tests.len == 0

    # A resolve refusal carries ZERO diagnostics and one positioned message,
    # so a pane that painted only `diagnostics` would show nothing at all for
    # the most likely first-run mistake.
    let missing = fixture()
    counted runTestPhase(missing, MissingManifest, exitCode = 1) == npvRefused
    counted "Nargo.toml" in paneText(missing)
    counted missing.vm.problems.val.len == 1
    counted missing.vm.problems.val[0].path == "/app/Nargo.toml"

  test "an undecodable answer is a fault, not a failing suite":
    let producer = fixture()
    let verdict = runTestPhase(producer, "{\"ok\":true}", exitCode = 0)
    counted verdict == npvFaulted
    counted "protocol fault" in paneText(producer)
    counted "not a fault in your tests" in paneText(producer)

  test "a new run does not show the previous one's verdicts":
    let producer = fixture()
    discard runTestPhase(producer, FourWays, exitCode = 1)
    counted producer.lastTests.tests.len == 4
    discard runTestPhase(producer, NoTests, exitCode = 0)
    counted producer.lastTests.tests.len == 0
    counted "passes_when_it_should_not" notin paneText(producer)

suite "what the TEST RESULTS pane shows":

  test "a run joins onto the catalog by selector and inverts nothing":
    # The catalog the browser's parser produces for the same sources, so the
    # join is over the ids the product actually uses.
    let sources = @[NoirSourceFile(path: "src/main.nr", content: """
fn main() {}

#[test]
fn passes() { assert(1 == 1); }

#[test]
fn fails() { assert(1 == 2, "one is not two"); }

#[test(should_fail)]
fn fails_as_asked() { assert(1 == 2); }

#[test(should_fail)]
fn passes_when_it_should_not() { assert(1 == 1); }
""")]
    let catalog = noirCatalogFromSources(sources)
    counted catalog.items.len == 4

    let vm = createTestResultsVM()
    vm.setCatalog(catalog)
    counted vm.rows.val.len == 4
    for row in vm.rows.val:
      counted row.state == trsNotRun

    let response = parseNoirTestResponse(FourWays)
    let events = noirTestRunEvents(response, catalog.items,
                                   runId = "run-1", commandLine = "nargo test",
                                   packageDir = "app")
    # `run-started` … per test `test-started`, an optional `failure`/`output`
    # carrying what the row will say, then `test-finished` … `run-finished`.
    # Three of the four have something to say — the two failures and the
    # `should_fail` pass — and the plain pass has nothing: 1 + 3 + 3 + 2 + 3 + 1.
    counted events.len == 13
    counted events[0].kind == tekRunStarted
    counted events[^1].kind == tekRunFinished

    for event in events:
      vm.ingestEvent(event)

    counted vm.rows.val.len == 4
    counted rowNamed(vm, "passes").state == trsPassed
    counted rowNamed(vm, "fails").state == trsFailed
    # THE INVERSION AGAIN, at the last layer it could be undone.
    counted rowNamed(vm, "fails_as_asked").state == trsPassed
    counted rowNamed(vm, "passes_when_it_should_not").state == trsFailed

    # The ids came from the CATALOG, so no row was appended as unknown.
    for row in vm.rows.val:
      counted row.file == "src/main.nr"

    # A `should_fail` row that passed SAYS so, because a green row there means
    # the opposite of what a green row usually means.
    counted "expected to fail" in rowNamed(vm, "fails_as_asked").message
    counted rowNamed(vm, "passes").message.len == 0

    # The failing row carries the user's own assertion text and not the bare
    # "Failed assertion".
    counted "one is not two" in rowNamed(vm, "fails").message

    counted not vm.summary.val.inProgress
    counted vm.summary.val.passed == 2
    counted vm.summary.val.failed == 2
    counted "2 passed" in vm.headline.val

  test "a refused run reaches the pane as diagnostics, not as silence":
    let vm = createTestResultsVM()
    let events = noirTestRunEvents(parseNoirTestResponse(CheckRefused), @[],
                                   "run-2", "nargo test", "app")
    counted events.len == 3
    counted events[1].kind == tekDiagnostic
    counted "no_such_function" in events[1].message
    for event in events:
      vm.ingestEvent(event)
    counted not vm.summary.val.inProgress
    counted vm.summary.val.diagnostics.len == 1

  test "a fuzzing harness is skipped with a reason a reader can act on":
    let response = parseNoirTestResponse(FuzzHarness)
    let harness = outcomeNamed(response, "takes_an_argument")
    counted harness.status == ntsSkipped
    counted harness.hasArguments
    counted noirRunStatus(harness.status) == tsSkipped
    counted "fuzzes it" in noirRunMessage(harness)

  test "a test the catalog does not have is shown, not dropped":
    # A real disagreement — a stale catalog, or a runner that generates tests —
    # and hiding it would make the pane quietly wrong. `joinRows` appends such
    # rows deliberately; this asserts the id derivation reaches it.
    let vm = createTestResultsVM()
    for event in noirTestRunEvents(parseNoirTestResponse(FourWays), @[],
                                   "run-3", "nargo test", "app"):
      vm.ingestEvent(event)
    counted vm.rows.val.len == 4
    counted rowNamed(vm, "fails_as_asked").state == trsPassed

  test "the run affordance is guarded, and the guard has three reasons":
    let vm = createTestResultsVM()
    # No host installed a runner.
    counted not vm.canRun()
    var started = 0
    vm.runTests = proc() = inc started
    counted vm.canRun()

    # A deployment that stated a reason.
    vm.setRunAbsence("This bundle carries no Noir compiler module.")
    counted not vm.canRun()
    vm.startRun()
    counted started == 0
    vm.setRunAbsence("")
    counted vm.canRun()

    # A run already in flight.
    vm.beginRun()
    counted vm.inFlight.val
    counted not vm.canRun()
    vm.startRun()
    counted started == 0
    # …and the headline says so before any event has arrived, which is the
    # whole window `inFlight` exists for.
    counted vm.headline.val == "running…"
    vm.endRun()
    counted vm.canRun()
    vm.startRun()
    counted started == 1

  test "beginRun clears the previous verdicts":
    let vm = createTestResultsVM()
    for event in noirTestRunEvents(parseNoirTestResponse(FourWays), @[],
                                   "run-4", "nargo test", "app"):
      vm.ingestEvent(event)
    counted vm.summary.val.rows.len == 4
    vm.beginRun()
    counted vm.summary.val.rows.len == 0
    counted vm.rows.val.len == 0

suite "recording a test, which is what running one means":

  test "a recorded test yields an artifact and runs nothing":
    let producer = fixture()
    let verdict = runPhase(producer, nbpTestRecord, Recorded, exitCode = 0)
    counted verdict == npvSucceeded
    counted not producer.artifact.isNil
    # The artifact goes to the tracer through the SAME request a Run's trace
    # uses, which is what makes this reuse the Run path's second half rather
    # than needing a second tracer route.
    let request = noirTraceRequest(producer.artifact, noirTestRecordInputs)
    counted request["artifact"]["noir_version"].getStr == "1.0.0"
    # EMPTY INPUTS, and that is the correct value rather than a missing one: a
    # `#[test]` takes no arguments, so its ABI has nothing to encode. Sending
    # the project's `Prover.toml` would encode `main`'s arguments against a
    # test's ABI.
    counted request["inputs"].getStr == ""
    counted noirTestRecordInputs == ""

  test "a record request is not a run request":
    let files = @[NoirSourceEntry(path: "app/src/main.nr", content: "fn main() {}")]
    let record = noirTestRecordRequest(files, "app", "tests::test_main")
    counted record["record"].getStr == "tests::test_main"
    counted not record.hasKey("tests")
    counted not record.hasKey("mode")

    let run = noirTestRequest(files, "app", @["tests::test_main"])
    counted not run.hasKey("record")
    counted run["tests"][0].getStr == "tests::test_main"

  test "ok with no artifact is a protocol fault, not a green recording":
    # The two responses differ in ONE field and `ok` is not it. A producer that
    # branched on `ok` alone would hand `null` to the tracer and fail a layer
    # down with a message naming the tracer.
    let producer = fixture()
    let verdict = runPhase(producer, nbpTestRecord, RecordedWithoutArtifact,
                           exitCode = 0)
    counted verdict == npvFaulted
    counted producer.artifact.isNil
    counted "protocol fault" in paneText(producer)
    counted "not a fault in your test" in paneText(producer)

  test "a refused recording names the test rather than the project":
    let producer = fixture()
    let verdict = runPhase(producer, nbpTestRecord, RecordRefused, exitCode = 1)
    counted verdict == npvRefused
    counted producer.artifact.isNil
    counted "no-such-test" in paneText(producer)
    counted "no_such_test" in paneText(producer)

  test "a recording replaces a Build's artifact rather than inheriting it":
    # A Build compiles `main`. Tracing THAT after clicking Run on a test would
    # step the program instead of the test that was clicked — a session that
    # opens, works, and shows the wrong execution.
    let producer = fixture()
    discard runPhase(producer, nbpCompile,
      """{"ok":true,"artifact":{"noir_version":"main-not-test"}}""", 0)
    counted not producer.artifact.isNil
    counted producer.artifact["noir_version"].getStr == "main-not-test"
    discard runPhase(producer, nbpTestRecord, RecordRefused, exitCode = 1)
    counted producer.artifact.isNil

  test "a recording does not wipe the verdict the pane just painted":
    # The gesture is three phases and the user sees the verdict first. A record
    # phase that cleared the pane would delete the pass or the failure before
    # the seconds an instrumented compile takes had elapsed.
    let producer = fixture()
    discard runTestPhase(producer, FourWays, exitCode = 1)
    let afterVerdict = paneText(producer)
    counted "passes_when_it_should_not" in afterVerdict
    discard runPhase(producer, nbpTestRecord, Recorded, exitCode = 0)
    counted "passes_when_it_should_not" in paneText(producer)
    counted "compiled the test for recording" in paneText(producer)

suite "the paths the two spellings meet on":

  test "a VFS path becomes the catalog's project-relative one":
    counted noirRunProjectRelative("app/src/main.nr", "app") == "src/main.nr"
    counted noirRunProjectRelative("src/main.nr", "") == "src/main.nr"
    # A path that does not carry the prefix is left alone rather than truncated
    # by length — truncation would silently produce a plausible wrong path.
    counted noirRunProjectRelative("other/src/main.nr", "app") ==
      "other/src/main.nr"

  test "test_noir_test_run_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
