## Rust provider for `ct test`, driving `cargo test` and libtest.
##
## DISCOVERY ASKS CARGO WHAT EXISTS
## --------------------------------
## A libtest selector is the test's module path inside the binary that
## compiles it, and nothing in a source file's own path says which binary that
## is or where its module tree starts. `[lib]` and `[[bin]]` may move a crate
## root anywhere, a module belongs to whichever target's `mod` declarations
## reach it, `#[path]` relocates a module file, and a virtual workspace has no
## package at its root at all. Deriving the selector from the file path got
## all of these wrong: the units matched no compiled test and ran nothing, or
## were never discovered.
##
## So discovery is layered, cheapest first:
##
## 1. `cargo metadata --no-deps` names every workspace member below the
##    project root and every target's real root file and edition
##    (https://doc.rust-lang.org/cargo/commands/cargo-metadata.html).
## 2. From each target root, the `mod` declarations are followed the way rustc
##    resolves them (https://doc.rust-lang.org/reference/items/modules.html),
##    which gives every compiled file its owning target and module path. This
##    reads source only, so the file-scoped route (`--file`, editor gutters)
##    uses it without compiling anything.
## 3. Project discovery then builds the test targets
##    (`cargo test --no-run --message-format=json`) and asks each binary for
##    `--list`, and rustdoc for its doc tests. That is the ground truth: a
##    selector spelled differently is replaced by the one the binary prints,
##    doc tests become units, and a listed test no source declaration places
##    (a macro-generated one) is reported in a diagnostic rather than omitted
##    in silence.
##
## Without a usable `cargo`, as on the Nix-fallback route, the path
## conventions below still decide, as they did before.

import std/[algorithm, json, options, os, sequtils, sets, strutils, tables]

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
  RunnableKinds = LibraryKinds & @["bin", "test", "example", "bench"]
  DocTestTag* = "doctest"
  ListTimeoutMs = 120_000
    ## A `harness = false` target's `--list` runs the project's own `main`,
    ## which may do anything, so listing is bounded.

  # Identifiers rustc's path printing writes with `r#` because they are
  # reserved in the crate's edition (`Ident::is_raw_guess`). Weak keywords
  # (`union`, `macro_rules`, `raw`, ...) are not reserved and print bare.
  # https://doc.rust-lang.org/reference/keywords.html
  ReservedAlways = ["as", "break", "const", "continue", "crate", "else",
    "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
    "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
    "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
    "where", "while", "abstract", "become", "box", "do", "final", "macro",
    "override", "priv", "typeof", "unsized", "virtual", "yield"]
  ReservedSince2018 = ["async", "await", "dyn", "try"]
  ReservedSince2024 = ["gen"]

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
    edition*: string
    test*: bool     ## `cargo test` builds and runs this target's tests
    doctest*: bool  ## `cargo test` runs this target's doc tests

  CargoPackage* = object
    name*: string
    manifestPath*: string
    targets*: seq[CargoTarget]

  CargoLayout* = object
    ## What Cargo says about the workspace members at or below the project
    ## root. `known = false` means Cargo could not be asked, or named none.
    known*: bool
    workspaceRoot*: string
    workspaceMembers*: int
    packages*: seq[CargoPackage]

  ModuleOwner* = object
    ## The target a source file is compiled into, and its module path there.
    package*: CargoPackage
    target*: CargoTarget
    modulePath*: seq[string]

  RustTestDecl* = object
    name*: string     ## the function name without `r#`
    written*: string  ## the function name as written
    modules*: seq[string]  ## enclosing inline modules, as written
    selector*: string
    line*: int
    column*: int
    endColumn*: int
    attrLine*: int
    ignored*: bool
    asyncRuntime*: string

  RustModDecl* = object
    ## An out-of-line `mod name;` and where it sits in its file.
    name*: string             ## as written
    inlineNames*: seq[string] ## enclosing inline modules, as written
    inlineDirs*: seq[string]  ## their directory components
    pathAttr*: string         ## the `#[path = "..."]` value, if any

  RustScan* = object
    tests*: seq[RustTestDecl]
    mods*: seq[RustModDecl]

  RustAttr = object
    name: string
    line: int
    text: string

  InlineModule = object
    name: string
    dir: string
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

proc canonicalPath(path: string): string =
  ## `path` with symlinks resolved, because Cargo reports resolved paths and a
  ## project root may reach it through one (`/var` is `/private/var` on macOS).
  try:
    expandFilename(path)
  except OSError:
    absolutePath(path)

proc isWithin(path, root: string): bool =
  path == root or path.startsWith(root & DirSep)

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

proc isCharLiteral(content: string; quote: int): bool =
  ## Whether the `'` at `quote` opens a character literal rather than a
  ## lifetime or label. A literal is one escape or one code point followed by
  ## `'`; `'a` in `<'a>` is followed by more identifier text. Treating every
  ## `'` as a literal masked `{ x: &'` in `struct S<'a> { x: &'a u8 }`,
  ## hiding a brace and corrupting every module path after it.
  var j = quote + 1
  if j >= content.len or content[j] == '\n':
    return false
  if content[j] == '\\':
    return true
  let lead = ord(content[j])
  j += (if lead < 0x80: 1
        elif lead shr 5 == 0b110: 2
        elif lead shr 4 == 0b1110: 3
        elif lead shr 3 == 0b11110: 4
        else: 1)
  j < content.len and content[j] == '\''

