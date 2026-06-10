import std/[json, os, osproc, sequtils, strutils, unittest]

import contracts
import ct_test
import discovery
import frameworks/rust_libtest

proc rustRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/rust_libtest_project"

proc libFile(): string =
  rustRoot() / "src/lib.rs"

proc nestedFile(): string =
  rustRoot() / "src/nested.rs"

proc integrationFile(): string =
  rustRoot() / "tests/integration_sample.rs"

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc selectors(catalog: TestCatalog): seq[string] =
  catalog.items.mapIt(it.selector)

proc allMessages(response: DiscoverResponse): string =
  for diagnostic in response.diagnostics:
    result.add diagnostic.message & "\n"
  for catalog in response.catalogs:
    for diagnostic in catalog.diagnostics:
      result.add diagnostic.message & "\n"

proc compileCtTestBinary(name: string): string =
  let binary = getTempDir() / (name & "-" & $getCurrentProcessId())
  let compile = execCmdEx(
    "nim c --hints:off --warnings:off --nimcache:/tmp/ct-nim-cache/" & name & " -o:" &
      quoteShell(binary) & " src/ct_test/ct_test.nim",
    options = {poUsePath},
    workingDir = getCurrentDir())
  if compile.exitCode != 0:
    checkpoint(compile.output)
  check compile.exitCode == 0
  if fileExists(binary):
    binary
  else:
    binary & ".out"

