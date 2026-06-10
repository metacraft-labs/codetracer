import std/[json, options, os, osproc, sequtils, strutils, tables]

import ../contracts
import ../discovery
import js_common

const
  JsPlaywrightProviderId* = "js-playwright"
  JsPlaywrightFramework* = "playwright"
  JsPlaywrightVersion* = "m8"
  PlaywrightJsonDiscoveryFile* = ".ct-test/playwright-list.json"
  PlaywrightJsonResultsFile* = ".ct-test/playwright-results.json"
  PlaywrightConfigFiles* = [
    "package.json",
    "playwright.config.js",
    "playwright.config.cjs",
    "playwright.config.mjs",
    "playwright.config.ts",
    "playwright.config.cts",
    "playwright.config.mts",
    "tsconfig.json"
  ]

type
  PlaywrightCommandScope* = enum
    pcsProject
    pcsFile

proc hasPlaywrightProject*(projectRoot: string): bool =
  let pkg = packageJson(projectRoot)
  if hasDependency(projectRoot, "@playwright/test") or
      hasDependency(projectRoot, "playwright"):
    return true
  if pkg.hasKey("scripts") and pkg["scripts"].kind == JObject:
    for _, value in pkg["scripts"]:
      if value.kind == JString and
          value.getStr.toLowerAscii.contains("playwright test"):
        return true
  for marker in PlaywrightConfigFiles:
    if marker != "package.json" and marker != "tsconfig.json" and
        fileExists(projectRoot / marker):
      return true
  false

proc providerCapabilities*(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: false,
    canRecordProject: false,
    canRecordFile: false,
    canRecordSingle: false,
    canCapturePerTestOutput: true,
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: true)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: JsPlaywrightProviderId,
    language: "javascript-typescript",
    framework: JsPlaywrightFramework,
    displayName: "Playwright",
    version: JsPlaywrightVersion,
    capabilities: providerCapabilities())

proc buildPlaywrightCommand*(
    projectRoot, filePath: string;
    scope: PlaywrightCommandScope;
    listOnly = false): seq[string] =
  result = @["npx", "--no-install", "playwright", "test"]
  case scope
  of pcsProject:
    discard
  of pcsFile:
    if filePath.len > 0:
      result.add normalizedRelative(projectRoot, filePath)
  result.add "--workers=1"
  if listOnly:
    result.add "--list"
  result.add "--reporter=json"

proc commandLine(args: seq[string]): string =
  args.mapIt(quoteShell(it)).join(" ")

proc executableAvailable(name: string): bool =
  findExe(name).len > 0

proc nodeText(node: JsonNode): string =
  case node.kind
  of JString:
    node.getStr
  of JObject:
    if node.hasKey("text"):
      node["text"].nodeText
    elif node.hasKey("message"):
      node["message"].nodeText
    else:
      $node
  else:
    $node

proc collectTextArray(node: JsonNode; field: string): string =
  if not node.hasKey(field) or node[field].kind != JArray:
    return ""
  var parts: seq[string] = @[]
  for item in node[field]:
    parts.add item.nodeText
  parts.join("")

proc fieldString(node: JsonNode; name: string; default = ""): string =
  if node.hasKey(name) and node[name].kind != JNull:
    node[name].getStr
  else:
    default

proc fieldInt(node: JsonNode; name: string; default = 0): int =
  if node.hasKey(name) and node[name].kind != JNull:
    node[name].getInt
  else:
    default

proc relFile(projectRoot, rawFile: string): string =
  if rawFile.len == 0:
    return ""
  if isAbsolute(rawFile):
    normalizedRelative(projectRoot, rawFile)
  else:
    rawFile.replace("\\", "/")

proc absFile(projectRoot, rawFile: string): string =
  if rawFile.len == 0:
    return ""
  if isAbsolute(rawFile):
    rawFile
  else:
    projectRoot / rawFile

proc specTitlePath(suiteTitles: seq[string]; spec: JsonNode): seq[string] =
  result = @[]
  if spec.hasKey("titlePath") and spec["titlePath"].kind == JArray:
    for node in spec["titlePath"]:
      let part = node.getStr
      if part.len > 0:
        result.add part
    if result.len > 0:
      return
  for title in suiteTitles:
    if title.len > 0:
      result.add title
  let title = spec.fieldString("title")
  if title.len > 0:
    result.add title

