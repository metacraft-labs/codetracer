import std/[algorithm, options, os, sequtils, strutils, tables]

import ../contracts
import ../discovery
import native_m11_common

const
  GoTestProviderId* = "go-test"
  GoTestFramework* = "go test"
  GoTestVersion* = "m11"
  GoNixPackages* = ["go"]

type
  GoCommandScope* = enum
    gcsProject
    gcsFile
    gcsSingle

  GoDeclKind* = enum
    gdkTest
    gdkBenchmark
    gdkSubtest

  GoTestDecl* = object
    kind*: GoDeclKind
    name*: string
    selector*: string
    parentSelector*: string
    line*: int
    column*: int
    endColumn*: int

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc isGoTestFile*(path: string): bool =
  fileExists(path) and path.endsWith("_test.go")

proc hasGoProject*(projectRoot: string): bool =
  dirExists(projectRoot) and fileExists(projectRoot / "go.mod")

proc goFiles*(projectRoot: string): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for path in walkDirRec(projectRoot):
    let rel = normalizedRelative(projectRoot, path)
    if rel.startsWith("vendor/") or rel.startsWith(".git/"):
      continue
    if isGoTestFile(path):
      result.add path
  result.sort(system.cmp[string])

proc identAfter(line, prefix: string): tuple[name: string; column: int;
    endColumn: int] =
  let pos = line.find(prefix)
  if pos < 0:
    return ("", 0, 0)
  var i = pos + prefix.len
  let start = i
  while i < line.len and line[i] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
    inc i
  if i == start:
    return ("", 0, 0)
  (line[start ..< i], pos + 1, i)

proc goExportedTestName(name: string; prefix: string): bool =
  if not name.startsWith(prefix) or name.len == prefix.len:
    return false
  let ch = name[prefix.len]
  not (ch in {'a'..'z'})

proc firstQuotedAfter(line: string; marker: string): string =
  let markerPos = line.find(marker)
  if markerPos < 0:
    return ""
  var i = markerPos + marker.len
  while i < line.len and line[i] in {' ', '\t', '('}:
    inc i
  if i >= line.len or line[i] != '"':
    return ""
  inc i
  while i < line.len:
    if line[i] == '\\':
      inc i
      if i < line.len:
        result.add line[i]
        inc i
      continue
    if line[i] == '"':
      return
    result.add line[i]
    inc i
  ""

proc braceDelta(line: string): int =
  for ch in line:
    if ch == '{':
      inc result
    elif ch == '}':
      dec result

proc parseGoTestDeclarations*(content: string): seq[GoTestDecl] =
  var
    lineNo = 0
    inFunc = false
    funcDepth = 0
    parent = ""
    parentKind = gdkTest
  for rawLine in content.splitLines:
    inc lineNo
    let stripped = rawLine.strip
    if stripped.startsWith("//"):
      continue

    if not inFunc:
      let testInfo = identAfter(rawLine, "func Test")
      if testInfo.name.len > 0 and goExportedTestName("Test" &
          testInfo.name, "Test"):
        let name = "Test" & testInfo.name
        result.add GoTestDecl(kind: gdkTest, name: name, selector: name,
            parentSelector: "", line: lineNo, column: testInfo.column,
            endColumn: testInfo.endColumn)
        inFunc = true
        funcDepth = braceDelta(rawLine)
        parent = name
        parentKind = gdkTest
        continue

      let benchInfo = identAfter(rawLine, "func Benchmark")
      if benchInfo.name.len > 0 and goExportedTestName("Benchmark" &
          benchInfo.name, "Benchmark"):
        let name = "Benchmark" & benchInfo.name
        result.add GoTestDecl(kind: gdkBenchmark, name: name, selector: name,
            parentSelector: "", line: lineNo, column: benchInfo.column,
            endColumn: benchInfo.endColumn)
        inFunc = true
        funcDepth = braceDelta(rawLine)
        parent = name
        parentKind = gdkBenchmark
        continue
    else:
      if parentKind == gdkTest:
        let subName = firstQuotedAfter(rawLine, ".Run")
        if subName.len > 0:
          result.add GoTestDecl(kind: gdkSubtest, name: subName,
              selector: parent & "/" & subName, parentSelector: parent,
              line: lineNo, column: max(1, rawLine.find(".Run") + 2),
              endColumn: max(1, rawLine.find(".Run") + 5 + subName.len))
      funcDepth += braceDelta(rawLine)
      if funcDepth <= 0:
        inFunc = false
        parent = ""

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
    canRecordSingle: false,
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: false)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: GoTestProviderId,
    language: "go",
    framework: GoTestFramework,
    displayName: "Go test",
    version: GoTestVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(info: TestProviderInfo; projectRoot, filePath: string;
    decl: GoTestDecl; idsBySelector: Table[string, string]): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  var tags = @["go", "go-test"]
  case decl.kind
  of gdkTest:
    tags.add "test"
  of gdkBenchmark:
    tags.add "benchmark"
  of gdkSubtest:
    tags.add "subtest"
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        decl.selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: if decl.kind == gdkSubtest: tikParameterizedCase else: tikCase,
    file: relative,
    range: SourceRange(startLine: decl.line, startColumn: decl.column,
        endLine: decl.line, endColumn: decl.endColumn),
    selector: decl.selector,
    parentId: idsBySelector.getOrDefault(decl.parentSelector, ""),
    tags: tags,
    location: LocationProvenance(source: lskParser,
        detail: "M11 lightweight Go parser for TestX, BenchmarkX, " &
          "and simple t.Run string subtests",
        confidence: if decl.kind == gdkSubtest: lcMedium else: lcHigh),
    stale: false,
    staleReason: "")

