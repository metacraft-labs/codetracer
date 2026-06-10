import std/[algorithm, options, os, sequtils, strutils, tables]

import ../contracts
import ../discovery

const
  RustLibtestProviderId* = "rust-libtest"
  RustLibtestFramework* = "libtest/cargo-test"
  RustLibtestVersion* = "m6"

type
  RustCommandScope* = enum
    rcsProject
    rcsFile
    rcsSingle

  RustTestDecl* = object
    name*: string
    selector*: string
    line*: int
    column*: int
    endColumn*: int
    attrLine*: int
    ignored*: bool
    asyncRuntime*: string

  ModuleFrame = object
    name: string
    closeDepth: int

proc normalizedRelative*(projectRoot, filePath: string): string =
  relativePath(filePath, projectRoot).replace("\\", "/")

proc isRustFile*(path: string): bool =
  path.endsWith(".rs") and fileExists(path)

proc hasCargoToml*(projectRoot: string): bool =
  fileExists(projectRoot / "Cargo.toml")

proc isCargoRustTestFile*(projectRoot, filePath: string): bool =
  if not isRustFile(filePath):
    return false
  let rel = normalizedRelative(projectRoot, filePath)
  rel.startsWith("src/") or rel.startsWith("tests/")

proc rustFiles*(projectRoot: string): seq[string] =
  if not dirExists(projectRoot):
    return @[]
  for root in ["src", "tests"]:
    let dir = projectRoot / root
    if dirExists(dir):
      for path in walkDirRec(dir):
        if isRustFile(path):
          result.add path
  result.sort(system.cmp[string])

proc maskRange(result: var string; content: string; startPos, endPos: int) =
  var i = startPos
  while i < endPos and i < content.len:
    result[i] = if content[i] == '\n': '\n' else: ' '
    inc i

proc rawStringEnd(content: string; start: int): int =
  var i = start
  if i < content.len and content[i] == 'b':
    inc i
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

proc sanitizeRust*(content: string): string =
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

    if i + 1 < content.len and content[i] == 'b' and content[i + 1] == '"':
      let start = i
      i += 2
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

    if content[i] == '\'':
      let start = i
      inc i
      while i < content.len:
        if content[i] == '\\':
          i += 2
        elif content[i] == '\'':
          inc i
          break
        elif content[i] == '\n':
          break
        else:
          inc i
      result.maskRange(content, start, i)
      continue

    inc i

proc isIdentStart(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '_'}

proc isIdentChar(ch: char): bool =
  ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}

proc normalizeRustIdent(raw: string): string =
  if raw.startsWith("r#"):
    raw[2 .. ^1]
  else:
    raw

proc readIdentAt(line: string; start: int; ident: var string; nextPos: var int): bool =
  var i = start
  if i + 1 < line.len and line[i] == 'r' and line[i + 1] == '#' and
      i + 2 < line.len and isIdentStart(line[i + 2]):
    i += 2
  elif i >= line.len or not isIdentStart(line[i]):
    return false
  let identStart = i
  inc i
  while i < line.len and isIdentChar(line[i]):
    inc i
  ident = normalizeRustIdent(line[identStart ..< i])
  nextPos = i
  true

proc findKeyword(line, keyword: string): int =
  var i = 0
  while i + keyword.len <= line.len:
    if line.continuesWith(keyword, i):
      let beforeOk = i == 0 or not isIdentChar(line[i - 1])
      let afterOk = i + keyword.len >= line.len or not isIdentChar(line[i + keyword.len])
      if beforeOk and afterOk:
        return i
    inc i
  -1

proc attrName(line: string): string =
  let stripped = line.strip
  if not stripped.startsWith("#["):
    return ""
  var i = 2
  while i < stripped.len and stripped[i] in {' ', '\t'}:
    inc i
  let start = i
  while i < stripped.len and stripped[i] notin {'(', ']', ' ', '\t'}:
    inc i
  stripped[start ..< i]

