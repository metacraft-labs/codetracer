import std/[os, tables]

import ../contracts
import ../discovery
import js_common

const
  JsVitestProviderId* = "js-vitest"
  JsVitestFramework* = "vitest"
  JsVitestVersion* = "m7"

proc providerCapabilities*(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: false,
    canRunFile: false,
    canRunSingle: false,
    canRecordProject: false,
    canRecordFile: false,
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: false)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: JsVitestProviderId,
    language: "javascript-typescript",
    framework: JsVitestFramework,
    displayName: "Vitest",
    version: JsVitestVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(info: TestProviderInfo; projectRoot, filePath: string;
    decl: JsTestDecl;idsBySelector: Table[string, string]): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  var tags = @["vitest"]
  tags.add decl.tags
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        decl.selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: if decl.kind == jtdSuite: tikSuite else: tikCase,
    file: relative,
    range: SourceRange(startLine: decl.line, startColumn: decl.column,
        endLine: decl.line, endColumn: decl.endColumn),
    selector: decl.selector,
    parentId: idsBySelector.getOrDefault(decl.parentSelector, ""),
    tags: tags,
    location: LocationProvenance(
      source: lskParser,
      detail: "M7 lightweight JS/TS parser; reconcile with Vitest native " &
        "collection before execution",
      confidence: lcMedium),
    stale: false,
    staleReason: "")

proc vitestFileCatalog*(
    projectRoot, filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  if not isJsFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning,
          "not a JavaScript/TypeScript source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))
  var
    items: seq[TestItem] = @[]
    idsBySelector = initTable[string, string]()
  for decl in
      parseJsTestDeclarations(projectRoot, filePath, readFile(filePath)):
    let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
    idsBySelector[item.selector] = item.id
    items.add item
  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
        items: items, diagnostics: @[]))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in jsFiles(projectRoot):
    let fileResult = vitestFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc newJsVitestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    ProviderResult[bool](diagnostics: @[], value: hasVitestProject(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    vitestFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    let catalog = vitestFileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    unsupportedRun(JsVitestProviderId, JsVitestVersion, scope)
  provider.record = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    unsupportedRecord(JsVitestProviderId, JsVitestVersion, scope)
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseEventUnsupported(JsVitestProviderId, JsVitestVersion)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceUnsupported(JsVitestProviderId, JsVitestVersion, catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: @JsTestConfigFiles)

proc newJsVitestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newJsVitestM1Provider()])
