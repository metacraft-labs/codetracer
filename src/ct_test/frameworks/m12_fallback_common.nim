import std/[algorithm, options, os, osproc, sequtils, strutils, tables, times]

import ../contracts
import ../discovery
import native_m11_common

type
  M12FallbackSpec* = object
    providerId*: string
    language*: string
    framework*: string
    displayName*: string
    version*: string
    fileExtensions*: seq[string]
    projectMarkers*: seq[string]
    ignoredDirs*: seq[string]
    runTool*: string
    nixPackages*: seq[string]
    canRecordFile*: bool
    fileCommand*: proc(projectRoot, filePath: string): string {.gcsafe.}
    projectCommand*: proc(projectRoot: string): string {.gcsafe.}
    entryPointDetail*: string
    limitations*: string

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc shellQuote*(value: string): string =
  quoteShell(value)

proc tempExecutable*(prefix, filePath: string): string =
  let parsed = splitFile(filePath)
  getTempDir() / (prefix & "-" & parsed.name & "-" & $getCurrentProcessId())

proc providerCapabilities*(spec: M12FallbackSpec): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: false,
    canRecordProject: false,
    canRecordFile: spec.canRecordFile,
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: spec.canRecordFile,
    emitsStructuredEvents: false)

proc providerInfo*(spec: M12FallbackSpec): TestProviderInfo =
  TestProviderInfo(
    id: spec.providerId,
    language: spec.language,
    framework: spec.framework,
    displayName: spec.displayName,
    version: spec.version,
    capabilities: providerCapabilities(spec))

proc hasProjectMarker*(projectRoot: string; markers: seq[string]): bool =
  if not dirExists(projectRoot):
    return false
  for marker in markers:
    if fileExists(projectRoot / marker) or dirExists(projectRoot / marker):
      return true
  false

proc hasSupportedExtension*(spec: M12FallbackSpec; path: string): bool =
  let ext = splitFile(path).ext.toLowerAscii
  for candidate in spec.fileExtensions:
    if ext == candidate.toLowerAscii:
      return true
  false

proc isIgnored(spec: M12FallbackSpec; projectRoot, path: string): bool =
  let rel = normalizedRelative(projectRoot, path)
  for ignored in spec.ignoredDirs:
    if rel == ignored or rel.startsWith(ignored.strip(chars = {'/'}) & "/"):
      return true
  false

proc sourceFiles*(spec: M12FallbackSpec; projectRoot: string): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for path in walkDirRec(projectRoot):
    if fileExists(path) and spec.hasSupportedExtension(path) and
        not spec.isIgnored(projectRoot, path):
      result.add path
  result.sort(system.cmp[string])

proc hasSourceProject*(spec: M12FallbackSpec; projectRoot: string): bool =
  hasProjectMarker(projectRoot, spec.projectMarkers) or
    spec.sourceFiles(projectRoot).len > 0

proc m12NixAvailable*(): bool =
  getEnv("CODETRACER_CT_TEST_DISABLE_NIX_FALLBACK", "") != "1" and
    nixAvailable()

proc fallbackItem(spec: M12FallbackSpec; projectRoot, filePath: string): TestItem =
  let
    info = providerInfo(spec)
    relative = normalizedRelative(projectRoot, filePath)
    selector = relative
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: splitFile(filePath).name,
    kind: tikCase,
    file: relative,
    range: SourceRange(startLine: 1, startColumn: 1, endLine: 1,
        endColumn: 1),
    selector: selector,
    parentId: "",
    tags: @[spec.language, "m12-fallback", "file"],
    location: LocationProvenance(source: lskFallback,
        detail: spec.entryPointDetail,
        confidence: lcLow),
    stale: false,
    staleReason: "")

proc fallbackFileCatalog*(spec: M12FallbackSpec; projectRoot,
    filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo(spec)
  if not fileExists(filePath) or not spec.hasSupportedExtension(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning,
          "not a supported " & spec.language & " fixture source file",
          filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))
  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info,
      items: @[fallbackItem(spec, projectRoot, filePath)],
      diagnostics: @[diagnostic(dsInfo, spec.limitations, filePath)]))

