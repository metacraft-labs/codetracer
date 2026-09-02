## The Build panel's SECOND PRODUCER — the wasm worker, beside the desktop's
## Electron IPC.
##
## ## What this replaces, and why the pane is not forked
##
## `build_vm.nim`'s own header says where its data comes from: "the legacy
## `BuildComponent` event handlers (`onBuildCommand` / `onBuildStdout` /
## `onBuildStderr` / `onBuildCode`) feed the VM". Those are `CODETRACER::`
## channels answered by the desktop `ct` process. A browser tab has no `ct`
## process, so on the web arm every one of them is silent and the BUILD pane
## has been permanently `bsIdle` — a panel with a ▶ that produced nothing.
##
## The obvious fix is a web-specific build panel, and it is the wrong one. The
## pane, its IsoNim view, its severity colouring, its clickable jump targets
## and its Problems rows are already correct and already tested; what was
## missing is a producer. So this module is exactly and only the shape
## `onBuildCommand` / `processBuildOutput` / `onBuildCode` have on the desktop,
## driven by `platform/wasm_worker.nim`'s three message kinds instead of by
## three IPC channels:
##
##     desktop                     browser
##     CODETRACER::build-command   beginPhase
##     CODETRACER::build-stdout    onOutput   (worker `output`, psStdout)
##     CODETRACER::build-stderr    onOutput   (worker `output`, psStderr)
##     CODETRACER::build-code      onExit     (worker `exit` and `failed`)
##
## and it calls the same `BuildVM` procs the desktop path calls. There is one
## pane, one view and one set of signals.
##
## ## Why the whole response is decoded at `exit` and not as it arrives
##
## Because the worker sends it as ONE chunk. `wasm_worker_browser.js` posts
## `{kind:'output', text: JSON.stringify(response)}` and then `{kind:'exit'}`,
## so there is no partial state a streaming decoder could use. Buffering and
## decoding at exit is therefore not a simplification, it is the protocol.
##
## Streaming is still honoured for stderr, because that is where a worker-level
## FAILURE arrives (`wasm_worker.finish` routes it there on the `start` path),
## and a failure must be painted even though no `VfsResponse` was ever sent.
##
## ## HTML ESCAPING IS A CORRECTNESS REQUIREMENT HERE, NOT HYGIENE
##
## `views/isonim_build_view.nim` assigns `line.htmlText` to `innerHTML` —
## deliberately, because the desktop's producer passes ANSI runs through
## `ansi_up`, which emits `<span style=...>`. Nothing this module produces is
## ANSI: it is compiler diagnostics, and a compiler diagnostic QUOTES THE
## USER'S OWN SOURCE (`expected type Foo<Bar>, found …`). On a product whose
## §1b.3 links can carry a project, that is script injection with extra steps.
## So every string that reaches `htmlText` goes through `escapeHtmlText`, and
## the suite asserts it with a source file that contains a `<script>`.

import std/[json, strutils]

import ../platform/noir_build
import ../platform/process
import ../store/types
import ./build_vm
import ../backend/replay_session_service

export noir_build

