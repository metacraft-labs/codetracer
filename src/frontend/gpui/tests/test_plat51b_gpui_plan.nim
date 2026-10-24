## test_plat51b_gpui_plan.nim — PLAT-51 part B (deliverables 8-11), the GPUI
## window's half: the shipped `codetracer-gpui` over a real recording and a
## real engine, driven by `--window-ops` (the events the window delivers),
## its element tree read back from `--report-window-plan` and its geometry
## from `CODETRACER_GPUI_GEOMETRY_OUT`.
##
##   * 9, THE FOCUS HIGHLIGHT: none before a pane is pressed, then ONE strip
##     on the focus colour, the focused box's outline in it; a press on
##     another pane moves both; the omnibox's `Focus highlight: off` removes
##     them and is REMEMBERED (`gpui-preferences`
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
##   * M74 (codetracer#841), THE FILE MENU: its items reach the welcome flow,
##     and a disabled item's reason is drawn beside it (EMT-D14).
##
## No mocks: the shipped binary, real recordings, a real engine, a real `ct
## record`.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles,
            times, unittest]

import gpui/chrome
import gpui/window_geometry

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 65
    ## 32 -> 33 (2026-10-17): the focus case asserts that NOTHING is outlined
    ## before the first press (the desktop's behaviour since the redesign),
    ## then that a press outlines the pressed pane — one check more.
    ## 33 -> 39 (2026-10-20): the File menu case (codetracer#841) — the
    ## welcome tab and form each of three File items opens, six checks.
    ## 39 -> 63 (2026-10-21): a disabled File item's reason drawn beside it
    ## (EMT-D14) — highlighted by keyboard and by pointer, an enabled item
    ## with none, chosen by Enter and by a click, and wrapped in two windows
    ## too narrow for it on one line — twenty-four checks.
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

const
  OpenFile = when defined(macosx): "key:`:alt,key:enter" else: "key:f:alt"
    ## How the M74 cases open File. CUA-Keymap.md §3.8 binds `Alt+F` on Linux
    ## and Windows only ("On macOS … Option+<letter> types a character"), so on
    ## macOS File is reached by `` Alt+` `` (`menu.open`, every platform) and
    ## `Enter` on its first folder. The cases' subject is File's ITEMS, not the
    ## mnemonic; "the two routes reach the same File menu" below holds the
    ## macOS route to the Linux one on every platform.

proc ctUnderTest(): string =
  ## The ONE `ct` a "Record new trace" case may run: `CT_BIN` when the
  ## environment names one, else this checkout's debug build. It is resolved
  ## here once and pinned into the window's `CT_BIN`, so the binary the case
  ## checks is the binary the window runs — never another `ct` that
  ## `native_host.findCtBinary` would fall through to (`PATH`, or one beside
  ## the engine) when this one is missing.
  let named = getEnv("CT_BIN", "")
  if named.len > 0: named else: repo / "src/build-debug/bin/ct"

