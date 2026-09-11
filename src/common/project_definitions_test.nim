## project_definitions_test.nim — PLAT-11's PURE suite.
##
## Four subjects, none of which needs a machine:
##
##   1. `project_definitions/containment.nim` — the one predicate that decides
##      whether a string a cloned repository wrote may name a file.
##   2. `project_definitions/parse.nim` — the closed declarative grammar, read
##      against hostile input.
##   3. `project_definitions/load.nim` — §6's composition and §6's separation
##      of the user's definitions from the project's.
##   4. `project_definitions/resolve.nim` — §4's per-point outcome against an
##      edited file.
##
## ## WHAT THIS SUITE IS NOT
##
## It is not evidence that anything was read off a disk. Every input here is a
## literal.
##
##   * `src/ct/launch/project_definitions_dir_test.nim` walks a REAL directory
##     tree: real `.codetracer/` directories, a real oversized file, a real
##     symlink, a real executable-tier file that is really not read.
##   * `src/frontend/viewmodel/tests/unit/test_point_collections_fill_the_point_list.nim`
##     drives a REAL `PointListVM` and asserts the milestone's verification
##     gate — that `PointListVM.points`, which was written by nothing, is now
##     written by this.
##
## ## NO MOCKS
##
## There is not a mock object in this file and there is nothing for one to
## stand in for. Every subject is a pure function over text: a path, a TOML
## document, a list of source lines. The one proc-valued parameter —
## `resolve.resolveCollection`'s `sources` — is a `{.noSideEffect.}` proc TYPE,
## and the suite passes real closures over literal line lists rather than a
## framework double; that is the same object the product passes, differing
## only in where the lines came from.
##
## ## TRAP 13 (Verification-Harness-Traps §13, §13a)
##
## Every assertion helper in this file is a `template`. A `check` inside a
## plain `proc` assigns a module-level `testStatusIMPL`, so the assertion
## cannot fail the test that called it and the case reports `[OK]` with the
## failed comparison printed directly above it. There are four helpers — `ck`,
## `ckEq`, `ckRefused` and `ckNoted` — and all four are templates wrapping
## `unittest.check`.
##
## Compile and run:
##   nim c -r src/common/project_definitions_test.nim

import std/[sets, strutils, unittest]

import ./project_definitions
import ./toml_subset

const ExpectedAssertions = 1614
  ## Written from a run, and asserted against the tally at the end of the
  ## file. `ci/lib/run-nim-test-lane.sh` reads this name.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

template ckRefused(problems: untyped; wanted: ProjectDefinitionCode) =
  ## A refusal asserted BY CODE.
  ##
  ## Verification-Harness-Traps §4b: a test asserting only "it refused" passes
  ## when the refusal was for the wrong reason. Every refusal in this suite
  ## goes through here, and `checkpoint` puts the rendered problems in the
  ## transcript so a failure names what actually happened rather than `false`.
  inc countedAssertions
  var sawWanted = false
  for pr in problems:
    if pr.code == wanted: sawWanted = true
  if not sawWanted:
    checkpoint("wanted " & $wanted & ", got:\n" & renderAll(problems))
  check sawWanted

template ckNoted(problems: untyped; wanted: ProjectDefinitionCode) =
  ## The same, for a notice. Separate from `ckRefused` so a case cannot
  ## accidentally assert that a notice refused something.
  inc countedAssertions
  var sawWanted = false
  for pr in problems:
    if pr.code == wanted and severityOf(pr.code) == pdsNotice: sawWanted = true
  if not sawWanted:
    checkpoint("wanted notice " & $wanted & ", got:\n" & renderAll(problems))
  check sawWanted

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc pointsFile(text: string; scope = ""; origin = doProject;
                path = ""): DefinitionFile =
  DefinitionFile(kind: dfkPoints, origin: origin, scope: scope,
                 path: (if path.len > 0: path
                        else: definitionPath(scope, dfkPoints)),
                 text: text)

proc visualisersFile(text: string; scope = ""; origin = doProject): DefinitionFile =
  DefinitionFile(kind: dfkVisualisers, origin: origin, scope: scope,
                 path: definitionPath(scope, dfkVisualisers), text: text)

proc scratchpadFile(text: string; scope = ""; origin = doProject): DefinitionFile =
  DefinitionFile(kind: dfkScratchpad, origin: origin, scope: scope,
                 path: definitionPath(scope, dfkScratchpad), text: text)

proc parseOne(f: DefinitionFile): tuple[defs: ProjectDefinitions,
                                        problems: seq[ProjectDefinitionProblem]] =
  var defs = ProjectDefinitions()
  let problems = parseDefinitionFile(f, defs)
  (defs, problems)

const GoodPoints = """
schema = "codetracer.points.v1"

[[collection]]
name = "the request path"
enabled = true

[[collection.point]]
kind = "tracepoint"
path = "src/server/router.nim"
anchor = "proc handleRequest"
occurrence = "1"
offset = "2"
line = "40"
expression = "req.url"
label = "entry"

[[collection.point]]
kind = "breakpoint"
path = "src/server/cache.nim"
anchor = "if miss:"
"""

const GoodVisualisers = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
matchKind = "typeName"
language = "rust"
summary = "{rows}x{cols}"
hide = ["stride", "cap"]
present = "Table"

[[visualiser]]
match = "Png"
summary = "{width}x{height} png"
present = "Image"
media = "image/png"
mediaFrom = "bytes"
"""

const GoodScratchpad = """
schema = "codetracer.scratchpad.v1"

[[diff]]
match = "Matrix"
algorithm = "numeric-tolerance"
tolerance = "1e-6"

