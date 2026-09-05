## test_tui_facade_boundary.nim — CTUI-0.
##
## ## The rule
##
## `src/frontend/tui/app/` is the SDK-consuming half of the TUI. No module
## under it may reach `backend/stdio_backend`, `viewmodel/headless_session`,
## `std/osproc` or `std/posix`, and none may import `src/frontend/tui/host/`,
## which is the one directory holding those capabilities.
##
## This is a STRUCTURAL test, not a review convention. `headless_app.nim` says
## of itself that "this module cannot reach a `std/osproc` from where it sits,
## and `ci/test/sdk-facade-boundary.sh` is what keeps that true"; this file is
## the same sentence for the TUI, and the reason it is a Nim suite rather than
## another shell guard is the mutation arm below — the checker has to be
## callable against a tree that is not this repository.
##
## ## What the walk covers, stated exactly
##
## Every `.nim` file under `app/`, plus everything they import that RESOLVES
## INSIDE `src/frontend/tui/`. Edges that leave that tree are checked as module
## specs and not followed.
##
## ## Imports are resolved to FILES, not compared as strings
##
## This is the difference between a structural test and a spelling convention,
## and getting it wrong is how the first version of this file could be evaded.
## `config.nims` puts `src/frontend` on the Nim module path, so
##
##     import tui/host/native_host
##
## written inside `app/tui_app.nim` compiles, reaches the host layer, and names
## nothing on any forbidden-spec list. An importer-relative rule does not see
## it, because the spec is not relative to the importer.
##
## Nim resolves `import a/b` by joining the spec onto each root on the search
## path, which means a root can only succeed if it is an ANCESTOR DIRECTORY of
## the file it resolves to. So instead of enumerating the roots — a list that
## `config.nims`, `ci/lib/test-lane-files.sh` and any future `--path` can all
## extend without telling this file — `specSpellings` enumerates the ancestors
## of each host module, bounded by the tree being scanned, and that set is
## exhaustive over roots by construction. `native_host`, `host/native_host`,
## `tui/host/native_host`, `frontend/tui/host/native_host` and
## `src/frontend/tui/host/native_host` are all reported by the same rule, and
## `../host/native_host` is caught by resolving it against the importer.
##
## The same treatment is applied to the two product modules the facade
## withholds, whose files this repository does have: every spelling that
## resolves to `viewmodel/headless_session.nim` or to
## `viewmodel/backend/stdio_backend.nim` is a violation, not just the four
## spellings someone thought to write down.
##
## `std/osproc` and `std/posix` stay literal string matches, and that is not an
## oversight: they are stdlib modules with no file inside this checkout to
## resolve against, so both spellings of each are listed instead.
##
## ## THE RESIDUAL, NAMED RATHER THAN LEFT FOR THE NEXT READER TO FIND
##
## The rule above is exhaustive over module-path ROOTS. It is not exhaustive
## over LEXICAL forms, and one form escapes it: `import "tui/host/native_host"`
## is legal Nim, resolves through a `--path` root exactly as the bare spelling
## does (verified by compiling both), and is NOT reported — `importSpecs`
## yields the spec with its quotation marks still on, so it matches no host
## spelling and resolves to no file. Nothing in this repository writes the
## quoted form, and `ci/test/sdk-facade-boundary.sh`'s `nim_imports` — the
## extractor this one deliberately mirrors rather than forks — has the same
## gap, which is why closing it belongs in one change across both, with a
## fourth mutation arm, rather than here alone. Until then this file's claim is
## "every ROOT-relative spelling", not "every spelling".
##
## That boundary is deliberate and is not a weakening. What lies past
## `codetracer_embed` is `ci/test/sdk-facade-boundary.sh`'s subject: it walks
## the facade's own transitive graph — into `isonim` and `nim-everywhere` as
## well — and fails the build when a renderer, a DOM or an `osproc` is
## reachable from it. Re-walking that graph here would either duplicate that
## guard or, worse, disagree with it: the facade guard bans `osproc` but not
## `std/posix`, so a transitive walk from here would report `app/` violations
## for modules `app/` never names. The two guards compose — this one owns the
## TUI's own edges, that one owns everything past the facade — and each says so.
##
## ## The mutation arm is part of the deliverable
##
## Per codetracer-specs/Testing/Verification-Harness-Traps.md, a chain of
## passing checks is not a result: a scanner that finds nothing satisfies every
## "must not contain" assertion written over it. So this file
##
##   * asserts what the scan FOUND before asserting what it did not — the file
##     count, the edge count, and one named edge (`codetracer_embed`) that must
##     be there;
##   * copies `app/` to a temporary tree, plants `import std/osproc` in one
##     module, and requires the same checker to report exactly that;
##   * plants an `import ../host/native_host` and requires that to be reported
##     too, because the host edge is a different rule from the spec list;
##   * plants an `import tui/host/native_host` — the `src/frontend`-relative
##     spelling that an importer-relative rule cannot see, and the evasion this
##     file was found to be open to — and requires that to be reported as well;
##   * and runs the checker over the UNMUTATED copy first in every arm, so a
##     finding cannot be an artefact of the temporary tree.
##
## The temporary tree mirrors this repository's own layout
## (`<tmp>/src/frontend/tui/{app,host}`) rather than being a flat pair of
## directories. That is what makes the third arm meaningful: `tui/host/…` is
## only a spelling of the host module when there is a `src/frontend` above it
## for a module-path root to sit on.

