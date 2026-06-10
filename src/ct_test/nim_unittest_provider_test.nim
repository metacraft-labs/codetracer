import std/[json, os, osproc, strutils, unittest]

import contracts
import discovery
import frameworks/nim_unittest

proc fixtureRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/nim_unittest_project"

proc sampleFile(): string =
  fixtureRoot() / "tests/test_sample.nim"

proc moreFile(): string =
  fixtureRoot() / "tests/test_more.nim"

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc allMessages(response: DiscoverResponse): string =
  for diagnostic in response.diagnostics:
    result.add diagnostic.message & "\n"
  for catalog in response.catalogs:
    for diagnostic in catalog.diagnostics:
      result.add diagnostic.message & "\n"

suite "ct-test M2 Nim unittest provider":
  test "detects Nim unittest project and file":
    let provider = newNimUnittestM1Provider()
    let detected = provider.provider.detect(fixtureRoot())
    check detected.value
    check detected.diagnostics.len == 0

    let fileCatalog = nimUnittestFileCatalog(fixtureRoot(), sampleFile()).value
    check fileCatalog.provider.id == "nim-unittest"
    check fileCatalog.provider.language == "nim"
    check fileCatalog.provider.framework == "std/unittest"
    check fileCatalog.provider.capabilities.canDiscoverFile
    check fileCatalog.provider.capabilities.canDiscoverProject
    check not fileCatalog.provider.capabilities.canRunSingle
    check not fileCatalog.provider.capabilities.canRecordSingle
    check fileCatalog.validateCatalog.valid

  test "discovers suite and test source ranges with stable selectors":
    let catalog = nimUnittestFileCatalog(fixtureRoot(), sampleFile()).value

    let math = catalog.itemBySelector("math::")
    check math.kind == tikSuite
    check math.range.startLine == 24
    check math.range.startColumn == 1
    check math.parentId == ""

    let adds = catalog.itemBySelector("math::adds numbers")
    check adds.kind == tikCase
    check adds.range.startLine == 25
    check adds.range.startColumn == 3
    check adds.parentId == math.id
    check adds.id == makeTestItemId(
      "nim-unittest",
      "nim",
      "std/unittest",
      "tests/test_sample.nim",
      "math::adds numbers")

    let nested = catalog.itemBySelector("math::nested::")
    let inner = catalog.itemBySelector("math::nested::inner case")
    check nested.range.startLine == 35
    check inner.range.startLine == 36
    check inner.parentId == nested.id

    let top = catalog.itemBySelector("::top level case")
    check top.range.startLine == 43
    check top.parentId == ""

  test "ignores comments, multiline strings, and non-test text":
    let catalog = nimUnittestFileCatalog(fixtureRoot(), sampleFile()).value
    var selectors: seq[string] = @[]
    for item in catalog.items:
      selectors.add item.selector

    check "not real suite::" notin selectors
    check "not real suite::not real test" notin selectors
    check "commented suite::" notin selectors
    check "commented suite::commented test" notin selectors
    check "block commented suite::" notin selectors
    check "block commented suite::block commented test" notin selectors
    check selectors.len == 9

  test "project discovery aggregates multiple Nim unittest files":
    let response = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: fixtureRoot(), jsonOutput: true),
      newNimUnittestProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    let catalog = response.catalogs[0]
    check catalog.provider.id == "nim-unittest"
    check catalog.itemBySelector("math::adds numbers").file == "tests/test_sample.nim"
    check catalog.itemBySelector("more::second file case").file == "tests/test_more.nim"
    check catalog.items.len == 11
    check catalog.validateCatalog.valid

  test "CLI JSON for real Nim fixture uses schema version and nim-unittest provider":
    let binary = getTempDir() / ("ct-test-m2-cli-" & $getCurrentProcessId())
    let compile = execCmdEx(
      "nim c --hints:off --warnings:off --nimcache:/tmp/ct-nim-cache/ct-test-m2-cli -o:" &
        quoteShell(binary) & " src/ct_test/ct_test.nim",
      options = {poUsePath},
      workingDir = getCurrentDir())
    check compile.exitCode == 0
    if compile.exitCode != 0:
      checkpoint(compile.output)

    let executable =
      if fileExists(binary):
        binary
      else:
        binary & ".out"
    let output = execProcess(
      executable,
      args = @["test", "discover", "--file", sampleFile(), "--json"],
      options = {poUsePath},
      workingDir = fixtureRoot())
    let node = parseJson(output)

    check node["schemaVersion"].getInt == 1
    check node["catalogs"].len == 1
    check node["catalogs"][0]["schemaVersion"].getInt == 1
    check node["catalogs"][0]["provider"]["id"].getStr == "nim-unittest"
    check node["catalogs"][0]["items"].len == 9
    check node["catalogs"][0]["items"][0]["file"].getStr == "tests/test_sample.nim"

  test "reports explicit unsupported diagnostics for unittest2 and unittest_parallel":
    let unittest2Catalog = nimUnittestFileCatalog(
      fixtureRoot(),
      fixtureRoot() / "tests/test_unittest2_detected.nim").value
    let parallelCatalog = nimUnittestFileCatalog(
      fixtureRoot(),
      fixtureRoot() / "tests/test_unittest_parallel_detected.nim").value

    check unittest2Catalog.items.len == 0
    check parallelCatalog.items.len == 0
    check unittest2Catalog.provider.capabilities.canDiscoverFile
    check not unittest2Catalog.provider.capabilities.canRunSingle

    var messages = ""
    for diagnostic in unittest2Catalog.diagnostics:
      messages.add diagnostic.message & "\n"
    for diagnostic in parallelCatalog.diagnostics:
      messages.add diagnostic.message & "\n"

    check messages.contains("unittest2 discovery is detected but not implemented in M2")
    check messages.contains("unittest_parallel discovery is detected but not implemented in M2")

  test "discover file through registry uses Nim provider and keeps fake provider out of default registry":
    let response = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: fixtureRoot(), file: sampleFile(), jsonOutput: true),
      newNimUnittestProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    check response.catalogs[0].provider.id == "nim-unittest"
    check not allMessages(response).contains("m1-fake")