[[diff]]
match = "Graph"
algorithm = "unordered-set"
"""

# ---------------------------------------------------------------------------
# 1. Containment — the security predicate
# ---------------------------------------------------------------------------

suite "PLAT-11: a definition may not name a file outside the project":

  test "an ordinary repository-relative path is contained":
    ckEq pathProblem("src/server/router.nim"), ppOk
    ckEq pathProblem("a"), ppOk
    ckEq pathProblem("a/b/c/d/e.rs"), ppOk
    ckEq pathProblem("src/my file.nim"), ppOk
    ckEq pathProblem("src/a-b_c+d@e.nim"), ppOk
    ck isContained("src/main.rs")

  test "every way a path can leave the project has its own answer":
    # Verification-Harness-Traps §4b. Each row names the value it must
    # produce, because "it refused" is satisfied by a refusal for the wrong
    # reason — and here the wrong reason would be a DIFFERENT security rule
    # having fired, which would leave the intended one untested.
    ckEq pathProblem("../secrets"), ppParentSegment
    ckEq pathProblem("../../etc/passwd"), ppParentSegment
    ckEq pathProblem("src/../../etc/passwd"), ppParentSegment
    ckEq pathProblem("src/a/../../../x"), ppParentSegment
    ckEq pathProblem("/etc/passwd"), ppAbsolute
    ckEq pathProblem("/"), ppAbsolute
    ckEq pathProblem("C:\\Windows\\System32\\cmd.exe"), ppDriveLetter
    ckEq pathProblem("c:/windows"), ppDriveLetter
    ckEq pathProblem("\\\\server\\share\\x"), ppUncPrefix
    ckEq pathProblem("src\\main.rs"), ppBackslash
    ckEq pathProblem("./src/main.rs"), ppCurrentSegment
    ckEq pathProblem("src/./main.rs"), ppCurrentSegment
    ckEq pathProblem("src//main.rs"), ppEmptySegment
    ckEq pathProblem("src/"), ppEmptySegment
    ckEq pathProblem(""), ppEmpty

  test "a NUL cannot hide in a path, and it is its OWN answer":
    # The byte that changes what "the rest of the string" means to anything
    # that hands the value to a C API. It is checked over the WHOLE string
    # before the segment walk, so it cannot sit behind a segment the walk
    # would have stopped at.
    ckEq pathProblem("src/main.nim\x00/etc/passwd"), ppControlChar
    ckEq pathProblem("\x00"), ppControlChar
    ckEq pathProblem("src/ma\nin.nim"), ppControlChar
    ckEq pathProblem("src/main.nim\x7f"), ppControlChar
    # And the scan reaches past a segment that would itself have been refused,
    # which is the property the ordering exists for: a control character in a
    # LATER segment is still found.
    ckEq pathProblem("ok/" & "x".repeat(200) & "/\x00"), ppControlChar

  test "shell, glob and expansion metacharacters are outside the grammar":
    # Not because this package hands a path to a shell — it hands a path to
    # nothing at all — but because a consumer downstream might, and a closed
    # set is the only form of that guarantee that survives a consumer nobody
    # has written yet.
    var checkedMetacharacters = 0
    for bad in ["src/$HOME/x", "src/`id`/x", "src/~root/x", "src/*.nim",
                "src/a?b", "src/a[b]c", "src/a;rm -rf /", "src/a&b",
                "src/a|b", "src/a>b", "src/a<b", "src/a(b)", "src/a'b",
                "src/a\"b", "src/a%2e%2e", "src/a,b", "src/a=b", "src/a:b",
                "src/a!b", "src/a#b", "src/a^b", "src/a{b}"]:
      inc checkedMetacharacters
      checkpoint("path: " & bad)
      # `:` alone is a bad character rather than a drive letter, because a
      # drive letter is the SECOND byte; both are refusals and neither is
      # `ppOk`, which is the property that matters.
      ck pathProblem(bad) != ppOk
    ckEq checkedMetacharacters, 22

  test "non-ASCII is refused, and the limitation is measured not assumed":
    # Named in `containment.nim`'s header as a real limitation. Asserting it
    # here is what makes it a fact rather than a belief: admitting bytes
    # >= 0x80 would admit overlong UTF-8 encodings of '/' and '.', which is
    # the mechanism of the classic traversal family.
    ckEq pathProblem("src/café.nim"), ppBadChar
    ckEq pathProblem("src/\xc0\xaf/x"), ppBadChar

  test "the bounds are numbers, and are asserted as numbers":
    ckEq MaxContainedPathBytes, 512
    ckEq MaxContainedSegmentBytes, 128
    ckEq MaxContainedPathSegments, 32
    ckEq pathProblem("a".repeat(513)), ppTooLong
    ckEq pathProblem("a".repeat(129) & "/b"), ppSegmentTooLong
    var deep = "a"
    for _ in 1 .. 32: deep.add "/a"
    ckEq pathProblem(deep), ppTooManySegments
    # And one below the bound is accepted, so the bound is a bound rather
    # than an off-by-one that refuses everything interesting.
    var justFits = "a"
    for _ in 1 .. 31: justFits.add "/a"
    ckEq pathProblem(justFits), ppOk

  test "a leading or trailing space in a segment is refused":
    ckEq pathProblem("src/ main.nim"), ppLeadingSpace
    ckEq pathProblem("src/main.nim "), ppTrailingSpace
    ckEq pathProblem(" src/main.nim"), ppLeadingSpace

  test "every refusal explains itself, and names the path":
    # A refusal a user cannot act on is the blank surface in a different
    # costume. Swept over the WHOLE enum rather than over the cases somebody
    # remembered, so a new `PathProblem` with no explanation goes red.
    var checkedProblems = 0
    for p in PathProblem:
      inc checkedProblems
      checkpoint("problem: " & $p)
      let text = describe(p, "the/offending/path")
      ck text.len > 20
      ck text.contains("the/offending/path")
    ckEq checkedProblems, ord(high(PathProblem)) + 1

  test "joining a contained scope to a contained path stays contained":
    # `joinContained` does no checking, on purpose, and this is the sweep
    # that makes that safe: over a cross product of contained scopes and
    # contained paths, the join is contained. A future change that made the
    # join clever enough to break it goes red here.
    var checkedJoins = 0
    for scope in ["", "packages/core", "a", "a/b/c"]:
      for p in ["x.nim", "src/x.nim", "a/b/c/d/e.nim"]:
        inc checkedJoins
        let joined = joinContained(scope, p)
        checkpoint("scope=" & scope & " path=" & p & " -> " & joined)
        ckEq pathProblem(joined), ppOk
    ckEq checkedJoins, 12

# ---------------------------------------------------------------------------
# 2. The layout and the tier boundary
# ---------------------------------------------------------------------------

suite "PLAT-11: .codetracer/ is split by concern, and the tier is per file":

  test "every file kind has a name, a schema and a tier, and they are distinct":
    var names = initHashSet[string]()
    var schemas = initHashSet[string]()
    var checkedKinds = 0
    for k in DefinitionFileKind:
      inc checkedKinds
      checkpoint("kind: " & $k)
      ck definitionFileName(k).len > 0
      ck schemaOf(k).len > 0
      ck definitionFileName(k) notin names
      ck schemaOf(k) notin schemas
      names.incl definitionFileName(k)
      schemas.incl schemaOf(k)
    ckEq checkedKinds, 5

  test "the tier partition is exactly three declarative and two executable":
    # §2.1's whole design goal is that "the useful majority is declarative".
    # Asserted as a partition rather than as two lists, so a kind cannot be
    # in both or in neither.
    ckEq declarativeKinds(), @[dfkPoints, dfkVisualisers, dfkScratchpad]
    ckEq executableKinds(), @[dfkVisualiserCode, dfkDiffCode]
    ckEq declarativeKinds().len + executableKinds().len,
         ord(high(DefinitionFileKind)) + 1
    ckEq tierOf(dfkPoints), dtDeclarative
    ckEq tierOf(dfkVisualiserCode), dtExecutable

  test "a schema id resolves back to exactly one file kind":
    var checkedSchemas = 0
    for k in DefinitionFileKind:
      inc checkedSchemas
      var back: DefinitionFileKind
      ck kindForSchema(schemaOf(k), back)
      ckEq back, k
    ckEq checkedSchemas, 5
    var nowhere: DefinitionFileKind
    ck not kindForSchema("codetracer.points.v2", nowhere)
    ck not kindForSchema("", nowhere)

  test "a definition path is composed from the scope and never from the data":
    ckEq definitionPath("", dfkPoints), ".codetracer/points.toml"
    ckEq definitionPath("packages/core", dfkVisualisers),
         "packages/core/.codetracer/visualisers.toml"
    ckEq ProjectDefinitionDir, ".codetracer"

  test "the executable-tier notice says it was not read, parsed or run":
    let f = DefinitionFile(kind: dfkVisualiserCode, origin: doProject,
                           path: definitionPath("", dfkVisualiserCode))
    let n = executableTierNotice(f)
    ckEq n.code, pdnExecutableTierPresent
    ckEq severityOf(n.code), pdsNotice
    ck n.detail.contains("not read")
    ck n.detail.contains("not run")
    ck n.detail.contains("trust grant")
    ck namesFile(n)

# ---------------------------------------------------------------------------
# 3. The declarative grammar, read against ordinary input
# ---------------------------------------------------------------------------

suite "PLAT-11: a well-formed definition loads":

  test "a point collection parses, with its anchor and not a bare line":
    let (defs, problems) = parseOne(pointsFile(GoodPoints))
    ckEq problems.len, 0
    ckEq defs.collections.len, 1
    let c = defs.collections[0]
    ckEq c.name, "the request path"
    ck c.enabledByDefault
    ckEq c.origin, doProject
    ckEq c.points.len, 2
    ckEq c.points[0].kind, pkTracepoint
    ckEq c.points[0].path, "src/server/router.nim"
    ckEq c.points[0].anchor.text, "proc handleRequest"
    ckEq c.points[0].anchor.occurrence, 1
    ckEq c.points[0].anchor.offset, 2
    ckEq c.points[0].anchor.line, 40
    ckEq c.points[0].expression, "req.url"
    ckEq c.points[1].kind, pkBreakpoint
    # The defaults a point that declares none gets.
    ckEq c.points[1].anchor.occurrence, 1
    ckEq c.points[1].anchor.offset, 0
    ckEq c.points[1].anchor.line, 0

  test "a visualiser declaration parses into the abstract vocabulary":
    let (defs, problems) = parseOne(visualisersFile(GoodVisualisers))
    ckEq problems.len, 0
    ckEq defs.visualisers.len, 2
    let v = defs.visualisers[0]
    ckEq v.match, "Matrix"
    ckEq v.matchKind, mkTypeName
    ckEq v.language, "rust"
    ckEq v.summary, "{rows}x{cols}"
    ckEq v.hide, @["stride", "cap"]
    ckEq v.present, pkTable
    ck not v.declaresMedia()
    let media = defs.visualisers[1]
    ckEq media.present, pkImage
    ckEq media.mediaType, "image/png"
    ckEq media.mediaFrom, "bytes"
    ck media.declaresMedia()

  test "a scratchpad diff SELECTS a built-in; it does not supply one":
    let (defs, problems) = parseOne(scratchpadFile(GoodScratchpad))
    ckEq problems.len, 0
    ckEq defs.diffs.len, 2
    ckEq defs.diffs[0].algorithm, daNumericTolerance
    ckEq defs.diffs[0].tolerance, "1e-6"
    ckEq defs.diffs[1].algorithm, daUnorderedSet
    ckEq defs.diffs[1].tolerance, ""

  test "matching is three total string comparisons and nothing else":
    # §2.2: "Matching and templating are total and terminate by
    # construction." Asserted over the whole `MatchKind` enum, so a fourth
    # member — a regex, a glob — arrives with no assertion and the count
    # below goes red.
    ckEq ord(high(MatchKind)) + 1, 3
    var exact = VisualiserRule(match: "Matrix", matchKind: mkTypeName)
    ck exact.matches("Matrix", "")
    ck not exact.matches("Matrix2", "")
    ck not exact.matches("aMatrix", "")
    var prefix = VisualiserRule(match: "Vec", matchKind: mkTypePrefix)
    ck prefix.matches("Vec3", "")
    ck prefix.matches("Vec", "")
    ck not prefix.matches("AVec3", "")
    ck not prefix.matches("Ve", "")
    var suffix = VisualiserRule(match: "Buffer", matchKind: mkTypeSuffix)
    ck suffix.matches("RingBuffer", "")
    ck not suffix.matches("Buffers", "")
    ck not suffix.matches("uffer", "")
    var langed = VisualiserRule(match: "Matrix", matchKind: mkTypeName,
                                language: "rust")
    ck langed.matches("Matrix", "rust")
    ck not langed.matches("Matrix", "python")

  test "specificity is a number, so a tie is a visible equality":
    # §5.4 breaks ties "by declaration order and reported", which is only
    # possible if a tie can be DETECTED. A comparison function would hide it.
    let exact = VisualiserRule(match: "Matrix", matchKind: mkTypeName)
    let prefix = VisualiserRule(match: "Matrix", matchKind: mkTypePrefix)
    let longer = VisualiserRule(match: "MatrixOfInts", matchKind: mkTypePrefix)
    let langed = VisualiserRule(match: "Matrix", matchKind: mkTypeName,
                                language: "rust")
    ck specificity(exact) > specificity(longer)
    ck specificity(longer) > specificity(prefix)
    ck specificity(langed) > specificity(exact)
    ckEq specificity(prefix), specificity(VisualiserRule(match: "Matrix",
                                                         matchKind: mkTypeSuffix))

  test "the presenter tier this package belongs to is PLAT-2's, not a new one":
    # §5.4's precedence is one order with four tiers. A second enum here
    # would be the second copy of it.
    ckEq PresenterTierOfProjectDefinition, ptProjectDefinition
    ck ord(ptInProgram) < ord(ptProjectDefinition)
    ck ord(ptProjectDefinition) < ord(ptPlugin)
    ck ord(ptPlugin) < ord(ptBuiltin)

# ---------------------------------------------------------------------------
# 4. HOSTILE INPUT — the tier is incapable of harm, and here is the measurement
# ---------------------------------------------------------------------------

suite "PLAT-11: a hostile definition is refused, by type, naming the file":

  test "an oversized file is refused before it is tokenised":
    let huge = "schema = \"codetracer.points.v1\"\n" & "#".repeat(MaxDefinitionBytes)
    let (defs, problems) = parseOne(pointsFile(huge))
    ckRefused problems, pdcFileTooLarge
    ckEq defs.collections.len, 0
    ck problems[0].detail.contains($MaxDefinitionBytes)
    ck namesFile(problems[0])
    # One byte under the bound is NOT refused for size, so the bound is a
    # bound rather than a refusal of everything.
    let justFits = "schema = \"codetracer.points.v1\"\n" &
      "#".repeat(MaxDefinitionBytes - 32)
    ckEq justFits.len, MaxDefinitionBytes
    var d2 = ProjectDefinitions()
    let p2 = parseDefinitionFile(pointsFile(justFits), d2)
    ckEq p2.len, 0

  test "a file that is small in bytes and enormous in lines is refused too":
    let manyLines = "schema = \"codetracer.points.v1\"\n" &
      "\n".repeat(MaxDefinitionLines + 1)
    let (_, problems) = parseOne(pointsFile(manyLines))
    ckRefused problems, pdcTooManyLines

  test "a nesting bomb is refused by the shared reader's own bound":
    # The bound is `toml_subset.MaxTomlNesting`, NAMED rather than restated,
    # so this package cannot drift from the reader that enforces it.
    let bomb = "schema = \"codetracer.points.v1\"\ncollection = " &
      "[".repeat(MaxTomlNesting + 4)
    let (defs, problems) = parseOne(pointsFile(bomb))
    ckRefused problems, pdcMalformedToml
    ckEq defs.collections.len, 0
    ck problems[0].detail.contains($MaxTomlNesting)
    # A deeply-but-legally nested document is NOT refused for nesting, which
    # is what makes the previous assertion about the bound rather than about
    # brackets.
    var d2 = ProjectDefinitions()
    discard parseDefinitionFile(
      pointsFile("schema = \"codetracer.points.v1\"\n"), d2)

  test "a path outside the checkout is refused, and says WHICH rule it broke":
    # The milestone's second integration test, at the grammar level.
    var checkedEscapes = 0
    for bad in ["../../etc/passwd", "/etc/passwd", "C:\\Windows\\cmd.exe",
                "src/../../../root/.ssh/id_rsa", "src\\main.rs",
                "\\\\attacker\\share\\x"]:
      inc checkedEscapes
      checkpoint("path: " & bad)
      # THE PATH IS A TOML **LITERAL** STRING (single quotes), which is how a
      # Windows path has to be written and how an attacker would write one: in
      # a basic string `C:\Windows` is an invalid escape, and the reader would
      # refuse the FILE before containment ever saw the path. Measured on this
      # suite's first run, where three of the six rows were refused for the
      # wrong reason — §4b, inside the fixture rather than inside the
      # assertion.
      let text = """