import std/[algorithm, os, sequtils, strutils, unittest]

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling, and inside a `const` block the declaration is invisible to it.
const ExpectedAssertions = 34

const
  ForbiddenSpecs = [
    "backend/stdio_backend",
    "stdio_backend",
    "headless_session",
    "viewmodel/headless_session",
    "std/osproc",
    "osproc",
    "std/posix",
    "posix",
  ]
    ## Both the qualified and the bare spelling of each, because Nim resolves
    ## `import osproc` and `import std/osproc` to the same module and a rule
    ## that named only one of them would be satisfied by writing the other.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type
  ImportEdge = object
    ## One `import`/`from`/`include` edge, as written.
    file*: string   ## repo-relative-ish path of the importing file
    spec*: string   ## the module spec, exactly as it appears in the source

  Violation = object
    file*: string
    spec*: string
    reason*: string

  ScanResult = object
    files*: seq[string]
    edges*: seq[ImportEdge]
    violations*: seq[Violation]

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

proc importSpecs(path: string): seq[string] =
  ## Every module spec a Nim file imports.
  ##
  ## Lexical, and it mirrors `ci/test/sdk-facade-boundary.sh`'s extractor
  ## rather than inventing a second dialect: `import a`, `import a, b`,
  ## `import a/b`, `import a/[b, c]`, `from a/b import c`, `include a`,
  ## `import a as b`, `import a except c`, and the indented continuation lines
  ## a bracket list may spread over.
  result = @[]
  var pending = ""
  for rawLine in readFile(path).splitLines():
    var line = rawLine
    let hash = line.find('#')
    if hash >= 0:
      line = line[0 ..< hash]
    let trimmed = line.strip()
    if pending.len == 0:
      if trimmed.startsWith("import ") or trimmed.startsWith("from ") or
         trimmed.startsWith("include ") or trimmed == "import" or
         trimmed == "include":
        pending = trimmed
      else:
        continue
    else:
      if trimmed.len == 0:
        continue
      pending = pending & " " & trimmed
    if pending in ["import", "include", "from"]:
      continue
    if pending.count('[') != pending.count(']') or pending.endsWith(",") or
       pending.endsWith("["):
      continue

    var body = pending
    if body.startsWith("from "):
      body = body[5 .. ^1]
      let at = body.find(" import ")
      if at >= 0:
        body = body[0 ..< at]
    elif body.startsWith("import "):
      body = body[7 .. ^1]
    elif body.startsWith("include "):
      body = body[8 .. ^1]
    let exceptAt = body.find(" except ")
    if exceptAt >= 0:
      body = body[0 ..< exceptAt]

    # Split on top-level commas, then expand `prefix/[a, b]`.
    var depth = 0
    var item = ""
    var items: seq[string] = @[]
    for ch in body & ",":
      if ch == '[': inc depth
      elif ch == ']': dec depth
      if ch == ',' and depth == 0:
        if item.strip().len > 0:
          items.add(item.strip())
        item = ""
      else:
        item.add(ch)
    for raw in items:
      var spec = raw
      let asAt = spec.find(" as ")
      if asAt >= 0:
        spec = spec[0 ..< asAt]
      spec = spec.strip()
      if spec.endsWith("]") and spec.contains('['):
        let open = spec.find('[')
        var prefix = spec[0 ..< open].strip()
        if prefix.endsWith("/"):
          prefix = prefix[0 ..< prefix.len - 1].strip()
        let inner = spec[open + 1 ..< spec.rfind(']')]
        for part in inner.split(','):
          let p = part.strip()
          if p.len > 0:
            result.add(prefix & "/" & p)
      elif spec.len > 0:
        result.add(spec)
    pending = ""

