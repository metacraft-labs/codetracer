import std/[json, options, os, osproc, sequtils, strutils, unittest]

import contracts
import ct_test
import discovery
import frameworks/cpp_catch2
import frameworks/cpp_common
import frameworks/cpp_ctest
import frameworks/cpp_gtest

proc gtestRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/cpp_gtest_project"

proc catchRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/cpp_catch2_project"

proc ctestRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/cpp_ctest_fallback_project"

proc gtestFile(): string =
  gtestRoot() / "tests/math_test.cpp"

proc catchFile(): string =
  catchRoot() / "tests/math_test.cpp"

proc buildDir(root: string): string =
  root / "build"

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc selectors(catalog: TestCatalog): seq[string] =
  catalog.items.mapIt(it.selector)

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

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

proc configureAndBuild(root: string): tuple[ok: bool; output: string] =
  createDir(buildDir(root))
  var cmakeArgs = "cmake -S . -B build"
  if root == gtestRoot():
    let
      gtestOut = execCmdEx("nix build --no-link --print-out-paths nixpkgs#gtest 2>/dev/null | tail -1",
        options = {poUsePath})
      gtestDev = execCmdEx("nix build --no-link --print-out-paths nixpkgs#gtest.dev 2>/dev/null | tail -1",
        options = {poUsePath})
    if gtestOut.exitCode == 0 and gtestDev.exitCode == 0:
      let
        libRoot = gtestOut.output.strip
        devRoot = gtestDev.output.strip
      cmakeArgs.add " -DGTest_DIR=" & quoteShell(devRoot / "lib/cmake/GTest")
      cmakeArgs.add " -DCMAKE_INSTALL_RPATH=" & quoteShell(libRoot / "lib")
  elif root == catchRoot():
    let catchOut = execCmdEx("nix build --no-link --print-out-paths nixpkgs#catch2_3 2>/dev/null | tail -1",
      options = {poUsePath})
    if catchOut.exitCode == 0:
      let catchRootPath = catchOut.output.strip
      cmakeArgs.add " -DCatch2_DIR=" & quoteShell(catchRootPath / "lib/cmake/Catch2")
  let configure = execCmdEx(cmakeArgs, options = {poUsePath},
      workingDir = root)
  if configure.exitCode != 0:
    return (false, configure.output)
  let build = execCmdEx("cmake --build build", options = {poUsePath},
      workingDir = root)
  (build.exitCode == 0, configure.output & "\n" & build.output)

proc requireBuilt(root: string) =
  let built = configureAndBuild(root)
  if not built.ok:
    checkpoint(built.output)
  check built.ok

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

