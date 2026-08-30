## Noir provider for `ct test`, driving `nargo test`.
##
## WHY `nargo`, AND NOT THE TRACER WASM MODULES
## --------------------------------------------
## Every non-M13 provider in this framework wraps the language's OWN test
## runner and its own test-declaration syntax — `cargo test` + `#[test]`,
## `go test` + `func TestX`, `pytest`, `node --test`. The M13 recorder
## harnesses (`smart_contract_common`) exist for the opposite case: an
## ecosystem with no native test runner at all, where the only executable
## surface is "hand this fixture file to a recorder CLI and see whether a
## `.ct` artifact falls out". Noir is emphatically in the first group: it has
## `#[test]`, `#[test(should_fail)]`, `#[test(should_fail_with = "…")]`, and a
## `nargo test` that already speaks a JSON Lines event stream. Driving the
## tracer wasm modules instead would answer a different question — *can
## CodeTracer trace Noir?* — and would answer nothing about *which tests does
## this workspace have, and how do I run one?*, which is the question a
## provider exists to answer.
##
## The tracer wasm modules belong to the `record` capability, and this provider
## deliberately does NOT claim it. See `recordUnsupported` below for the trap
## that has to be closed before it can be claimed honestly.
##
## WHAT NOIR GIVES US THAT MOST PROVIDERS DO NOT
## ---------------------------------------------
## `nargo test --format json` emits one JSON object per line
## (`tooling/nargo_cli/src/cli/test_cmd/formatters.rs`, `JsonFormatter`), so
## this provider reports REAL per-test statuses and per-test output rather than
## mapping one process exit code onto every test in the run — which is all
## `native_m11_common.runCommand` can do, and all the Go/D/Crystal providers
## get. That is why `emitsStructuredEvents` and `canCapturePerTestOutput` are
## true here and false almost everywhere else.

import std/[algorithm, json, options, os, sequtils, strutils, tables, times]

import ../contracts
import ../discovery
import ../process_exec
import native_m11_common

const
  NoirNargoProviderId* = "noir-nargo"
  NoirNargoFramework* = "nargo test"
  NoirNargoVersion* = "m17"
  NoirNargoBinary* = "nargo"
  NoirProjectMarker* = "Nargo.toml"

  NoirRecordUnsupported* =
    "Noir trace recording is not claimed by the noir-nargo provider: the " &
    "only Noir tracer today is the tooling/tracer_wasm pair, and an " &
    "ordinary compile-then-trace run reports ok from BOTH modules while " &
    "producing a trace of one event and zero steps. Recording must not be " &
    "claimed until the record path asserts a non-trivial trace (steps > 0 " &
    "and calls > 0), not merely a successful exit and a debug_symbols field."

type
  NoirCommandScope* = enum
    ncsProject
    ncsFile
    ncsSingle

  NoirTestDecl* = object
    name*: string
    selector*: string
      ## `nargo`'s fully-qualified test name: the `::`-joined module path plus
      ## the function name. Derived to match
      ## `HirContext::fully_qualified_function_name`
      ## (compiler/noirc_frontend/src/hir/mod.rs), which is what
      ## `--exact` compares against.
    line*: int
    column*: int
    endColumn*: int
    attrLine*: int
    shouldFail*: bool
    expectedFailure*: string
    unconstrained*: bool

  NoirRunSummary* = object
    ## What a parsed `nargo test --format json` stream actually contained.
    ##
    ## Counted rather than inferred, because the whole point of the
    ## non-triviality rule is that "the process exited 0" and "tests ran" are
    ## different facts and a run can have the first without the second.
    finished*: int
    passed*: int
    failed*: int
    skipped*: int
    started*: int
    suiteLines*: int
    unparsedLines*: int

  ModuleFrame = object
    name: string
    closeDepth: int

# ---------------------------------------------------------------------------
# Source sanitising
# ---------------------------------------------------------------------------

proc maskRange(target: var string; content: string; startPos, endPos: int) =
  var i = startPos
  while i < endPos and i < content.len:
    target[i] = if content[i] == '\n': '\n' else: ' '
    inc i

