## project_definitions_dir_test.nim — PLAT-11 on a REAL disk.
##
## `src/common/project_definitions_test.nim` is the pure half: every input
## there is a literal. This file builds real directory trees in a real
## temporary directory, with real `.codetracer/` directories, a real oversized
## file, a real recording sitting beside the definitions, a real
## executable-tier file, and real source files that are then really edited.
##
## ## THE CASE THIS FILE EXISTS FOR
##
## PLAT-11's first integration test: *"Opening a repository containing
## definitions executes nothing — asserted, with a mutation arm proving the
## assertion can fail."*
##
## "Executes nothing" is a must-NOT-happen assertion, and
## Verification-Harness-Traps §4 is about exactly those: a check that looks
## for something and finds nothing passes whether or not the system works. So
## the case below carries a **planted control** — a sentinel file created by
## hand, in the same directory, observed by the same predicate — so that a
## broken observation cannot produce a clean pass.
##
## And the properties that make executing INEXPRESSIBLE are asserted
## separately and each is killable: the executable-tier file's bytes never
## enter the process, the set of files opened is the constant set, and a
## definition naming a path outside the checkout is refused. Those are what
## `run-plat11-definitions-mutations.py` aims at; "no sentinel appeared" is
## the outcome, and the three properties are the reasons.
##
## ## THE SECOND CASE THIS FILE EXISTS FOR, ADDED 2026-09-11
##
## *"A definition referencing a path outside the checkout is refused"* — which
## the lexical grammar satisfied for every spelling a definition could write,
## and which an ordinary checked-in symlink walked straight past. The two
## cases at the bottom of this file are the escape and its positive twin: a
## `vendor -> /elsewhere` link whose bytes must not come back, and a checkout
## that is ITSELF behind a symlink whose own files must still be readable.
## The second exists because the half-repair that breaks it fails in the safe
## direction (Verification-Harness-Traps §15) and would redden nothing.
##
## ## NO MOCKS
##
## Nothing is stubbed. `loadCheckoutDefinitions` is the product function, the
## directories are real, `readSourceFile` really reads, and the sentinel is a
## real path checked with a real `fileExists`. The one indirection —
## `resolve.resolveCollection`'s `sources` parameter — is fed by
## `readSourceFile`, the product's own reader, over the real tree.
##
## ## TRAP 13 (Verification-Harness-Traps §13, §13a)
##
## Every assertion helper here is a `template`.
##
## Compile and run:
##   nim c -r src/ct/launch/project_definitions_dir_test.nim

import std/[os, sets, strutils, unittest]

import ./project_definitions_dir

const ExpectedAssertions = 99

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

template ckRefused(problems: untyped; wanted: ProjectDefinitionCode) =
  inc countedAssertions
  var sawWanted = false
  for pr in problems:
    if pr.code == wanted: sawWanted = true
  if not sawWanted:
    checkpoint("wanted " & $wanted & ", got:\n" & renderAll(problems))
  check sawWanted

# ---------------------------------------------------------------------------
# A real tree
# ---------------------------------------------------------------------------

proc firstLine(sf: SourceFile): string =
  ## The first line, or the empty string when there is none.
  ##
  ## WRITTEN BECAUSE A MUTATION ARM CRASHED THE SUITE THROUGH `lines[0]`.
  ## Arm D7 makes `readSourceFile` return `present: false` for a checkout
  ## behind a symlink; the case noticed, reported `[FAILED]`, and then indexed
  ## an empty `seq` on the very next line — an `IndexDefect` that took every
  ## case AFTER it with it, including the tally. That is
  ## Verification-Harness-Traps §1a's shape and this harness's own fifth
  ## verdict (`SUITE-DIED`) arriving from the SUITE's side: a case that dies
  ## while reporting is a case whose neighbours never ran. An assertion about
  ## the first line must survive there being none.
  if sf.lines.len == 0: "" else: sf.lines[0]

proc freshRoot(name: string): string =
  result = getTempDir() / "ct-plat11-" & name & "-" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc writeDefinition(root, scope, fileName, text: string) =
  let dir = root / (if scope.len == 0: ".codetracer"
                    else: scope & "/.codetracer")
  createDir(dir)
  writeFile(dir / fileName, text)

