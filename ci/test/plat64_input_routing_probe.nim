## plat64_input_routing_probe.nim — Input-Routing-And-Keymaps.md IR-3, IR-5 and
## §5.1 on the terminal (a real pty, the shipped binary) and GPUI (the window
## plan, the shipped binary), over ONE `keybindings.json`:
##
##   * a user's chord for a debugger operation reaches it, through each front-end's
##     own decoder (IR-5);
##   * a press on a call-trace row runs the operation its element declares, and a
##     Ctrl+press the user rebound follows the rebinding (§5.1);
##   * every surface that displays the operation's chord shows the new one (IR-3).
##
## Its answers go to `$PLAT64_SHARED_RESULTS`, where
## `plat64-input-routing-three-front-ends.sh` compares them with the desktop's.
##
## No mocks: real recordings, real replay-server, the shipped binaries. The chord
## is written as the modifyOtherKeys bytes the binary asks a terminal for.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, times, unicode]

import term_assert
import nim_libvterm

import ../../src/frontend/gpui/tests/gpui_child_env # the shim's runtime libraries
import ../../src/frontend/gpui/app/leaves          # the call trace's row geometry
import ../../src/frontend/gpui/window_geometry     # `paneInsetOf`

import ../../src/frontend/tui/tests/fixtures/fixture_provider
import ../../src/frontend/tui/tests/real_terminal/lifecycle_support

const
  Cols = 200
  Rows = 50
  SharedRows* = """// one keymap for every front-end
[
  { "key": "ctrl+alt+j", "command": "debugger.step-over" },
  { "key": "ctrl+click", "command": "debugger.continue",
    "when": "paneKind == calltrace && elementKind == row" },
]
"""

var failures = 0

proc expect(cond: bool; what: string) =
  if cond: echo "ok   ", what
  else:
    echo "FAIL ", what
    inc failures

let shared = block:
  let named = getEnv("PLAT64_SHARED_KEYBINDINGS", "")
  if named.len > 0: named
  else:
    let d = createTempDir("plat64-input-routing-", "")
    writeFile(d / "keybindings.json", SharedRows)
    d / "keybindings.json"
let results = getEnv("PLAT64_SHARED_RESULTS", shared.parentDir / "results.jsonl")

proc answer(frontEnd: string;
            start, afterChord, afterCtrlPress, afterPress: int;
            shown: bool): JsonNode =
  %*{"frontEnd": frontEnd, "start": start, "afterChord": afterChord,
     "afterCtrlPress": afterCtrlPress, "afterPress": afterPress,
     "chordShown": shown}

proc record(a: JsonNode) =
  let f = open(results, fmAppend)
  f.writeLine($a)
  f.close()
  echo "answer ", $a

# --- the terminal --------------------------------------------------------

proc text(sess: var TuiTestSession; r: int): string =
  for c in 0 ..< Cols:
    let cell = sess.cellAt(r, c)
    result.add(if int(cell.rune) == 0: " " else: $cell.rune)

proc pointerLine(sess: var TuiTestSession): int =
  ## The source line the execution pointer ` ▸ ` is on, or -1
  ## (`test_plat50_clicks.pointerLine`'s reading).
  discard sess.drainOutput(80)
  for r in 2 ..< Rows - 1:
    let t = sess.text(r)
    let at = t.find(" ▸ ")
    if at > 0:
      let runes = t[0 ..< at].toRunes
      var i = runes.high
      var digits = ""
      while i >= 0 and runes[i] == Rune(' '): dec i
      while i >= 0 and ($runes[i])[0].isDigit:
        digits = $runes[i] & digits
        dec i
      if digits.len > 0: return parseInt(digits)
  -1

proc settled(sess: var TuiTestSession): int =
  ## The pointer's line once it has not moved for three seconds (a step's
  ## answer can take seconds on a loaded host; a shorter window read the
  ## line before a step landed).
  var last = sess.pointerLine
  var stable = 0
  for _ in 0 ..< 90:
    sleep(1000)
    let now = sess.pointerLine
    if now == last and now > 0:
      inc stable
      if stable >= 3: return now
    else:
      stable = 0
    last = now
  last

proc press(sess: var TuiTestSession; row, col: int; ctrl = false) =
  let code = if ctrl: 16 else: 0
  sess.send("\e[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\e[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) & "m")

proc callRow(sess: var TuiTestSession; head: string): (int, int) =
  discard sess.drainOutput(80)
  for r in 0 ..< Rows:
    let t = sess.text(r)
    let h = t.find(head)
    if h >= 0: return (r, t[0 ..< h].runeLen)
  (-1, -1)

proc screenHas(sess: var TuiTestSession; needle: string): bool =
  ## Whether `needle` is drawn, waiting up to ten seconds for the frame.
  for _ in 0 ..< 50:
    discard sess.drainOutput(200)
    for r in 0 ..< Rows:
      if needle in sess.text(r): return true
    sleep(200)
  false

proc terminalAnswer(calc: string): JsonNode =
  let state = createTempDir("plat64-input-routing-tui-", "")
  var sess = newTuiTest(tuiBinary(), @["--theme=dark", calc])
    .width(Cols).height(Rows)
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .envSet("CODETRACER_KEYBINDINGS", shared)
    .spawn()
  settleOnDebugger(sess, Cols, Rows)
  let start = sess.settled
  const CtrlAltJ = "\e[27;7;106~"  # the modifyOtherKeys form the binary asks for
  sess.send(CtrlAltJ)
  let afterChord = sess.settled
  # Ctrl+press on a call: the user's row steps instead of going to the call.
  let (r0, c0) = sess.callRow("add #")
  doAssert r0 >= 0, "calc's `add` call is not on the screen"
  sess.press(r0, c0 + 2, ctrl = true)
  let afterCtrlPress = sess.settled
  # The plain press is the element's own: it goes to that call.
  let (r1, c1) = sess.callRow("sub #")
  sess.press(r1, c1 + 2)
  let afterPress = sess.settled
  # IR-3: the shortcut reference shows the user's chord for Step Over.
  sess.send(":keys reference\r")
  sleep(1500)
  let shown = sess.screenHas("ctrl+alt+j  debugger.step-over")
  if existsEnv("PLAT64_PROBE_DEBUG"):
    for r in 0 ..< Rows: echo sess.text(r)
  sess.send("\e")
  sleep(300)
  sess.send("\x11")         # Ctrl+Q
  discard sess.waitExit(initDuration(seconds = 15))
  sess.terminate()
  sess.close()
  removeDir(state)
  answer("terminal", start, afterChord, afterCtrlPress, afterPress, shown)

# --- GPUI ------------------------------------------------------------------

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let gpuiBin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                     repo.parentDir / "isonim-gpui/rust/target/debug")

