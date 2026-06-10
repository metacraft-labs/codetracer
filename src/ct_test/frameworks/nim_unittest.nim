import std/[algorithm, options, os, sequtils, strutils, tables]

import ../contracts
import ../discovery

const
  NimUnittestProviderId* = "nim-unittest"
  NimUnittestFramework* = "std/unittest"
  NimUnittestVersion* = "m2"

type
  NimUnitFramework* = enum
    nufStdUnittest
    nufUnittest2
    nufUnittestParallel

  NimUnitDeclarationKind = enum
    nudSuite
    nudTest

  NimUnitDeclaration = object
    kind: NimUnitDeclarationKind
    name: string
    line: int
    column: int
    endColumn: int
    indent: int
    selector: string
    parentSelector: string

  ScanState = object
    source: string
    pos: int
    line: int
    column: int

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
    id: NimUnittestProviderId,
    language: "nim",
    framework: NimUnittestFramework,
    displayName: "Nim std/unittest",
    version: NimUnittestVersion,
    capabilities: providerCapabilities())

proc normalizedRelative(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc normalizeImportName(raw: string): string =
  raw.strip(chars = {' ', '\t', '\r', '\n', '"', '\'', '`', ','})

proc frameworkForImport(raw: string): Option[NimUnitFramework] =
  let name = normalizeImportName(raw)
  case name
  of "unittest", "std/unittest":
    some(nufStdUnittest)
  of "unittest2":
    some(nufUnittest2)
  of "unittest_parallel":
    some(nufUnittestParallel)
  else:
    none(NimUnitFramework)

proc importCandidates(raw: string): seq[string] =
  let item = raw.strip
  if item.startsWith("std/[") and item.endsWith("]"):
    let inner = item["std/[".len ..< item.len - 1]
    for part in inner.split(','):
      result.add "std/" & part.strip
  else:
    result.add item

proc splitTopLevelImports(raw: string): seq[string] =
  var
    start = 0
    bracketDepth = 0
  for i, ch in raw:
    case ch
    of '[':
      inc bracketDepth
    of ']':
      if bracketDepth > 0:
        dec bracketDepth
    of ',':
      if bracketDepth == 0:
        result.add raw[start ..< i].strip
        start = i + 1
    else:
      discard
  result.add raw[start .. ^1].strip

proc stripLineComment(line: string): string =
  var
    i = 0
    inString = false
    quote = '\0'
    triple = false
  while i < line.len:
    let ch = line[i]
    if inString:
      if triple:
        if i + 2 < line.len and line[i] == quote and line[i + 1] == quote and line[i + 2] == quote:
          i += 3
          inString = false
          triple = false
          continue
      elif ch == '\\':
        i += 2
        continue
      elif ch == quote:
        inString = false
      inc i
      continue
    if ch == '#':
      return line[0 ..< i]
    if ch in {'"', '\''}:
      inString = true
      quote = ch
      triple = i + 2 < line.len and line[i + 1] == ch and line[i + 2] == ch
      if triple:
        i += 3
      else:
        inc i
      continue
    inc i
  line

proc detectFrameworksInContent*(content: string): seq[NimUnitFramework] =
  var seen = initTable[NimUnitFramework, bool]()
  for rawLine in content.splitLines:
    let line = stripLineComment(rawLine).strip
    if line.len == 0:
      continue
    if line.startsWith("import "):
      for part in splitTopLevelImports(line["import ".len .. ^1]):
        for candidate in importCandidates(part):
          let maybeFramework = frameworkForImport(candidate)
          if maybeFramework.isSome:
            seen[maybeFramework.get] = true
    elif line.startsWith("from "):
      let tail = line["from ".len .. ^1]
      let moduleName = tail.split("import", maxsplit = 1)[0]
      let maybeFramework = frameworkForImport(moduleName)
      if maybeFramework.isSome:
        seen[maybeFramework.get] = true

  for framework in NimUnitFramework:
    if seen.getOrDefault(framework, false):
      result.add framework

proc frameworkName(framework: NimUnitFramework): string =
  case framework
  of nufStdUnittest: "std/unittest"
  of nufUnittest2: "unittest2"
  of nufUnittestParallel: "unittest_parallel"

proc isIdentStart(ch: char): bool =
  ch in {'A' .. 'Z', 'a' .. 'z', '_'}

proc isIdentChar(ch: char): bool =
  ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}

