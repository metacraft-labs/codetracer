import std/[os, tables]

import ../contracts
import ../discovery
import cpp_common

const
  CppCTestProviderId* = "cpp-ctest"
  CppCTestFramework* = "ctest"
  CppCTestVersion* = "m10"

proc providerCapabilities*(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: false,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: false,
    canRunSingle: true,
    canRecordProject: false,
    canRecordFile: false,
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: false)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: CppCTestProviderId,
    language: "c++",
    framework: CppCTestFramework,
    displayName: "CMake CTest fallback",
    version: CppCTestVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(info: TestProviderInfo; projectRoot: string; decl: CTestDecl): TestItem =
  let file =
    if fileExists(projectRoot / "build" / "CTestTestfile.cmake"):
      "build/CTestTestfile.cmake"
    else:
      "CTestTestfile.cmake"
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, file, decl.name),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: tikCase,
    file: file,
    range: SourceRange(startLine: max(1, decl.line), startColumn: 1,
        endLine: max(1, decl.line), endColumn: max(1, decl.name.len)),
    selector: decl.name,
    parentId: "",
    tags: @["c++", "ctest", "executable-fallback"],
    location: LocationProvenance(
      source: lskFramework,
      detail: "M10 CTest executable-level fallback from CTestTestfile.cmake/add_test entries",
      confidence: lcMedium),
    stale: false,
    staleReason: "")

proc ctestProjectCatalog*(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var items: seq[TestItem] = @[]
  for decl in ctestDecls(projectRoot):
    items.add itemFromDecl(info, projectRoot, decl)
  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
        items: items, diagnostics: @[]))

proc newCppCTestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    ProviderResult[bool](diagnostics: @[], value: hasCTestProject(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[TestCatalog] {.gcsafe.} =
    ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning,
          "CTest fallback discovers executable-level project tests, not source-file tests",
          file)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: providerInfo(), items: @[], diagnostics: @[]))
  provider.discoverProject = proc(projectRoot: string): ProviderResult[TestCatalog] {.gcsafe.} =
    ctestProjectCatalog(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[TestItem]] {.gcsafe.} =
    let catalog = ctestProjectCatalog(projectRoot)
    ProviderResult[seq[TestItem]](
      diagnostics: @[diagnostic(dsWarning,
          "CTest fallback locations are CTestTestfile.cmake add_test entries, not C/C++ source ranges",
          file)],
      value: catalog.value.items)
  provider.run = proc(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
    runNativeCommand(CppCTestProviderId, cfkCTest, scope)
  provider.record = proc(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
    ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsWarning,
          "CTest fallback recording is unsupported in M10 because it lacks framework-native single-test process arguments",
          scope.file)],
      value: @[])
  provider.parseEvent = proc(raw: string): ProviderResult[TestEvent] {.gcsafe.} =
    parseProviderEventLine(CppCTestProviderId, raw)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    ProviderResult[Table[string, TraceMetadata]](
      diagnostics: @[diagnostic(dsWarning,
          "CTest fallback trace entry-point mapping is unsupported in M10")],
      value: initTable[string, TraceMetadata]())
  M1Provider(provider: provider, relevantConfigFiles: @CppConfigFiles)

proc newCppCTestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newCppCTestM1Provider()])