proc sanitizeRust*(content: string): string =
  ## `content` with comments, strings and character literals blanked out,
  ## keeping every newline and every offset, so positions found in the result
  ## index the original text too.
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
      if not isCharLiteral(content, i):
        inc i
        continue
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

proc bareIdent*(written: string): string =
  ## An identifier without its raw prefix: `r#try` is `try`.
  if written.startsWith("r#"): written[2 .. ^1] else: written

proc editionYear(edition: string): int =
  ## Cargo's default edition is 2015 when a manifest names none.
  try:
    parseInt(edition)
  except ValueError:
    2015

proc libtestSegment*(written, edition: string): string =
  ## One path segment as libtest prints it. rustc keeps `r#` only where the
  ## bare word is reserved in the crate's edition: `r#try` stays `r#try` in
  ## 2018+ and prints `try` in 2015, and `r#plain` always prints `plain`.
  if not written.startsWith("r#"):
    return written
  let
    bare = bareIdent(written)
    year = editionYear(edition)
  if bare in ReservedAlways or (year >= 2018 and bare in ReservedSince2018) or
      (year >= 2024 and bare in ReservedSince2024):
    written
  else:
    bare

proc readIdentAt(text: string; start: int; ident: var string;
    nextPos: var int): bool =
  ## The identifier at `start` as written, `r#` included.
  var i = start
  if i + 2 < text.len and text[i] == 'r' and text[i + 1] == '#' and
      isIdentStart(text[i + 2]):
    i += 2
  elif i >= text.len or not isIdentStart(text[i]):
    return false
  inc i
  while i < text.len and isIdentChar(text[i]):
    inc i
  ident = text[start ..< i]
  nextPos = i
  true

proc attrPath(text: string): string =
  ## The attribute's path: `tokio::test` from `tokio::test(flavor = ...)`.
  var i = 0
  while i < text.len and text[i] in Whitespace:
    inc i
  let start = i
  while i < text.len and (isIdentChar(text[i]) or text[i] == ':'):
    inc i
  text[start ..< i]

proc attrStringValue(text: string): string =
  ## The string of `path = "..."`, read from the unsanitized text.
  let first = text.find('"')
  let last = text.rfind('"')
  if first >= 0 and last > first:
    result = text[first + 1 ..< last]

proc attrIsTest(name: string): bool =
  name == "test" or name == "tokio::test" or name == "async_std::test" or
    name == "actix_rt::test" or name == "actix_web::test"

proc asyncRuntimeFor(name: string): string =
  case name
  of "tokio::test": "tokio"
  of "async_std::test": "async-std"
  of "actix_rt::test", "actix_web::test": "actix"
  else: ""

proc scanRust*(content: string): RustScan =
  ## The test functions and out-of-line module declarations of one file.
  ##
  ## Tokens, not lines: `#[test] fn one_line() {}` and an attribute spread
  ## over several lines are both one declaration. Pending attributes attach
  ## to the next `fn` or `mod`, and `;`, `{` and `}` drop them, so an
  ## attribute on a struct never reaches a later function.
  let s = sanitizeRust(content)
  var
    i = 0
    line = 1
    lineStart = 0
    depth = 0
    inline: seq[InlineModule] = @[]
    pending: seq[RustAttr] = @[]

  proc skipSpace(k: var int) =
    while k < s.len and s[k] in Whitespace:
      if s[k] == '\n':
        inc line
        lineStart = k + 1
      inc k

  while i < s.len:
    let c = s[i]
    if c == '\n':
      inc line
      lineStart = i + 1
      inc i
    elif c == '#' and i + 1 < s.len and (s[i + 1] == '[' or
        (s[i + 1] == '!' and i + 2 < s.len and s[i + 2] == '[')):
      let
        inner = s[i + 1] == '!'
        open = if inner: i + 2 else: i + 1
        attrLine = line
      var
        j = open + 1
        brackets = 1
      while j < s.len and brackets > 0:
        case s[j]
        of '[': inc brackets
        of ']': dec brackets
        of '\n':
          inc line
          lineStart = j + 1
        else: discard
        inc j
      if not inner:
        let close = max(open + 1, j - 1)
        pending.add RustAttr(name: attrPath(s[open + 1 ..< close]),
          line: attrLine, text: content[open + 1 ..< close])
      i = j
    elif c == '{':
      inc depth
      pending.setLen 0
      inc i
    elif c == '}':
      dec depth
      while inline.len > 0 and depth < inline[^1].closeDepth:
        discard inline.pop()
      pending.setLen 0
      inc i
    elif c == ';':
      pending.setLen 0
      inc i
    elif isIdentStart(c) and (i == 0 or not isIdentChar(s[i - 1])):
      var
        word = ""
        next = i
      discard readIdentAt(s, i, word, next)
      let
        wordLine = line
        wordColumn = i - lineStart + 1
      i = next
      if word == "fn":
        var k = i
        skipSpace(k)
        var name = ""
        if readIdentAt(s, k, name, next):
          var
            testAttrLine = 0
            ignored = false
            runtime = ""
          for attr in pending:
            if attrIsTest(attr.name):
              if testAttrLine == 0:
                testAttrLine = attr.line
              if runtime.len == 0:
                runtime = asyncRuntimeFor(attr.name)
            elif attr.name == "ignore":
              ignored = true
          if testAttrLine > 0:
            result.tests.add RustTestDecl(
              name: bareIdent(name),
              written: name,
              modules: inline.mapIt(it.name),
              line: line,
              column: (if line == wordLine: wordColumn else: 1),
              endColumn: next - lineStart,
              attrLine: testAttrLine,
              ignored: ignored,
              asyncRuntime: runtime)
          i = next
        pending.setLen 0
      elif word == "mod":
        var k = i
        skipSpace(k)
        var name = ""
        if readIdentAt(s, k, name, next):
          var pathAttr = ""
          for attr in pending:
            if attr.name == "path":
              pathAttr = attrStringValue(attr.text)
          k = next
          skipSpace(k)
          if k < s.len and s[k] == ';':
            result.mods.add RustModDecl(name: name,
              inlineNames: inline.mapIt(it.name),
              inlineDirs: inline.mapIt(it.dir), pathAttr: pathAttr)
          elif k < s.len and s[k] == '{':
            inline.add InlineModule(name: name,
              dir: (if pathAttr.len > 0: pathAttr else: bareIdent(name)),
              closeDepth: depth + 1)
          i = k
        pending.setLen 0
    else:
      inc i

