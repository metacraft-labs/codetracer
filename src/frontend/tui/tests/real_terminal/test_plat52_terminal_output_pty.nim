## test_plat52_terminal_output_pty.nim — PLAT-52, the shipped
## `codetracer-tui` on a REAL pseudo-terminal (TermAssert: a real pty, the
## screen read back through libvterm), drawing the Terminal Output pane:
##
##   * `terminal_colours` — the pane's lines in the colours the program wrote
##     them in, read off the terminal's own cells (24-bit colour, bold), the
##     future muted; a click on a fragment moves the debugger to the tick its
##     write was produced at — the SAME tick the desktop lands on for the same
##     line (`answers/plat52-terminal.electron.json`, the real Electron app),
##     and after it every coloured fragment the desktop draws as past carries
##     the desktop's computed colour on the terminal too; a press at the end of
##     the scrollbar scrubber shows the output's last line and does not move
##     the debugger;
##   * `terminal_screen` — the pane shows the program's SCREEN; its built-in
##     scrubber is REAL-TIME: held and dragged, the top bar's tick moves while
##     the button is still down (the user, 2026-10-06); and at each tick the
##     desktop's scrubber was dragged to, the terminal's screen rows are the
##     desktop's rows.
##
## No mocks: the binary, the engine, the recordings and the desktop's
## measurements are real. State in a scratch directory.

