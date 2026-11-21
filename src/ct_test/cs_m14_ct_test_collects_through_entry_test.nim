## `ct test` collects Nim tests through the tests entry: it builds a Nim test
## source itself, asks the binary `--entrypoint=tests --list` for its tests,
## and runs each by name with `--entrypoint=tests --run-exact=<name>`
## (`frameworks/nim_tests_entry.nim`).
##
## WHAT IS CHECKED
##
##   * `ct test discover` on a Nim test source, and on the project, returns
##     exactly the names the built binary's `--list` prints, for a binary
##     that answers the entry through nim-entrypoints (`testCase`) and for one
##     that answers it through the `ct_test_unittest_parallel` shim
##     (`std/unittest` suites, named `<suite>::<test>` or `<test>`).
##   * `ct test run` runs one test by its listed name: the run executes that
##     test and no other (each test prints a marker of its own), and a failing
##     test fails the run with exit 1.
##
## NEGATIVE CONTROLS
##
##   * A plain `std/unittest` binary without the entry. The fixture's
##     `test_disabled_entry.nim` names `entrypoints` only under `when false:`,
##     so ct test builds it (its import scan sees the name) and gets a plain
##     binary. That binary answers `--entrypoint=tests --list` with its tests'
##     names and answers `--run-exact=math::mul` by running nothing and
##     exiting 0 although `math::mul` fails -- asserted on the binary itself,
##     so the control is known to be able to see a vacuous pass. ct test must
##     not list it per test: its tests come from the lexical scan, marked
##     not-runnable, and the run refuses them (exit 2, nothing executed),
##     never reporting `math::mul` as passed.
##   * A plain `std/unittest` source, which is never built, and a shim source
##     that does not compile: discovery falls back to the lexical scan, and
##     the run refuses their tests as it always has.
##
## PREREQUISITES -- supplied, never waived (a missing one FAILS the suite with
## the remedy; nothing here skips):
##
##   * `nim` on PATH (the dev shell's);
##   * nim-entrypoints with `--run-exact`: `$ENTRYPOINTS_SRC` (its `src`),
##     else the workspace sibling `../nim-entrypoints/src`;
##   * reprobuild's `ct_test_unittest_parallel` with the tests entry:
##     `$CT_TEST_UNITTEST_PARALLEL_SRC` (its `src`), else the workspace
##     sibling `../reprobuild/libs/ct_test_unittest_parallel/src`.
##
## No mocks: the fixtures are real Nim sources compiled by the real `nim`, the
## CLI is `runCtTest` (what `ct test` and `ct-test` call), and the outcomes are
## read from the run's own `--summary` and `--events` files. The fixture
## project is written to a temporary directory so that this repository's own
## `config.nims` does not apply to its compiles; its `config.nims` puts the two
## sources on the search path, as a user's project would.

import std/[json, os, sequtils, strutils, tempfiles, unittest]

import ct_test
import contracts
import discovery
import process_exec
import run_orchestration
import frameworks/nim_tests_entry

const
  ShimSource = """
import ct_test_unittest_parallel

suite "math":
  test "add":
    echo "CSM14CT math::add"
    check 1 + 1 == 2

  test "mul":
    echo "CSM14CT math::mul"
    check 2 * 2 == 5

test "loose":
  echo "CSM14CT loose"
"""
  EntrySource = """
import entrypoints
import entrypoints/tests

testCase "alpha":
  echo "CSM14CT alpha"

testCase "beta":
  echo "CSM14CT beta"
  doAssert 2 * 2 == 5, "beta fails"

main:
  echo "CSM14CT main"
"""
  DisabledEntrySource = """
import std/unittest
when false:
  # Read by ct test's import scan, never compiled: the binary is a plain
  # std/unittest one.
  import entrypoints

suite "math":
  test "add":
    echo "CSM14CT plain math::add"
    check 1 + 1 == 2

  test "mul":
    echo "CSM14CT plain math::mul"
    check 2 * 2 == 5
"""
  PlainSource = """
import std/unittest

suite "plain":
  test "never built":
    check true
"""
  BrokenSource = """
import ct_test_unittest_parallel

suite "broken":
  test "does not compile":
    check undeclaredInThisFixture == 1
"""

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc requireSource(envVar, sibling, probeFile, needle, what: string): string =
  ## The source directory named by `envVar`, else the workspace sibling,
  ## refused with the remedy when it is missing or predates `needle`.
  result = getEnv(envVar)
  if result.len == 0:
    result = repoRoot().parentDir / sibling
  let probe = result / probeFile
  if not fileExists(probe):
    raise newException(IOError, "this suite needs " & what & ": set " &
      envVar & " to its source directory or check it out at " &
      repoRoot().parentDir / sibling & " (looked for " & probe & ")")
  if needle notin readFile(probe):
    raise newException(IOError, probe & " predates " & what & " (it has " &
      "no " & needle & "); update that checkout, or point " & envVar &
      " at a newer one")