proc selectorFor(prefix, modules: seq[string]; name: string): string =
  var parts: seq[string] = @[]
  parts.add prefix
  parts.add modules
  parts.add name
  parts.filterIt(it.len > 0).join("::")

proc withSelectors(scan: RustScan; prefix: seq[string];
    edition: string): seq[RustTestDecl] =
  for decl in scan.tests:
    var located = decl
    located.selector = selectorFor(prefix,
      decl.modules.mapIt(libtestSegment(it, edition)),
      libtestSegment(decl.written, edition))
    result.add located

proc modulePathParts(stem: string): seq[string] =
  ## The module path of a file below a crate root, from its slash-separated
  ## stem. `mod.rs` names its directory, so it adds no segment of its own.
  for part in stem.split('/'):
    if part != "mod":
      result.add part

proc fileModulePrefix(projectRoot, filePath: string): seq[string] =
  ## The path-convention guess at the module path of `filePath`, for when
  ## Cargo cannot be asked. Each target is its own crate, so the path starts
  ## at THAT target's root: a directory that only selects a target
  ## (`src/bin/<x>/`, `tests/<x>/`) is not a module.
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

proc manifestEdition(projectRoot: string): string =
  ## The `edition` of `projectRoot/Cargo.toml`, for the convention route.
  result = "2015"
  try:
    for raw in readFile(projectRoot / "Cargo.toml").splitLines:
      let line = raw.strip
      if line.startsWith("edition") and '=' in line:
        let value = attrStringValue(line)
        if value.len > 0:
          return value
  except IOError, OSError:
    discard

proc parseRustTestDeclarations*(projectRoot, filePath,
    content: string): seq[RustTestDecl] =
  ## Test declarations with path-convention selectors: the route taken when
  ## Cargo cannot say which target compiles `filePath`.
  withSelectors(scanRust(content), fileModulePrefix(projectRoot, filePath),
    manifestEdition(projectRoot))

proc targetPriority(target: CargoTarget): int =
  ## The order in which targets claim a module file that several of them
  ## compile. The library comes first, as `cargo test --lib` always did.
  if target.kinds.anyIt(it in LibraryKinds): 0
  elif "bin" in target.kinds: 1
  elif "test" in target.kinds: 2
  elif "example" in target.kinds: 3
  else: 4

proc testTargets*(package: CargoPackage): seq[CargoTarget] =
  ## The targets `cargo test` builds a test harness for, library first.
  result = package.targets.filterIt(it.test and
    it.kinds.anyIt(it in RunnableKinds))
  result.sort(proc(a, b: CargoTarget): int =
    cmp(targetPriority(a), targetPriority(b)))

