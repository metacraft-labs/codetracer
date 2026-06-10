import std/[algorithm, json, options, os, sha1, strutils, tables]

import contracts

type
  DiscoverScopeKind* = enum
    dskWorkspace
    dskFile

  DiscoverRequest* = object
    scope*: DiscoverScopeKind
    workspaceRoot*: string
    file*: string
    jsonOutput*: bool

  DiscoverResponse* = object
    schemaVersion*: int
    workspaceRoot*: string
    file*: string
    catalogs*: seq[TestCatalog]
    diagnostics*: seq[TestDiagnostic]

  CacheStats* = object
    hits*: int
    misses*: int
    invalidations*: int

  DiscoveryCache* = ref object
    entries: Table[string, ProviderResult[TestCatalog]]
    fileIndex: Table[string, seq[string]]
    stats*: CacheStats

  M1Provider* = object
    provider*: TestProvider
    relevantConfigFiles*: seq[string]

  ProviderRegistry* = object
    providers*: seq[M1Provider]

  FakeProviderCounters* = ref object
    detectCalls*: int
    discoverProjectCalls*: int
    discoverFileCalls*: Table[string, int]

const
  DiscoverSchemaVersion* = TestCatalogSchemaVersion

proc newDiscoveryCache*(): DiscoveryCache =
  DiscoveryCache(
    entries: initTable[string, ProviderResult[TestCatalog]](),
    fileIndex: initTable[string, seq[string]](),
    stats: CacheStats())

proc diagnostic*(
    severity: DiagnosticSeverity;
    message: string;
    file = ""): TestDiagnostic =
  TestDiagnostic(
    severity: severity,
    message: message,
    file: file,
    range: none(SourceRange))

proc absoluteNormalized(path: string): string =
  normalizedPath(absolutePath(path))

proc hashString(value: string): string =
  $secureHash(value)

proc hashFileContent(path: string): string =
  if fileExists(path):
    hashString(readFile(path))
  else:
    "missing"

proc configFingerprint(workspaceRoot: string; configFiles: seq[
    string]): string =
  var parts: seq[string] = @[]
  for config in configFiles:
    let path = workspaceRoot / config
    if fileExists(path):
      parts.add config.replace("\\", "/") & "=" & hashFileContent(path)
  parts.join("|")

proc cacheKey(
    workspaceRoot, providerId, filePath: string;
    fileHash: string;
    configHash: string): string =
  [
    absoluteNormalized(workspaceRoot),
    providerId,
    absoluteNormalized(filePath),
    fileHash,
    configHash
  ].join("\t")

proc fileIndexKey(workspaceRoot, providerId, filePath: string): string =
  [
    absoluteNormalized(workspaceRoot),
    providerId,
    absoluteNormalized(filePath)
  ].join("\t")

proc rememberFileKey(cache: DiscoveryCache; indexKey, key: string) =
  var keys = cache.fileIndex.getOrDefault(indexKey, @[])
  if key notin keys:
    keys.add key
  cache.fileIndex[indexKey] = keys

proc invalidateStaleFileEntries(
    cache: DiscoveryCache;
    indexKey, currentKey: string) =
  let previous = cache.fileIndex.getOrDefault(indexKey, @[])
  var kept: seq[string] = @[]
  for key in previous:
    if key == currentKey:
      kept.add key
    elif cache.entries.hasKey(key):
      cache.entries.del key
      inc cache.stats.invalidations
  if kept.len > 0:
    cache.fileIndex[indexKey] = kept
  elif cache.fileIndex.hasKey(indexKey):
    cache.fileIndex.del indexKey

proc discoverFileCached(
    cache: DiscoveryCache;
    provider: M1Provider;
    workspaceRoot, filePath: string): ProviderResult[TestCatalog] =
  let
    fileHash = hashFileContent(filePath)
    configHash = configFingerprint(workspaceRoot, provider.relevantConfigFiles)
    key = cacheKey(workspaceRoot, provider.provider.info.id, filePath,
      fileHash, configHash)
    indexKey = fileIndexKey(workspaceRoot, provider.provider.info.id, filePath)

  cache.invalidateStaleFileEntries(indexKey, key)
  if cache.entries.hasKey(key):
    inc cache.stats.hits
    return cache.entries[key]

  inc cache.stats.misses
  result = provider.provider.discoverFile(workspaceRoot, filePath)
  cache.entries[key] = result
  cache.rememberFileKey(indexKey, key)

