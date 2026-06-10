import std/[json, options, os, osproc, sequtils, strutils, unittest]

import contracts
import ct_test
import discovery
import frameworks/ada_fallback
import frameworks/assembly_fallback
import frameworks/fortran_fallback
import frameworks/julia_fallback
import frameworks/lean_fallback
import frameworks/m12_fallback_common
import frameworks/native_m11_common
import frameworks/odin_fallback
import frameworks/pascal_fallback
import frameworks/v_fallback

type
  FallbackFixture = object
    name: string
    root: string
    file: string
    expectedOutput: string
    spec: M12FallbackSpec
    provider: M1Provider

proc fixtureRoot(name: string): string =
  getCurrentDir() / "src/ct_test/fixtures" / name

proc fixtures(): seq[FallbackFixture] =
  @[
    FallbackFixture(name: "Pascal", root: fixtureRoot("m12_pascal_project"),
      file: fixtureRoot("m12_pascal_project") / "tests/test_calculator.pas",
      expectedOutput: "pascal fixture passed", spec: pascalSpec(),
      provider: newPascalFallbackM1Provider()),
    FallbackFixture(name: "Fortran", root: fixtureRoot("m12_fortran_project"),
      file: fixtureRoot("m12_fortran_project") / "tests/test_calculator.f90",
      expectedOutput: "fortran fixture passed", spec: fortranSpec(),
      provider: newFortranFallbackM1Provider()),
    FallbackFixture(name: "Ada", root: fixtureRoot("m12_ada_project"),
      file: fixtureRoot("m12_ada_project") / "tests/test_calculator.adb",
      expectedOutput: "ada fixture passed", spec: adaSpec(),
      provider: newAdaFallbackM1Provider()),
    FallbackFixture(name: "Odin", root: fixtureRoot("m12_odin_project"),
      file: fixtureRoot("m12_odin_project") / "main.odin",
      expectedOutput: "odin fixture passed", spec: odinSpec(),
      provider: newOdinFallbackM1Provider()),
    FallbackFixture(name: "V", root: fixtureRoot("m12_v_project"),
      file: fixtureRoot("m12_v_project") / "tests/test_calculator.v",
      expectedOutput: "v fixture passed", spec: vSpec(),
      provider: newVFallbackM1Provider()),
    FallbackFixture(name: "Lean", root: fixtureRoot("m12_lean_project"),
      file: fixtureRoot("m12_lean_project") / "Main.lean",
      expectedOutput: "lean fixture passed", spec: leanSpec(),
      provider: newLeanFallbackM1Provider()),
    FallbackFixture(name: "Julia", root: fixtureRoot("m12_julia_project"),
      file: fixtureRoot("m12_julia_project") / "test/runtests.jl",
      expectedOutput: "julia fixture passed", spec: juliaSpec(),
      provider: newJuliaFallbackM1Provider()),
    FallbackFixture(name: "Assembly", root: fixtureRoot("m12_assembly_project"),
      file: fixtureRoot("m12_assembly_project") / "hello.S",
      expectedOutput: "assembly fixture passed", spec: assemblySpec(),
      provider: newAssemblyFallbackM1Provider())
  ]

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

proc toolOrNixAvailable(spec: M12FallbackSpec): bool =
  toolAvailable(spec.runTool)

proc checkNonEmptyCtArtifact(events: seq[TestEvent]; label: string): string =
  let created = events.eventsOfKind(tekRecordingCreated)
  check created.len == 1
  if created.len == 0 or created[0].trace.isNone:
    return ""
  let trace = created[0].trace.get
  let path = trace.path / (trace.recordingId & ".ct")
  checkpoint(label & " .ct artifact: " & path)
  check fileExists(path)
  if fileExists(path):
    check getFileSize(path) > 0
  path

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

