## test_m71_gpui_plan.nim — M71 (codetracer#838) in the GPUI window, read off
## the SHIPPED binary's window plan (`codetracer-gpui --report-window-plan
## --window-ops=…`: the window's own root builder and its own pointer
## handlers) over real recordings, a real `replay-server` and a real git
## repository.
##
## The terminal's State, Files and VCS panes drew no scrollbar and ignored the
## wheel; the issue asked the native window to be checked for the same gap
## (Native-Front-End-Parity.md: "where the desktop has a behaviour, the native
## front-ends have it too"). Scrollbar-Scrubbers.md §2: a pane whose whole
## content is in hand "keeps an ordinary scrollbar", with "the click rule
## (§3), which applies to it as well so that every scrollbar behaves alike";
## CodeTracer-TUI.md §4.4's wheel scrolls "the pane beneath the pointer ...
## without requiring pane focus". So, for each pane:
##
##   * VCS and Files: more rows than the body holds draw the list scrubber
##     (`data-ct-list-scrubber`) over ALL the rows; rows that fit draw none;
##   * the vertical wheel over the pane (not focused first) moves its first
##     row;
##   * a press at the track's END shows the last rows (first + shown ==
##     total), at its start the first; the held thumb dragged to the end
##     does too;
##   * the State pane already scrolled with the wheel and drew its thumb; its
##     bar now takes the same §3 press and drag (a track a press lands on,
##     `data-ct-state-scroll-track`), reaching the same end the wheel does.
##
## The VCS pane reads the window's working directory (`attachVcs`): a
## repository built by `scripts/plat47-vcs-fixture.sh`, given sixty more
## untracked files for the overflowing case. No mocks: the binary, the
## engine, the recordings and git are the product's.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import gpui/list_scrubber
import ../../tui/tests/fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 43

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1440
  H = 1400
  ShortH = 600
    ## A window short enough that an open value history overflows the state
    ## box (and, in `shortFiles`' box, that the Files tree overflows).
  Extra = 60
    ## Untracked files added to the fixture repository: more rows than the
    ## VCS pane holds at `H`.
  FixtureRows = 7
    ## The fixture repository's pane, counted off the fixture script: the
    ## branch, the working tree's caption and its three files, the commits'
    ## caption and the one commit.
  StateScrollAttribute = "data-ct-state-scroll"
  StateTrackAttribute = "data-ct-state-scroll-track"
  VcsScrollAttribute = "data-ct-vcs-scroll"
  FileTreeFirstAttribute = "data-ct-file-tree-first"

let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repoRoot / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repoRoot.parentDir / "isonim-gpui/rust/target/debug")

var scratchDirs: seq[string] = @[]
  ## The temporary repositories and layouts this suite made, removed by its
  ## last case.

proc fixture(spec: FixtureSpec): string =
  ## The recording of `spec`, recorded on first use (`fixture_provider`, as
  ## the PLAT-57 suite does); a recorder that is missing FAILS by name.
  let resolved = resolveFixture(spec)
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

type Run = object
  plan: JsonNode
  rc: int
  err: string