proc validateRequest*(request: DiscoverRequest): seq[TestDiagnostic] =
  result = @[]
  if request.workspaceRoot.len == 0:
    result.add diagnostic(dsError, "missing required --workspace <path>")
  elif not dirExists(request.workspaceRoot):
    result.add diagnostic(
      dsError,
      "invalid workspace: directory does not exist: " & request.workspaceRoot)

  if request.scope == dskFile:
    if request.file.len == 0:
      result.add diagnostic(dsError, "missing required --file <path>")
    elif not fileExists(request.file):
      result.add diagnostic(dsError, "invalid file: file does not exist: " &
          request.file, request.file)

proc parseDiscoverArgs*(args: seq[string]): ProviderResult[DiscoverRequest] =
  var
    request = DiscoverRequest(scope: dskWorkspace, jsonOutput: false)
    diagnostics: seq[TestDiagnostic] = @[]
    i = 0

  while i < args.len:
    case args[i]
    of "--workspace":
      if i + 1 >= args.len:
        diagnostics.add diagnostic(dsError, "missing value for --workspace")
      else:
        request.workspaceRoot = args[i + 1]
        inc i
    of "--file":
      if i + 1 >= args.len:
        diagnostics.add diagnostic(dsError, "missing value for --file")
      else:
        request.scope = dskFile
        request.file = args[i + 1]
        inc i
    of "--json":
      request.jsonOutput = true
    else:
      diagnostics.add diagnostic(
        dsError, "unknown discover argument: " & args[i])
    inc i

  if request.workspaceRoot.len == 0 and request.scope == dskFile and
      request.file.len > 0:
    request.workspaceRoot = getCurrentDir()

  for requestDiagnostic in validateRequest(request):
    diagnostics.add requestDiagnostic

  ProviderResult[DiscoverRequest](diagnostics: diagnostics, value: request)

proc responseToJson*(response: DiscoverResponse): JsonNode =
  var catalogs = newJArray()
  var diagnostics = newJArray()
  for catalog in response.catalogs:
    catalogs.add catalog.toJson
  for diagnostic in response.diagnostics:
    diagnostics.add diagnostic.toJson
  %*{
    "schemaVersion": response.schemaVersion,
    "workspaceRoot": response.workspaceRoot,
    "file": response.file,
    "catalogs": catalogs,
    "diagnostics": diagnostics
  }

proc hasErrors(response: DiscoverResponse): bool =
  for diagnostic in response.diagnostics:
    if diagnostic.severity == dsError:
      return true
  false

proc hasErrorDiagnostics(diagnostics: seq[TestDiagnostic]): bool =
  for diagnostic in diagnostics:
    if diagnostic.severity == dsError:
      return true
  false

proc discover*(
    request: DiscoverRequest;
    registry: ProviderRegistry;
    cache: DiscoveryCache): DiscoverResponse =
  result = DiscoverResponse(
    schemaVersion: DiscoverSchemaVersion,
    workspaceRoot: request.workspaceRoot,
    file: request.file,
    catalogs: @[],
    diagnostics: @[])

  let validationDiagnostics = validateRequest(request)
  if validationDiagnostics.len > 0:
    result.diagnostics = validationDiagnostics
    return

  var supportedProviders = 0
  for provider in registry.providers:
    let detected = provider.provider.detect(request.workspaceRoot)
    for item in detected.diagnostics:
      result.diagnostics.add item
    if not detected.value:
      result.diagnostics.add diagnostic(
        dsWarning,
        "unsupported provider: " & provider.provider.info.id &
        " did not detect a compatible framework")
      continue

    inc supportedProviders
    case request.scope
    of dskFile:
      if not provider.provider.info.capabilities.canDiscoverFile:
        result.diagnostics.add diagnostic(
          dsWarning,
          "unsupported provider: " & provider.provider.info.id &
          " cannot discover files",
          request.file)
        continue
      let providerResult = cache.discoverFileCached(provider,
          request.workspaceRoot, request.file)
      if providerResult.value.items.len > 0:
        for item in providerResult.diagnostics:
          result.diagnostics.add item
        result.catalogs.add providerResult.value
      elif providerResult.diagnostics.hasErrorDiagnostics:
        for item in providerResult.diagnostics:
          result.diagnostics.add item
    of dskWorkspace:
      if not provider.provider.info.capabilities.canDiscoverProject:
        result.diagnostics.add diagnostic(
          dsWarning,
        "unsupported provider: " & provider.provider.info.id &
        " cannot discover workspaces")
        continue
      let providerResult = provider.provider.discoverProject(
          request.workspaceRoot)
      for item in providerResult.diagnostics:
        result.diagnostics.add item
      result.catalogs.add providerResult.value

  if supportedProviders == 0:
    result.diagnostics.add diagnostic(dsError,
      "no supported test providers detected for workspace")

proc discoverExitCode*(response: DiscoverResponse): int =
  if response.hasErrors: 1 else: 0

