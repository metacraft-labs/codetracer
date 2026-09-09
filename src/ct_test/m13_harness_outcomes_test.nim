## Outcome reporting for the M13 smart-contract and VM recorder harnesses.
##
## Split out of `m13_smart_contract_harnesses_test.nim` deliberately. That file
## is gated behind `CT_M16_HEAVY` in `ci/test/m16-release-gate.sh` because its
## cases need the sibling recorder repositories checked out, real recorder
## binaries, and a full `nim c` of `ct_test.nim`. Nothing here needs any of
## that -- the recorder is a stub script this file writes, and the CLI is
## driven in-process -- so gating these cases behind an opt-in flag would leave
## the regression they guard against unguarded on every ordinary CI run. A
## guard that does not run is not a guard.
##
## ---------------------------------------------------------------------------
## THE STUB RECORDER, AND WHY THERE IS ONE
## ---------------------------------------------------------------------------
##
## The fourteen M13 recorders are Rust sibling repositories this workspace does
## not build, and the behaviour under test is what the harness reports when a
## recorder FAILS -- which no real recorder can be asked for on demand anyway.
##
## What this file writes is a stub BINARY, not a mock object: nothing inside
## `smart_contract_common` is replaced, injected or intercepted. The provider
## discovers it exactly the way it discovers a real recorder (in
## `<repo>/target/debug/<binary>`, the location `just build-siblings`
## produces), launches it as a real subprocess through the real
## `process_exec.execCapturedShell`, and reads a real exit code and a real
## filesystem for the artifact. The stub's whole surface is the recorder CLI
## contract `SmartHarnessSpec.stableTestCommand` already documents:
## `<binary> record <file.cairo> --out-dir <dir>`, plus the `--help` banner
## `smart_contract_common.recorderHelpLooksReal` requires before it will trust
## a binary named by `<SPEC>_CMD`.

import std/[json, options, os, strutils, tables, unittest]

import certificate_issuance
import contracts
import ct_test
import discovery
import run_orchestration
import frameworks/native_m11_common
import frameworks/smart_contract_common
import frameworks/smart_contract_harnesses

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

proc trailingKinds(events: seq[TestEvent]; count: int): seq[TestEventKind] =
  ## The kinds of the last ``count`` events, in order.
  ##
  ## Order matters and is asserted rather than assumed: the reason has to reach
  ## a reader before the outcome that follows from it, and every other provider
  ## in this family emits the same three-event tail.
  for i in max(0, events.len - count) ..< events.len:
    result.add events[i].kind

proc clearRecorderEnv(spec: SmartHarnessSpec) =
  putEnv(spec.envCommand, "")

type StubBehaviour = enum
  ## What the stub recorder does when it is asked to record.
  sbRecords          ## writes a non-empty `.ct` into `--out-dir`, exits 0
  sbFails            ## exits 3 without writing anything
  sbNoArtifact       ## exits 0 but leaves `--out-dir` empty
  sbSignalled        ## writes the artifact, then kills itself with SIGKILL

const StubRecorderPreamble = """#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = "--help" ]; then
    printf 'codetracer-cairo-recorder (CodeTracer Cairo recorder, stub)\n'
    printf 'usage: codetracer-cairo-recorder record <file.cairo> --out-dir <dir>\n'
    exit 0
  fi
done
out_dir=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--out-dir" ]; then out_dir="$arg"; fi
  prev="$arg"
done
"""

proc stubBody(behaviour: StubBehaviour): string =
  case behaviour
  of sbRecords:
    "mkdir -p \"$out_dir\"\n" &
    "printf 'ct-stub-trace-bytes' > \"$out_dir/flow_test.ct\"\n" &
    "exit 0\n"
  of sbFails:
    "printf 'cairo recorder: parse error at line 3\\n' >&2\n" &
    "exit 3\n"
  of sbNoArtifact:
    "mkdir -p \"$out_dir\"\n" &
    "exit 0\n"
  of sbSignalled:
    "mkdir -p \"$out_dir\"\n" &
    "printf 'ct-stub-trace-bytes' > \"$out_dir/flow_test.ct\"\n" &
    "kill -9 $$\n"

