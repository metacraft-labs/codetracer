## plat68_one_keymap_probe.nim — ONE `keybindings.json`, the terminal's and
## GPUI's halves of "one configuration, three front-ends"
## (Base-Keymaps-And-Layer-Stack.md §3.5; driven by
## `ci/test/plat68-one-keymap-three-front-ends.sh`, which runs the desktop's
## half — `src/tests/gui/tests/keymaps/plat68c-shared-keybindings.spec.ts` —
## over the SAME file in the same run and compares the three answers).
##
## The file (`PLAT68_SHARED_KEYBINDINGS`) carries a PANE-SCOPED row — Step
## Over on `Ctrl+Alt+J` only while a list pane has the focus (`when:
## listFocus`) — and a `-command` removal of the base's `F10` → Step Over.
## Each front-end, on the `calc` recording from its start:
##
##   1. reads the execution line (`start`);
##   2. presses `Ctrl+Alt+J` with the editor focused — outside the row's
##      scope: the debugger stays (`afterOutside`);
##   3. focuses the call trace with a pointer press on its tab, and presses
##      `F10` — removed: the debugger stays (`afterRemoved`);
##   4. presses `Ctrl+Alt+J` — the user's row, in its scope: one step
##      (`afterRebound`).
##
## Each answer is one JSON line appended to `PLAT68_SHARED_RESULTS`. This
## probe asserts its own two front-ends agree; the script asserts all three.
##
## The terminal is the shipped binary on a real pty (TermAssert / libvterm),
## its keys the bytes a terminal sends (`Ctrl+Alt+J` in the `modifyOtherKeys`
## form the binary negotiates on an `xterm-256color` TERM); GPUI is the
## shipped binary's window plan (`--window-ops`, its own key handlers). No
## mocks: real binaries, a real engine, the real recording, one real file.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unicode]

import term_assert
import nim_libvterm

import ../../src/frontend/tui/tests/fixtures/fixture_provider
import ../../src/frontend/tui/tests/real_terminal/lifecycle_support

const
  Cols = 200
  Rows = 50
  SharedRows* = """// one keymap for every front-end
[
  { "key": "ctrl+alt+j", "command": "debugger.step-over", "when": "listFocus" },
  { "key": "f10", "command": "-debugger.step-over" },
]
"""

var failures = 0

proc expect(cond: bool; what: string) =
  if cond: echo "ok   ", what
  else:
    echo "FAIL ", what
    inc failures

let shared = block:
  let named = getEnv("PLAT68_SHARED_KEYBINDINGS", "")
  if named.len > 0: named
  else:
    let d = createTempDir("plat68-one-keymap-", "")
    writeFile(d / "keybindings.json", SharedRows)
    d / "keybindings.json"
let results = getEnv("PLAT68_SHARED_RESULTS", shared.parentDir / "results.jsonl")

proc answer(frontEnd: string;
            start, afterOutside, afterRemoved, afterRebound: int): JsonNode =
  %*{"frontEnd": frontEnd, "start": start, "afterOutside": afterOutside,
     "afterRemoved": afterRemoved, "afterRebound": afterRebound}

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

proc terminalAnswer(calc: string): JsonNode =
  let state = createTempDir("plat68-one-keymap-tui-", "")
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
  # A pointer press on the source's text: the editor has the focus, as on the
  # other two front-ends (the terminal starts with a list pane focused).
  var srcRow, srcCol = -1
  for r in 0 ..< Rows:
    let c = sess.text(r).find("#!/usr/bin/env python3")
    if c >= 0:
      srcRow = r
      srcCol = sess.text(r)[0 ..< c].runeLen + 3
      break
  doAssert srcRow >= 0, "calc's first line is not on the screen"
  sess.send("\e[<0;" & $(srcCol + 1) & ";" & $(srcRow + 1) & "M")
  sess.send("\e[<0;" & $(srcCol + 1) & ";" & $(srcRow + 1) & "m")
  sleep(500)
  sess.send(CtrlAltJ)               # the editor has the focus: out of scope
  let afterOutside = sess.settled
  # `Alt+C` (CUA's `layout.focus-pane(call-trace)`) focuses the call trace.
  # (A press on its tab label activates the tab but leaves the focus where it
  # was on this front-end; GPUI's window, the other way round, takes the
  # focus from the press and not from `Alt+C`. How each front-end MOVES the
  # focus is not what this probe compares — the keys after it are.)
  sess.send("\e[27;3;99~")   # Alt+C, unambiguous (no ESC-prefix timing)
  sleep(500)
  if existsEnv("PLAT68_PROBE_DEBUG"):
    echo "after the press: line ", sess.settled, " status ", sess.text(Rows - 1)
  sess.send("\e[21~")              # F10: removed
  let afterRemoved = sess.settled
  sess.send(CtrlAltJ)               # the user's row, in its scope
  let afterRebound = sess.settled
  if existsEnv("PLAT68_PROBE_DEBUG"):
    echo "status after: ", sess.text(Rows - 1)
  sess.send("\x11")         # Ctrl+Q
  discard sess.waitExit(initDuration(seconds = 15))
  sess.terminate()
  sess.close()
  removeDir(state)
  answer("terminal", start, afterOutside, afterRemoved, afterRebound)

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

proc gpuiLine(calc, ops: string): int =
  if not fileExists(gpuiBin):
    raise newException(IOError, "prerequisite missing: " & gpuiBin &
                       " (just build-gpui)")
  let state = createTempDir("plat68-one-keymap-gpui-", "")
  defer: removeDir(state)
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
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
  executionLine(parseJson(output))

proc gpuiAnswer(calc: string): JsonNode =
  const
    Outside = "wait:1000,key:j:control+alt,wait:1500"
    Removed = Outside & ",click:tab:calltrace,wait:500,key:f10,wait:1500"
  answer("gpui", gpuiLine(calc, "wait:1500"), gpuiLine(calc, Outside),
         gpuiLine(calc, Removed),
         gpuiLine(calc, Removed & ",key:j:control+alt,wait:1500"))

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
  expect(a["afterOutside"].getInt == a["start"].getInt,
         fe & ": Ctrl+Alt+J outside a list pane (when: listFocus) steps nothing")
  expect(a["afterRemoved"].getInt == a["start"].getInt,
         fe & ": F10, removed by the user, steps nothing")
  expect(a["afterRebound"].getInt != a["start"].getInt,
         fe & ": Ctrl+Alt+J in the call trace, the user's row, steps")
for k in ["start", "afterOutside", "afterRemoved", "afterRebound"]:
  expect(t[k] == g[k], "terminal and GPUI agree on " & k)
echo "CHECKS: ", 12
quit(if failures == 0: 0 else: 1)
