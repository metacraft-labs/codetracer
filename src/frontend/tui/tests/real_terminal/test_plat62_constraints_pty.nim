## test_plat62_constraints_pty.nim — PLAT-62, Tier 2. **The Constraints pane
## on a real terminal, measured against the desktop.**
##
## Spec: `Planned-Features/Noir-Studio.md` § "The Constraints pane on the
## terminal and the GPUI window (PLAT-62)".
##
## The shipped `codetracer-tui`, driven as a user drives it — exact SGR mouse
## bytes on the cells the pane was drawn in, the omnibox typed — and read back
## off the screen through libvterm. The reference is the REAL Electron app's
## pane over the same crate (`src/tests/visual/answers/
## plat62-constraints.electron.json`, `just plat62-capture-electron`):
##
##   * EDIT MODE over the PLAT-62 crate (`--edit`): the pane the Edit default
##     places, measured by the real `nargo info --json`; the headline, and per
##     row the name, the count and where the function is declared, equal to
##     the desktop's, in its order; a press on `halve` opens its declaring line
##     in the editor; a right press opens the desktop's menu; a press on a
##     directive says why nothing opens;
##   * ITS RECORDING: the terminal started on a recording in the crate's
##     directory, the crate's test recorded and opened in a new session tab
##     from Test Results (the real `ct record-test`); there, where the Debug
##     default places no Constraints pane, `:constraints` opens it with the
##     desktop's rows, and a press on `main` opens its line from the
##     recording.
##
## No mocks: the real binary, the real `nargo`, `ct`, `ct-test` and
## `replay-server` on a real crate, a real pty (TermAssert + libvterm), the
## real Electron app's answers.

import std/[json, monotimes, os, strutils, tempfiles, times, unittest]
from std/unicode import runeLen, Rune, `$`

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ../fixtures/plat62_noir_circuit
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 12

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  AnswersFile = "src/tests/visual/answers/plat62-constraints.electron.json"
  MeasureBudgetMs = 120_000
  RecordBudgetMs = 300_000

type Snapshot = seq[seq[Cell]]

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

proc screenText(s: Snapshot): string =
  for r in 0 ..< Rows:
    result.add s.text(r) & "\n"

proc waitFor(sess: var TuiTestSession; needle: string;
             timeoutMs = 60000): (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last: Snapshot
  while getMonoTime() < deadline:
    last = sess.snap()
    let at = last.findRow(needle)
    if at[0] >= 0: return at
    sleep(50)
  raise newException(AssertionFailedError, "never showed '" & needle &
                     "'; screen:\n" & last.screenText())

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int; button = 0) =
  sess.mouse(button, row, col)
  sess.mouse(button, row, col, release = true)

proc omnibox(sess: var TuiTestSession; line: string) =
  sess.send("\x10")  # Ctrl+P
  sleep(200)
  sess.send(line)
  sleep(150)
  sess.send("\r")

proc writeCrate(): string =
  result = createTempDir("ct-plat62-pty-", "")
  createDir(result / "src")
  writeFile(result / "Nargo.toml", Plat62NargoToml)
  for (path, content) in Plat62Files:
    writeFile(result / path, content)

proc rowsMatch(sess: var TuiTestSession; headRow: int; answers: JsonNode): int =
  ## How many of the desktop's rows the screen shows, in its order, under the
  ## headline: each line holds the row's name, count and place.
  let s = sess.snap()
  var r = headRow + 1
  for want in answers["before"]["rows"]:
    while r < Rows and s.text(r).cellFind(want["name"].getStr) < 0 and
          r < headRow + 6:
      inc r
    let line = s.text(r)
    if line.contains(want["name"].getStr) and
       line.contains(" " & want["count"].getStr & " ") and
       (want["where"].getStr.len == 0 or line.contains(want["where"].getStr)):
      inc result
    else:
      checkpoint("row '" & want["name"].getStr & "' at " & $r & ": '" &
                 line & "'")
    inc r

proc widenLeftOf(sess: var TuiTestSession; row: int; cols = 70) =
  ## Drag the divider left of the pane on `row` (the last `▏` before the
  ## pane's text) `cols` cells to the left, as a user drags it, so the
  ## columns the desktop shows whole are shown whole.
  let s = sess.snap()
  var divider = -1
  for c in 0 ..< Cols:
    if $s[row][c].rune == "▏":
      divider = c
  doAssert divider > 0, "no divider on row " & $row & ":\n" & s.screenText()
  sess.mouse(0, row, divider)
  for step in 1 .. 7:
    sess.mouse(32, row, divider - step * (cols div 7))
    sleep(30)
  sess.mouse(0, row, divider - cols, release = true)
  discard sess.waitFor("applied")
  sleep(300)

