import std/[os, tables]

import ../contracts
import ../discovery
import ruby_common

const
  RubyMinitestProviderId* = "ruby-minitest"
  RubyMinitestFramework* = "minitest"
  RubyMinitestVersion* = "m9"

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
    id: RubyMinitestProviderId,
    language: "ruby",
    framework: RubyMinitestFramework,
    displayName: "Ruby Minitest",
    version: RubyMinitestVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(
    info: TestProviderInfo;
    projectRoot, filePath: string;
    decl: RubyTestDecl;
    idsBySelector: Table[string, string]): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  var tags = @["ruby", "minitest"]
  tags.add decl.tags
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        decl.selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: if decl.kind == rtdSuite: tikSuite else: tikCase,
    file: relative,
    range: SourceRange(
      startLine: decl.line,
      startColumn: decl.column,
      endLine: decl.line,
      endColumn: decl.endColumn),
    selector: decl.selector,
    parentId: idsBySelector.getOrDefault(decl.parentSelector, ""),
    tags: tags,
    location: LocationProvenance(
      source: lskParser,
      detail: "M9 lightweight Ruby Minitest parser; native Minitest loading " &
        "remains authoritative before execution",
      confidence: lcMedium),
    stale: false,
    staleReason: "")

proc minitestFileCatalog*(
    projectRoot, filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  if not isRubyFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Ruby source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))

  var
    items: seq[TestItem] = @[]
    idsBySelector = initTable[string, string]()
  for decl in parseMinitestDeclarations(
      projectRoot, filePath, readFile(filePath)):
    let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
    idsBySelector[item.selector] = item.id
    items.add item

  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
        items: items, diagnostics: @[]))

proc detectProject(projectRoot: string): ProviderResult[bool] =
  ProviderResult[bool](diagnostics: @[], value: hasMinitestProject(projectRoot))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in rubyFiles(projectRoot, isCandidateMinitestFile):
    let fileResult = minitestFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc newRubyMinitestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    detectProject(projectRoot)
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    minitestFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    let catalog = minitestFileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    runRubyCommand(RubyMinitestProviderId, rfkMinitest, scope)
  provider.record = proc(scope: TestScope): ProviderResult[seq[
      TestEvent]] {.gcsafe.} =
    recordRubyCommand(RubyMinitestProviderId, rfkMinitest, scope)
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseProviderEventLine(RubyMinitestProviderId, raw)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    mapTraceByCatalogId(RubyMinitestProviderId, catalog, traces)
  M1Provider(provider: provider, relevantConfigFiles: @RubyTestConfigFiles)

proc newRubyMinitestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newRubyMinitestM1Provider()])
