import std/[json, options, os, osproc, sequtils, strutils, unittest]

import certificate_issuance
import contracts
import ct_test
import discovery
import run_orchestration
import frameworks/crystal_spec
import frameworks/d_unittest
import frameworks/go_test
import frameworks/native_m11_common

proc goRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/go_test_project"

proc goFile(): string =
  goRoot() / "calculator_test.go"

proc dRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/d_unittest_project"

proc dFile(): string =
  dRoot() / "source/calculator.d"

proc crystalRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/crystal_spec_project"

proc crystalFile(): string =
  crystalRoot() / "spec/calculator_spec.cr"

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc itemByName(catalog: TestCatalog; name: string): TestItem =
  for item in catalog.items:
    if item.name == name:
      return item
  raise newException(ValueError, "missing name: " & name)

proc selectors(catalog: TestCatalog): seq[string] =
  catalog.items.mapIt(it.selector)

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

proc compileCtTestBinary(name: string): string =
  let binary = getTempDir() / (name & "-" & $getCurrentProcessId())
  let compile = execCmdEx(
    "nim c --hints:off --warnings:off --nimcache:/tmp/ct-nim-cache/" & name &
    " -o:" & quoteShell(binary) & " src/ct_test/ct_test.nim",
    options = {poUsePath},
    workingDir = getCurrentDir())
  if compile.exitCode != 0:
    checkpoint(compile.output)
  check compile.exitCode == 0
  if fileExists(binary):
    binary
  else:
    binary & ".out"

proc checkPassedRun(runResult: ProviderResult[seq[TestEvent]]) =
  if runResult.diagnostics.len > 0:
    checkpoint($runResult.diagnostics)
    checkpoint($runResult.value)
  check runResult.diagnostics.len == 0
  let finished = runResult.value.eventsOfKind(tekTestFinished)
  check finished.len > 0
  if finished.len > 0:
    check finished[0].status.get == tsPassed
  for event in runResult.value:
    check event.validateEvent.valid