proc isUnder(path, dir: string): bool =
  ## Is `path` inside `dir`?
  ##
  ## `startsWith(dir)` alone is wrong and quietly so: it makes
  ## `src/frontend/tui-notes/x.nim` look like a member of `src/frontend/tui`.
  ## The separator is what makes it a containment test rather than a prefix one.
  path == dir or path.startsWith(dir & DirSep)

proc specSpellings*(file, scanRoot: string): seq[string] =
  ## Every module spec that can resolve to `file` through Nim's module path.
  ##
  ## Nim joins an import spec onto each root on the search path, so a root can
  ## only resolve `spec` to `file` if that root is an ANCESTOR DIRECTORY of
  ## `file` and `spec` is the path from it. Enumerating the ancestors is
  ## therefore exhaustive over roots — including roots this file does not know
  ## about, which is the property that matters, because `config.nims`, the lane
  ## flags and any future `--path` all add roots without telling this test.
  ##
  ## Bounded at `scanRoot`: above the tree being scanned there is nothing this
  ## suite is entitled to make claims about, and a root above the repository
  ## would make every module in it ambiguous anyway.
  result = @[]
  let target = normalizedPath(file)
  let bound = normalizedPath(scanRoot)
  var dir = target.parentDir
  while true:
    var rel = target.relativePath(dir)
    when DirSep != '/':
      rel = rel.replace(DirSep, '/')
    if rel.endsWith(".nim"):
      rel.setLen(rel.len - len(".nim"))
    if rel.len > 0 and rel notin result:
      result.add(rel)
    let parent = dir.parentDir
    if dir == bound or parent == dir:
      break
    dir = parent

proc searchRoots(tuiTree, scanRoot: string): seq[string] =
  ## The directories an intra-tree import may be resolved against.
  ##
  ## Same argument as `specSpellings`, used for FOLLOWING edges rather than for
  ## grading them: any root that resolves to a file inside `tuiTree` is an
  ## ancestor of that file, so the chain from `tuiTree` up to `scanRoot` covers
  ## every root that can reach the tree from outside it.
  result = @[]
  var dir = normalizedPath(tuiTree)
  let bound = normalizedPath(scanRoot)
  while true:
    result.add(dir)
    let parent = dir.parentDir
    if dir == bound or parent == dir:
      break
    dir = parent

proc resolveWithin(spec, importer, tree: string; roots: seq[string]): string =
  ## Where `spec` resolves inside `tree`, or "" when it points outside it.
  ##
  ## The importer's own directory first — Nim's relative rule, and how every
  ## intra-tree import in `src/frontend/tui/` is written today — then every
  ## module-path root that could reach the tree. Both are needed: dropping the
  ## second is exactly the hole that let `import tui/host/native_host` compile
  ## with this suite green.
  for base in @[importer.parentDir] & roots:
    let candidate = normalizedPath(base / (spec & ".nim"))
    if fileExists(candidate) and candidate.isUnder(tree):
      return candidate
  ""