type
  NoirBuildPhase* = enum
    ## Which of the three subcommands is in flight. The pane needs to know
    ## because their stdout is not the same thing: `compile` answers a
    ## `VfsResponse` a few kilobytes long that is worth decoding, `test`
    ## answers a `TestVfsResponse` whose per-test rows are worth painting, and
    ## `trace` answers a whole `MemoryTrace` — 3.7 KB for the bundled template
    ## and unbounded in general. Painting the last verbatim would put a trace
    ## in a log pane.
    nbpCompile
    nbpTrace
    nbpTest

  NoirPhaseVerdict* = enum
    ## What `onExit` concluded. Returned rather than stored so the caller can
    ## chain compile → trace without asking the VM what happened — a caller
    ## that read `vm.code.val` back would be inferring its own state from a
    ## presentation layer.
    npvSucceeded
      ## Exit 0 and, for a compile, a decoded `ok: true` with an artifact.
    npvRefused
      ## The toolchain answered and said no: diagnostics, or a resolve
      ## refusal. The user has something to fix.
    npvFaulted
      ## The toolchain did not answer: a module that would not load, a
      ## protocol violation, an undecodable response. Nothing about the
      ## user's program is established.
    npvCancelled
      ## Stopped. `ProcessExit.signalled`, which `process.nim` keeps distinct
      ## from a non-zero exit for exactly this reason: "a cancelled run
      ## establishes nothing, and callers that conflate the two report a
      ## cancellation as a failure".

  NoirBuildProducer* = ref object
    ## One producer per pane, reused across runs.
    vm*: BuildVM
    projectRoot*: string
      ## The renderer's spelling of the project root, WITH its leading slash
      ## — `/hello_noir`. Diagnostics come back keyed by the compiler's VFS
      ## spelling (`hello_noir/src/utils.nr`) and a jump target has to be the
      ## former or it opens nothing. See `rendererPath`.
    packageDir*: string
      ## The compiler's spelling — `hello_noir`.
    phase*: NoirBuildPhase
    stdoutText*: string
    stderrText*: string
    artifact*: JsonNode
      ## Carried from a successful compile so a Run's trace phase has
      ## something to send. Cleared at the start of every compile, so a trace
      ## can never be issued against the artifact of a previous, different
      ## build.
    lastVerdict*: NoirPhaseVerdict
    lastSummary*: NoirTraceSummary
    lastTests*: NoirTestResponse
      ## What the last `nbpTest` phase decoded, whole.
      ##
      ## Kept on the producer for the same reason `artifact` is: the Test
      ## Results pane is a SECOND surface over this run, and it needs the
      ## per-test outcomes rather than the lines this module painted into the
      ## build pane. A caller reads it after `onExit` returns.
      ##
      ## Not an `Option` and not cleared to a sentinel: `decoded` already
      ## distinguishes "no run has happened" (`false`, no raw) from a run,
      ## which is the distinction an `Option` would be adding a second
      ## spelling for.
    settled: bool
      ## `onExit` runs once per phase. `wasm_worker.finish` already forgets a
      ## run before settling it, but a transport that delivered twice would
      ## otherwise append a second copy of every line.

    onProblem*: proc(problem: BuildProblemLine)
      ## Mirror a diagnostic into the PROBLEMS pane, when a host asks for it.
      ##
      ## The desktop feeds two view-models from one diagnostic —
      ## `ui/build.nim:448` calls `BuildVM.appendProblem` and
      ## `ui/errors.nim:201` calls `ErrorsVM.appendProblem` — and this
      ## producer only ever fed the first. The consequence was that in a
      ## browser tab the BUILD pane painted diagnostics and the PROBLEMS pane
      ## stayed empty, which also meant `BuildVM.problems` had no production
      ## reader at all: it was written on every build and read by nothing but
      ## tests.
      ##
      ## A callback rather than a direct call because this module is in the
      ## ViewModel layer, which `ci/test/hostfree-build.sh` forbids from
      ## reaching the host. The host installs it; see `ui/web_noir_build.nim`.
    onProblemsCleared*: proc()
      ## Paired with `onProblem`: a new compile clears the pane's problem
      ## list, and the mirror has to be cleared with it or the second build
      ## shows the first build's errors underneath its own.

const
  noirBuildFaultPrefix* = "codetracer: "
    ## Prefixes the lines this producer writes ABOUT the build rather than
    ## lines the toolchain wrote. A user reading the pane must be able to tell
    ## "the compiler said this" from "the studio said this": they are fixed by
    ## different people, and a wall of undifferentiated text is how a
    ## deployment fault gets reported as a Noir bug.

# ---------------------------------------------------------------------------
# Escaping and paths
# ---------------------------------------------------------------------------

proc escapeHtmlText*(text: string): string =
  ## The five characters that must not reach `innerHTML` as markup.
  ##
  ## `&` first, or every entity this proc writes gets its own `&` escaped a
  ## second time and the pane renders `&amp;lt;` where a user wrote `<`.
  result = newStringOfCap(text.len + 16)
  for ch in text:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else: result.add ch

proc rendererPath*(producer: NoirBuildProducer; vfsPath: string): string =
  ## A diagnostic's `file` in the spelling the renderer opens tabs by.
  ##
  ## The compiler answers `hello_noir/src/utils.nr` because that is the key it
  ## was handed; the renderer's tabs, its file tree rows and its breakpoint
  ## table are all keyed by `/hello_noir/src/utils.nr`
  ## (`web_entry_surface.templateProjectRoot` explains why the leading slash
  ## is required there — `utils.openTab` treats a relative name as a path it
  ## must rescue by tail-matching, and `edit_mode.sourceScore` awards `+10`
  ## for a `/src/` segment).
  ##
  ## So a row whose `locationPath` kept the compiler's spelling would be a
  ## clickable jump target that opens a SECOND, empty tab — the failure that
  ## looks like it worked. One conversion, in one place.
  ##
  ## A path the prefix does not match is passed through unchanged rather than
  ## having a slash bolted on: the stdlib's own sources reach diagnostics
  ## occasionally, and inventing a project-relative identity for them would
  ## make a row claim the project contains a file it does not.
  if vfsPath.len == 0: return ""
  let prefix = producer.packageDir & "/"
  if producer.packageDir.len > 0 and vfsPath.startsWith(prefix):
    return producer.projectRoot & "/" & vfsPath[prefix.len .. ^1]
  vfsPath

