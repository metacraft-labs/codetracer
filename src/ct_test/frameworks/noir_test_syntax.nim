## The Noir test-declaration SYNTAX, with no filesystem and no subprocess.
##
## ## Why this is its own module
##
## `noir_nargo.nim` is the `ct test` provider: it walks a project root, reads
## files, and shells out to `nargo`. None of that exists in a browser, and
## `-d:ctWeb` makes `std/os` and `process_exec` unavailable by construction —
## so a renderer that wanted to know *which tests does this project have* had
## exactly two options, and one of them was a second parser.
##
## A second parser is not a hypothetical hazard here. `#[test]`,
## `#[test(should_fail)]` and `#[test(should_fail_with = "…")]` all have to
## agree with `nargo`'s own attribute grammar, module paths have to be resolved
## the way `HirContext::fully_qualified_function_name` resolves them, and
## strings, raw strings and comments have to be masked before any of it — which
## is why `sanitizeNoir` exists and why it is 60 lines. Two implementations of
## that would disagree the first time either was touched, and the symptom would
## be a Test Results pane that lists a test the runner does not have, or misses
## one it does.
##
## So the syntax half lives here, imports `std/[options, sequtils, strutils]`
## and `../contracts`, and compiles on every backend this repository has.
## `noir_nargo.nim` imports it and keeps the halves that genuinely need a host:
## the directory walk, the `readFile`, and the `nargo` invocation.
##
## ## Paths are RELATIVE here, and that is the whole of the interface
##
## The provider computes `normalizedRelative(projectRoot, filePath)` with
## `std/os`'s `relativePath` — which the browser arm cannot have, and which the
## renderer does not need: a bundled template's files are already named by
## their project-relative path. So every proc below takes the relative path,
## `noir_nargo.nim` does the one native conversion, and no `os` import reaches
## a web build.

import std/[options, sequtils, strutils]

import ../contracts

const
  NoirNargoProviderId* = "noir-nargo"
  NoirNargoFramework* = "nargo test"
  NoirNargoVersion* = "m17"
  NoirProjectMarker* = "Nargo.toml"

type
  NoirSourceFile* = object
    ## One source, named by its project-relative path. The shape both hosts
    ## can produce: `noir_nargo.readSourceGuarded` fills it from disk, and
    ## `platform/noir_template` already holds exactly this pair.
    path*: string
    content*: string


type
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

proc isIdentStart*(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '_'}

proc isIdentChar*(ch: char): bool =
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

proc modulePrefixForRelative*(relativePath: string): seq[string] =
  ## The module path a file contributes, matching how `nargo` resolves
  ## `mod foo;` — `src/foo.nr` and `src/foo/mod.nr` are both module `foo`, and
  ## the crate root (`src/main.nr` for a `bin`, `src/lib.nr` for a `lib`)
  ## contributes nothing.
  ##
  ## Takes the PROJECT-RELATIVE path. `noir_nargo.fileModulePrefix` is the
  ## thin native wrapper that computes that path with `std/os`; see this
  ## module's header for why the split is where it is.
  let rel = relativePath.replace("\\", "/")
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

proc selectorFor*(prefix, modules: seq[string]; name: string): string =
  var parts: seq[string] = @[]
  parts.add prefix
  parts.add modules
  parts.add name
  parts.filterIt(it.len > 0).join("::")


proc parseNoirTestDeclarationsRelative*(relativePath,
    content: string): seq[NoirTestDecl] =
  ## Every `#[test]` in one source, by project-relative path. The whole of
  ## Noir test discovery, with no host: `noir_nargo.parseNoirTestDeclarations`
  ## is the native wrapper and the renderer calls this one directly over the
  ## bundled template.
  let
    sanitized = sanitizeNoir(content)
    filePrefix = modulePrefixForRelative(relativePath)
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

proc itemFromDeclRelative*(info: TestProviderInfo; relativePath: string;
    decl: NoirTestDecl): TestItem =
  ## One `TestItem` from one parsed declaration. Identical to what
  ## `noir_nargo` produced before the split — the id, the tags, the range and
  ## the `LocationProvenance` are byte for byte the same, which is what keeps
  ## `noir_providers_test.nim` a check on this code rather than on a copy.
  let relative = relativePath
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


proc noirCatalogFromSources*(files: seq[NoirSourceFile]): TestCatalog =
  ## Discover every test in a set of already-read Noir sources.
  ##
  ## This is `noir_nargo.discoverProjectImpl` with the two host-shaped steps
  ## lifted out — the directory walk and the `readFile` — so a caller that
  ## already HAS the sources does not need either. `noir_nargo` keeps both and
  ## calls in here; `ui/web_entry_surface` hands it the bundled template.
  ##
  ## Files outside `src/` contribute nothing, because nargo compiles `src/`
  ## and nothing else — the same rule `noir_nargo.isNoirSourceFile` enforces
  ## against a filesystem, applied to a path instead.
  let info = providerInfo()
  result = TestCatalog(schemaVersion: TestCatalogSchemaVersion,
      provider: info, items: @[], diagnostics: @[])
  for file in files:
    let rel = file.path.replace("\\", "/")
    if not rel.endsWith(".nr"):
      continue
    if not rel.startsWith("src/"):
      result.diagnostics.add TestDiagnostic(
        severity: dsInfo,
        message: "Noir file is outside the crate's src/ discovery root",
        file: rel,
        range: none(SourceRange))
      continue
    for decl in parseNoirTestDeclarationsRelative(rel, file.content):
      result.items.add itemFromDeclRelative(info, rel, decl)
