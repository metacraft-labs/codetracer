## test_gpui_shell_split.nim — PLAT-20. **The shell/leaf decomposition and the
## verification gate, asserted rather than reviewed.**
##
## PLAT-20's verification gate is one sentence: *"`HeadlessApp` is unchanged by
## this milestone beyond additive front-end registration. A shell that needed
## changing to host a second GPU front-end was not renderer-free."* A gate
## phrased as "unchanged" is a claim about a diff, and this suite asserts the
## half of it that survives the commit: that the shell does not reach a
## renderer, that `headless_app/` does not know this front-end exists, and that
## exactly one module of `gpui/app/` imports GPUI.
##
## ## No mocks — and the renderer is REAL
##
## No mock, no stub, no fake renderer. `GpuiRenderer` here is
## `isonim-gpui`'s own, the shadow tree is built by the real Rust shim
## (`libgpui_nim_shim`) through its `extern "C"` surface, and the render plan is
## the shim's own plan builder. That is PLAT-19's verification tier, pointed at
## PLAT-20's arrangement.
##
## What it is NOT is a GPU window: whether `createWindow` opens one depends on
## whether the shim was built with `--features gpui-backend`, and this suite
## does not open a window at all. It asserts the tree and the plan, which is
## what the shell/leaf split is about.
##
## No backend either, and that is the same argument the other two PLAT-20
## suites make: a leaf's PLACEMENT and its STATE are properties of the
## arrangement, and `GpuiShell.openWindow` exists so a window can hold one
## without a session. The "no ViewModel yet" state this exercises is a real
## product state — `HeadlessApp.openSession` creates a session in `dspCreated`
## and the panel ViewModels stay nil until launch — and it is the state
## `codetracer-gpui --report-plan` prints on a real recording.
##
## ## Trap 13
##
## Every helper that calls `check` is a `template`.

import std/[os, strutils, unittest]

import isonim_gpui/renderer

import gpui/app/shell
import gpui/app/leaves

var asserted = 0
var countedAssertions = 0
  ## The PER-TEST counter is reset by `resetCount`; this one never is, so the
  ## file can emit the `CHECKS: <n>` line `ci/lib/test-lane-report.sh` reads.
  ## Without it the lane reports the file as UNMEASURED and its `[OK]` count
  ## stands in for an assertion count — which is Verification-Harness-Traps §7
  ## exactly, and the lane says so in its own output.

template ck(condition: untyped) =
  inc asserted
  inc countedAssertions
  check condition

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template resetCount() =
  asserted = 0

proc repoSrcFrontend(): string =
  ## `src/frontend`, from THIS source file's own path rather than from the
  ## working directory — the suite must read the same tree it was compiled
  ## from whichever directory the lane runs it in.
  currentSourcePath().parentDir.parentDir.parentDir

proc importLinesOf(path: string): seq[string] =
  ## Every `import` / `from` line of a Nim file, with comments and blank lines
  ## dropped.
  ##
  ## Deliberately NOT a general Nim import extractor: `ci/lib/nim-imports.sh`
  ## is that, it is 400 lines, and Verification-Harness-Traps §14a is the entry
  ## about re-deriving it badly in a second place. What this needs is much
  ## smaller and is stated as such — the files it reads are this milestone's
  ## own, they are formatted one import per line, and the assertions below name
  ## the modules positively (`what does it import`) rather than negatively
  ## (`prove it imports nothing bad`), so a line this misses cannot create a
  ## false pass in the direction that matters.
  result = @[]
  for raw in readFile(path).splitLines():
    let line = raw.strip()
    if line.startsWith("import ") or line.startsWith("from "):
      result.add line

suite "PLAT-20: the shell is renderer-free":

  test "gpui/app/shell.nim imports no renderer, and the file says which":
    resetCount()
    let path = repoSrcFrontend() / "gpui" / "app" / "shell.nim"
    ck fileExists(path)
    let imports = importLinesOf(path)
    # §4's positive control: a reader that found nothing satisfies every
    # "does not import" assertion below for free.
    ck imports.len == 5
    var renderers = 0
    for line in imports:
      if "isonim_gpui" in line or "isonim_tui" in line or
         "renderer" in line or "view_vocabulary" in line:
        inc renderers
    ck renderers == 0
    # And the positive half, so the count above is about THIS file: it really
    # does import the two things the milestone says the shell is.
    var sawApp = false
    var sawWindows = false
    for line in imports:
      if "headless_app/headless_app" in line: sawApp = true
      if "headless_app/window_set" in line: sawWindows = true
    ck sawApp
    ck sawWindows
    expectCount(5)

  test "exactly ONE module of gpui/app/ imports GPUI, and it is leaves.nim":
    resetCount()
    let dir = repoSrcFrontend() / "gpui" / "app"
    var scanned = 0
    var importers: seq[string] = @[]
    for kind, path in walkDir(dir):
      if kind != pcFile or not path.endsWith(".nim"):
        continue
      inc scanned
      for line in importLinesOf(path):
        if "isonim_gpui" in line:
          importers.add path.extractFilename
          break
    # §4b: the membership is knowable, so the control is the COUNT.
    ck scanned == 3   # dock_projection.nim, shell.nim, leaves.nim
    ck importers.len == 1
    ck importers[0] == "leaves.nim"
    expectCount(3)

  test "headless_app/ IMPORTS nothing from this front-end":
    resetCount()
    # The verification gate's other half. `HeadlessApp` is the shell both
    # front-ends drive, and it must not have been taught that a second one
    # exists.
    #
    # **THE PREDICATE IS "IMPORTS", NOT "MENTIONS", AND THAT CORRECTION WAS
    # FORCED BY A RUN.** The first version of this case grepped every file
    # under `headless_app/` for the string `gpui` and went red on
    # `extent_distribution.nim`, whose header explains that the GPUI dock
    # projection is the second consumer of the routine — a sentence that is
    # both true and exactly the documentation a shared module owes. A scan
    # that forbids a word forbids the explanation of why the word is there,
    # which is Verification-Harness-Traps §4d pointed the other way: matching
    # vocabulary rather than syntax, and refusing prose instead of passing
    # over it.
    let dir = repoSrcFrontend() / "headless_app"
    var scanned = 0
    var importers = 0
    for kind, path in walkDir(dir):
      if kind != pcFile or not path.endsWith(".nim"):
        continue
      inc scanned
      for line in importLinesOf(path):
        if "gpui" in line.toLowerAscii or "isonim" in line.toLowerAscii or
           "tui" in line.toLowerAscii:
          inc importers
    ck scanned == 5   # headless_app, layout_model, layout_interaction,
                      # window_set, extent_distribution
    ck importers == 0
    # The positive twin over the same reader (§4a): the scanner really is
    # reading import lines, so `importers == 0` is not an empty scan.
    var totalImports = 0
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".nim"):
        totalImports += importLinesOf(path).len
    ck totalImports >= 8
    expectCount(3)

  test "the dock placeholder is a VALUE, so it cannot rot silently":
    resetCount()
    # Verification-Harness-Traps §7a: a header sentence saying "gpui-kit is not
    # wired yet" is the most comfortable place for a claim that stops being
    # true without anything going red. This is that claim as an assertion.
    ck gpuiKitDockAvailable == false
    expectCount(1)

