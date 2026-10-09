## test_plat51b_gpui_plan.nim — PLAT-51 part B (deliverables 8-11), the GPUI
## window's half: the shipped `codetracer-gpui` over a real recording and a
## real engine, driven by `--window-ops` (the events the window delivers),
## its element tree read back from `--report-window-plan` and its geometry
## from `CODETRACER_GPUI_GEOMETRY_OUT`.
##
##   * 9, THE FOCUS HIGHLIGHT: ONE strip on the focus colour, the focused
##     box's outline in it; a press on another pane moves both; the omnibox's
##     `Focus highlight: off` removes them and is REMEMBERED (`gpui-preferences`
##     beside the remembered layout, read at the next start);
##     `--focus-highlight=on|off`;
##   * 11, LIVE REFLOW: a divider held 80 px along has ALREADY moved its panes
##     (the geometry the window drew mid-drag) and the remembered layout is
##     not written until the release; `--live-resize=off` keeps the
##     arrangement and draws a guide; the cost of one motion, measured;
##   * 10, GOLDENLAYOUT'S DROP ZONES: the dragged pane is out of the drawn
##     arrangement while it is carried; over a strip the placeholder opens a
##     gap where the tab would go; the layout's right edge is the ground's
##     band, a split of the whole layout;
##   * 8, THE WELCOME SCREEN OF A NEW TAB: the "+" opens it with the start
##     options in the DESKTOP's order (the real Electron app's,
##     `answers/plat51-desktop.electron.json`) and the recent panels; "Record
##     new trace" runs a real `ct record` and the recording opens in the tab.
##
## No mocks: the shipped binary, real recordings, a real engine, a real `ct
## record`.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles,
            times, unittest]

import gpui/chrome
import gpui/window_geometry

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 32
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  DesktopAnswers = "src/tests/visual/answers/plat51-desktop.electron.json"
  W = 1920
  H = 1080

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

