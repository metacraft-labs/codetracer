## test_plat45_gpui_layout.nim — PLAT-45. **The GPUI window opens the shared
## default, draws every pane of it (data or a report), and remembers its OWN
## last layout in its own file.**
##
## Run (needs `just build-gpui`, the `calc` recording under
## `test-logs/tui-fixtures/`, and `REPLAY_SERVER_BIN`):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat45_gpui_layout.nim
##
## Every case runs the SHIPPED `codetracer-gpui --report-plan` on the real
## `calc` recording with a state directory of its own, and reads the window's
## arrangement out of the binary's OWN OUTPUT — the dock document it hands
## gpui-kit (`--dock-out`), reduced to the medium-independent relation by
## `arrangement_relation.ofRegions`, and the render plan's pane leaves — never
## out of the `Layout` the case wrote (Verification-Harness-Traps §4a).
##
##   1. **Deliverable 6**: with nothing remembered the window opens the shared
##      default, depth 0 — the arrangement's relation equals the shared tree's.
##   2. **Deliverable 2**: every pane of the shared default is in the plan;
##      the panes this front-end cannot draw are REPORT leaves naming the pane
##      and the reason (`gpui/app/capability.gpuiCapability`), never absent.
##   3. **Deliverable 8**: rearrange (`--layout-ops`, the window's scripted
##      gesture) → written through to `gpui-layout.json` and to nothing else;
##      restart → the rearranged layout; the terminal's and the desktop's
##      layout files, planted with arrangements of their own, are never read;
##      `--reset-layout` → the shared default returns and ONLY the GPUI file
##      is gone; a corrupt file is reported by kind, the window opens on the
##      default, and the file is left byte for byte.
##
## No mocks: the shipped binary, the real shim, the real `replay-server`, a real
## recording and real files.

import std/[json, os, osproc, sets, streams, strtabs, strutils, tempfiles,
            unittest]

import headless_app/layout_model
import headless_app/arrangement_relation
import gpui/app/capability

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  GpuiDocument = "gpui-layout.json"
  TuiDocument = "tui-layout.json"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

proc requirePrereq(ok: bool; what: string) =
  ## **A MISSING PREREQUISITE FAILS BY NAME. It does not skip.**
  if not ok:
    raise newException(IOError, "prerequisite missing: " & what)

type Run = object
  rc: int
  plan: JsonNode
  dock: JsonNode
  err: string

proc runGpui(stateDir, configHome: string; extra: seq[string] = @[]): Run =
  ## One headless `--report-plan` run on `calc`, with its own state root and
  ## its own `XDG_CONFIG_HOME` (where the DESKTOP keeps its layout).
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = stateDir
  env["XDG_CONFIG_HOME"] = configHome
  let errFile = genTempPath("plat45-gpui-", ".err")
  let dockFile = genTempPath("plat45-gpui-", ".dock.json")
  var args = @["--report-plan", "--width=1440", "--height=900",
               "--dock-out=" & dockFile]
  args.add extra
  args.add calc
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  result.rc = p.waitForExit()
  p.close()
  result.err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  if result.rc == 0:
    result.plan = parseJson(output)
    result.dock = parseJson(readFile(dockFile))
  if fileExists(dockFile):
    removeFile(dockFile)

proc dockRegions(n: JsonNode; x, y, w, h: float;
                 into: var seq[RegionRect]) =
  ## The dock document's centre, laid out from its OWN axes and pixel sizes.
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

proc centreArrangement(dock: JsonNode): Arrangement =
  var regions: seq[RegionRect] = @[]
  dockRegions(dock["center"], 0, 0, 1440, 900, regions)
  ofRegions(regions, tolerance = 0.5)

proc planLeaves(plan: JsonNode): seq[(string, string, string)] =
  ## `(pane, slot path, state)` for every pane leaf the plan draws.
  proc walk(n: JsonNode; acc: var seq[(string, string, string)]) =
    if n.kind != JObject: return
    if n.hasKey("attributes") and n["attributes"].kind == JObject:
      let a = n["attributes"]
      if a.hasKey("data-ct-pane"):
        acc.add((a["data-ct-pane"].getStr, a{"data-ct-slot-path"}.getStr,
                 a{"data-ct-state"}.getStr))
    if n.hasKey("children") and n["children"].kind == JArray:
      for c in n["children"]: walk(c, acc)
  walk(plan, result)

