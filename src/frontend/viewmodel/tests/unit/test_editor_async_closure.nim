## PLAT-29 — THE IMPORT-CLOSURE CHECK, AND THE SEVEN ROUTES PAST A TEXT SCAN.
##
## Subject: `ci/test/editor-import-closure.sh`, driven against the REAL tree and
## against eight synthetic trees, one per route.
##
## =========================================================================
## WHY THIS SUITE IS SEPARATE FROM THE OTHER TWO, AND WHY IT IS NATIVE-ONLY
## =========================================================================
##
## The gate is a shell script, so grading it means spawning one. `std/osproc`'s
## `startProcess` is `posix_spawnp`, which emscripten declares and does not
## define and which `nim js` has not got at all — so this file is subtracted
## from `vm-unit-js` and `vm-unit-wasm` by name, exactly as
## `test_sdk_facade_boundary.nim` is and for the same reason. The other two
## PLAT-29 suites carry no process and run on all three backends.
##
## **THE REJECTION IS THE FIX RATHER THAN A `when` GUARD**, and this file is the
## sharp version of why: its central claim is *the gate refused this tree*, and
## that claim is GREEN, for free, on a target that could not have run the gate
## under any circumstances.
##
## =========================================================================
## THE SEVEN ROUTES, AND WHY EACH IS A CASE
## =========================================================================
##
## PLAT-29's gate says the closure check must use PLAT-8's hardened scanner
## *"rather than a sixth one"*, because **six separate routes past a naive
## import scan were found by PLAT-7's five verification passes and are already
## closed in `ci/lib/nim-imports.sh`**. Each is a case here because each was
## once a route something got through — measured, in this repository, with a
## gate printing `15 checks, 0 failing` over a tree that had already escaped.
##
## | route | what defeats a naive scanner | what refuses it here |
## |---|---|---|
## | 1 | a NEWLINE-CONTINUED import — `import` alone on its line, the spec indented under it. 138 files under `src/` are written this way, and a keyword test of `/^import[ \t]/` sees none of them | the extractor's `collecting` buffer |
## | 2 | a BLOCK COMMENT sharing the import's line | the extractor REFUSES the line rather than guessing at nim's comment nesting, and the gate turns a refusal into a finding. Measured: the case was written expecting the allow-list to catch it, and a different mechanism did |
## | 3 | the MODULE-QUALIFIED spelling through one hop of indirection — the module that imports the async surface is not the module the rule is about | THE CLOSURE. This is the route a per-file scan cannot see at all, and it is why this milestone moved the claim from a scan to a closure |
## | 4 | nim's FOREIGN-FUNCTION PRAGMAS, which need no import — one line of `{.importc: "system", header: …}` is every effect at once | the denied-pragma table, matched inside `{. … .}` spans |
## | 5 | THE CALL SITE rather than the rendering — a conditional import on a CONTINUATION line, which the extractor's self-check used to be asked about only on non-continuation lines | the extractor's refusal, surfaced by the gate as a finding rather than discarded |
## | 6 | `export … except`, which narrows ONE path and cannot narrow a second one a module opens for itself | THE ALLOW-LIST, which refuses the module by spec and does not care what the export clause says |
## | 7 | nothing — a plain `import std/asyncdispatch`. The planted arm, which must redden before the control digests are re-recorded (§32) | the allow-list |
##
## **AN EIGHTH TREE ARRIVED WITH PLAT-31 AND IT IS NOT AN ASYNC ROUTE.** The
## gate grew a seventh CHECK — *"no module of the keymap package may appear in
## the editing core's closure"* (`Editing-Operations-And-Keymaps.md` §1: the
## keymap layer is EXTERNAL) — and PLAT-31's verification gate asks for it
## *"by PLAT-29's instrument, with a planted import"*. `rtKeymapImport` is that
## plant, and the case asserts not only that the gate reddened but that the
## SEVENTH check is what reddened and the other three found nothing: the
## planted keymap module is deliberately spotless, so a gate that failed it for
## an allow-list reason would be the misdirected verdict route 3 already cost
## this file once.
##
## Routes 3 and 6 are refused by the ALLOW-LIST and route 4 by the PRAGMA
## TABLE, and they are kept apart deliberately: Verification-Harness-Traps §32a
## is that two mechanisms guarding one property silently halve the older one's
## mutation coverage unless each gets evidence only it can satisfy.
##
## =========================================================================
## THE CONTROL IS IN THE SAME SUITE AND IS THE SAME TREE
## =========================================================================
##
## §7b: an unfalsified negative control is a self-comparison wearing a
## negation. "The gate refused this tree" is satisfied by a gate that refuses
## every tree, by a temp directory that was never created, and by a script path
## with a typo in it. So the last case builds the SAME tree with the plant
## removed and requires the gate to pass it — one builder, two callers, and the
## difference between them is the planted line and nothing else.
##
## §29: every assertion goes through `counted`, which is a template.
##
## Compile and run (from the repository root):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_editor_async_closure.nim