const HostilePoints = """
schema = "codetracer.points.v1"

[[collection]]
name = "escape"

[[collection.point]]
kind = "breakpoint"
path = '../../SENTINEL'
anchor = "fn main"
"""

const HostileVisualisers = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
interpreter = "/bin/sh"
exec = "touch SENTINEL"
"""

const HostileScratchpad = """
schema = "codetracer.scratchpad.v1"

[[diff]]
match = "Matrix"
algorithm = "SENTINEL_CMD"
"""

const GoodPoints = """
schema = "codetracer.points.v1"

[[collection]]
name = "the request path"
enabled = true

[[collection.point]]
kind = "tracepoint"
path = "src/router.nim"
anchor = "proc handleRequest"
offset = "1"
line = "4"

[[collection.point]]
kind = "breakpoint"
path = "src/router.nim"
anchor = "proc handleTimeout"

[[collection.point]]
kind = "breakpoint"
path = "src/deleted.nim"
anchor = "proc gone"
"""

const RouterSource = """import std/strutils

proc handleRequest(r: Req) =
  discard
"""

# ---------------------------------------------------------------------------
# THE SYMLINK ESCAPE, and the bytes it used to bring back
# ---------------------------------------------------------------------------

const OutsideNeedle = "PRIVATE-KEY-MATERIAL-ct-plat11"
  ## A byte string that appears NOWHERE else in this repository, so "did any
  ## of the outside file's content come back" is a question with one answer
  ## rather than a substring coincidence.

const OutsideSecret = OutsideNeedle & "\nsecond line of the outside file\n"

const EscapingPoints = """
schema = "codetracer.points.v1"

[[collection]]
name = "escape"