proc rawStringEnd(content: string; start: int): int =
  ## End (exclusive) of a Noir raw string `r#…#"…"#…#` beginning at `start`,
  ## or -1 when `start` does not open one. Noir's lexer emits `Token::RawStr`
  ## with a hash count (compiler/noirc_frontend/src/lexer/lexer.rs), same
  ## shape as Rust's.
  var i = start
  if i >= content.len or content[i] != 'r':
    return -1
  inc i
  var hashes = 0
  while i < content.len and content[i] == '#':
    inc hashes
    inc i
  if i >= content.len or content[i] != '"':
    return -1
  inc i
  while i < content.len:
    if content[i] == '"':
      var j = i + 1
      var matched = true
      for _ in 0 ..< hashes:
        if j >= content.len or content[j] != '#':
          matched = false
          break
        inc j
      if matched:
        return j
    inc i
  content.len

proc sanitizeNoir*(content: string): string =
  ## Blank out comments and string literals, preserving byte offsets and line
  ## breaks so line numbers survive.
  ##
  ## DELIBERATELY DIFFERENT FROM `rust_libtest.sanitizeRust` IN ONE PLACE:
  ## single quotes are NOT treated as a literal delimiter. Noir has no char
  ## literal and no lifetimes — its lexer's only uses of `'` are the quoted
  ## attribute form `#['…]` and an error-recovery case inside strings
  ## (`skip_until_string_end`). Masking from a `'` to the next `'` would
  ## therefore blank out a run of ordinary code starting at an attribute, and
  ## every `#[test]` after it would be invisible.
  result = content
  var i = 0
  while i < content.len:
    if i + 1 < content.len and content[i] == '/' and content[i + 1] == '/':
      let start = i
      while i < content.len and content[i] != '\n':
        inc i
      result.maskRange(content, start, i)
      continue

    if i + 1 < content.len and content[i] == '/' and content[i + 1] == '*':
      let start = i
      i += 2
      var depth = 1
      while i < content.len and depth > 0:
        if i + 1 < content.len and content[i] == '/' and content[i + 1] == '*':
          inc depth
          i += 2
        elif i + 1 < content.len and content[i] == '*' and content[i + 1] == '/':
          dec depth
          i += 2
        else:
          inc i
      result.maskRange(content, start, i)
      continue

    let rawEnd = rawStringEnd(content, i)
    if rawEnd >= 0:
      result.maskRange(content, i, rawEnd)
      i = rawEnd
      continue

    if content[i] == '"':
      let start = i
      inc i
      while i < content.len:
        if content[i] == '\\':
          i += 2
        elif content[i] == '"':
          inc i
          break
        else:
          inc i
      result.maskRange(content, start, i)
      continue

    inc i

# ---------------------------------------------------------------------------
# Declaration parsing
# ---------------------------------------------------------------------------

proc isIdentStart(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '_'}

proc isIdentChar(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}

proc readIdentAt(line: string; start: int; ident: var string;
    nextPos: var int): bool =
  var i = start
  if i >= line.len or not isIdentStart(line[i]):
    return false
  let identStart = i
  inc i
  while i < line.len and isIdentChar(line[i]):
    inc i
  ident = line[identStart ..< i]
  nextPos = i
  true

proc findKeyword(line, keyword: string): int =
  var i = 0
  while i + keyword.len <= line.len:
    if line.continuesWith(keyword, i):
      let beforeOk = i == 0 or not isIdentChar(line[i - 1])
      let afterOk = i + keyword.len >= line.len or
        not isIdentChar(line[i + keyword.len])
      if beforeOk and afterOk:
        return i
    inc i
  -1

proc readFnName(line: string): tuple[name: string; column: int;
    endColumn: int] =
  let fnPos = findKeyword(line, "fn")
  if fnPos < 0:
    return ("", 0, 0)
  var
    name = ""
    nextPos = 0
    i = fnPos + "fn".len
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  if readIdentAt(line, i, name, nextPos):
    (name, fnPos + 1, nextPos)
  else:
    ("", 0, 0)

proc readModName(line: string): Option[string] =
  let modPos = findKeyword(line, "mod")
  if modPos < 0:
    return none(string)
  var
    name = ""
    nextPos = 0
    i = modPos + "mod".len
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  if readIdentAt(line, i, name, nextPos):
    some(name)
  else:
    none(string)

proc braceDelta(line: string): int =
  for ch in line:
    if ch == '{':
      inc result
    elif ch == '}':
      dec result

type
  NoirAttr = object
    isTest: bool
    shouldFail: bool
    expectedFailure: string
    line: int