import std/[json, math, monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 45

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  AnswersFile = "src/tests/visual/answers/plat52-terminal.electron.json"

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc spec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

proc open(name: string): TuiTestSession =
  let resolved = resolveFixture(spec(name))
  doAssert resolved.outcome == foRecorded, resolved.detail
  inc spawned
  let state = getTempDir() / ("plat52-pty-" & $getCurrentProcessId() & "-" &
                              $spawned)
  removeDir(state)
  createDir(state)
  result = newTuiTest(tuiBinary(), @["--theme=dark", resolved.tracePath])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .spawn()
  settleOnDebugger(result, Cols, Rows)

proc snap(sess: var TuiTestSession): Snapshot =
  discard sess.drainOutput(80)
  for r in 0 ..< Rows:
    var row: seq[Cell] = @[]
    for c in 0 ..< Cols:
      row.add sess.cellAt(r, c)
    result.add row

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add(if int(c.rune) == 0: " " else: $c.rune)

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc findRow(s: Snapshot; needle: string): (int, int) =
  for r in 0 ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc waitFor(sess: var TuiTestSession; needle: string;
             timeoutMs = 30000): (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let at = sess.snap().findRow(needle)
    if at[0] >= 0: return at
    sleep(40)
  raise newException(AssertionFailedError, "never showed '" & needle & "'")

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int) =
  sess.mouse(0, row, col)
  sess.mouse(0, row, col, release = true)

proc quit(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc fgHex(c: Cell): string =
  if c.fg.kind == ckRgb: hexOf((c.fg.r.int, c.fg.g.int, c.fg.b.int)) else: ""

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

proc composite(colour, ground: string; opacity: float): string =
  ## `colour` at `opacity` over `ground`, as a browser composites it — the
  ## desktop's `.future`. An independent statement of the rule, not the
  ## product's blend.
  if colour.len != 7 or ground.len != 7:
    return "?"
  let a = parseHexColour(colour)
  let b = parseHexColour(ground)
  proc ch(x, y: int): int = int(round(float(x) * opacity + float(y) * (1.0 - opacity)))
  hexOf((ch(a.r, b.r), ch(a.g, b.g), ch(a.b, b.b)))

proc tick(sess: var TuiTestSession): int =
  ## The debugger's tick, as the top bar says it (`tick: 1,168 / …`).
  let line = sess.snap().text(0)
  let at = line.find("tick: ")
  if at < 0:
    return -1
  var digits = ""
  for c in line[at + "tick: ".len .. ^1]:
    if c in {'0' .. '9'}: digits.add c
    elif c == ',': discard
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc waitTickChange(sess: var TuiTestSession; from0: int;
                    timeoutMs = 60000): int =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let t = sess.tick()
    if t >= 0 and t != from0: return t
    sleep(40)
  sess.tick()

proc showTerminalOutput(sess: var TuiTestSession) =
  ## Press the pane's tab where its strip draws it.
  let s = sess.snap()
  for r in 0 ..< Rows:
    let t = s.text(r)
    if t.contains(" Event Log ") and t.contains(" Terminal Output "):
      sess.press(r, t.cellFind(" Terminal Output ") + 2)
      return
  raise newException(AssertionFailedError, "no Terminal Output tab drawn")

proc paneArea(s: Snapshot): tuple[top, left, right, bottom: int] =
  ## The pane's rows and columns: below its strip, to the divider or edge.
  for r in 0 ..< Rows:
    let t = s.text(r)
    let c = t.cellFind(" Event Log ")
    if c >= 0 and t.contains(" Terminal Output "):
      var right = Cols - 1
      return (r + 1, max(0, c - 1), right, Rows - 2)
  (-1, -1, -1, -1)

let answers =
  if fileExists(AnswersFile): parseJson(readFile(AnswersFile))
  else: newJObject()

suite "PLAT-52: the Terminal Output pane on a real terminal — lines":

  test "the desktop's colours, a click landing at the desktop's tick":
    var sess = open("terminal_colours")
    defer: sess.quit()
    sess.showTerminalOutput()
    var (row, col) = sess.waitFor("red plain bold green")
    # At the program's entry every line is still to come: each fragment in
    # ITS colour at the desktop's opacity over the cell's ground — the
    # desktop's `.future` composited, measured against its capture.
    var s = sess.snap()
    ck s[row][col].fgHex != "#bb0000"
    require answers.hasKey("lines")
    let startLine = answers["lines"]["linesAtStart"][0]
    var fc = col
    var futureCompared = 0
    for f in startLine["fragments"]:
      let t = f["text"].getStr
      if t.len == 0: continue
      let cell = s[row][fc]
      let op = parseFloat(f["opacity"].getStr)
      let expected = composite(f["color"].getStr, cell.bgHex, op)
      checkpoint("future '" & t & "': terminal " & cell.fgHex & " on " &
                 cell.bgHex & ", desktop " & f["color"].getStr & " @" & $op &
                 " -> " & expected)
      ck f["tense"].getStr == "future"
      ck cell.fgHex == expected
      inc futureCompared
      fc += t.runeLen
    ck futureCompared == 3
    # K32: press the fragment of the line "row   2".
    let (r2, c2) = sess.waitFor("row   2 ")
    let before = sess.tick()
    sess.press(r2, c2 + 1)
    let after = sess.waitTickChange(before)
    checkpoint("tick " & $before & " -> " & $after)
    ck after != before
    ck after > 0
    # The desktop lands at the same tick for the same line.
    require answers.hasKey("lines")
    let desk = answers["lines"]
    ck desk["click"]["line"].getInt == 10
    ck desk["click"]["after"]["ticks"].getInt == after
    # The past is drawn as written — in the desktop's computed colours.
    sleep(300)
    s = sess.snap()
    (row, col) = s.findRow("red plain bold green")
    ck row >= 0
    let deskLines = desk["linesAfterClick"]
    var compared = 0
    for li in 0 .. 3:
      let line = deskLines[li]
      let at = s.findRow(line["text"].getStr)
      if at[0] < 0:
        checkpoint("line " & $li & " not on screen: " & line["text"].getStr)
        continue
      var c = at[1]
      for f in line["fragments"]:
        let t = f["text"].getStr
        if t.len == 0: continue
        let cell = s[at[0]][c]
        let deskColour = f["color"].getStr
        let deskGround = f["background"].getStr
        let coloured = deskColour notin ["", "#f3f3f3", "#ffffff"] and
                       f["tense"].getStr == "past"
        if coloured:
          if cell.fgHex != deskColour:
            checkpoint("line " & $li & " '" & t & "': terminal " &
                       cell.fgHex & ", desktop " & deskColour)
          ck cell.fgHex == deskColour
          inc compared
        if deskGround.len > 0 and deskGround != "transparent" and
           f["tense"].getStr == "past":
          ck cell.bgHex == deskGround
          inc compared
        if f["weight"].getStr == "700":
          ck caBold in cell.attrs
        c += t.runeLen
    checkpoint("fragments compared: " & $compared)
    ck compared >= 6
    # The line after the active one is still to come on both front-ends.
    let deskFuture = deskLines[11]["fragments"][0]["tense"].getStr
    ck deskFuture == "future"

  test "the scrollbar scrubs the whole output and leaves the debugger":
    var sess = open("terminal_colours")
    defer: sess.quit()
    sess.showTerminalOutput()
    discard sess.waitFor("red plain bold green")
    let s = sess.snap()
    let area = s.paneArea()
    ck area.top > 0
    let tick0 = sess.tick()
    # The track is the pane's rightmost column; press its last cell.
    sess.press(area.bottom - 1, area.right)
    discard sess.waitFor("done")
    ck sess.snap().findRow("row 119 ")[0] >= 0
    ck sess.tick() == tick0

suite "PLAT-52: the Terminal Output pane on a real terminal — the screen":

  test "the screen's scrubber is REAL-TIME, and the screen is the desktop's":
    var sess = open("terminal_screen")
    defer: sess.quit()
    sess.showTerminalOutput()
    discard sess.waitFor(" Screen ")
    let s = sess.snap()
    # The scrubber's track is the pane's second-to-last row.
    let area = s.paneArea()
    let trackRow = area.bottom - 1
    let t0 = sess.tick()
    sess.mouse(0, trackRow, area.left + 2)
    let t1 = sess.waitTickChange(t0)
    # Dragged, the button still down: the debugger follows the pointer.
    sess.mouse(32, trackRow, area.left + (area.right - area.left) div 2)
    let t2 = sess.waitTickChange(t1)
    checkpoint("ticks " & $t0 & " -> " & $t1 & " -> " & $t2 & " (held)")
    ck t1 != t0
    ck t2 > t1
    sess.mouse(0, trackRow, area.left + (area.right - area.left) div 2,
               release = true)
    sleep(300)
    ck sess.tick() == t2
    discard sess.waitFor("dashboard")
    # At each tick the desktop's scrubber was dragged to, the same screen.
    require answers.hasKey("screen")
    var compared = 0
    for step in answers["screen"]["drag"]:
      let target = step["ticks"].getInt
      # `:goto <tick>` — the command line's seek.
      sess.send(":")
      sleep(100)
      sess.send("goto " & $target)
      sleep(100)
      sess.send("\r")
      let deadline = getMonoTime() + initDuration(milliseconds = 60000)
      while sess.tick() != target and getMonoTime() < deadline:
        sleep(40)
      ck sess.tick() == target
      sleep(300)
      let now = sess.snap()
      let a = now.paneArea()
      # The screen's first column: where its top row's frame corner is drawn.
      let (cornerRow, left) = now.findRow("┌─ dashboard")
      ck cornerRow == a.top + 1
      var agree = 0
      var rowsChecked = 0
      var r = a.top + 1        # under the toggle row
      for deskRow in step["rows"]:
        if r >= a.bottom - 1: break
        let want = deskRow.getStr.strip(leading = false)
        let got = now.text(r).runeSubStr(left, a.right - left + 1)
        let wantClip = want.runeSubStr(0, min(want.runeLen, a.right - left + 1))
        if got.strip(leading = false) == wantClip.strip(leading = false):
          inc agree
        else:
          checkpoint("tick " & $target & " row " & $(r - a.top - 1) &
                     ": terminal '" & got.strip(leading = false) &
                     "' desktop '" & wantClip & "'")
        inc rowsChecked
        inc r
      ck rowsChecked > 10
      ck agree == rowsChecked
      inc compared
    ck compared == 3

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