proc buildSeverityOf*(severity: NoirDiagnosticSeverity): BuildLineSeverity =
  ## `PositionedDiagnostic.severity` → the pane's severity.
  ##
  ## THE FIELD MAPPING, and the reason the browser path never parses text.
  ## The desktop's Noir arm is being repaired for the opposite defect —
  ## `nargo`'s terminal output emits a box-drawing rule rather than `-->`, so
  ## its matcher mis-parses into a corrupted row with every severity forced to
  ## error. This side has structured objects and a four-case enum, so the
  ## mapping is total and exhaustive rather than a heuristic.
  ##
  ## `ndsBug` maps to `blsError` and that is a decision, not an oversight:
  ## `DiagnosticKind::Bug` is an internal compiler fault, which is not a
  ## warning and is certainly not information — a user whose build is broken
  ## by one must see it in the Problems panel's `pfErrors` filter.
  ##
  ## `ndsUnknown` also maps to `blsError`, for the opposite reason: a severity
  ## this build does not recognise must not be quietly filtered OUT of the
  ## errors view, which is where a user looks when a build fails. It is not
  ## silent about it — `problemMessage` prefixes the raw word — so the two
  ## are distinguishable in the pane even though they share a colour.
  case severity
  of ndsError: blsError
  of ndsWarning: blsWarning
  of ndsInfo: blsInfo
  of ndsBug: blsError
  of ndsUnknown: blsError

proc problemMessage*(diagnostic: NoirDiagnostic): string =
  ## The message a Problems row carries: the diagnostic, then the frontend's
  ## secondary labels and notes.
  ##
  ## Secondaries are NOT dropped. "expected type u8, found type ()" alone does
  ## not say where the `u8` came from; its secondaries — "expected u8 because
  ## of return type", "() returned here" — are the half of the diagnostic that
  ## makes it actionable, and `nargo`'s terminal rendering shows them.
  ##
  ## An unrecognised severity names itself here, because `buildSeverityOf`
  ## folds it into `blsError` and something has to keep the fact visible.
  result = ""
  if diagnostic.severity == ndsUnknown and diagnostic.severityText.len > 0:
    result.add "[" & diagnostic.severityText & "] "
  elif diagnostic.severity == ndsBug:
    result.add "[compiler bug] "
  result.add diagnostic.message
  for secondary in diagnostic.secondaryMessages:
    result.add " — " & secondary
  for note in diagnostic.notes:
    result.add " (note: " & note & ")"

proc problemOf*(producer: NoirBuildProducer;
                diagnostic: NoirDiagnostic): BuildProblemLine =
  ## `PositionedDiagnostic` → `BuildProblemLine`, field for field.
  ##
  ## `end_line`, `end_column`, `start` and `end` have no counterpart in
  ## `BuildProblemLine` and are deliberately not smuggled into the message:
  ## the pane navigates to a POINT, and a row reading "3:41-3:43" would be
  ## carrying a range no click can use. They stay on `NoirDiagnostic` for a
  ## caller that grows a range selection later.
  BuildProblemLine(
    severity: buildSeverityOf(diagnostic.severity),
    path: producer.rendererPath(diagnostic.file),
    line: diagnostic.line,
    col: diagnostic.column,
    message: problemMessage(diagnostic))

proc manifestRefusalProblem*(producer: NoirBuildProducer;
                             manifest, message: string;
                             line, column: int): BuildProblemLine =
  ## A RESOLVE refusal as a Problems row, from its four fields.
  ##
  ## `noir_build.nim`'s header fact 3: a refusal before compilation carries
  ## ZERO diagnostics and one positioned message, so a pane that rendered only
  ## `diagnostics` would paint nothing for the two most likely first-run
  ## mistakes — a `Nargo.toml` that names a git dependency, and a missing
  ## manifest. Both are errors and both point at a file the user can open.
  ##
  ## Takes the fields rather than a response because BOTH responses carry
  ## them: `resolve_vfs` is the same function behind `nv_compile_vfs` and
  ## `nv_test_vfs`, so a manifest that is refused for a Build is refused
  ## identically for a test run. Two copies of this would be two chances for
  ## one of them to stop pointing at the manifest.
  BuildProblemLine(
    severity: blsError,
    path: producer.rendererPath(manifest),
    line: line,
    col: column,
    message: message)