proc moduleFiles*(target: CargoTarget): seq[tuple[file: string;
    modulePath: seq[string]]] =
  ## Every file `target` compiles, with its module path, found the way rustc
  ## resolves `mod name;`: beside a crate root or `mod.rs`, in a directory
  ## named after any other file, `#[path]` relative to the declaring file's
  ## directory (inline modules adding their own components), and a
  ## `#[path]`-loaded file owning its directory like a `mod.rs`.
  ## https://doc.rust-lang.org/reference/items/modules.html#module-source-filenames
  ##
  ## `#[cfg]` is not evaluated: a gated module is followed, and its tests are
  ## units that `runRust` reports skipped when they were not compiled.
  type Pending = tuple[file: string; modulePath: seq[string]; ownsDir: bool]
  var
    queue: seq[Pending] = @[(target.srcPath, newSeq[string](), true)]
    seen = initHashSet[string]()
    next = 0
  while next < queue.len:
    let entry = queue[next]
    inc next
    if entry.file in seen:
      continue
    seen.incl entry.file
    result.add (entry.file, entry.modulePath)
    var content = ""
    try:
      content = readFile(entry.file)
    except IOError, OSError:
      continue
    let
      dir = parentDir(entry.file)
      childDir =
        if entry.ownsDir: dir
        else: dir / splitFile(entry.file).name
    for decl in scanRust(content).mods:
      var
        base = childDir
        file = ""
        ownsDir = false
      for component in decl.inlineDirs:
        base = base / component
      if decl.pathAttr.len > 0:
        file = (if decl.inlineDirs.len == 0: dir else: base) / decl.pathAttr
        ownsDir = true
      elif fileExists(base / bareIdent(decl.name) & ".rs"):
        file = base / bareIdent(decl.name) & ".rs"
      elif fileExists(base / bareIdent(decl.name) / "mod.rs"):
        file = base / bareIdent(decl.name) / "mod.rs"
        ownsDir = true
      if file.len == 0 or not fileExists(file):
        continue
      queue.add (canonicalPath(file),
        entry.modulePath &
          decl.inlineNames.mapIt(libtestSegment(it, target.edition)) &
          libtestSegment(decl.name, target.edition),
        ownsDir)

proc moduleOwners*(layout: CargoLayout): OrderedTable[string, ModuleOwner] =
  ## Every compiled file of every package, keyed by its canonical path. A
  ## file several targets compile belongs to the first by `targetPriority`.
  for package in layout.packages:
    for target in package.testTargets:
      for (file, modulePath) in moduleFiles(target):
        if file notin result:
          result[file] = ModuleOwner(package: package, target: target,
            modulePath: modulePath)

proc ownerOf*(layout: CargoLayout; filePath: string): Option[ModuleOwner] =
  let wanted = canonicalPath(filePath)
  for package in layout.packages:
    for target in package.testTargets:
      for (file, modulePath) in moduleFiles(target):
        if file == wanted:
          return some(ModuleOwner(package: package, target: target,
            modulePath: modulePath))

proc packageDir(package: CargoPackage): string =
  parentDir(package.manifestPath)

proc packageContaining(layout: CargoLayout;
    filePath: string): Option[CargoPackage] =
  ## The innermost package whose directory holds `filePath`.
  let wanted = canonicalPath(filePath)
  var best = -1
  for index, package in layout.packages:
    if wanted.isWithin(package.packageDir) and (best < 0 or
        package.packageDir.len > layout.packages[best].packageDir.len):
      best = index
  if best >= 0:
    result = some(layout.packages[best])

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

proc itemFromDecl(info: TestProviderInfo; relative: string;
    decl: RustTestDecl; detail: string): TestItem =
  var tags = @["rust", "libtest", "cargo-test"]
  if decl.ignored:
    tags.add "ignore"
  if decl.asyncRuntime.len > 0:
    tags.add decl.asyncRuntime
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
      endColumn: max(decl.endColumn, 1)),
    selector: decl.selector,
    parentId: "",
    tags: tags,
    location: LocationProvenance(
      source: lskParser,
      detail: detail,
      confidence: lcHigh),
    stale: false,
    staleReason: "")

const
  ConventionDetail = "Rust source parser; module path guessed from the " &
    "file path because Cargo could not be asked"
  ModuleTreeDetail = "Rust source parser; module path from the target's " &
    "mod tree in cargo metadata"
  ReconciledDetail = "Rust source parser; selector confirmed by the " &
    "compiled test binary's --list"

proc emptyCatalog(info: TestProviderInfo): TestCatalog =
  TestCatalog(schemaVersion: TestCatalogSchemaVersion, provider: info,
    items: @[], diagnostics: @[])

proc ownedFileItems(info: TestProviderInfo; relative, filePath: string;
    owner: ModuleOwner): seq[TestItem] =
  var content = ""
  try:
    content = readFile(filePath)
  except IOError, OSError:
    return
  for decl in withSelectors(scanRust(content), owner.modulePath,
      owner.target.edition):
    result.add itemFromDecl(info, relative, decl, ModuleTreeDetail)

proc conventionalFileCatalog(info: TestProviderInfo;
    projectRoot, filePath: string): TestCatalog =
  result = emptyCatalog(info)
  if not isCargoRustTestFile(projectRoot, filePath):
    result.diagnostics.add diagnostic(dsInfo,
      "Rust file is outside Cargo src/ or tests/ discovery roots", filePath)
    return
  let relative = normalizedRelative(projectRoot, filePath)
  for decl in parseRustTestDeclarations(projectRoot, filePath,
      readFile(filePath)):
    result.items.add itemFromDecl(info, relative, decl, ConventionDetail)