suite "PLAT-20: the leaves are GPUI, through the real shim":

  test "every placed pane becomes one subtree, in the projection's order":
    resetCount()
    var sh = newGpuiShell()
    let id = WindowId(0)
    ck sh.openWindow(id, defaultReplayLayoutValue()).kind == wsApplied
    let leafSet = sh.leavesFor(id)
    ck leafSet.refused.len == 0
    ck leafSet.leaves.len == 5   # the five panes of the default replay layout

    var r: GpuiRenderer
    let drawn = renderLeaves(r, leafSet)
    # PLAT-9's rule: a pane with no ViewModel draws its REPORT rather than
    # nothing, so `drawn` equals the leaf count on every path.
    ck drawn.drawn == leafSet.leaves.len
    ck drawn.reported == leafSet.leaves.len   # no session: all five report

    # Read back out of the SHADOW TREE — what the shim holds — rather than out
    # of the input this test supplied.
    let ids = drawnPaneIds(r, drawn)
    ck ids.len == 5
    for leaf in leafSet.leaves:
      ck leaf.paneId in ids
    expectCount(11)

  test "the render plan verifies, and carries one line per leaf":
    resetCount()
    var sh = newGpuiShell()
    let id = WindowId(3)
    ck sh.openWindow(id, defaultReplayLayoutValue()).kind == wsApplied
    var r: GpuiRenderer
    let drawn = renderLeaves(r, sh.leavesFor(id))
    ck leafPlanIsValid(r, drawn)
    let plan = leafPlanJson(r, drawn)
    ck plan.len > 0
    # A SECOND READING, through the shim's own plan builder rather than through
    # the shadow tree the case just wrote.
    let texts = planLeafTexts(plan)
    ck texts.len == 5
    var waiting = 0
    for t in texts:
      if "waiting for the session to launch" in t:
        inc waiting
    ck waiting == 5
    expectCount(5)

  test "a REFUSED projection draws the refusal, not an empty window":
    resetCount()
    var sh = newGpuiShell()
    let id = WindowId(0)
    var layout = defaultReplayLayoutValue()
    let docked = layout.apply(cmdDock(paneState, leTop))
    ck docked.kind == loApplied
    ck sh.openWindow(id, docked.layout).kind == wsApplied
    let leafSet = sh.leavesFor(id)
    ck leafSet.refused.len >= 1
    ck leafSet.leaves.len == 0
    var r: GpuiRenderer
    let drawn = renderLeaves(r, leafSet)
    ck drawn.drawn == 0
    ck leafPlanIsValid(r, drawn)
    let texts = planLeafTexts(leafPlanJson(r, drawn))
    ck texts.len == 1
    ck "layout refused" in texts[0]
    ck "NoPlacementForEdge" in texts[0]
    expectCount(9)

  test "a contributed pane from an unloaded extension keeps its slot":
    resetCount()
    # PLAT-9's third arm, reaching this front-end: *"the layout keeps the slot,
    # the front-end renders a report naming the extension, and reinstalling it
    # restores the pane where it was."* Never a blank region.
    var sh = newGpuiShell()
    let id = WindowId(0)
    let tree = row([pane(paneEditor, "Editor"),
                    contributedPaneNode("acme.metrics/overview", "Metrics")])
    ck sh.openWindow(id, initLayout(tree)).kind == wsApplied
    let leafSet = sh.leavesFor(id)
    ck leafSet.leaves.len == 2
    var contributed = 0
    for leaf in leafSet.leaves:
      if leaf.paneId == "acme.metrics/overview":
        inc contributed
        ck leaf.slot.tabCount == 1
    ck contributed == 1
    var r: GpuiRenderer
    let drawn = renderLeaves(r, leafSet)
    ck drawn.drawn == 2
    let texts = planLeafTexts(leafPlanJson(r, drawn))
    var named = 0
    for t in texts:
      if "acme.metrics/overview" in t:
        inc named
    ck named == 1
    expectCount(6)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 43

suite "PLAT-20: the assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