proc entrypointsSrc(): string =
  requireSource("ENTRYPOINTS_SRC", "nim-entrypoints/src",
    "entrypoints/tests.nim", "run-exact",
    "nim-entrypoints with --run-exact")

proc shimSrc(): string =
  requireSource("CT_TEST_UNITTEST_PARALLEL_SRC",
    "reprobuild/libs/ct_test_unittest_parallel/src",
    "ct_test_unittest_parallel.nim", "--run-exact",
    "ct_test_unittest_parallel with the tests entry")

proc nimStringLiteral(value: string): string =
  ## `value` as a Nim string literal, for the fixture's config.nims.
  result = "\""
  for ch in value:
    if ch in {'"', '\\'}:
      result.add '\\'
    result.add ch
  result.add '"'

proc writeFixture(): string =
  ## A fresh project directory holding the five sources under `tests/`.
  ## The prerequisites are resolved first, so a missing one leaves nothing
  ## behind.
  let
    entrypoints = entrypointsSrc()
    shim = shimSrc()
  result = createTempDir("ct-cs-m14-entry-", "")
  writeFile(result / "config.nims",
    "switch(\"path\", " & nimStringLiteral(entrypoints) & ")\n" &
    "switch(\"path\", " & nimStringLiteral(shim) & ")\n")
  createDir(result / "tests")
  writeFile(result / "tests" / "test_shim.nim", ShimSource)
  writeFile(result / "tests" / "test_entry.nim", EntrySource)
  writeFile(result / "tests" / "test_disabled_entry.nim", DisabledEntrySource)
  writeFile(result / "tests" / "test_plain.nim", PlainSource)
  writeFile(result / "tests" / "test_broken.nim", BrokenSource)

proc lineOf(source, needle: string): int =
  ## 1-based line of the first line of `source` containing `needle`.
  var index = 0
  for line in source.splitLines:
    inc index
    if needle in line:
      return index
  raise newException(ValueError, "fixture has no line with " & needle)

proc discoverFile(root, file: string): DiscoverResponse =
  discover(DiscoverRequest(scope: dskFile, workspaceRoot: root,
    file: root / file, jsonOutput: true), newDefaultProviderRegistry(),
    newDiscoveryCache())

proc discoverWorkspace(root: string): DiscoverResponse =
  discover(DiscoverRequest(scope: dskWorkspace, workspaceRoot: root,
    jsonOutput: true), newDefaultProviderRegistry(), newDiscoveryCache())

proc nimItems(response: DiscoverResponse): seq[TestItem] =
  for catalog in response.catalogs:
    if catalog.provider.id == "nim-unittest":
      result.add catalog.items

proc itemsOf(response: DiscoverResponse; file: string): seq[TestItem] =
  response.nimItems.filterIt(it.file == file)

proc messages(response: DiscoverResponse): string =
  for d in response.diagnostics:
    result.add d.message & "\n"
  for catalog in response.catalogs:
    for d in catalog.diagnostics:
      result.add d.message & "\n"

proc binaryList(root, file: string): seq[string] =
  ## What the binary ct test built for `file` prints for
  ## `--entrypoint=tests --list`, read straight from the binary.
  let binary = binaryPathFor(root / file)
  require fileExists(binary)
  let listing = execCaptured(listArgv(binary), cwd = root)
  check listing.exitCode == 0
  listing.stdout.strip.splitLines