proc parseCargoLayout*(metadataOutput, projectRoot: string): CargoLayout =
  ## The workspace members at or below `projectRoot` out of `cargo metadata`
  ## output, with their targets. Anything unreadable yields `known = false`,
  ## which sends the caller back to the path conventions rather than to a
  ## wrong answer.
  ## https://doc.rust-lang.org/cargo/commands/cargo-metadata.html#json-format
  ##
  ## The document is one line. `process_exec` merges stderr into the stream,
  ## so a manifest warning can sit beside it and must not make it unreadable.
  ## A member above the root is not this project's: a run rooted in one
  ## member of a larger workspace discovers that member only.
  let root = canonicalPath(projectRoot)
  let lines = metadataOutput.splitLines.filterIt(it.startsWith("{"))
  if lines.len == 0:
    return CargoLayout()
  try:
    let document = parseJson(lines[^1])
    result.workspaceRoot = canonicalPath(
      document{"workspace_root"}.getStr(projectRoot))
    result.workspaceMembers = document["workspace_members"].len
    for package in document["packages"].getElems:
      let manifest = canonicalPath(package["manifest_path"].getStr)
      if not parentDir(manifest).isWithin(root):
        continue
      var parsed = CargoPackage(name: package["name"].getStr,
        manifestPath: manifest)
      for target in package["targets"].getElems:
        let kinds = target["kind"].getElems.mapIt(it.getStr)
        parsed.targets.add CargoTarget(
          name: target["name"].getStr,
          kinds: kinds,
          srcPath: canonicalPath(target["src_path"].getStr),
          edition: target{"edition"}.getStr("2015"),
          # Cargo's defaults when an older Cargo omits the flags.
          test: target{"test"}.getBool(
            kinds.anyIt(it in LibraryKinds or it in ["bin", "test"])),
          doctest: target{"doctest"}.getBool(kinds.anyIt(it == "lib")))
      result.packages.add parsed
    result.known = result.packages.len > 0
  except JsonParsingError, KeyError, ValueError:
    return CargoLayout()

proc readCargoLayout(projectRoot: string): CargoLayout =
  ## Ask Cargo which packages and targets exist. `[lib]`, `[[bin]]` and
  ## `[[test]]` may rename a target or move its file, `autobins`/`autotests`
  ## may remove one, and a virtual workspace has no package at its root, so
  ## no path convention can answer this. `--no-deps` needs no resolution or
  ## network.
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

proc rustFileCatalogIn(projectRoot, filePath: string;
    layout: CargoLayout): TestCatalog =
  let info = providerInfo()
  if not layout.known:
    return conventionalFileCatalog(info, projectRoot, filePath)
  result = emptyCatalog(info)
  let owner = layout.ownerOf(filePath)
  if owner.isNone:
    result.diagnostics.add diagnostic(dsInfo,
      "Rust file is compiled into no Cargo test target: no mod declaration " &
      "reaches it from a target root", filePath)
    return
  result.items = ownedFileItems(info,
    normalizedRelative(projectRoot, filePath), filePath, owner.get)

proc rustFileCatalog*(projectRoot, filePath: string): ProviderResult[TestCatalog] =
  ## The tests of one file. Source only: it asks `cargo metadata` for the
  ## module tree but compiles nothing, so it lists no doc tests and does not
  ## reconcile against `--list`; project discovery does both.
  if not isRustFile(filePath):
    return ProviderResult[TestCatalog](
      diagnostics: @[diagnostic(dsWarning, "not a Rust source file", filePath)],
      value: emptyCatalog(providerInfo()))
  ProviderResult[TestCatalog](diagnostics: @[],
    value: rustFileCatalogIn(projectRoot, filePath,
      readCargoLayout(projectRoot)))

proc libtestListNames*(output: string): seq[string] =
  ## The names a libtest or rustdoc `--list` prints, one `<name>: test` per
  ## test. Benchmarks (`: benchmark`) and Cargo's own lines are not tests.
  ## https://doc.rust-lang.org/rustc/tests/index.html#--list
  for line in output.splitLines:
    if line.endsWith(": test"):
      result.add line[0 ..< line.len - ": test".len]

proc docTestLocation*(name: string): tuple[path: string; line: int] =
  ## The file and fence line rustdoc names a doc test by:
  ## `src/lib.rs - module::item (line 12)`, or `src/lib.rs - (line 1)` for a
  ## crate-level one. The path is relative to the workspace root. A libtest
  ## name holds no spaces, so anything else answers `("", 0)`.
  let separator = name.find(" - ")
  let open = name.rfind(" (line ")
  if separator <= 0 or open < separator or not name.endsWith(")"):
    return ("", 0)
  try:
    result = (name[0 ..< separator],
      parseInt(name[open + " (line ".len ..< name.len - 1]))
  except ValueError:
    return ("", 0)

proc isDocTestSelector*(selector: string): bool =
  docTestLocation(selector).line > 0

proc parseTestArtifacts*(output: string): Table[string, string] =
  ## The test executables in `cargo test --no-run --message-format=json`
  ## output, keyed by their target's canonical root file. A binary also built
  ## as a plain executable reports a second artifact with `profile.test`
  ## false, which is not a test harness.
  ## https://doc.rust-lang.org/cargo/reference/external-tools.html#artifact-messages
  for line in output.splitLines:
    if not line.startsWith("{"):
      continue
    try:
      let message = parseJson(line)
      if message{"reason"}.getStr == "compiler-artifact" and
          message{"executable"}.getStr.len > 0 and
          message{"profile"}{"test"}.getBool:
        result[canonicalPath(message["target"]["src_path"].getStr)] =
          message["executable"].getStr
    except JsonParsingError, KeyError, ValueError:
      discard

