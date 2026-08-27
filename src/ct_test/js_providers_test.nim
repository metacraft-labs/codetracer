import std/[json, options, os, osproc, sequtils, strutils, tables, unittest]

import contracts
import ct_test
import discovery
import frameworks/js_common
import frameworks/js_jest
import frameworks/js_node_test
import frameworks/js_vitest

const
  JestCalcSelector = "tests/calculator.test.js::calculator"
  JestAddsSelector = "tests/calculator.test.js::calculator > adds numbers"
  JestSubtractsSelector =
    "tests/calculator.test.js::calculator > subtracts numbers"
  JestAsyncSelector =
    "tests/calculator.test.js::calculator > async operations"
  JestSkippedSelector =
    "tests/calculator.test.js::calculator > async operations > " &
    "waits for promise"
  JestTopSelector = "tests/calculator.test.js::top level js"
  JestTsMultipliesSelector =
    "tests/strings.test.ts::typescript calculator > multiplies numbers"
  JestTsAsyncSelector =
    "tests/strings.test.ts::typescript calculator > handles async types"
  VitestAsyncSelector =
    "tests/math.spec.ts::math > nested > async square"
  NodeSuiteSelector = "test/sample.test.js::node runner"
  NodeRunsSelector = "test/sample.test.js::node runner > runs js"
  NodeAsyncSelector = "test/sample.test.js::node runner > runs async js"
  NodeTsSelector = "test/types.test.ts::typescript needs loader"
  NodeRecordSelector =
    "test/record_single.test.cjs::records single cjs node test"

proc jestRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/js_jest_project"

proc vitestRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/js_vitest_project"

proc nodeRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/js_node_test_project"

proc jestSample(): string =
  jestRoot() / "tests/calculator.test.js"

proc jestTsSample(): string =
  jestRoot() / "tests/strings.test.ts"

proc vitestSample(): string =
  vitestRoot() / "tests/math.spec.ts"

proc nodeSample(): string =
  nodeRoot() / "test/sample.test.js"

proc nodeRecordSample(): string =
  nodeRoot() / "test/record_single.test.cjs"

proc nodeTsSample(): string =
  nodeRoot() / "test/types.test.ts"

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc selectors(catalog: TestCatalog): seq[string] =
  catalog.items.mapIt(it.selector)

proc catalogProviderIds(response: DiscoverResponse): seq[string] =
  response.catalogs.mapIt(it.provider.id)

proc catalogDiagnosticsContain(catalog: TestCatalog; needle: string): bool =
  for diagnostic in catalog.diagnostics:
    if diagnostic.message.contains(needle):
      return true
  false

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

proc outputContains(events: seq[TestEvent]; needle: string): bool =
  for event in events:
    if event.output.contains(needle) or event.message.contains(needle):
      return true
  false

proc firstTrace(events: seq[TestEvent]): TraceMetadata =
  for event in events:
    if event.trace.isSome:
      return event.trace.get
  raise newException(ValueError, "missing trace metadata")

proc withEnvValue(name, value: string; body: proc()) =
  let
    hadValue = existsEnv(name)
    oldValue = getEnv(name)
  putEnv(name, value)
  try:
    body()
  finally:
    if hadValue: putEnv(name, oldValue) else: delEnv(name)

proc withoutEnvValue(name: string; body: proc()) =
  let
    hadValue = existsEnv(name)
    oldValue = getEnv(name)
  delEnv(name)
  try:
    body()
  finally:
    if hadValue:
      putEnv(name, oldValue)

proc withCurrentDir(dir: string; body: proc()) =
  let old = getCurrentDir()
  setCurrentDir(dir)
  try:
    body()
  finally:
    setCurrentDir(old)