proc goFileCatalog*(projectRoot, filePath: string): ProviderResult[
    TestCatalog] =
  let info = providerInfo()
  if not isGoTestFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Go _test.go source file",
          filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))
  var
    items: seq[TestItem] = @[]
    idsBySelector = initTable[string, string]()
  for decl in parseGoTestDeclarations(readFile(filePath)):
    let item = itemFromDecl(info, projectRoot, filePath, decl, idsBySelector)
    idsBySelector[item.selector] = item.id
    items.add item
  ProviderResult[TestCatalog](diagnostics: @[],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: items, diagnostics: @[]))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in goFiles(projectRoot):
    let fileResult = goFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc regexEscape(value: string): string =
  for ch in value:
    if ch in {'\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}',
        '^', '$'}:
      result.add '\\'
    result.add ch

proc goRunPattern*(selector: string): string =
  selector.split('/').mapIt("^" & regexEscape(it) & "$").join("/")

proc buildGoCommand*(projectRoot, filePath, selector: string;
    scope: GoCommandScope): seq[string] =
  result = @["go", "test"]
  case scope
  of gcsProject:
    result.add "./..."
  of gcsFile:
    result.add "."
  of gcsSingle:
    result.add "."
    if selector.startsWith("Benchmark"):
      result.add @["-run", "^$", "-bench", goRunPattern(selector)]
    else:
      result.add @["-run", goRunPattern(selector), "-v"]

proc runGo(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  let commandScope =
    case scope.kind
    of tskProject: gcsProject
    of tskFile: gcsFile
    of tskSingle: gcsSingle
  runCommand(GoTestProviderId, scope, buildGoCommand(scope.projectRoot,
      scope.file, scope.selector, commandScope), @GoNixPackages)

proc recordGoUnsupported(scope: TestScope): ProviderResult[seq[
    TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning,
        "Go test recording is not enabled in M11 because go test " &
        "compiles an ephemeral test binary; run support and precise " &
        "selectors are available",
        scope.file)],
    value: @[])

proc newGoTestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    ProviderResult[bool](diagnostics: @[], value: hasGoProject(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    goFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[
      TestItem]] {.gcsafe.} =
    let catalog = goFileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = runGo
  provider.record = recordGoUnsupported
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseProviderEventLine(GoTestProviderId, raw)
  provider.mapTraceEntryPoints = proc(catalog: TestCatalog; traces: seq[
      TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
    ProviderResult[Table[string, TraceMetadata]](
      diagnostics: @[diagnostic(dsWarning,
          "Go test trace entry-point mapping is unavailable until " &
          "recording is enabled")],
      value: initTable[string, TraceMetadata]())
  M1Provider(provider: provider, relevantConfigFiles: @["go.mod", "go.sum"])

proc newGoTestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newGoTestM1Provider()])