proc initScanState(source: string): ScanState =
  ScanState(source: source, pos: 0, line: 1, column: 1)

proc current(state: ScanState): char =
  if state.pos < state.source.len:
    state.source[state.pos]
  else:
    '\0'

proc advance(state: var ScanState) =
  if state.pos >= state.source.len:
    return
  if state.source[state.pos] == '\n':
    inc state.line
    state.column = 1
  else:
    inc state.column
  inc state.pos

proc skipLineComment(state: var ScanState) =
  while state.pos < state.source.len and state.current != '\n':
    state.advance()

proc skipBlockComment(state: var ScanState) =
  var depth = 0
  while state.pos < state.source.len:
    if state.pos + 1 < state.source.len and
        state.source[state.pos] == '#' and
        state.source[state.pos + 1] == '[':
      inc depth
      state.advance()
      state.advance()
    elif state.pos + 1 < state.source.len and
        state.source[state.pos] == ']' and
        state.source[state.pos + 1] == '#':
      state.advance()
      state.advance()
      dec depth
      if depth == 0:
        break
    else:
      state.advance()

proc skipString(state: var ScanState) =
  let quote = state.current
  var triple = false
  if state.pos + 2 < state.source.len and
      state.source[state.pos + 1] == quote and
      state.source[state.pos + 2] == quote:
    triple = true
    state.advance()
    state.advance()
    state.advance()
  else:
    state.advance()

  while state.pos < state.source.len:
    if triple:
      if state.pos + 2 < state.source.len and
          state.source[state.pos] == quote and
          state.source[state.pos + 1] == quote and
          state.source[state.pos + 2] == quote:
        state.advance()
        state.advance()
        state.advance()
        break
      state.advance()
    else:
      if state.current == '\\':
        state.advance()
        state.advance()
      elif state.current == quote:
        state.advance()
        break
      else:
        state.advance()

proc skipWhitespace(state: var ScanState) =
  while state.current in {' ', '\t', '\r', '\n'}:
    state.advance()

proc readIdentifier(state: var ScanState): string =
  let start = state.pos
  while isIdentChar(state.current):
    state.advance()
  state.source[start ..< state.pos]

proc parseStringLiteral(state: var ScanState): Option[tuple[value: string, endColumn: int]] =
  if state.current notin {'"', '\''}:
    return none(tuple[value: string, endColumn: int])
  let quote = state.current
  var
    value = ""
    triple = false
  if state.pos + 2 < state.source.len and
      state.source[state.pos + 1] == quote and
      state.source[state.pos + 2] == quote:
    triple = true
    state.advance()
    state.advance()
    state.advance()
  else:
    state.advance()

  while state.pos < state.source.len:
    if triple:
      if state.pos + 2 < state.source.len and
          state.source[state.pos] == quote and
          state.source[state.pos + 1] == quote and
          state.source[state.pos + 2] == quote:
        state.advance()
        state.advance()
        state.advance()
        return some((value, max(1, state.column - 1)))
      value.add state.current
      state.advance()
    else:
      if state.current == '\\':
        state.advance()
        if state.pos < state.source.len:
          value.add state.current
          state.advance()
      elif state.current == quote:
        state.advance()
        return some((value, max(1, state.column - 1)))
      elif state.current == '\n':
        return none(tuple[value: string, endColumn: int])
      else:
        value.add state.current
        state.advance()

  none(tuple[value: string, endColumn: int])

proc suiteSelector(path: seq[string]): string =
  path.join("::") & "::"

proc testSelector(path: seq[string]; name: string): string =
  if path.len == 0:
    "::" & name
  else:
    path.join("::") & "::" & name

