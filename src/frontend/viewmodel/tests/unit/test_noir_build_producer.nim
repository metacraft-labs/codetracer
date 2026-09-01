## Headless tests for the BUILD pane's SECOND producer — the wasm worker.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_noir_build_producer.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_noir_build_producer.nim
##
## ## What this asserts, and why it drives the REAL `BuildVM`
##
## The pane is not forked: `noir_build_producer` calls the same `setCommand` /
## `appendLine` / `appendProblem` / `setCode` procs the desktop's
## `BuildComponent` calls, and `createBuildVM`'s `status` memo derives
## `bsRunning` / `bsFailed` / `bsSucceeded` from them. So every case below
## builds a real VM over a stub backend and reads the signals the IsoNim view
## reads. A test double for the VM would assert that the producer calls the
## procs the test thinks it should, which is the same thing said twice.
##
## ## The failure this suite is built against
##
## A producer that appended SOMETHING for every input would pass "the pane has
## output" over painted garbage. So the assertions are counted, the counts are
## themselves asserted, and the interesting ones are about WHICH row got which
## severity and which path — the two fields a mis-mapping corrupts while
## leaving every count intact.

import std/[json, strutils, unittest]

import isonim/core/[signals, computation]

import ../../backend/backend_service
import ../../platform/noir_build
import ../../platform/process
import ../../store/replay_data_store
import ../../store/types
import ../../viewmodels/build_vm
import ../../viewmodels/noir_build_producer

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 145
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# A real BuildVM over a stub backend — the same construction
# `ui/build.initBuildVM` uses when no shared store has arrived.
# ---------------------------------------------------------------------------

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
                       projectRoot = "/hello_noir", packageDir = "hello_noir")

proc runPhase(producer: NoirBuildProducer; phase: NoirBuildPhase;
              stdout: string; exitCode: int;
              stderr: string = ""): NoirPhaseVerdict =
  ## One whole phase, driven through the three message kinds in the order the
  ## worker sends them: `output`, then `exit`.
  producer.beginPhase(phase, "nargo compile", 1000.0)
  if stderr.len > 0:
    producer.onOutput(ProcessOutputChunk(stream: psStderr, text: stderr))
  if stdout.len > 0:
    producer.onOutput(ProcessOutputChunk(stream: psStdout, text: stdout))
  producer.onExit(ProcessExit(exitCode: exitCode, signalled: false))

proc problemsWith(vm: BuildVM; severity: BuildLineSeverity): int =
  for problem in vm.problems.val:
    if problem.severity == severity: inc result

proc linesMentioning(vm: BuildVM; needle: string): int =
  for line in vm.output.val:
    if needle in line.htmlText: inc result

# ---------------------------------------------------------------------------
# Fixtures: verbatim `noir_wasm.wasm` output. See
# `test_noir_build_marshalling.nim`'s header for why they are measured rather
# than written.
# ---------------------------------------------------------------------------

const CleanCompile = """{"ok":true,"plan":{},"artifact":{"bytecode":"H4sI"}}"""

const TypeError = """{"ok":false,"stage":"compile","kind":"compile-error","message":"the program did not compile: 1 diagnostic(s)","diagnostics":[{"message":"expected type u8, found type ()","file":"hello_noir/src/utils.nr","line":3,"column":41,"end_line":3,"end_column":43,"start":66,"end":68,"secondary_messages":["expected u8 because of return type","() returned here"],"notes":[],"severity":"error"}]}"""

const MixedSeverities = """{"ok":false,"stage":"compile","kind":"compile-error","message":"the program did not compile: 2 diagnostic(s)","diagnostics":[{"message":"Unused expression result of type Field","file":"hello_noir/src/main.nr","line":3,"column":5,"end_line":3,"end_column":10,"start":40,"end":45,"secondary_messages":[],"notes":[],"severity":"warning"},{"message":"Could not resolve 'nope' in path","file":"hello_noir/src/main.nr","line":4,"column":12,"end_line":4,"end_column":16,"start":58,"end":62,"secondary_messages":[],"notes":[],"severity":"error"}]}"""

const CleanWithWarning = """{"ok":true,"plan":{},"artifact":{"bytecode":"H4sI"},"warnings":[{"message":"Unused expression result of type Field","file":"hello_noir/src/main.nr","line":3,"column":5,"end_line":3,"end_column":10,"start":40,"end":45,"secondary_messages":[],"notes":[],"severity":"warning"}]}"""

const GitDependencyRefused = """{"ok":false,"stage":"resolve","kind":"git-dependency-refused","message":"hello_noir/Nargo.toml:7:8: the dependency `util` is a GIT dependency. A virtual filesystem cannot fetch it.","manifest":"hello_noir/Nargo.toml","line":7,"column":8}"""

