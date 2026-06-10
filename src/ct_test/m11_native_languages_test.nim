import std/[json, options, os, osproc, sequtils, strutils, unittest]

import contracts
import ct_test
import discovery
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