proc docTestItem(info: TestProviderInfo; relative, name: string;
    line: int): TestItem =
  TestItem(
    id: makeTestItemId(info.id, info.language, info.framework, relative, name),
    providerId: info.id,
    language: info.language,
    framework: info.framework,
    name: name,
    kind: tikCase,
    file: relative,
    range: SourceRange(startLine: line, startColumn: 1, endLine: line,
      endColumn: 1),
    selector: name,
    parentId: "",
    tags: @["rust", "libtest", "cargo-test", DocTestTag],
    location: LocationProvenance(source: lskFramework,
      detail: "rustdoc --list names the doc test by its fence line",
      confidence: lcExact),
    stale: false,
    staleReason: "")

proc withoutRawPrefixes(selector: string): string =
  selector.split("::").mapIt(bareIdent(it)).join("::")

proc commandTail(output: string): string =
  ## The last lines of a failed command, for a diagnostic.
  let lines = output.strip.splitLines
  lines[max(0, lines.len - 5) .. ^1].join("\n")

proc reconcileWithLibtest(catalog: var TestCatalog; projectRoot: string;
    layout: CargoLayout; owners: OrderedTable[string, ModuleOwner]) =
  ## Hold the source-derived catalog against what the compiled binaries list,
  ## and add the doc tests rustdoc lists. See the module comment.
  let info = catalog.provider
  var buildArgs = @["cargo", "test", "--no-run", "--message-format=json"]
  for package in layout.packages:
    buildArgs.add @["--package", package.name]
  let build = execCaptured(buildArgs, cwd = projectRoot)
  let artifacts = parseTestArtifacts(build.output)
  if build.exitCode != 0:
    catalog.diagnostics.add diagnostic(dsWarning,
      "cargo test --no-run exited " & $build.exitCode & ", so the targets " &
      "that did not build were not checked against their --list and their " &
      "doc tests were not discovered:\n" & commandTail(build.output))

  var
    listed = initTable[string, seq[string]]()
    unlisted: seq[string] = @[]
  for package in layout.packages:
    for target in package.testTargets:
      if target.srcPath notin artifacts:
        unlisted.add package.name & "/" & target.name
        continue
      let run = execCaptured(@[artifacts[target.srcPath], "--list"],
        cwd = package.packageDir, timeoutMs = ListTimeoutMs)
      if run.exitCode != 0 or run.timedOut:
        unlisted.add package.name & "/" & target.name
        continue
      listed[target.srcPath] = libtestListNames(run.output)
  if unlisted.len > 0 and build.exitCode == 0:
    catalog.diagnostics.add diagnostic(dsWarning,
      "no test list was read for " & unlisted.join(", ") & ", so their " &
      "selectors stay as the source parser derived them")

  var matched = initHashSet[string]()
  for item in catalog.items.mitems:
    let file = canonicalPath(projectRoot / item.file)
    if file notin owners:
      continue
    let srcPath = owners[file].target.srcPath
    if srcPath notin listed:
      continue
    var name = item.selector
    if name notin listed[srcPath]:
      # The binary spells it differently: take the binary's spelling.
      let spellings = listed[srcPath].filterIt(
        withoutRawPrefixes(it) == withoutRawPrefixes(name))
      if spellings.len != 1:
        continue
      name = spellings[0]
      item.selector = name
      item.id = makeTestItemId(info.id, info.language, info.framework,
        item.file, name)
    item.location.detail = ReconciledDetail
    matched.incl srcPath & "\0" & name

  var unplaced: seq[string] = @[]
  for srcPath, names in listed:
    for name in names:
      if srcPath & "\0" & name notin matched:
        unplaced.add name
  if unplaced.len > 0:
    catalog.diagnostics.add diagnostic(dsWarning,
      $unplaced.len & " test(s) the compiled binaries list have no source " &
      "declaration discovery can place, so they are not discovered (a " &
      "macro-generated test, or a module several targets compile): " &
      unplaced.join(", "))

  let root = canonicalPath(projectRoot)
  for package in layout.packages:
    if not package.targets.anyIt(it.doctest and
        it.kinds.anyIt(it in LibraryKinds)):
      continue
    if build.exitCode != 0 and package.targets.anyIt(
        it.kinds.anyIt(it in LibraryKinds) and it.srcPath notin artifacts):
      continue
    let doc = execCaptured(@["cargo", "test", "--doc", "--package",
      package.name, "--", "--list"], cwd = projectRoot,
      timeoutMs = ListTimeoutMs)
    if doc.exitCode != 0 or doc.timedOut:
      catalog.diagnostics.add diagnostic(dsWarning,
        "rustdoc could not list the doc tests of " & package.name &
        ", so they were not discovered:\n" & commandTail(doc.output))
      continue
    for name in libtestListNames(doc.output):
      let location = docTestLocation(name)
      if location.line == 0:
        continue
      let file = canonicalPath(layout.workspaceRoot / location.path)
      catalog.items.add docTestItem(info, normalizedRelative(root, file),
        name, location.line)

