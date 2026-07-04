import std/[algorithm, options, os, osproc, strutils, tables, times]

import ../contracts
import ../discovery
import native_m11_common

const
  DUnittestProviderId* = "d-unittest"
  DUnittestFramework* = "d unittest/dub"
  DUnittestVersion* = "m11"
  DNixPackages* = ["dub", "ldc"]

type
  DCommandScope* = enum
    dcsProject
    dcsFile
    dcsSingle

  DTestDecl* = object
    name*: string
    selector*: string
    line*: int
    column*: int
    endColumn*: int

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc isDFile*(path: string): bool =
  fileExists(path) and splitFile(path).ext.toLowerAscii == ".d"

proc hasDubProject*(projectRoot: string): bool =
  dirExists(projectRoot) and (fileExists(projectRoot / "dub.json") or
    fileExists(projectRoot / "dub.sdl"))

proc dFiles*(projectRoot: string): seq[string]

proc hasDProject*(projectRoot: string): bool =
  if hasDubProject(projectRoot):
    return true
  dFiles(projectRoot).len > 0

proc dFiles*(projectRoot: string): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for path in walkDirRec(projectRoot):
    let rel = normalizedRelative(projectRoot, path)
    if rel.startsWith(".dub/") or rel.startsWith(".git/"):
      continue
    if isDFile(path):
      result.add path
  result.sort(system.cmp[string])

proc parseDUnittestDeclarations*(projectRoot, filePath, content: string): seq[
    DTestDecl] =
  let relative = normalizedRelative(projectRoot, filePath)
  var lineNo = 0
  for rawLine in content.splitLines:
    inc lineNo
    let stripped = rawLine.strip
    if stripped.startsWith("//"):
      continue
    let pos = rawLine.find("unittest")
    if pos >= 0:
      let beforeOk = pos == 0 or rawLine[pos - 1] notin {'A'..'Z', 'a'..'z',
          '0'..'9', '_'}
      let after = pos + "unittest".len
      let afterOk = after >= rawLine.len or rawLine[after] notin {'A'..'Z',
          'a'..'z', '0'..'9', '_'}
      if beforeOk and afterOk:
        let selector = relative & ":" & $lineNo
        result.add DTestDecl(name: "unittest line " & $lineNo,
            selector: selector, line: lineNo, column: pos + 1,
            endColumn: pos + "unittest".len)

proc providerCapabilities*(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: false,
    canRecordProject: false,
    canRecordFile: true,
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: true,
    emitsStructuredEvents: false)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: DUnittestProviderId,
    language: "d",
    framework: DUnittestFramework,
    displayName: "D unittest / dub test",
    version: DUnittestVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(info: TestProviderInfo; projectRoot, filePath: string;
    decl: DTestDecl): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        decl.selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: tikCase,
    file: relative,
    range: SourceRange(startLine: decl.line, startColumn: decl.column,
        endLine: decl.line, endColumn: decl.endColumn),
    selector: decl.selector,
    parentId: "",
    tags: @["d", "unittest"],
    location: LocationProvenance(source: lskParser,
        detail: "M11 lightweight D parser for unittest blocks",
        confidence: lcMedium),
    stale: false,
    staleReason: "")

proc dFileCatalog*(projectRoot, filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  if not isDFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a D source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))
  var items: seq[TestItem] = @[]
  for decl in parseDUnittestDeclarations(projectRoot, filePath,
      readFile(filePath)):
    items.add itemFromDecl(info, projectRoot, filePath, decl)
  ProviderResult[TestCatalog](diagnostics: @[],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: items, diagnostics: @[]))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in dFiles(projectRoot):
    let fileResult = dFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc buildDCommand*(projectRoot, filePath, selector: string;
    scope: DCommandScope): seq[string] =
  case scope
  of dcsProject:
    if hasDubProject(projectRoot):
      @["dub", "test"]
    else:
      @["ldc2", "-unittest", "-main"] & dFiles(projectRoot)
  of dcsFile:
    let rel = normalizedRelative(projectRoot, filePath)
    @["ldc2", "-unittest", "-main", "-run", rel]
  of dcsSingle:
    @[]

proc runD(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  if scope.kind == tskSingle:
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsWarning,
          "D built-in unittest blocks do not expose stable single-test " &
          "selectors; use file or project scope",
          scope.file)],
      value: @[])
  let commandScope = if scope.kind == tskProject: dcsProject else: dcsFile
  runCommand(DUnittestProviderId, scope, buildDCommand(scope.projectRoot,
      scope.file, scope.selector, commandScope), @DNixPackages)

proc recordD(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  if scope.kind != tskFile:
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsWarning,
          "D M11 recording supports file-level unittest scopes only",
          scope.file)],
      value: @[])
  {.cast(gcsafe).}:
    let
      buildRoot = getTempDir() / ("ct-m11-d-build-" &
          $getCurrentProcessId() & "-" & $epochTime().int & "-" & $cpuTime())
      runner = buildRoot / "d-unittest-runner"
      rel = normalizedRelative(scope.projectRoot, scope.file)
      buildArgs = @["ldc2", "-unittest", "-main", "-g", "-of=" & runner, rel]
      buildCommand = commandWithNixFallback(buildArgs, @DNixPackages)
    createDir(buildRoot)
    let build = execCmdEx(buildCommand, options = {poUsePath},
        workingDir = scope.projectRoot)
    if build.exitCode != 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsError,
            "D unittest runner build failed with exit code " & $build.exitCode,
            scope.file)],
        value: @[event(tekFailure, DUnittestProviderId,
            DUnittestProviderId & ":record-build:" & scope.selector,
            if scope.testId.len > 0: scope.testId else: scope.selector,
            some(tsFailed), "D unittest runner build failed", build.output)])
    recordCommand(DUnittestProviderId, scope, @[runner], @[], rel)

proc newDUnittestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    {.cast(gcsafe).}:
      ProviderResult[bool](diagnostics: @[], value: hasDProject(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    dFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    let catalog = dFileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = runD
  provider.record = recordD
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseProviderEventLine(DUnittestProviderId, raw)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceByCatalogId(catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: @["dub.json", "dub.sdl"])

proc newDUnittestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newDUnittestM1Provider()])