suite "ct-test M6 Rust libtest provider":
  test "detects Cargo projects and Rust files":
    check hasCargoToml(rustRoot())
    check isRustFile(libFile())
    check isCargoRustTestFile(rustRoot(), libFile())
    check isCargoRustTestFile(rustRoot(), integrationFile())

    let detected = newRustLibtestM1Provider().provider.detect(rustRoot())
    check detected.value
    check detected.diagnostics.len == 0

  test "discovers unit tests with libtest-like module selectors and source ranges":
    let catalog = rustFileCatalog(rustRoot(), libFile()).value
    check catalog.provider.id == "rust-libtest"
    check catalog.provider.framework == "libtest/cargo-test"
    check catalog.provider.capabilities.canDiscoverFile
    check catalog.provider.capabilities.canRunSingle
    check not catalog.provider.capabilities.canRecordSingle
    check catalog.validateCatalog.valid

    let plain = catalog.itemBySelector("tests::unit_adds")
    check plain.kind == tikCase
    check plain.range.startLine == 24
    check plain.range.startColumn == 1
    check plain.range.endLine == 25
    check plain.range.endColumn == 16

    let ignored = catalog.itemBySelector("tests::ignored_unit")
    check ignored.range.startLine == 30
    check "ignore" in ignored.tags

    let tokio = catalog.itemBySelector("tests::tokio_async_unit")
    check tokio.range.startLine == 35
    check tokio.range.endLine == 36
    check "tokio" in tokio.tags

    let nested = catalog.itemBySelector("tests::inner::nested_unit")
    check nested.range.startLine == 41
    check nested.range.endLine == 42

    let asyncStd = catalog.itemBySelector("tests::inner::async_std_nested")
    check asyncStd.range.startLine == 46
    check asyncStd.range.endLine == 47
    check "async-std" in asyncStd.tags

    let allSelectors = catalog.selectors
    check "tests::fake_from_raw_string" notin allSelectors
    check "tests::fake_from_line_comment" notin allSelectors
    check "tests::fake_from_block_comment" notin allSelectors
    check catalog.items.len == 5

  test "discovers file module tests with source path module prefixes":
    let catalog = rustFileCatalog(rustRoot(), nestedFile()).value
    let item = catalog.itemBySelector("nested::nested_file_tests::nested_file_unit")
    check item.file == "src/nested.rs"
    check item.range.startLine == 3
    check item.range.endLine == 4
    check catalog.items.len == 1
    check catalog.validateCatalog.valid

  test "discovers integration tests without file-name selector prefix":
    let catalog = rustFileCatalog(rustRoot(), integrationFile()).value
    check catalog.itemBySelector("integration_smoke").range.startLine == 5
    check catalog.itemBySelector("failing_integration").range.startLine == 10
    check catalog.itemBySelector("api::nested_integration").range.startLine == 16
    check "fake_without_attr" notin catalog.selectors.join("\n")
    check catalog.items.len == 3
    check catalog.validateCatalog.valid

  test "project discovery aggregates src and integration test files":
    let response = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: rustRoot(), jsonOutput: true),
      newRustLibtestProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    let catalog = response.catalogs[0]
    check catalog.provider.id == "rust-libtest"
    check catalog.itemBySelector("tests::unit_adds").file == "src/lib.rs"
    check catalog.itemBySelector("nested::nested_file_tests::nested_file_unit").file == "src/nested.rs"
    check catalog.itemBySelector("integration_smoke").file == "tests/integration_sample.rs"
    check catalog.items.len == 9
    check catalog.validateCatalog.valid

  test "default CLI JSON uses schema version and Rust provider id":
    let executable = compileCtTestBinary("ct-test-m6-cli")
    let output = execProcess(
      executable,
      args = @["test", "discover", "--file", integrationFile(), "--json"],
      options = {poUsePath},
      workingDir = rustRoot())
    let node = parseJson(output)
    check node["schemaVersion"].getInt == 1
    check node["catalogs"].len == 1
    check node["catalogs"][0]["schemaVersion"].getInt == 1
    check node["catalogs"][0]["provider"]["id"].getStr == "rust-libtest"
    check node["catalogs"][0]["items"][0]["file"].getStr == "tests/integration_sample.rs"

  test "command construction is explicit and trace recording remains unsupported":
    let unitSelector = rustFileCatalog(rustRoot(), libFile()).value.itemBySelector("tests::unit_adds").selector
    let integrationSelector = rustFileCatalog(rustRoot(), integrationFile()).value.itemBySelector("api::nested_integration").selector

    check buildRustCommand(rustRoot(), libFile(), unitSelector, rcsProject) ==
      @["cargo", "test"]
    check buildRustCommand(rustRoot(), libFile(), unitSelector, rcsFile) ==
      @["cargo", "test", "--lib"]
    check buildRustCommand(rustRoot(), libFile(), unitSelector, rcsSingle) ==
      @["cargo", "test", "--lib", "--", "tests::unit_adds", "--exact", "--include-ignored"]
    check buildRustCommand(rustRoot(), integrationFile(), integrationSelector, rcsFile) ==
      @["cargo", "test", "--test", "integration_sample"]
    check buildRustCommand(rustRoot(), integrationFile(), integrationSelector, rcsSingle) ==
      @["cargo", "test", "--test", "integration_sample", "--", "api::nested_integration", "--exact", "--include-ignored"]

    let provider = newRustLibtestM1Provider()
    let recordResult = provider.provider.record(TestScope(
      kind: tskSingle,
      projectRoot: rustRoot(),
      file: libFile(),
      selector: unitSelector))
    check recordResult.value.len == 0
    check recordResult.diagnostics.len == 1
    check recordResult.diagnostics[0].message.contains("not wired in M6")

    let runResult = provider.provider.run(TestScope(
      kind: tskSingle,
      projectRoot: rustRoot(),
      file: libFile(),
      selector: unitSelector))
    check runResult.value.len == 0
    check runResult.diagnostics[0].message.contains("event parsing")

  test "default registry leaves Nim and Python providers intact for their fixtures":
    let nimRoot = getCurrentDir() / "src/ct_test/fixtures/nim_unittest_project"
    let nimFile = nimRoot / "tests/test_sample.nim"
    let pyRoot = getCurrentDir() / "src/ct_test/fixtures/python_pytest_project"
    let pyFile = pyRoot / "tests/test_sample.py"

    let nimResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: nimRoot, file: nimFile, jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    let pyResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: pyRoot, file: pyFile, jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(nimResponse) == 0
    check nimResponse.catalogs[0].provider.id == "nim-unittest"
    check allMessages(nimResponse).contains("rust-libtest did not detect")
    check discoverExitCode(pyResponse) == 0
    check pyResponse.catalogs[0].provider.id == "python-pytest"