schema = "codetracer.points.v1"

[[collection]]
name = "escape"

[[collection.point]]
kind = "breakpoint"
path = 'PATH'
anchor = "fn main"
""".replace("PATH", bad)
      let (defs, problems) = parseOne(pointsFile(text))
      ckRefused problems, pdcPathEscapesProject
      # AND THE COLLECTION IS NOT PARTIALLY LOADED. A collection whose only
      # point was refused has no points, and an empty collection is itself a
      # refusal — so nothing reaches `defs` at all.
      ckEq defs.collections.len, 0
      var named = false
      for pr in problems:
        if pr.code == pdcPathEscapesProject:
          ck pr.detail.contains(bad)
          ck namesFile(pr)
          named = true
      ck named
    ckEq checkedEscapes, 6

  test "a definition declaring an interpreter, an exec or a command is not a definition":
    # THE CENTRAL CASE OF THIS MILESTONE.
    #
    # Every one of these lands on `pdcUnknownKey` — the SAME code a misspelled
    # `enabled` produces — and that sameness is the evidence rather than a
    # weakness. There is no arm in `parse.nim` that recognises these keys in
    # order to refuse them; there is no arm that recognises them at all. The
    # grammar has twenty-nine keys and none of them takes a program, so
    # "executing" is not a thing this format can express — and the case below
    # asserts that count against the array itself, so this sentence cannot
    # drift off it again.
    var checkedKeys = 0
    for key in ["interpreter", "exec", "command", "script", "run", "shell",
                "plugin", "load", "library", "dll", "eval", "natvisFile",
                "include", "extends", "url", "argv", "env", "cwd"]:
      inc checkedKeys
      checkpoint("key: " & key)
      let text = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
KEY = "/bin/sh"
""".replace("KEY", key)
      let (defs, problems) = parseOne(visualisersFile(text))
      ckRefused problems, pdcUnknownKey
      ckEq defs.visualisers.len, 0
      var explained = false
      for pr in problems:
        if pr.code == pdcUnknownKey:
          ck pr.detail.contains("'" & key & "'")
          # The message says WHY there is no such key, so an author reading it
          # learns the rule rather than guessing at a spelling.
          ck pr.detail.contains("no key here that names a program")
          explained = true
      ck explained
    ckEq checkedKeys, 18

  test "the accepted-key set is the whole grammar, asserted against a literal":
    # DELIBERATELY A SECOND COPY (Verification-Harness-Traps §14 names this
    # as the exception it is): the thing guarded is not a computation, it is a
    # decision about what may exist, and a guard deriving itself from the
    # subject would approve of whatever the subject said.
    #
    # Adding a key to `AcceptedKeys` reddens this case. That is the point: a
    # key that named a program would have to be added here too, by somebody
    # who then has to explain it.
    ckEq AcceptedKeys[tiRootPoints], @["schema", "collection"]
    ckEq AcceptedKeys[tiRootVisualisers], @["schema", "visualiser"]
    ckEq AcceptedKeys[tiRootScratchpad], @["schema", "diff"]
    ckEq AcceptedKeys[tiCollection], @["name", "enabled", "point"]
    ckEq AcceptedKeys[tiCollectionPoint],
         @["kind", "path", "anchor", "occurrence", "offset", "line",
           "expression", "label"]
    ckEq AcceptedKeys[tiVisualiser],
         @["match", "matchKind", "language", "summary", "hide", "present",
           "media", "mediaFrom"]
    ckEq AcceptedKeys[tiDiff], @["match", "matchKind", "algorithm", "tolerance"]
    var total = 0
    for t in TableId: total += AcceptedKeys[t].len
    ckEq total, 29

  test "no accepted key is spelled like something that runs":
    # A second, INDEPENDENT statement of the same property, over the data
    # rather than over the literal. The case above would go red if a key were
    # added; this one says what KIND of key may never be added, and it reads
    # the same array the parser reads.
    var checkedTables = 0
    for t in TableId:
      inc checkedTables
      for key in AcceptedKeys[t]:
        checkpoint("table " & $t & " key " & key)
        let lowered = key.toLowerAscii
        for forbidden in ["exec", "command", "cmd", "run", "shell", "script",
                          "interpreter", "eval", "spawn", "argv", "binary",
                          "program", "dll", "so", "dylib", "url", "http"]:
          ck not lowered.contains(forbidden)
    ckEq checkedTables, 7

  test "a top-level table belonging to another file is refused, not ignored":
    # `points.toml` and `visualisers.toml` used to share one root key row, so
    # a `[[visualiser]]` written into `points.toml` was read by nobody and
    # reported by nobody. That is the "unrecognised, ignored" arm arriving
    # through a TABLE NAME instead of through a key, and it is the one the
    # suite found rather than review.
    let strayTable = """
schema = "codetracer.points.v1"

[[visualiser]]
match = "Matrix"
"""
    let (defs, problems) = parseOne(pointsFile(strayTable))
    ckRefused problems, pdcUnknownKey
    ckEq defs.collections.len, 0
    ckEq defs.visualisers.len, 0

  test "a future schema version is REPORTED, never partially honoured":
    # §6, and `LayoutDecodeError`'s rule. The user's next step is in the
    # message and it is not "fix your file".
    let future = GoodPoints.replace("codetracer.points.v1",
                                    "codetracer.points.v7")
    let (defs, problems) = parseOne(pointsFile(future))
    ckRefused problems, pdcUnknownSchemaVersion
    ckEq defs.collections.len, 0
    ck isUnknownToThisBuild(pdcUnknownSchemaVersion)
    ck problems[0].detail.contains("codetracer.points.v7")
    ck problems[0].detail.contains("codetracer.points.v1")
    ck problems[0].detail.contains("NOT partially honoured")
    ck namesFile(problems[0])

  test "a KNOWN schema in the WRONG file is a different refusal":
    # §6 makes the trust tier a property of the FILE. A file that could
    # redeclare which concern it carries is a file no per-file gate applies
    # to, so this is refused rather than followed — and refused with its own
    # code, because "you are in the wrong file" and "this build is too old"
    # are opposite messages.
    let swapped = GoodPoints.replace("codetracer.points.v1",
                                     "codetracer.visualisers.v1")
    let (defs, problems) = parseOne(pointsFile(swapped))
    ckRefused problems, pdcSchemaKindMismatch
    ckEq defs.collections.len, 0
    ck not isUnknownToThisBuild(pdcSchemaKindMismatch)
    ck problems[0].detail.contains("visualisers.toml")

  test "a file declaring no schema is refused rather than assumed current":
    let (defs, problems) = parseOne(pointsFile("[[collection]]\nname = \"x\"\n"))
    ckRefused problems, pdcMissingSchema
    ckEq defs.collections.len, 0

  test "a point with only a line number is refused":
    # §4: "a stable location: path plus a resilient anchor, NOT A BARE LINE
    # NUMBER, so an edit above the point does not silently move it." The rule
    # is enforced at the boundary rather than left to review.
    let text = """
schema = "codetracer.points.v1"

[[collection]]
name = "fragile"

[[collection.point]]
kind = "breakpoint"
path = "src/main.rs"
line = "42"
"""
    let (defs, problems) = parseOne(pointsFile(text))
    ckRefused problems, pdcAnchorMissing
    ckEq defs.collections.len, 0
    var explained = false
    for pr in problems:
      if pr.code == pdcAnchorMissing:
        ck pr.detail.contains("42")
        ck pr.detail.contains("silently marks a different statement")
        explained = true
    ck explained

  test "a summary template that could loop or run away is refused":
    # §2.2: "Matching and templating are total and terminate by
    # construction." Validated at parse time so substitution later is one
    # linear pass that cannot fail.
    ckEq templateProblem("{rows}x{cols}"), tpOk
    ckEq templateProblem("no placeholders"), tpOk
    ckEq templateProblem("{{ a literal brace"), tpOk
    ckEq templateProblem("{a.b.c}"), tpOk
    ckEq templateProblem("{unterminated"), tpUnterminated
    ckEq templateProblem("{a{b}}"), tpNested
    ckEq templateProblem("{}"), tpEmptyPlaceholder
    ckEq templateProblem("{a b}"), tpBadPlaceholderChar
    ckEq templateProblem("{a/../b}"), tpBadPlaceholderChar
    ckEq templateProblem("{a}".repeat(MaxTemplatePlaceholders + 1)),
         tpTooManyPlaceholders
    ckEq templateProblem("x".repeat(MaxSummaryBytes + 1)), tpPlaceholderTooLong
    var checkedTemplateProblems = 0
    for p in TemplateProblem:
      inc checkedTemplateProblems
      ck describeTemplate(p).len > 10
    ckEq checkedTemplateProblems, 7

  test "a visualiser naming a presentation a VALUE cannot be is refused":
    # PLAT-3's vocabulary has sixteen entries and a recorded value can be
    # five of them. `present = "Button"` names something real and useless,
    # which §4.1 makes a load-time error rather than a silently missing
    # feature.
    var checkedPresentations = 0
    for bad in ["Button", "Modal", "Menu", "Tabs", "ProgressIndicator",
                "Checkbox", "Toggle", "Input", "Select", "Collapsible",
                "Markdown"]:
      inc checkedPresentations
      checkpoint("present: " & bad)
      let text = "schema = \"codetracer.visualisers.v1\"\n\n" &
        "[[visualiser]]\nmatch = \"X\"\npresent = \"" & bad & "\"\n"
      let (defs, problems) = parseOne(visualisersFile(text))
      ckRefused problems, pdcUnknownPresentation
      ckEq defs.visualisers.len, 0
    ckEq checkedPresentations, 11
    # And the five a value CAN be are accepted, so the refusal is about the
    # vocabulary rather than about the key.
    var checkedAccepted = 0
    for good in knownPresentationNames():
      inc checkedAccepted
      checkpoint("present: " & good)
      let text = "schema = \"codetracer.visualisers.v1\"\n\n" &
        "[[visualiser]]\nmatch = \"X\"\npresent = \"" & good & "\"\n" &
        (if good == "Image": "media = \"image/png\"\nmediaFrom = \"b\"\n" else: "")
      let (defs, problems) = parseOne(visualisersFile(text))
      ckEq problems.len, 0
      ckEq defs.visualisers.len, 1
    ckEq checkedAccepted, 5
    ckEq knownPresentationNames().len, ValuePresentationKinds.card

  test "a media type nothing renders is refused, and the list is closed":
    let text = "schema = \"codetracer.visualisers.v1\"\n\n" &
      "[[visualiser]]\nmatch = \"X\"\nmedia = \"application/x-sh\"\n" &
      "mediaFrom = \"b\"\n"
    let (defs, problems) = parseOne(visualisersFile(text))
    ckRefused problems, pdcUnknownMediaType
    ckEq defs.visualisers.len, 0
    ckEq DeclarativeMediaTypes.len, 8
    # Declaring bytes without saying what they are, and saying what they are
    # without naming the bytes, are both refused: §5.2's mechanism is the
    # project SAYING WHICH BYTES, and half of that is not a declaration.
    let noFrom = "schema = \"codetracer.visualisers.v1\"\n\n" &
      "[[visualiser]]\nmatch = \"X\"\nmedia = \"image/png\"\n"
    ckRefused parseOne(visualisersFile(noFrom)).problems, pdcMissingField
    let noMedia = "schema = \"codetracer.visualisers.v1\"\n\n" &
      "[[visualiser]]\nmatch = \"X\"\nmediaFrom = \"b\"\n"
    ckRefused parseOne(visualisersFile(noMedia)).problems, pdcMissingField

  test "a scratchpad diff naming an algorithm CodeTracer does not ship is refused":
    # And the message says the boundary out loud: a project SELECTS; supplying
    # a comparison is the executable tier, which is a different file behind a
    # grant. There is no path here that turns the name into a lookup.
    let text = "schema = \"codetracer.scratchpad.v1\"\n\n" &
      "[[diff]]\nmatch = \"Matrix\"\nalgorithm = \"./my_diff.wasm\"\n"
    let (defs, problems) = parseOne(scratchpadFile(text))
    ckRefused problems, pdcUnknownDiffAlgorithm
    ckEq defs.diffs.len, 0
    var explained = false
    for pr in problems:
      if pr.code == pdcUnknownDiffAlgorithm:
        ck pr.detail.contains("SELECTS")
        ck pr.detail.contains("trust grant")
        explained = true
    ck explained
    ckEq knownDiffAlgorithms(),
         @["structural", "numeric-tolerance", "unordered-set", "text-lines"]

  test "a tolerance that is not a bounded decimal is refused":
    ck boundedTolerance("0")
    ck boundedTolerance("0.001")
    ck boundedTolerance("1e-6")
    ck boundedTolerance("2.5E+3")
    ck not boundedTolerance("")
    ck not boundedTolerance("-1")
    ck not boundedTolerance("1.")
    ck not boundedTolerance(".1")
    ck not boundedTolerance("1e")
    ck not boundedTolerance("1e1000")
    ck not boundedTolerance("0x10")
    ck not boundedTolerance("1" & "0".repeat(MaxNumberBytes))
    ck not boundedTolerance("nan")
    let bad = "schema = \"codetracer.scratchpad.v1\"\n\n" &
      "[[diff]]\nmatch = \"M\"\nalgorithm = \"numeric-tolerance\"\n" &
      "tolerance = \"$(id)\"\n"
    ckRefused parseOne(scratchpadFile(bad)).problems, pdcBadNumber

  test "a quoted decimal outside its bound is refused":
    var n = 0
    ck boundedDecimal("42", n, 0, 100)
    ckEq n, 42
    ck not boundedDecimal("", n, 0, 100)
    ck not boundedDecimal("-1", n, 0, 100)
    ck not boundedDecimal("1 ", n, 0, 100)
    ck not boundedDecimal("101", n, 0, 100)
    ck not boundedDecimal("9".repeat(MaxNumberBytes + 1), n, 0, 1_000_000_000)
    # A huge occurrence would be an unbounded scan of the file; it is a
    # refusal rather than a clamp.
    let text = """
schema = "codetracer.points.v1"

[[collection]]
name = "x"

[[collection.point]]
kind = "breakpoint"
path = "a.rs"
anchor = "fn main"
occurrence = "999999999"
"""
    ckRefused parseOne(pointsFile(text)).problems, pdcBadNumber

  test "every bounded collection has its bound enforced":
    var checkedBounds = 0
    # Collections.
    var many = "schema = \"codetracer.points.v1\"\n"
    for i in 0 .. MaxCollections:
      many.add "\n[[collection]]\nname = \"c" & $i & "\"\n" &
        "\n[[collection.point]]\nkind = \"breakpoint\"\npath = \"a.rs\"\n" &
        "anchor = \"fn\"\n"
    inc checkedBounds
    ckRefused parseOne(pointsFile(many)).problems, pdcTooManyEntries
    # Points in one collection.
    var manyPoints = "schema = \"codetracer.points.v1\"\n\n[[collection]]\n" &
      "name = \"c\"\n"
    for i in 0 .. MaxPointsPerCollection:
      manyPoints.add "\n[[collection.point]]\nkind = \"breakpoint\"\n" &
        "path = \"a.rs\"\nanchor = \"fn\"\n"
    inc checkedBounds
    ckRefused parseOne(pointsFile(manyPoints)).problems, pdcTooManyEntries
    # Visualiser rules.
    var manyRules = "schema = \"codetracer.visualisers.v1\"\n"
    for i in 0 .. MaxVisualiserRules:
      manyRules.add "\n[[visualiser]]\nmatch = \"T" & $i & "\"\n"
    inc checkedBounds
    ckRefused parseOne(visualisersFile(manyRules)).problems, pdcTooManyEntries
    # Hidden fields.
    var manyHidden = "schema = \"codetracer.visualisers.v1\"\n\n" &
      "[[visualiser]]\nmatch = \"T\"\nhide = ["
    for i in 0 .. MaxHiddenFields:
      manyHidden.add "\"f" & $i & "\", "
    manyHidden.add "]\n"
    inc checkedBounds
    ckRefused parseOne(visualisersFile(manyHidden)).problems, pdcTooManyEntries
    # Diff selections.
    var manyDiffs = "schema = \"codetracer.scratchpad.v1\"\n"
    for i in 0 .. MaxDiffSelections:
      manyDiffs.add "\n[[diff]]\nmatch = \"T" & $i &
        "\"\nalgorithm = \"structural\"\n"
    inc checkedBounds
    ckRefused parseOne(scratchpadFile(manyDiffs)).problems, pdcTooManyEntries
    ckEq checkedBounds, 5

  test "an over-long value is refused rather than truncated":
    let text = "schema = \"codetracer.points.v1\"\n\n[[collection]]\n" &
      "name = \"" & "n".repeat(MaxNameBytes + 1) & "\"\n"
    ckRefused parseOne(pointsFile(text)).problems, pdcValueTooLong

  test "two collections of one name are refused, not last-wins":
    let text = """
schema = "codetracer.points.v1"

[[collection]]
name = "dup"

[[collection.point]]
kind = "breakpoint"
path = "a.rs"
anchor = "fn a"

[[collection]]
name = "dup"

[[collection.point]]
kind = "breakpoint"
path = "b.rs"
anchor = "fn b"
"""
    let (defs, problems) = parseOne(pointsFile(text))
    ckRefused problems, pdcDuplicateName
    ckEq defs.collections.len, 1
    ckEq defs.collections[0].points[0].path, "a.rs"

  test "an empty collection is refused":
    let text = "schema = \"codetracer.points.v1\"\n\n[[collection]]\n" &
      "name = \"empty\"\n"
    let (defs, problems) = parseOne(pointsFile(text))
    ckRefused problems, pdcEmptyCollection
    ckEq defs.collections.len, 0

  test "a value of the wrong TOML kind is refused, naming the key":
    var checkedTypes = 0
    for text in [
        "schema = \"codetracer.points.v1\"\n\n[[collection]]\nname = [\"a\"]\n",
        "schema = \"codetracer.points.v1\"\n\n[[collection]]\nname = \"c\"\n" &
          "enabled = \"yes\"\n",
        "schema = \"codetracer.points.v1\"\n\n[[collection]]\nname = \"c\"\n" &
          "point = \"one\"\n"]:
      inc checkedTypes
      checkpoint(text)
      ckRefused parseOne(pointsFile(text)).problems, pdcWrongType
    let badHide = "schema = \"codetracer.visualisers.v1\"\n\n[[visualiser]]\n" &
      "match = \"X\"\nhide = \"one\"\n"
    inc checkedTypes
    ckRefused parseOne(visualisersFile(badHide)).problems, pdcWrongType
    ckEq checkedTypes, 4

  test "an unknown point kind and an unknown match kind are refused by name":
    let badPoint = """
schema = "codetracer.points.v1"

[[collection]]
name = "c"

[[collection.point]]
kind = "watchpoint"
path = "a.rs"
anchor = "fn"
"""
    ckRefused parseOne(pointsFile(badPoint)).problems, pdcUnknownPointKind
    let badMatch = "schema = \"codetracer.visualisers.v1\"\n\n" &
      "[[visualiser]]\nmatch = \"X\"\nmatchKind = \"regex\"\n"
    let (_, problems) = parseOne(visualisersFile(badMatch))
    ckRefused problems, pdcUnknownMatchKind
    var explained = false
    for pr in problems:
      if pr.code == pdcUnknownMatchKind:
        # THE MESSAGE SAYS WHY THERE IS NO REGEX, because "regex" is the
        # single most likely thing an author will reach for and the reason it
        # is absent is not guessable.
        ck pr.detail.contains("no regular expression")
        ck pr.detail.contains("terminate by construction")
        explained = true
    ck explained

  test "an unreadable file is refused as unreadable, with the reader's own message":
    var checkedMalformed = 0
    for bad in ["schema = \"codetracer.points.v1\"\nthis is not toml\n",
                "schema = \"codetracer.points.v1\"\nk = \"1\"\nk = \"2\"\n",
                "[a]\nx = \"1\"\n[a]\ny = \"2\"\n",
                "schema = \"codetracer.points.v1\"\nk = 12\n",
                "\"unterminated"]:
      inc checkedMalformed
      checkpoint(bad)
      let (defs, problems) = parseOne(pointsFile(bad))
      ck problems.len > 0
      ckEq defs.collections.len, 0
    ckEq checkedMalformed, 5

  test "every problem this suite can produce names its file":
    # THE SWEEP (`plugin_model_test`'s shape). A per-case claim is satisfied
    # by the cases somebody remembered to write, so this folds over every
    # code in the enum and asserts the rendered text carries the file.
    var checkedCodes = 0
    for c in ProjectDefinitionCode:
      inc checkedCodes
      checkpoint("code: " & $c)
      let p = problem(".codetracer/points.toml", 3, c, "the detail")
      ck namesFile(p)
      ck render(p).contains(".codetracer/points.toml")
      ck render(p).contains(":3:")
      ck codeText(c).len > 0
    ckEq checkedCodes, ord(high(ProjectDefinitionCode)) + 1
    # AND THE SWEEP CAN FAIL. `namesFile` is a function precisely so the rule
    # and its control are one piece of code; here is the control.
    ck not namesFile(problem("", 0, pdcUnknownKey, "no file"))

  test "the severity partition is total and the notices are exactly four":
    var refusalCount = 0
    var noticeCount = 0
    for c in ProjectDefinitionCode:
      case severityOf(c)
      of pdsRefusal: inc refusalCount
      of pdsNotice: inc noticeCount
    ckEq noticeCount, 4
    ckEq refusalCount + noticeCount, ord(high(ProjectDefinitionCode)) + 1
    ck refusalCount > 20