proc windowPlan(ops: string; geometry: var JsonNode; state = "";
                pre: seq[string] = @[]): JsonNode =
  ## The window's root after `ops`, as the shipped binary reports it, and
  ## the geometry it drew last. `state` is the product's state root (a fresh
  ## one when empty, removed afterwards).
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if not dirExists(calc):
    raise newException(IOError, "prerequisite missing: " & calc)
  let own = state.len == 0
  let root = if own: createTempDir("plat51b-gpui-plan-", "") else: state
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = root
  env["XDG_STATE_HOME"] = root / "xdg"
  let ct = repo / "src/build-debug/bin/ct"
  if fileExists(ct):
    env["CT_BIN"] = ct
  let geomFile = root / "geometry.json"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = geomFile
  var args = pre & @["--report-window-plan", "--width=" & $W,
                     "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add calc
  let errFile = genTempPath("plat51b-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  geometry = if fileExists(geomFile): parseFile(geomFile) else: newJNull()
  if own:
    removeDir(root)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & err)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  parseJson(output)

proc windowPlan(ops: string; state = ""; pre: seq[string] = @[]): JsonNode =
  var g: JsonNode
  windowPlan(ops, g, state, pre)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc style(n: JsonNode; name: string): string = n{"styles"}{name}.getStr

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc focusedStrips(plan: JsonNode): seq[JsonNode] =
  for s in plan.nodesWith("data-ct-strip-focused"):
    if s.attr("data-ct-strip-focused") == "true":
      result.add s

proc tabsNode(g: JsonNode; pane: string): JsonNode =
  for n in g["nodes"]:
    if n{"kind"}.getStr == "tabs" and pane in n["panes"].to(seq[string]):
      return n
  nil

proc centre(r: JsonNode): (int, int) =
  (r[0].getInt + r[2].getInt div 2, r[1].getInt + r[3].getInt div 2)

suite "PLAT-51 part B GPUI: the focus highlight":

  test "one strip on the focus colour; a press moves it; the command turns it off, remembered":
    var g: JsonNode
    let plan = windowPlan("wait:1", g)
    let first = plan.focusedStrips()
    ck first.len == 1
    if first.len == 1:
      ck first[0].style("bg") == chromeOf(crFocusOutline)
    # A press in the call trace's body: its strip takes the focus colour.
    let ct = g.tabsNode("calltrace")
    let (x, y) = centre(ct["body"])
    let pressed = windowPlan("press:" & $x & ":" & $y & ",release:" & $x &
                             ":" & $y)
    let now = pressed.focusedStrips()
    ck now.len == 1
    if now.len == 1 and first.len == 1:
      ck now[0].attr("data-ct-tabs") != first[0].attr("data-ct-tabs")
      ck "Call Trace" in now[0].attr("data-ct-tabs")
    # The omnibox's command: off, and remembered for the next start.
    let state = createTempDir("plat51b-gpui-focus-", "")
    defer: removeDir(state)
    let off = windowPlan("key:p:control,type::focus highlight off,key:enter",
                         state)
    ck off.focusedStrips().len == 0
    ck readFile(state / "gpui-preferences").contains("focus-highlight=off")
    let restarted = windowPlan("wait:1", state)
    ck restarted.focusedStrips().len == 0
    # The command line, over the remembered choice, for that run.
    ck windowPlan("wait:1", state, @["--focus-highlight=on"]).focusedStrips().len == 1
    ck windowPlan("wait:1", "", @["--focus-highlight=off"]).focusedStrips().len == 0

suite "PLAT-51 part B GPUI: live reflow while a divider is dragged":

  test "held 80 px along, the panes have moved; nothing is written until the release":
    var g0: JsonNode
    discard windowPlan("wait:1", g0)
    let d = g0["dividers"][0]
    let (dx, dy) = centre(d["rect"])
    let filesBefore = g0.tabsNode("fileTree")["rect"][2].getInt
    let state = createTempDir("plat51b-gpui-live-", "")
    defer: removeDir(state)
    var gm: JsonNode
    discard windowPlan("press:" & $dx & ":" & $dy & ",move:" & $(dx + 40) &
                       ":" & $dy & ",move:" & $(dx + 80) & ":" & $dy, gm, state)
    let filesMid = gm.tabsNode("fileTree")["rect"][2].getInt
    checkpoint("files " & $filesBefore & " -> mid-drag " & $filesMid)
    ck abs(filesMid - (filesBefore + 80)) <= 2
    ck not fileExists(state / "gpui-layout.json")
    var gr: JsonNode
    discard windowPlan("press:" & $dx & ":" & $dy & ",move:" & $(dx + 80) &
                       ":" & $dy & ",release:" & $(dx + 80) & ":" & $dy, gr,
                       state)
    ck abs(gr.tabsNode("fileTree")["rect"][2].getInt - (filesBefore + 80)) <= 2
    ck fileExists(state / "gpui-layout.json")

  test "with --live-resize=off the arrangement stays and a guide is drawn":
    var g0: JsonNode
    discard windowPlan("wait:1", g0)
    let (dx, dy) = centre(g0["dividers"][0]["rect"])
    var gm: JsonNode
    let plan = windowPlan("press:" & $dx & ":" & $dy & ",move:" & $(dx + 80) &
                          ":" & $dy, gm, "", @["--live-resize=off"])
    ck gm.tabsNode("fileTree")["rect"][2].getInt ==
       g0.tabsNode("fileTree")["rect"][2].getInt
    ck plan.nodesWith("data-ct-resize-guide").len == 1

  test "the cost of one live motion, measured":
    # THE WINDOW'S OWN WORK PER MOTION — the arrangement re-laid-out and its
    # element tree rebuilt — as the difference between a run that moves the
    # divider forty times and one that presses and releases it, over the
    # same start-up. A proxy for the frame (the off-screen shim paints
    # nothing), reported with the host's load.
    var g0: JsonNode
    discard windowPlan("wait:1", g0)
    let (dx, dy) = centre(g0["dividers"][0]["rect"])
    var moves = ""
    for i in 1 .. 40:
      moves.add ",move:" & $(dx + (i mod 20) * 4) & ":" & $dy
    proc timed(ops: string): float =
      let t0 = epochTime()
      discard windowPlan(ops)
      epochTime() - t0
    # Best of FIVE, interleaved: each figure is a whole process's run, and a
    # shared host's load swings between runs (best of three once read 22 ms
    # a motion at load 29 where the next two runs read 12.7 and 4.4).
    var base, moved = high(float)
    for _ in 0 ..< 5:
      base = min(base, timed("press:" & $dx & ":" & $dy & ",release:" & $dx &
                             ":" & $dy))
      moved = min(moved, timed("press:" & $dx & ":" & $dy & moves &
                               ",release:" & $dx & ":" & $dy))
    let perMotionMs = (moved - base) * 1000.0 / 40.0
    let load = try: readFile("/proc/loadavg").splitWhitespace()[0]
               except IOError: "?"
    echo "PLAT-51 GPUI live drag: ", formatFloat(perMotionMs, ffDecimal, 2),
         " ms per motion (best of 5; load ", load, ")"
    checkpoint("per motion " & $perMotionMs & " ms")
    # The 16 ms budget on a host that is not oversubscribed; on one that is,
    # scaled by the share of a processor this process gets (load / cores).
    let share = max(1.0, (try: parseFloat(load) except ValueError: 0.0) /
                         float(countProcessors()))
    ck perMotionMs < 16.0 * share

suite "PLAT-51 part B GPUI: GoldenLayout's drop zones in the window":

  test "the carried pane is out of the arrangement; the placeholder; the outer band":
    var g: JsonNode
    discard windowPlan("hold:state:calltrace:strip", g)
    # The Variables tab is carried: its stack shows the Scratchpad alone.
    let st = g.tabsNode("scratchpad")
    ck not st.isNil and "state" notin st["panes"].to(seq[string])
    let plan = windowPlan("hold:state:calltrace:strip")
    # Over the Call Trace's first tab: the placeholder's gap in that strip.
    let ph = plan.nodesWith("data-ct-tab-placeholder")
    ck ph.len == 1
    let tints = plan.nodesWith("data-ct-drop")
    ck tints.len == 1
    # The layout's own right edge: GoldenLayout's ground band — the whole
    # layout's height, at its right.
    var gb: JsonNode
    # (Aimed at the Call Trace's height: at a strip's height the strip's
    # header is the smaller area and wins, as in GoldenLayout.)
    let band = windowPlan("hold:state:calltrace:outer-right", gb)
    let bt = band.nodesWith("data-ct-drop")
    ck bt.len == 1
    if bt.len == 1:
      let inner = gb["inner"]
      let left = bt[0]{"styles"}{"left"}.getStr
      let height = bt[0]{"styles"}{"h"}.getStr
      checkpoint("band left " & left & " h " & height & "; inner " & $inner)
      ck height == $inner[3].getInt & "px"

suite "PLAT-51 part B GPUI: a new tab's Welcome Screen":

  test "the + opens it: the desktop's start options in its order, the recent panels":
    let desk = parseFile(repo / DesktopAnswers)["newTab"]
    let plan = windowPlan("tab-add")
    ck plan.nodesWith("data-ct-welcome").len == 1
    var options: seq[string] = @[]
    var enabled: seq[bool] = @[]
    for n in plan.nodesWith("data-ct-welcome-row"):
      if n.attr("data-ct-welcome-row").startsWith("option:"):
        options.add n.textOf.strip
        enabled.add n.attr("data-ct-welcome-enabled") == "true"
    var deskOptions: seq[string] = @[]
    for o in desk["options"]:
      deskOptions.add o["label"].getStr
    checkpoint("window " & $options & " desktop " & $deskOptions)
    ck options == deskOptions
    # The shell is refused on both; the native arm also refuses a new file
    # and an online trace (Welcome-Screen.md, the native arm).
    ck enabled.len == 6 and not enabled[5]
    ck enabled[1] and enabled[2] and enabled[3]
    let text = plan.nodesWith("data-ct-welcome")[0].textOf
    for panel in desk["panels"]:
      ck panel.getStr in text

  test "Record new trace runs a real ct record and the recording opens in the tab":
    let ct = repo / "src/build-debug/bin/ct"
    if not fileExists(ct):
      checkpoint("prerequisite missing: " & ct & " (just build-once)")
    ck fileExists(ct)
    let state = createTempDir("plat51b-gpui-record-", "")
    defer: removeDir(state)
    let program = state / "greeter.py"
    writeFile(program, "def greet(name):\n    return 'hello ' + name\n\n" &
                       "print(greet('plat51'))\n")
    # The focus starts on "Open folder"; "Record new trace" is the next row.
    let plan = windowPlan("tab-add,key:down,key:enter,type:" & program &
                          ",key:enter,wait:240000", state)
    var titles: seq[string] = @[]
    for t in plan.nodesWith("data-ct-session-tab"):
      titles.add t.attr("data-ct-session-tab")
    checkpoint("tabs " & $titles)
    var recorded = false
    for t in titles:
      if t.startsWith("greeter-"): recorded = true
    ck recorded
    ck plan.nodesWith("data-ct-welcome").len == 0
    var found = 0
    for kind, path in walkDir(state / "recordings"):
      if kind == pcDir and path.extractFilename.startsWith("greeter-"):
        inc found
    ck found == 1

suite "PLAT-51 part B GPUI: assertion count":
  test "every assertion ran":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
