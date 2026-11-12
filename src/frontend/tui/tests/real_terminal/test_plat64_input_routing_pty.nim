## Ported to the scenario
## src/tests/scenarios/terminal/input-routing-user-chords.yaml; kept as the
## subject of its mutation harness (run-plat64-input-routing-mutations.py);
## named by src/frontend/tui/tests/real_terminal/test_plat50_clicks.nim.
##
## test_plat64_input_routing_pty.nim — Input-Routing-And-Keymaps.md on the shipped
## terminal binary, over a real pty and one user `keybindings.json`: IR-5 (a user's
## chord reaches its operation through this front-end's decoder), §5.1 (a press on
## a call row runs what its element declares, and a Ctrl+press the user rebound
## follows the rebinding) and IR-3 (the shortcut reference shows the new chord).
##
## The chord and the presses are written as the bytes a terminal sends.
##
## No mocks: a real pty, the shipped binary, a real recording and replay-server.

import std/[os, posix, strutils, tempfiles, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support

const
  ExpectedAssertions = 9
  Cols = 200
  Rows = 50
  UserRows = """[
  { "key": "ctrl+alt+j", "command": "debugger.step-over" },
  { "key": "ctrl+click", "command": "debugger.continue",
    "when": "paneKind == calltrace && elementKind == row" },
]
"""
  CtrlAltJ = "\e[27;7;106~"

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc text(sess: var TuiTestSession; r: int): string =
  for c in 0 ..< Cols:
    let cell = sess.cellAt(r, c)
    result.add(if int(cell.rune) == 0: " " else: $cell.rune)

proc pointerLine(sess: var TuiTestSession): int =
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

proc callRow(sess: var TuiTestSession; head: string; args = ""): (int, int) =
  ## The call-trace row that starts with `head` and lists `args`, found by what
  ## the call is (`test_plat50_clicks.waitForCall`'s reading).
  discard sess.drainOutput(80)
  for r in 0 ..< Rows:
    let t = sess.text(r)
    let h = t.find(head)
    if h >= 0 and (args.len == 0 or t.find(args) > h): return (r, t[0 ..< h].runeLen)
  (-1, -1)

proc atRecordingEnd(sess: var TuiTestSession): bool =
  ## The top bar reads `tick: N / N`: the debugger is at the recording's end.
  discard sess.drainOutput(200)
  for r in 0 ..< 2:
    let t = sess.text(r)
    let at = t.find("tick: ")
    if at >= 0:
      let parts = t[at + 6 .. ^1].split(' ')
      if parts.len >= 3 and parts[1] == "/" and parts[0] == parts[2]:
        return true
  false

proc screenHas(sess: var TuiTestSession; needle: string): bool =
  ## Whether `needle` is drawn, waiting up to ten seconds for the frame.
  for _ in 0 ..< 50:
    discard sess.drainOutput(200)
    for r in 0 ..< Rows:
      if needle in sess.text(r): return true
    sleep(200)
  false

suite "PLAT-64 on a real terminal":
  test "a user's chord, an element's press and a rebound Ctrl+press":
    let calc = requireFixture(fixtureSpec("calc"))
    let state = createTempDir("plat64-input-routing-", "")
    writeFile(state / "keybindings.json", UserRows)
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", calc])
      .width(Cols).height(Rows)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("XDG_STATE_HOME", state)
      .envSet("XDG_CONFIG_HOME", state / "config")
      .envSet("CODETRACER_HOME", state / "ct-home")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
      .envSet("CODETRACER_KEYBINDINGS", state / "keybindings.json")
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    let start = sess.settled
    ck start > 0
    sess.send(CtrlAltJ)
    let afterChord = sess.settled
    ck afterChord != start
    let (r0, c0) = sess.callRow("add #")
    ck r0 >= 0
    sess.press(r0, c0 + 2, ctrl = true)
    let afterCtrl = sess.settled
    # The user's row is Continue (no breakpoint: to the end); the press did not go to the call.
    ck sess.atRecordingEnd
    # The user's row stepped: not `add`'s body, where the plain press goes.
    ck afterCtrl != afterChord
    # The plain press on `sub` (10 - 4), elsewhere than where the debugger is
    # now (inside the first `add`): the element's own operation goes there.
    let (r1, c1) = sess.callRow("sub #", "(left=10, right=4)")
    sess.press(r1, c1 + 2)
    let afterPress = sess.settled
    ck r1 >= 0
    if afterPress == afterCtrl:
      for r in 0 ..< Rows: checkpoint(sess.text(r))
    ck afterPress != afterCtrl
    sess.send(":keys reference\r")
    sleep(1500)
    # The reference names the row as the user wrote it.
    let shown = sess.screenHas("ctrl+alt+j  debugger.step-over")
    if not shown:
      for r in 0 ..< Rows: checkpoint(sess.text(r))
    ck shown
    sess.send("\e")
    sleep(300)
    sess.send("\x11")
    discard sess.waitExit(initDuration(seconds = 15))
    sess.terminate()
    sess.close()
    removeDir(state)
    inc countedAssertions
    check countedAssertions == ExpectedAssertions
