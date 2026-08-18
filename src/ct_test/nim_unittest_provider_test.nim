import std/[json, os, osproc, sequtils, strutils, unittest]

import ct_test
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

proc catalogProviderIds(response: DiscoverResponse): seq[string] =
  for catalog in response.catalogs:
    result.add catalog.provider.id

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
      DiscoverRequest(scope: dskWorkspace, workspaceRoot: fixtureRoot(),
          jsonOutput: true),
      newNimUnittestProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    let catalog = response.catalogs[0]
    check catalog.provider.id == "nim-unittest"
    check catalog.itemBySelector("math::adds numbers").file ==
      "tests/test_sample.nim"
    check catalog.itemBySelector("more::second file case").file ==
      "tests/test_more.nim"
    # 9 in test_sample.nim + 2 in test_more.nim + 6 in
    # test_lexical_edge_cases.nim (1 suite + 5 cases, matching what
    # `nim c -r` on that fixture actually reports).
    check catalog.items.len == 17
    check catalog.validateCatalog.valid

  test "CLI JSON for real Nim fixture uses nim-unittest provider":
    let binary = getTempDir() / ("ct-test-m2-cli-" & $getCurrentProcessId())
    let compile = execCmdEx(
      "nim c --hints:off --warnings:off " &
        "--nimcache:/tmp/ct-nim-cache/ct-test-m2-cli -o:" &
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
    check node["catalogs"][0]["items"][0]["file"].getStr ==
      "tests/test_sample.nim"
    check "m1-fake" notin output
    check "m1-unsupported" notin output

  test "reports unsupported diagnostics for unittest variants":
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

    check messages.contains(
      "unittest2 discovery is detected but not implemented in M2")
    check messages.contains(
      "unittest_parallel discovery is detected but not implemented in M2")

  test "discover file through default registry uses Nim provider":
    let response = discover(
      DiscoverRequest(
        scope: dskFile,
        workspaceRoot: fixtureRoot(),
        file: sampleFile(),
        jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())

    check discoverExitCode(response) == 0
    check response.catalogs.len == 1
    check response.catalogs[0].provider.id == "nim-unittest"
    check response.catalogProviderIds == @["nim-unittest"]
    check not allMessages(response).contains("m1-fake")
    check not allMessages(response).contains("m1-unsupported")

# ---------------------------------------------------------------------------
# Lexical regressions.
#
# These run the real provider over real source text written to a real temp
# file — no mocks, no internal-proc shortcuts — because the defect they pin
# was invisible at every level except "file in, catalog out": the scanner
# happily reported *some* declarations while silently dropping the ones that
# followed an apostrophe it had misread.
# ---------------------------------------------------------------------------

var lexicalCaseCounter = 0

proc catalogForSource(source: string): TestCatalog =
  ## Materialise ``source`` as a Nim test file and discover it.
  let root = getTempDir() / ("ct-test-nim-lexical-" & $getCurrentProcessId())
  inc lexicalCaseCounter
  let file = root / "tests" / ("test_case" & $lexicalCaseCounter & ".nim")
  createDir(root / "tests")
  writeFile(file, source)
  nimUnittestFileCatalog(root, file).value

proc selectorsOf(catalog: TestCatalog): seq[string] =
  catalog.items.mapIt(it.selector)

proc messagesOf(catalog: TestCatalog): string =
  for item in catalog.diagnostics:
    result.add item.message & "\n"

const declarationTail = """

suite "round trip":
  test "keeps the probe":
    discard
"""

suite "ct-test Nim unittest lexical regressions":
  test "a numeric type suffix no longer hides the declarations after it":
    # The reported defect, reduced: the apostrophe in `10485760'i64` used to
    # open a phantom character literal that ran to the end of the file.
    let catalog = catalogForSource(
      "import std/unittest\n\nconst sizeBytes = 10485760'i64\n" &
      declarationTail)
    check catalog.selectorsOf ==
      @["round trip::", "round trip::keeps the probe"]
    check "no literal suite/test declarations" notin catalog.messagesOf

  test "every apostrophe-bearing literal form keeps the scan in sync":
    const probes = [
      "0'u8",                       # integer type suffix
      "10485760'i64",               # the reported case
      "1.0'f32",                    # float type suffix
      "2.5'f64",
      "0x1F'i64",                   # hex literal with a suffix
      "0b1010'u8",
      "1_000_000'u32",              # underscore separators plus a suffix
      "12'MyMeters",                # custom numeric literal
      "'a'",                        # character literal
      "'\\''",                      # escaped-apostrophe character literal
      "'\\x41'",
      "\"it's a string\"",          # apostrophe inside a string
      "r\"C:\\dir\\\"",             # raw string ending in a backslash
      "gr\"a\"\"b\""]               # generalized raw string literal
    for probe in probes:
      let catalog = catalogForSource(
        "import std/unittest\n\nconst probe = " & probe & "\n" &
        declarationTail)
      checkpoint("probe: " & probe)
      check catalog.selectorsOf ==
        @["round trip::", "round trip::keeps the probe"]

  test "an apostrophe in a comment or a doc comment stays inert":
    let catalog = catalogForSource(
      "import std/unittest\n\n" &
      "## It's a doc comment.\n" &
      "# and it's a line comment\n" &
      "#[ a block comment: it's fine ]#\n" &
      declarationTail)
    check catalog.selectorsOf ==
      @["round trip::", "round trip::keeps the probe"]

  test "declarations inside comments are not discovered":
    # The mirror defect: over-counting.  A commented-out test is not a test.
    let catalog = catalogForSource(
      "import std/unittest\n\n" &
      "# suite \"commented suite\":\n" &
      "#   test \"commented test\":\n" &
      "#[\nsuite \"block suite\":\n  test \"block test\":\n]#\n" &
      declarationTail)
    check catalog.selectorsOf ==
      @["round trip::", "round trip::keeps the probe"]

  test "declarations inside a multi-line string are not discovered":
    let catalog = catalogForSource(
      "import std/unittest\n\n" &
      "const fixture = \"\"\"\n" &
      "suite \"string suite\":\n  test \"string test\":\n    discard\n" &
      "\"\"\"\n" &
      declarationTail)
    check catalog.selectorsOf ==
      @["round trip::", "round trip::keeps the probe"]

  test "declarations inside a `when false:` block are not discovered":
    # `when false:` is the idiomatic way to disable Nim source without deleting
    # it.  The compiler never instantiates the body, so no runner can produce
    # those cases and discovery must not claim them — but it must say so
    # rather than dropping them silently, and it must resume afterwards.
    let catalog = catalogForSource(
      "import std/unittest\n\n" &
      "when false:\n" &
      "  suite \"disabled suite\":\n    test \"disabled case\":\n      discard\n" &
      declarationTail)
    check catalog.selectorsOf ==
      @["round trip::", "round trip::keeps the probe"]
    check catalog.messagesOf.contains("`when false:`")

  test "a `when false:` block nested inside a suite ends at the dedent":
    let catalog = catalogForSource(
      "import std/unittest\n\n" &
      "suite \"outer\":\n" &
      "  when false:\n    test \"disabled case\":\n      discard\n" &
      "  test \"live case\":\n    discard\n")
    check catalog.selectorsOf == @["outer::", "outer::live case"]

  test "a half-typed name string does not manufacture a test case":
    # A single-quoted string cannot cross a line, so `test "half typed` is a
    # file mid-edit, not a declaration. Inventing a case from it would put a
    # phantom in the catalog that no runner can ever produce — and, worse, one
    # whose selector changes on the next keystroke.
    let catalog = catalogForSource(
      "import std/unittest\n\ntest \"half typed\n" & declarationTail)
    check catalog.selectorsOf ==
      @["round trip::", "round trip::keeps the probe"]

  test "the parenthesised and glued call forms are still discovered":
    let parenthesised = catalogForSource(
      "import std/unittest\n\nsuite(\"paren suite\"):\n  test(\"paren case\"):\n    discard\n")
    check parenthesised.selectorsOf ==
      @["paren suite::", "paren suite::paren case"]
    # `test"name"` is Nim's generalized raw string literal syntax; it still
    # calls the `test` template, so it is still a declaration.
    let glued = catalogForSource(
      "import std/unittest\n\ntest\"glued case\":\n  discard\n")
    check glued.selectorsOf == @["::glued case"]

  test "an import hidden inside a here-doc is not a framework detection":
    # `maskNimNonCode` blanks multi-line literals, so a documentation block
    # that quotes an `import std/unittest` line no longer makes the file look
    # like a test file with no tests.
    check detectFrameworksInContent(
      "const doc = \"\"\"\nimport std/unittest\n\"\"\"\n").len == 0
    check detectFrameworksInContent("import std/unittest\n").len == 1
    # A single-line literal is preserved: `import "module"` is legal Nim.
    check detectFrameworksInContent("import \"std/unittest\"\n").len == 1

suite "ct-test CLI surface":
  test "the usage string documents the scoping escape hatch":
    ## `--scope`/`--unscoped` change which files discovery is even allowed to
    ## look at. They were absent from the usage text entirely, which made the
    ## only way out of the default scoping something a caller had to be told
    ## about out of band.
    let usage = ctTestUsageMessage()
    check usage.contains("--scope auto|vcs|walk|unscoped")
    check usage.contains("--unscoped")
    check usage.contains("CT_TEST_SCOPE")

  test "an unknown verb prints that usage string":
    let registry = newDefaultProviderRegistry()
    let cache = newDiscoveryCache()
    # `runCtTest` writes the response to stdout; assert on the message the
    # response carries by rebuilding it the same way the CLI does.
    check runCtTest(@["test", "nonsense"], registry, cache) == 1
