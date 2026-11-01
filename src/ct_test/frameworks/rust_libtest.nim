import std/[algorithm, json, options, os, sequtils, strutils, tables]

import ../contracts
import ../discovery
import ../process_exec
import native_m11_common

const
  RustLibtestProviderId* = "rust-libtest"
  RustLibtestFramework* = "libtest/cargo-test"
  RustLibtestVersion* = "m6"
  RustLibtestNixPackages* = ["cargo", "rustc"]
  LibraryKinds = @["lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"]
  RunnableKinds = LibraryKinds & @["bin", "test"]

type
  RustCommandScope* = enum
    rcsProject
    rcsFile
    rcsSingle

  CargoTarget* = object
    ## One entry of a package's `targets` in `cargo metadata`.
    name*: string
    kinds*: seq[string]
    srcPath*: string

  CargoLayout* = object
    ## What Cargo says about the package rooted at the project. `known = false`
    ## means Cargo could not be asked.
    known*: bool
    packageName*: string
    workspaceMembers*: int
    targets*: seq[CargoTarget]

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
      for path in walkWorkspaceFiles(dir):
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

proc modulePathParts(stem: string): seq[string] =
  ## The module path of a file below a crate root, from its slash-separated
  ## stem. `mod.rs` names its directory, so it adds no segment of its own.
  for part in stem.split('/'):
    if part != "mod":
      result.add part

proc fileModulePrefix(projectRoot, filePath: string): seq[string] =
  ## The module path libtest prints for tests in `filePath`, relative to the
  ## test binary that compiles the file. Each target is its own crate, so the
  ## path starts at THAT target's root: a directory that only selects a target
  ## (`src/bin/<x>/`, `tests/<x>/`) is not a module, and writing it into the
  ## selector makes an exact run match nothing.
  let rel = normalizedRelative(projectRoot, filePath)
  if not rel.endsWith(".rs"):
    return @[]
  let stem = rel[0 ..< rel.len - ".rs".len]
  if stem.startsWith("src/bin/"):
    let parts = stem["src/bin/".len .. ^1].split('/')
    # `src/bin/<x>.rs` and `src/bin/<x>/main.rs` are crate roots.
    if parts.len > 1 and parts[1 .. ^1] != @["main"]:
      result = modulePathParts(parts[1 .. ^1].join("/"))
  elif stem.startsWith("src/"):
    let inner = stem["src/".len .. ^1]
    if inner notin ["lib", "main"]:
      result = modulePathParts(inner)
  elif stem.startsWith("tests/"):
    let parts = stem["tests/".len .. ^1].split('/')
    # `tests/<x>.rs` and `tests/<x>/main.rs` are crate roots.
    if parts.len > 1 and parts[1 .. ^1] != @["main"]:
      result = modulePathParts(parts[1 .. ^1].join("/"))

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
  ## Cargo's auto-discovered integration target owning `filePath`:
  ## `tests/<x>.rs` is target `x`, and so is everything below `tests/<x>/` when
  ## `tests/<x>/main.rs` makes that directory a target. A directory without a
  ## `main.rs` (the conventional `tests/common/`) is no target at all.
  ## https://doc.rust-lang.org/cargo/guide/project-layout.html
  let rel = normalizedRelative(projectRoot, filePath)
  if rel.startsWith("tests/") and rel.endsWith(".rs"):
    let stem = rel["tests/".len ..< rel.len - ".rs".len]
    if "/" notin stem:
      return stem
    let target = stem.split('/')[0]
    if fileExists(projectRoot / "tests" / target / "main.rs"):
      return target
  ""

proc binaryTargetName(projectRoot, filePath: string): string =
  ## Cargo's auto-discovered binary target owning a file under `src/bin/`.
  let rel = normalizedRelative(projectRoot, filePath)
  if rel.startsWith("src/bin/") and rel.endsWith(".rs"):
    result = rel["src/bin/".len ..< rel.len - ".rs".len].split('/')[0]

proc crateHasLibrary(projectRoot: string): bool =
  ## A library target exists by Cargo's `src/lib.rs` convention or by an
  ## explicit `[lib]` section. Only that one header matters here, so this does
  ## not need a TOML parser.
  if fileExists(projectRoot / "src" / "lib.rs"):
    return true
  let manifest = projectRoot / "Cargo.toml"
  fileExists(manifest) and
    readFile(manifest).splitLines.anyIt(it.strip == "[lib]")