import std/[os, osproc, strutils, unittest]

import ../../../../common/editor_core_admission

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 50

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  .parentDir.parentDir
  ## `src/frontend/viewmodel/tests/unit/<this file>` — six hops.

const Gate = "ci/test/editor-import-closure.sh"

const GateTimeoutSeconds = 180
  ## EVERY WAIT IS BOUNDED. *"A test that hangs on the defect it detects
  ## reports the defect as its absence."* The gate walks a closure with a
  ## `while` loop in it; a resolver that started returning a path it had
  ## already visited would spin, and a spinning gate must fail the case rather
  ## than the lane.

type GateRun = object
  code: int
  output: string

proc runGate(editorDir, searchRoot: string): GateRun =
  ## The gate, over a named tree. ONE runner, called by the rule's cases and by
  ## the control (Verification-Harness-Traps §30) — a control that spawned the
  ## gate through a second copy of this could agree with itself while the rule's
  ## copy was broken.
  let (output, code) = execCmdEx(
    # `KEYMAP_PACKAGE` names the directory the gate's seventh check matches.
    # The synthetic tree is under `/tmp` and cannot carry the real path, so the
    # rule is parameterised rather than the check being weakened to a bare
    # `*keymap*` — which would match `src/common/key_names.nim` and make the
    # rule about a name instead of about a package. The real run uses the
    # default, and this is the only caller that overrides it.
    "KEYMAP_PACKAGE=keymap timeout " & $GateTimeoutSeconds & " bash " &
    quoteShell(Gate) &
    " --editor-dir=" & quoteShell(editorDir) &
    " --search-root=" & quoteShell(searchRoot),
    workingDir = repoRoot)
  GateRun(code: code, output: output)

# ---------------------------------------------------------------------------
# The synthetic tree. ONE builder; the route is a parameter.
# ---------------------------------------------------------------------------

type Route = enum
  rtClean          ## the control
  rtNewlineImport
  rtBlockComment
  rtReExportHop
  rtFfiPragma
  rtCallSiteConditional
  rtExportExcept
  rtPlainImport
  rtKeymapImport
    ## **PLAT-31's ROUTE, AND IT IS NOT AN ASYNC ROUTE AT ALL.** The gate grew
    ## a seventh check — *"no module of the keymap package may appear in the
    ## editing core's closure"* — and PLAT-31's verification gate asks for it
    ## *"by PLAT-29's instrument, with a planted import"*. This is that plant.
    ##
    ## It lives here rather than in a second harness for the reason PLAT-29's
    ## own header gives about the scanner: the seven routes past a text scan
    ## are closed in `ci/lib/nim-imports.sh`, and a plant driven through a
    ## second builder would be planted against a tree the real routes were
    ## never proved over. One builder, one runner, one more parameter.

const RouteCount = ord(high(Route)) - ord(low(Route)) + 1