proc executionLine(n: JsonNode): int =
  if n.kind != JObject: return -1
  let a = n{"attributes"}
  if a.kind == JObject and a{"data-ct-pointer"}.getStr == "eptExecution":
    return parseInt(a{"data-ct-row"}.getStr)
  for c in n{"children"}.getElems:
    let l = executionLine(c)
    if l >= 0: return l
  -1

proc gpuiPlan(calc, ops: string): JsonNode =
  if not fileExists(gpuiBin):
    raise newException(IOError, "prerequisite missing: " & gpuiBin &
                       " (just build-gpui)")
  let state = createTempDir("plat64-input-routing-gpui-", "")
  defer: removeDir(state)
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_KEYBINDINGS"] = shared
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 180 \"$0\" \"$@\" 2>/dev/null", gpuiBin,
             "--report-window-plan", "--width=1440", "--height=1400",
             "--window-ops=" & ops, calc],
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  if rc != 0:
    raise newException(IOError, "the GPUI window plan failed (" & ops & ")")
  parseJson(output)

proc gpuiGeometry(calc: string): tuple[x, y: int] =
  ## Where call row 1's name is drawn, from the geometry the window writes.
  let state = createTempDir("plat64-input-routing-geom-", "")
  defer: removeDir(state)
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = state / "geometry.json"
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 180 \"$0\" \"$@\" >/dev/null 2>&1", gpuiBin,
             "--report-window-plan", "--width=1440", "--height=1400",
             "--window-ops=wait:1500", calc], env = env, options = {})
  discard p.waitForExit()
  p.close()
  let geom = parseFile(state / "geometry.json")
  for n in geom["nodes"]:
    if n{"kind"}.getStr == "tabs" and "calltrace" in n["panes"].to(seq[string]):
      let b = n["body"].to(seq[int])
      let y = b[1] + paneInsetOf("calltrace").top + CallRowsTopPx +
              callRowTopPx(1) + (callRowTopPx(2) - callRowTopPx(1)) div 2
      return (b[0] + CallToggleLeftPx + CallIndentPx + 14 + 8 + 6, y)
  raise newException(IOError, "no call trace in the window's geometry")

proc gpuiLine(calc, ops: string): int =
  executionLine(gpuiPlan(calc, ops))

proc gpuiAnswer(calc: string): JsonNode =
  const
    Chord = "wait:1500,key:j:control+alt,wait:1500"
    Menu = "wait:1000,menu:Debug,wait:300"
  # A real press on call row 1's name (`click:call:<row>@<x>x<y>`), so the row's
  # listeners and the window's pointer router both hear it.
  let geom = gpuiGeometry(calc)
  let press = "click:call:1@" & $geom.x & "x" & $geom.y
  let CtrlPress = Chord & "," & press & ":left:ctrl,wait:1500"
  let Plain = CtrlPress & "," & press & ":left,wait:1500"
  let shown = "Ctrl+Alt+J" in $gpuiPlan(calc, Menu)
  answer("gpui", gpuiLine(calc, "wait:1500"), gpuiLine(calc, Chord),
         gpuiLine(calc, CtrlPress), gpuiLine(calc, Plain), shown)

# --- the run ---------------------------------------------------------------

let resolved = resolveFixture("calc")
doAssert resolved.outcome == foRecorded, resolved.detail
echo "keybindings.json: ", shared
let t = terminalAnswer(resolved.tracePath)
record(t)
let g = gpuiAnswer(resolved.tracePath)
record(g)
for a in [t, g]:
  let fe = a["frontEnd"].getStr
  expect(a["start"].getInt > 0, fe & ": the execution line is read")
  expect(a["afterChord"].getInt != a["start"].getInt,
         fe & ": the user's Ctrl+Alt+J steps")
  expect(a["afterCtrlPress"].getInt != a["afterChord"].getInt,
         fe & ": a Ctrl+press on a call row follows the user's rebinding")
  expect(a["chordShown"].getBool, fe & ": the surface shows the user's chord")
for k in ["start", "afterChord"]:
  expect(t[k] == g[k], "terminal and GPUI agree on " & k)
quit(if failures == 0: 0 else: 1)