proc parseNimUnittestDeclarations*(content: string): ProviderResult[seq[NimUnitDeclaration]] =
  var
    state = initScanState(content)
    suiteStack: seq[NimUnitDeclaration] = @[]
    diagnostics: seq[TestDiagnostic] = @[]
    declarations: seq[NimUnitDeclaration] = @[]

  while state.pos < state.source.len:
    let ch = state.current
    if ch == '#':
      if state.pos + 1 < state.source.len and state.source[state.pos + 1] == '[':
        state.skipBlockComment()
      else:
        state.skipLineComment()
      continue
    if ch in {'"', '\''}:
      state.skipString()
      continue
    if isIdentStart(ch):
      let
        tokenLine = state.line
        tokenColumn = state.column
        tokenIndent = tokenColumn - 1
        ident = state.readIdentifier()
      if ident in ["suite", "test"]:
        var lookahead = state
        lookahead.skipWhitespace()
        if lookahead.current == '(':
          lookahead.advance()
          lookahead.skipWhitespace()
        let parsed = lookahead.parseStringLiteral()
        if parsed.isSome:
          while suiteStack.len > 0 and suiteStack[^1].indent >= tokenIndent:
            discard suiteStack.pop()
          let name = parsed.get.value
          let kind =
            if ident == "suite": nudSuite else: nudTest
          var suitePath = suiteStack.mapIt(it.name)
          let selector =
            if kind == nudSuite:
              suiteSelector(suitePath & @[name])
            else:
              testSelector(suitePath, name)
          let parentSelector =
            if suiteStack.len == 0:
              ""
            else:
              suiteStack[^1].selector
          let declaration = NimUnitDeclaration(
            kind: kind,
            name: name,
            line: tokenLine,
            column: tokenColumn,
            endColumn: parsed.get.endColumn,
            indent: tokenIndent,
            selector: selector,
            parentSelector: parentSelector)
          declarations.add declaration
          if kind == nudSuite:
            suiteStack.add declaration
          state = lookahead
          continue
    state.advance()

  ProviderResult[seq[NimUnitDeclaration]](diagnostics: diagnostics, value: declarations)

proc itemKind(kind: NimUnitDeclarationKind): TestItemKind =
  case kind
  of nudSuite: tikSuite
  of nudTest: tikCase

proc itemFromDeclaration(
    info: TestProviderInfo;
    projectRoot, filePath: string;
    declaration: NimUnitDeclaration;
    idsBySelector: Table[string, string]): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  let parentId =
    if declaration.parentSelector.len > 0:
      idsBySelector.getOrDefault(declaration.parentSelector, "")
    else:
      ""
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative, declaration.selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: declaration.name,
    kind: itemKind(declaration.kind),
    file: relative,
    range: SourceRange(
      startLine: declaration.line,
      startColumn: declaration.column,
      endLine: declaration.line,
      endColumn: declaration.endColumn),
    selector: declaration.selector,
    parentId: parentId,
    tags: @["nim", "std-unittest"],
    location: LocationProvenance(
      source: lskParser,
      detail: "M2 lightweight Nim unittest lexical scanner",
      confidence: lcMedium),
    stale: false,
    staleReason: "")

proc unsupportedDiagnostics(filePath: string; frameworks: seq[NimUnitFramework]): seq[TestDiagnostic] =
  for framework in frameworks:
    case framework
    of nufStdUnittest:
      discard
    of nufUnittest2, nufUnittestParallel:
      result.add diagnostic(
        dsWarning,
        "Nim " & framework.frameworkName & " discovery is detected but not implemented in M2; only std/unittest is parsed",
        filePath)