proc manifestProblem*(producer: NoirBuildProducer;
                      response: NoirCompileResponse): BuildProblemLine =
  ## A compile response's resolve refusal. See `manifestRefusalProblem`.
  producer.manifestRefusalProblem(
    response.manifest, response.message, response.line, response.column)

proc manifestProblem*(producer: NoirBuildProducer;
                      response: NoirTestResponse): BuildProblemLine =
  ## A test response's resolve refusal. Same four fields, same row.
  producer.manifestRefusalProblem(
    response.manifest, response.message, response.line, response.column)

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc emit(producer: NoirBuildProducer; text: string; isStdout: bool;
          severity: BuildLineSeverity = blsNone;
          path: string = ""; line: int = 0) =
  ## One rendered line, escaped.
  ##
  ## Split on newlines exactly as `build.processBuildOutput` does, so a
  ## multi-line message is as many rows as it has lines rather than one row
  ## with literal `\n` in it — the pane gives each row its own class and its
  ## own click target.
  for part in text.split('\n'):
    producer.vm.appendLine(BuildOutputLine(
      htmlText: escapeHtmlText(part),
      isStdout: isStdout,
      severity: severity,
      locationPath: path,
      locationLine: line))

proc note(producer: NoirBuildProducer; text: string) =
  ## A line the STUDIO wrote, not the toolchain. See `noirBuildFaultPrefix`.
  producer.emit(noirBuildFaultPrefix & text, isStdout = true)

proc paintDiagnostic(producer: NoirBuildProducer; diagnostic: NoirDiagnostic) =
  ## One diagnostic, in the pane's output stream AND in its Problems list.
  ##
  ## Both, because they are two different surfaces over the same fact and the
  ## desktop producer feeds both from one line
  ## (`build.appendBuild` → `appendLine` + `appendProblem`). Feeding only the
  ## Problems panel would leave the BUILD pane showing an exit code with no
  ## account of it.
  let problem = producer.problemOf(diagnostic)
  let located =
    if problem.path.len > 0 and problem.line > 0:
      problem.path & ":" & $problem.line &
        (if problem.col > 0: ":" & $problem.col else: "")
    else:
      ""
  let severityWord =
    case problem.severity
    of blsError: "error"
    of blsWarning: "warning"
    of blsInfo: "note"
    of blsNone: ""
  producer.emit(
    (if located.len > 0: located & ": " else: "") &
      (if severityWord.len > 0: severityWord & ": " else: "") &
      problem.message,
    isStdout = problem.severity != blsError,
    severity = problem.severity,
    path = problem.path,
    line = problem.line)
  producer.vm.appendProblem(problem)
  if not producer.onProblem.isNil:
    producer.onProblem(problem)
  producer.vm.appendError(BuildErrorLine(
    locationPath: problem.path,
    locationLine: problem.line,
    rawLocation: (if located.len > 0: located else: problem.path),
    other: problem.message))

# ---------------------------------------------------------------------------
# The three message kinds
# ---------------------------------------------------------------------------

proc newNoirBuildProducer*(vm: BuildVM; projectRoot, packageDir: string
                          ): NoirBuildProducer =
  NoirBuildProducer(
    vm: vm, projectRoot: projectRoot, packageDir: packageDir,
    phase: nbpCompile, stdoutText: "", stderrText: "", artifact: nil,
    lastVerdict: npvSucceeded, settled: true)

