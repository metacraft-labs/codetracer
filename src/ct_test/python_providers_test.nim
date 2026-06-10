import std/[json, os, osproc, sequtils, strutils, unittest]

import contracts
import ct_test
import discovery
import frameworks/python_common
import frameworks/python_pytest
import frameworks/python_unittest

proc pytestRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/python_pytest_project"

proc unittestRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/python_unittest_project"

proc pytestSample(): string =
  pytestRoot() / "tests/test_sample.py"

proc unittestSample(): string =
  unittestRoot() / "tests/test_sample.py"

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
  check compile.exitCode == 0
  if compile.exitCode != 0:
    checkpoint(compile.output)
  if fileExists(binary):
    binary
  else:
    binary & ".out"

suite "ct-test M5 Python pytest and unittest providers":
  test "pytest discovers source ranges, selectors, decorators, and class methods":
    let catalog = pytestFileCatalog(pytestRoot(), pytestSample()).value
    check catalog.provider.id == "python-pytest"
    check catalog.provider.framework == "pytest"
    check catalog.provider.capabilities.canDiscoverFile
    check catalog.provider.capabilities.canDiscoverProject
    check not catalog.provider.capabilities.canRunSingle
    check not catalog.provider.capabilities.canRecordSingle
    check catalog.validateCatalog.valid

    let plain = catalog.itemBySelector("tests/test_sample.py::test_plain")
    check plain.kind == tikCase
    check plain.range.startLine == 27
    check plain.range.startColumn == 1
    check plain.parentId == ""

    let camel = catalog.itemBySelector("tests/test_sample.py::testCamelCaseName")
    check camel.kind == tikCase
    check camel.range.startLine == 31

    let asyncFunction = catalog.itemBySelector("tests/test_sample.py::test_async_function")
    check asyncFunction.kind == tikCase
    check asyncFunction.range.startLine == 35
    check asyncFunction.range.startColumn == 1

    let parametrized = catalog.itemBySelector("tests/test_sample.py::test_parametrized")
    check parametrized.kind == tikParameterizedCase
    check parametrized.range.startLine == 50
    check "parametrize" in parametrized.tags

    let klass = catalog.itemBySelector("tests/test_sample.py::TestArithmetic")
    let methodItem = catalog.itemBySelector("tests/test_sample.py::TestArithmetic::test_adds")
    check klass.kind == tikSuite
    check klass.range.startLine == 54
    check methodItem.range.startLine == 55
    check methodItem.parentId == klass.id

    let asyncMethod = catalog.itemBySelector("tests/test_sample.py::TestArithmetic::test_async_method")
    check asyncMethod.kind == tikCase
    check asyncMethod.range.startLine == 58
    check asyncMethod.parentId == klass.id

    let methodParam = catalog.itemBySelector("tests/test_sample.py::TestArithmetic::test_method_parametrized")
    check methodParam.kind == tikParameterizedCase
    check methodParam.range.startLine == 62
    check "parametrize" in methodParam.tags

    let skipped = catalog.itemBySelector("tests/test_sample.py::test_skipped_marker")
    let xfail = catalog.itemBySelector("tests/test_sample.py::test_expected_failure")
    check "skip" in skipped.tags
    check "xfail" in xfail.tags

    let allSelectors = catalog.selectors
    check "tests/test_sample.py::test_from_string" notin allSelectors
    check "tests/test_sample.py::test_from_raw_string" notin allSelectors
    check "tests/test_sample.py::TestFromString" notin allSelectors
    check "tests/test_sample.py::test_from_comment" notin allSelectors
    check "tests/test_sample.py::HelperClass::test_not_collected_by_pytest_source_slice" notin allSelectors
    check catalog.items.len == 10

  test "unittest discovers TestCase methods and ignores strings comments and plain classes":
    let catalog = unittestFileCatalog(unittestRoot(), unittestSample()).value
    check catalog.provider.id == "python-unittest"
    check catalog.provider.framework == "unittest"
    check catalog.provider.capabilities.canDiscoverFile
    check catalog.provider.capabilities.canDiscoverProject
    check not catalog.provider.capabilities.canRunSingle
    check not catalog.provider.capabilities.canRecordSingle
    check catalog.validateCatalog.valid

    let suiteItem = catalog.itemBySelector("tests.test_sample.CalculatorCase")
    let adds = catalog.itemBySelector("tests.test_sample.CalculatorCase.test_adds")
    let camel = catalog.itemBySelector("tests.test_sample.CalculatorCase.testCamelCaseName")
    let skipped = catalog.itemBySelector("tests.test_sample.CalculatorCase.test_skipped")
    check suiteItem.kind == tikSuite
    check suiteItem.range.startLine == 22
    check adds.kind == tikCase
    check adds.range.startLine == 23
    check adds.parentId == suiteItem.id
    check camel.kind == tikCase
    check camel.range.startLine == 26
    check camel.parentId == suiteItem.id
    check "skip" in skipped.tags

    let asyncSuite = catalog.itemBySelector("tests.test_sample.AsyncCalculatorCase")
    let asyncMethod = catalog.itemBySelector("tests.test_sample.AsyncCalculatorCase.test_async_method")
    check asyncSuite.kind == tikSuite
    check asyncSuite.range.startLine == 37
    check asyncMethod.kind == tikCase
    check asyncMethod.range.startLine == 38
    check asyncMethod.parentId == asyncSuite.id

    let allSelectors = catalog.selectors
    check "tests.test_sample.FakeCase" notin allSelectors
    check "tests.test_sample.FakeCase.test_from_string" notin allSelectors
    check "tests.test_sample.RawFakeCase" notin allSelectors
    check "tests.test_sample.RawFakeCase.test_from_raw_string" notin allSelectors
    check "tests.test_sample.CommentedCase" notin allSelectors
    check "tests.test_sample.NotATestCase.test_not_unittest" notin allSelectors
    check catalog.items.len == 6

  test "default registry prefers pytest when pytest config is present":
    let response = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: pytestRoot(), file: pytestSample(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    check response.catalogs[0].provider.id == "python-pytest"
    check allMessages(response).contains("python-unittest skipped by default because pytest configuration is present")

  test "default registry detects unittest when pytest config is absent":
    let response = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: unittestRoot(), file: unittestSample(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    check response.catalogs[0].provider.id == "python-unittest"
    check response.catalogs[0].itemBySelector("tests.test_sample.CalculatorCase.test_adds").range.startLine == 23

  test "project discovery aggregates multiple Python files":
    let pytestResponse = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: pytestRoot(), jsonOutput: true),
      newPythonPytestProviderRegistry(),
      newDiscoveryCache())
    let unittestResponse = discover(
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: unittestRoot(), jsonOutput: true),
      newPythonUnittestProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(pytestResponse) == 0
    check pytestResponse.catalogs.len == 1
    check pytestResponse.catalogs[0].itemBySelector("tests/test_sample.py::test_plain").file == "tests/test_sample.py"
    check pytestResponse.catalogs[0].itemBySelector("tests/more_test.py::TestMore::test_more_method").file == "tests/more_test.py"
    check pytestResponse.catalogs[0].items.len == 13
    check pytestResponse.catalogs[0].validateCatalog.valid

    check discoverExitCode(unittestResponse) == 0
    check unittestResponse.catalogs.len == 1
    check unittestResponse.catalogs[0].itemBySelector("tests.test_sample.CalculatorCase.test_adds").file == "tests/test_sample.py"
    check unittestResponse.catalogs[0].itemBySelector("tests.test_more.MoreCase.test_more").file == "tests/test_more.py"
    check unittestResponse.catalogs[0].items.len == 8
    check unittestResponse.catalogs[0].validateCatalog.valid

  test "CLI JSON uses schema version and correct Python provider ids":
    let executable = compileCtTestBinary("ct-test-m5-cli")
    let pytestOutput = execProcess(
      executable,
      args = @["test", "discover", "--file", pytestSample(), "--json"],
      options = {poUsePath},
      workingDir = pytestRoot())
    let pytestNode = parseJson(pytestOutput)
    check pytestNode["schemaVersion"].getInt == 1
    check pytestNode["catalogs"].len == 1
    check pytestNode["catalogs"][0]["schemaVersion"].getInt == 1
    check pytestNode["catalogs"][0]["provider"]["id"].getStr == "python-pytest"
    check pytestNode["catalogs"][0]["items"][0]["file"].getStr == "tests/test_sample.py"

    let unittestOutput = execProcess(
      executable,
      args = @["test", "discover", "--file", unittestSample(), "--json"],
      options = {poUsePath},
      workingDir = unittestRoot())
    let unittestNode = parseJson(unittestOutput)
    check unittestNode["schemaVersion"].getInt == 1
    check unittestNode["catalogs"].len == 1
    check unittestNode["catalogs"][0]["schemaVersion"].getInt == 1
    check unittestNode["catalogs"][0]["provider"]["id"].getStr == "python-unittest"

  test "command construction is explicit but provider execution remains unsupported":
    let pytestCatalog = pytestFileCatalog(pytestRoot(), pytestSample()).value
    let pytestSingle = pytestCatalog.itemBySelector("tests/test_sample.py::TestArithmetic::test_adds")
    check buildPytestCommand(pytestRoot(), pytestSample(), pytestSingle.selector, pcsProject) ==
      @["python", "-m", "pytest", "-q", "--color=no"]
    check buildPytestCommand(pytestRoot(), pytestSample(), pytestSingle.selector, pcsFile) ==
      @["python", "-m", "pytest", "-q", "--color=no", "tests/test_sample.py"]
    check buildPytestCommand(pytestRoot(), pytestSample(), pytestSingle.selector, pcsSingle) ==
      @["python", "-m", "pytest", "-q", "--color=no", "tests/test_sample.py::TestArithmetic::test_adds"]

    let unittestCatalog = unittestFileCatalog(unittestRoot(), unittestSample()).value
    let unittestSingle = unittestCatalog.itemBySelector("tests.test_sample.CalculatorCase.test_adds")
    check buildUnittestCommand(unittestRoot(), unittestSample(), unittestSingle.selector, pcsProject) ==
      @["python", "-m", "unittest", "discover", "-s", ".", "-p", "test*.py", "-t", "."]
    check buildUnittestCommand(unittestRoot(), unittestSample(), unittestSingle.selector, pcsFile) ==
      @["python", "-m", "unittest", "tests.test_sample"]
    check buildUnittestCommand(unittestRoot(), unittestSample(), unittestSingle.selector, pcsSingle) ==
      @["python", "-m", "unittest", "tests.test_sample.CalculatorCase.test_adds"]

    let provider = newPythonPytestM1Provider()
    let recordResult = provider.provider.record(TestScope(
      kind: tskSingle,
      projectRoot: pytestRoot(),
      file: pytestSample(),
      testId: pytestSingle.id,
      selector: pytestSingle.selector))
    check recordResult.value.len == 0
    check recordResult.diagnostics.len == 1
    check recordResult.diagnostics[0].message.contains("not wired in M5")