proc run(ops: string; subject: string; pre: seq[string] = @[];
         workDir = ""; height = H): Run =
  ## The window's root after `ops`, the exit status and the stderr — NOT
  ## raising on a refused op, because "there is no scrollbar to press" is
  ## the defect this suite is about and is asserted, not crashed on.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if subject.len == 0:
    raise newException(IOError, "prerequisite missing: a tui-fixtures " &
      "recording (the tui lane records them on its first run)")
  let state = createTempDir("m71-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  # Every other per-user location of the spawned binary: its own, under this
  # case's directory (common/ct_home).
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  var args = pre & @["--report-window-plan", "--width=" & $W,
                     "--height=" & $height]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add subject
  let errFile = genTempPath("m71-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args,
    workingDir = workDir, env = env, options = {})
  let output = p.outputStream.readAll()
  result.rc = p.waitForExit()
  p.close()
  result.err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  result.plan = if result.rc == 0: parseJson(output) else: newJNull()
  if result.rc != 0:
    checkpoint("codetracer-gpui exited " & $result.rc & " (" & ops & "): " &
               result.err)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc scrubber(plan: JsonNode; pane: string): JsonNode =
  for n in plan.nodesWith(ListTrackAttribute):
    if n.attr(ListTrackAttribute) == pane: return n
  newJNull()

proc scrubInt(plan: JsonNode; pane, field: string): int =
  ## A field of pane `pane`'s list scrubber, -1 when it has none.
  let s = plan.scrubber(pane)
  if s.kind == JNull: -1 else: parseInt(s.attr("data-ct-scrub-" & field))

proc firstAttr(plan: JsonNode; attribute: string): string =
  ## The value of the first node carrying `attribute`, "" for none.
  for n in plan.nodesWith(attribute):
    return n.attr(attribute)
  ""

proc stateTop(plan: JsonNode): int =
  ## How far the state pane's rows box is scrolled (`top,left`), -1 unread.
  let s = plan.firstAttr(StateScrollAttribute)
  if s.len == 0: -1 else: parseInt(s.split(',')[0])

proc fileRowIds(plan: JsonNode): seq[string] =
  ## The Files pane's drawn rows, top to bottom (the vocabulary `Tree` ids
  ## under the `fileTree` root).
  proc walk(n: JsonNode; inTree: bool; acc: var seq[string]) =
    if n.kind != JObject: return
    let id = n.attr("data-view-id")
    let here = inTree or id == "fileTree"
    if inTree and n.attr("data-view-kind") == "Tree" and
       id.startsWith("fileTree"):
      acc.add id
    for c in n{"children"}.getElems: walk(c, here, acc)
  walk(plan, false, result)

proc vcsRepo(extra: int): string =
  ## The PLAT-47 fixture repository, with `extra` untracked files more.
  result = createTempDir("m71-vcs-gpui-", "") / "repo"
  scratchDirs.add result.parentDir
  let (output, code) = execCmdEx("bash " &
    quoteShell(repoRoot / "scripts" / "plat47-vcs-fixture.sh") & " " &
    quoteShell(result))
  if code != 0:
    checkpoint(output)
  doAssert code == 0, "plat47-vcs-fixture.sh failed"
  for i in 0 ..< extra:
    writeFile(result / ("untracked_" & align($i, 2, '0') & ".txt"), $i & "\n")

let calc = fixture(fixtureSpec("calc"))
let multiRoot = fixture(FixtureSpec(
  name: "multi_root",
  program: "test-programs/multi_root/app/main.py",
  recorder: "codetracer-python-recorder",
  probe: FixtureProbe(kind: pkPythonRecorder),
  buildHint: "Install codetracer_python_recorder into the interpreter " &
             "`ct` will use.",
  blockedOn: ""))

proc filesLayoutFile(): string =
  ## A saved layout with the Files pane in a box a sixth of the window high,
  ## over the editor: at `ShortH` it holds fewer rows than `multi_root`'s
  ## tree lists (eight), which the default layout's tall left column never
  ## does.
  result = createTempDir("m71-files-layout-", "") / "layout.json"
  scratchDirs.add result.parentDir
  writeFile(result, $(%*{"version": 5, "docked": [],
    "layout": {"kind": "column", "weight": 1.0, "children": [
      {"kind": "pane", "pane": "fileTree", "weight": 1.0},
      {"kind": "pane", "pane": "editor", "weight": 5.0}]}}))

let shortFiles = @["--layout=" & filesLayoutFile()]

suite "M71 GPUI: the VCS pane keeps an ordinary scrollbar":

  test "more rows than the body holds draw the list scrubber over all of them; rows that fit, none":
    let big = vcsRepo(Extra)
    let over = run("click:tab:vcs:left", calc, workDir = big)
    ck over.rc == 0
    let total = over.plan.scrubInt("vcs", "total")
    checkpoint("vcs scrubber total " & $total)
    ck total == FixtureRows + Extra
    ck over.plan.scrubInt("vcs", "first") == 0
    let small = vcsRepo(0)
    let fits = run("click:tab:vcs:left", calc, workDir = small)
    ck fits.rc == 0
    ck fits.plan.firstAttr(VcsScrollAttribute) == "0"   # the pane is drawn
    ck fits.plan.scrubber("vcs").kind == JNull

  test "VCS: the wheel scrolls it; a press at the track's end shows the last rows; the thumb drags":
    let big = vcsRepo(Extra)
    let wheel = run("click:tab:vcs:left,wheel:vcs:3", calc, workDir = big)
    ck wheel.rc == 0
    checkpoint("after the wheel: first " & $wheel.plan.scrubInt("vcs", "first"))
    ck wheel.plan.scrubInt("vcs", "first") == 3
    ck wheel.plan.firstAttr(VcsScrollAttribute) == "3"
    let atEnd = run("click:tab:vcs:left,scrub:vcs:track:1000", calc,
                    workDir = big)
    ck atEnd.rc == 0
    let first = atEnd.plan.scrubInt("vcs", "first")
    let shown = atEnd.plan.scrubInt("vcs", "visible")
    checkpoint("track end: first " & $first & " shown " & $shown)
    ck shown > 0
    ck first + shown == FixtureRows + Extra
    ck atEnd.plan.firstAttr(VcsScrollAttribute) == $first
    let back = run("click:tab:vcs:left,scrub:vcs:track:1000," &
                   "scrub:vcs:track:0", calc, workDir = big)
    ck back.rc == 0
    ck back.plan.scrubInt("vcs", "first") == 0
    let dragged = run("click:tab:vcs:left,scrub:vcs:drag:0:1000", calc,
                      workDir = big)
    ck dragged.rc == 0
    ck dragged.plan.scrubInt("vcs", "first") == first

suite "M71 GPUI: the Files pane keeps an ordinary scrollbar":

  test "a tree taller than its body is drawn a window at a time, under the list scrubber":
    # A short box (`shortFiles`): the Files body holds fewer rows than the
    # recording's tree lists; the default layout's tall one holds them all.
    let tall = run("", multiRoot)
    ck tall.rc == 0
    let all = tall.plan.fileRowIds
    checkpoint("files rows " & $all)
    ck all.len > 3
    ck tall.plan.scrubber("fileTree").kind == JNull
    let short = run("", multiRoot, pre = shortFiles,
                    height = ShortH)
    ck short.rc == 0
    ck short.plan.scrubInt("fileTree", "total") == all.len
    let shown = short.plan.scrubInt("fileTree", "visible")
    checkpoint("short window shows " & $shown)
    ck shown > 0 and shown < all.len
    ck short.plan.fileRowIds == all[0 ..< shown]

  test "Files: the wheel scrolls it; a press at the track's end shows the last rows; the thumb drags":
    let all = run("", multiRoot).plan.fileRowIds
    let wheel = run("wheel:fileTree:1", multiRoot, pre = shortFiles,
                    height = ShortH)
    ck wheel.rc == 0
    ck wheel.plan.scrubInt("fileTree", "first") == 1
    ck wheel.plan.firstAttr(FileTreeFirstAttribute) == "1"
    let atEnd = run("scrub:fileTree:track:1000", multiRoot, pre = shortFiles,
                    height = ShortH)
    ck atEnd.rc == 0
    let first = atEnd.plan.scrubInt("fileTree", "first")
    let shown = atEnd.plan.scrubInt("fileTree", "visible")
    ck first + shown == all.len
    # The LAST rows of the tree are the ones drawn.
    ck atEnd.plan.fileRowIds == all[first ..< all.len]
    let dragged = run("scrub:fileTree:drag:0:1000", multiRoot,
                      pre = shortFiles, height = ShortH)
    ck dragged.rc == 0
    ck dragged.plan.scrubInt("fileTree", "first") == first

suite "M71 GPUI: the State pane's bar takes the §3 press and drag":

  test "a press at its track's end reaches the end the wheel does; its start the top; the thumb drags":
    # `__name__`'s value history open under its row, in a short window: the
    # rows overflow the state box.
    const open = "click:statecontrol:history:__name__"
    let pre = @["--replay-ops=next=3"]
    let rows = run(open, calc, pre = pre, height = ShortH)
    ck rows.rc == 0
    ck rows.plan.nodesWith(StateTrackAttribute).len == 1
    ck rows.plan.stateTop == 0
    # The wheel, far past the end: the box's furthest scroll.
    let wheeled = run(open & ",wheel:state:1000", calc, pre = pre,
                      height = ShortH)
    ck wheeled.rc == 0
    let bottom = wheeled.plan.stateTop
    checkpoint("the wheel's end: " & $bottom)
    ck bottom > 0
    let atEnd = run(open & ",scrub:state:track:1000", calc, pre = pre,
                    height = ShortH)
    ck atEnd.rc == 0
    ck atEnd.plan.stateTop == bottom
    let back = run(open & ",scrub:state:track:1000,scrub:state:track:0", calc,
                   pre = pre, height = ShortH)
    ck back.rc == 0
    ck back.plan.stateTop == 0
    let dragged = run(open & ",scrub:state:drag:0:1000", calc, pre = pre,
                      height = ShortH)
    ck dragged.rc == 0
    ck dragged.plan.stateTop == bottom

suite "M71 GPUI plan: assertion count":
  test "every assertion ran":
    for d in scratchDirs: removeDir(d)
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