proc beginPhase*(producer: NoirBuildProducer; phase: NoirBuildPhase;
                 command: string; nowMs: float) =
  ## `CODETRACER::build-command`'s equivalent, and it does what
  ## `build.onBuildCommand` does in the same order: label, timestamp, running,
  ## then clear.
  ##
  ## The clear is LAST, matching the desktop, because `clearOutput` resets
  ## `code` and a `status` memo that recomputed between the writes would flash
  ## `bsIdle`.
  ##
  ## A COMPILE clears the carried artifact; a TRACE must not. A trace is the
  ## second half of one Run and the artifact is what the first half produced —
  ## clearing it here would make every Run trace `null`.
  producer.phase = phase
  producer.stdoutText = ""
  producer.stderrText = ""
  producer.settled = false
  if phase == nbpCompile:
    producer.artifact = nil
    producer.lastSummary = NoirTraceSummary()
  if phase == nbpTest:
    # The previous run's verdicts, gone before the new one starts. A pane that
    # kept them would show a green row for a test the current sources no longer
    # contain, which is the stalest thing a test pane can say.
    producer.lastTests = NoirTestResponse()
  producer.vm.setCommand(command)
  producer.vm.setBuildStartTime(nowMs)
  producer.vm.setRunning(true)
  if phase != nbpTrace:
    # Only the SECOND phase of a Run leaves the pane alone. A trace that wiped
    # it would delete the compile's own warnings before the user had read them.
    # A test run is a run of its own and starts from an empty pane, exactly as
    # a compile does.
    producer.vm.clearOutput()
    if not producer.onProblemsCleared.isNil:
      producer.onProblemsCleared()

proc onOutput*(producer: NoirBuildProducer; chunk: ProcessOutputChunk) =
  ## The worker's `output` message.
  ##
  ## stdout is BUFFERED and not painted: it is one JSON document, and a
  ## `VfsResponse` printed verbatim is not something anyone reads. stderr is
  ## painted immediately, because that is where `wasm_worker.finish` routes a
  ## worker-level failure — including the three module-load faults
  ## (`not-delivered` / `not-served` / `broken`), whose whole value is the
  ## sentence they carry.
  case chunk.stream
  of psStdout:
    producer.stdoutText.add chunk.text
  of psStderr:
    producer.stderrText.add chunk.text
    if chunk.text.len > 0:
      producer.emit(chunk.text, isStdout = false, severity = blsError)

proc paintCompileResult(producer: NoirBuildProducer;
                        response: NoirCompileResponse): NoirPhaseVerdict =
  ## Everything a decoded `VfsResponse` says, painted.
  if not response.decoded:
    producer.note(
      "the Noir compiler answered with something this build could not " &
      "decode as a compile result. That is a protocol fault, not a fault in " &
      "your program: nothing about it has been established.")
    if response.raw.len > 0:
      producer.emit(response.raw[0 ..< min(response.raw.len, 400)],
                    isStdout = false, severity = blsError)
    return npvFaulted

  # Warnings are painted on the way through whether or not the compile
  # succeeded, because a successful build with warnings is the normal case and
  # the pane is where they live.
  for warning in response.warnings:
    producer.paintDiagnostic(warning)

  if response.ok:
    producer.artifact = response.artifact
    if response.artifact.isNil:
      # `ok` with no artifact is `mode: "resolve"`, which this product never
      # asks for. Reaching it means the request was not the one this module
      # composed.
      producer.note(
        "the compiler reported success and produced no artifact. This build " &
        "only ever asks for `program` or `debug`, both of which compile, so " &
        "the request that was sent is not the one this build composes.")
      return npvFaulted
    let warningCount = response.warnings.len
    producer.note(
      "compiled " & producer.packageDir &
      (if warningCount > 0: " with " & $warningCount & " warning" &
        (if warningCount == 1: "" else: "s") else: " cleanly"))
    return npvSucceeded

  # A refusal. Two shapes, and they must not be collapsed: a resolve refusal
  # is positioned in a manifest and carries no diagnostics; a compile error
  # carries diagnostics and no manifest position.
  if hasRefusalPosition(response):
    let problem = producer.manifestProblem(response)
    let located =
      if problem.line > 0: problem.path & ":" & $problem.line &
        (if problem.col > 0: ":" & $problem.col else: "")
      else: problem.path
    producer.emit(located & ": error: " & problem.message,
                  isStdout = false, severity = blsError,
                  path = problem.path, line = problem.line)
    producer.vm.appendProblem(problem)
    producer.vm.appendError(BuildErrorLine(
      locationPath: problem.path, locationLine: problem.line,
      rawLocation: located, other: problem.message))
  for diagnostic in response.diagnostics:
    producer.paintDiagnostic(diagnostic)

  if response.diagnostics.len == 0 and not hasRefusalPosition(response):
    # Refused with nothing to point at. Still say what it said — an empty
    # pane over a failed build is the state this whole module exists to end.
    producer.note(
      "the Noir toolchain refused this build" &
      (if response.stage.len > 0: " at the " & response.stage & " stage" else: "") &
      (if response.kind.len > 0: " (" & response.kind & ")" else: "") & ".")
    if response.message.len > 0:
      producer.emit(response.message, isStdout = false, severity = blsError)
  return npvRefused