const TraceDocument = """{"events":[{"Path":"p"},{"Call":{}},{"Step":{}},{"Step":{}},{"Step":{}},{"Call":{}}],"paths":["hello_noir/src/main.nr","hello_noir/src/utils.nr"]}"""

const TrivialTrace = """{"events":[{"Path":"p"}],"paths":["hello_noir/src/main.nr"]}"""

suite "the pane is driven, not forked":

  test "a clean compile leaves the pane succeeded with the artifact carried":
    let producer = fixture()
    let verdict = runPhase(producer, nbpCompile, CleanCompile, 0)
    counted verdict == npvSucceeded
    # `status` is the memo the IsoNim view's header reads.
    counted producer.vm.status.val == bsSucceeded
    counted not producer.vm.isRunning.val
    counted producer.vm.code.val == 0
    counted producer.vm.hasOutput.val
    counted producer.vm.problems.val.len == 0
    counted producer.vm.errors.val.len == 0
    # The artifact is carried so a Run's second phase has something to send.
    counted not producer.artifact.isNil
    counted producer.artifact["bytecode"].getStr == "H4sI"
    # The pane says what happened, and says it as the STUDIO rather than as
    # the toolchain.
    counted linesMentioning(producer.vm, "compiled hello_noir") == 1
    counted linesMentioning(producer.vm, noirBuildFaultPrefix) == 1

  test "the pane is RUNNING between begin and exit, and says the command":
    # `bsRunning` is what draws the spinner and enables the ■. A producer that
    # only wrote at exit would leave a 2.5-second first compile looking idle.
    let producer = fixture()
    counted producer.vm.status.val == bsIdle
    producer.beginPhase(nbpCompile, "nargo compile", 4242.0)
    counted producer.vm.status.val == bsRunning
    counted producer.vm.isRunning.val
    counted producer.vm.command.val == "nargo compile"
    counted producer.vm.buildStartTime.val == 4242.0
    discard producer.onExit(ProcessExit(exitCode: 0, signalled: false))
    counted not producer.vm.isRunning.val

  test "a compile error paints a row, a problem and an error, all located":
    let producer = fixture()
    let verdict = runPhase(producer, nbpCompile, TypeError, 1)
    counted verdict == npvRefused
    counted producer.vm.status.val == bsFailed
    counted producer.vm.code.val == 1
    counted producer.artifact.isNil

    # ONE problem, not two and not zero.
    counted producer.vm.problems.val.len == 1
    let problem = producer.vm.problems.val[0]
    counted problem.severity == blsError
    counted problem.line == 3
    counted problem.col == 41
    # THE PATH IS THE RENDERER'S, not the compiler's. A row keeping
    # `hello_noir/src/utils.nr` is a clickable jump target that opens a
    # second, empty tab.
    counted problem.path == "/hello_noir/src/utils.nr"
    counted problem.path.startsWith("/")
    # The secondaries survive: "expected type u8" alone does not say where the
    # `u8` came from.
    counted "expected type u8, found type ()" in problem.message
    counted "expected u8 because of return type" in problem.message
    counted "() returned here" in problem.message

    # The Errors panel row is the same fact, keyed the same way.
    counted producer.vm.errors.val.len == 1
    counted producer.vm.errors.val[0].locationPath == "/hello_noir/src/utils.nr"
    counted producer.vm.errors.val[0].locationLine == 3

    # And an output row that is CLICKABLE — `isonim_build_view.lineClass`
    # gives `build-clickable` only when `locationPath` is non-empty.
    var clickable = 0
    for line in producer.vm.output.val:
      if line.locationPath.len > 0:
        inc clickable
        counted line.locationPath == "/hello_noir/src/utils.nr"
        counted line.locationLine == 3
        counted line.severity == blsError
    counted clickable == 1

  test "severities reach the pane unflattened":
    # THE ASSERTION THE DESKTOP TEXT MATCHER CANNOT MAKE. Its box-drawing
    # parse forces every severity to error; this path has a field.
    let producer = fixture()
    let verdict = runPhase(producer, nbpCompile, MixedSeverities, 1)
    counted verdict == npvRefused
    counted producer.vm.problems.val.len == 2
    counted problemsWith(producer.vm, blsError) == 1
    counted problemsWith(producer.vm, blsWarning) == 1
    counted problemsWith(producer.vm, blsInfo) == 0
    counted problemsWith(producer.vm, blsNone) == 0
    # The counts sum to the list, so a dropped row cannot hide between two
    # independent counts.
    counted problemsWith(producer.vm, blsError) +
      problemsWith(producer.vm, blsWarning) == producer.vm.problems.val.len
    # ATTACHED TO THE RIGHT ROWS. Two counts that were correct with the
    # severities swapped would pass everything above.
    counted producer.vm.problems.val[0].severity == blsWarning
    counted "Unused expression" in producer.vm.problems.val[0].message
    counted producer.vm.problems.val[1].severity == blsError
    counted "Could not resolve" in producer.vm.problems.val[1].message
    # The output rows carry the same severities — that is what colours them.
    var errorLines, warningLines = 0
    for line in producer.vm.output.val:
      if line.severity == blsError: inc errorLines
      elif line.severity == blsWarning: inc warningLines
    counted errorLines == 1
    counted warningLines == 1

  test "a successful compile still reports its warnings":
    # The normal case, and the one a producer that only painted on failure
    # would lose.
    let producer = fixture()
    let verdict = runPhase(producer, nbpCompile, CleanWithWarning, 0)
    counted verdict == npvSucceeded
    counted producer.vm.status.val == bsSucceeded
    counted producer.vm.problems.val.len == 1
    counted problemsWith(producer.vm, blsWarning) == 1
    counted problemsWith(producer.vm, blsError) == 0
    counted linesMentioning(producer.vm, "with 1 warning") == 1
    counted not producer.artifact.isNil

  test "a resolve refusal paints a row even though it has no diagnostics":
    # `noir_build.nim` header fact 3. A pane rendering only `diagnostics`
    # paints NOTHING here, and a git dependency in `Nargo.toml` is one of the
    # two most likely first-run mistakes.
    let producer = fixture()
    let verdict = runPhase(producer, nbpCompile, GitDependencyRefused, 1)
    counted verdict == npvRefused
    counted producer.vm.status.val == bsFailed
    counted producer.vm.problems.val.len == 1
    let problem = producer.vm.problems.val[0]
    counted problem.severity == blsError
    counted problem.path == "/hello_noir/Nargo.toml"
    counted problem.line == 7
    counted problem.col == 8
    counted "GIT dependency" in problem.message
    counted producer.vm.output.val.len > 0

