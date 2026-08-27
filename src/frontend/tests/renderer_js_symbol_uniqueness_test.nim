## src/frontend/tests/renderer_js_symbol_uniqueness_test.nim
##
## The renderer ships as ONE JavaScript file evaluated in ONE global scope,
## so every top-level ``function`` the Nim JS backend emits must carry a
## unique name: a second declaration of the same name silently replaces the
## first, and every call site — including the ones that belonged to the
## replaced definition — ends up in the survivor.
##
## ``nim js --hotCodeReloading:on`` breaks that invariant.  Under HCR the JS
## backend names routines through ``idOrSig`` (Nim
## ``compiler/sighashes.nim``), whose ``hashProc`` hashes the routine's
## *type* and its owning module and **not its name**; collisions are
## disambiguated with ``BModule.sigConflicts``, a ``CountTable`` created
## fresh for every Nim module (``compiler/jsgen.nim``, ``newModule``).  Two
## routines that share a signature and an owning module but are emitted
## while two *different* modules are being generated therefore receive
## byte-identical JS names, each starting the collision counter at zero.
##
## A closure inside a generic proc is the canonical victim: every
## instantiation's inner lambda has the same ``proc ()`` type and the same
## owning module, so the lambda of ``f[A]`` and the lambda of ``f[B]``
## become one JS function and whichever is emitted last wins for both.  The
## surviving body carries the *other* instantiation's runtime type info, so
## ``nimCopy`` walks a ``string`` as though it were a record, reads a field
## the value does not have, and dies with
##
##     TypeError: Cannot read properties of undefined (reading 'slice')
##
## That is exactly how the CodeTracer renderer died on startup, on every
## session, before this guard existed: ``createMemo[string]`` (instantiated
## from ``debug_controls_vm``) ran ``createMemo[DeepReviewFileEntry]``'s
## closure body (instantiated from ``deepreview_vm``), and the memo's copy
## step tried to read ``.path`` off a Nim string.
##
## This suite is a behavioural test of the *shipping configuration*, not a
## lint on it.  It reads the JavaScript targets' own ``hotCodeReloading``
## setting out of ``repro.nim`` — the recipe that actually builds ``ui.js``
## — compiles a four-module fixture with exactly that setting, and requires
## the result to keep two instantiations of one generic apart, both in the
## emitted names and at run time under node.  If the flag ever comes back,
## this fails before anyone has to launch the app.
##
## Prerequisites: ``nim`` and ``node`` on ``PATH`` (both are in the dev
## shell).  A missing one fails loudly and names itself rather than
## skipping — a silent skip here would restore precisely the blind spot the
## suite exists to close.

import std/[os, osproc, strutils, unittest]

# ---------------------------------------------------------------------------
# Locating the repo and reading the renderer's build configuration
# ---------------------------------------------------------------------------

proc repoRootPath(): string =
  ## ``<repo>/src/frontend/tests/<this file>`` — four `parentDir` hops.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc jsTargetsEnablingHcr(reproNim: string): seq[string] =
  ## Every ``ctNimJs`` build action in ``repro.nim`` that passes
  ## ``hotCodeReloadingOnValue = true``.  ``ctNimJs`` is the template that
  ## wraps ``nim.js`` for all of CodeTracer's JavaScript outputs under
  ## reprobuild (ui.js, subwindow.js, index.js, server_index.js and the two
  ## renderer test bundles).
  ##
  ## It is NOT the only way a JS bundle gets built, which is why the test
  ## below scans whole files rather than only this one: ``src/Tuprules.tup``
  ## builds the same outputs on the legacy tup path (still the default of
  ## ``just build-once`` on Linux), ``justfile`` has two hand-written renderer
  ## recipes, and ``build_for_extension.sh`` builds ``ui.js`` for the VS Code
  ## extension.  All four carried the flag; all four must stay clear of it.
  result = @[]
  var current = ""
  for rawLine in reproNim.splitLines:
    let line = rawLine.strip
    if line.startsWith("let ") and line.contains("= ctNimJs("):
      # `let frontendUiJs = ctNimJs(` -> `frontendUiJs`
      current = line[4 .. ^1].split('=')[0].strip
    elif current.len > 0:
      if line.startsWith("target("):
        current = ""
      elif line.contains("hotCodeReloadingOnValue") and line.contains("true"):
        result.add current
        current = ""

const HandWrittenBuildFiles = [
  "justfile",              # `build-ui-js` / `build-ui-js-hmr`
  "src/Tuprules.tup",      # `!nim_js` / `!nim_node_subwindow`
  "build_for_extension.sh" # `ui.js` for the VS Code extension
]