proc attrIsTest(name: string): bool =
  name == "test" or name == "tokio::test" or name == "async_std::test" or
    name == "actix_rt::test" or name == "actix_web::test"

proc asyncRuntimeFor(name: string): string =
  case name
  of "tokio::test": "tokio"
  of "async_std::test": "async-std"
  of "actix_rt::test", "actix_web::test": "actix"
  else: ""

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

proc readFnName(line: string): tuple[name: string, column: int, endColumn: int] =
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

proc braceDelta(line: string): int =
  for ch in line:
    if ch == '{':
      inc result
    elif ch == '}':
      dec result

proc fileModulePrefix(projectRoot, filePath: string): seq[string] =
  let rel = normalizedRelative(projectRoot, filePath)
  if rel.startsWith("src/"):
    var stem = rel["src/".len .. ^1]
    if stem.endsWith(".rs"):
      stem = stem[0 ..< stem.len - 3]
    if stem in ["lib", "main"]:
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

proc parseRustTestDeclarations*(projectRoot, filePath, content: string): seq[RustTestDecl] =
  let sanitized = sanitizeRust(content)
  let filePrefix = fileModulePrefix(projectRoot, filePath)
  var
    lineNo = 0
    braceDepth = 0
    modules: seq[ModuleFrame] = @[]
    pendingAttrs: seq[tuple[name: string, line: int]] = @[]

  for line in sanitized.splitLines:
    inc lineNo
    while modules.len > 0 and braceDepth < modules[^1].closeDepth:
      discard modules.pop()

    let stripped = line.strip
    if stripped.len == 0:
      continue

    let attr = attrName(line)
    if attr.len > 0:
      pendingAttrs.add (attr, lineNo)
    else:
      let fnInfo = readFnName(line)
      if fnInfo.name.len > 0:
        var
          testAttrLine = 0
          ignored = false
          runtime = ""
        for pending in pendingAttrs:
          if attrIsTest(pending.name):
            if testAttrLine == 0:
              testAttrLine = pending.line
            if runtime.len == 0:
              runtime = asyncRuntimeFor(pending.name)
          elif pending.name == "ignore":
            ignored = true
        if testAttrLine > 0:
          let moduleNames = modules.mapIt(it.name)
          result.add RustTestDecl(
            name: fnInfo.name,
            selector: selectorFor(filePrefix, moduleNames, fnInfo.name),
            line: lineNo,
            column: fnInfo.column,
            endColumn: fnInfo.endColumn,
            attrLine: testAttrLine,
            ignored: ignored,
            asyncRuntime: runtime)
        pendingAttrs = @[]
      elif not stripped.startsWith("#["):
        pendingAttrs = @[]

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
    canCapturePerTestOutput: false,
    canMapTraceEntryPoints: false,
    emitsStructuredEvents: false)

proc providerInfo*(): TestProviderInfo =
  TestProviderInfo(
    id: RustLibtestProviderId,
    language: "rust",
    framework: RustLibtestFramework,
    displayName: "Rust libtest / cargo test",
    version: RustLibtestVersion,
    capabilities: providerCapabilities())

proc itemFromDecl(
    info: TestProviderInfo;
    projectRoot, filePath: string;
    decl: RustTestDecl): TestItem =
  let relative = normalizedRelative(projectRoot, filePath)
  var tags = @["rust", "libtest", "cargo-test"]
  if decl.ignored:
    tags.add "ignore"
  if decl.asyncRuntime.len > 0:
    tags.add decl.asyncRuntime
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative, decl.selector),
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
      detail: "M6 lightweight Rust parser; reconcile selectors with cargo test -- --list before execution",
      confidence: lcHigh),
    stale: false,
    staleReason: "")