proc canonicalPath(path: string): string =
  ## `path` with symlinks resolved, because Cargo reports resolved paths and a
  ## project root may reach it through one (`/var` is `/private/var` on macOS).
  try:
    expandFilename(path)
  except OSError:
    absolutePath(path)

proc parseCargoLayout*(metadataOutput, projectRoot: string): CargoLayout =
  ## The package rooted at `projectRoot` out of `cargo metadata` output, with
  ## its targets. Anything unreadable yields `known = false`, which sends the
  ## caller back to the path conventions rather than to a wrong answer.
  ## https://doc.rust-lang.org/cargo/commands/cargo-metadata.html#json-format
  ##
  ## The document is one line. `process_exec` merges stderr into the stream,
  ## so a manifest warning can sit beside it and must not make it unreadable.
  let manifest = canonicalPath(projectRoot / "Cargo.toml")
  let lines = metadataOutput.splitLines.filterIt(it.startsWith("{"))
  if lines.len == 0:
    return CargoLayout()
  try:
    let root = parseJson(lines[^1])
    for package in root["packages"].getElems:
      if canonicalPath(package["manifest_path"].getStr) != manifest:
        continue
      result.packageName = package["name"].getStr
      result.workspaceMembers = root["workspace_members"].len
      for target in package["targets"].getElems:
        result.targets.add CargoTarget(
          name: target["name"].getStr,
          kinds: target["kind"].getElems.mapIt(it.getStr),
          srcPath: canonicalPath(target["src_path"].getStr))
      result.known = true
      return
  except JsonParsingError, KeyError, ValueError:
    return CargoLayout()

proc readCargoLayout(projectRoot: string): CargoLayout =
  ## Ask Cargo which targets the package has. `[lib]`, `[[bin]]` and `[[test]]`
  ## may rename a target or move its file, `autobins`/`autotests` may remove
  ## one, and a workspace may redirect the default package, so no path
  ## convention can answer this. `--no-deps` needs no resolution or network.
  {.cast(gcsafe).}:
    try:
      let probe = execCaptured(
        @["cargo", "metadata", "--no-deps", "--format-version", "1"],
        cwd = projectRoot)
      if probe.exitCode == 0:
        result = parseCargoLayout(probe.output, projectRoot)
    except CatchableError:
      # No usable cargo here, as on the Nix-fallback route: conventions decide.
      result = CargoLayout()

proc targetOwning(layout: CargoLayout; file: string): Option[CargoTarget] =
  ## The test-capable target whose crate root is `file`.
  let wanted = canonicalPath(file)
  for target in layout.targets:
    if target.srcPath == wanted and target.kinds.anyIt(it in RunnableKinds):
      return some(target)

proc conventionalCrateRoot(projectRoot, filePath: string): string =
  ## The crate root that compiles a file which is not itself a root: the
  ## `main.rs` of its `tests/<x>/` or `src/bin/<x>/` directory. Empty when the
  ## path convention names none.
  let rel = normalizedRelative(projectRoot, filePath)
  for prefix in ["tests/", "src/bin/"]:
    if rel.startsWith(prefix):
      let parts = rel[prefix.len .. ^1].split('/')
      if parts.len > 1:
        return projectRoot / prefix / parts[0] / "main.rs"

proc targetArgsFor(target: CargoTarget): seq[string] =
  if "test" in target.kinds:
    @["--test", target.name]
  elif "bin" in target.kinds:
    @["--bin", target.name]
  else:
    @["--lib"]

proc layoutTargetArgs(layout: CargoLayout;
    projectRoot, filePath: string): seq[string] =
  ## The target selection Cargo's own target list gives for `filePath`. A
  ## binary is always named: `--bins` would also run any other binary that has
  ## a test of the same name, and its pass would be credited to this file.
  var owner = layout.targetOwning(filePath)
  let crateRoot = conventionalCrateRoot(projectRoot, filePath)
  if owner.isNone and crateRoot.len > 0:
    owner = layout.targetOwning(crateRoot)
  if owner.isSome:
    return targetArgsFor(owner.get)
  # A module file. It belongs to the library when there is one, then to the
  # package's default binary. Neither may be right, and that is safe: a
  # target not holding the test matches nothing, and `runRust` reports that as
  # skipped.
  if layout.targets.anyIt(it.kinds.anyIt(it in LibraryKinds)):
    return @["--lib"]
  let mainBinary = layout.targetOwning(projectRoot / "src" / "main.rs")
  if mainBinary.isSome:
    return targetArgsFor(mainBinary.get)
  @["--bins"]