suite "ct-test M12 fallback language providers":
  putEnv("CODETRACER_CT_TEST_DISABLE_NIX_FALLBACK", "1")

  test "fallback_languages_have_clear_capabilities":
    for fixture in fixtures():
      let catalog = fixture.provider.provider.discoverFile(fixture.root,
          fixture.file).value
      check catalog.provider.id == fixture.spec.providerId
      check catalog.provider.capabilities.canDiscoverProject
      check catalog.provider.capabilities.canDiscoverFile
      check catalog.provider.capabilities.canLocateTests
      check catalog.provider.capabilities.canRunProject
      check catalog.provider.capabilities.canRunFile
      check not catalog.provider.capabilities.canRunSingle
      check not catalog.provider.capabilities.canRecordProject
      check catalog.provider.capabilities.canRecordFile ==
        fixture.spec.canRecordFile
      check not catalog.provider.capabilities.canRecordSingle
      check catalog.provider.capabilities.canMapTraceEntryPoints ==
        fixture.spec.canRecordFile
      check not catalog.provider.capabilities.emitsStructuredEvents
      check catalog.items.len == 1
      check catalog.items[0].location.source == lskFallback
      let validation = catalog.validateCatalog
      checkpoint(fixture.name & ": " & $validation.errors)
      check validation.valid

      let single = fixture.provider.provider.run(TestScope(kind: tskSingle,
          projectRoot: fixture.root, file: fixture.file,
          selector: catalog.items[0].selector, testId: catalog.items[0].id))
      check single.value.len == 0
      check single.diagnostics.len == 1
      check single.diagnostics[0].message.contains("does not advertise")

  test "M12 fixture discovery finds one file-level item per language":
    for fixture in fixtures():
      let detected = fixture.provider.provider.detect(fixture.root)
      check detected.value
      let projectCatalog = fixture.provider.provider.discoverProject(
          fixture.root).value
      let fileCatalog = fixture.provider.provider.discoverFile(fixture.root,
          fixture.file).value
      check projectCatalog.items.len >= 1
      check fileCatalog.items.len == 1
      check projectCatalog.itemBySelector(normalizedRelative(fixture.root,
          fixture.file)).id == fileCatalog.items[0].id

  test "M12 fixture file run produces output or honest missing-tool diagnostic":
    for fixture in fixtures():
      let catalog = fixture.provider.provider.discoverFile(fixture.root,
          fixture.file).value
      let item = catalog.items[0]
      let runResult = fixture.provider.provider.run(TestScope(kind: tskFile,
          projectRoot: fixture.root, file: fixture.file, selector: item.selector,
          testId: item.id))
      if toolOrNixAvailable(fixture.spec):
        if runResult.diagnostics.len > 0:
          checkpoint(fixture.name & " diagnostics: " & $runResult.diagnostics)
          checkpoint(fixture.name & " events: " & $runResult.value)
        check runResult.diagnostics.len == 0
        check runResult.value.eventsOfKind(tekTestFinished)[0].status.get ==
          tsPassed
        let outputEvents = runResult.value.eventsOfKind(tekOutput)
        check outputEvents.len > 0
        if outputEvents.len > 0:
          check fixture.expectedOutput in outputEvents[0].output
        for event in runResult.value:
          check event.validateEvent.valid
      else:
        check runResult.value.len == 0
        check runResult.diagnostics.len == 1
        check runResult.diagnostics[0].message.contains(
            fixture.spec.runTool & " is required")

  test "M12 file recording creates traces when prerequisites are available":
    for fixture in fixtures():
      let catalog = fixture.provider.provider.discoverFile(fixture.root,
          fixture.file).value
      let item = catalog.items[0]
      let recordResult = fixture.provider.provider.record(TestScope(
          kind: tskFile, projectRoot: fixture.root, file: fixture.file,
          selector: item.selector, testId: item.id))
      if fixture.spec.canRecordFile and toolOrNixAvailable(fixture.spec) and
          nativeRecorderPrefix().len > 0:
        if recordResult.diagnostics.len > 0:
          checkpoint(fixture.name & " diagnostics: " & $recordResult.diagnostics)
          checkpoint(fixture.name & " events: " & $recordResult.value)
        check recordResult.diagnostics.len == 0
        discard checkNonEmptyCtArtifact(recordResult.value, fixture.name)
        for event in recordResult.value:
          check event.validateEvent.valid
      else:
        check recordResult.value.len == 0
        check recordResult.diagnostics.len == 1
        let message = recordResult.diagnostics[0].message
        check message.contains("does not advertise file-level recording") or
          message.contains("is required") or
          message.contains("ct-mcr native recorder is required")

  test "default CLI JSON includes M12 providers":
    let executable = compileCtTestBinary("ct-test-m12-cli")
    let output = execProcess(executable,
      args = @["test", "discover", "--file",
          fixtureRoot("m12_julia_project") / "test/runtests.jl", "--json"],
      options = {poUsePath},
      workingDir = fixtureRoot("m12_julia_project"))
    let node = parseJson(output)
    let ids = node["catalogs"].getElems.mapIt(it["provider"]["id"].getStr)
    check "julia-fallback" in ids