proc coreBody(route: Route): string =
  ## The root module of the synthetic editor directory.
  ##
  ## Its header names a denied identifier IN PROSE for every route, including
  ## the control: the gate's comment-stripper control needs a subject, and a
  ## tree that gave it none would make the CONTROL red and tell us nothing
  ## about the plant.
  result = """
## A synthetic editor-core module. This header mentions `addTimer` and
## `epochTime` in prose and in prose only, which is what the gate's
## comment-stripper control is about.

"""
  case route
  of rtClean:
    result.add "import ../lib/helper\n"
  of rtNewlineImport:
    # ROUTE 1 — the spelling 138 files under `src/` use, and the one a keyword
    # test of `/^import[ \t]/` cannot see.
    result.add "import ../lib/helper\nimport\n  std/asyncdispatch\n"
  of rtBlockComment:
    # ROUTE 2 — a block comment sharing the import's line.
    result.add "import ../lib/helper\n#[ a note ]# import std/asyncdispatch\n"
  of rtReExportHop, rtExportExcept:
    # ROUTES 3 AND 6 — this module is clean; the helper is not. A per-file scan
    # over the editor directory sees nothing at all here.
    result.add "import ../lib/helper\n"
  of rtFfiPragma:
    # ROUTE 4 — no import at all.
    result.add "import ../lib/helper\n"
    result.add "proc cSystem(cmd: cstring): cint " &
               "{.importc: \"system\", header: \"<stdlib.h>\".}\n"
    result.add "proc unused(): cint = cSystem(\"true\")\n"
  of rtCallSiteConditional:
    # ROUTE 5 — a conditional import on a CONTINUATION line of a multi-line
    # import, which is the shape the extractor's self-check was once not asked
    # about. It must become a REFUSAL, not a silent miss.
    result.add "import\n  ../lib/helper; when '#' == '#': import std/asyncdispatch\n"
  of rtPlainImport:
    # ROUTE 7 — the planted arm. Nothing clever; it is here so a gate that had
    # stopped working entirely would be caught by the simplest possible input.
    result.add "import ../lib/helper\nimport std/asyncdispatch\n"
  of rtKeymapImport:
    # PLAT-31 — the editing core reaching INTO the keymap package. The planted
    # module is otherwise spotless: it imports nothing denied, binds no foreign
    # function and names no async primitive, so the ONLY check that can fail is
    # the seventh. A plant that also tripped the allow-list would redden the
    # gate for a reason that has nothing to do with the rule being tested,
    # which is the misdirected verdict route 3 already cost this file once.
    result.add "import ../lib/helper\nimport ../keymap/editing_keymap\n"
  result.add "\nproc value*(): int = 41 + 1\n"

proc helperBody(route: Route): string =
  case route
  of rtReExportHop:
    # The indirection: the helper imports and re-exports the async surface, so
    # the ROOT module can spell `asyncdispatch.poll` without importing it.
    "import std/asyncdispatch\nexport asyncdispatch\n" &
      "proc helped*(): int = 1\n"
  of rtExportExcept:
    # `export … except` narrows ONE path. The allow-list refuses the module by
    # spec and does not consult the clause at all, which is the whole point.
    "import std/times\nexport times except now\n" &
      "proc helped*(): int = 2\n"
  else:
    "proc helped*(): int = 3\n"

proc buildTree(base: string; route: Route): string =
  ## Returns the editor directory. ONE builder for every route, so the only
  ## difference between the control's tree and a planted one is the plant.
  ##
  ## **THE HELPER LIVES OUTSIDE THE EDITOR DIRECTORY, AND THAT IS THE WHOLE
  ## POINT OF ROUTES 3 AND 6.** It was inside it for one afternoon, and the
  ## mutation harness caught it: arm `A3` removes the BFS's enqueue — turning
  ## the closure back into the per-file scan this milestone replaced — and
  ## route 3 STAYED GREEN, because a helper in the root directory is a ROOT and
  ## a root is scanned whether or not anything walks to it. The case was
  ## reporting a property it was not testing, and the verdict that said so was
  ## `MISDIRECTED` rather than `SURVIVED`: the arm still killed something, just
  ## not the thing it names.
  let editorDir = base / "editor"
  let libDir = base / "lib"
  createDir(editorDir)
  createDir(libDir)
  writeFile(editorDir / "core.nim", coreBody(route))
  writeFile(libDir / "helper.nim", helperBody(route))
  if route == rtKeymapImport:
    # The synthetic keymap package, BESIDE the editor directory and not inside
    # it — for routes 3 and 6's reason, which the header above spends a
    # paragraph on: a module in the root directory is a ROOT and is scanned
    # whether or not anything walks to it, so a plant placed there would pass
    # even if the closure walk were removed entirely.
    let keymapDir = base / "keymap"
    createDir(keymapDir)
    writeFile(keymapDir / "editing_keymap.nim",
              "## A synthetic keymap module. It is deliberately CLEAN —\n" &
              "## nothing denied, no pragma, no std import at all — so the\n" &
              "## only check it can trip is the keymap-package rule itself.\n" &
              "proc resolveKey*(k: string): string = k\n")
  editorDir

proc withTree(route: Route): GateRun =
  let base = getTempDir() / "ct-plat29-closure-" & $ord(route) & "-" &
             $getCurrentProcessId()
  removeDir(base)
  createDir(base)
  defer: removeDir(base)
  let editorDir = buildTree(base, route)
  runGate(editorDir, base)