proc fallbackProjectCatalog*(spec: M12FallbackSpec;
    projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo(spec)
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in spec.sourceFiles(projectRoot):
    catalog.items.add fallbackItem(spec, projectRoot, path)
  catalog.diagnostics.add diagnostic(dsInfo, spec.limitations, projectRoot)
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc commandWithNixShell(command, runTool: string;
    nixPackages: seq[string]): string =
  if toolAvailable(runTool):
    return command
  if nixPackages.len > 0 and m12NixAvailable():
    var args = @["nix", "shell"]
    for pkg in nixPackages:
      args.add "nixpkgs#" & pkg
    args.add @["-c", "sh", "-lc", command]
    return commandLine(args)
  command

proc runShellCommand*(spec: M12FallbackSpec; scope: TestScope;
    command: string): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    if command.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError, "empty fallback command", scope.file)],
        value: @[])
    if not toolAvailable(spec.runTool) and not m12NixAvailable():
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[missingToolDiagnostic(spec.runTool, spec.nixPackages,
            scope.file)],
        value: @[])

    let
      finalCommand = commandWithNixShell(command, spec.runTool,
          spec.nixPackages)
      runId = spec.providerId & ":run:" & $scope.kind & ":" & scope.selector
      testId = if scope.testId.len > 0: scope.testId else: scope.selector
    var events = @[
      event(tekRunStarted, spec.providerId, runId, testId,
          message = finalCommand),
      event(tekTestStarted, spec.providerId, runId, testId,
          message = scope.selector)
    ]
    let started = epochTime()
    let outcome = execCmdEx(finalCommand, options = {poUsePath},
        workingDir = scope.projectRoot)
    let duration = int((epochTime() - started) * 1000)
    if outcome.output.len > 0:
      events.add event(tekOutput, spec.providerId, runId, testId,
          output = outcome.output, durationMs = duration)
    if outcome.exitCode == 0:
      events.add event(tekTestFinished, spec.providerId, runId, testId,
          some(tsPassed), "passed", durationMs = duration)
      events.add event(tekRunFinished, spec.providerId, runId, testId,
          some(tsPassed), "passed", durationMs = duration)
      ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)
    else:
      events.add event(tekFailure, spec.providerId, runId, testId,
          some(tsFailed), "fallback command exited with " & $outcome.exitCode,
          outcome.output, durationMs = duration)
      events.add event(tekRunFinished, spec.providerId, runId, testId,
          some(tsFailed), "failed", durationMs = duration)
      ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "fallback execution failed with exit code " & $outcome.exitCode,
            scope.file)],
        value: events)

proc unsupportedSingle*(spec: M12FallbackSpec; scope: TestScope;
    action: string): ProviderResult[seq[TestEvent]] =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning,
        spec.displayName & " does not advertise " & action &
        " because M12 has no reliable framework-native single-test selector; " &
        "use file-level fixture actions",
        scope.file)],
    value: @[])

proc fallbackRun*(spec: M12FallbackSpec; scope: TestScope): ProviderResult[
    seq[TestEvent]] {.gcsafe.} =
  if scope.kind == tskSingle:
    return unsupportedSingle(spec, scope, "single-test execution")
  let command =
    if scope.kind == tskProject:
      spec.projectCommand(scope.projectRoot)
    else:
      spec.fileCommand(scope.projectRoot, scope.file)
  runShellCommand(spec, scope, command)

proc fallbackRecord*(spec: M12FallbackSpec; scope: TestScope): ProviderResult[
    seq[TestEvent]] {.gcsafe.} =
  if scope.kind == tskSingle:
    return unsupportedSingle(spec, scope, "single-test recording")
  if scope.kind != tskFile:
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsWarning,
          spec.displayName & " M12 recording supports file-level fixtures only",
          scope.file)],
      value: @[])
  if not spec.canRecordFile:
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsWarning,
          spec.displayName & " does not advertise file-level recording in M12; " &
          "run support remains available",
          scope.file)],
      value: @[])
  if not toolAvailable(spec.runTool) and not m12NixAvailable():
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[missingToolDiagnostic(spec.runTool, spec.nixPackages,
          scope.file)],
      value: @[])
  let command = spec.fileCommand(scope.projectRoot, scope.file)
  recordCommand(spec.providerId, scope, @["sh", "-lc", commandWithNixShell(
      command, spec.runTool, spec.nixPackages)], @[],
      normalizedRelative(scope.projectRoot, scope.file))

proc newM12FallbackProvider*(spec: M12FallbackSpec): M1Provider =
  var provider = TestProvider(info: providerInfo(spec))
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    {.cast(gcsafe).}:
      ProviderResult[bool](diagnostics: @[],
          value: spec.hasSourceProject(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    fallbackFileCatalog(spec, projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    fallbackProjectCatalog(spec, projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    let catalog = fallbackFileCatalog(spec, projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    fallbackRun(spec, scope)
  provider.record = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    fallbackRecord(spec, scope)
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseProviderEventLine(spec.providerId, raw)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceByCatalogId(catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: spec.projectMarkers)