proc cargoTargetArgs(projectRoot, filePath: string;
    layout: CargoLayout): seq[string] =
  ## The Cargo target selection for one source file. `--lib` is not a safe
  ## default: in a package without a library Cargo refuses it outright, which
  ## reports a passing test as failed, and for a file compiled into another
  ## target it runs a binary that does not contain the test. Cargo's target
  ## list decides when it is available. The path conventions below are the
  ## fallback for when it is not.
  if layout.known:
    return layoutTargetArgs(layout, projectRoot, filePath)
  let integration = integrationTargetName(projectRoot, filePath)
  if integration.len > 0:
    return @["--test", integration]
  let binary = binaryTargetName(projectRoot, filePath)
  if binary.len > 0:
    return @["--bin", binary]
  let rel = normalizedRelative(projectRoot, filePath)
  if rel != "src/main.rs" and crateHasLibrary(projectRoot):
    @["--lib"]
  else:
    @["--bins"]

proc buildRustCommand*(projectRoot, filePath, selector: string;
    scope: RustCommandScope; layout: CargoLayout): seq[string] =
  ## The `cargo test` argv for `scope`. A workspace names the package, because
  ## `default-members` can otherwise point the command at a different one.
  result = @["cargo", "test"]
  if layout.known and layout.workspaceMembers > 1:
    result.add @["--package", layout.packageName]
  case scope
  of rcsProject:
    discard
  of rcsFile:
    result.add cargoTargetArgs(projectRoot, filePath, layout)
  of rcsSingle:
    result.add cargoTargetArgs(projectRoot, filePath, layout)
    result.add @["--", selector, "--exact", "--include-ignored"]

proc buildRustCommand*(projectRoot, filePath, selector: string;
    scope: RustCommandScope): seq[string] =
  ## `buildRustCommand` with the project's layout read from Cargo.
  buildRustCommand(projectRoot, filePath, selector, scope,
    readCargoLayout(projectRoot))

proc libtestPassedCount*(output: string): int =
  ## The total of `N passed` over every libtest summary line in `output`.
  ## One `cargo test` prints one `test result:` line per test binary it runs.
  ##
  ## Stable libtest has no machine-readable reporter (see
  ## `framework_research/rust-libtest.md`), so this reads the human summary:
  ## `test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 2 filtered out`.
  ## Anchoring on ` passed;` rather than on the word after the colon keeps it
  ## working when libtest colours `ok`, as `--color=always` does. A line with
  ## an unreadable count is evidence of nothing and adds nothing.
  ##
  ## The line must START with the marker. Cargo's stream also carries text the
  ## project controls: rustc quotes source lines in its warnings (`3 | ...`)
  ## and a build script's `cargo:warning` is echoed behind a `warning:` prefix,
  ## so a marker anywhere in a line can be a comment in the code under test.
  for line in output.splitLines:
    if not line.startsWith("test result:"):
      continue
    let countEnd = line.find(" passed;")
    if countEnd < 0:
      continue
    var countStart = countEnd
    while countStart > 0 and line[countStart - 1] in Digits:
      dec countStart
    try:
      result += parseInt(line[countStart ..< countEnd])
    except ValueError:
      discard

proc libtestRanSelector*(output, selector: string): bool =
  ## Whether libtest printed a result line for exactly `selector`:
  ## `test tests::passes ... ok`, or `test tests::p - should panic ... ok`.
  ##
  ## Only the prefix is read. A test writing to the real stdout splits the line
  ## (`test tests::passes ... noise`, then `ok` alone), and the exit code has
  ## already ruled out a failure. The trailing space stops `tests::pass` from
  ## matching `tests::passes`.
  let prefix = "test " & selector & " "
  output.splitLines.anyIt(it.startsWith(prefix))

proc cargoRefusedForFeatures*(output: string): bool =
  ## Whether Cargo refused to build a target over its `required-features`:
  ## ``error: target `x` in package `y` requires the features: `z` ``.
  output.splitLines.anyIt(it.startsWith("error: target `") and
    "requires the features:" in it)

