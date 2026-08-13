import std/[algorithm, options, os, sequtils, strutils, tables]

import ../contracts
import ../discovery
import ../nim_lexer

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

proc detectFrameworksInTokens*(content: string;
    tokens: seq[NimToken]): seq[NimUnitFramework] =
  ## Which unittest flavours does this source import?
  ##
  ## The scan is line-oriented (an ``import`` clause is a statement, and the
  ## overwhelmingly common form is a single line), but it runs over
  ## ``maskNimNonCode`` rather than the raw text.  That is what keeps a ``#``
  ## or a quote inside a literal from being read as code — the hand-rolled
  ## per-line comment stripper this replaced shared the apostrophe bug that
  ## used to break declaration scanning, and duplicated its logic besides.
  ##
  ## Takes the token stream rather than scanning for itself so a caller that
  ## also needs the declarations pays for exactly one scan of the file.
  var seen = initTable[NimUnitFramework, bool]()
  for rawLine in maskNimNonCode(content, tokens).splitLines:
    let line = rawLine.strip
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

proc detectFrameworksInContent*(content: string): seq[NimUnitFramework] =
  ## Convenience wrapper for callers that only need the framework answer
  ## (``detectProject``'s last-resort probe, and the tests).
  detectFrameworksInTokens(content, scanNimSource(content))

proc frameworkName(framework: NimUnitFramework): string =
  case framework
  of nufStdUnittest: "std/unittest"
  of nufUnittest2: "unittest2"
  of nufUnittestParallel: "unittest_parallel"

proc suiteSelector(path: seq[string]): string =
  path.join("::") & "::"

proc testSelector(path: seq[string]; name: string): string =
  if path.len == 0:
    "::" & name
  else:
    path.join("::") & "::" & name