proc selectorFor(relativeFile: string; titles: seq[string]): string =
  relativeFile & "::" & titles.join(" > ")

proc playwrightItem(
    info: TestProviderInfo;
    projectRoot: string;
    spec: JsonNode;
    titles: seq[string]): TestItem =
  let
    rawFile = spec.fieldString("file")
    relative = relFile(projectRoot, rawFile)
    selector = selectorFor(relative, titles)
    line = max(1, spec.fieldInt("line", 1))
    column = max(1, spec.fieldInt("column", 1))
  var tags = @["playwright"]
  if spec.hasKey("tags") and spec["tags"].kind == JArray:
    for tag in spec["tags"]:
      tags.add tag.getStr
  if spec.hasKey("tests") and spec["tests"].kind == JArray:
    for test in spec["tests"]:
      let projectName = test.fieldString("projectName")
      if projectName.len > 0:
        tags.add "project:" & projectName
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: if titles.len > 0: titles[^1] else: spec.fieldString("title"),
    kind: tikCase,
    file: relative,
    range: SourceRange(startLine: line, startColumn: column, endLine: line,
        endColumn: column),
    selector: selector,
    parentId: "",
    tags: tags,
    location: LocationProvenance(
      source: lskFramework,
      detail: "Playwright JSON reporter/list output",
      confidence: lcExact),
    stale: false,
    staleReason: "")

proc collectSpecs(
    info: TestProviderInfo;
    projectRoot: string;
    suite: JsonNode;
    suiteTitles: seq[string];
    items: var seq[TestItem]) =
  var titles = suiteTitles
  let suiteTitle = suite.fieldString("title")
  if suiteTitle.len > 0 and not suite.hasKey("file"):
    titles.add suiteTitle

  if suite.hasKey("specs") and suite["specs"].kind == JArray:
    for spec in suite["specs"]:
      let specFile =
        if spec.fieldString("file").len > 0: spec.fieldString("file")
        else: suite.fieldString("file")
      if specFile.len > 0:
        spec["file"] = %specFile
      let specTitles = specTitlePath(titles, spec)
      if specTitles.len > 0 and spec.fieldString("file").len > 0:
        items.add playwrightItem(info, projectRoot, spec, specTitles)

  if suite.hasKey("suites") and suite["suites"].kind == JArray:
    for child in suite["suites"]:
      collectSpecs(info, projectRoot, child, titles, items)

proc parsePlaywrightCatalogJson*(
    projectRoot: string;
    rawJson: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: info,
    items: @[],
    diagnostics: @[])
  try:
    let root = parseJson(rawJson)
    if root.hasKey("suites") and root["suites"].kind == JArray:
      for suite in root["suites"]:
        collectSpecs(info, projectRoot, suite, @[], catalog.items)
    elif root.hasKey("projects") and root["projects"].kind == JArray:
      for project in root["projects"]:
        if project.hasKey("suites") and project["suites"].kind == JArray:
          for suite in project["suites"]:
            collectSpecs(info, projectRoot, suite, @[], catalog.items)
    else:
      catalog.diagnostics.add diagnostic(
        dsError,
        "Playwright JSON did not contain a suites array")
  except CatchableError as err:
    catalog.diagnostics.add diagnostic(
      dsError,
      "failed to parse Playwright JSON: " & err.msg)
  ProviderResult[TestCatalog](diagnostics: catalog.diagnostics,
      value: catalog)

proc statusFromPlaywright(raw: string): TestResultStatus =
  case raw
  of "passed":
    tsPassed
  of "skipped":
    tsSkipped
  of "failed":
    tsFailed
  else:
    tsErrored

proc event(
    kind: TestEventKind;
    runId, testId: string;
    status = none(TestResultStatus);
    message = "";
    output = "";
    durationMs = 0): TestEvent =
  TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: kind,
    providerId: JsPlaywrightProviderId,
    runId: runId,
    testId: testId,
    status: status,
    message: message,
    output: output,
    durationMs: durationMs,
    trace: none(TraceMetadata),
    diagnostic: none(TestDiagnostic))

