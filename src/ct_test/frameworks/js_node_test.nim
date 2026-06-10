import std/[os, strutils, tables]

import ../contracts
import ../discovery
import js_common

const
  JsNodeTestProviderId* = "js-node-test"
  JsNodeTestFramework* = "node:test"
  JsNodeTestVersion* = "m7"

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
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: true)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: JsNodeTestProviderId,
    language: "javascript-typescript",
    framework: JsNodeTestFramework,
    displayName: "Node test runner",
    version: JsNodeTestVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(info: TestProviderInfo; projectRoot, filePath: string;
    decl: JsTestDecl;idsBySelector: Table[string, string]): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  var tags = @["node:test"]
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
      detail: "M7 lightweight JS parser; Node runner execution should " &
        "validate against --test-name-pattern",
      confidence: lcMedium),
    stale: false,
    staleReason: "")

proc nodeTestFileCatalog*(
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
    diagnostics: seq[TestDiagnostic] = @[]
  let ext = splitFile(filePath).ext.toLowerAscii
  if ext in [".ts", ".tsx", ".mts", ".cts"]:
    diagnostics.add diagnostic(
      dsInfo,
      "Node test runner TypeScript execution requires a loader or " &
      "sourcemaps; " &
      "M7 run support is limited to directly executable JavaScript",
      filePath)
  for decl in
      parseJsTestDeclarations(projectRoot, filePath, readFile(filePath)):
    let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
    idsBySelector[item.selector] = item.id
    items.add item
  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
        items: items, diagnostics: diagnostics))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in jsFiles(projectRoot):
    let fileResult = nodeTestFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc newJsNodeTestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    ProviderResult[bool](
      diagnostics: @[], value: hasNodeTestProject(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    nodeTestFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    let catalog = nodeTestFileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    runNodeTestCommand(JsNodeTestProviderId, scope)
  provider.record = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    recordNodeTestCommand(JsNodeTestProviderId, scope)
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseEventUnsupported(JsNodeTestProviderId, JsNodeTestVersion)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceUnsupported(
      JsNodeTestProviderId, JsNodeTestVersion, catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: @JsTestConfigFiles)

proc newJsNodeTestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newJsNodeTestM1Provider()])