proc pathWithout(executable: string): string =
  ## The current ``PATH`` with every directory that provides ``executable``
  ## removed.
  ##
  ## A resolution test has to pin the *order* of the fallbacks, which means
  ## knowing that the recorder is not reachable by an earlier one. Rebuilding
  ## ``PATH`` from scratch would do that but would also take ``node`` and
  ## ``sh`` away from the command under test; prepending a directory cannot
  ## remove anything. Subtracting exactly the providers of one name leaves the
  ## rest of the environment intact, so the assertion holds whether or not the
  ## developer's shell happens to have the recorder installed.
  var kept: seq[string] = @[]
  for dir in getEnv("PATH").split(PathSep):
    if dir.len > 0 and fileExists(dir / executable):
      continue
    kept.add dir
  kept.join($PathSep)

proc writeExecutable(path, contents: string) =
  createDir(path.parentDir)
  writeFile(path, contents)
  setFilePermissions(path, {fpUserExec, fpUserRead, fpUserWrite})

proc diagnosticText(runResult: ProviderResult[seq[TestEvent]]): string =
  var parts: seq[string] = @[]
  for item in runResult.diagnostics:
    parts.add $item.severity & ": " & item.message
  parts.join("\n")

proc nodeScratchProject(name, testFileName, testSource: string): string =
  ## Materialise a throwaway `node --test` project for one test.
  ##
  ## Scratch rather than a checked-in fixture because the discovery assertions
  ## above pin `js_node_test_project`'s exact item and test counts, so a new
  ## test file dropped in there would break cases that have nothing to do with
  ## skips. Nothing is installed: `node --test` needs no dependencies.
  result = getTempDir() / (name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "test")
  writeFile(result / "package.json",
    """{"name": "ct-test-scratch", "version": "1.0.0"}""")
  writeFile(result / "test" / testFileName, testSource)

proc jsRecorderSibling(): string =
  ## The real ``codetracer-js-recorder`` checkout beside this one, or ``""``.
  ## Only the *test* is allowed to look here: it is describing the machine it
  ## runs on, whereas the provider must answer from the workspace it is given.
  let candidate = getCurrentDir().parentDir / "codetracer-js-recorder"
  if fileExists(candidate / "packages" / "cli" / "dist" / "index.js"):
    candidate
  else:
    ""