proc baseCapabilities(
    canDiscoverProject = true;
    canDiscoverFile = true): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: canDiscoverProject,
    canDiscoverFile: canDiscoverFile,
    canLocateTests: true,
    canRunProject: false,
    canRunFile: false,
    canRunSingle: false,
    canRecordProject: false,
    canRecordFile: false,
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: true)

proc fakeProviderInfo(id: string): TestProviderInfo =
  TestProviderInfo(
    id: id,
    language: "fake",
    framework: "fixture",
    displayName: "Fake Fixture Provider",
    version: "m1",
    capabilities: baseCapabilities())

proc fakeItem(providerId, workspaceRoot, filePath: string;
    line: int): TestItem =
  let relative = relativePath(filePath, workspaceRoot).replace("\\", "/")
  let selector = relative & "::test_" & $line
  TestItem(
    id: makeTestItemId(providerId, "fake", "fixture", relative, selector),
    providerId: providerId,
    language: "fake",
    framework: "fixture",
    name: "test_" & $line,
    kind: tikCase,
    file: relative,
    range: SourceRange(
      startLine: line,
      startColumn: 1,
      endLine: line,
      endColumn: 10),
    selector: selector,
    parentId: "",
    tags: @["m1-fixture"],
    location: LocationProvenance(
      source: lskPattern,
      detail: "M1 deterministic fake provider",
      confidence: lcMedium),
    stale: false,
    staleReason: "")

proc fixtureLines(filePath: string): seq[int] =
  result = @[]
  if not fileExists(filePath):
    return
  var lineNo = 0
  for line in lines(filePath):
    inc lineNo
    if line.strip.startsWith("# CT_TEST_FAKE"):
      result.add lineNo
  if result.len == 0:
    result.add 1

proc fakeFileCatalog(providerInfo: TestProviderInfo; workspaceRoot,
    filePath: string): TestCatalog =
  var items: seq[TestItem] = @[]
  for line in fixtureLines(filePath):
    items.add fakeItem(providerInfo.id, workspaceRoot, filePath, line)
  TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: providerInfo,
    items: items,
    diagnostics: @[diagnostic(dsInfo,
      "stale parser/cache fallback: M1 fake provider uses pattern-based " &
      "fixture discovery",
      filePath)])

proc fakeProjectFiles(workspaceRoot: string): seq[string] =
  result = @[]
  for path in walkDirRec(workspaceRoot):
    if fileExists(path) and path.endsWith(".fake") and
        splitFile(path).name != "ct-test":
      result.add path
  result.sort(system.cmp[string])

proc newFakeProviderRegistry*(counters: FakeProviderCounters):
    ProviderRegistry =
  let info = fakeProviderInfo("m1-fake")
  var provider = TestProvider(info: info)
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    inc counters.detectCalls
    ProviderResult[bool](diagnostics: @[], value: fileExists(projectRoot /
        "ct-test.fake"))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    let normalized = absoluteNormalized(file)
    counters.discoverFileCalls[normalized] =
      counters.discoverFileCalls.getOrDefault(normalized, 0) + 1
    ProviderResult[TestCatalog](
      diagnostics: @[],
      value: fakeFileCatalog(info, projectRoot, file))
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    inc counters.discoverProjectCalls
    var catalog = TestCatalog(
      schemaVersion: TestCatalogSchemaVersion,
      provider: info,
      items: @[],
      diagnostics: @[])
    for path in fakeProjectFiles(projectRoot):
      let fileCatalog = fakeFileCatalog(info, projectRoot, path)
      catalog.items.add fileCatalog.items
      catalog.diagnostics.add fileCatalog.diagnostics
    ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

  let unsupportedInfo = TestProviderInfo(
    id: "m1-unsupported",
    language: "fake",
    framework: "unsupported",
    displayName: "Unsupported M1 Provider",
    version: "m1",
    capabilities: baseCapabilities(canDiscoverProject = false,
        canDiscoverFile = false))
  var unsupported = TestProvider(info: unsupportedInfo)
  unsupported.detect = proc(projectRoot: string): ProviderResult[
      bool] {.gcsafe.} =
    ProviderResult[bool](
      diagnostics: @[diagnostic(dsInfo,
        "unsupported provider probe completed: m1-unsupported")],
      value: false)

  ProviderRegistry(providers: @[
    M1Provider(provider: provider, relevantConfigFiles: @["ct-test.fake"]),
    M1Provider(provider: unsupported, relevantConfigFiles: @[])
  ])

proc newFakeProviderCounters*(): FakeProviderCounters =
  FakeProviderCounters(discoverFileCalls: initTable[string, int]())

proc emptyProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[])