proc forbiddenFileSpecs(scanRoot: string; files: seq[string]): seq[string] =
  ## Every spelling of every module in `files`, for the files that exist.
  ##
  ## `files` are the product modules the Embed SDK facade withholds. They live
  ## OUTSIDE the scanned tree, so they are never reached by the traversal — but
  ## they are reachable by an import, and by more spellings than the four a
  ## reviewer would think to write down (`headless_session`,
  ## `viewmodel/headless_session`, `frontend/viewmodel/headless_session`,
  ## `src/frontend/viewmodel/headless_session`, and — via the importer — any
  ## `../…` path to the same file).
  result = @[]
  for f in files:
    if fileExists(f):
      for s in specSpellings(f, scanRoot):
        if s notin result:
          result.add(s)

proc scanAppTree*(appDir, tuiTree, hostDir, scanRoot: string;
                  facadeWithheld: seq[string] = @[]): ScanResult =
  ## Walk `appDir`, following only edges that stay inside `tuiTree`, and report
  ## every forbidden edge.
  ##
  ## Takes its roots as parameters rather than deriving them, which is what
  ## makes the mutation arms possible: the same code that grades this repository
  ## grades a planted copy of it.
  result = ScanResult(files: @[], edges: @[], violations: @[])

  # Every spelling that lands under `host/`, computed once. This is the rule
  # that replaced "the spec is written relative to the importer".
  var hostSpecs: seq[string] = @[]
  if hostDir.len > 0:
    for path in walkDirRec(hostDir):
      if path.endsWith(".nim"):
        for s in specSpellings(path, scanRoot):
          if s notin hostSpecs:
            hostSpecs.add(s)
  let withheldSpecs = forbiddenFileSpecs(scanRoot, facadeWithheld)
  let roots = searchRoots(tuiTree, scanRoot)

  var queue: seq[string] = @[]
  for path in walkDirRec(appDir):
    if path.endsWith(".nim"):
      queue.add(normalizedPath(path))
  sort(queue)
  var seen = queue
  var i = 0
  while i < queue.len:
    let file = queue[i]
    inc i
    result.files.add(file)
    for spec in importSpecs(file):
      result.edges.add(ImportEdge(file: file, spec: spec))
      var reported = false

      for forbidden in ForbiddenSpecs:
        if spec == forbidden:
          result.violations.add(Violation(
            file: file, spec: spec,
            reason: "app/ may not import '" & forbidden &
                    "'; that capability lives in src/frontend/tui/host/"))
          reported = true

      if not reported and spec in withheldSpecs:
        result.violations.add(Violation(
          file: file, spec: spec,
          reason: "app/ may not import a module the Embed SDK facade withholds" &
                  "; that capability lives in src/frontend/tui/host/"))
        reported = true

      # The host rule, by RESOLUTION rather than by spelling: either the spec
      # is one of the ancestor-relative names of a host module, or it resolves
      # against the importer to a file under `host/`.
      let resolved = resolveWithin(spec, file, tuiTree, roots)
      let hitsHost = hostDir.len > 0 and
        (spec in hostSpecs or (resolved.len > 0 and resolved.isUnder(hostDir)))
      if hitsHost:
        if not reported:
          result.violations.add(Violation(
            file: file, spec: spec,
            reason: "app/ may not import the host layer (resolves under " &
                    hostDir & ")"))
        continue

      if resolved.len == 0:
        continue
      if resolved notin seen:
        seen.add(resolved)
        queue.add(resolved)

proc describe(vs: seq[Violation]): string =
  vs.mapIt(it.file & " imports '" & it.spec & "': " & it.reason).join("; ")

proc copyTree(src, dst: string) =
  createDir(dst)
  for path in walkDirRec(src):
    let rel = path.relativePath(src)
    createDir((dst / rel).parentDir)
    copyFile(path, dst / rel)

type MutantTree = object
  ## A throwaway copy of the TUI's two layers, laid out exactly as the
  ## repository lays them out.
  ##
  ## The layout is not cosmetic. `tui/host/native_host` is only a spelling of
  ## the host module when a `src/frontend` exists above it for a module-path
  ## root to sit on, so a flat `<tmp>/{app,host}` could not host the third
  ## mutation arm at all — and an arm that cannot express the evasion is not an
  ## arm.
  root*: string     ## the scan root; stands in for the repo root
  tuiTree*: string
  appDir*: string
  hostDir*: string