type RunResult = object
  code: int
  summary: JsonNode
  finished: seq[JsonNode]   ## the `test-finished` events
  output: string            ## every `output` event's text, concatenated

proc runIds(root: string; ids: seq[string]; name: string): RunResult =
  ## `ct test run` over `root`, admitting only `ids`.
  let scratch = root / ".run-" & name
  createDir(scratch)
  writeFile(scratch / "partition.txt", ids.join("\n") & "\n")
  result.code = runCtTest(@["test", "run", "--workspace", root,
    "--partition", "file:" & scratch / "partition.txt",
    "--threads", "2", "--no-certificate",
    "--summary", scratch / "summary.json",
    "--events", scratch / "events.jsonl"],
    newDefaultProviderRegistry(), newDiscoveryCache())
  result.summary = parseJson(readFile(scratch / "summary.json"))
  for line in readFile(scratch / "events.jsonl").splitLines:
    if line.strip.len == 0:
      continue
    let event = parseJson(line)
    case event["kind"].getStr
    of "test-finished": result.finished.add event
    of "output": result.output.add event["output"].getStr
    else: discard

proc idOf(items: seq[TestItem]; selector: string): string =
  for item in items:
    if item.selector == selector:
      return item.id
  raise newException(ValueError, "no item with selector " & selector)

let root = writeFixture()

