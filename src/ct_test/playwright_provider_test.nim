import std/[json, options, os, osproc, sequtils, strutils, unittest]

import contracts
import ct_test
import discovery
import frameworks/js_playwright

const
  HomeSelector = "tests/home.spec.ts::home page > renders greeting"
  FailingSelector = "tests/form.spec.ts::form flow > fails on missing output"

proc playwrightRoot(): string =
  getCurrentDir() / "src/ct_test/fixtures/js_playwright_project"

proc homeSpec(): string =
  playwrightRoot() / "tests/home.spec.ts"

proc formSpec(): string =
  playwrightRoot() / "tests/form.spec.ts"

proc discoveryJson(): string =
  readFile(playwrightRoot() / PlaywrightJsonDiscoveryFile)

proc resultsJson(): string =
  readFile(playwrightRoot() / PlaywrightJsonResultsFile)

proc itemBySelector(catalog: TestCatalog; selector: string): TestItem =
  for item in catalog.items:
    if item.selector == selector:
      return item
  raise newException(ValueError, "missing selector: " & selector)

proc eventsOfKind(events: seq[TestEvent]; kind: TestEventKind): seq[TestEvent] =
  for event in events:
    if event.kind == kind:
      result.add event

proc finishedBySelector(events: seq[TestEvent]; selector: string): TestEvent =
  let id = makeTestItemId(
    JsPlaywrightProviderId,
    "javascript-typescript",
    JsPlaywrightFramework,
    selector.split("::")[0],
    selector)
  for event in events:
    if event.kind == tekTestFinished and event.testId == id:
      return event
  raise newException(ValueError, "missing finished event: " & selector)

proc catalogProviderIds(response: DiscoverResponse): seq[string] =
  response.catalogs.mapIt(it.provider.id)

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

suite "ct-test M8 Playwright provider":
  test "detects Playwright config and package markers":
    check hasPlaywrightProject(playwrightRoot())
    check newJsPlaywrightM1Provider().provider.detect(playwrightRoot()).value

  test "discovers Playwright tests from JSON reporter output":
    let parsed = parsePlaywrightCatalogJson(playwrightRoot(), discoveryJson())
    check parsed.diagnostics.len == 0
    let catalog = parsed.value
    check catalog.provider.id == JsPlaywrightProviderId
    check catalog.provider.capabilities.canRunFile
    check not catalog.provider.capabilities.canRunSingle
    check not catalog.provider.capabilities.canRecordFile
    check catalog.provider.capabilities.canCapturePerTestOutput
    check catalog.validateCatalog.valid
    check catalog.items.len == 5

    let home = catalog.itemBySelector(HomeSelector)
    let failing = catalog.itemBySelector(FailingSelector)
    check home.file == "tests/home.spec.ts"
    check home.range.startLine == 4
    check "project:chromium" in home.tags
    check failing.file == "tests/form.spec.ts"
    check failing.range.startLine == 9

  test "default discovery batches catalog items by requested file":
    let homeResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: playwrightRoot(),
          file: homeSpec(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(homeResponse) == 0
    check homeResponse.catalogProviderIds == @[JsPlaywrightProviderId]
    check homeResponse.catalogs[0].items.len == 2
    check homeResponse.catalogs[0].items[0].file == "tests/home.spec.ts"

    let formResponse = discover(
      DiscoverRequest(scope: dskFile, workspaceRoot: playwrightRoot(),
          file: formSpec(), jsonOutput: true),
      newDefaultProviderRegistry(),
      newDiscoveryCache())
    check discoverExitCode(formResponse) == 0
    check formResponse.catalogProviderIds == @[JsPlaywrightProviderId]
    check formResponse.catalogs[0].items.len == 3
    check formResponse.catalogs[0].items[0].file == "tests/form.spec.ts"

  test "locateTests forwards Playwright JSON diagnostics":
    let provider = newJsPlaywrightM1Provider()
    let tempRoot = getTempDir() / ("ct-playwright-bad-json-" &
      $getCurrentProcessId())
    createDir(tempRoot / ".ct-test")
    try:
      writeFile(tempRoot / "playwright.config.ts", "export default {};\n")
      writeFile(tempRoot / PlaywrightJsonDiscoveryFile, "{")
      let located = provider.provider.locateTests(
        tempRoot,
        tempRoot / "tests/missing.spec.ts")
      check located.value.len == 0
      check located.diagnostics.len == 1
      check located.diagnostics[0].message.contains(
        "failed to parse Playwright JSON")
    finally:
      removeDir(tempRoot)

  test "builds file batch commands with workers pinned to one":
    check buildPlaywrightCommand(playwrightRoot(), homeSpec(), pcsFile) ==
      @["npx", "--no-install", "playwright", "test", "tests/home.spec.ts",
        "--workers=1", "--reporter=json"]
    check buildPlaywrightCommand(playwrightRoot(), formSpec(), pcsFile,
        listOnly = true) ==
      @["npx", "--no-install", "playwright", "test", "tests/form.spec.ts",
        "--workers=1", "--list", "--reporter=json"]
    check buildPlaywrightCommand(playwrightRoot(), "", pcsProject) ==
      @["npx", "--no-install", "playwright", "test", "--workers=1",
        "--reporter=json"]

  test "playwright_batches_by_file_and_reports_per_test":
    let parsed = parsePlaywrightResultsJson(playwrightRoot(), resultsJson(),
        "m8-fixture-run")
    if parsed.diagnostics.len > 0:
      checkpoint($parsed.diagnostics)
    check parsed.diagnostics.len == 0
    let events = parsed.value
    check events.eventsOfKind(tekRunStarted).len == 1
    check events.eventsOfKind(tekTestStarted).len == 5
    check events.eventsOfKind(tekTestFinished).len == 5
    check events.eventsOfKind(tekFailure).len == 1
    check events.eventsOfKind(tekRunFinished)[0].status.get == tsFailed
    check events.finishedBySelector(HomeSelector).status.get == tsPassed
    check events.finishedBySelector(FailingSelector).status.get == tsFailed
    check events.finishedBySelector(
      "tests/form.spec.ts::form flow > skips optional path").status.get ==
        tsSkipped
    check events.eventsOfKind(tekOutput).len == 2
    for event in events:
      check event.validateEvent.valid

  test "recording capability remains unsupported with explicit diagnostic":
    let provider = newJsPlaywrightM1Provider()
    let recordResult = provider.provider.record(TestScope(
      kind: tskFile,
      projectRoot: playwrightRoot(),
      file: homeSpec(),
      selector: "tests/home.spec.ts"))
    check recordResult.value.len == 0
    check recordResult.diagnostics.len == 1
    check recordResult.diagnostics[0].message.contains(
      "browser trace recording is not advertised in M8")

  test "CLI JSON discovers Playwright provider from fixture output":
    let executable = compileCtTestBinary("ct-test-m8-cli")
    let output = execProcess(
      executable,
      args = @["test", "discover", "--file", homeSpec(), "--json"],
      options = {poUsePath},
      workingDir = playwrightRoot())
    let node = parseJson(output)
    check node["schemaVersion"].getInt == 1
    check node["catalogs"].len == 1
    check node["catalogs"][0]["provider"]["id"].getStr ==
      JsPlaywrightProviderId
    check node["catalogs"][0]["items"].len == 2