proc rustFileCatalog*(projectRoot, filePath: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  if not isRustFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Rust source file", filePath)],
      value: TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info, items: @[], diagnostics: @[]))
  if not isCargoRustTestFile(projectRoot, filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[],
      value: TestCatalog(
        schemaVersion: TestCatalogSchemaVersion,
        provider: info,
        items: @[],
        diagnostics: @[diagnostic(dsInfo, "Rust file is outside Cargo src/ or tests/ discovery roots", filePath)]))

  var items: seq[TestItem] = @[]
  for decl in parseRustTestDeclarations(projectRoot, filePath, readFile(filePath)):
    items.add itemFromDecl(info, projectRoot, filePath, decl)
  ProviderResult[TestCatalog](
    diagnostics: @[],
    value: TestCatalog(
      schemaVersion: TestCatalogSchemaVersion,
      provider: info,
      items: items,
      diagnostics: @[]))

proc detectProject(projectRoot: string): ProviderResult[bool] =
  ProviderResult[bool](diagnostics: @[], value: hasCargoToml(projectRoot))

proc discoverProjectImpl(projectRoot: string): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: info,
    items: @[],
    diagnostics: @[])
  for path in rustFiles(projectRoot):
    let fileResult = rustFileCatalog(projectRoot, path)
    catalog.items.add fileResult.value.items
    catalog.diagnostics.add fileResult.value.diagnostics
  ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

proc locateTestsImpl(projectRoot, filePath: string): ProviderResult[seq[TestItem]] =
  let catalog = rustFileCatalog(projectRoot, filePath)
  ProviderResult[seq[TestItem]](
    diagnostics: catalog.value.diagnostics,
    value: catalog.value.items)

proc integrationTargetName(projectRoot, filePath: string): string =
  let rel = normalizedRelative(projectRoot, filePath)
  if rel.startsWith("tests/") and rel.endsWith(".rs"):
    let stem = rel["tests/".len ..< rel.len - 3]
    if "/" notin stem:
      return stem
  ""

proc buildRustCommand*(projectRoot, filePath, selector: string; scope: RustCommandScope): seq[string] =
  result = @["cargo", "test"]
  case scope
  of rcsProject:
    discard
  of rcsFile:
    let target = integrationTargetName(projectRoot, filePath)
    if target.len > 0:
      result.add @["--test", target]
    else:
      result.add "--lib"
  of rcsSingle:
    let target = integrationTargetName(projectRoot, filePath)
    if target.len > 0:
      result.add @["--test", target]
    else:
      result.add "--lib"
    result.add @["--", selector, "--exact", "--include-ignored"]

proc notImplementedRecord(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, "Rust libtest trace recording is not wired in M6; use command construction for run-only support", scope.file)],
    value: @[])

proc notImplementedRun(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, "Rust libtest process execution and event parsing are not wired in M6; command construction is tested", scope.file)],
    value: @[])

proc parseEventUnsupported(raw: string): ProviderResult[TestEvent] {.gcsafe.} =
  ProviderResult[TestEvent](
    diagnostics: @[diagnostic(dsWarning, "Rust libtest event parsing is not implemented in M6")],
    value: TestEvent(schemaVersion: TestEventSchemaVersion, providerId: RustLibtestProviderId))

proc mapTraceUnsupported(
    catalog: TestCatalog;
    traces: seq[TraceMetadata]): ProviderResult[Table[string, TraceMetadata]] {.gcsafe.} =
  ProviderResult[Table[string, TraceMetadata]](
    diagnostics: @[diagnostic(dsWarning, "Rust libtest trace entry-point mapping is not implemented in M6")],
    value: initTable[string, TraceMetadata]())

proc newRustLibtestM1Provider*(): M1Provider =
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    detectProject(projectRoot)
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[TestCatalog] {.gcsafe.} =
    rustFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[TestItem]] {.gcsafe.} =
    locateTestsImpl(projectRoot, file)
  provider.run = notImplementedRun
  provider.record = notImplementedRecord
  provider.parseEvent = parseEventUnsupported
  provider.mapTraceEntryPoints = mapTraceUnsupported
  M1Provider(
    provider: provider,
    relevantConfigFiles: @["Cargo.toml", "Cargo.lock", ".cargo/config.toml"])

proc newRustLibtestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newRustLibtestM1Provider()])
