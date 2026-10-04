## test_plat50_gpui_plan.nim — PLAT-50 on GPUI: the desktop's click
## behaviours, colours, centred omnibox and dividers in the WINDOW, read from
## the shipped `codetracer-gpui`'s window plan (`--report-window-plan`) after
## `--window-ops` presses.
##
## A press on a pane row is `click:<part>:<key>[:<button>[:ctrl|alt|ctrl+alt]]`
## (a code key is `<line>@<column>`; `label-menu:<pane>` right-clicks a dock
## label): the
## binary finds the row the window wired (`window_clicks.findClickTarget`)
## and dispatches the press to it as the shim delivers a real press to the
## element under the pointer (`isonim-gpui`'s `wire_pointer_listeners`, whose
## right and middle buttons are new for this); `ctx:<label>` presses an entry
## of the open right-click menu. Each case asserts the click's effect as the
## window draws it:
##
##   * K24 / K25 — an event row: the editor's execution line and the
##     timeline's tick move to the event (line 111, tick 68); a right click
##     opens the event's content;
##   * K10 / K11 — the gutter: a breakpoint mark on the row; a right click
##     disables it (the dimmed mark);
##   * K12 / K13 — the code: Ctrl+click and a middle click go to the line; a
##     right click opens the desktop's editor menu, and its Run to Cursor
##     runs there;
##   * K22 — a call's menu, and Collapse Call Children collapses it;
##   * K7 — a tab's menu, and Close removes the tab;
##   * K27 / K28 — a value expands; a variable's menu;
##   * K30 — the timeline's track seeks;
##   * K17 / K18 / K19 — Files (on `multi_root`): a file opens in the editor
##     (its tab names it), a folder collapses, a node opens no menu (the
##     desktop has none);
##   * K23 / K33 — an argument pinned to the scratchpad, its close button;
##   * K26 — an event-log header orders the log, again reverses it;
##   * K14 / K15 — Alt+click anchors a column breakpoint, Ctrl+Alt+click and
##     the menu's "Jump to call" go into the call;
##   * K36 — an inline value's menu, Ctrl+click pins it;
##   * K29 / K31 / K37 / K42 — the Variables tabs, a point selected in the
##     Points pane the View menu opens, the footer's location copied (read
##     back from the shim's clipboard), a dock label's menu;
##   * K34 / K53 — the VCS pane on a real git repository: a file's diff, a
##     commit's files.
##
## And the chrome (deliverables 4-6): the band and the window on the
## desktop's ground (ui/surface/primary/default), panes on the panel, the
## omnibox the desktop's `clamp(24em, 24vw, 40em)` and centred, inside a
## ui/border/secondary border; a right-click menu on the dropdown surface in
## ui/border/primary; `--dividers=subtle` draws a line in each gap between
## side-by-side panes, the default none.
##
## No mocks: the shipped binary, real recordings, a real `replay-server`.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
from std/unicode import runeLen

import gpui/chrome
import gpui/window_geometry
import gpui/window_top_bar
import styles/generated/design_tokens
from ../../../common/view_vocabulary/layout_questions import trGutterLineNumber

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 112
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  MultiRootPrefix = "multi_root-"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1440
  H = 1400

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

proc multiRoot(): string =
  for kind, path in walkDir(repo / "test-logs/tui-fixtures"):
    if kind == pcDir and path.extractFilename.startsWith(MultiRootPrefix):
      return path
  ""