proc stubWorkspace(name: string; behaviour: StubBehaviour;
    withFixture = true): string =
  ## A throwaway workspace shaped like the one `ct test --workspace` is given:
  ## a recorder repo checked out inside it, one fixture under the repo's
  ## declared `fixtureRoots`, and a recorder binary where
  ## `configuredRecorderCommand` looks for one.
  let spec = cairoSpec()
  result = getTempDir() / ("ct-m13-outcome-" & name & "-" &
    $getCurrentProcessId())
  removeDir(result)
  let repo = result / spec.recorderRepo
  createDir(repo / "test-programs" / "cairo")
  if withFixture:
    writeFile(repo / "test-programs" / "cairo" / "flow_test.cairo",
      "fn main() {\n    let answer = 42;\n}\n")
  createDir(repo / "target" / "debug")
  let binary = repo / "target" / "debug" / spec.recorderBinary
  writeFile(binary, StubRecorderPreamble & stubBody(behaviour))
  setFilePermissions(binary, {fpUserExec, fpUserRead, fpUserWrite})

proc stubFixture(root: string): string =
  root / cairoSpec().recorderRepo / "test-programs" / "cairo" /
    "flow_test.cairo"

proc stubRecorderBinary(root: string): string =
  let spec = cairoSpec()
  root / spec.recorderRepo / "target" / "debug" / spec.recorderBinary

proc driveHarness(root: string;
    mode: TestRunMode): ProviderResult[seq[TestEvent]] =
  ## Run (or record) the workspace's single fixture through the real provider.
  ##
  ## Discovery is not bypassed: the scope handed to the provider is built from
  ## the catalog item the provider itself produced, so a change that breaks the
  ## wiring between the two shows up here rather than being papered over by a
  ## hand-written scope.
  let spec = cairoSpec()
  clearRecorderEnv(spec)
  let provider = newSmartHarnessProvider(spec)
  let catalog = provider.provider.discoverFile(root, stubFixture(root)).value
  require catalog.items.len == 1
  let item = catalog.items[0]
  let scope = TestScope(kind: tskFile, projectRoot: root,
      file: stubFixture(root), selector: item.selector, testId: item.id)
  if mode == trmRecord: provider.provider.record(scope)
  else: provider.provider.run(scope)

proc singleUnitRunResult(providerId: string;
    runResult: ProviderResult[seq[TestEvent]]): TestRunResult =
  ## Wrap one provider's REAL event stream in the shape `summarize` reduces.
  ##
  ## The counting assertions below go through the shipped counter rather than
  ## re-deriving the tallies here: a test that counts the events itself pins
  ## its own arithmetic and would pass against any counter, including one that
  ## ignores `tekTestFinished` entirely -- which is the defect.
  ##
  ## A deliberate twin of the identical helper in
  ## `m11_native_languages_test.nim`. It is twelve lines of scaffolding whose
  ## only contract is "`summarize` sees exactly this provider's events", and
  ## sharing it would mean exporting it from a new `src/ct_test` module for the
  ## sake of two test files that run in two different CI lanes.
  TestRunResult(
    totalDiscovered: 1,
    skippedByPartition: 0,
    dispatchedUnits: 1,
    threads: 1,
    wallTimeMs: 0,
    outcomes: @[RunUnitOutcome(
      providerId: providerId,
      testId: "unit-1",
      unrunnable: false,
      events: runResult.value,
      diagnostics: runResult.diagnostics)])

