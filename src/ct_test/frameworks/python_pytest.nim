import std/[os, tables]

import ../contracts
import ../discovery
import python_common

const
  PythonPytestProviderId* = "python-pytest"
  PythonPytestFramework* = "pytest"
  PythonPytestVersion* = "m5"

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
    id: PythonPytestProviderId,
    language: "python",
    framework: PythonPytestFramework,
    displayName: "Python pytest",
    version: PythonPytestVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(
    info: TestProviderInfo;
    projectRoot, filePath: string;
    decl: PythonTestDecl;
    idsBySelector: Table[string, string]): TestItem =
  let
    relative = normalizedRelative(projectRoot, filePath)
    selector = pytestSelector(projectRoot, filePath, decl)
    parentSelector =
      if decl.kind == ptkMethod:
        relative & "::" & decl.className
      else:
        ""
    parentId =
      if parentSelector.len > 0:
        idsBySelector.getOrDefault(parentSelector, "")
      else:
        ""
  var tags = @["python", "pytest"]
  tags.add decl.tags
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative, selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: if "parametrize" in decl.tags: tikParameterizedCase elif decl.kind == ptkClass: tikSuite else: tikCase,
    file: relative,
    range: SourceRange(
      startLine: decl.line,
      startColumn: decl.column,
      endLine: decl.line,
      endColumn: decl.endColumn),
    selector: selector,
    parentId: parentId,
    tags: tags,
    location: LocationProvenance(
      source: lskParser,
      detail: "M5 lightweight Python source parser; reconcile with pytest --collect-only before execution",
      confidence: lcMedium),
    stale: false,
    staleReason: "")

proc pytestFileCatalog*(projectRoot, filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  if not isPythonFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Python source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info, items: @[], diagnostics: @[]))

  let declarations = parsePythonDeclarations(readFile(filePath))
  var
    items: seq[TestItem] = @[]
    idsBySelector = initTable[string, string]()
    diagnostics: seq[TestDiagnostic] = @[]

  for decl in declarations:
    if decl.kind == ptkClass and isPytestClassName(decl.name):
      let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
      idsBySelector[item.selector] = item.id
      items.add item
    elif decl.kind == ptkFunction:
      let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
      idsBySelector[item.selector] = item.id
      items.add item
    elif decl.kind == ptkMethod and isPytestClassName(decl.className):
      let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
      idsBySelector[item.selector] = item.id
      items.add item

  if items.len == 0 and isCandidatePytestFile(filePath):
    diagnostics.add diagnostic(
      dsInfo,
      "pytest candidate file has no source-discoverable test functions or Test* classes",
      filePath)

  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(
      schemaVersion: TestCatalogSchemaVersion,
      provider: info,
      items: items,
      diagnostics: diagnostics))

proc detectProject(projectRoot: string): ProviderResult[bool] =
  if not dirExists(projectRoot):
    return ProviderResult[bool](diagnostics: @[], value: false)
  if hasPytestConfig(projectRoot):
    return ProviderResult[bool](diagnostics: @[], value: true)
  for path in pythonFiles(projectRoot, isCandidatePytestFile):
    let catalog = pytestFileCatalog(projectRoot, path).value
    if catalog.items.len > 0:
      return ProviderResult[bool](diagnostics: @[], value: true)
  ProviderResult[bool](diagnostics: @[], value: false)

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: info,
    items: @[],
    diagnostics: @[])
  for path in pythonFiles(projectRoot, isCandidatePytestFile):
    let fileResult = pytestFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc locateTestsImpl(projectRoot, filePath: string): ProviderResult[seq[TestItem]] =
  let catalog = pytestFileCatalog(projectRoot, filePath)
  ProviderResult[seq[TestItem]](
    diagnostics: catalog.value.diagnostics,
    value: catalog.value.items)

proc notImplementedEvents(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, "Python pytest run/record execution is not wired in M5; command construction is documented and tested", scope.file)],
    value: @[])

proc parseEventUnsupported(raw: string): ProviderResult[TestEvent] {.gcsafe.} =
  ProviderResult[TestEvent](
    diagnostics: @[diagnostic(dsWarning, "Python pytest event parsing is not implemented in M5")],
    value: TestEvent(schemaVersion: TestEventSchemaVersion, providerId: PythonPytestProviderId))

proc mapTraceUnsupported(
    catalog: TestCatalog;
    traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
  ProviderResult[Table[string, TraceMetadata]](
    diagnostics: @[diagnostic(dsWarning, "Python pytest trace entry-point mapping is not implemented in M5")],
    value: initTable[string, TraceMetadata]())

proc newPythonPytestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    detectProject(projectRoot)
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[TestCatalog] {.gcsafe.} =
    pytestFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[TestItem]] {.gcsafe.} =
    locateTestsImpl(projectRoot, file)
  provider.run = notImplementedEvents
  provider.record = notImplementedEvents
  provider.parseEvent = parseEventUnsupported
  provider.mapTraceEntryPoints = mapTraceUnsupported
  M1Provider(
    provider: provider,
    relevantConfigFiles: @["pytest.ini", "tox.ini", "setup.cfg", "pyproject.toml"])

proc newPythonPytestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newPythonPytestM1Provider()])
