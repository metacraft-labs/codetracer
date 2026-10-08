## test_plat47_gpui_parity.nim — PLAT-47. **The GPUI window at desktop
## parity: the shared default is the desktop's Debug layout, the FILES and
## calltrace panes list what the desktop's list, and the tab strip and focus
## outline are the desktop's.**
##
## Run (needs `just build-gpui`, the `calc` recording under
## `test-logs/tui-fixtures/`, `REPLAY_SERVER_BIN`, and the desktop capture
## `src/tests/visual/answers/plat47-desktop-parity.electron.json` from
## `just plat47-capture-electron`):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat47_gpui_parity.nim
##
## The panes are read out of the SHIPPED `codetracer-gpui --report-plan`'s own
## output on the real recording (Verification-Harness-Traps §4a: never the
## model the case built), and compared with the REAL desktop's capture of the
## same recording.
##
## PLAT-47 part B adds, over the same plan: the editor painted from the one
## editor theme (B1 — every token class's colour, the line numbers, the
## ground and the execution band, against the desktop's measured Monaco
## colours), the call trace's title counting the whole trace (B3), and the
## VCS pane over a real git repository with a modified, an added and an
## untracked file (deliverable 4, against the desktop's VCS capture
## `plat47-vcs.electron.json`). The same claims from the WINDOW's pixels are
## `test_plat47_gpui_window.nim`. The chrome's tab and outline styles are the lists
## `chrome.tabStyle` / `.paneOutlineStyle` hand the window
## (`main.paintWindowChrome` applies exactly them), compared with the colours
## the desktop capture measured.
##
## No mocks: the shipped binary, the real shim, the real `replay-server`, a
## real recording and a real desktop capture. A missing prerequisite fails by
## name.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import headless_app/layout_model
import headless_app/arrangement_relation
import gpui/chrome

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  Answers = "src/tests/visual/answers/plat47-desktop-parity.electron.json"
  VcsAnswers = "src/tests/visual/answers/plat47-vcs.electron.json"
  VcsFixture = "scripts/plat47-vcs-fixture.sh"
  WindowRecord = "src/tests/visual/plat45-gpui-arrangement.json"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

proc requirePrereq(ok: bool; what: string) =
  if not ok:
    raise newException(IOError, "prerequisite missing: " & what)

const PlanHeight = 1080
  ## PLAT-48: 900 until the window gained its top bar (a band above the
  ## tree) and the footer's strip: at 900 the editor's rows, centred on the
  ## entry line, no longer reach past `calc`'s module docstring, and B1 saw
  ## only the comment and string classes. At 1080 they reach code again.