proc testMark(outcome: NoirTestOutcome): string =
  ## The glyph the build pane's row starts with.
  ##
  ## The SAME four glyphs `views/isonim_test_results_view.stateMark` uses, so a
  ## reader who has both panes open sees one vocabulary rather than two. They
  ## are spelled here rather than imported because this module is a ViewModel
  ## and that one is a View; importing a view from a producer would invert the
  ## layering the host-free gate enforces.
  case outcome.status
  of ntsPass: "\u2713"          ## ✓
  of ntsFail: "\u2717"          ## ✗
  of ntsCompileError: "!"
  of ntsSkipped: "\u2013"       ## –
  of ntsUnknown: "?"

proc paintTestResult(producer: NoirBuildProducer;
                     response: NoirTestResponse): NoirPhaseVerdict =
  ## Everything a decoded `TestVfsResponse` says, painted into the build pane.
  ##
  ## THE BUILD PANE AND NOT A NEW ONE, because the plumbing a failing test
  ## needs is the plumbing a failing build already has: a positioned message,
  ## a click that opens the file at the line, and a mirrored row in PROBLEMS.
  ## A test failure IS a diagnostic with a location, and giving it a second,
  ## poorer surface would be building a worse copy of a pane that works.
  if not response.decoded:
    producer.note(
      "the Noir toolchain answered with something this build could not " &
      "decode as a test result. That is a protocol fault, not a fault in " &
      "your tests: nothing about them has been established.")
    if response.raw.len > 0:
      producer.emit(response.raw[0 .. min(response.raw.high, 400)],
                    isStdout = false, severity = blsError)
    return npvFaulted

  if not response.ok:
    # The suite did not RUN. Distinct from a red suite in every way that
    # matters: no test reached a verdict, so there is nothing to report per
    # test, and the thing to fix is the project rather than an assertion.
    if response.manifest.len > 0:
      # A resolve refusal points at a manifest and carries no diagnostics —
      # `noir_build.nim`'s header fact 3. Painting only `diagnostics` here
      # would leave a missing `Nargo.toml` reported as an empty pane.
      let problem = producer.manifestProblem(response)
      let located =
        if problem.line > 0: problem.path & ":" & $problem.line &
          (if problem.col > 0: ":" & $problem.col else: "")
        else: problem.path
      producer.emit(located & ": error: " & problem.message,
                    isStdout = false, severity = blsError,
                    path = problem.path, line = problem.line)
      producer.vm.appendProblem(problem)
      if not producer.onProblem.isNil:
        producer.onProblem(problem)
      producer.vm.appendError(BuildErrorLine(
        locationPath: problem.path, locationLine: problem.line,
        rawLocation: located, other: problem.message))
    for diagnostic in response.diagnostics:
      producer.paintDiagnostic(diagnostic)
    if response.diagnostics.len == 0 and response.manifest.len == 0:
      producer.note(
        "the Noir toolchain could not run the tests" &
        (if response.stage.len > 0: " (refused at the " & response.stage &
                                    " stage)" else: "") &
        (if response.kind.len > 0: " [" & response.kind & "]" else: "") & ".")
      if response.message.len > 0:
        producer.emit(response.message, isStdout = false, severity = blsError)
    elif response.diagnostics.len > 0:
      producer.note(
        "the tests were not run: the project did not compile. " &
        $response.diagnostics.len & " diagnostic(s) above.")
    else:
      producer.note("the tests were not run; the refusal is above.")
    return npvRefused

  for warning in response.warnings:
    producer.paintDiagnostic(warning)

  if response.tests.len == 0:
    # A REAL AND DIFFERENT OUTCOME from a green run, and one a tally of zeroes
    # renders identically. `nargo test` over a package with no `#[test]`
    # functions succeeds and runs nothing, and a pane reporting "0 passed" as
    # success would be telling a user their tests pass when they have none.
    producer.note(
      "the project compiled and declares no tests. `nargo test` runs the " &
      "functions marked `#[test]`; this package has none.")
    return npvSucceeded

  for outcome in response.tests:
    let expectation = noirTestExpectationNote(outcome)
    let suffix = if expectation.len > 0: "  (" & expectation & ")" else: ""
    let path = producer.rendererPath(outcome.file)
    case outcome.status
    of ntsPass:
      producer.emit(testMark(outcome) & " " & outcome.name & suffix,
                    isStdout = true, severity = blsNone,
                    path = path, line = outcome.line)
    of ntsSkipped:
      producer.emit(testMark(outcome) & " " & outcome.name & suffix,
                    isStdout = true, severity = blsInfo,
                    path = path, line = outcome.line)
      if outcome.output.strip().len > 0:
        producer.emit("    " & outcome.output.strip(), isStdout = true,
                      severity = blsInfo, path = path, line = outcome.line)
    of ntsFail, ntsCompileError, ntsUnknown:
      producer.emit(testMark(outcome) & " " & outcome.name & suffix,
                    isStdout = false, severity = blsError,
                    path = path, line = outcome.line)
      # THE DIAGNOSTIC, when there is one, through the ordinary path — so a
      # failing assertion lands in PROBLEMS and jumps to the `assert` line
      # rather than to the `fn` line. That is the whole reason this pane was
      # chosen: the affordance already exists and already works.
      if outcome.hasDiagnostic:
        producer.paintDiagnostic(outcome.diagnostic)
      else:
        let text = noirTestFailureText(outcome)
        if text.len > 0:
          producer.emit("    " & text, isStdout = false, severity = blsError,
                        path = path, line = outcome.line)
    if outcome.status != ntsSkipped and outcome.output.strip().len > 0:
      # What the test PRINTED. Indented under its row and marked as ordinary
      # output, because it is the program talking rather than the runner.
      for printed in outcome.output.strip().split('\n'):
        producer.emit("    " & printed, isStdout = true, severity = blsNone,
                      path = path, line = outcome.line)

  producer.note(
    $response.passed & " passed, " & $response.failed & " failed" &
    (if response.skipped > 0: ", " & $response.skipped & " skipped" else: "") &
    " of " & $response.tests.len & " test(s)")

  if response.failed > 0: npvRefused else: npvSucceeded

