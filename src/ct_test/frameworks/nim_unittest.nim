## OUTSTANDING VERIFICATION OBLIGATION (recorded 2026-08-14, PR #622)
##
## The lexical-scanner rewrite in this provider was merged on the evidence of
## `ct-test-release-gate` alone, which passed (16m49s, run 31706159237). The
## other gate that exercises this code, `ct-test-providers` (the "ct-test
## cross-language provider gate"), was NOT green: it failed in 2m48s in the same
## run, in `Setup dev env`, as part of the workspace-lock outage that PR #623
## fixed. It therefore never reached this provider and says nothing about it
## either way.
##
## So: this provider has no green `ct-test-providers` run behind it.
## `ct-test-providers` MUST be observed green before the next change that
## touches this file or `../nim_lexer`. Do not treat a passing
## `ct-test-release-gate` as covering it -- the two gates have deliberately
## different prerequisites (see the block comment above `ct-test-release-gate`
## in `.github/workflows/codetracer.yml`), and only the providers gate drives
## the real recorder siblings.
##
## Delete this note once such a run exists, and cite it.

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

proc continuesClause(token: NimToken): bool =
  ## May an import clause carry on past a line break that follows ``token``?
  ##
  ## Nim's line-continuation rule for these statements in practice: the clause
  ## goes on when the line ended on the separator between modules or on one of
  ## the operators that cannot end a module name.  See the grammar's
  ## ``importStmt``/``includeStmt`` productions in
  ## https://nim-lang.org/docs/manual.html#modules — an open bracket also
  ## continues the clause, and that case is handled by the bracket depth in
  ## ``importClauseEnd`` rather than here.
  token.kind == ntkPunct and token.ch in {',', '/', '.'}

proc importClauseEnd(tokens: seq[NimToken]; start: int): int =
  ## Index one past the last token of the import clause whose module list
  ## begins at ``start``.
  ##
  ## THE STATEMENT, NOT THE LINE, IS THE UNIT.  An ``import`` clause routinely
  ## spans two lines — ``import std/[os, strutils,`` / ``            unittest]``
  ## is the house style once the list outgrows a line — and a scan that reads
  ## one physical line and calls it the statement simply does not see the
  ## continuation.  When the module it cannot see is ``unittest``, the file is
  ## not merely mis-imported: no framework is detected, so the file is never
  ## scanned for declarations at all and drops out of the catalog entirely.
  ##
  ## So the clause ends at the first line break that is not held open by an
  ## unclosed bracket and not invited by a trailing separator, or at a ``;``
  ## statement separator, whichever comes first.
  var
    index = start
    depth = 0
    previous = -1
  while index < tokens.len:
    let token = tokens[index]
    # Comments carry no syntax: they may sit anywhere inside the clause
    # (``import std/[os, # why not\n  unittest]``) without ending or
    # continuing it, so they are neither a break candidate nor a `previous`.
    if token.kind == ntkComment:
      inc index
      continue
    if previous >= 0 and token.line > tokens[previous].endLine and
        depth == 0 and not tokens[previous].continuesClause:
      break
    if token.kind == ntkPunct:
      case token.ch
      of '[', '(', '{':
        inc depth
      of ']', ')', '}':
        if depth > 0:
          dec depth
      of ';':
        # ``import os; import unittest`` — two statements on one line.
        if depth == 0:
          break
      else:
        discard
    previous = index
    inc index
  max(start, previous + 1)

type
  NimImportClause* = object
    ## One ``import`` / ``from … import`` / ``include`` statement, as read by
    ## ``scanNimImportClauses``.
    keyword*: string            ## "import", "from" or "include"
    modules*: seq[string]       ## module names, ``std/[a, b]`` already expanded
    line*: int                  ## 1-based line the keyword sits on