proc planText(plan: JsonNode): string =
  ## Every text node of the plan, joined — what the window would paint.
  proc walk(n: JsonNode; acc: var string) =
    if n.kind != JObject: return
    if n{"kind"}.getStr == "TextNode":
      acc.add n{"text"}.getStr & "\n"
    if n.hasKey("children") and n["children"].kind == JArray:
      for c in n["children"]: walk(c, acc)
  walk(plan, result)

proc sharedPaneNames(): HashSet[string] =
  for p in allPanes(sharedDefaultLayout().tree):
    result.incl $p

proc otherProductsPlanted(stateDir, configHome: string): (string, string) =
  ## The terminal's and the desktop's own layout files, planted with
  ## arrangements of THEIR own — each one different from the shared default —
  ## so a GPUI window that read either would open something else.
  var tuiLayout = initLayout(sharedDefaultLayout().tree)
  let docked = apply(tuiLayout, cmdDock(paneEventLog, leBottom))
  doAssert docked.kind == loApplied
  let tuiText = pretty(saveLayout(docked.layout)) & "\n"
  writeFile(stateDir / TuiDocument, tuiText)
  createDir(configHome / "codetracer")
  let desktopText = "{\"root\": {\"type\": \"row\", \"content\": []}}\n"
  writeFile(configHome / "codetracer" / "default_layout.json", desktopText)
  (tuiText, desktopText)