proc runPlan(cwd = ""): (int, JsonNode, JsonNode, string) =
  let state = createTempDir("plat47-gpui-state-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  let errFile = genTempPath("plat47-gpui-", ".err")
  let dockFile = genTempPath("plat47-gpui-", ".dock.json")
  let args = @["--report-plan", "--width=1440", "--height=" & $PlanHeight,
               "--dock-out=" & dockFile, calc]
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    workingDir = cwd, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  var plan, dock: JsonNode = newJNull()
  if rc == 0:
    plan = parseJson(output)
    dock = parseJson(readFile(dockFile))
  if fileExists(dockFile): removeFile(dockFile)
  removeDir(state)
  (rc, plan, dock, err)

proc paneText(plan: JsonNode; pane: string): seq[string] =
  ## Every text node under the plan's leaf for `pane`, in order.
  proc texts(n: JsonNode; acc: var seq[string]) =
    if n.kind != JObject: return
    if n{"kind"}.getStr == "TextNode":
      acc.add n{"text"}.getStr
    if n.hasKey("children") and n["children"].kind == JArray:
      for c in n["children"]: texts(c, acc)
  proc walk(n: JsonNode; acc: var seq[string]) =
    if n.kind != JObject: return
    if n{"attributes"}.kind == JObject and
       n["attributes"]{"data-ct-pane"}.getStr == pane:
      texts(n, acc)
      return
    if n.hasKey("children") and n["children"].kind == JArray:
      for c in n["children"]: walk(c, acc)
  walk(plan, result)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  ## Every plan node carrying `attribute`, in plan order.
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n{"attributes"}.kind == JObject and n["attributes"].hasKey(attribute):
      acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc dockRegions(n: JsonNode; x, y, w, h: float;
                 into: var seq[RegionRect]) =
  case n["panel_name"].getStr
  of "StackPanel":
    let info = n["info"]["stack"]
    let horizontal = info["axis"].getInt == 0
    var total = 0.0
    for s in info["sizes"]: total += s.getFloat
    var cursor = if horizontal: x else: y
    for i, c in n["children"].getElems:
      let share = info["sizes"][i].getFloat / total
      if horizontal:
        dockRegions(c, cursor, y, w * share, h, into)
        cursor += w * share
      else:
        dockRegions(c, x, cursor, w, h * share, into)
        cursor += h * share
  of "TabPanel":
    var tabs: seq[string] = @[]
    for c in n["children"]:
      tabs.add c["info"]["panel"]["pane"].getStr
    into.add RegionRect(x: x, y: y, w: w, h: h, tabs: tabs,
                        active: n["info"]["tabs"]["active_index"].getInt)
  else:
    discard

suite "PLAT-47: the GPUI window at desktop parity":

  test "the prerequisites are here":
    requirePrereq(fileExists(bin), bin & " (just build-gpui)")
    requirePrereq(dirExists(calc), calc & " (run 'just test-tui' once)")
    requirePrereq(fileExists(repo / Answers),
                  Answers & " (just plat47-capture-electron)")

  let desk = if fileExists(repo / Answers): parseFile(repo / Answers)
             else: newJObject()
  let (rc, plan, dock, err) = runPlan()

  test "the window opens the desktop's Debug layout: TESTS with FILES, no CONSTRAINTS":
    if rc != 0: checkpoint(err)
    ck rc == 0
    var regions: seq[RegionRect] = @[]
    dockRegions(dock["center"], 0, 0, 1440, PlanHeight, regions)
    let got = ofRegions(regions, tolerance = 0.5)
    checkpoint("gpui: " & got.canonical)
    ck got.problem.len == 0
    ck sameArrangement(got, ofTree(sharedDefaultLayout().tree))
    ck got.canonical.contains("stack[fileTree*,vcs,testResults]")
    ck not got.canonical.contains("constraints")

  test "FILES lists the desktop's entries, and the call trace its calls":
    var want: seq[string] = @[]
    for e in desk{"files"}.getElems: want.add e.getStr
    let files = paneText(plan, "fileTree").join("\n")
    checkpoint("gpui files: " & files)
    ck want.len == 3
    for w in want:
      ck files.contains(w)
    var calls: seq[string] = @[]
    for e in desk{"calltrace"}.getElems: calls.add e.getStr
    # One entry per drawn call row (PLAT-49: a row is drawn as its semantic
    # parts — toggle, callee, index, arguments, return — each a text node).
    var trace: seq[string] = @[]
    for row in plan.nodesWith("data-call-index"):
      trace.add textOf(row)
    checkpoint("gpui calltrace: " & $trace[0 ..< min(6, trace.len)])
    ck calls.len >= 5
    # Each of the desktop's first calls, in order, is a row of the GPUI pane
    # (indented by depth, as the desktop's rows are).
    var at = 0
    var matched = 0
    for c in calls[0 ..< min(10, calls.len)]:
      # A row reads "<toggle> callee #index(args) => return"; the desktop's
      # `.call-text` is the callee and index, right before the arguments.
      while at < trace.len and not trace[at].contains(c & "("):
        inc at
      if at < trace.len:
        inc matched
        inc at
    ck matched == min(10, calls.len)

  test "the tab strip and the focus outline are the desktop's":
    let active = tabStyle(true)
    let inactive = tabStyle(false)
    ck ("font-weight", "bold") in active
    ck ("font-weight", "bold") notin inactive
    ck active[0][1] != inactive[0][1]
    # PLAT-49 (the user's direction over PLAT-47's measurement): the selected
    # tab has a background of its own, distinct from the strip's own ground.
    ck ("background-color", chromeOf(crTabActiveBackground)) in active
    ck chromeOf(crTabActiveBackground) != chromeOf(crTabStripBackground)
    for (k, v) in active & inactive:
      # No glyph anywhere: a tab is styled, never framed.
      ck k in ["color", "font-weight", "background-color"]
    # B2: a 1px BORDER of the desktop's outline colour around the focused
    # pane, the same width — invisible — around every other.
    ck ("border-color", desk{"focus"}{"outline"}.getStr) in
       paneOutlineStyle(true)
    ck ("border-width", desk{"focus"}{"outlineWidth"}.getStr) in
       paneOutlineStyle(true)
    ck ("border-width", desk{"focus"}{"outlineWidth"}.getStr) in
       paneOutlineStyle(false)
    ck ("border-color", desk{"focus"}{"outline"}.getStr) notin
       paneOutlineStyle(false)
    ck ("border-color", chromeOf(crWindowBackground)) in
       paneOutlineStyle(false)

  test "the WINDOW outlines its focused region, closed, in the desktop's colour":
    # Read off the window's own PIXELS (PLAT-39's reader, via PLAT-45's
    # committed record `src/tests/visual/plat45-gpui-arrangement.json`, which
    # `just plat45-arrangement-window && just plat45-window-record`
    # regenerates): the focused region — the editor, where the window's keys
    # go — carries the desktop's outline gray on all four edges, and no other
    # region carries it on any edge.
    let record = parseJson(readFile(repo / WindowRecord))
    let regions = record["frames"]["shared"]["regions"]
    var outlined = 0
    for r in regions:
      let o = r{"outline"}
      ck not o.isNil
      if o.isNil: continue
      let all4 = o["top"].getBool and o["bottom"].getBool and
                 o["left"].getBool and o["right"].getBool
      let any = o["top"].getBool or o["bottom"].getBool or
                o["left"].getBool or o["right"].getBool
      checkpoint(r["active"].getStr & ": " & $o)
      if r["active"].getStr == "Editor":
        ck all4
        inc outlined
      else:
        ck not any
    ck outlined == 1
    # The record's outline gray is the desktop's measured colour.
    ck desk{"focus"}{"outline"}.getStr == chromeOf(crFocusOutline)

  test "B1: the editor's colours are the desktop's Monaco colours, class by class":
    let ed = desk["editor"]
    # The desktop scope each class is measured under.
    const classKey = [("tcKeyword", "keyword"), ("tcString", "string"),
                      ("tcComment", "comment"), ("tcIdentifier", "identifier"),
                      ("tcPunctuation", "delimiter"), ("tcPlain", "identifier")]
    var seen: seq[string] = @[]
    for run in nodesWith(plan, "data-ct-token-class"):
      let cls = run["attributes"]["data-ct-token-class"].getStr
      for (c, key) in classKey:
        if c == cls:
          if cls notin seen: seen.add cls
          if run["styles"]{"text_color"}.getStr != ed[key].getStr:
            checkpoint(cls & " '" & textOf(run) & "' is " &
                       run["styles"]{"text_color"}.getStr & ", want " &
                       ed[key].getStr)
            ck false
    checkpoint("classes seen: " & $seen)
    ck seen.len == classKey.len
    # The line numbers, resting and on the execution line, and the band on
    # the CODE COLUMN — never on the row, never on the gutter.
    var banded = 0
    var restingNumbers = 0
    var activeNumbers = 0
    for row in nodesWith(plan, "data-ct-row"):
      let gutter = row["children"][0]
      let column = row["children"][1]
      ck column{"attributes"}{"data-ct-code-column"}.getStr == "true"
      ck row["styles"]{"bg"}.getStr == ""
      ck gutter["styles"]{"bg"}.getStr == ""
      let execution = row["attributes"]["data-ct-pointer"].getStr == "eptExecution"
      if execution:
        inc banded
        ck column["styles"]{"bg"}.getStr == ed["executionLine"].getStr
        ck column["styles"]{"flex_grow"}.getStr == "1"
        ck gutter["styles"]{"text_color"}.getStr == ed["activeLineNumber"].getStr
        inc activeNumbers
      else:
        ck column["styles"]{"bg"}.getStr == ""
        if gutter["styles"]{"text_color"}.getStr == ed["lineNumber"].getStr:
          inc restingNumbers
    ck banded == 1
    ck activeNumbers == 1
    ck restingNumbers > 20
    # The ground: the editor pane's own background.
    var ground = ""
    for pane in nodesWith(plan, "data-ct-pane"):
      if pane["attributes"]["data-ct-pane"].getStr == "editor":
        ground = pane["styles"]{"bg"}.getStr
    ck ground == ed["background"].getStr

  test "B3: the call trace's title counts the whole trace":
    let trace = paneText(plan, "calltrace")
    ck trace.len > 0
    ck trace[0].startsWith("Call Trace ") and trace[0].endsWith(" call(s)")
    ck trace[0] != "Call Trace 0 call(s)"

  test "deliverable 4: the VCS pane over a real repository equals the desktop's VCS panel":
    requirePrereq(fileExists(repo / VcsAnswers),
                  VcsAnswers & " (just plat47-capture-electron)")
    let want = parseFile(repo / VcsAnswers)
    let dir = createTempDir("plat47-gpui-vcs-", "")
    let fixture = execCmdEx("bash " & quoteShell(repo / VcsFixture) & " " &
                            quoteShell(dir / "repo"))
    ck fixture.exitCode == 0
    let (vrc, vplan, _, verr) = runPlan(cwd = dir / "repo")
    if vrc != 0: checkpoint(verr)
    ck vrc == 0
    let vcs = paneText(vplan, "vcs")
    checkpoint("gpui vcs: " & $vcs)
    ck want["branch"].getStr in vcs
    ck want["header"].getStr in vcs
    var rows: seq[string] = @[]
    for r in want["rows"]:
      rows.add r[0].getStr & " " & r[1].getStr
    ck rows.len == 3
    # The three changed files, with their states, in the desktop's order.
    var at = -1
    for r in rows:
      let i = vcs.find(r)
      ck i > at
      at = i
    for c in want["commits"]:
      var found = false
      for line in vcs:
        if line.endsWith(" " & c.getStr): found = true
      ck found
    removeDir(dir)

echo "CHECKS: ", CHECKS