proc quotedMessageAfter(rawLine, marker: string): string =
  ## The first double-quoted run following `marker` on the UNSANITISED line.
  ##
  ## `should_fail_with`'s message is a string literal, and `sanitizeNoir`
  ## blanks string literals — deliberately, because that is what stops a
  ## `#[test]` written inside a string from being read as a declaration. So
  ## the attribute is RECOGNISED on the sanitised line (masking-correct: a
  ## `#[test]` inside a comment must stay invisible) and its message is
  ## RECOVERED from the raw line. Reading the whole attribute off the raw line
  ## instead would resurrect every commented-out test.
  let markerPos = rawLine.find(marker)
  if markerPos < 0:
    return ""
  let openQuote = rawLine.find('"', markerPos + marker.len)
  if openQuote < 0:
    return ""
  var i = openQuote + 1
  while i < rawLine.len:
    if rawLine[i] == '\\':
      i += 2
      continue
    if rawLine[i] == '"':
      return rawLine[openQuote + 1 ..< i]
    inc i
  ""

proc parseTestAttribute*(sanitizedLine, rawLine: string; lineNo: int;
    attr: var NoirAttr): bool =
  ## Recognise the three — and only the three — forms Noir's parser accepts:
  ## `#[test]`, `#[test(should_fail)]`, `#[test(should_fail_with = "msg")]`
  ## (compiler/noirc_frontend/src/parser/parser/attributes.rs, and the error
  ## text in lexer/errors.rs that enumerates them).
  let stripped = sanitizedLine.strip
  if not stripped.startsWith("#["):
    return false
  var body = stripped[2 .. ^1]
  let closing = body.rfind(']')
  if closing < 0:
    return false
  body = body[0 ..< closing].strip
  if body == "test":
    attr = NoirAttr(isTest: true, line: lineNo)
    return true
  if not body.startsWith("test"):
    return false
  var rest = body["test".len .. ^1].strip
  if not (rest.startsWith("(") and rest.endsWith(")")):
    return false
  rest = rest[1 ..< rest.len - 1].strip
  if rest == "should_fail":
    attr = NoirAttr(isTest: true, shouldFail: true, line: lineNo)
    return true
  if rest.startsWith("should_fail_with"):
    if rest.find('=') < 0:
      return false
    attr = NoirAttr(isTest: true, shouldFail: true,
        expectedFailure: quotedMessageAfter(rawLine, "should_fail_with"),
        line: lineNo)
    return true
  false

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc fileModulePrefix*(projectRoot, filePath: string): seq[string] =
  ## The module path a file contributes, matching how `nargo` resolves
  ## `mod foo;` — `src/foo.nr` and `src/foo/mod.nr` are both module `foo`, and
  ## the crate root (`src/main.nr` for a `bin`, `src/lib.nr` for a `lib`)
  ## contributes nothing.
  let rel = normalizedRelative(projectRoot, filePath)
  if not rel.startsWith("src/"):
    return @[]
  var stem = rel["src/".len .. ^1]
  if stem.endsWith(".nr"):
    stem = stem[0 ..< stem.len - 3]
  if stem in ["main", "lib"]:
    return @[]
  for part in stem.split('/'):
    if part == "mod":
      continue
    result.add part

proc selectorFor(prefix, modules: seq[string]; name: string): string =
  var parts: seq[string] = @[]
  parts.add prefix
  parts.add modules
  parts.add name
  parts.filterIt(it.len > 0).join("::")