proc windowPlan(ops: string; subject = ""; pre: seq[string] = @[];
                trace: var string; workDir = ""): JsonNode =
  ## The window's root after `ops`, as the shipped binary reports it, and the
  ## window's gesture trace (stderr).
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat50-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  var args = pre & @["--report-window-plan", "--width=" & $W,
                     "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add (if subject.len > 0: subject else: calc)
  let errFile = genTempPath("plat50-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    # A run that never finishes (a move the engine never answers) is a
    # failure, not a wait: the window is given two minutes.
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args,
    workingDir = workDir, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result = parseJson(output)
  proc sweep(n: JsonNode) =
    if n{"tag"}.getStr == "img":
      let src = n{"attributes"}{"src"}.getStr
      if src.len > 0 and fileExists(src):
        try: removeDir(src.parentDir)
        except OSError: discard
    for c in n{"children"}.getElems: sweep(c)
  sweep(result)

proc windowPlan(ops: string; subject = ""; pre: seq[string] = @[];
                workDir = ""): JsonNode =
  var t: string
  windowPlan(ops, subject, pre, t, workDir)

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

proc px(n: JsonNode; style: string): int =
  let v = n{"styles"}{style}.getStr
  if v.endsWith("px"): parseInt(v[0 ..< v.len - 2]) else: -1

proc executionLine(plan: JsonNode): int =
  for n in plan.nodesWith("data-ct-execution-line"):
    return parseInt(n.attr("data-ct-execution-line"))
  -1

proc markOf(plan: JsonNode; line: int): string =
  for n in plan.nodesWith("data-ct-row"):
    if n.attr("data-ct-row") == $line:
      return n.attr("data-ct-mark")

proc menuEntries(plan: JsonNode): seq[(string, string)] =
  for n in plan.nodesWith("data-ct-context-entry"):
    result.add (n.attr("data-ct-context-entry"),
                n.attr("data-ct-context-enabled"))

proc typed(text: string): string =
  ## `--window-ops` keys typing `text`.
  for ch in text:
    result.add(if ch == ' ': ",key:space" else: ",key:" & $ch)

proc viewText(plan: JsonNode; id: string): string =
  ## The text of the vocabulary view `id`.
  for n in plan.nodesWith("data-view-id"):
    if n.attr("data-view-id") == id: return n.textOf

proc contentOf(plan: JsonNode): (string, string) =
  ## The text over the window: its title and its text.
  for n in plan.nodesWith("data-ct-event-content"):
    return (n.attr("data-ct-event-content"), n.textOf)

proc codeTextOf(plan: JsonNode; line: int): string =
  ## The code an editor row draws (its annotation not included).
  for n in plan.nodesWith("data-ct-row"):
    if n.attr("data-ct-row") == $line:
      for c in n.nodesWith("data-ct-text-role"):
        if c.attr("data-ct-text-role") == "editor-code":
          return c.textOf

proc dark(t: DesignToken): string = DesignTokenHex[t][dmDark]

var callIndexCache: seq[(string, string)]

proc callIndexOf(name, args: string): string =
  ## The `data-call-index` of the call-trace row for `name` called with
  ## `args` — found by WHAT the call is, not by its number, which depends on
  ## the frames the recorder wraps the program in.
  for (k, v) in callIndexCache:
    if k == name & args: return v
  for n in windowPlan("").nodesWith("data-call-index"):
    let t = n.textOf
    if t.contains(name & " #") and t.contains(args):
      result = n.attr("data-call-index")
      break
  callIndexCache.add (name & args, result)

suite "PLAT-50 GPUI: the event log, the editor and the timeline":

  test "an event row goes to the event; a right click shows its content":
    let plan = windowPlan("click:event:1:left")
    ck plan.executionLine == 111
    ck plan.textOf.contains("tick 68")
    let shown = windowPlan("click:event:2:right")
    let content = shown.nodesWith("data-ct-event-content")
    ck content.len == 1
    ck content[0].attr("data-ct-event-content").contains("event #2 at tick 88")
    ck content[0].textOf.contains("6 * 7 = 42")
    ck content[0].style("bg") == dark(dtColorsUiSurfacePrimaryDefault)
    # The debugger did not move.
    ck shown.executionLine != 111

  test "the gutter sets a breakpoint; a right click disables it":
    let plan = windowPlan("click:gutter:31:left")
    ck plan.markOf(31) == "emBreakpoint"
    let off = windowPlan("click:gutter:31:left,click:gutter:31:right")
    ck off.markOf(31) == "emBreakpointDisabled"
    let back = windowPlan(
      "click:gutter:31:left,click:gutter:31:right,click:gutter:31:right")
    ck back.markOf(31) == "emBreakpoint"
    # The rows a press reaches are the ones the user sees: every element
    # wired as the gutter is a line number, every one wired as code is the
    # code column — a press on the number never runs the code's behaviour.
    var gutters, codes = 0
    var wiredRight = true
    for n in plan.nodesWith("data-ct-clicks"):
      case n.attr("data-ct-clicks")
      of "gutter":
        inc gutters
        if n.attr("data-ct-text-role") != $trGutterLineNumber:
          wiredRight = false
      of "code":
        inc codes
        if not n.has("data-ct-code-column"): wiredRight = false
      else: discard
    ck gutters > 10 and codes > 10
    ck wiredRight

  test "Ctrl+click and a middle click go to the line":
    ck windowPlan("click:code:31:left:ctrl").executionLine == 31
    ck windowPlan("click:code:36:middle").executionLine == 36
    # A plain click goes nowhere.
    ck windowPlan("click:code:31:left").executionLine != 31

  test "the editor's menu is the desktop's, and Run to Cursor runs there":
    var trace = ""
    let plan = windowPlan("click:code:31:right", trace = trace)
    let entries = plan.menuEntries
    var labels: seq[string] = @[]
    for (l, _) in entries: labels.add l
    ck labels == @["Copy", "Find", "Jump to line", "Run to Cursor",
                   "Jump backward to line", "Jump to call",
                   "Jump forward to call", "Jump backward to call",
                   "Add breakpoint", "Add tracepoint"]
    # Every entry enabled, as on the desktop.
    for (_, enabled) in entries: ck enabled == "true"
    let menu = plan.nodesWith("data-ct-context-menu")
    ck menu.len == 1
    ck menu[0].attr("data-ct-context-menu") == "editor-text"
    ck menu[0].style("bg") == dark(dtColorsUiSurfacePrimaryDefault)
    ck menu[0].style("border_color") == dark(dtColorsUiBorderPrimary)
    let ran = windowPlan("click:code:31:right,ctx:Run to Cursor")
    ck ran.executionLine == 31
    ck ran.nodesWith("data-ct-context-menu").len == 0
    # Copy: the line, to the system clipboard (the shim's).
    var copyTrace = ""
    let copied = windowPlan("click:code:31:right,ctx:Copy", trace = copyTrace)
    ck copied.nodesWith("data-ct-context-menu").len == 0
    ck copyTrace.contains("copied line 31: return left + right")
    # Nothing BEFORE the first stop: "Jump backward to line" finds no step,
    # the window answers (it does not hang on a move that never comes) and
    # the debugger stays where it was.
    var missTrace = ""
    let miss = windowPlan("click:code:31:right,ctx:Jump backward to line",
                          trace = missTrace)
    ck miss.executionLine == 1
    ck missTrace.contains("line jump failed: no backward step reaches")

  test "the timeline's track seeks":
    var trace = ""
    # Four fifths along the track (`click:timeline:<permille>`).
    let plan = windowPlan("click:tab:timeline:left,click:timeline:800",
                          trace = trace)
    ck trace.contains("pane click timeline")
    ck plan.executionLine != 1
    ck plan.textOf.contains("tick 13")

suite "PLAT-50 GPUI: the call trace, a tab and the variables":

  test "a call's menu: Collapse Call Children collapses it":
    let applyOp = callIndexOf("apply_op", "left=2")
    ck applyOp.len > 0
    let plan = windowPlan("click:call:" & applyOp & ":right")
    var labels: seq[string] = @[]
    for (l, _) in plan.menuEntries: labels.add l
    ck labels == @["Collapse Call Children"]
    ck plan.menuEntries[0][1] == "true"
    var trace = ""
    let done = windowPlan("click:call:" & applyOp & ":right,ctx:Collapse Call Children",
                          trace = trace)
    ck trace.contains("context action toggle-call-children")
    # The call (apply_op) is collapsed: its toggle says so, its child is gone
    # from the rows (the rows renumber, so the toggle is what is read).
    var toggle = ""
    for n in done.nodesWith("data-call-index"):
      if n.attr("data-call-index") == applyOp: toggle = n.attr("data-call-toggle")
    ck toggle == "collapsed"

  test "a tab's menu: Close removes the tab":
    let plan = windowPlan("click:tab:vcs:right")
    var labels: seq[string] = @[]
    for (l, _) in plan.menuEntries: labels.add l
    ck labels == @["Pin to Left", "Pin to Bottom", "Pin to Right", "Close",
                   "Maximise container"]
    ck plan.menuEntries[4][1] == "true"
    # Maximise: the container alone in the window, then back.
    let full = windowPlan("click:tab:vcs:right,ctx:Maximise container")
    var boxes = 0
    for n in full.nodesWith("data-ct-tabs"): inc boxes
    ck boxes == 1
    let back = windowPlan("click:tab:vcs:right,ctx:Maximise container," &
                          "click:tab:vcs:right,ctx:Minimise container")
    var boxesBack = 0
    for n in back.nodesWith("data-ct-tabs"): inc boxesBack
    ck boxesBack > 3
    let closed = windowPlan("click:tab:vcs:right,ctx:Close")
    var vcs = false
    for n in closed.nodesWith("data-ct-tab-pane"):
      if n.attr("data-ct-tab-pane") == "vcs": vcs = true
    ck not vcs

  test "a value expands; a variable's menu":
    let open = windowPlan("click:event:3:left,click:var:EXPRESSIONS:left")
    var child = false
    for n in open.nodesWith("data-view-id"):
      if n.attr("data-view-id") == "EXPRESSIONS.[0]": child = true
    ck child
    let menu = windowPlan("click:event:3:left,click:var:EXPRESSIONS:right")
    let entries = menu.menuEntries
    ck entries.len == 2
    ck entries[0][0] == "Toggle value history"
    ck entries[1][0] == "Show value origin"
    ck entries[0][1] == "true" and entries[1][1] == "true"
    # The value's history, then its origin, over the window.
    let hist = windowPlan("click:event:3:left,click:var:EXPRESSIONS:right," &
                          "ctx:Toggle value history").contentOf
    ck hist[0].startsWith("history of EXPRESSIONS (")
    ck hist[1].contains("\"2 + 3\"")
    let origin = windowPlan("click:event:3:left,click:var:EXPRESSIONS:right," &
                            "ctx:Show value origin").contentOf
    ck origin[0] == "origin of EXPRESSIONS"
    ck origin[1].len > 0

suite "PLAT-50 GPUI: Files":

  test "a file opens in the editor; a folder collapses; a node's menu":
    let mr = multiRoot()
    ck mr.len > 0
    if mr.len > 0:
      var trace = ""
      # Find helpers.py's node: the tree's ids are child-index paths.
      let plan0 = windowPlan("", mr)
      var helpers = ""
      for n in plan0.nodesWith("data-ct-clicks"):
        if n.attr("data-ct-clicks") == "file" and
           n.textOf.startsWith("helpers.py"):
          helpers = n.attr("data-view-id")
      ck helpers.startsWith("fileTree.")
      let opened = windowPlan("click:file:" & helpers & ":left", mr,
                              trace = trace)
      ck trace.contains("opened ")
      ck opened.textOf.contains("def add(left, right):")
      var tabNamesIt = false
      for n in opened.nodesWith("data-ct-tabs"):
        if n.attr("data-ct-tabs").contains("helpers.py"): tabNamesIt = true
      ck tabNamesIt
      # One press, one row: the folder the file is in heard the press too (a
      # press bubbles) and did NOT collapse — its file is still drawn.
      var stillListed = false
      for n in opened.nodesWith("data-ct-clicks"):
        if n.attr("data-view-id") == helpers: stillListed = true
      ck stillListed
      # The folder above it collapses: its files are no longer drawn.
      let folder = helpers[0 ..< helpers.rfind('.')]
      let collapsed = windowPlan("click:file:" & folder & ":left", mr)
      var still = false
      for n in collapsed.nodesWith("data-ct-clicks"):
        if n.attr("data-view-id") == helpers: still = true
      ck not still
      # No Files menu, as on the desktop.
      let menu = windowPlan("click:file:" & helpers & ":right", mr)
      ck menu.menuEntries.len == 0
      ck menu.nodesWith("data-ct-context-menu").len == 0

suite "PLAT-50 GPUI: the sweep's other rows":

  test "an argument pinned to the scratchpad; its close button removes it":
    let add = callIndexOf("add", "left=2, right=3")
    let plan = windowPlan("click:arg:" & add & "/0:right,ctx:Add value to scratchpad," &
                          "click:tab:scratchpad:left")
    ck plan.viewText("scratchpad").contains("left2")
    let gone = windowPlan("click:arg:" & add & "/0:right," &
                          "ctx:Add value to scratchpad," &
                          "click:tab:scratchpad:left,click:scratch:0:left")
    ck gone.viewText("scratchpad").len == 0
    ck gone.textOf.contains("no values have been pinned to the scratchpad")

  test "an event-log header orders the log; again reverses it":
    let up = windowPlan("click:header:output")
    let t = up.viewText("eventLog")
    ck t.contains("output ▲")
    ck t.find("1 + 2 * 3 - 4 / 2 = 2") < t.find("2 + 3 = 5")
    ck t.find("2 + 3 = 5") < t.find("checksum = 73")
    let down = windowPlan("click:header:output,click:header:output")
    let d = down.viewText("eventLog")
    ck d.contains("output ▼")
    ck d.find("checksum = 73") < d.find("2 + 3 = 5")

  test "Alt+click anchors a column breakpoint; Ctrl+Alt+click goes into a call":
    var trace = ""
    let plan = windowPlan("click:code:31@12:left:alt", trace = trace)
    ck plan.markOf(31) == "emBreakpoint"
    ck trace.contains("column breakpoint 31:12")
    # The point list holds the breakpoint AT ITS COLUMN (the store's row is
    # the engine's verified anchor), as the Points pane lists it.
    let listed = windowPlan("click:code:31@12:left:alt," &
      "key:p:control,key:colon" & typed("Breakp") & ",key:enter")
    var rows: seq[string] = @[]
    for n in listed.nodesWith("data-ct-clicks"):
      if n.attr("data-ct-clicks") == "point": rows.add n.textOf
    ck rows.len == 1 and rows[0].contains("main.py:31:12")
    # Event 1 stops on line 111; line 109 calls `evaluate`.
    let into = windowPlan("click:event:1:left,click:code:109@20:left:ctrl+alt")
    ck into.executionLine == 72
    let menu = windowPlan("click:event:1:left,click:code:109@20:right," &
                          "ctx:Jump to call")
    ck menu.executionLine == 72

  test "an inline value's menu; Ctrl+click pins it":
    let stop = windowPlan("click:event:1:left")
    let code = stop.codeTextOf(111)
    ck code.len > 0
    let col = code.runeLen + 5          # inside the first `name: value`
    var trace = ""
    let menu = windowPlan("click:event:1:left,click:value:111@" & $col &
                          ":right", trace = trace)
    var labels: seq[string] = @[]
    for (l, _) in menu.menuEntries: labels.add l
    ck labels == @["Jump to value", "Add value to scratchpad",
                   "Add all values to scratchpad"]
    let pinned = windowPlan("click:event:1:left,click:value:111@" & $col &
                            ":left:ctrl,click:tab:scratchpad:left")
    ck pinned.viewText("scratchpad").len > 0

  test "the Variables tabs, a point, the footer's location, a dock label":
    let globals = windowPlan("click:statetab:1:left")
    ck globals.viewText("state.root").startsWith("globals")
    var trace = ""
    let points = windowPlan("click:gutter:31:left,click:gutter:36:left," &
      "key:p:control,key:colon" & typed("Breakp") & ",key:enter," &
      "click:point:1:left", trace = trace)
    ck trace.contains("leaf adopted pointList")
    var highlighted = ""
    for n in points.nodesWith("data-ct-clicks"):
      if n.attr("data-ct-clicks") == "point" and
         n.attr("data-highlighted") == "true":
        highlighted = n.textOf
    ck highlighted.contains("main.py:36")
    var copyTrace = ""
    discard windowPlan("click:position:x", trace = copyTrace)
    # The path, as the desktop's copy control copies it (no line), read back
    # from the shim's clipboard.
    var copied = ""
    for l in copyTrace.splitLines:
      let at = l.find("copied the path: ")
      if at >= 0: copied = l[at + "copied the path: ".len .. ^1].strip()
    ck copied.endsWith("test-programs/calc/main.py")
    let labelMenu = windowPlan("label-menu:buildOutput")
    var labels: seq[string] = @[]
    for (l, _) in labelMenu.menuEntries: labels.add l
    ck labels == @["Pin to Left", "Pin to Right", "Unpin", "Close"]

  test "the VCS pane: a file's diff, a commit's files":
    let repo = createTempDir("plat50-vcs-gpui-", "") / "repo"
    let (output, code) = execCmdEx("bash " &
      quoteShell(getEnv("CODETRACER_REPO_ROOT", getCurrentDir()) /
                 "scripts" / "plat47-vcs-fixture.sh") & " " &
      quoteShell(repo))
    if code != 0: checkpoint(output)
    ck code == 0
    let diff = windowPlan("click:tab:vcs:left,click:vcsfile:file-1:left",
                          workDir = repo).contentOf
    ck diff[0] == "diff notes.txt  (working tree)"
    ck diff[1].contains("+++ b/notes.txt")
    let opened = windowPlan("click:tab:vcs:left,click:commit:commit-0:left",
                            workDir = repo)
    let list = opened.viewText("vcs.commits.list")
    ck list.contains("A notes.txt") and list.contains("A unchanged.txt")

suite "PLAT-50 GPUI: the chrome":

  test "the desktop's grounds, a centred bordered omnibox":
    let plan = windowPlan("")
    let band = plan.nodesWith("data-ct-top-bar")
    var bandBg = ""
    for n in band:
      if n.attr("data-ct-top-bar") == "band": bandBg = n.style("bg")
    ck bandBg == dark(dtColorsUiSurfacePrimaryDefault)
    ck chromeOf(crWindowBackground) == dark(dtColorsUiSurfacePrimaryDefault)
    ck chromeOf(crPaneBackground) == dark(dtColorsUiSurfaceBasePanel)
    ck chromeOf(crTabStripBackground) == dark(dtColorsUiSurfacePrimaryDefault)
    let omni = plan.nodesWith("data-ct-omnibar")
    ck omni.len == 1
    let o = omni[0]
    ck o.px("w") == omnibarDesktopPx(W)
    ck o.px("w") == OmnibarDesktopFloorPx          # 24% of 1440 is below it
    ck abs(o.px("left") + o.px("w") div 2 - W div 2) <= 1
    ck o.style("bg") == dark(dtColorsUiSurfaceInputDefault)
    ck o.style("border_color") == dark(dtColorsUiBorderSecondary)
    # No transport control has a ground of its own.
    var groundless = true
    for n in plan.nodesWith("data-ct-control"):
      if n.style("bg").len > 0: groundless = false
    ck groundless
    ck omnibarDesktopPx(3000) == OmnibarDesktopCeilingPx

  test "--dividers=subtle draws a line in each gap between side-by-side panes":
    let plain = windowPlan("")
    ck plain.nodesWith("data-ct-divider-line").len == 0
    let subtle = windowPlan("", pre = @["--dividers=subtle"])
    let lines = subtle.nodesWith("data-ct-divider-line")
    ck lines.len >= 2
    for l in lines:
      ck l.px("w") == 1
      ck l.style("bg") == dark(dtColorsUiBorderSecondary)

suite "PLAT-50 GPUI plan: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