suite "ct-test M10 C/C++ GoogleTest Catch2 CTest providers":
  test "gtest_macro_source_range_maps_to_listed_test":
    check hasGoogleTestProject(gtestRoot())
    let listed = @["MathTest.AddsNumbers", "CalculatorFixture.UsesFixtureState",
      "MathTest.MultiLineMacro"]
    let catalog = gtestFileCatalog(gtestRoot(), gtestFile(), listed).value
    check catalog.provider.id == "cpp-gtest"
    check catalog.provider.capabilities.canRunSingle
    check catalog.provider.capabilities.canRecordSingle
    let validation = catalog.validateCatalog
    checkpoint($validation.errors)
    check validation.valid

    let adds = catalog.itemBySelector("MathTest.AddsNumbers")
    check adds.range.startLine == 12
    check adds.range.startColumn == 1
    check adds.location.confidence == lcHigh

    let fixture = catalog.itemBySelector("CalculatorFixture.UsesFixtureState")
    check fixture.range.startLine == 16
    check "test_f" in fixture.tags

    let multiline = catalog.itemBySelector("MathTest.MultiLineMacro")
    check multiline.range.startLine == 24
    check multiline.range.endLine == 25

    let allSelectors = catalog.selectors
    check "CommentedOut.IsIgnored" notin allSelectors
    check "StringLiteral.IsIgnored" notin allSelectors
    check catalog.items.len == 3

  test "Catch2 parser discovers TEST_CASE SCENARIO and SECTION context":
    check hasCatch2Project(catchRoot())
    let catalog = catch2FileCatalog(catchRoot(), catchFile(),
      @["multiplication works", "zero multiplication"]).value
    check catalog.provider.id == "cpp-catch2"
    let validation = catalog.validateCatalog
    checkpoint($validation.errors)
    check validation.valid

    let testCase = catalog.itemBySelector("multiplication works")
    check testCase.range.startLine == 7
    check testCase.location.confidence == lcHigh
    check "[math][fast]" in testCase.tags

    let section = catalog.itemBySelector("multiplication works / identity")
    check section.kind == tikSuite
    check section.range.startLine == 10
    check "section" in section.tags

    check catalog.itemBySelector("zero multiplication").range.startLine == 15
    check "commented out" notin catalog.selectors.join("\n")
    check "string literal" notin catalog.selectors.join("\n")

  test "framework list output parsers normalize native selectors":
    let gtestOutput = """
MathTest.
  AddsNumbers
  MultiLineMacro
CalculatorFixture.
  UsesFixtureState
"""
    check parseGTestListOutput(gtestOutput) == @[
      "MathTest.AddsNumbers",
      "MathTest.MultiLineMacro",
      "CalculatorFixture.UsesFixtureState"]

    let catchOutput = """
All available test cases:
  multiplication works
      [math][fast]
  zero multiplication
2 test cases
"""
    check parseCatch2ListOutput(catchOutput) == @[
      "multiplication works", "zero multiplication"]

    let ctestOutput = """
Test project /tmp/build
  Test #1: fallback_smoke
  Test #2: fallback_named_arg
"""
    check parseCTestListOutput(ctestOutput) == @[
      "fallback_smoke", "fallback_named_arg"]

  test "command construction covers single file and project scopes":
    check buildCppCommand(cfkGoogleTest, gtestRoot(), gtestFile(),
        "MathTest.AddsNumbers", ccsSingle)[^1] ==
      "--gtest_filter=MathTest.AddsNumbers"
    check buildCppCommand(cfkCatch2, catchRoot(), catchFile(),
        "multiplication works", ccsSingle)[^1] == "multiplication works"
    check buildCppCommand(cfkCTest, ctestRoot(), "", "fallback_smoke",
        ccsSingle) == @["ctest", "--test-dir", ctestRoot() / "build",
          "--output-on-failure", "-R", "^fallback_smoke$"]

  test "real CMake GoogleTest fixture builds lists and runs one test":
    requireBuilt(gtestRoot())
    let exe = findBuiltExecutable(gtestRoot(), "gtest")
    check exe.len > 0
    let listed = execCmdEx(quoteShell(exe) & " --gtest_list_tests",
      options = {poUsePath}, workingDir = gtestRoot())
    if listed.exitCode != 0:
      checkpoint(listed.output)
    check listed.exitCode == 0
    check "MathTest." in listed.output
    check "AddsNumbers" in listed.output

    let catalog = gtestFileCatalog(gtestRoot(), gtestFile(),
      parseGTestListOutput(listed.output)).value
    let item = catalog.itemBySelector("MathTest.AddsNumbers")
    let runResult = newCppGTestM1Provider().provider.run(TestScope(
      kind: tskSingle,
      projectRoot: gtestRoot(),
      file: gtestFile(),
      testId: item.id,
      selector: item.selector))
    if runResult.diagnostics.len > 0:
      checkpoint($runResult.diagnostics)
      checkpoint($runResult.value)
    check runResult.diagnostics.len == 0
    check runResult.value.eventsOfKind(tekTestFinished)[0].status.get == tsPassed
    for event in runResult.value:
      check event.validateEvent.valid

  test "real CMake Catch2 fixture builds lists and runs one test":
    requireBuilt(catchRoot())
    let exe = findBuiltExecutable(catchRoot(), "catch2")
    check exe.len > 0
    let listed = execCmdEx(quoteShell(exe) & " --list-tests",
      options = {poUsePath}, workingDir = catchRoot())
    if listed.exitCode != 0:
      checkpoint(listed.output)
    check listed.exitCode == 0
    check "multiplication works" in listed.output

    let catalog = catch2FileCatalog(catchRoot(), catchFile(),
      parseCatch2ListOutput(listed.output)).value
    let item = catalog.itemBySelector("multiplication works")
    let runResult = newCppCatch2M1Provider().provider.run(TestScope(
      kind: tskSingle,
      projectRoot: catchRoot(),
      file: catchFile(),
      testId: item.id,
      selector: item.selector))
    if runResult.diagnostics.len > 0:
      checkpoint($runResult.diagnostics)
      checkpoint($runResult.value)
    check runResult.diagnostics.len == 0
    check runResult.value.eventsOfKind(tekTestFinished)[0].status.get == tsPassed
    for event in runResult.value:
      check event.validateEvent.valid

  test "catch2_records_single_test_trace when native recorder is available":
    requireBuilt(catchRoot())
    let catalog = catch2FileCatalog(catchRoot(), catchFile()).value
    let item = catalog.itemBySelector("multiplication works")
    let recordResult = newCppCatch2M1Provider().provider.record(TestScope(
      kind: tskSingle,
      projectRoot: catchRoot(),
      file: catchFile(),
      testId: item.id,
      selector: item.selector))
    if nativeRecorderPrefix().len == 0:
      check recordResult.value.len == 0
      check recordResult.diagnostics.len == 1
      check recordResult.diagnostics[0].message.contains("ct-mcr native recorder is required")
    else:
      if recordResult.diagnostics.len > 0:
        checkpoint($recordResult.diagnostics)
        checkpoint($recordResult.value)
      check recordResult.diagnostics.len == 0
      check recordResult.value.eventsOfKind(tekRecordingCreated).len == 1
      check recordResult.value.eventsOfKind(tekRecordFinished)[0].status.get == tsPassed
      discard recordResult.value.checkNonEmptyCtArtifact("catch2 single-test")
      for event in recordResult.value:
        check event.validateEvent.valid

  test "CTest fallback parses add_test entries and runs one test":
    requireBuilt(ctestRoot())
    let list = execCmdEx("ctest --test-dir build -N", options = {poUsePath},
      workingDir = ctestRoot())
    if list.exitCode != 0:
      checkpoint(list.output)
    check list.exitCode == 0
    check parseCTestListOutput(list.output) == @[
      "fallback_smoke", "fallback_named_arg"]

    let catalog = ctestProjectCatalog(ctestRoot()).value
    check catalog.provider.id == "cpp-ctest"
    check catalog.provider.capabilities.canRunSingle
    check not catalog.provider.capabilities.canDiscoverFile
    check catalog.provider.capabilities.canLocateTests
    check not catalog.provider.capabilities.canRecordSingle
    let validation = catalog.validateCatalog
    checkpoint($validation.errors)
    check validation.valid
    check catalog.itemBySelector("fallback_smoke").file ==
      "build/CTestTestfile.cmake"

    let runResult = newCppCTestM1Provider().provider.run(TestScope(
      kind: tskSingle,
      projectRoot: ctestRoot(),
      selector: "fallback_smoke",
      testId: catalog.itemBySelector("fallback_smoke").id))
    if runResult.diagnostics.len > 0:
      checkpoint($runResult.diagnostics)
      checkpoint($runResult.value)
    check runResult.diagnostics.len == 0
    check runResult.value.eventsOfKind(tekTestFinished)[0].status.get == tsPassed

  test "default CLI JSON includes C++ providers":
    let executable = compileCtTestBinary("ct-test-m10-cpp-cli")
    let output = execProcess(
      executable,
      args = @["test", "discover", "--file", gtestFile(), "--json"],
      options = {poUsePath},
      workingDir = gtestRoot())
    let node = parseJson(output)
    check node["schemaVersion"].getInt == 1
    check node["catalogs"].len >= 1
    check node["catalogs"][0]["provider"]["id"].getStr == "cpp-gtest"