proc newMutantTree(appDir, hostDir, tag: string): MutantTree =
  let tmp = getTempDir() / ("ctui0-facade-" & tag & "-" & $getCurrentProcessId())
  removeDir(tmp)
  result = MutantTree(
    root: tmp,
    tuiTree: normalizedPath(tmp / "src" / "frontend" / "tui"),
    appDir: normalizedPath(tmp / "src" / "frontend" / "tui" / "app"),
    hostDir: normalizedPath(tmp / "src" / "frontend" / "tui" / "host"))
  copyTree(appDir, result.appDir)
  copyTree(hostDir, result.hostDir)

proc scanMutant(m: MutantTree): ScanResult =
  ## Grade the mutant with the SAME checker that grades this repository.
  ## Named apart from the suite's `scan` value so method-call syntax cannot
  ## resolve to a shadowing local.
  scanAppTree(m.appDir, m.tuiTree, m.hostDir, m.root)

suite "CTUI-0: the app/ layer stays inside the Embed SDK facade":

  let root = repoRoot()
  let tuiTree = normalizedPath(root / "src" / "frontend" / "tui")
  let appDir = normalizedPath(tuiTree / "app")
  let hostDir = normalizedPath(tuiTree / "host")

  # The two modules `codetracer_embed` deliberately withholds, named as FILES
  # so that every spelling resolving to them is a violation rather than only
  # the ones written into `ForbiddenSpecs`.
  let facadeWithheld = @[
    normalizedPath(root / "src" / "frontend" / "viewmodel" / "headless_session.nim"),
    normalizedPath(root / "src" / "frontend" / "viewmodel" / "backend" /
                   "stdio_backend.nim")]

  let scan = scanAppTree(appDir, tuiTree, hostDir, root, facadeWithheld)

  test "the walk reached the app/ tree":
    # THE POSITIVE CONTROL, and it comes first because everything after it is
    # a universal quantification that an empty scan satisfies for free
    # (Verification-Harness-Traps §4). The count is asserted rather than
    # non-emptiness, because the membership is knowable: it is the set of
    # `.nim` files in the directory (§4b).
    var onDisk: seq[string] = @[]
    for path in walkDirRec(appDir):
      if path.endsWith(".nim"):
        onDisk.add(path)
    checkpoint("app/ modules on disk: " & $onDisk.len)
    checkpoint("modules walked: " & $scan.files.len)
    checkpoint("import edges read: " & $scan.edges.len)
    ck onDisk.len >= 2
    ck scan.files.len == onDisk.len
    ck scan.edges.len >= scan.files.len

  test "the extractor actually reads imports, not just files":
    # The positive twin of every negative assertion below. If `importSpecs`
    # stopped parsing — a changed dialect, a bad slice — the forbidden-edge
    # checks would go on passing over an empty set of edges, and only this
    # goes red.
    let specs = scan.edges.mapIt(it.spec)
    checkpoint("specs: " & specs.deduplicate().join(", "))
    ck "codetracer_embed" in specs
    ck "headless_app/headless_app" in specs
    ck "isonim_tui" in specs

  test "no app/ module reaches the host layer or a host capability":
    if scan.violations.len > 0:
      checkpoint(describe(scan.violations))
    ck scan.violations.len == 0

  test "host/ is NOT a declared SDK consumer":
    # The exemption, asserted from this side too. `ci/test/sdk-facade-
    # boundary.sh` discovers consumers by marker, so a `.sdk-consumer` file
    # placed at `src/frontend/tui/` — one directory up, an easy and plausible
    # mistake — would silently enrol `host/` and make that guard fail for a
    # reason nobody would connect to this rule.
    ck fileExists(appDir / ".sdk-consumer")
    ck not fileExists(hostDir / ".sdk-consumer")
    ck not fileExists(tuiTree / ".sdk-consumer")

  test "host/ really does hold the capabilities app/ may not":
    # Without this the boundary could be satisfied by a host layer that reaches
    # nothing — a rule about a distinction that had stopped existing. This is
    # the same shape as trap 4a's "positive twin": the negative assertion above
    # and this positive one run through the same extractor.
    var hostSpecs: seq[string] = @[]
    for path in walkDirRec(hostDir):
      if path.endsWith(".nim"):
        hostSpecs.add(importSpecs(path))
    checkpoint("host/ specs: " & hostSpecs.deduplicate().join(", "))
    ck "headless_session" in hostSpecs
    ck "std/posix" in hostSpecs or "posix" in hostSpecs

  test "the resolver knows every spelling the module path gives host/":
    # THE POSITIVE CONTROL ON THE RULE ITSELF, and the reason the three
    # mutation arms below are not the only evidence: they plant three
    # spellings, and this asserts that the set the checker computed is the
    # complete one those three are drawn from. A `specSpellings` that returned
    # only the basename would still make the `../host/…` arm go red, and
    # nothing else in the file would notice.
    var hostSpecs: seq[string] = @[]
    for path in walkDirRec(hostDir):
      if path.endsWith(".nim"):
        for s in specSpellings(path, root):
          if s notin hostSpecs:
            hostSpecs.add(s)
    checkpoint("host spellings: " & hostSpecs.join(", "))
    # Bare, for a `--path` pointing at `host/` itself.
    ck "native_host" in hostSpecs
    # Relative to `src/frontend/tui/`.
    ck "host/native_host" in hostSpecs
    # Relative to `src/frontend`, which `config.nims` puts on the module path.
    # THIS IS THE ONE THE FIRST VERSION OF THIS FILE COULD NOT SEE.
    ck "tui/host/native_host" in hostSpecs
    # And relative to the checkout, for a `--path:.`.
    ck "src/frontend/tui/host/native_host" in hostSpecs

  test "MUTATION: a planted 'import std/osproc' in app/ is detected":
    # THE ARM THAT PROVES THE DETECTOR DETECTS. A green run of the tests above
    # is compatible with a checker that cannot fail; this is what separates the
    # two, and it is a deliverable of CTUI-0 rather than a demonstration.
    let m = newMutantTree(appDir, hostDir, "osproc")

    # CONTROL FIRST: the copy, unmutated, must be clean. Without this a
    # positive result below could equally mean "the temporary tree confuses the
    # checker", which is a hang wearing a mutation's label.
    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "tui_app.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) & "\nimport std/osproc\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting std/osproc: " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.spec == "std/osproc")
    ck mutated.violations.anyIt(it.file == victim)
    removeDir(m.root)

  test "MUTATION: a planted importer-relative host import is detected":
    # A DIFFERENT RULE, so it needs its own arm: the spec list would not catch
    # `../host/native_host`, which names no forbidden module at all — it is
    # caught by resolving the spec against the importer, and only an arm that
    # plants it can show that half works.
    let m = newMutantTree(appDir, hostDir, "host-edge")

    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "cli.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) & "\nimport ../host/native_host\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting '../host/native_host': " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.reason.contains("host layer"))
    ck mutated.violations.anyIt(it.file == victim)
    removeDir(m.root)

  test "MUTATION: a planted 'import tui/host/native_host' is detected":
    # THE EVASION THIS FILE WAS FOUND TO BE OPEN TO, and therefore the arm that
    # matters most here. `config.nims` puts `src/frontend` on the module path,
    # so this spelling COMPILES from `app/tui_app.nim`, reaches the host layer,
    # and is relative to no importer — the earlier rule looked only at the
    # importer's own directory and reported nothing. It is caught now because
    # the checker enumerates the ancestor-relative spellings of every host
    # module instead of the one spelling the TUI happens to use.
    let m = newMutantTree(appDir, hostDir, "path-root")

    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "tui_app.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) & "\nimport tui/host/native_host\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting 'tui/host/native_host': " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.reason.contains("host layer"))
    ck mutated.violations.anyIt(it.file == victim)
    removeDir(m.root)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