proc finishSkipped(run: var ProviderResult[seq[TestEvent]]; reason: string;
    scope: TestScope) =
  ## Rewrite a unit's outcome to skipped: no test ran, so it is evidence of
  ## nothing in either direction. The failure event and the error diagnostic of
  ## a refused command go with it, and the reason stays where a reader looks.
  run.value.keepItIf(it.kind != tekFailure)
  for event in run.value.mitems:
    if event.kind in {tekTestFinished, tekRunFinished}:
      event.status = some(tsSkipped)
      event.message = reason
  run.diagnostics = @[diagnostic(dsWarning, reason, scope.file)]

proc notImplementedRecord(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ProviderResult[seq[TestEvent]](
    diagnostics: @[diagnostic(dsWarning, "Rust libtest trace recording is not wired in M6; use command construction for run-only support", scope.file)],
    value: @[])

proc runRust(scope: TestScope): ProviderResult[seq[TestEvent]] {.gcsafe.} =
  ## Execute Cargo/libtest at the granularity the orchestrator requested, and
  ## report a pass only on libtest's own evidence that a test passed.
  ##
  ## **Exit code 0 is not that evidence.** `cargo test -- <name> --exact` exits
  ## 0 with `running 0 tests` when nothing matches, and matching nothing is
  ## reachable from correct input: discovery reads source text, so a test under
  ## `#[cfg(windows)]` or a disabled feature is discovered and never compiled.
  ## Reporting that as a pass would put a test that did not run into a
  ## certificate, which test-certificates-spec `Standard.md` §8 forbids
  ## ("producers MUST NOT claim targets that did not run"). Such a unit
  ## finishes `tsSkipped`, the status `summarize` and `recordUnitResult` both
  ## refuse to count as evidence. The rule holds for every scope. It also
  ## covers a `harness = false` target, whose output has no libtest summary,
  ## and output so large the capture bound cut the summary off: in both the
  ## provider cannot show that a test passed.
  ##
  ## A single-test scope must also find the selector's own result line, so a
  ## `harness = false` target that ignores the selector and prints a summary of
  ## its own attests nothing about the discovered test. A file or project scope
  ## has no one selector, and its summary says only that some test passed. The
  ## orchestrator dispatches single-test scopes.
  ##
  ## Any non-zero exit stays a failure from `runCommand`, including a build
  ## error that ran no test, with one exception: Cargo refusing a target whose
  ## `required-features` are off. That is a `cfg(feature = ...)` gate at target
  ## level, so it finishes the way a gated test does. One `tekTestFinished`
  ## stands for the whole scope.
  let commandScope =
    case scope.kind
    of tskProject: rcsProject
    of tskFile: rcsFile
    of tskSingle: rcsSingle
  result = runCommand(RustLibtestProviderId, scope,
    buildRustCommand(scope.projectRoot, scope.file, scope.selector,
      commandScope), @RustLibtestNixPackages)

  var
    output = ""
    reportedPass = false
  for event in result.value:
    if event.kind == tekOutput:
      output.add event.output
    elif event.kind == tekTestFinished and event.status == some(tsPassed):
      reportedPass = true
  if not reportedPass:
    if cargoRefusedForFeatures(output):
      result.finishSkipped("cargo did not build the target of selector '" &
        scope.selector & "': it needs features this run does not enable",
        scope)
    return
  if libtestPassedCount(output) > 0 and
      (scope.kind != tskSingle or libtestRanSelector(output, scope.selector)):
    return

  result.finishSkipped("cargo test exited 0 but libtest reported no passed " &
    "test for selector '" & scope.selector & "': it matched no compiled " &
    "test (a cfg-gated test, or one outside the selected Cargo target)", scope)

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
  provider.run = runRust
  provider.record = notImplementedRecord
  provider.parseEvent = parseEventUnsupported
  provider.mapTraceEntryPoints = mapTraceUnsupported
  M1Provider(
    provider: provider,
    relevantConfigFiles: @["Cargo.toml", "Cargo.lock", ".cargo/config.toml"])

proc newRustLibtestProviderRegistry*(): ProviderRegistry =
  ProviderRegistry(providers: @[newRustLibtestM1Provider()])