proc scanNimImportClauses*(content: string;
    tokens: seq[NimToken]): seq[NimImportClause] =
  ## Every module this source names in an import-like statement.
  ##
  ## Driven by the token stream rather than by lines, which is what makes the
  ## scan see a clause that spans lines (``importClauseEnd``), an ``import``
  ## that is not the first thing on its line (``when defined(x): import …``),
  ## and two clauses separated by ``;``.  It equally makes an ``import`` that
  ## is only *mentioned* — in a comment, or inside a string literal holding
  ## sample source — a non-event, because those are tokens of their own kind.
  ##
  ## The module list itself is still read out of the source text, over
  ## ``maskNimNonCode`` so that a comment inside the clause contributes
  ## nothing; the clause's extent is what the tokens decide.
  ##
  ## Takes the token stream rather than scanning for itself so a caller that
  ## also needs the declarations pays for exactly one scan of the file.
  let masked = maskNimNonCode(content, tokens)
  var index = 0
  while index < tokens.len:
    let token = tokens[index]
    if token.kind != ntkIdent:
      inc index
      continue
    let keyword =
      if content.identIs(token, "import"): "import"
      elif content.identIs(token, "from"): "from"
      elif content.identIs(token, "include"): "include"
      else: ""
    if keyword.len == 0:
      inc index
      continue
    # ``import`` is a keyword, so an identifier spelled that way can only be a
    # backtick-quoted one (a field or routine deliberately named after the
    # keyword). That is not a statement, and reading a module list out of what
    # follows it would be reading someone else's expression.
    if index > 0 and tokens[index - 1].kind == ntkPunct and
        tokens[index - 1].ch == '`':
      inc index
      continue

    let stop = importClauseEnd(tokens, index + 1)
    if stop <= index + 1:
      inc index
      continue
    let
      clauseStart = min(token.endOffset, masked.len)
      clauseEnd = min(tokens[stop - 1].endOffset, masked.len)
    var clause = NimImportClause(keyword: keyword, line: token.line)
    if clauseStart < clauseEnd:
      let text = masked[clauseStart ..< clauseEnd]
      if keyword == "from":
        # ``from <module> import <symbols>``: only the module is a dependency
        # of this file on another module; the symbol list names its contents.
        clause.modules.add text.split("import", maxsplit = 1)[0].strip
      else:
        for part in splitTopLevelImports(text):
          for candidate in importCandidates(part):
            clause.modules.add candidate
    result.add clause
    index = stop

proc detectFrameworksInClauses*(clauses: seq[NimImportClause]):
    seq[NimUnitFramework] =
  ## Which unittest flavours do these clauses import?
  ##
  ## ``include`` is deliberately not a detection: the included file's own
  ## imports are what would matter, and resolving an include path is a
  ## different (and much larger) job than reading one file's text.  A file that
  ## reaches ``unittest`` only through an ``include`` is therefore still
  ## undetected — but ``nimUnittestFileCatalog`` reports the include in the
  ## diagnostic, so the conclusion carries the evidence it was drawn from.
  var seen = initTable[NimUnitFramework, bool]()
  for clause in clauses:
    if clause.keyword == "include":
      continue
    for module in clause.modules:
      let maybeFramework = frameworkForImport(module)
      if maybeFramework.isSome:
        seen[maybeFramework.get] = true

  for framework in NimUnitFramework:
    if seen.getOrDefault(framework, false):
      result.add framework

proc detectFrameworksInTokens*(content: string;
    tokens: seq[NimToken]): seq[NimUnitFramework] =
  ## Which unittest flavours does this source import?
  detectFrameworksInClauses(scanNimImportClauses(content, tokens))

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

const MaxReportedModules = 12
  ## How many module names the "no unittest import" diagnostic spells out
  ## before summarising the rest. Enough to recognise a file at a glance
  ## without turning one info line into a screenful.

proc noFrameworkMessage*(clauses: seq[NimImportClause]): string =
  ## The message for "this file imports no unittest flavour I know".
  ##
  ## It states what the scan READ, not just what it concluded, and that is the
  ## whole point.  The bare conclusion — "no Nim unittest imports detected in
  ## file" — is emitted identically whether the file genuinely imports no test
  ## framework or whether the scan failed to read the import that is right
  ## there in the source.  Those two are opposite facts, and a diagnostic that
  ## renders them the same way is why a scan defect that dropped whole files
  ## out of the catalog could sit in a workspace report, dozens of rows deep,
  ## looking exactly like the rows that were correct.
  ##
  ## With the module list attached, the reader can check the claim against the
  ## file: an import the scan missed is an import missing from this list.
  var
    imported: seq[string] = @[]
    included: seq[string] = @[]
  for clause in clauses:
    for module in clause.modules:
      if module.len == 0:
        continue
      if clause.keyword == "include":
        included.add module
      else:
        imported.add module

  proc summarise(modules: seq[string]): string =
    if modules.len <= MaxReportedModules:
      modules.join(", ")
    else:
      modules[0 ..< MaxReportedModules].join(", ") &
        " and " & $(modules.len - MaxReportedModules) & " more"

  if imported.len == 0:
    result = "no imports were read from this file at all, so no Nim unittest " &
      "framework could be detected"
  else:
    result = "no Nim unittest imports detected in file; the " & $imported.len &
      " module(s) it imports are " & summarise(imported)
  if included.len > 0:
    # The one blind spot left once the clause scan is statement-oriented:
    # whatever the included file imports is invisible from here.
    result.add ". It also has " & $included.len & " `include` clause(s) (" &
      summarise(included) & ") whose own imports this scan does not follow"

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
  # Read the import clauses once: the framework answer and the diagnostic that
  # explains a negative answer are two readings of the same evidence.
  let clauses = scanNimImportClauses(content, tokens)
  let frameworks = detectFrameworksInClauses(clauses)
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
      noFrameworkMessage(clauses),
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