# ===========================================================================
suite "PLAT-29 — the import-closure check, on the real tree":
# ===========================================================================

  test "THE EDITOR MODEL'S CLOSURE IS CLEAN, AND IT IS NOT A CLOSURE OF ONE":
    let (output, code) = execCmdEx(
      "timeout " & $GateTimeoutSeconds & " bash " & quoteShell(Gate),
      workingDir = repoRoot)
    echo output.strip()
    counted code == 0
    counted output.contains("0 failing")
    # NON-VACUITY, and it is the assertion that matters most here: a gate that
    # walked one module would print `0 failing` just as happily. The closure
    # has to be bigger than the root set, which is only true if the walk
    # actually followed an edge — and bigger than THIS repository, which is
    # only true if it followed one into `isonim-tui`, where the grapheme
    # segmenter the whole coordinate model rests on lives.
    let listed = execCmdEx(
      "bash " & quoteShell(Gate) & " --list-closure", workingDir = repoRoot)
    var rootModules = 0
    var closureModules = 0
    var siblingModules = 0
    for line in listed[0].splitLines():
      if line.len == 0: continue
      inc closureModules
      if line.startsWith(EditorCoreRootDir): inc rootModules
      if line.startsWith("/"): inc siblingModules
    counted rootModules > 0
    counted closureModules > rootModules
    counted siblingModules > 0
    checkpoint($closureModules & " module(s) in the closure, " & $rootModules &
               " of them roots, " & $siblingModules & " in sibling packages")
    # AND THE TABLES THE GATE PARSED ARE THE TABLES THIS MODULE DECLARES.
    # One predicate, one function (§30): the gate prints what it parsed and
    # the Nim side asserts against its own array rather than against a second
    # copy of the list.
    counted output.contains($EditorCoreAllowedStdlibModules.len & "/" &
                            $EditorCoreAllowedStdlibModules.len & " allow-list")
    counted output.contains($EditorCoreDeniedNames.len & "/" &
                            $EditorCoreDeniedNames.len & " denied name(s)")
    counted isEditorCoreAllowedStdlibModule("std/unicode")
    counted not isEditorCoreAllowedStdlibModule("std/asyncdispatch")
    counted not isEditorCoreAllowedStdlibModule("std/times")

