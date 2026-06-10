import std/[os, strutils, tables]

import ../contracts
import ../discovery
import python_common

const
  PythonUnittestProviderId* = "python-unittest"
  PythonUnittestFramework* = "unittest"
  PythonUnittestVersion* = "m5"

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
    id: PythonUnittestProviderId,
    language: "python",
    framework: PythonUnittestFramework,
    displayName: "Python unittest",
    version: PythonUnittestVersion,
    capabilities: providerCapabilities())

proc contentMentionsUnittest(content: string): bool =
  let sanitized = sanitizePython(content)
  sanitized.contains("import unittest") or
    sanitized.contains("from unittest import") or
    sanitized.contains("unittest.TestCase") or
    sanitized.contains("unittest.IsolatedAsyncioTestCase") or
    sanitized.contains("(IsolatedAsyncioTestCase") or
    sanitized.contains("(TestCase")

proc unittestClassNames(content: string): seq[string] =
  let sanitized = sanitizePython(content)
  for line in sanitized.splitLines:
    let stripped = line.strip
    if stripped.startsWith("class ") and
        (stripped.contains("unittest.TestCase") or
          stripped.contains("unittest.IsolatedAsyncioTestCase") or
          stripped.contains("(IsolatedAsyncioTestCase") or
          stripped.contains("(TestCase")):
      var i = "class ".len
      let start = i
      while i < stripped.len and stripped[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
        inc i
      if i > start:
        result.add stripped[start ..< i]

proc itemFromDecl(
    info: TestProviderInfo;
    projectRoot, filePath: string;
    decl: PythonTestDecl;
    idsBySelector: Table[string, string]): TestItem =
  let
    relative = normalizedRelative(projectRoot, filePath)
    selector = unittestSelector(projectRoot, filePath, decl)
    parentSelector =
      if decl.kind == ptkMethod:
        moduleNameForFile(projectRoot, filePath) & "." & decl.className
      else:
        ""
    parentId =
      if parentSelector.len > 0:
        idsBySelector.getOrDefault(parentSelector, "")
      else:
        ""
  var tags = @["python", "unittest"]
  tags.add decl.tags
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative, selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: if decl.kind == ptkClass: tikSuite else: tikCase,
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
      detail: "M5 lightweight Python source parser; unittest native discovery imports modules and does not expose stable ranges",
      confidence: lcMedium),
    stale: false,
    staleReason: "")

proc unittestFileCatalog*(projectRoot, filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  if not isPythonFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Python source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info, items: @[], diagnostics: @[]))

  let
    content = readFile(filePath)
    classNames = unittestClassNames(content)
    declarations = parsePythonDeclarations(content)
  var
    items: seq[TestItem] = @[]
    idsBySelector = initTable[string, string]()
    diagnostics: seq[TestDiagnostic] = @[]

  for decl in declarations:
    if decl.kind == ptkClass and decl.name in classNames:
      let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
      idsBySelector[item.selector] = item.id
      items.add item
    elif decl.kind == ptkMethod and decl.className in classNames:
      let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
      idsBySelector[item.selector] = item.id
      items.add item

  if items.len == 0 and contentMentionsUnittest(content):
    diagnostics.add diagnostic(
      dsInfo,
      "unittest import detected but no unittest.TestCase test methods were found",
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
    return ProviderResult[bool](
      diagnostics: @[diagnostic(dsInfo, "python-unittest skipped by default because pytest configuration is present")],
      value: false)
  for path in pythonFiles(projectRoot, isCandidateUnittestFile):
    let catalog = unittestFileCatalog(projectRoot, path).value
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
  for path in pythonFiles(projectRoot, isCandidateUnittestFile):
    let fileResult = unittestFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc locateTestsImpl(projectRoot, filePath: string): ProviderResult[seq[TestItem]] =
  let catalog = unittestFileCatalog(projectRoot, filePath)
  ProviderResult[seq[TestItem]](
    diagnostics: catalog.value.diagnostics,
    value: catalog.value.items)

proc notImplementedEvents(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, "Python unittest run/record execution is not wired in M5; command construction is documented and tested", scope.file)],
    value: @[])

proc parseEventUnsupported(raw: string): ProviderResult[TestEvent] {.gcsafe.} =
  ProviderResult[TestEvent](
    diagnostics: @[diagnostic(dsWarning, "Python unittest event parsing is not implemented in M5")],
    value: TestEvent(schemaVersion: TestEventSchemaVersion, providerId: PythonUnittestProviderId))

proc mapTraceUnsupported(
    catalog: TestCatalog;
    traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
  ProviderResult[Table[string, TraceMetadata]](
    diagnostics: @[diagnostic(dsWarning, "Python unittest trace entry-point mapping is not implemented in M5")],
    value: initTable[string, TraceMetadata]())

proc newPythonUnittestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    detectProject(projectRoot)
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[TestCatalog] {.gcsafe.} =
    unittestFileCatalog(projectRoot, file)
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
    relevantConfigFiles: @[".vscode/settings.json", "pyproject.toml", "pytest.ini", "tox.ini", "setup.cfg"])

proc newPythonUnittestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newPythonUnittestM1Provider()])