proc parseNoirTestDeclarations*(projectRoot, filePath,
    content: string): seq[NoirTestDecl] =
  let
    sanitized = sanitizeNoir(content)
    filePrefix = fileModulePrefix(projectRoot, filePath)
    rawLines = content.splitLines
  var
    lineNo = 0
    braceDepth = 0
    modules: seq[ModuleFrame] = @[]
    pending: seq[NoirAttr] = @[]
    sawNonAttrLine = false

  for line in sanitized.splitLines:
    inc lineNo
    let rawLine = if lineNo <= rawLines.len: rawLines[lineNo - 1] else: line
    while modules.len > 0 and braceDepth < modules[^1].closeDepth:
      discard modules.pop()

    let stripped = line.strip
    if stripped.len == 0:
      continue

    var attr: NoirAttr
    if parseTestAttribute(line, rawLine, lineNo, attr):
      pending.add attr
      sawNonAttrLine = false
    elif stripped.startsWith("#["):
      # Some other attribute — `#[export]`, `#[oracle(...)]`, `#[builtin]`.
      # It does not cancel a pending `#[test]`, because attributes stack.
      sawNonAttrLine = false
    else:
      let fnInfo = readFnName(line)
      if fnInfo.name.len > 0:
        var
          testAttrLine = 0
          shouldFail = false
          expectedFailure = ""
        for candidate in pending:
          if candidate.isTest:
            if testAttrLine == 0:
              testAttrLine = candidate.line
            if candidate.shouldFail:
              shouldFail = true
            if candidate.expectedFailure.len > 0 and expectedFailure.len == 0:
              expectedFailure = candidate.expectedFailure
        if testAttrLine > 0:
          result.add NoirTestDecl(
            name: fnInfo.name,
            selector: selectorFor(filePrefix, modules.mapIt(it.name),
                fnInfo.name),
            line: lineNo,
            column: fnInfo.column,
            endColumn: fnInfo.endColumn,
            attrLine: testAttrLine,
            shouldFail: shouldFail,
            expectedFailure: expectedFailure,
            unconstrained: findKeyword(line, "unconstrained") >= 0)
        pending = @[]
        sawNonAttrLine = true
      else:
        if sawNonAttrLine:
          pending = @[]
        sawNonAttrLine = true

    let maybeMod = readModName(line)
    let delta = braceDelta(line)
    if maybeMod.isSome and line.contains("{"):
      modules.add ModuleFrame(name: maybeMod.get, closeDepth: braceDepth + 1)
    braceDepth += delta

# ---------------------------------------------------------------------------
# Provider surface
# ---------------------------------------------------------------------------

proc isNoirFile*(path: string): bool =
  path.endsWith(".nr") and fileExists(path)

proc hasNargoToml*(projectRoot: string): bool =
  dirExists(projectRoot) and fileExists(projectRoot / NoirProjectMarker)

proc isNoirSourceFile*(projectRoot, filePath: string): bool =
  isNoirFile(filePath) and
    normalizedRelative(projectRoot, filePath).startsWith("src/")

proc noirFiles*(projectRoot: string): seq[string] =
  ## `walkWorkspaceFiles`, never `walkDirRec` — docs/ct-test-provider-guide.md
  ## §"Enumerating Workspace Files". A Noir workspace routinely carries a
  ## `target/` directory and vendored git dependencies under `~/.nargo`; the
  ## shared scope keeps both out of every provider at once.
  if not dirExists(projectRoot):
    return @[]
  let sourceRoot = projectRoot / "src"
  if not dirExists(sourceRoot):
    return @[]
  for path in walkWorkspaceFiles(sourceRoot):
    if isNoirFile(path):
      result.add path
  result.sort(system.cmp[string])

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
    # True, and meant: `nargo test --format json --show-output` carries a
    # per-test `stdout` field, which becomes one `tekOutput` event per test.
    canCapturePerTestOutput: true,
    # False by contract as much as by fact — `validateCapabilities` refuses
    # trace entry-point mapping without a recording capability, and this
    # provider claims none.
    canMapTraceEntryPoints: false,
    # True, and meant: the events below come from nargo's own JSON Lines
    # stream, not from an exit code fanned out over the catalog.
    emitsStructuredEvents: true)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: NoirNargoProviderId,
    language: "noir",
    framework: NoirNargoFramework,
    displayName: "Noir nargo test",
    version: NoirNargoVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(info: TestProviderInfo; projectRoot, filePath: string;
    decl: NoirTestDecl): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  var tags = @["noir", "nargo-test"]
  if decl.shouldFail:
    tags.add "should-fail"
  if decl.expectedFailure.len > 0:
    tags.add "should-fail-with"
  if decl.unconstrained:
    tags.add "unconstrained"
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative,
        decl.selector),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: decl.name,
    kind: tikCase,
    file: relative,
    range: SourceRange(
      startLine: decl.attrLine,
      startColumn: 1,
      endLine: decl.line,
      endColumn: decl.endColumn),
    selector: decl.selector,
    parentId: "",
    tags: tags,
    location: LocationProvenance(
      source: lskParser,
      detail: "Noir source parser for #[test], #[test(should_fail)] and " &
        "#[test(should_fail_with = \"…\")]; selectors mirror nargo's " &
        "fully-qualified names and are checkable against nargo test " &
        "--list-tests",
      confidence: lcHigh),
    stale: false,
    staleReason: "")