suite "ct-test M13 harness outcomes are reported and counted":
  ## THE REGRESSION, for the fourteen M13 smart-contract and VM harnesses.
  ##
  ## `run_orchestration.summarize` and `certificate_issuance.recordUnitResult`
  ## count `tekTestFinished` and nothing else. `runRecorderCommand` emitted one
  ## only when the recorder succeeded; when the recorder failed, or produced no
  ## trace, it emitted a `tekFailure` and a `tekRecordFinished`/`tekRunFinished`
  ## instead, and neither is counted. A workspace whose fixtures all failed
  ## therefore reported `executed 0, failed 0`, took the "nothing-executed"
  ## verdict and exited `ExitNothingExecuted` (2) -- byte-identical to a run
  ## that never happened.
  ##
  ## The requirement, from test-certificates-spec `Standard.md`:
  ##
  ## * §3.1 -- `passed` is the only value supporting a positive claim, so a
  ##   fixture whose recorder exited non-zero (or crashed) must never finish
  ##   `tsPassed`; and
  ## * §8 -- "Producers MUST NOT claim targets that did not run", which is only
  ##   enforceable if "ran and failed" and "did not run" stay distinguishable.
  ##
  ## The assertions are on `RunVerdict` / `ExitTestsFailed` /
  ## `ExitNothingExecuted` symbols rather than on the integers 1 and 2: the
  ## requirement is that the two outcomes are never confusable, and the
  ## particular numbers are only today's spelling of it.

  test "the shared emitter closes a RECORDING with the trace it produced":
    ## OWNS: the record-shaped contract of the shared emitter.
    ##
    ## `native_m11_common.recordCommand` (the M11 file-recording path) and
    ## `smart_contract_common.runRecorderCommand` both close with
    ## `tekRecordFinished` and hang the produced trace on it, and both now go
    ## through `unitOutcomeEvents`. Asserted directly here because the M11
    ## recorder binary (`ct-mcr`) is not built in this workspace, so its own
    ## path cannot be driven end to end -- and an emitter whose record shape is
    ## only exercised through one of its two callers is how the run and record
    ## tails drifted apart in the first place.
    var metadata = initTable[string, string]()
    metadata["catalogTestId"] = "unit-1"
    let trace = TraceMetadata(traceId: "t", recordingId: "t", path: "/tmp",
        backend: "native", entryPoint: "e", metadata: metadata)

    let recorded = unitOutcomeEvents("native-m11", "run-1", "unit-1", tsPassed,
        "", finishedKind = tekRecordFinished, trace = some(trace))
    check recorded.len == 2
    check recorded[0].kind == tekTestFinished
    check recorded[0].status.get == tsPassed
    check recorded[0].message == "passed"
    # The trace rides on the CLOSING event only, which is exactly where the
    # hand-written copies put it.
    check recorded[0].trace.isNone
    check recorded[1].kind == tekRecordFinished
    check recorded[1].status.get == tsPassed
    check recorded[1].message == "passed"
    check recorded[1].output == ""
    check recorded[1].trace.isSome

    let failed = unitOutcomeEvents("native-m11", "run-1", "unit-1", tsFailed,
        "ct-mcr exited with 1", "boom", finishedKind = tekRecordFinished)
    check failed.len == 3
    check failed[0].kind == tekFailure
    check failed[0].message == "ct-mcr exited with 1"
    check failed[1].kind == tekTestFinished
    check failed[1].status.get == tsFailed
    check failed[1].message == "failed"
    check failed[2].kind == tekRecordFinished
    check failed[2].status.get == tsFailed
    check failed[2].trace.isNone
    # The captured output rides on the `tekFailure` and NOWHERE else. The
    # closing event's `output` is hard-coded empty, and that is load-bearing
    # rather than incidental: the fourteen providers that reach this emitter
    # through the exit-code overload emitted a closing event with an empty
    # `output` before the collapse, and their event streams must stay
    # byte-identical across it. Pinned on the FAILING case because that is the
    # only one whose `output` argument is non-empty, so it is the only one
    # where a leak would be visible.
    check failed[0].output == "boom"
    check failed[1].output == ""
    check failed[2].output == ""
    for event in recorded & failed:
      check event.validateEvent.valid

  test "a recorder that fails finishes the fixture as failed, and says why":
    ## OWNS: the events on the command-failure branch, and in particular the
    ## `tekFailure` that carries the reason and the captured output beside the
    ## `tekTestFinished` the counters read. Neither substitutes for the other:
    ## drop the failure event and a human loses the reason; drop the finished
    ## event and the run loses the test.
    let root = stubWorkspace("failing", sbFails)
    defer: removeDir(root)
    let runResult = driveHarness(root, trmRun)
    if runResult.diagnostics.len != 1:
      checkpoint($runResult.diagnostics)
      checkpoint($runResult.value)

    # Reported through diagnostics AND events; neither stands in for the other.
    check runResult.diagnostics.len == 1
    if runResult.diagnostics.len == 1:
      check runResult.diagnostics[0].severity == dsError
      check runResult.diagnostics[0].message.contains(
        "recorder command failed with exit code 3")

    let failures = runResult.value.eventsOfKind(tekFailure)
    check failures.len == 1
    if failures.len == 1:
      check failures[0].status.get == tsFailed
      check failures[0].message == "recorder command exited with 3"
      check failures[0].output.contains("parse error at line 3")

    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 1
    if finished.len == 1:
      check finished[0].status.get == tsFailed
      check finished[0].message == "failed"

    let closing = runResult.value.eventsOfKind(tekRunFinished)
    check closing.len == 1
    if closing.len == 1:
      check closing[0].status.get == tsFailed
      check closing[0].message == "failed"
      # Nothing was recorded, so the closing event may not carry a trace …
      check closing[0].trace.isNone
    # … and nothing may announce one either.
    check runResult.value.eventsOfKind(tekRecordingCreated).len == 0

    # The order every provider in this family emits: the reason, then the event
    # the counters read, then the closing event.
    check runResult.value.trailingKinds(3) ==
      @[tekFailure, tekTestFinished, tekRunFinished]
    for event in runResult.value:
      check event.validateEvent.valid

  test "a failing M13 fixture is COUNTED as one failed test, not as nothing":
    ## OWNS: the counting, and the verdict and exit code that follow from it.
    ##
    ## The tallies come out of the SHIPPED `summarize` rather than from a
    ## recount written beside the assertion, so a counter that stops reading
    ## `tekTestFinished` reddens this case even with the event emitted.
    let root = stubWorkspace("counted", sbFails)
    defer: removeDir(root)
    let summary = summarize(singleUnitRunResult("smart-cairo",
        driveHarness(root, trmRun)))
    check summary.executed == 1
    check summary.failed == 1
    check summary.passed == 0
    check summary.skipped == 0
    check summary.runVerdict == rvFailed
    check summary.runExitCode == ExitTestsFailed
    # Said the other way round, because this is the confusion the fix removes:
    # a suite that failed must not report what a suite that never ran reports.
    check summary.runVerdict != rvNothingExecuted
    check summary.runExitCode != ExitNothingExecuted

  test "a recorder that produces no trace is counted as one errored test":
    ## OWNS: the artifact-missing branch.
    ##
    ## `tsErrored` rather than `tsFailed`: the recorder claimed success and
    ## there is nothing to replay, which is a broken harness rather than a
    ## failing fixture. `summarize` folds both into `failed` and neither may be
    ## attested, so the distinction is for the reader — but it must survive,
    ## and the unit must still be counted as having run.
    let root = stubWorkspace("no-artifact", sbNoArtifact)
    defer: removeDir(root)
    let runResult = driveHarness(root, trmRun)

    # The REASON, on this branch too. The emitter emits `tekFailure` for
    # `tsFailed` AND `tsErrored`, and for nothing else; narrow that guard to
    # `tsFailed` alone and an errored fixture still counts correctly while the
    # only event carrying "what went wrong" disappears — a regression every
    # count-based assertion below is blind to. `tekTestFinished` is what the
    # counters read; `tekFailure` is what a human reads; neither substitutes
    # for the other, on either failing status.
    let failures = runResult.value.eventsOfKind(tekFailure)
    check failures.len == 1
    if failures.len == 1:
      check failures[0].status.get == tsErrored
      check failures[0].message ==
        "recorder did not produce a non-empty .ct artifact"

    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 1
    if finished.len == 1:
      check finished[0].status.get == tsErrored
      check finished[0].message == "errored"
    check runResult.value.eventsOfKind(tekRecordingCreated).len == 0
    for event in runResult.value:
      check event.validateEvent.valid

    let summary = summarize(singleUnitRunResult("smart-cairo", runResult))
    check summary.executed == 1
    check summary.failed == 1
    check summary.passed == 0
    check summary.runVerdict == rvFailed
    check summary.runExitCode == ExitTestsFailed

  test "a successful recorder emits exactly the events it always did":
    ## OWNS: the passing path, in BOTH modes.
    ##
    ## The fix routes three branches through one emitter, so a mistake there
    ## could just as easily turn passes into failures, move the trace off the
    ## closing event, or close a recording with the run-mode event kind. The
    ## message TEXT is pinned too: the hand-written tail spelled it as the
    ## literal `"passed"`, the emitter spells it `$status`, and the two agree
    ## only because `TestResultStatus` declares `tsPassed = "passed"` — nothing
    ## else in this suite would notice if that stopped being true.
    for mode in [trmRun, trmRecord]:
      let root = stubWorkspace("passing-" & $mode, sbRecords)
      defer: removeDir(root)
      let runResult = driveHarness(root, mode)
      if runResult.diagnostics.len > 0:
        checkpoint($mode & " diagnostics: " & $runResult.diagnostics)
        checkpoint($mode & " events: " & $runResult.value)
      check runResult.diagnostics.len == 0
      check runResult.value.eventsOfKind(tekFailure).len == 0

      let created = runResult.value.eventsOfKind(tekRecordingCreated)
      check created.len == 1
      if created.len == 1:
        check created[0].message == "recorded"
        check created[0].trace.isSome

      let finished = runResult.value.eventsOfKind(tekTestFinished)
      check finished.len == 1
      if finished.len == 1:
        check finished[0].status.get == tsPassed
        check finished[0].message == "passed"
        check finished[0].trace.isNone

      let closingKind =
        if mode == trmRecord: tekRecordFinished else: tekRunFinished
      let otherKind =
        if mode == trmRecord: tekRunFinished else: tekRecordFinished
      let closing = runResult.value.eventsOfKind(closingKind)
      check closing.len == 1
      if closing.len == 1:
        check closing[0].status.get == tsPassed
        check closing[0].message == "passed"
        check closing[0].output == ""
        check closing[0].trace.isSome
      check runResult.value.eventsOfKind(otherKind).len == 0

      check runResult.value.trailingKinds(3) ==
        @[tekRecordingCreated, tekTestFinished, closingKind]
      for event in runResult.value:
        check event.validateEvent.valid

  test "only exit code ZERO is a pass, so a signalled recorder is not":
    ## OWNS: `statusForExitCode`'s boundary.
    ##
    ## The predicate is "exactly zero", NOT "greater than zero", because the
    ## negative half of the range is reachable: `process_exec.execCaptured`
    ## reports a child killed by a SIGNAL as `-1` (runquota's
    ## `waitForCompletion` takes the `WIFSIGNALED` branch and leaves the
    ## `exitCode: -1` the completion was initialised with). Spelled `> 0`, a
    ## recorder that segfaults would be attested `tsPassed`, which
    ## `Standard.md` §3.1 forbids outright.
    check statusForExitCode(0) == tsPassed
    check statusForExitCode(1) == tsFailed
    check statusForExitCode(3) == tsFailed
    check statusForExitCode(-1) == tsFailed
    check statusForExitCode(-9) == tsFailed

    # And the same requirement end to end, in the shape that makes it bite: a
    # recorder that writes a perfectly good trace and is THEN killed. The
    # artifact exists, so the exit-code predicate is the only thing standing
    # between this fixture and a positive claim.
    let root = stubWorkspace("signalled", sbSignalled)
    defer: removeDir(root)
    let runResult = driveHarness(root, trmRun)
    let failures = runResult.value.eventsOfKind(tekFailure)
    if failures.len == 1:
      checkpoint("signalled recorder reported: " & failures[0].message)
    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 1
    if finished.len == 1:
      check finished[0].status.get != tsPassed
    check runResult.diagnostics.len == 1
    let summary = summarize(singleUnitRunResult("smart-cairo", runResult))
    check summary.executed == 1
    check summary.failed == 1
    check summary.passed == 0
    check summary.runExitCode != ExitNothingExecuted

  test "the shipped CLI tells a failing M13 workspace from an empty one":
    ## OWNS: the end-to-end requirement, through the real CLI entry point and
    ## the real default provider registry.
    ##
    ## `Standard.md` §8 -- "Producers MUST NOT claim targets that did not run".
    ## A run in which every fixture failed and a run that executed nothing
    ## support the same (empty) positive claim but call for entirely different
    ## investigations, and `ExitNothingExecuted` exists precisely to keep them
    ## apart. Before the fix they were indistinguishable for these providers:
    ## same counts, same verdict, same exit code, same withheld reason.
    ##
    ## The summary is read back from `--summary <path>`, the documented way a
    ## machine consumer reads a run, rather than by scraping stdout.
    let spec = cairoSpec()
    let originalEnv = getEnv(spec.envCommand, "")
    defer: putEnv(spec.envCommand, originalEnv)

    proc runWorkspace(root: string): (int, JsonNode) =
      ## `newSmartHarnessProvider` computes the capabilities the registry
      ## stores with NO project root, so `<SPEC>_CMD` is the only way to reach
      ## a recorder that `run_orchestration` will dispatch to; see the KNOWN
      ## GAP note on that proc. The registry is therefore built AFTER the
      ## variable is set, which is what a user with a built recorder does.
      putEnv(spec.envCommand, stubRecorderBinary(root))
      let summaryPath = root / "summary.json"
      let code = runCtTest(
        @["test", "run", "--workspace", root, "--summary", summaryPath,
          "--threads", "1"],
        newDefaultProviderRegistry(), newDiscoveryCache())
      require fileExists(summaryPath)
      (code, parseJson(readFile(summaryPath)))

    let failing = stubWorkspace("cli-failing", sbFails)
    defer: removeDir(failing)
    let (failingCode, failingSummary) = runWorkspace(failing)
    checkpoint("failing: " & $failingSummary)
    check failingCode == ExitTestsFailed
    check failingSummary["verdict"].getStr == $rvFailed
    check failingSummary["executed"].getInt == 1
    check failingSummary["failed"].getInt == 1
    require failingSummary.hasKey("certificate")
    require failingSummary["certificate"].hasKey("withheld_reason")
    check failingSummary["certificate"]["issued"].getBool == false
    # §3.1 again: a run with a failed test may not be attested, and the reason
    # it is withheld for must be the failure, not "nothing ran".
    check failingSummary["certificate"]["withheld_reason"].getStr ==
      $wrTestsFailed

    # The contrast, in the same shape: the same recorder repo and the same
    # working recorder, and no fixture for it to record.
    let empty = stubWorkspace("cli-empty", sbFails, withFixture = false)
    defer: removeDir(empty)
    let (emptyCode, emptySummary) = runWorkspace(empty)
    checkpoint("empty: " & $emptySummary)
    check emptyCode == ExitNothingExecuted
    check emptySummary["verdict"].getStr == $rvNothingExecuted
    check emptySummary["executed"].getInt == 0
    check emptySummary["failed"].getInt == 0
    require emptySummary.hasKey("certificate")
    require emptySummary["certificate"].hasKey("withheld_reason")
    check emptySummary["certificate"]["issued"].getBool == false
    check emptySummary["certificate"]["withheld_reason"].getStr ==
      $wrNoTestsExecuted

    # Stated as an inequality too, because "not confusable" is the requirement
    # and the values above are only today's spelling of it.
    check failingCode != emptyCode
    check failingSummary["verdict"].getStr != emptySummary["verdict"].getStr

    # And the third outcome, so the fix cannot be "report everything failed":
    # a workspace whose recorder works still passes and still exits 0.
    let passing = stubWorkspace("cli-passing", sbRecords)
    defer: removeDir(passing)
    let (passingCode, passingSummary) = runWorkspace(passing)
    checkpoint("passing: " & $passingSummary)
    check passingCode == ExitRunPassed
    check passingSummary["verdict"].getStr == $rvPassed
    check passingSummary["executed"].getInt == 1
    check passingSummary["passed"].getInt == 1
    check passingSummary["failed"].getInt == 0
