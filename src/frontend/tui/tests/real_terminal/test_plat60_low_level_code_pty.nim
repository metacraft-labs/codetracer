## test_plat60_low_level_code_pty.nim — PLAT-60, Tier 2. **The Low Level Code
## pane on a real terminal.**
##
## The shipped `codetracer-tui` on the `noir_space_ship` recording (the Noir
## producer's), driven as a user drives it, read back off the screen through
## libvterm:
##
##   * `Alt+1` — the desktop's `aLowLevel1` — opens the pane beside the source
##     (its tab on the editor's strip row, to the editor's right), its header
##     saying `sync on` and that a step goes by line;
##   * every instruction the engine lists is drawn under its source line, as
##     `StepId(<step>)`, with its `path:line`, and the execution pointer `▸` is
##     on the instruction of the line the header's location names;
##   * a press on an instruction of another line moves the debugger there: the
##     header's tick moves and the pointer follows;
##   * a right press opens the instruction's menu, its four entries drawn.
##
## No mocks: the real binary, a real recording made by `nargo`, a real
## `replay-server`, a real pty (TermAssert + libvterm).

import std/[monotimes, os, strutils, times, unittest]
from std/unicode import runeLen, runeSubStr

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 16

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  AltOne = "\x1b1"

proc rowOf(sess: var TuiTestSession; row: int): string =
  discard sess.drainOutput(40)
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc screen(sess: var TuiTestSession): seq[string] =
  discard sess.drainOutput(60)
  for r in 0 ..< Rows:
    result.add sess.rowOf(r)

proc waitScreen(sess: var TuiTestSession; needle: string;
                timeoutMs = 60000): seq[string] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    for line in result:
      if line.contains(needle):
        return
    sleep(50)
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared; screen:\n" & result.join("\n"))

proc tickOf(line: string): int =
  let at = line.find("tick: ")
  if at < 0: return -1
  var n = ""
  for ch in line[at + 6 .. ^1]:
    if ch in {'0' .. '9'}: n.add ch
    elif ch == ',': discard
    else: break
  if n.len == 0: -1 else: parseInt(n)

proc press(sess: var TuiTestSession; row, col: int; button = 0) =
  sess.send("\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) & "m")

proc cellOf(line, needle: string): int =
  ## The cell `needle` starts at in `line`, -1 when it is not there.
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc paneSlice(t: string; col, width: int): string =
  ## Cells `[col, col + width)` of screen row `t`.
  t.runeSubStr(col, width)

proc instructionRows(s: seq[string]; col, width: int):
    seq[tuple[row, col, line: int; pointer: bool]] =
  ## Every drawn instruction of the pane at cells `[col, col + width)`: its
  ## screen row, the cell its offset starts at, the source line drawn above
  ## it (`  13  println(…)`), and whether the pointer `▸` marks it.
  var line = 0
  for r, t in s:
    let cell = t.paneSlice(col, width)
    let words = cell.strip().splitWhitespace()
    if words.len == 0: continue
    if words[0].allCharsInSet(Digits) and not cell.startsWith("▸"):
      line = parseInt(words[0])
    let at = max(cell.cellOf("StepId("), cell.cellOf("<no step id>"))
    if at >= 0 and line > 0:
      result.add (r, col + at, line, cell.startsWith("▸"))

suite "PLAT-60 on a real terminal: the Low Level Code pane":

  test "Alt+1 beside the source; the listing; a press moves; the menu":
    let resolved = resolveFixture("noir_space_ship")
    doAssert resolved.outcome == foRecorded, resolved.detail
    let state = getTempDir() / ("plat60-pty-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", resolved.tracePath])
      .width(Cols).height(Rows).transcript()
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("XDG_STATE_HOME", state)
      .envSet("CODETRACER_HOME", state / "ct-home")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    let before = sess.screen()
    ck before.join("\n").find("Low Level Code") < 0
    let tick0 = tickOf(before[0])
    ck tick0 >= 0

    sess.send(AltOne)
    var s = sess.waitScreen("steps by line")
    # The pane's header row (its sync toggle and what a step does), under its
    # tab on the editor's strip row; the status row says what Alt+1 did.
    var header = -1
    for r, t in s:
      if header < 0 and r < Rows - 1 and t.contains(" sync on ") and
         t.contains("steps by line"):
        header = r
    checkpoint("screen:\n" & s.join("\n"))
    ck header > 1
    ck s[Rows - 1].contains("Low Level Code beside the source")
    # The pane's cells: from its header's first cell to the next divider —
    # its tab's label is above them (cut with `…` when the column is short).
    let paneCol = s[header].cellOf(" sync on ")
    let paneWidth = s[header].runeSubStr(paneCol).cellOf("▏")
    ck paneCol > 0 and paneWidth > 20
    ck s[header - 1].runeSubStr(paneCol, paneWidth).contains("Low Level")
    let rows = instructionRows(s, paneCol, paneWidth)
    checkpoint("listing:\n" & s.join("\n"))
    ck rows.len >= 3
    # The pointer, on one instruction: the line the editor's `▸` is on.
    var pointed = -1
    for i, r in rows:
      if r.pointer: pointed = i
    ck pointed >= 0
    # A press on an instruction of another line moves the debugger there.
    var target = -1
    for i, r in rows:
      if pointed >= 0 and r.line != rows[pointed].line and r.line > 0 and
         s[r.row].paneSlice(paneCol, paneWidth).contains("StepId("):
        target = i
    ck target >= 0
    sess.press(rows[target].row, rows[target].col + 2)
    let deadline = getMonoTime() + initDuration(milliseconds = 60000)
    var moved = sess.screen()
    while getMonoTime() < deadline and tickOf(moved[0]) == tick0:
      sleep(100)
      moved = sess.screen()
    ck tickOf(moved[0]) != tick0
    let after = instructionRows(sess.screen(), paneCol, paneWidth)
    var nowPointed = -1
    for i, r in after:
      if r.pointer: nowPointed = i
    ck nowPointed >= 0
    if nowPointed >= 0 and target >= 0:
      ck after[nowPointed].line == rows[target].line
    # A right press: the instruction's menu.
    sess.press(after[0].row, after[0].col + 2, 2)
    # Each entry waited for on its own: a frame read while the menu is
    # still being painted holds only some of its rows.
    for label in ["Go to Source Line", "Show Source Line", "Copy Instruction",
                  "Copy Source Location"]:
      ck sess.waitScreen(label).join("\n").contains(label)
    sess.send("\x1b")
    sess.close()
    removeDir(state)

suite "PLAT-60 PTY suite self-check":
  test "plat60_pty_assertion_count_is_measured":
    checkpoint("assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
