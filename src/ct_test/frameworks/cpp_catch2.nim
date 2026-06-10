import std/[os, tables]

import ../contracts
import ../discovery
import cpp_common

const
  CppCatch2ProviderId* = "cpp-catch2"
  CppCatch2Framework* = "catch2"
  CppCatch2Version* = "m10"

proc providerCapabilities*(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: true,
    canRecordProject: false,
    canRecordFile: false,
    canRecordSingle: true,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: true,
    emitsStructuredEvents: false)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: CppCatch2ProviderId,
    language: "c++",
    framework: CppCatch2Framework,
    displayName: "C++ Catch2",
    version: CppCatch2Version,
    capabilities: providerCapabilities())

proc itemFromDecl(info: TestProviderInfo; projectRoot, filePath: string;
    decl: CppTestDecl): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        decl.selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: if decl.kind == ctdSection: tikSuite else: tikCase,
    file: relative,
    range: SourceRange(startLine: decl.line, startColumn: decl.column,
        endLine: decl.endLine, endColumn: decl.endColumn),
    selector: decl.selector,
    parentId: "",
    tags: @["c++"] & decl.tags,
    location: LocationProvenance(
      source: lskParser,
      detail: "M10 lightweight Catch2 macro parser; TEST_CASE/SCENARIO selectors reconcile with --list-tests when available; SECTION is source-only context",
      confidence: if decl.reconciled: lcHigh else: lcMedium),
    stale: false,
    staleReason: "")

proc catch2FileCatalog*(projectRoot, filePath: string;
    listedSelectors: seq[string] = @[]): ProviderResult[TestCatalog] =
  let info = providerInfo()
  if not isCppFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a C/C++ source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
          items: @[], diagnostics: @[]))
  var items: seq[TestItem] = @[]
  for decl in parseCatch2Declarations(readFile(filePath)):
    var reconciled = decl
    reconciled.reconciled = decl.kind == ctdSection or
      listedSelectors.len == 0 or decl.selector in listedSelectors
    items.add itemFromDecl(info, projectRoot, filePath, reconciled)
  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
        items: items, diagnostics: @[]))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in cppFiles(projectRoot):
    let fileResult = catch2FileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc newCppCatch2M1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    ProviderResult[bool](diagnostics: @[], value: hasCatch2Project(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[TestCatalog] {.gcsafe.} =
    catch2FileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[TestItem]] {.gcsafe.} =
    let catalog = catch2FileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = proc(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
    runNativeCommand(CppCatch2ProviderId, cfkCatch2, scope)
  provider.record = proc(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
    recordNativeCommand(CppCatch2ProviderId, cfkCatch2, scope)
  provider.parseEvent = proc(raw: string): ProviderResult[TestEvent] {.gcsafe.} =
    parseProviderEventLine(CppCatch2ProviderId, raw)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceByCatalogId(catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: @CppConfigFiles)

proc newCppCatch2ProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newCppCatch2M1Provider()])