proc resultMessage(runResult: JsonNode): string =
  if runResult.hasKey("error") and runResult["error"].kind == JObject:
    let message = runResult["error"].fieldString("message")
    if message.len > 0:
      return message
  if runResult.hasKey("errors") and runResult["errors"].kind == JArray:
    var messages: seq[string] = @[]
    for err in runResult["errors"]:
      if err.kind == JObject:
        let message = err.fieldString("message")
        if message.len > 0:
          messages.add message
    if messages.len > 0:
      return messages.join("\n")
  ""

proc collectResultEvents(
    projectRoot: string;
    suite: JsonNode;
    suiteTitles: seq[string];
    runId: string;
    events: var seq[TestEvent]) =
  var titles = suiteTitles
  let suiteTitle = suite.fieldString("title")
  if suiteTitle.len > 0 and not suite.hasKey("file"):
    titles.add suiteTitle

  if suite.hasKey("specs") and suite["specs"].kind == JArray:
    for spec in suite["specs"]:
      let rawFile =
        if spec.fieldString("file").len > 0: spec.fieldString("file")
        else: suite.fieldString("file")
      let relative = relFile(projectRoot, rawFile)
      let specTitles = specTitlePath(titles, spec)
      let selector = selectorFor(relative, specTitles)
      let testId = makeTestItemId(
        JsPlaywrightProviderId,
        "javascript-typescript",
        JsPlaywrightFramework,
        relative,
        selector)
      events.add event(tekTestStarted, runId, testId, message = selector)
      var
        finalStatus = tsErrored
        durationMs = 0
        output = ""
        failureMessage = ""
      if spec.hasKey("tests") and spec["tests"].kind == JArray:
        for test in spec["tests"]:
          let statusText = test.fieldString("status",
              test.fieldString("expectedStatus", ""))
          if statusText.len > 0:
            finalStatus = statusFromPlaywright(statusText)
          if test.hasKey("results") and test["results"].kind == JArray:
            for runResult in test["results"]:
              if runResult.hasKey("status"):
                finalStatus =
                  statusFromPlaywright(runResult.fieldString("status"))
              durationMs += runResult.fieldInt("duration")
              output.add runResult.collectTextArray("stdout")
              output.add runResult.collectTextArray("stderr")
              let message = runResult.resultMessage
              if message.len > 0:
                failureMessage = message
      if output.len > 0:
        events.add event(tekOutput, runId, testId, output = output)
      if finalStatus in {tsFailed, tsErrored}:
        events.add event(tekFailure, runId, testId, some(finalStatus),
            failureMessage)
      events.add event(tekTestFinished, runId, testId, some(finalStatus),
          $finalStatus, durationMs = durationMs)

  if suite.hasKey("suites") and suite["suites"].kind == JArray:
    for child in suite["suites"]:
      collectResultEvents(projectRoot, child, titles, runId, events)

proc parsePlaywrightResultsJson*(
    projectRoot: string;
    rawJson: string;
    runId = "js-playwright:run"): ProviderResult[seq[TestEvent]] =
  var events = @[event(tekRunStarted, runId, "", message = "playwright-json")]
  var diagnostics: seq[TestDiagnostic] = @[]
  try:
    let root = parseJson(rawJson)
    if root.hasKey("suites") and root["suites"].kind == JArray:
      for suite in root["suites"]:
        collectResultEvents(projectRoot, suite, @[], runId, events)
    else:
      diagnostics.add diagnostic(
        dsError,
        "Playwright results JSON did not contain a suites array")
    var finalStatus = tsPassed
    for item in events:
      if item.kind == tekTestFinished and item.status.isSome and
          item.status.get in {tsFailed, tsErrored}:
        finalStatus = tsFailed
    events.add event(tekRunFinished, runId, "", some(finalStatus),
        $finalStatus)
  except CatchableError as err:
    diagnostics.add diagnostic(
      dsError,
      "failed to parse Playwright results JSON: " & err.msg)
    events.add event(tekRunFinished, runId, "", some(tsErrored), "errored")
  ProviderResult[seq[TestEvent]](diagnostics: diagnostics, value: events)