proc windowPlan(ops: string; geometry: var JsonNode; state = "";
                pre: seq[string] = @[]; width = W): JsonNode =
  ## The window's root after `ops`, as the shipped binary reports it, and
  ## the geometry it drew last. `state` is the product's state root (a fresh
  ## one when empty, removed afterwards); `width` the window's, in pixels.
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
  # Every other per-user location of the spawned binary (common/ct_home).
  env["CODETRACER_HOME"] = root / "ct-home"
  let ct = ctUnderTest()
  if fileExists(ct):
    env["CT_BIN"] = ct
  else:
    env.del("CT_BIN")
  let geomFile = root / "geometry.json"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = geomFile
  var args = pre & @["--report-window-plan", "--width=" & $width,
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

proc windowPlan(ops: string; state = ""; pre: seq[string] = @[];
                width = W): JsonNode =
  var g: JsonNode
  windowPlan(ops, g, state, pre, width)

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
    # As on the desktop, nothing is outlined until a pane has been pressed
    # (the editor holds the keys before that, unmarked).
    ck plan.focusedStrips().len == 0
    proc pressIn(pane: string): string =
      let (x, y) = centre(g.tabsNode(pane)["body"])
      "press:" & $x & ":" & $y & ",release:" & $x & ":" & $y
    # A press in the editor's body: its strip takes the focus colour.
    let first = windowPlan(pressIn("editor")).focusedStrips()
    ck first.len == 1
    if first.len == 1:
      ck first[0].style("bg") == chromeOf(crFocusOutline)
    # Then a press in the call trace's body: the focus moves to its strip.
    let pressed = windowPlan(pressIn("editor") & "," & pressIn("calltrace"))
    let now = pressed.focusedStrips()
    ck now.len == 1
    if now.len == 1 and first.len == 1:
      ck now[0].attr("data-ct-tabs") != first[0].attr("data-ct-tabs")
      ck "Call Trace" in now[0].attr("data-ct-tabs")
    # The omnibox's command: off — a press then outlines nothing — and
    # remembered for the next start.
    let state = createTempDir("plat51b-gpui-focus-", "")
    defer: removeDir(state)
    let off = windowPlan("key:p:control,type::focus highlight off,key:enter," &
                         pressIn("calltrace"), state)
    ck off.focusedStrips().len == 0
    ck readFile(state / "gpui-preferences").contains("focus-highlight=off")
    let restarted = windowPlan(pressIn("calltrace"), state)
    ck restarted.focusedStrips().len == 0
    # The command line, over the remembered choice, for that run.
    ck windowPlan(pressIn("calltrace"), state,
                  @["--focus-highlight=on"]).focusedStrips().len == 1
    ck windowPlan(pressIn("calltrace"), "",
                  @["--focus-highlight=off"]).focusedStrips().len == 0

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
    let ct = ctUnderTest()
    checkpoint("ct under test: " & ct)
    if not fileExists(ct):
      checkpoint("prerequisite missing: " & ct &
                 " (just build-once, or CT_BIN); the window is not run " &
                 "against any other ct")
    ck fileExists(ct)
    if fileExists(ct):
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

suite "M74 (#841) GPUI: File opens the same way on every platform":

  test "the two routes reach the same File menu (Alt+F, and Alt+` then Enter)":
    var g: JsonNode
    let byMnemonic = windowPlan("key:f:alt", g)
    let byMenuKey = windowPlan("key:`:alt,key:enter", g)
    var a, b: seq[string]
    for n in byMnemonic.nodesWith("data-ct-menu-active"):
      if n.attr("data-ct-menu-active") == "true": a.add n.attr("data-ct-menu-item")
    for n in byMenuKey.nodesWith("data-ct-menu-active"):
      if n.attr("data-ct-menu-active") == "true": b.add n.attr("data-ct-menu-item")
    checkpoint("Alt+F " & $a & " / Alt+` Enter " & $b)
    ck a == @["File", "Open Trace..."]
    ck b == a

suite "M74 (#841) GPUI: the File menu reaches the welcome flow":
  # codetracer#841: the window's menu enabled a static list without a single
  # File item. Here File is opened with `Alt+F` (CUA-Keymap.md §3.8, the
  # window's default CUA base) and an item chosen with `Down` / `Enter`,
  # through the window's own key handlers (`--window-ops`).

  proc welcomeForm(plan: JsonNode): string =
    for n in plan.nodesWith("data-ct-welcome-form"):
      return n.attr("data-ct-welcome-form")
    ""

  test "New Trace Tab opens the Welcome Screen; Open Trace… and Record New Trace… open its forms":
    # File's items in order: Open Trace…, Open Trace in New Tab…, Record New
    # Trace…, New Trace Tab. The folder opens on the first.
    let tab = windowPlan(OpenFile & ",key:down,key:down,key:down,key:enter")
    ck tab.nodesWith("data-ct-welcome").len == 1
    ck tab.welcomeForm == ""
    let open = windowPlan(OpenFile & ",key:enter")
    ck open.nodesWith("data-ct-welcome").len == 1
    ck open.welcomeForm == "open-local-trace"
    let record = windowPlan(OpenFile & ",key:down,key:down,key:enter")
    ck record.nodesWith("data-ct-welcome").len == 1
    ck record.welcomeForm == "record-new-trace"

suite "M74 (#841) GPUI: a disabled File item says why, beside it":
  # EMT-D14 (Edit-Mode-Toolbar.md §8): every disabled state carries a
  # non-empty reason, and the parity rule wants it SHOWN, not only logged
  # (the terminal puts "<item>: <reason>" on its status line). A desktop
  # menu shows a disabled item's explanation as a tooltip, so the window
  # draws its hover label — the element a control's tooltip uses — beside
  # the highlighted row. Close Current File is disabled here because a GPUI
  # edit tab holds one file (`GpuiFileListReason` in main.nim).

  const
    CloseFileReason =
      "the window's editor holds one file per tab; there is no list of " &
      "open files to step through"
    ToCloseFile = OpenFile & ",key:down,key:down,key:down,key:down"
      ## File opens on Open Trace…; Close Current File is the fifth item.

  proc pxRect(a: JsonNode): PxRect =
    PxRect(x: a[0].getInt, y: a[1].getInt, w: a[2].getInt, h: a[3].getInt)

  proc fileRow(g: JsonNode; label: string): tuple[pop, row: PxRect] =
    ## The popover holding row `label` and the row, as the window drew them.
    for p in g["topBar"]["popovers"]:
      for row in p["rows"]:
        if row["label"].getStr == label:
          return (p["rect"].pxRect, row["rect"].pxRect)

  proc px(n: JsonNode; style: string): int =
    let v = n{"styles"}{style}.getStr
    if v.endsWith("px"): parseInt(v[0 ..< v.len - 2]) else: -1

  proc rectOf(n: JsonNode): PxRect =
    PxRect(x: n.px("left"), y: n.px("top"), w: n.px("w"), h: n.px("h"))

  proc hoverLabels(plan: JsonNode): seq[JsonNode] =
    plan.nodesWith("data-ct-hover-label")

  proc besideRow(label: JsonNode; pop, row: PxRect; width = W): bool =
    ## Level with the row, clear of its popover, and inside a window `width`
    ## pixels wide.
    let r = label.rectOf
    checkpoint("label " & $r & " row " & $row & " popover " & $pop)
    r.w > 0 and r.y < row.y + row.h and r.y + r.h > row.y and
      (r.x >= pop.x + pop.w or r.x + r.w <= pop.x) and
      r.x >= 0 and r.y >= 0 and r.x + r.w <= width and r.y + r.h <= H

  proc labelLines(label: JsonNode): seq[string] =
    ## A wrapped label's lines, in drawing order.
    for n in label.nodesWith("data-ct-hover-label-line"):
      result.add n.textOf

  proc mid(r: PxRect): string = $(r.x + r.w div 2) & ":" & $(r.y + r.h div 2)

  test "highlighted by keyboard or pointer, the reason is drawn beside the row; an enabled item has none":
    var g: JsonNode
    let opened = windowPlan(OpenFile, g)
    # Open Trace…, highlighted on opening, is performed here: no label.
    ck opened.hoverLabels.len == 0
    let (pop, close) = g.fileRow("Close Current File")
    let (_, newTab) = g.fileRow("New Trace Tab")
    ck close.w > 0 and newTab.w > 0
    # THE KEYBOARD: Down onto Close Current File.
    let keyed = windowPlan(ToCloseFile)
    let kl = keyed.hoverLabels
    ck kl.len == 1
    if kl.len == 1:
      ck kl[0].attr("data-ct-hover-label") == CloseFileReason
      ck kl[0].textOf == CloseFileReason
      ck kl[0].besideRow(pop, close)
      # Painted last, over the popovers and the panes.
      var last = -1
      for i, c in keyed{"children"}.getElems:
        if c == kl[0]: last = i
      ck last == keyed{"children"}.len - 1
    # Up again, onto New Trace Tab (enabled): the label goes.
    ck windowPlan(ToCloseFile & ",key:up").hoverLabels.len == 0
    # THE POINTER: the same row hovered, then an enabled one.
    let hovered = windowPlan(OpenFile & ",move:" & close.mid)
    let hl = hovered.hoverLabels
    ck hl.len == 1
    if hl.len == 1:
      ck hl[0].textOf == CloseFileReason
      ck hl[0].besideRow(pop, close)
    ck windowPlan(OpenFile & ",move:" & close.mid & ",move:" &
                  newTab.mid).hoverLabels.len == 0

  test "choosing it, by Enter or by a click, keeps the menu open and shows the reason":
    var g0: JsonNode
    discard windowPlan(OpenFile, g0)
    let (pop, close) = g0.fileRow("Close Current File")
    var ge: JsonNode
    let entered = windowPlan(ToCloseFile & ",key:enter", ge)
    ck ge["topBar"]["menuOpen"].getBool
    let el = entered.hoverLabels
    ck el.len == 1 and el[0].textOf == CloseFileReason
    # A press with no motion before it (a touch, a tablet): the press alone
    # must bring the refused row's reason up.
    var gc: JsonNode
    let clicked = windowPlan(OpenFile & ",press:" & close.mid & ",release:" &
                             close.mid, gc)
    ck gc["topBar"]["menuOpen"].getBool
    let cl = clicked.hoverLabels
    ck cl.len == 1 and cl[0].textOf == CloseFileReason
    if cl.len == 1:
      ck cl[0].besideRow(pop, close)

  test "in a window too narrow for one line, the reason wraps: beside the menu where there is room, never past the window":
    # The reason is wider than the room right of the File menu in a laptop-
    # sized window: it wraps there, beside the row, rather than being slid
    # over the very menu it explains. In a window narrower than the reason
    # can sit beside at all, it wraps to the window instead of running out
    # of it.
    for (width, beside) in [(1280, true), (640, false)]:
      checkpoint("window width " & $width)
      var g: JsonNode
      discard windowPlan(OpenFile, g, width = width)
      let (pop, close) = g.fileRow("Close Current File")
      let ls = windowPlan(ToCloseFile, width = width).hoverLabels
      ck ls.len == 1
      if ls.len == 1:
        let lines = ls[0].labelLines
        let r = ls[0].rectOf
        checkpoint("label " & $r & " lines " & $lines)
        ck lines.len > 1 and lines.join(" ") == CloseFileReason
        ck r.x >= 0 and r.x + r.w <= width and r.h == lines.len * 24
        if beside:
          ck ls[0].besideRow(pop, close, width)

suite "PLAT-51 part B GPUI: assertion count":
  test "every assertion ran":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