# ===========================================================================
suite "PLAT-29 — the seven routes past a text scan":
# ===========================================================================

  test "ROUTE 1 — a NEWLINE-CONTINUED import is seen":
    let run = withTree(rtNewlineImport)
    counted run.code != 0
    counted run.output.contains("VIOLATION editor-core-imports-allow-listed")
    counted run.output.contains("std/asyncdispatch")

  test "ROUTE 2 — an import sharing its line with a BLOCK COMMENT is REFUSED, not missed":
    # MEASURED RATHER THAN ASSUMED, and the measurement moved this case's
    # assertion. The first spelling of it expected the allow-list to name
    # `std/asyncdispatch`, and the extractor does something better: it REFUSES
    # to analyse the line at all, because reading a block comment correctly
    # means implementing nim's comment nesting in awk and getting it subtly
    # wrong is a silent MISS. The gate turns that refusal into a finding, so
    # the route is closed — by a different mechanism from the one the case was
    # written against, which is the only reason the case is worth running.
    let run = withTree(rtBlockComment)
    counted run.code != 0
    counted run.output.contains("VIOLATION import-specs-analysable")
    counted run.output.contains("#[ a note ]# import std/asyncdispatch")
    # AND NOT SILENTLY ADMITTED: the allow-list never saw the spec, so a gate
    # that only ran check 2 would have passed this tree.
    counted not run.output.contains("VIOLATION editor-core-imports-allow-listed")

  test "ROUTE 3 — one hop of INDIRECTION, which a per-file scan cannot see at all":
    # THE ROUTE THIS MILESTONE EXISTS FOR. `core.nim` imports nothing but a
    # local helper; a scan over the editor directory's own text finds no
    # `asyncdispatch` and no `await` anywhere in it.
    let run = withTree(rtReExportHop)
    counted run.code != 0
    counted run.output.contains("VIOLATION editor-core-imports-allow-listed")
    counted run.output.contains("helper.nim: std/asyncdispatch")
    # AND THE ROOT MODULE IS INNOCENT, which is what makes this a closure test
    # rather than a scan test: the finding names the HELPER.
    counted not run.output.contains("core.nim: std/asyncdispatch")

  test "ROUTE 4 — a FOREIGN-FUNCTION PRAGMA, which needs no import":
    let run = withTree(rtFfiPragma)
    counted run.code != 0
    counted run.output.contains("VIOLATION editor-core-binds-no-foreign-function")
    counted run.output.contains("importc")
    # Refused by the PRAGMA TABLE and by nothing else — the allow-list has
    # nothing to refuse here, and §32a is why that is stated as its own
    # assertion rather than left implied.
    counted not run.output.contains("VIOLATION editor-core-imports-allow-listed")

  test "ROUTE 5 — THE CALL SITE rather than the rendering: a refusal is a finding":
    # `ci/lib/nim-imports.sh` refuses to ANALYSE a line it cannot read rather
    # than guessing, and its header states the debt a third caller owes:
    # *"a case in its own suite that fails when a refused line is not
    # reported."* This is that case.
    let run = withTree(rtCallSiteConditional)
    counted run.code != 0
    counted run.output.contains("VIOLATION import-specs-analysable")
    counted run.output.contains("Refusing to analyse is safe for a guard")
    # ITS OWN LINE, not route 2's: two routes end at the same check through two
    # different mechanisms in the extractor — a comment strip and the
    # per-piece `imports_unread` self-check — and evidence that cannot tell
    # them apart is evidence for neither (§32a).
    counted run.output.contains("when '#' == '#': import std/asyncdispatch")
    counted not run.output.contains("#[ a note ]#")

  test "ROUTE 6 — `export … except` narrows one path and not the other":
    let run = withTree(rtExportExcept)
    counted run.code != 0
    counted run.output.contains("VIOLATION editor-core-imports-allow-listed")
    counted run.output.contains("helper.nim: std/times")
    # A CLOCK IS THE ROW WHERE THIS LIST AND PLAT-8's VISIBLY DISAGREE, and the
    # disagreement is the reason the editor core has a list of its own:
    # `PluginAllowedStdlibModules` admits `std/times` because a clock is not a
    # mediated EFFECT; §11 refuses it because a clock is not DETERMINISTIC.
    counted not isEditorCoreAllowedStdlibModule("std/monotimes")

  test "ROUTE 7 — THE PLANTED IMPORT MUST REDDEN IT":
    let run = withTree(rtPlainImport)
    counted run.code != 0
    counted run.output.contains("VIOLATION editor-core-imports-allow-listed")
    counted run.output.contains("core.nim: std/asyncdispatch")

  test "PLAT-31 — A PLANTED KEYMAP IMPORT MUST REDDEN IT":
    # PLAT-31's verification gate: *"NO KEY TYPE IN THE CORE'S IMPORT CLOSURE,
    # by PLAT-29's instrument, with a planted import."* The instrument is this
    # gate and the plant is `rtKeymapImport`.
    let run = withTree(rtKeymapImport)
    checkpoint(run.output.strip())
    counted run.code != 0
    # THE FAILURE IS NAMED, AND IT IS THE SEVENTH CHECK. A case that only
    # asserted a non-zero exit would pass on a gate that reddened for any of
    # the other six reasons — which is the misdirected verdict, and this file
    # has paid for it once already.
    counted run.output.contains("VIOLATION editor-core-imports-no-keymap")
    counted run.output.contains("editing_keymap")
    # …and NOTHING ELSE fired. The planted module is clean, so the allow-list,
    # the pragma scan and the denied-name scan must all still pass: the plant
    # is evidence about ONE rule.
    counted not run.output.contains("VIOLATION editor-core-imports-allow-listed")
    counted not run.output.contains("VIOLATION editor-core-binds-no-foreign-function")
    counted not run.output.contains("VIOLATION editor-core-names-no-async-primitive")
    counted run.output.contains("1 failing")

  test "THE CONTROL — the same tree with nothing planted is GREEN":
    # §7b. Without this, every case above is satisfied by a gate that refuses
    # every tree, by a temp directory that was never created and by a typo in
    # the script path.
    let run = withTree(rtClean)
    checkpoint(run.output.strip())
    counted run.code == 0
    counted run.output.contains("0 failing")
    counted not run.output.contains("VIOLATION")
    # AND THE CONTROL'S OWN NON-VACUITY: the gate really walked the tree and
    # really found both modules, so "no violations" is a statement about two
    # modules rather than about zero.
    counted run.output.contains("1 root module(s)")
    counted run.output.contains("2 in the closure")
    counted RouteCount == 9

# ===========================================================================
suite "PLAT-29 — the tally":
# ===========================================================================
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