proc spawnIn(project, state: string; args: seq[string];
             ct = ""): TuiTestSession =
  var t = newTuiTest(tuiBinary(), @["--theme=dark"] & args)
    .width(Cols).height(Rows).transcript()
    .workDir(project)
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
               "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .envSet("TEST_CERTIFICATES_DIR", state / "certs")
    .envSet("TEST_CERTIFICATES_SYSTEM_DIR", state / "certs-system")
  if ct.len > 0:
    t = t.envSet("CT_BIN", ct)
  t.carryRunMark().spawn()

let answers = parseJson(readFile(lifecycle_support.repoRoot() / AnswersFile))

suite "PLAT-62: the Constraints pane on a real terminal":

  test "Edit mode: the desktop's rows, a press, the menu":
    let project = writeCrate()
    let state = getTempDir() / ("plat62-pty-edit-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = spawnIn(project, state, @["--edit", project])
    let headline = answers["before"]["headline"].getStr
    var (hr, _) = sess.waitFor(headline, MeasureBudgetMs)
    sess.widenLeftOf(hr + 3)
    hr = sess.waitFor(headline)[0]
    ck hr >= 0
    ck sess.rowsMatch(hr, answers) == answers["before"]["rows"].len
    # A PRESS ON `halve`: its declaring line in the editor.
    var s = sess.snap()
    let (halveRow, halveCol) = s.findRow("halve ")
    ck halveRow > hr
    sess.press(halveRow, halveCol)
    discard sess.waitFor("opened src/main.nr:" & $Plat62HalveLine)
    ck sess.snap().findRow("unconstrained fn halve(v: Field)")[0] >= 0
    # A RIGHT PRESS on `main`: the desktop's menu.
    s = sess.snap()
    var mr = -1
    var mc = -1
    for r in hr + 1 .. min(Rows - 1, hr + 5):
      let c = s.text(r).cellFind("main ")
      if c >= 0:
        mr = r
        mc = c
        break
    ck mr > hr
    sess.press(mr, mc, button = 2)
    var shown = 0
    for e in answers["placedMenu"]:
      if sess.waitFor(e["label"].getStr)[0] >= 0: inc shown
    ck shown == answers["placedMenu"].len
    sess.send("\x1b")
    sleep(300)
    # A PRESS ON A DIRECTIVE: nothing opens, and the status line says why.
    s = sess.snap()
    let (dr, dc) = s.findRow("directive_integer_quotient")
    ck dr > hr
    sess.press(dr, dc)
    discard sess.waitFor("the compiler generated this function")
    sess.send("\x11")   # Ctrl+Q
    discard sess.waitExit(initDuration(seconds = 20))
    removeDir(state)
    removeDir(project)

  test "its recording: `:constraints` in the recording's own tab":
    let calc = resolveFixture(FixtureSpec(
      name: "calc", program: "test-programs/calc/main.py",
      recorder: "codetracer-python-recorder",
      probe: FixtureProbe(kind: pkPythonRecorder),
      buildHint: "Install codetracer_python_recorder into the interpreter " &
                 "`ct` will use.",
      blockedOn: ""))
    doAssert calc.outcome == foRecorded, calc.detail
    let ct = fixture_provider.findCtBinary()
    doAssert ct.len > 0, "prerequisite missing: ct (build it, or set CT_BIN)"
    let project = writeCrate()
    let state = getTempDir() / ("plat62-pty-rec-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = spawnIn(project, state, @[calc.tracePath], ct)
    settleOnDebugger(sess, Cols, Rows)
    # The crate's test, recorded and opened in a new session tab.
    var s = sess.snap()
    var tr, tc = -1
    for r in 0 ..< Rows:
      let t = s.text(r)
      if t.contains(" Files ") and t.contains(" Tests"):
        tr = r
        tc = t.cellFind(" Tests") + 2
        break
    doAssert tr >= 0, "no Tests tab:\n" & s.screenText()
    sess.press(tr, tc)
    let (rowR, _) = sess.waitFor("test_main")
    s = sess.snap()
    let openCol = s.text(rowR).cellFind("⏺⏵") + 1
    ck openCol > 0
    sess.press(rowR, openCol)
    discard sess.waitFor("in a new tab", RecordBudgetMs)
    # Debug mode places no Constraints pane; `:constraints` opens it.
    ck sess.snap().findRow(answers["before"]["headline"].getStr)[0] < 0
    sess.omnibox(":constraints")
    let (hr, _) = sess.waitFor(answers["before"]["headline"].getStr,
                               MeasureBudgetMs)
    ck sess.rowsMatch(hr, answers) == answers["before"]["rows"].len
    # A press on `main` opens its line from the recording.
    s = sess.snap()
    var mr, mc = -1
    for r in hr + 1 .. min(Rows - 1, hr + 5):
      let c = s.text(r).cellFind("main ")
      if c >= 0:
        mr = r
        mc = c
        break
    ck mr > hr
    sess.press(mr, mc)
    discard sess.waitFor("opened src/main.nr:" & $Plat62MainLine)
    ck sess.snap().findRow("fn main(x: Field, y: pub Field)")[0] >= 0
    sess.send("\x11")
    discard sess.waitExit(initDuration(seconds = 20))
    removeDir(state)
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