suite "faults are told apart from refusals":

  test "an undecodable answer is a FAULT and says nothing about the program":
    let producer = fixture()
    let verdict = runPhase(producer, nbpCompile, "<!doctype html>", 0)
    # Exit code ZERO over an undecodable body: the pane must not paint
    # `bsSucceeded` because the worker happened to exit cleanly.
    counted verdict == npvFaulted
    counted producer.vm.status.val == bsFailed
    counted producer.vm.code.val == 1
    counted producer.vm.problems.val.len == 0
    counted linesMentioning(producer.vm, "could not decode") == 1
    counted producer.artifact.isNil

  test "a worker failure arrives on stderr and is painted":
    # `wasm_worker.finish` routes a `failed` message's text to `onOutput` as
    # stderr on the `start` path, which is where the three module-load faults
    # arrive. Before that fix a streaming caller saw a bare exit code 1.
    let producer = fixture()
    const Fault = "this deployment does not ship the `noir-tracer` wasm module"
    let verdict = runPhase(producer, nbpTrace, "", 1, stderr = Fault)
    counted verdict == npvFaulted
    counted producer.vm.status.val == bsFailed
    counted linesMentioning(producer.vm, "noir-tracer") == 1
    var stderrLines = 0
    for line in producer.vm.output.val:
      if not line.isStdout: inc stderrLines
    counted stderrLines >= 1

  test "a refusal is not an exit — nothing ran":
    let producer = fixture()
    producer.beginPhase(nbpCompile, "nargo compile", 1.0)
    let verdict = producer.onRefusal(
      "`nargo` has no wasm build, so it cannot run in the browser.")
    counted verdict == npvFaulted
    counted producer.vm.status.val == bsFailed
    counted producer.vm.code.val == 1
    counted linesMentioning(producer.vm, "no wasm build") == 1
    counted linesMentioning(producer.vm, noirBuildFaultPrefix) == 1
    # A later `onExit` for the same phase must not append a second verdict.
    #
    # THE VERDICT ALONE IS NOT ENOUGH TO ASSERT, and that is measured: a
    # producer that forgot to settle here would run the compile path over an
    # empty stdout, decode nothing, and answer `npvFaulted` — the SAME value,
    # for a completely different reason, with a second account of the failure
    # appended underneath the first. So the ROWS are what this checks.
    let rowsAfterRefusal = producer.vm.output.val.len
    counted rowsAfterRefusal > 0
    counted producer.onExit(ProcessExit(exitCode: 0, signalled: false)) ==
      npvFaulted
    counted producer.vm.output.val.len == rowsAfterRefusal
    counted linesMentioning(producer.vm, "could not decode") == 0
    counted producer.vm.status.val == bsFailed

  test "a STOP is not a failure":
    # `process.nim`: "a cancelled run establishes nothing, and callers that
    # conflate the two report a cancellation as a failure".
    let producer = fixture()
    producer.beginPhase(nbpCompile, "nargo compile", 1.0)
    let verdict = producer.onExit(ProcessExit(
      exitCode: 1, signalled: true, signalName: "terminate"))
    counted verdict == npvCancelled
    counted verdict != npvFaulted
    counted verdict != npvRefused
    counted linesMentioning(producer.vm, "stopped") == 1
    counted linesMentioning(producer.vm, "establishes nothing") == 1
    counted producer.vm.problems.val.len == 0

  test "one exit settles one phase, however many arrive":
    let producer = fixture()
    producer.beginPhase(nbpCompile, "nargo compile", 1.0)
    producer.onOutput(ProcessOutputChunk(stream: psStdout, text: CleanCompile))
    counted producer.onExit(ProcessExit(exitCode: 0)) == npvSucceeded
    let rowsAfterFirst = producer.vm.output.val.len
    counted producer.onExit(ProcessExit(exitCode: 0)) == npvSucceeded
    counted producer.vm.output.val.len == rowsAfterFirst
    counted rowsAfterFirst > 0