proc handWrittenRecipesEnablingHcr(repoRoot: string): seq[string] =
  ## ``<file>: <line>`` for every non-comment line in the hand-written build
  ## definitions that passes ``--hotCodeReloading``.  Comment lines are skipped
  ## (all three files use ``#``) so each may keep saying *why* the flag is
  ## absent.
  result = @[]
  for relPath in HandWrittenBuildFiles:
    let path = repoRoot / relPath
    if not fileExists(path):
      continue
    for line in readFile(path).splitLines:
      let stripped = line.strip
      if stripped.startsWith("#"):
        continue
      if stripped.contains("--hotCodeReloading"):
        result.add relPath & ": " & stripped

proc countCtNimJsTargets(reproNim: string): int =
  ## Guard for the parser above: if ``repro.nim`` is ever restructured so the
  ## ``ctNimJs`` call sites stop matching, ``jsTargetsEnablingHcr`` would
  ## return an empty seq and this suite would pass by seeing nothing at all.
  result = 0
  for rawLine in reproNim.splitLines:
    let line = rawLine.strip
    if line.startsWith("let ") and line.contains("= ctNimJs("):
      inc result

# ---------------------------------------------------------------------------
# The fixture: one generic proc with an inner closure, instantiated at two
# different types from two different modules.
# ---------------------------------------------------------------------------
#
# ``storeInto`` mirrors ``storeReactiveValue`` in isonim's
# ``core/computation.nim`` (a ``var T`` destination written under
# ``when defined(js)``), and ``makeBox`` mirrors ``createMemo``'s shape: a
# generic proc that builds a closure over its own locals and calls it once.
# The two instantiating modules each run their instantiation at module scope
# so the generic body is emitted while *that* module is the one being
# generated — which is what puts the two lambdas in two different
# ``sigConflicts`` tables.

const FixtureGenLib = """
type
  Box*[T] = ref object
    value*: T

proc storeInto[T](dest: var T; value: T) =
  when defined(js):
    shallowCopy(dest, value)
  else:
    dest = value

proc makeBox*[T](fn: proc(): T): Box[T] =
  let box = Box[T]()
  let fill = proc() =
    storeInto(box.value, fn())
  fill()
  box
"""

const FixtureUsesString = """
import genlib

proc makeStringBox*(): Box[string] =
  makeBox[string](proc(): string = "abcd")

let stringBox* = makeStringBox()
"""

const FixtureUsesObject = """
import genlib

type
  Rec* = object
    a*: string
    b*: string
    n*: int

proc makeRecBox*(): Box[Rec] =
  makeBox[Rec](proc(): Rec = Rec(a: "x", b: "y", n: 7))

let recBox* = makeRecBox()
"""

const FixtureMain = """
import usesstring, usesobject

echo "string=", stringBox.value
echo "rec=", recBox.value.a, ",", recBox.value.b, ",", recBox.value.n
"""

const ExpectedStringLine = "string=abcd"
const ExpectedRecLine = "rec=x,y,7"

proc writeFixture(dir: string) =
  removeDir(dir)
  createDir(dir)
  writeFile(dir / "genlib.nim", FixtureGenLib)
  writeFile(dir / "usesstring.nim", FixtureUsesString)
  writeFile(dir / "usesobject.nim", FixtureUsesObject)
  writeFile(dir / "main.nim", FixtureMain)

proc duplicateTopLevelFunctions(bundle: string): seq[string] =
  ## Names declared by more than one top-level ``function NAME(`` in the
  ## bundle.  The JS backend emits every routine as a top-level declaration,
  ## so this is the whole namespace.
  var seen: seq[string] = @[]
  result = @[]
  for line in bundle.splitLines:
    if not line.startsWith("function "):
      continue
    let rest = line[9 .. ^1]
    let paren = rest.find('(')
    if paren <= 0:
      continue
    let name = rest[0 ..< paren]
    if name in seen:
      if name notin result:
        result.add name
    else:
      seen.add name

type FixtureBuild = object
  compiled: bool
  compilerOutput: string
  bundlePath: string

proc buildFixture(nimExe, workDir: string; hotCodeReloading: bool):
    FixtureBuild =
  writeFixture(workDir)
  let bundlePath = workDir / "bundle.js"
  var args = @["js", "--mm:refc", "--hints:off", "--warnings:off"]
  if hotCodeReloading:
    args.add "--hotCodeReloading:on"
  args.add("--out:" & bundlePath)
  args.add(workDir / "main.nim")
  let output = execProcess(nimExe, args = args,
                           options = {poStdErrToStdOut, poUsePath})
  FixtureBuild(compiled: fileExists(bundlePath), compilerOutput: output,
               bundlePath: bundlePath)