proc compileCtTestBinary(name: string): string =
  let binary = getTempDir() / (name & "-" & $getCurrentProcessId())
  let compile = execCmdEx(
    "nim c --hints:off --warnings:off --nimcache:/tmp/ct-nim-cache/" & name &
    " -o:" &
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

suite "ct-test M7 JavaScript and TypeScript providers":
  test "Jest provider detects package and discovers JS and TS tests":
    check hasJestProject(jestRoot())
    check not hasVitestProject(jestRoot())
    check not hasNodeTestProject(jestRoot())

    let catalog = jestFileCatalog(jestRoot(), jestSample()).value
    check catalog.provider.id == "js-jest"
    check catalog.provider.framework == "jest"
    check catalog.provider.capabilities.canDiscoverFile
    check not catalog.provider.capabilities.canRunSingle
    check not catalog.provider.capabilities.canRecordSingle
    check catalog.validateCatalog.valid

    let suiteItem = catalog.itemBySelector(JestCalcSelector)
    let adds = catalog.itemBySelector(JestAddsSelector)
    let subtracts = catalog.itemBySelector(JestSubtractsSelector)
    let asyncSuite = catalog.itemBySelector(JestAsyncSelector)
    let skipped = catalog.itemBySelector(JestSkippedSelector)
    let topLevel = catalog.itemBySelector(JestTopSelector)
    check suiteItem.kind == tikSuite
    check suiteItem.range.startLine == 13
    check adds.range.startLine == 14
    check adds.parentId == suiteItem.id
    check "only" in subtracts.tags
    check asyncSuite.parentId == suiteItem.id
    check skipped.parentId == asyncSuite.id
    check "skip" in skipped.tags
    check topLevel.parentId == ""

    let allSelectors = catalog.selectors
    check "tests/calculator.test.js::from string" notin allSelectors
    check "tests/calculator.test.js::from template" notin allSelectors
    check "tests/calculator.test.js::from comment" notin allSelectors
    check "tests/calculator.test.js::from block comment" notin allSelectors
    check catalog.items.len == 6

    let tsCatalog = jestFileCatalog(jestRoot(), jestTsSample()).value
    check tsCatalog.itemBySelector(
      JestTsMultipliesSelector).range.startLine == 7
    check tsCatalog.itemBySelector(JestTsAsyncSelector).range.startLine == 11
    check "tests/strings.test.ts::fake ts string" notin tsCatalog.selectors
    check "tests/strings.test.ts::fake ts template" notin tsCatalog.selectors

  test "Vitest provider detects config and discovers nested tests":
    check hasVitestProject(vitestRoot())
    check not hasJestProject(vitestRoot())

    let catalog = vitestFileCatalog(vitestRoot(), vitestSample()).value
    check catalog.provider.id == "js-vitest"
    check catalog.provider.framework == "vitest"
    check not catalog.provider.capabilities.canRunFile
    check not catalog.provider.capabilities.canRecordFile
    check catalog.validateCatalog.valid

    let math = catalog.itemBySelector("tests/math.spec.ts::math")
    let adds = catalog.itemBySelector("tests/math.spec.ts::math > adds")
    let nested = catalog.itemBySelector("tests/math.spec.ts::math > nested")
    let asyncSquare = catalog.itemBySelector(VitestAsyncSelector)
    let todo = catalog.itemBySelector(
      "tests/math.spec.ts::documents todo support")
    check math.range.startLine == 7
    check adds.range.startLine == 8
    check adds.parentId == math.id
    check nested.parentId == math.id
    check asyncSquare.parentId == nested.id
    check "concurrent" in asyncSquare.tags
    check "todo" in todo.tags
    check "tests/math.spec.ts::fake vitest string" notin catalog.selectors
    check "tests/math.spec.ts::fake vitest template" notin catalog.selectors
    check catalog.items.len == 5

  test "Node test provider detects node:test and reports TS loader diagnostic":
    check hasNodeTestProject(nodeRoot())
    check not hasJestProject(nodeRoot())
    check not hasVitestProject(nodeRoot())

    let catalog = nodeTestFileCatalog(nodeRoot(), nodeSample()).value
    check catalog.provider.id == "js-node-test"
    check catalog.provider.framework == "node:test"
    check catalog.provider.capabilities.canRunSingle
    check catalog.provider.capabilities.canRunFile
    check catalog.provider.capabilities.canRunProject
    check not catalog.provider.capabilities.canCapturePerTestOutput
    check catalog.provider.capabilities.canRecordSingle
    check catalog.validateCatalog.valid

    let suiteItem = catalog.itemBySelector(NodeSuiteSelector)
    let runs = catalog.itemBySelector(NodeRunsSelector)
    let asyncRun = catalog.itemBySelector(NodeAsyncSelector)
    let top = catalog.itemBySelector("test/sample.test.js::top level node")
    check suiteItem.range.startLine == 8
    check runs.parentId == suiteItem.id
    check asyncRun.range.startLine == 13
    check top.parentId == ""
    check "test/sample.test.js::fake node string" notin catalog.selectors
    check "test/sample.test.js::fake node template" notin catalog.selectors
    check catalog.items.len == 4

    let tsCatalog = nodeTestFileCatalog(nodeRoot(), nodeTsSample()).value
    check tsCatalog.catalogDiagnosticsContain("TypeScript execution requires")
    check tsCatalog.itemBySelector(NodeTsSelector).range.startLine == 4

  test "default registry discovers only matching JS provider for file requests":
    let jestResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: jestRoot(),
          file: jestSample(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(jestResponse) == 0
    check "js-jest" in jestResponse.catalogProviderIds
    check "js-vitest" notin jestResponse.catalogProviderIds
    check "js-node-test" notin jestResponse.catalogProviderIds

    let vitestResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: vitestRoot(),
          file: vitestSample(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(vitestResponse) == 0
    check vitestResponse.catalogProviderIds == @["js-vitest"]

    let nodeResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: nodeRoot(),
          file: nodeSample(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(nodeResponse) == 0
    check nodeResponse.catalogProviderIds == @["js-node-test"]

  test "CLI JSON uses schema version and correct JS provider ids":
    let executable = compileCtTestBinary("ct-test-m7-cli")
    let jestOutput = execProcess(
      executable,
      args = @["test", "discover", "--file", jestSample(), "--json"],
      options = {poUsePath},
      workingDir = jestRoot())
    let jestNode = parseJson(jestOutput)
    check jestNode["schemaVersion"].getInt == 1
    check jestNode["catalogs"].len == 1
    check jestNode["catalogs"][0]["schemaVersion"].getInt == 1
    check jestNode["catalogs"][0]["provider"]["id"].getStr == "js-jest"

    let vitestOutput = execProcess(
      executable,
      args = @["test", "discover", "--file", vitestSample(), "--json"],
      options = {poUsePath},
      workingDir = vitestRoot())
    let vitestNode = parseJson(vitestOutput)
    check vitestNode["schemaVersion"].getInt == 1
    check vitestNode["catalogs"].len == 1
    check vitestNode["catalogs"][0]["provider"]["id"].getStr == "js-vitest"

    let nodeOutput = execProcess(
      executable,
      args = @["test", "discover", "--file", nodeSample(), "--json"],
      options = {poUsePath},
      workingDir = nodeRoot())
    let nodeJson = parseJson(nodeOutput)
    check nodeJson["schemaVersion"].getInt == 1
    check nodeJson["catalogs"].len == 1
    check nodeJson["catalogs"][0]["provider"]["id"].getStr ==
      "js-node-test"

  test "Node test provider runs one real JavaScript test through node --test":
    let catalog = nodeTestFileCatalog(nodeRoot(), nodeSample()).value
    let item = catalog.itemBySelector(NodeRunsSelector)
    let provider = newJsNodeTestM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskSingle,
      projectRoot: nodeRoot(),
      file: nodeSample(),
      testId: item.id,
      selector: item.selector))

    if runResult.diagnostics.len > 0:
      checkpoint($runResult.diagnostics)
    check runResult.diagnostics.len == 0
    check runResult.value.eventsOfKind(tekRunStarted).len == 1
    check runResult.value.eventsOfKind(tekTestStarted).len == 1
    check runResult.value.eventsOfKind(tekOutput).len == 1
    check runResult.value.eventsOfKind(tekTestFinished).len == 1
    check runResult.value.eventsOfKind(tekRunFinished).len == 1
    check runResult.value.eventsOfKind(tekTestFinished)[0].status.get ==
      tsPassed
    check runResult.value.outputContains("ok 1 - runs js")
    check runResult.value.outputContains("# tests 1")
    for event in runResult.value:
      check event.validateEvent.valid

  test "Node test provider runs all real JavaScript tests in a file":
    let provider = newJsNodeTestM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskFile,
      projectRoot: nodeRoot(),
      file: nodeSample(),
      selector: "test/sample.test.js"))

    if runResult.diagnostics.len > 0:
      checkpoint($runResult.diagnostics)
    check runResult.diagnostics.len == 0
    check runResult.value.eventsOfKind(tekTestFinished)[0].status.get ==
      tsPassed
    check runResult.value.outputContains("# tests 3")
    check runResult.value.outputContains("# suites 1")

  test "Node test provider runs the real fixture project through node --test":
    let provider = newJsNodeTestM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskProject,
      projectRoot: nodeRoot(),
      selector: "js-node-test-project"))

    if runResult.diagnostics.len > 0:
      checkpoint($runResult.diagnostics)
    check runResult.diagnostics.len == 0
    check runResult.value.eventsOfKind(tekTestFinished)[0].status.get ==
      tsPassed
    check runResult.value.outputContains("# tests 5")
    check runResult.value.outputContains("# suites 1")

  test "node:test reports a skipped test as skipped rather than as a pass":
    ## THE REGRESSION. `node --test` with every test skipped prints
    ## `# pass 0` / `# skipped 2` and **exits 0**, and the provider's only
    ## status source was that exit code, so the file reported `tsPassed` —
    ## which `certificate_issuance.recordUnitResult` then counted as an
    ## executed test and claimed as a covered target. Measured through the
    ## shipped `ct-test test run` CLI on exactly this file, before the fix:
    ##
    ##   executed 2, passed 2, skipped 0, verdict "passed", exit 0
    ##   certificate ISSUED, targets = ["test/skipped.test.js"]
    ##
    ## after:
    ##
    ##   executed 0, skipped 2, verdict "nothing-executed", exit 2
    ##   certificate WITHHELD (wrNoTestsExecuted), no target claimed
    let project = nodeScratchProject("ct-node-skipped", "skipped.test.js", """
const { test } = require('node:test');

test('first is skipped', { skip: 'not implemented yet' }, () => {
  throw new Error('never runs');
});

test('second is skipped', { skip: 'still not implemented' }, () => {
  throw new Error('never runs either');
});
""")
    defer: removeDir(project)

    let provider = newJsNodeTestM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskFile,
      projectRoot: project,
      file: project / "test" / "skipped.test.js",
      selector: "test/skipped.test.js"))

    if runResult.diagnostics.len > 0:
      checkpoint(runResult.diagnosticText)
    check runResult.diagnostics.len == 0

    let finished = runResult.value.eventsOfKind(tekTestFinished)
    check finished.len == 2
    for event in finished:
      check event.status.get == tsSkipped
    check runResult.value.eventsOfKind(tekFailure).len == 0
    for event in runResult.value.eventsOfKind(tekRunFinished):
      check event.status.get == tsSkipped
    for event in runResult.value:
      check event.validateEvent.valid

  test "node:test separates suites, skips, todos and real failures":
    ## Three things this must get right at once, which is why they share a
    ## fixture: a `describe` emits its own TAP point (`type: 'suite'`) that
    ## must NOT be counted as a test; a `todo` carries a `# TODO` directive
    ## and is counted under node's `# todo` even when its body throws (node
    ## writes `not ok ... # TODO` for that one and `ok ... # TODO` for a
    ## passing todo, so the DIRECTIVE decides, not the `ok`), which makes it
    ## no evidence and maps it to `tsSkipped`; and a genuine failure must
    ## still be a failure.
    let project = nodeScratchProject("ct-node-shapes", "shapes.test.js", """
const { test, describe, it } = require('node:test');
const assert = require('node:assert');

describe('outer suite', () => {
  it('passes', () => { assert.strictEqual(1, 1); });
  it('is skipped', { skip: 'why not' }, () => { assert.fail('nope'); });
  it('fails', () => { assert.strictEqual(1, 2); });
});

test('top level passes', () => { assert.ok(true); });
test('top level todo', { todo: 'later' }, () => { assert.fail('ignored'); });
""")
    defer: removeDir(project)

    let provider = newJsNodeTestM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskFile,
      projectRoot: project,
      file: project / "test" / "shapes.test.js",
      selector: "test/shapes.test.js"))

    let finished = runResult.value.eventsOfKind(tekTestFinished)
    # Five TESTS, not six: node's own `# tests 5` excludes the suite, and the
    # parser's cross-check against that counter is what keeps the suite's
    # `not ok` line from being counted as a sixth.
    check finished.len == 5
    var passed, failed, skipped = 0
    for event in finished:
      case event.status.get(tsErrored)
      of tsPassed: inc passed
      of tsFailed, tsErrored: inc failed
      of tsSkipped: inc skipped
    check passed == 2
    check failed == 1
    check skipped == 2
    check runResult.value.eventsOfKind(tekFailure).len == 1
    check runResult.diagnosticText.contains("at least one test did not pass")
    for event in runResult.value:
      check event.validateEvent.valid

  test "a node:test stream that is not TAP falls back to the exit code and says so":
    ## The fallback must survive, and must be AUDIBLE. `node --test` picks its
    ## reporter by whether stdout is a TTY — `tap` when it is not, which is
    ## always the case under capture — so this is what a future default change
    ## or an overridden reporter would look like, and the provider must produce
    ## an honest result with a named reason rather than reporting nothing.
    let notTap = parseNodeTapResults("js-node-test", "run-1", "unit-1",
      "> passes (0.4ms)\n> is skipped (0.1ms) # not implemented\n" &
      "tests 2\npass 0\nskipped 2\n")
    check not notTap.usable
    check notTap.reason.contains("did not produce a TAP stream")

    # A stream that parses to counts node itself contradicts is refused too:
    # under-counting would read as "this unit executed nothing" and withhold a
    # certificate that should have been issued, which is a worse failure than
    # falling back.
    let inconsistent = parseNodeTapResults("js-node-test", "run-1", "unit-1",
      "TAP version 13\nok 1 - a\n1..1\n# tests 3\n# pass 3\n# fail 0\n" &
      "# skipped 0\n# todo 0\n")
    check not inconsistent.usable
    check inconsistent.reason.contains("did not parse consistently")

    # And one with no summary counters at all cannot be checked, so it is not
    # believed.
    let noCounters = parseNodeTapResults("js-node-test", "run-1", "unit-1",
      "TAP version 13\nok 1 - a\n1..1\n")
    check not noCounters.usable
    check noCounters.reason.contains("summary counter")

  test "commands are explicit and Jest/Vitest run and record stay unsupported":
    let jestItem = jestFileCatalog(jestRoot(), jestSample(
        )).value.itemBySelector(
      "tests/calculator.test.js::calculator > adds numbers")
    check buildJsCommand(jfkJest, jestRoot(), jestSample(),
        "calculator adds numbers", jcsProject) ==
      @["npx", "jest", "--runInBand"]
    check buildJsCommand(jfkJest, jestRoot(), jestSample(),
        "calculator adds numbers", jcsFile) ==
      @["npx", "jest", "--runInBand", "--runTestsByPath",
        "tests/calculator.test.js"]
    check buildJsCommand(jfkJest, jestRoot(), jestSample(),
        "calculator adds numbers", jcsSingle) ==
      @["npx", "jest", "--runInBand", "--runTestsByPath",
        "tests/calculator.test.js", "--testNamePattern",
        "calculator adds numbers"]

    check buildJsCommand(jfkVitest, vitestRoot(), vitestSample(),
        "math nested async square", jcsSingle) ==
      @["npx", "vitest", "run", "tests/math.spec.ts", "-t",
        "math nested async square"]
    check buildJsCommand(jfkNodeTest, nodeRoot(), nodeSample(),
        "node runner runs js", jcsSingle) ==
      @["node", "--test", "--test-name-pattern", "node runner runs js",
        "test/sample.test.js"]

    let provider = newJsJestM1Provider()
    let runResult = provider.provider.run(TestScope(
      kind: tskSingle,
      projectRoot: jestRoot(),
      file: jestSample(),
      testId: jestItem.id,
      selector: jestItem.selector))
    check runResult.value.len == 0
    check runResult.diagnostics.len == 1
    check runResult.diagnostics[0].message.contains(
      "process execution and event parsing are not wired in m7")
    let recordResult = provider.provider.record(TestScope(
      kind: tskSingle,
      projectRoot: jestRoot(),
      file: jestSample(),
      testId: jestItem.id,
      selector: jestItem.selector))
    check recordResult.value.len == 0
    check recordResult.diagnostics.len == 1
    check recordResult.diagnostics[0].message.contains(
      "trace recording is not wired in m7")

    let nodeProvider = newJsNodeTestM1Provider()
    let nodeRecordResult = nodeProvider.provider.record(TestScope(
      kind: tskSingle,
      projectRoot: nodeRoot(),
      file: nodeSample(),
      selector: "test/sample.test.js::node runner > runs js"))
    check nodeRecordResult.value.len == 0
    check nodeRecordResult.diagnostics.len == 1
    check nodeRecordResult.diagnostics[0].message.contains("single-case files")

  test "Node test provider records CommonJS and produces non-empty CTFS":
    ## Runs against a workspace that CONTAINS the recorder checkout, which is
    ## how a caller names a sibling recorder now that the provider no longer
    ## searches the process working directory (see the resolution test below).
    ##
    ## The recorder used to be found because this suite happens to run from a
    ## checkout sitting beside ``codetracer-js-recorder``, which is not a route
    ## an end user has: their project is not beside ours. `just build` in the
    ## recorder repo is also unable to create
    ## ``node_modules/.bin/codetracer-js-recorder`` when the workspace's
    ## ``node_modules`` comes from a read-only Nix derivation, so
    ## ``scripts/detect-siblings.sh`` cannot put it on ``PATH`` either and says
    ## so with a warning. Naming a workspace is the route that works in both
    ## configurations, and it is the one asserted here.
    let sibling = jsRecorderSibling()
    if sibling.len == 0 and findExe("codetracer-js-recorder").len == 0 and
        getEnv("CODETRACER_JS_RECORDER_PATH", "").len == 0:
      # Per ci/test/ct-providers.sh, a recording test must fail rather than
      # skip when its recorder is absent — a silent skip is how recorder
      # coverage disappears.
      checkpoint("codetracer-js-recorder is required: build the sibling " &
        "checkout (`direnv exec ../codetracer-js-recorder just build`) or " &
        "set CODETRACER_JS_RECORDER_PATH")
    check (sibling.len > 0 or findExe("codetracer-js-recorder").len > 0 or
      getEnv("CODETRACER_JS_RECORDER_PATH", "").len > 0)

    let workspace = getTempDir() / ("ct-js-record-workspace-" &
      $getCurrentProcessId())
    removeDir(workspace)
    copyDir(nodeRoot(), workspace)
    if sibling.len > 0:
      createSymlink(sibling, workspace / "codetracer-js-recorder")
    defer: removeDir(workspace)

    let
      sampleInWorkspace = workspace / "test/record_single.test.cjs"
      catalog = nodeTestFileCatalog(workspace, sampleInWorkspace).value
      item = catalog.itemBySelector(NodeRecordSelector)
      provider = newJsNodeTestM1Provider()
      recordResult = provider.provider.record(TestScope(
        kind: tskSingle,
        projectRoot: workspace,
        file: sampleInWorkspace,
        testId: item.id,
        selector: item.selector))

    if recordResult.diagnostics.len > 0:
      checkpoint($recordResult.diagnostics)
      checkpoint($recordResult.value)
    check recordResult.diagnostics.len == 0
    check recordResult.value.eventsOfKind(tekRecordStarted).len == 1
    check recordResult.value.eventsOfKind(tekTestStarted).len == 1
    check recordResult.value.eventsOfKind(tekOutput).len == 1
    check recordResult.value.eventsOfKind(tekRecordingCreated).len == 1
    check recordResult.value.eventsOfKind(tekTestFinished).len == 1
    check recordResult.value.eventsOfKind(tekRecordFinished).len == 1
    check recordResult.value.eventsOfKind(tekRecordFinished)[0].status.get ==
      tsPassed
    check recordResult.value.outputContains("Trace written to:")

    let trace = recordResult.value.firstTrace
    check trace.backend == "javascript"
    check trace.entryPoint == "test/record_single.test.cjs"
    check trace.metadata["frameworkSelector"] == item.selector
    let artifacts = toSeq(walkFiles(trace.path / "*.ct"))
    check artifacts.len == 1
    check getFileSize(artifacts[0]) > 0
    for event in recordResult.value:
      check event.validateEvent.valid

  test "node:test recorder resolution is anchored to the workspace, not the cwd":
    ## REGRESSION. ``jsRecorderCommandPrefix`` used to look for the recorder
    ## checkout under ``getCurrentDir().parentDir``, so *whether a trace could
    ## be recorded at all*, and by which repository's recorder, depended on the
    ## directory the shell happened to be in. Measured against the pre-fix
    ## binary with one workspace, one file, one selector and one environment,
    ## varying only the cwd, this same call answered three different ways:
    ##
    ##   cwd beside the workspace  → the workspace's own recorder
    ##   cwd = $HOME               → "codetracer-js-recorder is required"
    ##   cwd = the codetracer repo → an UNRELATED checkout's recorder
    ##
    ## The third is the one worth naming: the trace is produced by a recorder
    ## belonging to a repository the caller never mentioned, and nothing in the
    ## output says so.
    ##
    ## The recorder here is a stub that exits non-zero. The assertion is on the
    ## command the provider *chose* — reported verbatim by ``tekRecordStarted``
    ## — because resolution is the whole subject; whether the recorder then
    ## produces a trace is the preceding test's business.
    let
      sandbox = getTempDir() / ("ct-js-recorder-anchor-" &
        $getCurrentProcessId())
      workspace = sandbox / "workspace"
      bareWorkspace = sandbox / "bare-workspace"
      elsewhere = sandbox / "elsewhere"
      workspaceCli = workspace / "codetracer-js-recorder" / "packages" /
        "cli" / "dist" / "index.js"
      pathDir = sandbox / "path-bin"
      pathCli = pathDir / "codetracer-js-recorder"
      configuredCli = pathDir / "configured-js-recorder"
      selector = "test/only.test.cjs::records only"
    removeDir(sandbox)
    for dir in [workspace, bareWorkspace, elsewhere, pathDir]:
      createDir(dir)
    defer: removeDir(sandbox)

    createDir(workspaceCli.parentDir)
    writeFile(workspaceCli, "process.exit(3)\n")
    writeExecutable(pathCli, "#!/bin/sh\nexit 4\n")
    writeExecutable(configuredCli, "#!/bin/sh\nexit 5\n")
    for root in [workspace, bareWorkspace]:
      createDir(root / "test")
      writeFile(root / "test/only.test.cjs",
        "const { test } = require('node:test');\n" &
        "test('records only', () => {});\n")

    proc recordFrom(projectRoot: string): ProviderResult[seq[TestEvent]] =
      recordNodeTestCommand("js-node-test", TestScope(
        kind: tskSingle,
        projectRoot: projectRoot,
        file: projectRoot / "test/only.test.cjs",
        testId: "anchor",
        selector: selector))

    proc chosenCommand(res: ProviderResult[seq[TestEvent]]): string =
      let started = res.value.eventsOfKind(tekRecordStarted)
      if started.len == 1: started[0].message else: ""

    # The recorder must not be reachable by an earlier fallback than the one
    # each case is about, so PATH is stripped of every provider of the name.
    let neutralPath = pathWithout("codetracer-js-recorder")

    withEnvValue("PATH", neutralPath):
      withoutEnvValue("CODETRACER_JS_RECORDER_PATH"):
        # THE REGRESSION: the same workspace, from directories that used to
        # give three different answers, now gives one.
        for cwd in [elsewhere, sandbox, getCurrentDir()]:
          withCurrentDir(cwd):
            let chosen = recordFrom(workspace).chosenCommand
            checkpoint("cwd=" & cwd)
            check chosen.contains(workspaceCli)

        # A workspace that does not contain the recorder is refused, and the
        # diagnostic names the root that was searched rather than leaving the
        # caller to guess which directory was consulted.
        for cwd in [elsewhere, getCurrentDir()]:
          withCurrentDir(cwd):
            let res = recordFrom(bareWorkspace)
            checkpoint("cwd=" & cwd)
            check res.value.len == 0
            check res.diagnostics.len == 1
            check res.diagnostics[0].message.contains(
              "codetracer-js-recorder is required")
            check res.diagnostics[0].message.contains(bareWorkspace)

    # PRECEDENCE, unchanged by the anchoring: an explicitly configured recorder
    # outranks everything, and PATH outranks the workspace checkout. Asserted
    # from a cwd whose parent holds neither, so a pass cannot come from the
    # removed fallback.
    withCurrentDir(elsewhere):
      withEnvValue("PATH", pathDir & PathSep & neutralPath):
        withEnvValue("CODETRACER_JS_RECORDER_PATH", configuredCli):
          check recordFrom(workspace).chosenCommand.contains(configuredCli)
        withoutEnvValue("CODETRACER_JS_RECORDER_PATH"):
          check recordFrom(workspace).chosenCommand.contains(pathCli)