suite "the trace phase reports what a trace IS":

  test "a real trace is counted and its files are clickable":
    let producer = fixture()
    let verdict = runPhase(producer, nbpTrace, TraceDocument, 0)
    counted verdict == npvSucceeded
    counted producer.vm.status.val == bsSucceeded
    counted producer.lastSummary.events == 6
    counted producer.lastSummary.steps == 3
    counted producer.lastSummary.calls == 2
    counted linesMentioning(producer.vm, "traced 6 events") == 1
    counted linesMentioning(producer.vm, "3 steps") == 1
    # The source files are rows a user can click, in the RENDERER's spelling.
    var traceRows = 0
    for line in producer.vm.output.val:
      if line.locationPath.len > 0:
        inc traceRows
        counted line.locationPath.startsWith("/hello_noir/")
    counted traceRows == 2
    # THE WHOLE TRACE IS NOT IN THE PANE. It is 3.7 KB for the bundled
    # template and unbounded in general; painting it verbatim would put a
    # trace in a log pane.
    counted linesMentioning(producer.vm, "\"events\"") == 0

  test "ONE-EVENT-ZERO-STEPS is a fault, not a success":
    # Both wasm modules answer `ok` over a trace with nothing in it —
    # `compare.mjs`'s header records the measurement. A pane that said
    # "traced" over that is the chain of agreements, one layer up.
    let producer = fixture()
    let verdict = runPhase(producer, nbpTrace, TrivialTrace, 0)
    counted verdict == npvFaulted
    counted producer.vm.status.val == bsFailed
    counted linesMentioning(producer.vm, "no steps") == 1

  test "a trace phase does not wipe the compile's warnings":
    # A Run is TWO phases and one pane. Clearing at the trace would delete the
    # compile's own output before the user had read it.
    let producer = fixture()
    discard runPhase(producer, nbpCompile, CleanWithWarning, 0)
    let warningsAfterCompile = producer.vm.problems.val.len
    counted warningsAfterCompile == 1
    let artifactBefore = producer.artifact
    discard runPhase(producer, nbpTrace, TraceDocument, 0)
    counted producer.vm.problems.val.len == warningsAfterCompile
    counted linesMentioning(producer.vm, "Unused expression") == 1
    # And the artifact survives into the trace phase, which is the whole point
    # of not clearing it.
    counted producer.artifact == artifactBefore
    # A NEW compile does clear, which is the desktop's behaviour
    # (`onBuildCommand` calls `clearOutput`) and stops one run's failures
    # bleeding into the next.
    discard runPhase(producer, nbpCompile, CleanCompile, 0)
    counted producer.vm.problems.val.len == 0
    counted linesMentioning(producer.vm, "Unused expression") == 0

  test "Run without inputs is refused by name, not defaulted":
    # Zeroes would satisfy the ABI and then fail `assert(x != y)`, which reads
    # as "your program is broken" about a program that is fine.
    let producer = fixture()
    producer.beginPhase(nbpTrace, "nargo trace", 1.0)
    let verdict = producer.traceInputsMissing("Prover.toml")
    counted verdict == npvFaulted
    counted producer.vm.status.val == bsFailed
    counted linesMentioning(producer.vm, "Prover.toml") == 1
    counted producer.vm.problems.val.len == 0