proc scratchGoModule(name, testFileName, source: string): string =
  ## Materialise a throwaway single-file Go module outside the repo.
  ##
  ## Scratch rather than a checked-in fixture on purpose: the discovery
  ## assertions above pin ``go_test_project``'s exact item count and selector
  ## list, so a second test file dropped in there would redden a test that has
  ## nothing to do with failure reporting. The module declares no dependencies,
  ## so ``go test`` needs no module cache and no network.
  result = getTempDir() / (name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  writeFile(result / "go.mod", "module " & name.replace("-", "") & "\n\ngo 1.21\n")
  writeFile(result / testFileName, source)

proc singleUnitRunResult(providerId: string;
    runResult: ProviderResult[seq[TestEvent]]): TestRunResult =
  ## Wrap one provider's REAL event stream in the shape ``summarize`` reduces.
  ##
  ## The counting assertions go through the shipped counter rather than
  ## re-deriving the tallies here: a test that counts the events itself pins
  ## its own arithmetic and would pass against any counter, including one that
  ## ignores ``tekTestFinished`` entirely — which is the defect.
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

proc checkNonEmptyCtArtifact(events: seq[TestEvent]; label: string): string =
  let created = events.eventsOfKind(tekRecordingCreated)
  check created.len == 1
  if created.len == 0 or created[0].trace.isNone:
    return ""
  let trace = created[0].trace.get
  var candidates: seq[string] = @[]
  if trace.recordingId.len > 0:
    candidates.add trace.path / (trace.recordingId & ".ct")
  if trace.traceId.len > 0 and trace.traceId != trace.recordingId:
    candidates.add trace.path / (trace.traceId & ".ct")
  for path in candidates:
    if fileExists(path):
      let size = getFileSize(path)
      checkpoint(label & " .ct artifact: " & path & " (" & $size & " bytes)")
      check size > 0
      return path
  checkpoint(label & " missing .ct artifact; candidates: " & $candidates)
  check false
  ""

suite "ct-test M11 Go D Crystal providers":
  test "Go discovery includes tests benchmarks and subtests":
    check hasGoProject(goRoot())
    let catalog = goFileCatalog(goRoot(), goFile()).value
    check catalog.provider.id == "go-test"
    check catalog.provider.capabilities.canRunSingle
    check not catalog.provider.capabilities.canRecordSingle
    let validation = catalog.validateCatalog
    checkpoint($validation.errors)
    check validation.valid

    check catalog.itemBySelector("TestAdd").range.startLine == 5
    check catalog.itemBySelector("TestGrouped").range.startLine == 11
    let alpha = catalog.itemBySelector("TestGrouped/alpha")
    check alpha.kind == tikParameterizedCase
    check alpha.parentId == catalog.itemBySelector("TestGrouped").id
    check "subtest" in alpha.tags
    check catalog.itemBySelector("BenchmarkDouble").range.startLine == 24
    check catalog.items.len == 5

  test "Go command construction covers package file single benchmark " &
      "and subtest":
    check buildGoCommand(goRoot(), goFile(), "", gcsProject) ==
      @["go", "test", "./..."]
    check buildGoCommand(goRoot(), goFile(), "", gcsFile) ==
      @["go", "test", "."]
    check buildGoCommand(goRoot(), goFile(), "TestAdd", gcsSingle) ==
      @["go", "test", ".", "-run", "^TestAdd$", "-v"]
    check buildGoCommand(goRoot(), goFile(), "TestGrouped/alpha", gcsSingle) ==
      @["go", "test", ".", "-run", "^TestGrouped$/^alpha$", "-v"]
    check buildGoCommand(goRoot(), goFile(), "BenchmarkDouble", gcsSingle) ==
      @["go", "test", ".", "-run", "^$", "-bench",
        "^BenchmarkDouble$"]

  test "go_subtest_selector_runs_one_subtest_when_supported":
    let catalog = goFileCatalog(goRoot(), goFile()).value
    let item = catalog.itemBySelector("TestGrouped/alpha")
    let runResult = newGoTestM1Provider().provider.run(TestScope(
      kind: tskSingle,
      projectRoot: goRoot(),
      file: goFile(),
      testId: item.id,
      selector: item.selector))
    checkPassedRun(runResult)
    let output = runResult.value.eventsOfKind(tekOutput)[0].output
    check "TestGrouped/alpha" in output
    check "TestGrouped/beta" notin output

  test "D discovery command construction and real file execution":
    check hasDubProject(dRoot())
    let catalog = dFileCatalog(dRoot(), dFile()).value
    check catalog.provider.id == "d-unittest"
    check catalog.provider.capabilities.canRunFile
    check not catalog.provider.capabilities.canRunSingle
    let validation = catalog.validateCatalog
    checkpoint($validation.errors)
    check validation.valid
    check catalog.items.len == 2
    check catalog.selectors == @["source/calculator.d:11",
      "source/calculator.d:15"]
    check buildDCommand(dRoot(), dFile(), "", dcsProject) == @["dub", "test"]
    check buildDCommand(dRoot(), dFile(), "", dcsFile) ==
      @["ldc2", "-unittest", "-main", "-run", "source/calculator.d"]

    let runResult = newDUnittestM1Provider().provider.run(TestScope(
      kind: tskFile,
      projectRoot: dRoot(),
      file: dFile(),
      selector: "source/calculator.d"))
    checkPassedRun(runResult)

    let single = newDUnittestM1Provider().provider.run(TestScope(
      kind: tskSingle,
      projectRoot: dRoot(),
      file: dFile(),
      selector: catalog.items[0].selector))
    check single.value.len == 0
    check single.diagnostics[0].message.contains(
        "do not expose stable single-test selectors")

  test "Crystal discovery command construction and real file/single execution":
    check hasCrystalProject(crystalRoot())
    let catalog = crystalFileCatalog(crystalRoot(), crystalFile()).value
    check catalog.provider.id == "crystal-spec"
    check catalog.provider.capabilities.canRunSingle
    let validation = catalog.validateCatalog
    checkpoint($validation.errors)
    check validation.valid
    check "spec/calculator_spec.cr:5" in catalog.selectors
    check "spec/calculator_spec.cr:10" in catalog.selectors

    let adds = catalog.itemByName("adds numbers")
    check buildCrystalCommand(crystalRoot(), crystalFile(), adds.selector,
        ccsSingle) == @["crystal", "spec", "--no-color", adds.selector]

    let fileRun = newCrystalSpecM1Provider().provider.run(TestScope(
      kind: tskFile,
      projectRoot: crystalRoot(),
      file: crystalFile(),
      selector: "spec/calculator_spec.cr"))
    checkPassedRun(fileRun)

    let singleRun = newCrystalSpecM1Provider().provider.run(TestScope(
      kind: tskSingle,
      projectRoot: crystalRoot(),
      file: crystalFile(),
      testId: adds.id,
      selector: adds.selector))
    checkPassedRun(singleRun)

  test "d_and_crystal_file_recording_smoke":
    let dRecord = newDUnittestM1Provider().provider.record(TestScope(
      kind: tskFile,
      projectRoot: dRoot(),
      file: dFile(),
      selector: "source/calculator.d"))
    let crystalRecord = newCrystalSpecM1Provider().provider.record(TestScope(
      kind: tskFile,
      projectRoot: crystalRoot(),
      file: crystalFile(),
      selector: "spec/calculator_spec.cr"))

    if dRecord.diagnostics.len > 0:
      checkpoint($dRecord.diagnostics)
      checkpoint($dRecord.value)
    if crystalRecord.diagnostics.len > 0:
      checkpoint($crystalRecord.diagnostics)
      checkpoint($crystalRecord.value)
    check dRecord.diagnostics.len == 0
    check crystalRecord.diagnostics.len == 0
    discard checkNonEmptyCtArtifact(dRecord.value, "D")
    discard checkNonEmptyCtArtifact(crystalRecord.value, "Crystal")
    for event in dRecord.value & crystalRecord.value:
      check event.validateEvent.valid

  test "a failing unit finishes as failed, and carries its reason beside it":
    ## OWNS: the STATUS on the failure branch.
    ##
    ## `unitOutcomeEvents` is the single emitter every exit-code-only provider
    ## in this family now shares (go-test, crystal-spec, d-unittest, the three
    ## C/C++ providers and the eight M12 fallback languages), so its contract
    ## is asserted directly and once: a non-zero exit finishes the unit
    ## `tsFailed` and a zero exit finishes it `tsPassed`, and `tekTestFinished`
    ## is present either way.
    ##
    ## Grounded in test-certificates-spec Standard.md §3.1 — `passed` is the
    ## only value supporting a positive claim — so a unit whose command exited
    ## non-zero must not finish `tsPassed` under any reading.
    let failed = unitOutcomeEvents("go-test", "run-1", "unit-1", 2,
      "test command exited with 2", "FAIL\tctrepro\t0.002s", 17)
    check failed.len == 3
    check failed[0].kind == tekFailure
    check failed[0].status.get == tsFailed
    # The reason and the captured output ride on the failure event, where a
    # human looks for them; the finished event beside it is what counts.
    check failed[0].message == "test command exited with 2"
    check failed[0].output == "FAIL\tctrepro\t0.002s"
    check failed[1].kind == tekTestFinished
    check failed[1].status.get == tsFailed
    check failed[1].durationMs == 17
    check failed[2].kind == tekRunFinished
    check failed[2].status.get == tsFailed
    for event in failed:
      check event.validateEvent.valid

    # The passing path is unchanged and must stay that way: two events, no
    # failure event, `tsPassed` on both.
    let passed = unitOutcomeEvents("go-test", "run-1", "unit-1", 0,
      "test command exited with 0", "ok\tctrepro\t0.002s", 5)
    check passed.len == 2
    check passed[0].kind == tekTestFinished
    check passed[0].status.get == tsPassed
    check passed[1].kind == tekRunFinished
    check passed[1].status.get == tsPassed
    # The message text too, because the collapse of three copies into this one
    # emitter rests on the passing path emitting the same BYTES it always did.
    # The three copies each spelled it as the literal `"passed"`; this one
    # spells it `$status`, and the two agree only because `TestResultStatus`
    # declares `tsPassed = "passed"`. Nothing else in the suite would notice if
    # that stopped being true, so it is pinned here.
    check passed[0].message == "passed"
    check passed[1].message == "passed"
    check failed[2].message == "failed"
    for event in passed:
      check event.validateEvent.valid

    # A child killed by a SIGNAL is a failure, and only exit code ZERO is a
    # pass. `execCaptured` — the launch the three C/C++ providers use — reports
    # a signalled child as exit code -1: runquota's `waitForCompletion` takes
    # the `WIFSIGNALED` branch, which sets `signaled`/`signal` and leaves the
    # `exitCode: -1` the completion was initialised with. A predicate written
    # as "greater than zero" rather than "not zero" would therefore attest a
    # segfaulting gtest binary as `tsPassed`, which Standard.md §3.1 forbids
    # outright. The boundary is asserted rather than assumed.
    let signalled = unitOutcomeEvents("cpp-gtest", "run-1", "unit-1", -1,
      "native test command exited with -1", "", 9)
    check signalled.len == 3
    check signalled[0].kind == tekFailure
    check signalled[0].status.get == tsFailed
    check signalled[1].kind == tekTestFinished
    check signalled[1].status.get == tsFailed
    check signalled[2].kind == tekRunFinished
    check signalled[2].status.get == tsFailed
    for event in signalled:
      check event.validateEvent.valid

  test "a failing Go file is COUNTED as one failed test, not as nothing":
    ## OWNS: the counting.
    ##
    ## THE REGRESSION. `run_orchestration.summarize` and
    ## `certificate_issuance.recordUnitResult` count `tekTestFinished` and
    ## nothing else, and this provider's failure branch emitted only
    ## `tekFailure` + `tekRunFinished`. So a Go file whose only test calls
    ## `t.Fatalf` contributed zero to `executed` and zero to `failed`. Measured
    ## through the shipped `ct-test test run` CLI on exactly this module,
    ## before the fix:
    ##
    ##   executed 0, failed 0, verdict "nothing-executed", exit 2
    ##   certificate WITHHELD (wrNoTestsExecuted)
    ##
    ## after:
    ##
    ##   executed 1, failed 1, verdict "failed", exit 1
    ##   certificate WITHHELD (wrTestsFailed)
    ##
    ## The tallies come out of the SHIPPED `summarize`, so a counter that stops
    ## reading `tekTestFinished` reddens this case even with the event emitted.
    let project = scratchGoModule("ct-go-failing", "fail_test.go", """
package ctgofailing

import "testing"

func TestAlwaysFails(t *testing.T) {
	t.Fatalf("deliberate failure")
}
""")
    defer: removeDir(project)

    let runResult = newGoTestM1Provider().provider.run(TestScope(
      kind: tskFile,
      projectRoot: project,
      file: project / "fail_test.go",
      selector: "fail_test.go"))

    # A failing suite is reported through diagnostics AND events; neither may
    # stand in for the other.
    check runResult.diagnostics.len == 1
    check runResult.diagnostics[0].severity == dsError
    check runResult.diagnostics[0].message.contains(
      "test execution failed with exit code")

    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 1
    if finished.len == 1:
      check finished[0].status.get == tsFailed
    check runResult.value.eventsOfKind(tekFailure).len == 1
    for event in runResult.value:
      check event.validateEvent.valid

    let summary = summarize(singleUnitRunResult("go-test", runResult))
    check summary.executed == 1
    check summary.failed == 1
    check summary.passed == 0
    check summary.skipped == 0
    check summary.runVerdict == rvFailed
    check summary.runExitCode == ExitTestsFailed
    # Said the other way round, because this is the confusion the fix removes:
    # a suite that failed must not report the verdict a suite that never ran
    # reports.
    check summary.runVerdict != rvNothingExecuted
    check summary.runExitCode != ExitNothingExecuted

  test "a passing Go file still reports one passed test and exits 0":
    ## The guard on the OTHER direction. The fix routes both branches through
    ## one emitter, so a mistake there could just as easily turn passes into
    ## failures; this pins the passing path's counts and verdict against that.
    let project = scratchGoModule("ct-go-passing", "ok_test.go", """
package ctgopassing

import "testing"

func TestAlwaysPasses(t *testing.T) {
	if 1+1 != 2 {
		t.Fatalf("arithmetic broke")
	}
}
""")
    defer: removeDir(project)

    let runResult = newGoTestM1Provider().provider.run(TestScope(
      kind: tskFile,
      projectRoot: project,
      file: project / "ok_test.go",
      selector: "ok_test.go"))

    if runResult.diagnostics.len > 0:
      checkpoint($runResult.diagnostics)
    check runResult.diagnostics.len == 0
    check runResult.value.eventsOfKind(tekFailure).len == 0
    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 1
    if finished.len == 1:
      check finished[0].status.get == tsPassed

    let summary = summarize(singleUnitRunResult("go-test", runResult))
    check summary.executed == 1
    check summary.passed == 1
    check summary.failed == 0
    check summary.runVerdict == rvPassed
    check summary.runExitCode == ExitRunPassed

  test "the shipped CLI tells a failing workspace apart from an empty one":
    ## OWNS: the end-to-end requirement, through the real binary.
    ##
    ## test-certificates-spec Standard.md §8: "Producers MUST NOT claim targets
    ## that did not run." A run that never executed anything and a run in which
    ## everything failed support the same (empty) positive claim but call for
    ## entirely different investigations, and `ExitNothingExecuted` (2) exists
    ## precisely to keep them apart. Before the fix they were byte-identical
    ## for this provider: same verdict, same exit code, same withheld reason.
    ##
    ## Driven through `runCtTest` — the real CLI entry point with the real
    ## default provider registry — and the summary is read back from
    ## `--summary <path>`, which is the documented way a machine consumer reads
    ## a run, rather than by scraping a merged stdout/stderr stream.
    let failing = scratchGoModule("ct-go-cli-failing", "fail_test.go", """
package ctgoclifailing

import "testing"

func TestAlwaysFails(t *testing.T) {
	t.Fatalf("deliberate failure")
}
""")
    defer: removeDir(failing)

    let failingSummaryPath = failing / "summary.json"
    let failingCode = runCtTest(
      @["test", "run", "--workspace", failing,
        "--summary", failingSummaryPath, "--threads", "1"],
      newDefaultProviderRegistry(), newDiscoveryCache())
    require fileExists(failingSummaryPath)
    let failingSummary = parseJson(readFile(failingSummaryPath))
    checkpoint($failingSummary)
    check failingCode == ExitTestsFailed
    check failingSummary["verdict"].getStr == $rvFailed
    check failingSummary["executed"].getInt == 1
    check failingSummary["failed"].getInt == 1
    require failingSummary.hasKey("certificate")
    require failingSummary["certificate"].hasKey("withheld_reason")
    check failingSummary["certificate"]["issued"].getBool == false
    # Standard.md §3.1: `passed` is the only value supporting a positive claim,
    # so a run with a failed test may not be attested — and the reason it is
    # withheld for must be the failure, not "nothing ran".
    check failingSummary["certificate"]["withheld_reason"].getStr ==
      $wrTestsFailed

    # The contrast, in the same shape: a workspace with no test file at all.
    # Nothing ran, so nothing may be claimed.
    let empty = getTempDir() / ("ct-go-cli-empty-" & $getCurrentProcessId())
    removeDir(empty)
    createDir(empty)
    defer: removeDir(empty)
    writeFile(empty / "go.mod", "module ctgocliempty\n\ngo 1.21\n")
    writeFile(empty / "lib.go",
      "package ctgocliempty\n\nfunc Add(a, b int) int { return a + b }\n")

    let emptySummaryPath = empty / "summary.json"
    let emptyCode = runCtTest(
      @["test", "run", "--workspace", empty,
        "--summary", emptySummaryPath, "--threads", "1"],
      newDefaultProviderRegistry(), newDiscoveryCache())
    require fileExists(emptySummaryPath)
    let emptySummary = parseJson(readFile(emptySummaryPath))
    checkpoint($emptySummary)
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
    # and the literal values above are only today's spelling of it.
    check failingCode != emptyCode
    check failingSummary["verdict"].getStr != emptySummary["verdict"].getStr

  test "default CLI JSON includes M11 providers":
    let executable = compileCtTestBinary("ct-test-m11-cli")
    let goOutput = execProcess(
      executable,
      args = @["test", "discover", "--file", goFile(), "--json"],
      options = {poUsePath},
      workingDir = goRoot())
    let goNode = parseJson(goOutput)
    check goNode["schemaVersion"].getInt == 1
    check goNode["catalogs"][0]["provider"]["id"].getStr == "go-test"

    let crystalOutput = execProcess(
      executable,
      args = @["test", "discover", "--file", crystalFile(), "--json"],
      options = {poUsePath},
      workingDir = crystalRoot())
    let crystalNode = parseJson(crystalOutput)
    check crystalNode["catalogs"][0]["provider"]["id"].getStr == "crystal-spec"