proc parseNimUnittestDeclarations(content: string; tokens: seq[NimToken];
    filePath = ""): ProviderResult[seq[NimUnitDeclaration]] =
  ## Find every literal ``suite "…":`` / ``test "…":`` declaration.
  ##
  ## Runs over the shared Nim token stream (``ct_test/nim_lexer``) rather than
  ## a bespoke character loop.  That is what makes the scan robust against the
  ## constructs that can *contain* a quote or a ``#``: numeric type suffixes
  ## (``0'u8``), character literals, raw and generalized-raw strings, nested
  ## block comments.  Previously an apostrophe in ``10485760'i64`` opened a
  ## phantom character literal and everything up to the next apostrophe —
  ## typically hundreds of lines, including every declaration in between — was
  ## skipped as if it were string content.
  ##
  ## Structure is still recovered from *column* alone: ``unittest``'s
  ## ``suite``/``test`` are templates taking an indented block, so a
  ## declaration belongs to the innermost enclosing suite that starts at a
  ## smaller column.  A lexer cannot know more than that, and the
  ## ``LocationProvenance`` attached to each item says so.
  ##
  ## The one *semantic* rule applied on top is ``when false:``.  It is the
  ## idiomatic way to disable a block of Nim source without deleting it; the
  ## compiler never instantiates the body, so those tests do not exist for any
  ## runner.  Reporting them would be the mirror of the bug above — discovery
  ## claiming cases the runner will never produce — so the block is skipped and
  ## the skip is reported as an ``info`` diagnostic rather than hidden.
  var
    suiteStack: seq[NimUnitDeclaration] = @[]
    diagnostics: seq[TestDiagnostic] = @[]
    declarations: seq[NimUnitDeclaration] = @[]
    index = 0
    # Column of the innermost active ``when false:``; 0 when none is active.
    # A single value suffices: a nested ``when false:`` is already covered by
    # the outer one, and the block ends at the first token that dedents to or
    # past the ``when``.
    disabledColumn = 0
    disabledDeclarations = 0

  proc nextCode(start: int): int =
    ## Index of the next non-comment token at or after ``start``.  Comments may
    ## legally sit between the keyword and its name (``test # why\n  "x":``).
    result = start
    while result < tokens.len and tokens[result].kind == ntkComment:
      inc result

  proc isName(token: NimToken): bool =
    ## Only a *terminated* string literal names a declaration; an unterminated
    ## one means the file is mid-edit or malformed, and inventing a test case
    ## from it would be a false positive.
    token.kind == ntkString and token.terminated

  while index < tokens.len:
    let token = tokens[index]
    var
      keyword = ""
      name = ""
      endColumn = 0
      lastIndex = index

    if token.kind != ntkComment:
      # Leaving the disabled block: the first token that is not indented past
      # the ``when`` re-enables discovery. Comments carry no indentation
      # meaning, so they never close the block.
      if disabledColumn > 0 and token.column <= disabledColumn:
        disabledColumn = 0
      if disabledColumn == 0 and content.identIs(token, "when"):
        let falseIndex = nextCode(index + 1)
        if falseIndex < tokens.len and
            content.identIs(tokens[falseIndex], "false"):
          let colonIndex = nextCode(falseIndex + 1)
          if colonIndex < tokens.len and
              tokens[colonIndex].kind == ntkPunct and
              tokens[colonIndex].ch == ':':
            disabledColumn = token.column
            index = colonIndex + 1
            continue

    let keywordToken =
      if content.identIs(token, "suite"): "suite"
      elif content.identIs(token, "test"): "test"
      else: ""

    if keywordToken.len > 0:
      # ``suite "name":`` and the parenthesised call form ``suite("name"):``.
      var nameIndex = nextCode(index + 1)
      if nameIndex < tokens.len and tokens[nameIndex].kind == ntkPunct and
          tokens[nameIndex].ch == '(':
        nameIndex = nextCode(nameIndex + 1)
      if nameIndex < tokens.len and tokens[nameIndex].isName:
        keyword = keywordToken
        name = tokens[nameIndex].value
        endColumn = tokens[nameIndex].endColumn
        lastIndex = nameIndex
    elif token.kind == ntkString and token.prefix in ["suite", "test"] and
        token.terminated:
      # ``test"name":`` — an identifier glued to a string literal is Nim's
      # generalized raw string literal syntax, which still calls the template.
      keyword = token.prefix
      name = token.value
      endColumn = token.endColumn

    if keyword.len > 0 and disabledColumn > 0:
      inc disabledDeclarations
      index = lastIndex + 1
      continue

    if keyword.len > 0:
      let tokenIndent = token.column - 1
      while suiteStack.len > 0 and suiteStack[^1].indent >= tokenIndent:
        discard suiteStack.pop()
      let kind = if keyword == "suite": nudSuite else: nudTest
      let suitePath = suiteStack.mapIt(it.name)
      let selector =
        if kind == nudSuite:
          suiteSelector(suitePath & @[name])
        else:
          testSelector(suitePath, name)
      let parentSelector =
        if suiteStack.len == 0: ""
        else: suiteStack[^1].selector
      let declaration = NimUnitDeclaration(
        kind: kind,
        name: name,
        line: token.line,
        column: token.column,
        endColumn: endColumn,
        indent: tokenIndent,
        selector: selector,
        parentSelector: parentSelector)
      declarations.add declaration
      if kind == nudSuite:
        suiteStack.add declaration
      index = lastIndex + 1
      continue

    inc index

  if disabledDeclarations > 0:
    diagnostics.add diagnostic(
      dsInfo,
      $disabledDeclarations & " suite/test declaration(s) skipped: they are " &
      "inside a `when false:` block and are never compiled",
      filePath)

  ProviderResult[seq[NimUnitDeclaration]](diagnostics: diagnostics, value: declarations)

proc parseNimUnittestDeclarations*(content: string; filePath = ""):
    ProviderResult[seq[NimUnitDeclaration]] =
  ## Convenience wrapper for callers that have source text but no tokens.
  parseNimUnittestDeclarations(content, scanNimSource(content), filePath)

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
  # Tokenize ONCE and hand the same stream to both consumers: this runs over
  # every candidate file in a workspace, and a second scan per file is a
  # second pass over every byte of the project's source for no new information.
  let tokens = scanNimSource(content)
  let frameworks = detectFrameworksInTokens(content, tokens)
  var catalogDiagnostics = unsupportedDiagnostics(filePath, frameworks)
  var items: seq[TestItem] = @[]

  if nufStdUnittest in frameworks:
    let parsed = parseNimUnittestDeclarations(content, tokens, filePath)
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
  for path in walkWorkspaceFiles(projectRoot):
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
  # Last resort for a Nim workspace with no project marker at all: look for a
  # unittest import in the sources themselves. This reads file contents, so it
  # is the single most expensive probe in the registry — restricting it to the
  # workspace's own files (rather than every ``.nim`` reachable from the root,
  # vendored compiler checkouts included) is what keeps it affordable.
  #
  # A source file that cannot be read is not evidence either way; skipping it
  # beats letting an ``IOError`` abort the whole discovery.
  for path in walkWorkspaceFiles(projectRoot):
    if path.endsWith(".nim"):
      var content = ""
      try:
        content = readFile(path)
      except IOError, OSError:
        continue
      let frameworks = detectFrameworksInContent(content)
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