proc detectProject(projectRoot: string): ProviderResult[bool] =
  ProviderResult[bool](diagnostics: @[], value: hasCargoToml(projectRoot))

proc discoverProjectImpl(projectRoot: string;
    reconcile: bool): ProviderResult[TestCatalog] =
  let info = providerInfo()
  var catalog = emptyCatalog(info)
  let layout = readCargoLayout(projectRoot)
  if not layout.known:
    for path in rustFiles(projectRoot):
      let fileCatalog = conventionalFileCatalog(info, projectRoot, path)
      catalog.items.add fileCatalog.items
      catalog.diagnostics.add fileCatalog.diagnostics
    return ProviderResult[TestCatalog](diagnostics: @[], value: catalog)

  let
    root = canonicalPath(projectRoot)
    owners = layout.moduleOwners
  var files = toSeq(owners.keys)
  files.sort(system.cmp[string])
  for file in files:
    catalog.items.add ownedFileItems(info, normalizedRelative(root, file),
      file, owners[file])
  if reconcile:
    {.cast(gcsafe).}:
      try:
        catalog.reconcileWithLibtest(projectRoot, layout, owners)
      except CatchableError as error:
        catalog.diagnostics.add diagnostic(dsWarning,
          "could not check discovery against cargo test --list: " &
          error.msg)
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

proc targetOwning(package: CargoPackage; file: string): Option[CargoTarget] =
  ## The test-capable target whose crate root is `file`.
  let wanted = canonicalPath(file)
  for target in package.testTargets:
    if target.srcPath == wanted:
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
  elif "example" in target.kinds:
    @["--example", target.name]
  elif "bench" in target.kinds:
    @["--bench", target.name]
  else:
    @["--lib"]

proc layoutTargetArgs(package: CargoPackage; owner: Option[ModuleOwner];
    filePath: string): seq[string] =
  ## The target selection Cargo's own target list gives for `filePath`. A
  ## binary is always named: `--bins` would also run any other binary that has
  ## a test of the same name, and its pass would be credited to this file.
  if owner.isSome:
    return targetArgsFor(owner.get.target)
  # A file no `mod` declaration reaches. Neither guess below may be right, and
  # that is safe: a target not holding the test matches nothing, and
  # `runRust` reports that as skipped.
  let crateRoot = conventionalCrateRoot(package.packageDir,
    canonicalPath(filePath))
  if crateRoot.len > 0:
    let root = package.targetOwning(crateRoot)
    if root.isSome:
      return targetArgsFor(root.get)
  if package.targets.anyIt(it.kinds.anyIt(it in LibraryKinds)):
    return @["--lib"]
  let mainBinary = package.targetOwning(package.packageDir / "src" / "main.rs")
  if mainBinary.isSome:
    return targetArgsFor(mainBinary.get)
  @["--bins"]

proc conventionTargetArgs(projectRoot, filePath: string): seq[string] =
  ## The Cargo target selection for one source file when Cargo cannot be
  ## asked. `--lib` is not a safe default: in a package without a library
  ## Cargo refuses it outright, which reports a passing test as failed.
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

proc packageArgs(layout: CargoLayout; package: CargoPackage;
    projectRoot: string): seq[string] =
  ## `--package` whenever the command could reach another package: a
  ## workspace's `default-members` can redirect it, and a member below the
  ## project root (a virtual workspace's, say) is not the current package.
  if layout.workspaceMembers > 1 or
      package.packageDir != canonicalPath(projectRoot):
    @["--package", package.name]
  else:
    @[]

proc buildRustCommand*(projectRoot, filePath, selector: string;
    scope: RustCommandScope; layout: CargoLayout): seq[string] =
  ## The `cargo test` argv for `scope`.
  ##
  ## A doc test is selected by its file's path only. rustdoc splits a filter
  ## on whitespace and ORs the pieces, so no argument selects
  ## `src/lib.rs - f (line 4)` alone; `runRust` reads that test's own result
  ## line out of its file's run instead.
  result = @["cargo", "test"]
  if not layout.known:
    case scope
    of rcsProject:
      discard
    of rcsFile:
      result.add conventionTargetArgs(projectRoot, filePath)
    of rcsSingle:
      if isDocTestSelector(selector):
        result.add @["--doc", "--", docTestLocation(selector).path]
      else:
        result.add conventionTargetArgs(projectRoot, filePath)
        result.add @["--", selector, "--exact", "--include-ignored"]
    return

  if scope == rcsProject:
    let rootPackage = layout.packages.filterIt(
      it.packageDir == canonicalPath(projectRoot))
    if rootPackage.len > 0:
      result.add packageArgs(layout, rootPackage[0], projectRoot)
    return

  let owner = layout.ownerOf(filePath)
  let package =
    if owner.isSome: some(owner.get.package)
    else: layout.packageContaining(filePath)
  if package.isNone:
    # Outside every member: Cargo has no target to name for it.
    result.add conventionTargetArgs(projectRoot, filePath)
    if scope == rcsSingle:
      result.add @["--", selector, "--exact", "--include-ignored"]
    return
  result.add packageArgs(layout, package.get, projectRoot)
  if scope == rcsSingle and isDocTestSelector(selector):
    result.add @["--doc", "--", docTestLocation(selector).path]
    return
  result.add layoutTargetArgs(package.get, owner, filePath)
  if scope == rcsSingle:
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