proc nimUnittestFileCatalog*(projectRoot, filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  if not filePath.endsWith(".nim"):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Nim source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info, items: @[], diagnostics: @[]))

  let content = readFile(filePath)
  let frameworks = detectFrameworksInContent(content)
  var catalogDiagnostics = unsupportedDiagnostics(filePath, frameworks)
  var items: seq[TestItem] = @[]

  if nufStdUnittest in frameworks:
    let parsed = parseNimUnittestDeclarations(content)
    catalogDiagnostics.add parsed.diagnostics
    var idsBySelector = initTable[string, string]()
    for declaration in parsed.value:
      let item = itemFromDeclaration(info, projectRoot, filePath, declaration, idsBySelector)
      idsBySelector[declaration.selector] = item.id
      items.add item
    if items.len == 0:
      catalogDiagnostics.add diagnostic(
        dsWarning,
        "std/unittest import detected but no literal suite/test declarations were found",
        filePath)
  elif frameworks.len == 0:
    catalogDiagnostics.add diagnostic(
      dsInfo,
      "no Nim unittest imports detected in file",
      filePath)

  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(
      schemaVersion: TestCatalogSchemaVersion,
      provider: info,
      items: items,
      diagnostics: catalogDiagnostics))

proc isCandidateNimTestFile(path: string): bool =
  if not path.endsWith(".nim") or not fileExists(path):
    return false
  let normalized = path.replace("\\", "/")
  let filename = splitFile(path).name.toLowerAscii
  normalized.contains("/tests/") or filename.startsWith("test") or filename.endsWith("_test")

proc nimProjectFiles(projectRoot: string): seq[string] =
  for path in walkDirRec(projectRoot):
    if isCandidateNimTestFile(path):
      result.add path
  result.sort(system.cmp[string])

proc detectProject(projectRoot: string): ProviderResult[bool] =
  if not dirExists(projectRoot):
    return ProviderResult[bool](diagnostics: @[], value: false)
  for marker in [".nimble", "nim.cfg", "config.nims"]:
    if fileExists(projectRoot / marker):
      return ProviderResult[bool](diagnostics: @[], value: true)
  for kind, path in walkDir(projectRoot):
    if kind == pcFile and path.endsWith(".nimble"):
      return ProviderResult[bool](diagnostics: @[], value: true)
  for path in walkDirRec(projectRoot):
    if path.endsWith(".nim"):
      let frameworks = detectFrameworksInContent(readFile(path))
      if frameworks.len > 0:
        return ProviderResult[bool](diagnostics: @[], value: true)
  ProviderResult[bool](diagnostics: @[], value: false)

proc discoverFileImpl(projectRoot, filePath: string): ProviderResult[TestCatalog] =
  nimUnittestFileCatalog(projectRoot, filePath)

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: info,
    items: @[],
    diagnostics: @[])
  for path in nimProjectFiles(projectRoot):
    let fileResult = nimUnittestFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc locateTestsImpl(projectRoot, filePath: string): ProviderResult[seq[TestItem]] =
  let catalogResult = nimUnittestFileCatalog(projectRoot, filePath)
  ProviderResult[seq[TestItem]](
    diagnostics: catalogResult.value.diagnostics,
    value: catalogResult.value.items)

proc notImplementedEvents(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, "Nim unittest run/record is not implemented in M2", scope.file)],
    value: @[])

proc parseEventUnsupported(raw: string): ProviderResult[TestEvent] {.gcsafe.} =
  ProviderResult[TestEvent](
    diagnostics: @[diagnostic(dsWarning, "Nim unittest event parsing is not implemented in M2")],
    value: TestEvent(schemaVersion: TestEventSchemaVersion, providerId: NimUnittestProviderId))

proc mapTraceUnsupported(
    catalog: TestCatalog;
    traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
  ProviderResult[Table[string, TraceMetadata]](
    diagnostics: @[diagnostic(dsWarning, "Nim unittest trace entry-point mapping is not implemented in M2")],
    value: initTable[string, TraceMetadata]())

proc newNimUnittestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    detectProject(projectRoot)
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[TestCatalog] {.gcsafe.} =
    discoverFileImpl(projectRoot, file)
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
    relevantConfigFiles: @["nim.cfg", "config.nims"])

proc newNimUnittestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newNimUnittestM1Provider()])