proc onExit*(producer: NoirBuildProducer; exit: ProcessExit): NoirPhaseVerdict =
  ## The worker's `exit` message — and its `failed` message, which
  ## `wasm_worker.deliver` also delivers here, with exit code 1.
  ##
  ## `build.onBuildCode`'s equivalent, and like it the LAST thing it does is
  ## `setCode`, which flips `running` false and lets `status` recompute once.
  if producer.settled:
    return producer.lastVerdict
  producer.settled = true

  if exit.signalled:
    # `process.nim`'s distinction, honoured: a stop is not a failure.
    producer.note(
      "stopped" & (if exit.signalName.len > 0: " (" & exit.signalName & ")" else: "") &
      ". A stopped run establishes nothing about the program.")
    producer.lastVerdict = npvCancelled
    producer.vm.setCode(exit.exitCode)
    return producer.lastVerdict

  case producer.phase
  of nbpCompile:
    producer.lastVerdict = producer.paintCompileResult(
      parseNoirCompileResponse(producer.stdoutText))
  of nbpTest:
    let response = parseNoirTestResponse(producer.stdoutText)
    producer.lastTests = response
    producer.lastVerdict = producer.paintTestResult(response)
  of nbpTrace:
    let summary = summariseNoirTrace(producer.stdoutText)
    producer.lastSummary = summary
    if exit.exitCode != 0 or not summary.decoded:
      producer.note(
        "the tracer did not produce a trace" &
        (if producer.stderrText.len == 0 and summary.bytes > 0:
           " (it answered " & $summary.bytes & " bytes that are not a trace)"
         else: "") & ".")
      producer.lastVerdict = npvFaulted
    elif isTrivialTrace(summary):
      # `compare.mjs`'s ONE-EVENT-ZERO-STEPS shape, surfaced instead of
      # celebrated. Both modules can answer `ok` over a trace with nothing in
      # it, and reporting that as a successful Run is the chain-of-agreements
      # failure this campaign keeps meeting.
      producer.note(
        "traced " & $summary.events & " event(s) and " & $summary.steps &
        " step(s) — a trace with no steps is not one you can step through. " &
        "An artifact compiled without instrumentation produces exactly this.")
      producer.lastVerdict = npvFaulted
    else:
      producer.note(
        "traced " & $summary.events & " events, " & $summary.steps &
        " steps, " & $summary.calls & " calls across " & $summary.paths.len &
        " source file(s)")
      for path in summary.paths:
        producer.emit("  " & producer.rendererPath(path), isStdout = true,
                      severity = blsInfo, path = producer.rendererPath(path),
                      line = 1)
      producer.lastVerdict = npvSucceeded
      # THE TRACE IS HANDED ON WHILE IT STILL EXISTS.
      #
      # `producer.stdoutText` is the whole `MemoryTrace` document and this is
      # the only moment it is both complete and still there: `beginPhase`
      # clears it, so a session asked for after the next Build would be opened
      # over an empty string. It is also the moment the trace has just been
      # judged good, which is the right precondition for opening a debugger
      # over it — the two arms above have already refused a trace with no
      # steps and one the tracer could not decode.
      #
      # ASKED FOR, NOT ASSUMED. `requestReplaySession` answers `false` on a
      # desktop build, in the extension, and in a web deployment that ships no
      # engine. All three must keep showing the summary rows above, so the
      # pane says which of the two happened rather than leaving a user to
      # infer it from a debugger that did or did not appear.
      # CONTAINED, and this is not defensive habit. `onExit` still has work to
      # do after this line — `setCode` and `setStatus` are what tell the pane
      # the Build finished — so an exception escaping a replay attempt would
      # abort the BUILD's own bookkeeping and leave a pane that traced 10
      # steps looking like it was still running. Measured exactly that way:
      # the rows painted, the two `note` calls below never ran, and the tab
      # reported one uncaught page error with no message a user could read.
      var opened = false
      var refusal = ""
      try:
        opened = requestReplaySession(ReplaySessionRequest(
          rawMemoryTrace: producer.stdoutText,
          packageDir: producer.packageDir,
          projectRoot: producer.projectRoot))
      except CatchableError as e:
        refusal = e.msg
      except:
        # A BARE arm too: under `nim js` a `Defect` and a raw JS throw are
        # neither `CatchableError`, and the whole point of this block is that
        # nothing gets past it.
        refusal = "the replay host raised a value that is not an exception"
      if opened:
        producer.note("opening a replay session over this trace")
      elif refusal.len > 0:
        producer.note("a replay session could not be started: " & refusal)
      else:
        # SAID OUT LOUD, and this row is the product's answer rather than a
        # diagnostic. A user who has just watched a program be traced and sees
        # no debugger appear is owed the reason, and "nothing happened" is the
        # one thing a pane must never mean. It is also what tells a gate the
        # difference between a deployment that ships no engine and a wiring
        # defect that silently declined to open one.
        producer.note(
          "this build cannot replay a trace in the tab (" &
          (if replaySessionServiceInstalled(): "the session was declined"
           else: "no replay host is installed") &
          "); the rows above are what the trace contains")

  # A verdict and an exit code must agree, and the VERDICT is the authority.
  # The worker sets a compile's exit code from `response.ok`, so the two
  # normally match; when they do not — an `exit: 0` over an undecodable
  # response — a pane trusting the code would paint `bsSucceeded` over a build
  # that established nothing.
  producer.vm.setCode(
    if producer.lastVerdict == npvSucceeded: 0
    elif exit.exitCode != 0: exit.exitCode
    else: 1)
  producer.lastVerdict