[[collection.point]]
kind = "breakpoint"
path = "vendor/id_rsa"
anchor = "PRIVATE-KEY-MATERIAL-ct-plat11"
"""
  ## A declaration that is LEXICALLY INSIDE the checkout in every way the path
  ## grammar can check — no `..`, no leading `/`, no drive letter, no
  ## backslash — and whose anchor is a line of a file outside it. `vendor` is
  ## an ordinary checked-in symlink, which is the whole of the trick.

# ---------------------------------------------------------------------------

suite "PLAT-11: opening a repository containing definitions executes nothing":

  test "a hostile .codetracer/ is refused, and nothing in it runs":
    let root = freshRoot("hostile")
    defer: removeDir(root)
    let sentinel = root / "SENTINEL"
    let control = root / "CONTROL-SENTINEL"

    # Every string position the grammar has, pointed at the sentinel: a path
    # that escapes the checkout towards it, a key naming an interpreter and a
    # command that would create it, and an algorithm name that is a command.
    writeDefinition(root, "", "points.toml",
                    HostilePoints.replace("SENTINEL", sentinel))
    writeDefinition(root, "", "visualisers.toml",
                    HostileVisualisers.replace("SENTINEL", sentinel))
    writeDefinition(root, "", "scratchpad.toml",
                    HostileScratchpad.replace("SENTINEL_CMD",
                                              "touch " & sentinel))
    # An executable-tier file, with real bytes, marked executable, containing
    # something that WOULD run if anything ran it.
    writeFile(root / ".codetracer/visualisers.wasm",
              "#!/bin/sh\ntouch " & sentinel & "\n")
    setFilePermissions(root / ".codetracer/visualisers.wasm",
                       {fpUserRead, fpUserWrite, fpUserExec})

    let loaded = loadCheckoutDefinitions(root)

    # THE PLANTED CONTROL (Verification-Harness-Traps §4). A "must not exist"
    # assertion is satisfied by an observation that cannot see anything, so
    # the observation is demonstrated on a file that IS there, in the same
    # directory, through the same predicate, in the same run.
    writeFile(control, "the observation works")
    ck fileExists(control)
    # …and the subject.
    ck not fileExists(sentinel)

    # THE THREE PROPERTIES THAT MAKE THAT OUTCOME STRUCTURAL RATHER THAN LUCKY.
    #
    # 1. The path that escapes the checkout was refused, by type.
    ckRefused loaded.problems, pdcPathEscapesProject
    ckEq loaded.project.collections.len, 0
    # 2. `interpreter` and `exec` are not keys, so the rule carrying them is
    #    not a rule.
    ckRefused loaded.problems, pdcUnknownKey
    ckEq loaded.project.visualisers.len, 0
    # 3. An algorithm name is a member of a closed set, never a lookup.
    ckRefused loaded.problems, pdcUnknownDiffAlgorithm
    ckEq loaded.project.diffs.len, 0
    ck not loaded.isOk()

  test "the executable-tier file's BYTES never enter the process":
    # The sharpest of the three, because it is the one a mutation can flip:
    # delete the early return in `readDefinitionFile` and the `.wasm`'s
    # contents appear in `text`.
    let root = freshRoot("exec-tier")
    defer: removeDir(root)
    createDir(root / ".codetracer")
    writeFile(root / ".codetracer/visualisers.wasm",
              "#!/bin/sh\necho THE-BYTES-OF-AN-EXECUTABLE-DEFINITION\n")
    writeFile(root / ".codetracer/diffs.wasm", "\0asm\1\0\0\0")
    writeDefinition(root, "", "points.toml", GoodPoints)

    let scan = discoverProjectDefinitions(root)
    var executableFiles = 0
    for f in scan.files:
      if tierOf(f.kind) == dtExecutable:
        inc executableFiles
        checkpoint("file: " & f.path)
        # NOT "the text is not the file's contents" — the text is EMPTY. A
        # weaker assertion would pass for a reader that hashed the file, or
        # read its first line, or read it and threw most of it away.
        ckEq f.text, ""
    ckEq executableFiles, 2

    let loaded = loadCheckoutDefinitions(root)
    ck describeLoad(loaded).contains("not read")
    ck not describeLoad(loaded).contains("THE-BYTES-OF-AN-EXECUTABLE-DEFINITION")
    # AND THE DECLARATIVE TIER BESIDE IT LOADED, which is §2.1's whole point:
    # the boundary is per file, so an executable definition does not disable
    # the data next to it.
    ckEq loaded.project.collections.len, 1
    ckEq loaded.project.collections[0].points.len, 3

  test "the set of files opened is the constant set, and nothing else":
    # A repository cannot cause CodeTracer to open a file of its choosing. The
    # tree below offers six tempting alternatives in the same directory.
    let root = freshRoot("file-set")
    defer: removeDir(root)
    createDir(root / ".codetracer")
    writeDefinition(root, "", "points.toml", GoodPoints)
    # A recording, which shares this directory by existing convention.
    writeFile(root / ".codetracer/session-1.trace", "not a definition")
    # A near-miss name (a typo), an unrelated config, a dotfile, and a
    # directory shaped like a definition file.
    writeFile(root / ".codetracer/point.toml",
              "schema = \"codetracer.points.v1\"\n")
    writeFile(root / ".codetracer/config.yaml", "x: 1\n")
    writeFile(root / ".codetracer/.hidden.toml", "x = \"1\"\n")
    createDir(root / ".codetracer/visualisers.toml.d")

    let scan = discoverProjectDefinitions(root)
    var opened = initHashSet[string]()
    for f in scan.files: opened.incl f.path
    ckEq opened.len, 1
    ck ".codetracer/points.toml" in opened
    ck ".codetracer/session-1.trace" notin opened
    ck ".codetracer/point.toml" notin opened
    ck ".codetracer/config.yaml" notin opened

    # THE TYPO IS REPORTED, because a one-character mistake in a definition's
    # NAME is otherwise the most invisible failure this feature has. The
    # recording is NOT reported, because a message that fires on every
    # recording is one nobody reads.
    var strayNames = initHashSet[string]()
    for pr in scan.problems:
      if pr.code == pdnUnrecognisedDefinitionFile: strayNames.incl pr.file
    ck ".codetracer/point.toml" in strayNames
    ck ".codetracer/.hidden.toml" in strayNames
    ck ".codetracer/session-1.trace" notin strayNames
    ck ".codetracer/config.yaml" notin strayNames
    ckEq strayNames.len, 2

  test "a repository with no .codetracer/ at all is silent and ok":
    # Almost every repository. A message on every launch would be noise, and
    # noise is how a report stops being read.
    let root = freshRoot("empty")
    defer: removeDir(root)
    let loaded = loadCheckoutDefinitions(root)
    ckEq loaded.problems.len, 0
    ckEq loaded.project.collections.len, 0
    ck loaded.isOk()
    ck describeLoad(loaded).contains("0 collection(s)")

  test "an oversized definition is refused by its SIZE, before it is read":
    let root = freshRoot("oversized")
    defer: removeDir(root)
    createDir(root / ".codetracer")
    var big = "schema = \"codetracer.points.v1\"\n"
    while big.len <= MaxDefinitionBytes:
      big.add "# padding padding padding padding padding padding padding\n"
    writeFile(root / ".codetracer/points.toml", big)
    ck getFileSize(root / ".codetracer/points.toml") > MaxDefinitionBytes

    let loaded = loadCheckoutDefinitions(root)
    ckRefused loaded.problems, pdcFileTooLarge
    ckEq loaded.project.collections.len, 0
    var saidOnDisk = false
    for pr in loaded.problems:
      if pr.code == pdcFileTooLarge:
        # The refusal came from the DISK path (`getFileSize`) rather than from
        # the parser's own byte bound, which is what "before it is read"
        # means. The two messages are deliberately different strings.
        ck pr.detail.contains("bytes on disk")
        saidOnDisk = true
    ck saidOnDisk

  test "a definition in a package scope outside the checkout is refused":
    let root = freshRoot("scope-escape")
    defer: removeDir(root)
    let scan = discoverProjectDefinitions(root, ["../elsewhere", "/etc",
                                                 "ok/package"])
    ckRefused scan.problems, pdcScopeEscapesProject
    var escaped = 0
    for pr in scan.problems:
      if pr.code == pdcScopeEscapesProject: inc escaped
    ckEq escaped, 2

# ---------------------------------------------------------------------------

suite "PLAT-11: monorepo composition, on a real tree":

  test "a nested package's definitions compose with the root's, nearer first":
    let root = freshRoot("monorepo")
    defer: removeDir(root)
    writeDefinition(root, "", "points.toml", """