suite "what reaches innerHTML is escaped":

  test "a diagnostic quoting the user's source cannot inject markup":
    # `isonim_build_view` assigns `htmlText` to `innerHTML`, deliberately —
    # the desktop's producer passes ANSI runs through `ansi_up`. Nothing here
    # is ANSI: it is compiler output quoting the user's own source, and §1b.3
    # links can carry a project.
    counted escapeHtmlText("<script>alert(1)</script>") ==
      "&lt;script&gt;alert(1)&lt;/script&gt;"
    counted escapeHtmlText("a & b") == "a &amp; b"
    counted escapeHtmlText("\"q\" 'p'") == "&quot;q&quot; &#39;p&#39;"
    # `&` FIRST, or every entity gets its own `&` escaped a second time.
    counted escapeHtmlText("&lt;") == "&amp;lt;"
    counted escapeHtmlText("plain text") == "plain text"

    # And it holds end to end, through a real diagnostic.
    let producer = fixture()
    const Injected = """{"ok":false,"stage":"compile","kind":"compile-error","message":"x","diagnostics":[{"message":"expected type <img src=x onerror=alert(1)>, found type ()","file":"hello_noir/src/main.nr","line":1,"column":1,"secondary_messages":[],"notes":[],"severity":"error"}]}"""
    discard runPhase(producer, nbpCompile, Injected, 1)
    counted producer.vm.problems.val.len == 1
    var rawTagRows = 0
    var escapedRows = 0
    for line in producer.vm.output.val:
      if "<img" in line.htmlText: inc rawTagRows
      if "&lt;img" in line.htmlText: inc escapedRows
    counted rawTagRows == 0
    counted escapedRows == 1
    # The PROBLEM row keeps the text unescaped — it is rendered as
    # `textContent` by the Problems panel, and double-escaping there would
    # show a user `&lt;img` where they wrote `<img`.
    counted "<img" in producer.vm.problems.val[0].message

  test "a multi-line message becomes one row per line":
    # `build.processBuildOutput` splits the same way, so each row gets its own
    # class and its own click target rather than one row with literal `\n`.
    let producer = fixture()
    producer.beginPhase(nbpCompile, "nargo compile", 1.0)
    discard producer.onRefusal("first line\nsecond line\nthird line")
    var matched = 0
    for line in producer.vm.output.val:
      if "second line" in line.htmlText or "third line" in line.htmlText:
        inc matched
        counted "\n" notin line.htmlText
    counted matched == 2

suite "the severity mapping is total":

  test "every NoirDiagnosticSeverity maps, and bug and unknown say so":
    counted buildSeverityOf(ndsError) == blsError
    counted buildSeverityOf(ndsWarning) == blsWarning
    counted buildSeverityOf(ndsInfo) == blsInfo
    # A compiler BUG is not a warning and not information: a user whose build
    # is broken by one must see it in the Problems panel's errors filter.
    counted buildSeverityOf(ndsBug) == blsError
    # An unrecognised severity likewise must not be filtered OUT of the errors
    # view, which is where a user looks when a build fails.
    counted buildSeverityOf(ndsUnknown) == blsError
    # But neither is SILENT about being the case it is — otherwise a decoder
    # that read the field and one that called everything an error would be
    # indistinguishable in the pane.
    counted "[compiler bug] " in problemMessage(NoirDiagnostic(
      message: "internal", severity: ndsBug, severityText: "bug"))
    counted "[catastrophe] " in problemMessage(NoirDiagnostic(
      message: "m", severity: ndsUnknown, severityText: "catastrophe"))
    counted "[" notin problemMessage(NoirDiagnostic(
      message: "m", severity: ndsError, severityText: "error"))
    counted "[" notin problemMessage(NoirDiagnostic(
      message: "m", severity: ndsWarning, severityText: "warning"))

  test "a path outside the package keeps its own identity":
    # The stdlib's own sources reach diagnostics occasionally. Bolting a
    # project prefix onto one would make a row claim the project contains a
    # file it does not.
    let producer = fixture()
    counted producer.rendererPath("hello_noir/src/main.nr") ==
      "/hello_noir/src/main.nr"
    counted producer.rendererPath("std/field.nr") == "std/field.nr"
    counted producer.rendererPath("") == ""
    # A path that merely STARTS with the package name is not inside it.
    counted producer.rendererPath("hello_noir_other/x.nr") ==
      "hello_noir_other/x.nr"

  test "noir_build_producer_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