proc readSourceGuarded(path: string; text: var string): bool =
  ## Guarded `readFile`, per docs/ct-test-provider-guide.md: an unreadable
  ## file must not abort a whole workspace discovery. A bare `except:` on
  ## purpose — CONTRIBUTING.md's portability rule — because the failure comes
  ## out of the OS, not out of Nim, and the narrow form is exactly the one
  ## that has already let an exception escape in this repo.
  try:
    text = readFile(path)
    true
  except:
    false

proc noirFileCatalog*(projectRoot, filePath: string): ProviderResult[
    TestCatalog] =
  let info = providerInfo()
  if not isNoirFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Noir .nr source file",
          filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))
  if not isNoirSourceFile(projectRoot, filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[],
          diagnostics: @[diagnostic(dsInfo,
              "Noir file is outside the crate's src/ discovery root",
              filePath)]))

  var source = ""
  if not readSourceGuarded(filePath, source):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning,
          "Noir source file could not be read; it contributes no catalog " &
          "items", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion,
          provider: info, items: @[], diagnostics: @[]))

  var items: seq[TestItem] = @[]
  for decl in parseNoirTestDeclarations(projectRoot, filePath, source):
    items.add itemFromDecl(info, projectRoot, filePath, decl)
  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
        items: items, diagnostics: @[]))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for path in noirFiles(projectRoot):
    let fileResult = noirFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
    for item in fileResult.diagnostics:
      catalog.diagnostics.add item
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc noirProjectCatalog*(projectRoot: string): ProviderResult[TestCatalog] =
  discoverProjectImpl(projectRoot)

proc noirSelectorsForFile*(projectRoot, filePath: string): seq[string] =
  noirFileCatalog(projectRoot, filePath).value.items.mapIt(it.selector)

# ---------------------------------------------------------------------------
# Command construction
# ---------------------------------------------------------------------------

proc buildNargoCommand*(selectors: seq[string];
    scope: NoirCommandScope): seq[string] =
  ## `--format json` is not optional decoration: it is the only reason this
  ## provider can report per-test results at all, so it is part of every
  ## command rather than a flag a caller may forget.
  ##
  ## FILE SCOPE IS AN EXACT LIST, NOT A PREFIX. `nargo test <substring>` is a
  ## `FunctionNameMatch::Contains` over the fully-qualified name, and a file at
  ## the crate root (`src/main.nr`) contributes an EMPTY module prefix — so
  ## the obvious "run the file's module prefix" spelling silently degrades a
  ## file-scoped run into a whole-project run, and reports it as success.
  ## `--exact a b c` is `FunctionNameMatch::Exact(Vec<String>)`, which matches
  ## any of the listed names and nothing else.
  result = @[NoirNargoBinary, "test", "--format", "json", "--show-output"]
  case scope
  of ncsProject:
    discard
  of ncsFile, ncsSingle:
    if selectors.len == 0:
      return @[]
    result.add "--exact"
    result.add selectors

proc parseNargoListTests*(output: string): seq[string] =
  ## `nargo test --list-tests` prints `<package> <fully-qualified name>` per
  ## line. Exposed so a suite can compare this provider's parsed selectors
  ## against nargo's own answer rather than against a second copy of the
  ## parser's beliefs.
  ## The shape is asserted rather than assumed: exactly two whitespace-
  ## separated fields, the second of which is a Noir path — identifiers joined
  ## by `::`. nargo prints compiler warnings above the list, complete with
  ## box-drawing rules and source excerpts, and a looser "take everything
  ## after the last space" rule swallows four of them as if they were test
  ## names. Measured: 11 "selectors" out of a 7-test crate.
  for rawLine in output.splitLines:
    let fields = rawLine.strip.splitWhitespace
    if fields.len != 2:
      continue
    let name = fields[1]
    if name.len == 0 or not isIdentStart(name[0]):
      continue
    var wellFormed = true
    for ch in name:
      if not (isIdentChar(ch) or ch == ':'):
        wellFormed = false
        break
    if wellFormed:
      result.add name
  result.sort(system.cmp[string])

# ---------------------------------------------------------------------------
# Event stream
# ---------------------------------------------------------------------------