# ---------------------------------------------------------------------------

suite "Renderer JS bundle — symbol uniqueness":

  let repoRoot = repoRootPath()
  let reproNimPath = repoRoot / "repro.nim"

  test "repro.nim's JavaScript build actions are readable":
    check fileExists(reproNimPath)
    # The parser must actually see the `ctNimJs` call sites; a restructured
    # recipe that stops matching would otherwise silently make every check
    # below vacuous.
    check countCtNimJsTargets(readFile(reproNimPath)) >= 4

  test "no JavaScript bundle is built with Nim hot code reloading":
    ## `--hotCodeReloading:on` is not part of CodeTracer's HMR design:
    ## `codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload.md` lists
    ## "Compatibility with Nim hot-code-reloading (the
    ## `--hotCodeReloading:on` C-target feature)" under Non-Goals.  What the
    ## flag does buy on the JS backend is the aliasing measured below.
    let offenders = jsTargetsEnablingHcr(readFile(reproNimPath))
    if offenders.len > 0:
      echo "repro.nim JS targets still enabling hotCodeReloading: ",
        offenders.join(", ")
    check offenders.len == 0

  test "no hand-written build recipe passes --hotCodeReloading":
    ## `repro.nim` is not the only thing that runs `nim js` here.  Three other
    ## build definitions compile the very same renderer sources and each one
    ## carried the flag:
    ##
    ## * `justfile` — `build-ui-js` / `build-ui-js-hmr`.
    ## * `src/Tuprules.tup` — `!nim_js` and `!nim_node_subwindow`; the tup path
    ##   is still what `just build-once` uses by default on Linux, so a flag
    ##   left here ships even though `repro.nim` is clean.
    ## * `build_for_extension.sh` — `ui.js` for the VS Code extension.
    ##
    ## Each file must still exist, or the scan would pass by looking at
    ## nothing.
    for relPath in HandWrittenBuildFiles:
      check fileExists(repoRoot / relPath)
    let offenders = handWrittenRecipesEnablingHcr(repoRoot)
    if offenders.len > 0:
      echo "build recipes still passing --hotCodeReloading: ",
        offenders.join(" | ")
    check offenders.len == 0

  test "two instantiations of one generic keep their own JS symbol and type":
    ## Compiles the fixture with the JavaScript targets' own
    ## `hotCodeReloading` setting, then checks both halves of the defect: the
    ## emitted names (the mechanism) and the values the bundle produces under
    ## node (the consequence).  Under the broken setting the two `makeBox`
    ## closures collapse onto one JS function name and the run dies inside
    ## `nimCopy`.
    let nimExe = findExe("nim")
    let nodeExe = findExe("node")
    if nimExe.len == 0 or nodeExe.len == 0:
      echo "prerequisite missing: `nim` and `node` must both be on PATH; ",
        "found nim=", nimExe, " node=", nodeExe
    check nimExe.len > 0
    check nodeExe.len > 0

    if nimExe.len > 0 and nodeExe.len > 0:
      # The fixture is compiled with whatever setting the tree actually
      # ships — from `repro.nim` OR from any of the hand-written recipes, so
      # a flag re-added to only one of them still gets its consequence
      # measured rather than only linted.
      let hcrOn = jsTargetsEnablingHcr(readFile(reproNimPath)).len > 0 or
        handWrittenRecipesEnablingHcr(repoRoot).len > 0
      let workDir = getTempDir() /
        ("ct-renderer-js-symbols-" & $getCurrentProcessId())
      let build = buildFixture(nimExe, workDir, hcrOn)
      if not build.compiled:
        echo "nim js failed:\n", build.compilerOutput
      check build.compiled

      if build.compiled:
        let dups = duplicateTopLevelFunctions(readFile(build.bundlePath))
        if dups.len > 0:
          echo "duplicate top-level JS functions (the later declaration ",
            "wins, so distinct Nim routines alias): ", dups.join(", ")
        check dups.len == 0

        let run = execCmdEx(nodeExe.quoteShell & " " &
                            build.bundlePath.quoteShell)
        if run.exitCode != 0:
          echo "node exited ", run.exitCode, ":\n", run.output
        check run.exitCode == 0
        check run.output.contains(ExpectedStringLine)
        check run.output.contains(ExpectedRecLine)
      removeDir(workDir)
