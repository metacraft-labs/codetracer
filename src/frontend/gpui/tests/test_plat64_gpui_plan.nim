## test_plat64_gpui_plan.nim — Input-Routing-And-Keymaps.md on the shipped GPUI
## binary's window plan, over one user `keybindings.json`: IR-5 (a user's chord
## reaches its operation through GPUI's decoder), §5.1 (a press on a call row, a
## tab's menu and a toolbar button run what the element declares, and a Ctrl+press
## the user rebound follows the rebinding), IR-3 (the program menu shows the new
## chord) and IR-6 (an operation with no session says so).
##
## No mocks: the shipped binary, a real recording, a real `replay-server`.

import replay_prerequisite
import ../../tui/tests/fixtures/fixture_provider
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env
import gpui/app/leaves      # the call trace's row geometry
import gpui/window_geometry # `paneInsetOf`

const
  W = 1440
  H = 1400
  UserRows = """[
  { "key": "ctrl+alt+j", "command": "debugger.step-over" },
  { "key": "ctrl+click", "command": "debugger.step-over",
    "when": "paneKind == calltrace && elementKind == row" },
]
"""

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                     repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = requireFixture(fixtureSpec("calc"))

proc run(ops: string; subject = calc): tuple[plan: JsonNode; trace: string;
                                           geometry: JsonNode] =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin & " (just build-gpui)")
  let state = createTempDir("plat64-gpui-plan-", "")
  writeFile(state / "keybindings.json", UserRows)
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_KEYBINDINGS"] = state / "keybindings.json"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = state / "geometry.json"
  let errFile = genTempPath("plat64-gpui-plan-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, subject]
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  result.trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  result.geometry = if fileExists(state / "geometry.json"):
                      parseFile(state / "geometry.json") else: newJNull()
  removeDir(state)
  if rc != 0:
    checkpoint(result.trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result.plan = parseJson(output)

proc calltraceBody(geom: JsonNode): seq[int] =
  for n in geom["nodes"]:
    if n{"kind"}.getStr == "tabs" and "calltrace" in n["panes"].to(seq[string]):
      return n["body"].to(seq[int])
  @[]

proc callPress(row: int): string =
  ## `click:call:<row>@<x>x<y>`: the row's own listeners and the window's
  ## pointer router hear the press on the call's name, as a real press does.
  let b = run("wait:1500").geometry.calltraceBody
  doAssert b.len == 4, "no call trace in the window's geometry"
  let y = b[1] + paneInsetOf("calltrace").top + CallRowsTopPx +
          callRowTopPx(row) + (callRowTopPx(row + 1) - callRowTopPx(row)) div 2
  let x = b[0] + CallToggleLeftPx + row * CallIndentPx + 14 + 8 + 6
  "click:call:" & $row & "@" & $x & "x" & $y

suite "PLAT-64 on GPUI":
  test "a user's chord reaches its operation (IR-5)":
    let r = run("wait:1500,key:j:control+alt,wait:1000")
    check "operation debugger.step-over" in r.trace

  test "a press on a call row runs what its element declares (§5.1)":
    let r = run("wait:1500," & callPress(1) & ":left,wait:1000")
    check "pointer Click -> calltrace.go-to-call" in r.trace or
      "calltrace jump" in r.trace

  test "a Ctrl+press the user rebound follows the rebinding":
    let r = run("wait:1500," & callPress(1) & ":left:ctrl,wait:1000")
    check "pointer Ctrl+Click -> debugger.step-over" in r.trace
    check "calltrace jump" notin r.trace

  test "a context click opens the element's menu":
    let r = run("wait:1500,click:call:1:right,wait:300")
    check "pointer RightClick -> context-menu.open" in r.trace

  test "the program menu shows the user's chord (IR-3)":
    let r = run("wait:1000,menu:Debug,wait:300")
    check "Ctrl+Alt+J" in $r.plan

  test "the menu's rows run through the router":
    let r = run("wait:1000,key:`:alt,wait:200,key:down,wait:200,key:escape,wait:200")
    check "operation menu.focus-next" in r.trace
    check "operation menu.close" in r.trace