proc jsonLineOrNil(line: string): JsonNode =
  ## Bare `except:` on purpose. `parseJson` raises `JsonParsingError` on the C
  ## backend and lets V8's raw `SyntaxError` through on the JS backend, so
  ## `except CatchableError` is not portable — CONTRIBUTING.md, "Code compiled
  ## for both backends". Here it is not hypothetical either: nargo writes
  ## compiler diagnostics and a trailing bare `Error:` to stderr, and
  ## `execCapturedShell` merges stderr into the same stream the JSON Lines
  ## arrive on.
  try:
    let node = parseJson(line)
    if node.kind == JObject: node else: nil
  except:
    nil

proc noirEventsFromOutput*(providerId, runId, output: string;
    summary: var NoirRunSummary): seq[TestEvent] =
  ## Turn one captured `nargo test --format json` stream into normalized
  ## events, and COUNT what it contained.
  ##
  ## The counting is the point. A stream that parsed cleanly and produced zero
  ## test results is not an empty success — it is a run that did not happen,
  ## and it looks exactly like a passing run to anything that consults only
  ## the exit code.
  summary = NoirRunSummary()
  for rawLine in output.splitLines:
    let line = rawLine.strip
    if line.len == 0:
      continue
    let node = jsonLineOrNil(line)
    if node.isNil:
      inc summary.unparsedLines
      continue
    let kind = if node.hasKey("type"): node["type"].getStr else: ""
    if kind != "test":
      inc summary.suiteLines
      continue
    let
      name = if node.hasKey("name"): node["name"].getStr else: ""
      eventName = if node.hasKey("event"): node["event"].getStr else: ""
      stdout = if node.hasKey("stdout"): node["stdout"].getStr else: ""
      durationMs =
        if node.hasKey("exec_time"): int(node["exec_time"].getFloat * 1000.0)
        else: 0
    if name.len == 0 or eventName.len == 0:
      inc summary.unparsedLines
      continue
    case eventName
    of "started":
      inc summary.started
      result.add event(tekTestStarted, providerId, runId, name,
          message = name)
    of "ok":
      inc summary.finished
      inc summary.passed
      if stdout.len > 0:
        result.add event(tekOutput, providerId, runId, name, output = stdout,
            durationMs = durationMs)
      result.add event(tekTestFinished, providerId, runId, name,
          some(tsPassed), "passed", durationMs = durationMs)
    of "failed":
      inc summary.finished
      inc summary.failed
      if stdout.len > 0:
        result.add event(tekOutput, providerId, runId, name, output = stdout,
            durationMs = durationMs)
      result.add event(tekFailure, providerId, runId, name, some(tsFailed),
          if stdout.len > 0: stdout.splitLines[0] else: "nargo reported a failure",
          stdout, durationMs = durationMs)
      result.add event(tekTestFinished, providerId, runId, name,
          some(tsFailed), "failed", durationMs = durationMs)
    of "ignored":
      inc summary.finished
      inc summary.skipped
      result.add event(tekTestFinished, providerId, runId, name,
          some(tsSkipped), "skipped", durationMs = durationMs)
    else:
      inc summary.unparsedLines

