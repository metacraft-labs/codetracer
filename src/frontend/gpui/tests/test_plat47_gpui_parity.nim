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
## same recording. The chrome's tab and outline styles are the lists
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
  WindowRecord = "src/tests/visual/plat45-gpui-arrangement.json"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = repo.parentDir / "isonim-gpui/rust/target/debug"
let calc = repo / CalcFixture

proc requirePrereq(ok: bool; what: string) =
  if not ok:
    raise newException(IOError, "prerequisite missing: " & what)

proc runPlan(): (int, JsonNode, JsonNode, string) =
  let state = createTempDir("plat47-gpui-state-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  let errFile = genTempPath("plat47-gpui-", ".err")
  let dockFile = genTempPath("plat47-gpui-", ".dock.json")
  let args = @["--report-plan", "--width=1440", "--height=900",
               "--dock-out=" & dockFile, calc]
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
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
    dockRegions(dock["center"], 0, 0, 1440, 900, regions)
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
    let trace = paneText(plan, "calltrace")
    checkpoint("gpui calltrace: " & $trace[0 ..< min(6, trace.len)])
    ck calls.len >= 5
    # Each of the desktop's first calls, in order, is a row of the GPUI pane
    # (indented by depth, as the desktop's rows are).
    var at = 0
    var matched = 0
    for c in calls[0 ..< min(10, calls.len)]:
      while at < trace.len and trace[at].strip() != c:
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
    for (k, v) in active & inactive:
      # No glyph anywhere: a tab is styled, never framed.
      ck k in ["color", "font-weight"]
    ck ("background-color", desk{"focus"}{"outline"}.getStr) in
       paneOutlineStyle(true)
    ck ("padding", "1px") in paneOutlineStyle(true)
    ck ("padding", "1px") in paneOutlineStyle(false)
    ck ("background-color", desk{"focus"}{"outline"}.getStr) notin
       paneOutlineStyle(false)
    ck ("background-color", chromeOf(crWindowBackground)) in
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

echo "CHECKS: ", CHECKS