proc libtestOwnOutcome*(output, selector: string): Option[TestResultStatus] =
  ## The status libtest printed for exactly `selector`:
  ## `test src/lib.rs - f (line 4) ... ok`, `... - compile fail ... ok`,
  ## `... FAILED` or `... ignored`. None when no such line is readable.
  let prefix = "test " & selector & " "
  for line in output.splitLines:
    if not line.startsWith(prefix):
      continue
    let marker = line.rfind(" ... ")
    if marker < 0:
      continue
    let verdict = line[marker + " ... ".len .. ^1].strip
    if verdict == "ok":
      return some(tsPassed)
    if verdict == "FAILED":
      return some(tsFailed)
    if verdict.startsWith("ignored"):
      return some(tsSkipped)

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

proc commandOutput(run: ProviderResult[seq[TestEvent]]): string =
  for event in run.value:
    if event.kind == tekOutput:
      result.add event.output

proc finishOwnOutcome(run: var ProviderResult[seq[TestEvent]];
    status: TestResultStatus; scope: TestScope; output: string) =
  ## Replace a unit's exit-code outcome with the one libtest printed for its
  ## own test, keeping the events that led up to it.
  var runId = ""
  var testId = ""
  var durationMs = 0
  for event in run.value:
    if event.kind == tekTestFinished:
      runId = event.runId
      testId = event.testId
      durationMs = event.durationMs
  run.value.keepItIf(it.kind notin {tekTestFinished, tekRunFinished,
    tekFailure})
  let message = "rustdoc reported doc test '" & scope.selector & "' " &
    (case status
     of tsPassed: "passed"
     of tsFailed: "failed"
     else: "ignored")
  run.value.add unitOutcomeEvents(RustLibtestProviderId, runId, testId,
    status, message, output, durationMs)
  run.diagnostics =
    case status
    of tsPassed: @[]
    of tsFailed: @[diagnostic(dsError, message, scope.file)]
    else: @[diagnostic(dsWarning, message, scope.file)]

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
  ## A doc test is judged on its own result line ALONE, in both directions:
  ## its command runs every doc test of the file (see `buildRustCommand`), so
  ## the exit code also answers for its siblings.
  ##
  ## Any other non-zero exit stays a failure from `runCommand`, including a
  ## build error that ran no test, with one exception: Cargo refusing a target
  ## whose `required-features` are off. That is a `cfg(feature = ...)` gate at
  ## target level, so it finishes the way a gated test does. One
  ## `tekTestFinished` stands for the whole scope.
  let commandScope =
    case scope.kind
    of tskProject: rcsProject
    of tskFile: rcsFile
    of tskSingle: rcsSingle
  result = runCommand(RustLibtestProviderId, scope,
    buildRustCommand(scope.projectRoot, scope.file, scope.selector,
      commandScope), @RustLibtestNixPackages)
  let output = result.commandOutput

  if scope.kind == tskSingle and isDocTestSelector(scope.selector):
    let own = libtestOwnOutcome(output, scope.selector)
    if own.isSome:
      result.finishOwnOutcome(own.get, scope, output)
    elif result.value.anyIt(it.kind == tekTestFinished and
        it.status == some(tsPassed)):
      result.finishSkipped("rustdoc printed no result for doc test '" &
        scope.selector & "'", scope)
    return

  let reportedPass = result.value.anyIt(it.kind == tekTestFinished and
    it.status == some(tsPassed))
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

proc newRustLibtestM1Provider*(reconcile = true): M1Provider =
  ## The provider. `reconcile = false` keeps project discovery to source and
  ## `cargo metadata`, compiling nothing: for a corpus whose dependencies may
  ## not be fetched, such as this provider's own discovery fixture.
  var provider = TestProvider(info: providerInfo())
  provider.detect = proc(projectRoot: string): ProviderResult[bool] {.gcsafe.} =
    detectProject(projectRoot)
  provider.discoverFile = proc(projectRoot, file: string): ProviderResult[TestCatalog] {.gcsafe.} =
    rustFileCatalog(projectRoot, file)
  provider.discoverProject = proc(projectRoot: string): ProviderResult[TestCatalog] {.gcsafe.} =
    discoverProjectImpl(projectRoot, reconcile)
  provider.locateTests = proc(projectRoot, file: string): ProviderResult[seq[TestItem]] {.gcsafe.} =
    locateTestsImpl(projectRoot, file)
  provider.run = runRust
  provider.record = notImplementedRecord
  provider.parseEvent = parseEventUnsupported
  provider.mapTraceEntryPoints = mapTraceUnsupported
  M1Provider(
    provider: provider,
    relevantConfigFiles: @["Cargo.toml", "Cargo.lock", ".cargo/config.toml"])

proc newRustLibtestProviderRegistry*(reconcile = true): ProviderRegistry =
  ProviderRegistry(providers: @[newRustLibtestM1Provider(reconcile)])