proc onRefusal*(producer: NoirBuildProducer; message: string): NoirPhaseVerdict =
  ## The run never started: `wasm_registry.refusal`'s sentence, or a platform
  ## that cannot spawn at all.
  ##
  ## A separate entry point from `onExit` because there is no exit — nothing
  ## ran. Reporting it as `exit 1` would put a build that never happened in
  ## the same state as one that failed, and the four `wasm_registry` refusals
  ## exist precisely so a user is not told the wrong one.
  if producer.settled:
    return producer.lastVerdict
  producer.settled = true
  producer.note(message)
  producer.lastVerdict = npvFaulted
  producer.vm.setCode(1)
  producer.lastVerdict

proc traceInputsMissing*(producer: NoirBuildProducer; inputsPath: string
                        ): NoirPhaseVerdict =
  ## Run asked for, and the project has no inputs to run WITH.
  ##
  ## `tracer_wasm/src/lib.rs`: "`inputs` is the text of a `Prover.toml`". A
  ## `bin` package with no `Prover.toml` has no values for `main`'s
  ## parameters, and there is no honest default — zeroes would satisfy the
  ## types and fail the assertions, which reads as "your program is broken"
  ## about a program that is fine.
  producer.note(
    "this project has no " & inputsPath & ", so there are no inputs to run " &
    "it with. A Noir `bin` package takes its arguments from that file; add " &
    "one naming every parameter of `main` and Run again.")
  producer.lastVerdict = npvFaulted
  producer.vm.setCode(1)
  producer.lastVerdict