proc noirRunResult*(scope: TestScope; command: string; outcome: CapturedRun;
    summary: var NoirRunSummary): ProviderResult[seq[TestEvent]] =
  ## Assemble the run's `ProviderResult` from a captured process outcome.
  ##
  ## Separated from the process launch so the three outcomes that are easy to
  ## get wrong — a truncated capture, a stream with no test results, and a
  ## failing test — are assertable directly on a transcript instead of only
  ## through a subprocess.
  let
    providerId = NoirNargoProviderId
    runId = providerId & ":" & $scope.kind & ":" & scope.selector
    testId = if scope.testId.len > 0: scope.testId else: scope.selector
  var events = @[event(tekRunStarted, providerId, runId, testId,
      message = command)]

  if outcome.truncated:
    # `process_exec.CapturedRun.truncated` exists for exactly this: a
    # line-per-record stream cut at a bound is indistinguishable from a
    # complete short one, and a JSON Lines stream is the most list-shaped
    # output ct_test consumes.
    events.add event(tekFailure, providerId, runId, testId, some(tsErrored),
        "nargo output was truncated at the capture bound; the per-test " &
        "results are a prefix and cannot be trusted", outcome.output,
        durationMs = outcome.durationMs)
    events.add event(tekRunFinished, providerId, runId, testId,
        some(tsErrored), "errored", durationMs = outcome.durationMs)
    summary = NoirRunSummary()
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError,
          "nargo output was truncated at the capture bound", scope.file)],
      value: events)

  events.add noirEventsFromOutput(providerId, runId, outcome.output, summary)

  if summary.finished == 0:
    # NON-TRIVIALITY, ASSERTED BY THE PROVIDER AND NOT LEFT TO THE CALLER.
    # `nargo test` with a selector that matches nothing exits 0 and prints a
    # suite line and no test lines. Reporting that as a pass is how a suite
    # goes green over nothing.
    events.add event(tekFailure, providerId, runId, testId, some(tsErrored),
        "nargo produced no per-test results (" & $summary.suiteLines &
        " suite line(s), " & $summary.unparsedLines & " unparsed line(s), " &
        "exit code " & $outcome.exitCode & "); a run that reports no tests " &
        "is not a passing run", outcome.output,
        durationMs = outcome.durationMs)
    events.add event(tekRunFinished, providerId, runId, testId,
        some(tsErrored), "errored", durationMs = outcome.durationMs)
    return ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError,
          "nargo produced no per-test results", scope.file)],
      value: events)

  let failed = summary.failed > 0
  events.add event(tekRunFinished, providerId, runId, testId,
      if failed: some(tsFailed) else: some(tsPassed),
      if failed: "failed" else: "passed", durationMs = outcome.durationMs)
  if failed:
    ProviderResult[seq[TestEvent]](
      diagnostics: @[diagnostic(dsError,
          $summary.failed & " of " & $summary.finished &
          " Noir test(s) failed", scope.file)],
      value: events)
  else:
    ProviderResult[seq[TestEvent]](diagnostics: @[], value: events)

proc runNoir(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  {.cast(gcsafe).}:
    let commandScope =
      case scope.kind
      of tskProject: ncsProject
      of tskFile: ncsFile
      of tskSingle: ncsSingle
    let selectors =
      case commandScope
      of ncsProject: @[]
      of ncsFile: noirSelectorsForFile(scope.projectRoot, scope.file)
      of ncsSingle: @[scope.selector]
    let args = buildNargoCommand(selectors, commandScope)
    if args.len == 0:
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[diagnostic(dsWarning,
            "no Noir tests were discovered in this scope, so nothing was " &
            "run; nargo was NOT invoked without a selector, because an " &
            "unselected nargo test runs the whole crate", scope.file)],
        value: @[])
    if not toolAvailable(NoirNargoBinary):
      return ProviderResult[seq[TestEvent]](
        diagnostics: @[missingToolDiagnostic(NoirNargoBinary, @[], scope.file)],
        value: @[])
    let command = commandLine(args)
    let outcome = execCapturedShell(command, cwd = scope.projectRoot)
    var summary: NoirRunSummary
    noirRunResult(scope, command, outcome, summary)

proc recordUnsupported(scope: TestScope): ProviderResult[
    seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, NoirRecordUnsupported, scope.file)],
    value: @[])

proc mapTraceUnsupported(catalog: TestCatalog;
    traces: seq[TraceMetadata]): ProviderResult[
    Table[string, TraceMetadata]] {.gcsafe.} =
  ProviderResult[Table[string, TraceMetadata]](
    diagnostics: @[diagnostic(dsWarning,
        "Noir trace entry-point mapping is unavailable until recording is " &
        "claimed")],
    value: initTable[string, TraceMetadata]())

proc newNoirNargoM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    # A project MARKER, not a content scan — the guide's rule, and the reason
    # this probe costs one `fileExists` per registered workspace.
    ProviderResult[bool](diagnostics: @[], value: hasNargoToml(projectRoot))
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    noirFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[
      TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[
      seq[TestItem]] {.gcsafe.} =
    let catalog = noirFileCatalog(projectRoot, file)
    ProviderResult[seq[TestItem]](diagnostics: catalog.value.diagnostics,
        value: catalog.value.items)
  provider.run = runNoir
  provider.record = recordUnsupported
  provider.parseEvent = proc(raw: string): ProviderResult[
      TestEvent] {.gcsafe.} =
    parseProviderEventLine(NoirNargoProviderId, raw)
  provider.mapTraceEntryPoints = mapTraceUnsupported
  M1Provider(provider: provider,
      relevantConfigFiles: @["Nargo.toml", "Nargo.lock"])

proc newNoirNargoProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newNoirNargoM1Provider()])