proc catalogFromFixtureOrCommand(
    projectRoot, filePath: string): ProviderResult[TestCatalog] =
  let fixtureJson = projectRoot / PlaywrightJsonDiscoveryFile
  if fileExists(fixtureJson):
    let parsed = parsePlaywrightCatalogJson(projectRoot, readFile(fixtureJson))
    if filePath.len == 0:
      return parsed
    let relative = normalizedRelative(projectRoot, filePath)
    var filtered = parsed.value
    filtered.items = filtered.items.filterIt(it.file == relative)
    return ProviderResult[TestCatalog](diagnostics: parsed.diagnostics,
        value: filtered)

  if not executableAvailable("npx"):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsError,
          "Playwright discovery requires Node.js/npx and @playwright/test; " &
          "no local Playwright JSON fixture or npx executable was found",
          filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: providerInfo(), items: @[], diagnostics: @[]))

  let
    scope = if filePath.len > 0: pcsFile else: pcsProject
    command = commandLine(buildPlaywrightCommand(projectRoot, filePath, scope,
        listOnly = true))
    result = execCmdEx(command, options = {poUsePath},
        workingDir = projectRoot)
  if result.exitCode != 0:
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsError,
          "Playwright discovery failed with exit code " & $result.exitCode &
          ": " & result.output,
          filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: providerInfo(), items: @[], diagnostics: @[]))
  parsePlaywrightCatalogJson(projectRoot, result.output)

proc runPlaywright*(
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    if scope.kind == tskSingle:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsWarning,
            "Playwright M8 batches by file and does not advertise " &
            "single-test execution",
            scope.file)],
        value: @[])
    if not executableAvailable("npx"):
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Playwright execution requires Node.js/npx and installed " &
            "@playwright/test plus browser binaries; npx was not found",
            scope.file)],
        value: @[])

    let
      commandScope = if scope.kind == tskProject: pcsProject else: pcsFile
      runId = JsPlaywrightProviderId & ":" & $scope.kind & ":" & scope.file
      command = commandLine(buildPlaywrightCommand(scope.projectRoot,
          scope.file, commandScope))
      result = execCmdEx(command, options = {poUsePath},
          workingDir = scope.projectRoot)
    if result.output.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "Playwright did not emit JSON reporter output", scope.file)],
        value: @[])
    let parsed = parsePlaywrightResultsJson(scope.projectRoot, result.output,
        runId)
    var diagnostics = parsed.diagnostics
    if result.exitCode != 0:
      diagnostics.add diagnostic(dsWarning,
          "Playwright exited with code " & $result.exitCode &
          "; per-test failure events were parsed from JSON output",
          scope.file)
    ProviderResult[seq[TestEvent]](diagnostics: diagnostics,
        value: parsed.value)

proc recordUnsupported(
    scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning,
        "Playwright browser trace recording is not advertised in M8 because " &
        "this environment lacks installed @playwright/test browser binaries " &
        "and no CodeTracer browser-trace ingestion path is wired yet",
        scope.file)],
    value: @[])

proc newJsPlaywrightM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    ProviderResult[bool](diagnostics: @[],
        value: hasPlaywrightProject(projectRoot))
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    catalogFromFixtureOrCommand(projectRoot, "")
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    catalogFromFixtureOrCommand(projectRoot, file)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    let catalog = catalogFromFixtureOrCommand(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.diagnostics,
        value: catalog.value.items)
  provider.run = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    runPlaywright(scope)
  provider.record = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    recordUnsupported(scope)
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    let parsed = parsePlaywrightResultsJson("", raw)
    if parsed.value.len > 0:
      ProviderResult[TestEvent](diagnostics: parsed.diagnostics,
          value: parsed.value[0])
    else:
      ProviderResult[TestEvent](diagnostics: parsed.diagnostics,
          value: TestEvent(schemaVersion: TestEventSchemaVersion,
              providerId: JsPlaywrightProviderId))
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceUnsupported(
      JsPlaywrightProviderId, JsPlaywrightVersion, catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: @PlaywrightConfigFiles)

proc newJsPlaywrightProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newJsPlaywrightM1Provider()])