schema = "codetracer.points.v1"

[[collection]]
name = "shared"

[[collection.point]]
kind = "breakpoint"
path = "src/root.nim"
anchor = "proc root"
""")
    writeDefinition(root, "packages/server", "points.toml", """
schema = "codetracer.points.v1"

[[collection]]
name = "shared"

[[collection.point]]
kind = "tracepoint"
path = "src/serve.nim"
anchor = "proc serve"

[[collection]]
name = "server only"

[[collection.point]]
kind = "breakpoint"
path = "src/serve.nim"
anchor = "proc serve"
""")
    let loaded = loadCheckoutDefinitions(root, ["packages/server"])
    ckEq loaded.project.collections.len, 2
    var byName = initHashSet[string]()
    for c in loaded.project.collections: byName.incl c.name
    ck "shared" in byName
    ck "server only" in byName
    for c in loaded.project.collections:
      if c.name == "shared":
        # The nearer one replaced the root's ENTIRELY.
        ckEq c.scope, "packages/server"
        ckEq c.points.len, 1
        ckEq c.points[0].path, "packages/server/src/serve.nim"
    var shadowNotices = 0
    for pr in loaded.problems:
      if pr.code == pdnCollectionShadowed: inc shadowNotices
    ckEq shadowNotices, 1
    ck loaded.isOk()

  test "the user's own definitions load into their own field":
    let root = freshRoot("user-sep")
    defer: removeDir(root)
    let userRoot = freshRoot("user-sep-home")
    defer: removeDir(userRoot)
    writeDefinition(root, "", "points.toml", """
schema = "codetracer.points.v1"

[[collection]]
name = "shared"

[[collection.point]]
kind = "breakpoint"
path = "a.nim"
anchor = "proc a"
""")
    writeFile(userRoot / "points.toml", """
schema = "codetracer.points.v1"

[[collection]]
name = "shared"