# ---------------------------------------------------------------------------
# 5. Composition and the user's own definitions (§6)
# ---------------------------------------------------------------------------

suite "PLAT-11: composition, with the override rules stated":

  test "a nested package's collection replaces an ancestor's of the same name":
    let root = pointsFile("""
schema = "codetracer.points.v1"

[[collection]]
name = "the request path"

[[collection.point]]
kind = "breakpoint"
path = "shared.rs"
anchor = "fn shared"
""")
    let nested = pointsFile("""
schema = "codetracer.points.v1"

[[collection]]
name = "the request path"

[[collection.point]]
kind = "tracepoint"
path = "server.rs"
anchor = "fn serve"
""", scope = "packages/server")
    let loaded = loadProjectDefinitions([root, nested])
    ckEq loaded.project.collections.len, 1
    let c = loaded.project.collections[0]
    ckEq c.scope, "packages/server"
    ckEq c.points.len, 1
    # REPLACED, NOT MERGED. A merged collection is one neither author wrote.
    ckEq c.points[0].path, "packages/server/server.rs"
    # AND THE OVERRIDE IS REPORTED, naming both files.
    ckNoted loaded.problems, pdnCollectionShadowed
    var named = false
    for pr in loaded.problems:
      if pr.code == pdnCollectionShadowed:
        ck pr.detail.contains(".codetracer/points.toml")
        ck pr.detail.contains("ENTIRELY rather than merging")
        named = true
    ck named
    # A notice does not make the load not-ok.
    ck loaded.isOk()

  test "the nearer definition wins whatever order the caller enumerated them":
    # A caller's directory-walk order is not a contract, and depending on it
    # is how "the nearer one wins" silently becomes "the last one read wins".
    let root = pointsFile("""
schema = "codetracer.points.v1"

[[collection]]
name = "shared"

[[collection.point]]
kind = "breakpoint"
path = "root.rs"
anchor = "fn root"
""")
    let nested = pointsFile("""
schema = "codetracer.points.v1"

[[collection]]
name = "shared"

[[collection.point]]
kind = "breakpoint"
path = "deep.rs"
anchor = "fn deep"
""", scope = "a/b/c")
    for order in [@[root, nested], @[nested, root]]:
      let loaded = loadProjectDefinitions(order)
      ckEq loaded.project.collections.len, 1
      ckEq loaded.project.collections[0].points[0].path, "a/b/c/deep.rs"

  test "a nested point's path is expressed relative to the REPOSITORY":
    let nested = pointsFile("""
schema = "codetracer.points.v1"

[[collection]]
name = "c"

[[collection.point]]
kind = "breakpoint"
path = "src/lib.rs"
anchor = "fn f"
""", scope = "packages/core")
    let loaded = loadProjectDefinitions([nested])
    ckEq loaded.project.collections[0].points[0].path,
         "packages/core/src/lib.rs"
    # And it is still contained, which is the property the join preserves.
    ckEq pathProblem(loaded.project.collections[0].points[0].path), ppOk

  test "a package scope outside the checkout is refused":
    # Composition may not reach outside the checkout any more than a single
    # path may. Without this a nested definition would be the channel.
    let escaping = pointsFile(GoodPoints, scope = "../../elsewhere")
    let loaded = loadProjectDefinitions([escaping])
    ckRefused loaded.problems, pdcScopeEscapesProject
    ckEq loaded.project.collections.len, 0
    ck not loaded.isOk()

  test "visualiser rules are ORDERED by nearness, not overridden":
    # Rules are not named, so there is no name for an override to key on.
    let root = visualisersFile("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "root"
""")
    let nested = visualisersFile("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "nested"
""", scope = "packages/core")
    let loaded = loadProjectDefinitions([root, nested])
    ckEq loaded.project.visualisers.len, 2
    ckEq loaded.project.visualisers[0].summary, "nested"
    ckEq loaded.project.visualisers[1].summary, "root"
    # Both survive; neither is dropped.
    ckEq loaded.project.visualisers[0].scope, "packages/core"
    ckEq loaded.project.visualisers[1].scope, ""

  test "a precedence tie is broken by declaration order AND reported":
    # §5.4: "ties broken by declaration order and reported". A silently
    # broken tie is a formatting layer that cannot explain itself.
    let f = visualisersFile("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Matrix"
summary = "first"

[[visualiser]]
match = "Matrix"
summary = "second"
""")
    let loaded = loadProjectDefinitions([f])
    ckEq loaded.project.visualisers.len, 2
    ckEq loaded.project.visualisers[0].summary, "first"
    ckNoted loaded.problems, pdnRuleTieReported
    var explained = false
    for pr in loaded.problems:
      if pr.code == pdnRuleTieReported:
        ck pr.detail.contains("Matrix")
        ck pr.detail.contains("earlier")
        explained = true
    ck explained

  test "a more specific rule outranks a less specific one at the same scope":
    let f = visualisersFile("""
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Vec"
matchKind = "typePrefix"
summary = "any vec"

[[visualiser]]
match = "Vec3"
summary = "a vec3"
""")
    let loaded = loadProjectDefinitions([f])
    ckEq loaded.project.visualisers[0].summary, "a vec3"
    ckEq loaded.project.visualisers[1].summary, "any vec"

  test "the user's definitions are a different field, never merged in":
    # §6: "A user's own definitions are separate and not checked in, and never
    # silently merged into the project's — otherwise a user's local experiment
    # becomes a diff."
    let projectFile = pointsFile("""
schema = "codetracer.points.v1"

[[collection]]
name = "shared"

[[collection.point]]
kind = "breakpoint"
path = "a.rs"
anchor = "fn a"
""")
    let userFile = pointsFile("""
schema = "codetracer.points.v1"

[[collection]]
name = "shared"

[[collection.point]]
kind = "tracepoint"
path = "b.rs"
anchor = "fn b"
""", origin = doUser, path = "<user>/points.toml")
    let loaded = loadProjectDefinitions([projectFile], [userFile])
    ckEq loaded.project.collections.len, 1
    ckEq loaded.user.collections.len, 1
    # THE SAME NAME IN BOTH, AND NEITHER REPLACED THE OTHER. Composition is
    # within one origin; a user's collection shadows nothing, so they can see
    # that they have shadowed nothing.
    ckEq loaded.project.collections[0].points[0].path, "a.rs"
    ckEq loaded.user.collections[0].points[0].path, "b.rs"
    ckEq loaded.project.collections[0].origin, doProject
    ckEq loaded.user.collections[0].origin, doUser
    # And the ONE function that returns both tags every entry.
    let all = loaded.allCollections()
    ckEq all.len, 2
    ckEq all[0].origin, doProject
    ckEq all[1].origin, doUser
    # No notice was produced, because nothing was overridden.
    ckEq notices(loaded.problems).len, 0

  test "a user file offered as part of the project's set is refused":
    # The separation is a CHECKED property of the call, not a convention the
    # caller is trusted with — and this is the only function that could merge
    # them, so the check lives inside it.
    let smuggled = pointsFile(GoodPoints, origin = doUser,
                              path = "<user>/points.toml")
    let loaded = loadProjectDefinitions([smuggled])
    ckRefused loaded.problems, pdcOriginMixed
    ckEq loaded.project.collections.len, 0
    # And the mirror: a project file offered as the user's.
    let mirrored = loadProjectDefinitions([], [pointsFile(GoodPoints)])
    ckRefused mirrored.problems, pdcOriginMixed
    ckEq mirrored.user.collections.len, 0

  test "an executable-tier file is reported and the declarative tier still loads":
    # §2.1's boundary, as an outcome rather than as a rule. The `.wasm` sits
    # beside the `.toml`, the `.toml` loads, and the `.wasm` produces a
    # sentence and nothing else.
    let code = DefinitionFile(kind: dfkVisualiserCode, origin: doProject,
                              path: definitionPath("", dfkVisualiserCode),
                              text: "")
    let loaded = loadProjectDefinitions([pointsFile(GoodPoints), code])
    ckNoted loaded.problems, pdnExecutableTierPresent
    # THE DECLARATIVE TIER LOADED.
    ckEq loaded.project.collections.len, 1
    ckEq loaded.project.collections[0].points.len, 2
    # AND THE LOAD IS OK: a notice is not a failure.
    ck loaded.isOk()
    ckEq refusals(loaded.problems).len, 0

  test "scope depth is the ordering, and it is a single number":
    ckEq scopeDepth(""), 0
    ckEq scopeDepth("a"), 1
    ckEq scopeDepth("a/b"), 2
    ckEq scopeDepth("packages/core/src"), 3

  test "the load describes itself in one block a user can read":
    let loaded = loadProjectDefinitions(
      [pointsFile(GoodPoints), visualisersFile(GoodVisualisers),
       scratchpadFile(GoodScratchpad)])
    let text = describeLoad(loaded)
    ck text.contains("1 collection(s)")
    ck text.contains("2 visualiser rule(s)")
    ck text.contains("2 diff selection(s)")
    ckEq loaded.problems.len, 0
    ck loaded.isOk()

# ---------------------------------------------------------------------------
# 6. Re-resolution against an edited file (§4)
# ---------------------------------------------------------------------------

const OriginalSource = @[
  "import std/strutils",          # 1
  "",                             # 2
  "proc handleRequest(r: Req) =", # 3
  "  let url = r.url",            # 4
  "  log url",                    # 5
  "",                             # 6
  "proc handleRetry(r: Req) =",   # 7
  "  discard",                    # 8
]

const EditedSource = @["# a new header comment", "# and another"] & OriginalSource
  ## The same file with two lines inserted at the top — the edit that would
  ## have silently moved every bare line number in the collection.

const DuplicateAnchors = @["fn helper()", "  body", "fn helper()", "  other"]

const ReindentedSource = @["    proc handleRequest(r: Req) =", "      discard"]

const ShortSource = @["fn main()", "  body"]

# THE LINE LISTS ARE MODULE-LEVEL `const`s AND NOT TEST LOCALS, and that is a
# Nim fact rather than a preference: `unittest`'s `test` body is a `block` at
# module scope, so a `var` declared in one is a GLOBAL, and a `{.gcsafe.}`
# closure — which is what `resolveCollection`'s `sources` parameter requires,
# by design, so that a caller cannot pass a lookup that reads the clock —
# cannot capture one. Hoisting them is what lets the suite pass REAL closures
# rather than weakening the parameter's pragma to accept a double.

func linesFor(path: string; lines: seq[string]; only: string): SourceFile =
  ## One source lookup, shared by the cases below. `only` is the single path
  ## that exists; everything else is absent, which is how `prFileAbsent`
  ## becomes reachable without a filesystem.
  if path == only: SourceFile(present: true, lines: lines)
  else: SourceFile(present: false)

suite "PLAT-11: a collection re-resolved against an edited file":

  test "each point reports resolved, moved or unresolvable — and none is dropped":
    # THE MILESTONE'S THIRD INTEGRATION TEST. The subject is one collection of
    # four points, re-resolved against a file edited in one go: two lines
    # inserted at the top, one anchor deleted, one file removed.
    var c = PointCollection(name: "the request path", file: ".codetracer/points.toml")
    c.points.add PointDefinition(
      kind: pkTracepoint, path: "router.nim",
      anchor: PointAnchor(text: "proc handleRequest", occurrence: 1, offset: 1,
                          line: 4))
    c.points.add PointDefinition(
      kind: pkBreakpoint, path: "router.nim",
      anchor: PointAnchor(text: "proc handleRetry", occurrence: 1, offset: 1,
                          line: 8))
    c.points.add PointDefinition(
      kind: pkBreakpoint, path: "router.nim",
      anchor: PointAnchor(text: "proc handleTimeout", occurrence: 1, offset: 0,
                          line: 12))
    c.points.add PointDefinition(
      kind: pkBreakpoint, path: "gone.nim",
      anchor: PointAnchor(text: "fn main", occurrence: 1, offset: 0, line: 1))

    let sources = proc (path: string): SourceFile {.noSideEffect, gcsafe,
                                                    raises: [].} =
      linesFor(path, EditedSource, "router.nim")

    let r = resolveCollection(c, sources)

    # ONE ENTRY PER DECLARED POINT. This is the assertion the whole module is
    # shaped around: there is no `continue` in the resolver's loop.
    ckEq r.points.len, c.points.len
    ckEq r.points.len, 4

    # 1. Moved: the anchor is two lines lower than the recorded hint, and the
    #    point followed it rather than staying at line 4.
    ckEq r.points[0].outcome, prMoved
    ckEq r.points[0].line, 6
    ck r.points[0].detail.contains("was at line 4")
    ck r.points[0].detail.contains("now at line 6")
    ck isUsable(r.points[0].outcome)

    # 2. Moved as well, at a different distance — because the SECOND anchor
    #    moved by the same two lines, which is what an insertion at the top
    #    does and is exactly the failure a bare line number would have had.
    ckEq r.points[1].outcome, prMoved
    ckEq r.points[1].line, 10

    # 3. Unresolvable: the anchored code does not exist. REPORTED, not
    #    dropped, and with the anchor text in the message so the author knows
    #    what to look for.
    ckEq r.points[2].outcome, prUnresolved
    ckEq r.points[2].line, 0
    ck r.points[2].detail.contains("proc handleTimeout")
    ck not isUsable(r.points[2].outcome)

    # 4. The file itself is gone, which is its OWN outcome: "the file you
    #    named is not in this checkout" and "the code you anchored to has been
    #    rewritten" send a reader to different places.
    ckEq r.points[3].outcome, prFileAbsent
    ckEq r.points[3].line, 0
    ck r.points[3].detail.contains("gone.nim")

    # AND THE FOUR COUNTS SUM TO THE DECLARED COUNT. A point that met no
    # outcome would show up here rather than being invisible.
    let counted = counts(r)
    var total = 0
    for o in PointOutcome: total += counted[o]
    ckEq total, 4
    ckEq counted[prMoved], 2
    ckEq counted[prUnresolved], 1
    ckEq counted[prFileAbsent], 1
    ckEq unresolvedCount(r), 2
    ck summarise(r).contains("4 point(s)")

  test "an unedited file resolves cleanly, which is what makes 'moved' mean something":
    var c = PointCollection(name: "c", file: ".codetracer/points.toml")
    c.points.add PointDefinition(
      kind: pkTracepoint, path: "router.nim",
      anchor: PointAnchor(text: "proc handleRequest", occurrence: 1, offset: 1,
                          line: 4))
    let sources = proc (path: string): SourceFile {.noSideEffect, gcsafe,
                                                    raises: [].} =
      linesFor(path, OriginalSource, "router.nim")
    let r = resolveCollection(c, sources)
    ckEq r.points[0].outcome, prResolved
    ckEq r.points[0].line, 4
    ckEq r.points[0].detail, ""

  test "a definition that recorded no line hint resolves rather than 'moves'":
    # `line` is a hint and `anchor` is the locator. A definition written by
    # hand, with no hint, is not perpetually "moved".
    var c = PointCollection(name: "c")
    c.points.add PointDefinition(
      kind: pkBreakpoint, path: "router.nim",
      anchor: PointAnchor(text: "proc handleRetry", occurrence: 1))
    let sources = proc (path: string): SourceFile {.noSideEffect, gcsafe,
                                                    raises: [].} =
      linesFor(path, OriginalSource, "router.nim")
    ckEq resolveCollection(c, sources).points[0].outcome, prResolved

  test "the occurrence is what stops a point sliding onto a new duplicate":
    var c = PointCollection(name: "c")
    c.points.add PointDefinition(
      kind: pkBreakpoint, path: "a.rs",
      anchor: PointAnchor(text: "fn helper", occurrence: 2, offset: 1, line: 4))
    c.points.add PointDefinition(
      kind: pkBreakpoint, path: "a.rs",
      anchor: PointAnchor(text: "fn helper", occurrence: 3, offset: 0))
    let sources = proc (path: string): SourceFile {.noSideEffect, gcsafe,
                                                    raises: [].} =
      linesFor(path, DuplicateAnchors, "a.rs")
    let r = resolveCollection(c, sources)
    ckEq r.points[0].outcome, prResolved
    ckEq r.points[0].line, 4
    # A third occurrence that does not exist is unresolvable, and the message
    # says which occurrence it wanted.
    ckEq r.points[1].outcome, prUnresolved
    ck r.points[1].detail.contains("3rd time")

  test "re-indentation does not unresolve a point":
    # A formatter re-indenting a whole file must not unresolve every point in
    # it, which is why the comparison is on the STRIPPED line.
    var c = PointCollection(name: "c")
    c.points.add PointDefinition(
      kind: pkBreakpoint, path: "a.nim",
      anchor: PointAnchor(text: "proc handleRequest", occurrence: 1))
    let sources = proc (path: string): SourceFile {.noSideEffect, gcsafe,
                                                    raises: [].} =
      linesFor(path, ReindentedSource, "a.nim")
    ckEq resolveCollection(c, sources).points[0].outcome, prResolved

  test "an offset past the end of the file is unresolvable, never clamped":
    # A point clamped to the last line points at something arbitrary, which is
    # the silent mislocation the anchor exists to prevent.
    var c = PointCollection(name: "c")
    c.points.add PointDefinition(
      kind: pkBreakpoint, path: "a.nim",
      anchor: PointAnchor(text: "fn main", occurrence: 1, offset: 500))
    let sources = proc (path: string): SourceFile {.noSideEffect, gcsafe,
                                                    raises: [].} =
      linesFor(path, ShortSource, "a.nim")
    let r = resolveCollection(c, sources)
    ckEq r.points[0].outcome, prUnresolved
    ckEq r.points[0].line, 0
    ck r.points[0].detail.contains("past the end")

  test "every outcome has a word, and a usability answer":
    var checkedOutcomes = 0
    for o in PointOutcome:
      inc checkedOutcomes
      ck describe(o).len > 0
    ckEq checkedOutcomes, 4
    ck isUsable(prResolved)
    ck isUsable(prMoved)
    ck not isUsable(prUnresolved)
    ck not isUsable(prFileAbsent)

# ---------------------------------------------------------------------------
# 7. The structural claim: this package cannot reach a machine
# ---------------------------------------------------------------------------

const ScanSubjects = [
  (name: "diagnostics",
   source: staticRead("project_definitions/diagnostics.nim"),
   imports: @["import std/strutils"]),
  (name: "containment",
   source: staticRead("project_definitions/containment.nim"),
   imports: newSeq[string]()),
  (name: "layout",
   source: staticRead("project_definitions/layout.nim"),
   imports: @["import ./diagnostics"]),
  (name: "model",
   source: staticRead("project_definitions/model.nim"),
   imports: @["import ./diagnostics", "import ./layout",
              "import ../value_presentation/vocabulary as presentation_vocabulary"]),
  (name: "parse",
   source: staticRead("project_definitions/parse.nim"),
   imports: @["import std/[strutils, tables]", "import ../toml_subset",
              "import ./diagnostics", "import ./containment",
              "import ./layout", "import ./model"]),
  (name: "load",
   source: staticRead("project_definitions/load.nim"),
   imports: @["import std/[algorithm, strutils, tables]",
              "import ./diagnostics", "import ./containment",
              "import ./layout", "import ./model", "import ./parse"]),
  (name: "resolve",
   source: staticRead("project_definitions/resolve.nim"),
   imports: @["import std/strutils", "import ./model"]),
  (name: "toml_subset",
   source: staticRead("toml_subset.nim"),
   imports: @["import std/[strutils, tables]"]),
  # PLAT-2's, not this package's — and in the scan anyway, because it is the
  # ONE module outside `project_definitions/` that this package's closure
  # reaches, and a closure claim that stopped at the package boundary would be
  # a claim about a subset of what the code can touch.
  # `ci/test/value-presentation-boundary.sh` is that module's primary guard
  # and catches shapes this scan cannot (a module-scope `let` initialised from
  # a call, a `{.cast(noSideEffect).}`); this is the second reader, looking
  # for the same thing from the other side.
  (name: "value_presentation/vocabulary",
   source: staticRead("value_presentation/vocabulary.nim"),
   imports: @["import std/[strutils, unicode]"]),
]

const ForbiddenNeedles = [
  # Filesystem.
  "std/os", "std/paths", "std/dirs", "std/files", "std/syncio",
  "readFile", "writeFile", "open(", "fileExists", "dirExists", "walkDir",
  "getFileSize", "staticRead", "gorge", "staticExec",
  # Process.
  "std/osproc", "startProcess", "execShellCmd", "execProcess", "execCmd",
  # Network.
  "std/net", "std/httpclient", "std/asyncnet", "newSocket", "std/uri",
  # Dynamic loading.
  "std/dynlib", "loadLib", "dlopen", "importc", "{.compile", "{.link",
  "{.emit", "{.passL", "{.passC",
  # Ambient state a pure declarative reader has no business reading.
  "getEnv", "putEnv", "std/envvars", "std/times", "getTime", "epochTime",
  "std/random", "std/streams",
]

func codeLines(source: string): seq[string] =
  ## Lines with the module's own DOC COMMENTS and `#` comments removed.
  ##
  ## Verification-Harness-Traps §4d: a scan pattern that matches the module's
  ## own prose is satisfied by prose. Every module in this package DISCUSSES
  ## `readFile`, `startProcess` and `getEnv` in its header — that is what the
  ## headers are for — so a scan over raw lines would find every needle in
  ## every file and prove nothing at all.
  for line in source.splitLines():
    let s = line.strip()
    if s.startsWith("#"): continue
    var cut = line
    let hash = cut.find('#')
    if hash >= 0: cut = cut[0 ..< hash]
    if cut.strip().len == 0: continue
    result.add cut

suite "PLAT-11: the loader has no way to reach a machine":

  test "the scanner finds a planted needle, so a clean scan means something":
    # Verification-Harness-Traps §4: a scanner that finds NOTHING passes every
    # "must not contain" check ever written. The control is planted here and
    # checked before any subject is scanned.
    let planted = "## a header mentioning readFile in prose\n" &
                  "import std/strutils\n" &
                  "proc f() = discard readFile(\"x\")\n"
    var found = false
    for l in codeLines(planted):
      if l.contains("readFile"): found = true
    ck found
    # And the comment stripper removes the prose rather than the code: the
    # header line is gone, the call is not.
    ckEq codeLines(planted).len, 2
    var proseSurvived = false
    for l in codeLines(planted):
      if l.contains("in prose"): proseSurvived = true
    ck not proseSurvived

  test "no module in this package mentions a filesystem, process or network name":
    var checkedSubjects = 0
    var checkedNeedles = 0
    for subject in ScanSubjects:
      inc checkedSubjects
      checkpoint("subject: " & subject.name)
      for needle in ForbiddenNeedles:
        inc checkedNeedles
        var hit = ""
        for l in codeLines(subject.source):
          if l.contains(needle): hit = l.strip()
        if hit.len > 0:
          checkpoint("needle '" & needle & "' at: " & hit)
        ckEq hit, ""
    ckEq checkedSubjects, 9
    ckEq checkedNeedles, 9 * ForbiddenNeedles.len

  test "and each module's import list is exactly what it is declared to be":
    # The import CLOSURE, not merely the absence of needles. A module could
    # import something innocuous that itself reaches a machine, so the list is
    # asserted verbatim and a new import is a red test rather than a silent
    # widening of what this package can touch.
    var checkedSubjects = 0
    for subject in ScanSubjects:
      inc checkedSubjects
      checkpoint("subject: " & subject.name)
      var imports: seq[string] = @[]
      for l in codeLines(subject.source):
        let s = l.strip()
        if s.startsWith("import "): imports.add s
      ckEq imports, subject.imports
    ckEq checkedSubjects, 9

  test "the whole closure is four std modules, and they are these four":
    # Reduced to the MODULE NAMES rather than the import statements, because
    # "which std modules can this code reach" is the question and
    # `import std/[a, b]` and `import std/a` are two spellings of one answer.
    var stdModules = initHashSet[string]()
    for subject in ScanSubjects:
      for imp in subject.imports:
        if not imp.startsWith("import std/"): continue
        var body = imp["import std/".len .. ^1]
        body = body.replace("[", "").replace("]", "")
        for name in body.split(','):
          stdModules.incl name.strip()
    ckEq stdModules.len, 4
    ck "strutils" in stdModules
    ck "tables" in stdModules
    ck "algorithm" in stdModules
    ck "unicode" in stdModules
    # Named negatively as well, because the positive list would still pass if
    # a fifth arrived: the count above is what forbids that, and these are the
    # ones whose arrival would matter most.
    for forbidden in ["os", "osproc", "streams", "net", "httpclient",
                      "dynlib", "times", "envvars", "random", "json"]:
      ck forbidden notin stdModules

# ---------------------------------------------------------------------------

suite "PLAT-11: the counted-assertion tally":

  test "the tally":
    # Verification-Harness-Traps §4c: a per-check assertion count is a
    # fingerprint, and a check that asserts its own count turns a silent skip
    # into a red run with no second run and no human noticing.
    check countedAssertions == ExpectedAssertions