suite "ct test collects Nim tests through the tests entry (CS-M14)":

  test "discover on a source returns the names the built binary lists":
    require findExe("nim").len > 0

    let shim = discoverFile(root, "tests/test_shim.nim")
    check discoverExitCode(shim) == 0
    let shimItems = shim.itemsOf("tests/test_shim.nim")
    check shimItems.mapIt(it.selector) == binaryList(root, "tests/test_shim.nim")
    check shimItems.mapIt(it.selector) == @["math::add", "math::mul", "loose"]
    for item in shimItems:
      check item.kind == tikCase
      check TestsEntryTag in item.tags
      check NotRunnableTag notin item.tags
      check item.location.source == lskFramework
    check shimItems.idOf("math::add").len > 0
    check shimItems[0].range.startLine == lineOf(ShimSource, "test \"add\"")
    check shimItems[2].range.startLine == lineOf(ShimSource, "test \"loose\"")
    check shim.catalogs.allIt(it.validateCatalog.valid)

    let entry = discoverFile(root, "tests/test_entry.nim")
    check discoverExitCode(entry) == 0
    let entryItems = entry.itemsOf("tests/test_entry.nim")
    check entryItems.mapIt(it.selector) == binaryList(root, "tests/test_entry.nim")
    check entryItems.mapIt(it.selector) == @["alpha", "beta"]
    check entryItems[1].range.startLine == lineOf(EntrySource, "testCase \"beta\"")
    check entryItems.allIt(TestsEntryTag in it.tags and
      NotRunnableTag notin it.tags)

  test "discover on the project lists through the entry and falls back for the rest":
    let response = discoverWorkspace(root)
    check discoverExitCode(response) == 0
    check response.itemsOf("tests/test_shim.nim").mapIt(it.selector) ==
      @["math::add", "math::mul", "loose"]
    check response.itemsOf("tests/test_entry.nim").mapIt(it.selector) ==
      @["alpha", "beta"]
    # The fallbacks: found by the lexical scan, every item not runnable.
    for file in ["tests/test_disabled_entry.nim", "tests/test_plain.nim",
                 "tests/test_broken.nim"]:
      let items = response.itemsOf(file)
      check items.len > 0
      check items.allIt(NotRunnableTag in it.tags and
        TestsEntryTag notin it.tags)
    let text = response.messages
    check "its binary has no tests entry" in text
    check "`nim c` of it exited" in text
    # The plain source imports nothing that answers the entry: never built.
    check not fileExists(binaryPathFor(root / "tests/test_plain.nim"))

  test "negative control: a binary without the entry lists, then passes vacuously":
    # Built by the discovery above; its own answers show the trap the probe
    # avoids: it lists its tests, and runs nothing for a failing one.
    let binary = binaryPathFor(root / "tests/test_disabled_entry.nim")
    require fileExists(binary)
    check binaryList(root, "tests/test_disabled_entry.nim") ==
      @["math::add", "math::mul"]
    let vacuous = execCaptured(runExactArgv(binary, "math::mul"), cwd = root)
    check vacuous.exitCode == 0
    check "CSM14CT plain math::mul" notin vacuous.output
    let probe = execCaptured(entryListArgv(binary), cwd = root)
    check probe.exitCode == 0
    check not entryListHasTests(probe.stdout)

  test "run runs one test by name, and only that test":
    # Per file: the disabled-entry fixture has a lexed `math::add` too.
    let response = discoverWorkspace(root)
    let items = response.itemsOf("tests/test_shim.nim") &
      response.itemsOf("tests/test_entry.nim")
    let add = runIds(root, @[items.idOf("math::add")], "add")
    check add.code == ExitRunPassed
    check add.summary["executed"].getInt == 1
    check add.summary["passed"].getInt == 1
    require add.finished.len == 1
    check add.finished[0]["testId"].getStr == items.idOf("math::add")
    check add.finished[0]["status"].getStr == "passed"
    check "CSM14CT math::add" in add.output
    check "CSM14CT math::mul" notin add.output
    check "CSM14CT loose" notin add.output

    let alpha = runIds(root, @[items.idOf("alpha")], "alpha")
    check alpha.code == ExitRunPassed
    check alpha.summary["executed"].getInt == 1
    check "CSM14CT alpha" in alpha.output
    check "CSM14CT beta" notin alpha.output
    check "CSM14CT main" notin alpha.output

  test "a failing test fails the run":
    let response = discoverWorkspace(root)
    let items = response.itemsOf("tests/test_shim.nim") &
      response.itemsOf("tests/test_entry.nim")
    let mul = runIds(root, @[items.idOf("math::mul")], "mul")
    check mul.code == ExitTestsFailed
    check mul.summary["failed"].getInt == 1
    check mul.summary["passed"].getInt == 0
    require mul.finished.len == 1
    check mul.finished[0]["status"].getStr == "failed"
    check "CSM14CT math::mul" in mul.output

    let beta = runIds(root, @[items.idOf("beta")], "beta")
    check beta.code == ExitTestsFailed
    check beta.summary["failed"].getInt == 1
    check "CSM14CT beta" in beta.output
    check "CSM14CT alpha" notin beta.output

  test "the whole project: listed tests run one by one, the rest are refused":
    let scratch = root / ".run-whole"
    createDir(scratch)
    let code = runCtTest(@["test", "run", "--workspace", root,
      "--threads", "2", "--no-certificate",
      "--summary", scratch / "summary.json"],
      newDefaultProviderRegistry(), newDiscoveryCache())
    let summary = parseJson(readFile(scratch / "summary.json"))
    check code == ExitTestsFailed
    check summary["executed"].getInt == 5
    check summary["passed"].getInt == 3
    check summary["failed"].getInt == 2
    check summary["unrunnable"].getInt ==
      discoverWorkspace(root).nimItems.countIt(NotRunnableTag in it.tags)

  test "negative control: tests without the entry are refused, never passed":
    let items = discoverWorkspace(root).nimItems
    let disabled = items.filterIt(it.file == "tests/test_disabled_entry.nim")
    let mulId = disabled.filterIt(it.name == "mul")[0].id
    let refused = runIds(root, @[mulId], "refused-mul")
    check refused.code == ExitNothingExecuted
    check refused.summary["executed"].getInt == 0
    check refused.summary["passed"].getInt == 0
    check refused.summary["unrunnable"].getInt == 1
    check refused.finished.len == 0

    let plain = items.filterIt(it.file == "tests/test_plain.nim")
    let broken = items.filterIt(it.file == "tests/test_broken.nim")
    let others = runIds(root, (plain & broken).filterIt(
      it.kind == tikCase).mapIt(it.id), "refused-others")
    check others.code == ExitNothingExecuted
    check others.summary["executed"].getInt == 0
    check others.summary["unrunnable"].getInt == 2

removeDir(root)