[[collection.point]]
kind = "tracepoint"
path = "b.nim"
anchor = "proc b"
""")
    let loaded = loadCheckoutDefinitions(root, [], userRoot)
    ckEq loaded.project.collections.len, 1
    ckEq loaded.user.collections.len, 1
    ckEq loaded.project.collections[0].points[0].path, "a.nim"
    ckEq loaded.user.collections[0].points[0].path, "b.nim"
    ckEq loaded.project.collections[0].origin, doProject
    ckEq loaded.user.collections[0].origin, doUser
    # NEITHER REPLACED THE OTHER, and nothing was reported as shadowed: the
    # user's experiment has not become a diff and has not been hidden either.
    ckEq notices(loaded.problems).len, 0
    ckEq loaded.allCollections().len, 2
    ck describeLoad(loaded).contains("your own definitions")

# ---------------------------------------------------------------------------

var resolveRoot = ""
  ## The checkout the reader below reads from.
  ##
  ## A module-level `var` and a module-level `proc`, rather than a closure
  ## over a test-local, because `unittest`'s `test` body is a `block` at
  ## module scope: a `var` declared inside one is already a global, and a
  ## `{.gcsafe.}` closure — which `resolveCollection`'s `sources` parameter
  ## requires BY DESIGN, so that no caller can pass a lookup that reads the
  ## clock — cannot capture one. Writing it this way is what lets the suite
  ## hand the resolver the PRODUCT's own reader rather than weakening the
  ## parameter's pragma to accept a test double.

proc readerForResolveRoot(path: string): SourceFile {.noSideEffect, gcsafe,
                                                      raises: [].} =
  ## `readSourceFile` under a `noSideEffect` cast.
  ##
  ## Reading a file IS a side effect, and the cast is here — in the CALLER —
  ## rather than on `readSourceFile` itself, which is the whole point of the
  ## parameter's pragma: the resolver cannot do I/O, the caller that holds the
  ## checkout can, and the cast is the visible seam between the two. The
  ## product's own call sites will make the same one, in the same place.
  {.cast(noSideEffect).}:
    {.cast(gcsafe).}:
      try: readSourceFile(resolveRoot, path)
      except CatchableError: SourceFile(present: false)

suite "PLAT-11: a collection re-resolved against a really edited file":

  test "each point reports resolved, moved or unresolvable — none is dropped":
    let root = freshRoot("resolve")
    defer: removeDir(root)
    createDir(root / "src")
    writeFile(root / "src/router.nim", RouterSource)
    writeDefinition(root, "", "points.toml", GoodPoints)

    let loaded = loadCheckoutDefinitions(root)
    ckEq loaded.project.collections.len, 1
    let c = loaded.project.collections[0]
    ckEq c.points.len, 3

    resolveRoot = root
    let sources = readerForResolveRoot

    # Before the edit: the first point resolves at the line the definition
    # recorded, which is what makes "moved" mean something afterwards.
    let before = resolveCollection(c, sources)
    ckEq before.points.len, 3
    ckEq before.points[0].outcome, prResolved
    ckEq before.points[0].line, 4

    # NOW REALLY EDIT THE FILE: two lines inserted above the anchor.
    writeFile(root / "src/router.nim",
              "# a new comment\n# and another\n" & RouterSource)
    let after = resolveCollection(c, sources)

    # ONE ENTRY PER DECLARED POINT, whatever became of each.
    ckEq after.points.len, 3
    ckEq after.points[0].outcome, prMoved
    ckEq after.points[0].line, 6
    ck after.points[0].detail.contains("was at line 4")
    ckEq after.points[1].outcome, prUnresolved
    ckEq after.points[1].line, 0
    ck after.points[1].detail.contains("proc handleTimeout")
    ckEq after.points[2].outcome, prFileAbsent
    ckEq after.points[2].line, 0
    ck after.points[2].detail.contains("deleted.nim")

    let counted = counts(after)
    var total = 0
    for o in PointOutcome: total += counted[o]
    ckEq total, 3
    ckEq unresolvedCount(after), 2

  test "readSourceFile refuses a path outside the checkout, at the syscall":
    # THE SECOND CALL OF ONE PREDICATE, not a second predicate. `parse.nim`
    # already refused anything outside the grammar before it could become a
    # `PointDefinition`; this is the check at the boundary that actually makes
    # the syscall, so it survives a refactor of everything upstream.
    let root = freshRoot("read-guard")
    defer: removeDir(root)
    createDir(root / "src")
    writeFile(root / "src/a.nim", "line one\n")
    writeFile(root.parentDir / ("ct-plat11-outside-" &
                                $getCurrentProcessId() & ".txt"), "secret\n")
    defer: removeFile(root.parentDir / ("ct-plat11-outside-" &
                                        $getCurrentProcessId() & ".txt"))
    ck readSourceFile(root, "src/a.nim").present
    ck not readSourceFile(root,
      "../ct-plat11-outside-" & $getCurrentProcessId() & ".txt").present
    ck not readSourceFile(root, "/etc/passwd").present
    ck not readSourceFile(root, "src/../../etc/passwd").present
    # And a path that is CONTAINED but simply not there is also absent, so the
    # refusal above is about containment rather than about absence being the
    # only outcome this function has.
    ck not readSourceFile(root, "src/missing.nim").present

    # THE TWO SHAPES THAT ONLY THE LEXICAL CHECK CATCHES, added 2026-09-11
    # with the realpath containment below it.
    #
    # The realpath check that closes the symlink escape also refuses every
    # path in the four lines above, which made each of them evidence about two
    # mechanisms at once and about neither in particular — and left the arm
    # aimed at the lexical check with nothing that could notice its removal
    # (Verification-Harness-Traps §16: a repair can make an arm unkillable
    # without moving its needle, simply by making a second mechanism cover the
    # same case). These two are refused by the GRAMMAR and by nothing else:
    #
    #   `src/../src/a.nim` resolves, through `realpath`, to a file that really
    #   is inside this checkout. Only `pathProblem` refuses it, and it should:
    #   two spellings of one path is one too many, and a definition that
    #   writes `..` is a definition nobody can check by reading.
    ck not readSourceFile(root, "src/../src/a.nim").present
    #   And a NUL, which is the reason `ppControlChar` exists. Every byte
    #   after it is invisible to the C API underneath `realpath`, so without
    #   the grammar's refusal the path that is CHECKED and the path that is
    #   OPENED are different strings — and the one that is opened resolves to
    #   a contained file, so the containment below says yes.
    ck not readSourceFile(root, "src/a.nim\0ignored").present

  test "a checked-in symlink does not carry a point's path out of the checkout":
    # THE ESCAPE PLAT-11'S VERIFICATION PASS REPRODUCED ON 2026-09-11, and the
    # repair that closed it. Before the repair this exact fixture gave
    # `prResolved` at line 1 of a file outside the checkout, with that file's
    # bytes in `SourceFile.lines` — `pathProblem` said `ppOk` (correctly: the
    # path IS lexically inside) and containment stopped there.
    #
    # WHAT IS ASSERTED IS THE EFFECT. "A problem code came back" is a claim
    # about the report; the claim worth making is that no byte of the outside
    # file reaches the caller, and that is what `OutsideNeedle` is for.
    let base = getTempDir() / "ct-plat11-symlink-" & $getCurrentProcessId()
    removeDir(base)
    defer: removeDir(base)
    let root = base / "checkout"
    let elsewhere = base / "elsewhere"
    createDir(root / "src")
    createDir(elsewhere)
    writeFile(elsewhere / "id_rsa", OutsideSecret)
    writeFile(root / "src/router.nim", RouterSource)
    createSymlink(elsewhere, root / "vendor")

    # THE FIXTURE IS PROVED BEFORE IT IS USED (Verification-Harness-Traps §4).
    # A scan that finds nothing passes every "must not contain" check ever
    # written, and so does a leak test over a file that was never there. The
    # outside file exists, carries the needle, and is reachable THROUGH the
    # symlink by an ordinary reader in this same process.
    ck readFile(elsewhere / "id_rsa").contains(OutsideNeedle)
    ck fileExists(root / "vendor" / "id_rsa")
    ck readFile(root / "vendor" / "id_rsa").contains(OutsideNeedle)
    # And the grammar is not what stops it, which is why the grammar was not
    # enough: this path satisfies every rule `pathProblem` has.
    ckEq pathProblem("vendor/id_rsa"), ppOk

    let escaped = readSourceFile(root, "vendor/id_rsa")
    ck not escaped.present
    ckEq escaped.lines.len, 0
    var leaked = false
    for l in escaped.lines:
      if l.contains(OutsideNeedle): leaked = true
    ck not leaked

    # THE POSITIVE TWIN, through the same function, in the same run (§4a): a
    # file that really is in the checkout comes back WITH ITS BYTES. Without
    # this, "nothing came back" is also what a reader that has stopped working
    # produces.
    let ordinary = readSourceFile(root, "src/router.nim")
    ck ordinary.present
    ck firstLine(ordinary).contains("import std/strutils")

    # AND END TO END, through the product loader and §4's re-resolution —
    # `loadCheckoutDefinitions` over a real `points.toml`, exactly the path the
    # verification pass walked to reach `prResolved` at line 1.
    writeDefinition(root, "", "points.toml", EscapingPoints)
    let loaded = loadCheckoutDefinitions(root)
    ckEq loaded.project.collections.len, 1
    resolveRoot = root
    let res = resolveCollection(loaded.project.collections[0],
                                readerForResolveRoot)
    # The point is still a ROW rather than an absence — §4's rule does not
    # bend for a refusal.
    ckEq res.points.len, 1
    ckEq res.points[0].outcome, prFileAbsent
    ckEq res.points[0].line, 0
    # And the refusal's own text does not quote the file it refused to read,
    # which is how a "safe" message becomes the disclosure.
    ck not res.points[0].detail.contains(OutsideNeedle)

  test "a checkout reached through a symlink still reads its own files":
    # VERIFICATION-HARNESS-TRAPS §15's POSITIVE TWIN, and the reason it is
    # written rather than assumed: PLAT-8 found this exact half-repair in
    # `canonicalGrantsOf` by writing the twin there. Resolving the CANDIDATE
    # and comparing it against an UNRESOLVED root refuses every file in a
    # checkout that is itself behind a symlink — `/tmp` on macOS, a bind
    # mount, a home under `/home/x` that is really `/data/home/x`. Every
    # assertion in the case above would be MORE satisfied and nothing anywhere
    # would go red.
    let base = getTempDir() / "ct-plat11-linkroot-" & $getCurrentProcessId()
    removeDir(base)
    defer: removeDir(base)
    let real = base / "real-checkout"
    createDir(real / "src")
    writeFile(real / "src/a.nim", "line one\n")
    let linked = base / "linked-checkout"
    createSymlink(real, linked)
    ck symlinkExists(linked)

    let viaLink = readSourceFile(linked, "src/a.nim")
    ck viaLink.present
    ckEq firstLine(viaLink), "line one"

    # A symlink INSIDE the checkout, pointing inside it, is an ordinary thing
    # for a repository to contain and still works: the repair resolves it and
    # finds the TARGET contained. "Refuse every symlink" would have been the
    # other half-repair, and it would have broken vendored trees for the same
    # invisible reason.
    createSymlink("src/a.nim", real / "alias.nim")
    let viaInside = readSourceFile(real, "alias.nim")
    ck viaInside.present
    ckEq firstLine(viaInside), "line one"

    # WHAT SHARING PLAT-8's PREDICATE COSTS, measured rather than assumed —
    # the same treatment the non-ASCII limitation gets in
    # `project_definitions_test`. `capabilities.pathIsUnder` refuses outright
    # if the two characters `..` appear ANYWHERE in either argument, which is
    # a SUBSTRING test rather than a segment test, so a file whose NAME
    # contains `..` is now unreadable here although the grammar accepts it.
    # The alternative was a second copy of the containment predicate, which is
    # §14's defect in a security check; the repair belongs in PLAT-8's file
    # and is recorded in PLAT-11's residues.
    writeFile(real / "src/a..b.nim", "dotted\n")
    ckEq pathProblem("src/a..b.nim"), ppOk
    ck not readSourceFile(real, "src/a..b.nim").present

# ---------------------------------------------------------------------------

suite "PLAT-11 (dir): the counted-assertion tally":

  test "the tally":
    check countedAssertions == ExpectedAssertions