suite "PLAT-45: the GPUI window and the shared default":

  test "the prerequisites are here":
    requirePrereq(fileExists(bin), bin & " (just build-gpui)")
    requirePrereq(dirExists(calc), calc & " (run 'just test-tui' once)")

  test "with nothing remembered the window opens the shared default, every pane placed":
    let state = createTempDir("plat45-gpui-state-", "")
    let config = createTempDir("plat45-gpui-config-", "")
    let run = runGpui(state, config)
    if run.rc != 0: checkpoint(run.err)
    ck run.rc == 0
    let got = centreArrangement(run.dock)
    let want = ofTree(sharedDefaultLayout().tree)
    checkpoint("gpui:   " & got.canonical)
    checkpoint("shared: " & want.canonical)
    ck got.problem.len == 0
    ck sameArrangement(got, want)
    # EVERY PANE OF THE SHARED DEFAULT IS IN THE PLAN — data or report.
    var drawn = initHashSet[string]()
    for (pane, path, st) in planLeaves(run.plan):
      drawn.incl pane
      ck path.startsWith("center/")
    ck drawn == sharedPaneNames()
    # THE CAPABILITY'S REPORT LEAVES: each undrawable pane is a report that
    # names itself, never an absent slot.
    let cap = gpuiCapability()
    let reports = reportLeaves(sharedDefaultLayout().tree, cap)
    # Four until PLAT-47 part B drew the VCS pane (from the desktop's VCSVM).
    ck reports.len == 3
    let text = planText(run.plan)
    for r in reports:
      var state = ""
      for (pane, path, st) in planLeaves(run.plan):
        if pane == $r.pane: state = st
      ck state == "pane-report"
      ck text.contains("the " & $r.pane & " pane is drawn by the desktop")
    # Nothing was written: no gesture, no document.
    ck not fileExists(state / GpuiDocument)
    removeDir(state)
    removeDir(config)

  test "rearranged, remembered in its OWN file, restored; the others' files never read":
    let state = createTempDir("plat45-gpui-state-", "")
    let config = createTempDir("plat45-gpui-config-", "")
    let (tuiText, desktopText) = otherProductsPlanted(state, config)
    # REARRANGE: the call-trace stack's second tab to the front, and the
    # Test Results pane merged into the Files stack.
    let first = runGpui(state, config,
      @["--layout-ops=activate:agentActivity,merge:testResults:fileTree"])
    if first.rc != 0: checkpoint(first.err)
    ck first.rc == 0
    # WRITTEN, and only this product's file.
    ck fileExists(state / GpuiDocument)
    let saved = restoreLayoutDocument(parseJson(readFile(state / GpuiDocument)))
    ck regionOf(saved.tree, paneTestResults) == regionOf(saved.tree, paneFileTree)
    ck readFile(state / TuiDocument) == tuiText
    ck readFile(config / "codetracer" / "default_layout.json") == desktopText
    # THE FIRST RUN ALREADY SHOWS IT…
    ck not sameArrangement(centreArrangement(first.dock),
                           ofTree(sharedDefaultLayout().tree))
    # …AND A RESTART RESTORES IT, with no flag.
    let second = runGpui(state, config)
    ck second.rc == 0
    let restored = centreArrangement(second.dock)
    ck sameArrangement(restored, ofTree(saved.tree))
    ck "stack[calltrace,agentActivity*]" in restored.groups
    # The terminal's planted docked Event Log did NOT reach this window: the
    # event log is in the centre, and there is no bottom dock at all.
    ck not second.dock.hasKey("bottom_dock")
    var eventLogPath = ""
    for (pane, path, st) in planLeaves(second.plan):
      if pane == "eventLog": eventLogPath = path
    ck eventLogPath.startsWith("center/")
    removeDir(state)
    removeDir(config)

  test "reset deletes ONLY this product's file and opens the shared default":
    let state = createTempDir("plat45-gpui-state-", "")
    let config = createTempDir("plat45-gpui-config-", "")
    let (tuiText, desktopText) = otherProductsPlanted(state, config)
    ck runGpui(state, config, @["--layout-ops=merge:vcs:editor"]).rc == 0
    ck fileExists(state / GpuiDocument)
    let reset = runGpui(state, config, @["--reset-layout"])
    ck reset.rc == 0
    ck not fileExists(state / GpuiDocument)
    ck sameArrangement(centreArrangement(reset.dock),
                       ofTree(sharedDefaultLayout().tree))
    ck readFile(state / TuiDocument) == tuiText
    ck readFile(config / "codetracer" / "default_layout.json") == desktopText
    # And the next start, with nothing remembered, is the default too.
    let after = runGpui(state, config)
    ck sameArrangement(centreArrangement(after.dock),
                       ofTree(sharedDefaultLayout().tree))
    removeDir(state)
    removeDir(config)

  test "a corrupt file is reported by kind, the window opens on the default, the file is left alone":
    let state = createTempDir("plat45-gpui-state-", "")
    let config = createTempDir("plat45-gpui-config-", "")
    for (bytes, kind) in [("{ not json", "NotJson"), ("", "EmptyDocument"),
                          ("{\"version\": 99, \"layout\": {}, \"docked\": []}",
                           "UnknownVersion")]:
      writeFile(state / GpuiDocument, bytes)
      let run = runGpui(state, config)
      checkpoint(kind & ": rc " & $run.rc & " " & run.err.strip())
      # THE LAUNCH DOES NOT FAIL…
      ck run.rc == 0
      # …THE USER IS TOLD, BY KIND…
      ck run.err.contains("saved layout ignored (" & kind & ")")
      # …THE WINDOW IS THE SHARED DEFAULT…
      ck sameArrangement(centreArrangement(run.dock),
                         ofTree(sharedDefaultLayout().tree))
      # …AND THE FILE IS BYTE FOR BYTE WHAT IT WAS, even after a gesture.
      ck readFile(state / GpuiDocument) == bytes
      let gestured = runGpui(state, config, @["--layout-ops=activate:vcs"])
      ck gestured.rc == 0
      ck readFile(state / GpuiDocument) == bytes
    removeDir(state)
    removeDir(config)

  test "the edit window opens the shared EDIT default":
    let state = createTempDir("plat45-gpui-state-", "")
    let config = createTempDir("plat45-gpui-config-", "")
    let run = runGpui(state, config, @["--edit"])
    if run.rc != 0: checkpoint(run.err)
    ck run.rc == 0
    ck sameArrangement(centreArrangement(run.dock),
                       ofTree(sharedEditLayout().tree))
    removeDir(state)
    removeDir(config)

echo "CHECKS: ", CHECKS
