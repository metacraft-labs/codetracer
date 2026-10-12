## test_plat68b_pty.nim — PLAT-68 Phase B, Tier 2: the shipped
## `codetracer-tui` in a real PTY (TermAssert + libvterm) over a real
## recording and a real `replay-server`, driven by the bytes a terminal sends.
##
##   * THE STATUS LABEL (CodeTracer-TUI.md §3.3.6 as amended): under CUA the
##     indicator is the base's name, never `NORMAL` — a mode label only under
##     a base that has modes (Vim: `NORMAL`) or for a pushed layer that names
##     one (`PALETTE`, popped back to `CUA`);
##   * DEBUG MODE'S KEYS: `F10` steps; with the read-only editor focused the
##     LETTERS step (`n`), and type nothing;
##   * `Enter` in the read-only editor opens the tracepoint editor on the
##     caret's line, as the desktop does;
##   * SMART HOME: the first non-blank, then column 1, then back;
##   * SELECTION in the read-only editor — `Shift+End` and a pointer DRAG —
##     drawn on the selection ground, and `Ctrl+C` copies it to the terminal's
##     clipboard (OSC 52 in the bytes the binary wrote); edits are refused;
##   * PASTE ASKS THE TERMINAL: once `Ctrl+E` made the document writable,
##     `Ctrl+V` writes the OSC 52 read; an answer is what is pasted, and
##     silence pastes the session's own copy;
##   * THE FOCUSED STRIP'S SELECTED TAB is told apart from the other tabs by
##     its ground, over the tab-contrast floor;
##   * the user's `keybindings.json` (`CODETRACER_KEYBINDINGS`) beats the base
##     for the same key (KL-11).
##
## The OSC 52 answers in the paste case are bytes WRITTEN TO THE CHILD'S
## INPUT — what a terminal that allows clipboard reads sends back. libvterm
## answers none, so the silent case is the harness's own behaviour. That is
## the terminal's side of the conversation, not a stand-in for the product.
##
## No mocks: the real binary, a real recording, a real engine, a real pty.

import std/[base64, monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
import ../../app/theme/roles

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 39

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  StatusRow = Rows - 1
  Line11 = "  ``src/frontend/tui/tests/fixtures/fixture_provider.nim`` and the Tier-1 TUI"
    ## calc's line 11, indented two cells — Smart Home's line.
  Line11Shown = "  ``src/frontend/tui/tests/fixtures/fixture_provider.nim``"
    ## The part of it the editor pane is wide enough to show.
  F10 = "\e[21~"
  ShiftEnd = "\e[1;2F"
  Home = "\e[H"
  CtrlC = "\x03"
  CtrlE = "\x05"
  CtrlP = "\x10"
  CtrlQ = "\x11"
  CtrlV = "\x16"

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc freshDir(): string =
  inc spawned
  result = getTempDir() / ("plat68b-pty-" & $getCurrentProcessId() & "-" &
                           $spawned)
  removeDir(result)
  createDir(result)

proc open(extra: seq[string] = @[]; keybindings = ""): TuiTestSession =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded, resolved.detail
  let state = freshDir()
  if keybindings.len > 0:
    writeFile(state / "keybindings.json", keybindings)
  result = newTuiTest(tuiBinary(), @["--theme=dark"] & extra &
                      @[resolved.tracePath])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .envSet("CODETRACER_KEYBINDINGS", state / "keybindings.json")
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

proc status(sess: var TuiTestSession): string =
  sess.snap().text(StatusRow).strip()

proc waitUntil(sess: var TuiTestSession; what: string;
               cond: proc(s: Snapshot): bool; timeoutMs = 20000) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if cond(sess.snap()): return
    sleep(40)
  raise newException(AssertionFailedError, "never: " & what & "; status: " &
                     sess.snap().text(StatusRow))

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int) =
  sess.mouse(0, row, col)
  sess.mouse(0, row, col, release = true)

proc quit(sess: var TuiTestSession) =
  sess.send(CtrlQ)
  discard sess.waitExit(initDuration(seconds = 15))
  sess.terminate()
  sess.close()

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

proc tick(s: Snapshot): int =
  let line = s.text(0)
  let at = line.find("tick: ")
  if at < 0: return -1
  var digits = ""
  for c in line[at + "tick: ".len .. ^1]:
    if c in {'0' .. '9'}: digits.add c
    elif c == ',': discard
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc line11(s: Snapshot): tuple[row, code: int] =
  ## The screen row of calc's line 11 and the cell its code starts at.
  let (r, c) = s.findRow("``src/frontend/tui/tests/fixtures/fixture_provider")
  (r, c - 2)

proc caretColumn(s: Snapshot; row, code: int): int =
  ## The 1-based text column of the reversed (caret) cell on `row`, or 0.
  for c in code ..< Cols:
    if caReverse in s[row][c].attrs: return c - code + 1
  0

proc clickLine11(sess: var TuiTestSession; column: int): tuple[row, code: int] =
  ## A left press on line 11's text at `column` (1-based): the editor takes
  ## the focus and the caret.
  result = sess.snap().line11()
  doAssert result.row >= 0, "calc's line 11 is not on the screen"
  sess.press(result.row, result.code + column - 1)
  let at = result
  sess.waitUntil("the caret at column " & $column,
    proc(s: Snapshot): bool = s.caretColumn(at.row, at.code) == column)

let selectionHex = tokenHex(RoleSpecs[srSurfaceSelection].bg, dmDark)

suite "PLAT-68 Phase B on a real terminal: the status label":

  test "CUA shows its name, never NORMAL; a pushed layer names itself":
    # The indicator is the label beside the product mode (`CUA [DEBUG]`).
    var sess = open()
    ck "CUA [DEBUG]" in sess.status()
    ck "NORMAL" notin sess.status()
    sess.send(CtrlP)
    sess.waitUntil("PALETTE", proc(s: Snapshot): bool =
      "PALETTE [DEBUG]" in s.text(StatusRow))
    ck "PALETTE [DEBUG]" in sess.status()
    sess.send("\e")
    sess.waitUntil("back to CUA", proc(s: Snapshot): bool =
      "CUA [DEBUG]" in s.text(StatusRow))
    ck "CUA [DEBUG]" in sess.status()
    sess.quit()

  test "a base with modes shows its mode":
    var sess = open(@["--keymap=vim"])
    ck "NORMAL [DEBUG]" in sess.status()
    sess.quit()

suite "PLAT-68 Phase B on a real terminal: Debug mode's keys":

  test "F10 steps; with the read-only editor focused, a letter steps and types nothing":
    var sess = open()
    let t0 = sess.snap().tick
    sess.send(F10)
    sess.waitUntil("F10 moved the tick", proc(s: Snapshot): bool =
      s.tick > t0)
    let t1 = sess.snap().tick
    ck t1 > t0
    discard sess.clickLine11(5)
    let before = sess.snap().line11()
    sess.send("n")
    sess.waitUntil("n moved the tick", proc(s: Snapshot): bool = s.tick > t1)
    ck sess.snap().tick > t1
    # The read-only document took no `n`.
    let after = sess.snap()
    ck after.text(after.line11().row).contains(Line11Shown)
    ck before.row >= 0
    sess.quit()

  test "Enter opens the tracepoint editor on the caret's line":
    var sess = open()
    discard sess.clickLine11(5)
    sess.send("\r")
    sess.waitUntil("the tracepoint editor", proc(s: Snapshot): bool =
      ":tracepoint " in s.text(StatusRow))
    ck ":tracepoint " in sess.snap().text(StatusRow)
    # Its expression, committed: the sweep runs ON THE CARET'S LINE.
    sess.send("left\r")
    sess.waitUntil("the sweep", proc(s: Snapshot): bool =
      "tracepoint `left` at " in s.text(StatusRow))
    ck "main.py:11" in sess.snap().text(StatusRow)
    sess.quit()

  test "Smart Home: the first non-blank, then column 1, then back":
    var sess = open()
    let at = sess.clickLine11(10)
    var seen: seq[int] = @[]
    for want in [3, 1, 3]:
      sess.send(Home)
      sess.waitUntil("Home to " & $want, proc(s: Snapshot): bool =
        s.caretColumn(at.row, at.code) == want)
      seen.add sess.snap().caretColumn(at.row, at.code)
    ck seen == @[3, 1, 3]
    sess.quit()

suite "PLAT-68 Phase B on a real terminal: selection and the clipboard":

  test "Shift+End selects to the line's end; Ctrl+C copies it (OSC 52)":
    var sess = open()
    let at = sess.clickLine11(3)
    sess.send(ShiftEnd)
    sess.waitUntil("a selection", proc(s: Snapshot): bool =
      s[at.row][at.code + 2].bgHex == selectionHex)
    let s = sess.snap()
    # From column 3 to the end of the text, on the selection ground.
    ck s[at.row][at.code + 2].bgHex == selectionHex
    ck s[at.row][at.code + Line11Shown.runeLen - 1].bgHex == selectionHex
    ck s[at.row][at.code].bgHex != selectionHex
    sess.send(CtrlC)
    sess.waitUntil("copied", proc(s: Snapshot): bool =
      "copied" in s.text(StatusRow))
    let copied = Line11[2 .. ^1]   # from column 3 to the line's end
    ck sess.transcriptBytes().contains("\e]52;c;" & base64.encode(copied))
    # Typing into the read-only document is refused: the line is unchanged.
    sess.send("x")
    sleep(300)
    ck sess.snap().text(at.row).contains(Line11Shown)
    sess.quit()

  test "a pointer drag selects across lines":
    var sess = open()
    let at = sess.clickLine11(3)
    # The press is held: motion with the left button (SGR 32), then release.
    sess.mouse(0, at.row, at.code + 2)
    sess.mouse(32, at.row + 1, at.code + 4)
    sess.mouse(0, at.row + 1, at.code + 4, release = true)
    sess.waitUntil("a two-line selection", proc(s: Snapshot): bool =
      s[at.row + 1][at.code].bgHex == selectionHex)
    let s = sess.snap()
    ck s[at.row][at.code + 2].bgHex == selectionHex
    ck s[at.row + 1][at.code + 3].bgHex == selectionHex
    ck s[at.row + 1][at.code + 4].bgHex != selectionHex
    sess.quit()

  test "paste asks the terminal (OSC 52 read): an answer is what is pasted":
    var sess = open()
    # The caret on line 3, which is empty (a press past a line's end puts
    # it at the end).
    let at = sess.snap().line11()
    sess.press(at.row - 8, at.code + 4)
    sess.send(CtrlE)
    sess.waitUntil("writable", proc(s: Snapshot): bool =
      "writable" in s.text(StatusRow))
    sess.send(CtrlV)
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while getMonoTime() < deadline and
          not sess.transcriptBytes().contains("\e]52;c;?\a"):
      discard sess.drainOutput(40)
    ck sess.transcriptBytes().contains("\e]52;c;?\a")
    sess.send("\e]52;c;" & base64.encode("ZQXJ-from-the-terminal") & "\a")
    sess.waitUntil("the answer pasted", proc(s: Snapshot): bool =
      s.findRow("ZQXJ-from-the-terminal")[0] >= 0)
    ck sess.snap().findRow("ZQXJ-from-the-terminal")[0] >= 0
    sess.quit()

  test "paste with a silent terminal pastes the session's own copy":
    var sess = open()
    let at = sess.clickLine11(3)
    sess.send(ShiftEnd)
    sess.send(CtrlC)
    sess.waitUntil("copied", proc(s: Snapshot): bool =
      "copied" in s.text(StatusRow))
    # Onto line 3, empty, and writable.
    sess.press(at.row - 8, at.code + 4)
    sess.send(CtrlE)
    sess.waitUntil("writable", proc(s: Snapshot): bool =
      "writable" in s.text(StatusRow))
    sess.send(CtrlV)
    # libvterm never answers: after the wait the session's copy goes in, so
    # line 11's text is on the screen twice.
    proc twice(s: Snapshot): bool =
      var n = 0
      for r in 0 ..< Rows:
        if "fixture_provider.nim``" in s.text(r): inc n
      n == 2
    sess.waitUntil("the internal copy pasted", twice)
    ck twice(sess.snap())
    ck sess.transcriptBytes().contains("\e]52;c;?\a")
    sess.quit()

suite "PLAT-68 Phase B on a real terminal: the focused strip's tabs":

  test "the selected tab's ground stands apart from the others' by the floor":
    var sess = open()
    # The editor has the focus once its text is pressed; its strip is the
    # focused one, and its active tab must not share the strip's ground.
    discard sess.clickLine11(3)
    let s = sess.snap()
    let focusHex = tokenHex(RoleSpecs[srTabBarFocused].bg, dmDark)
    let activeHex = tokenHex(RoleSpecs[srTabActiveFocused].bg, dmDark)
    var stripRow = -1
    for r in 1 ..< StatusRow:
      for c in 0 ..< Cols:
        if s[r][c].bgHex == focusHex:
          stripRow = r
          break
      if stripRow >= 0: break
    ck stripRow >= 0
    var activeCells, focusCells = 0
    for c in 0 ..< Cols:
      if s[stripRow][c].bgHex == activeHex: inc activeCells
      if s[stripRow][c].bgHex == focusHex: inc focusCells
    ck activeCells > 0 and focusCells > 0
    ck contrastRatio(parseHexColour(activeHex), parseHexColour(focusHex)) >=
       TabGroundContrastFloor
    sess.quit()

suite "PLAT-68 Phase B on a real terminal: the user's keybindings.json":

  test "a user row beats the base row for the same key (KL-11)":
    # The base's `F10` is one step; the user binds it to CONTINUE, which runs
    # this recording to its end — far past one step.
    var base = open()
    let b0 = base.snap().tick
    base.send(F10)
    base.waitUntil("F10 stepped", proc(s: Snapshot): bool = s.tick > b0)
    let stepped = base.snap().tick
    base.quit()
    var sess = open(keybindings = """// JSONC, as VS Code writes it
    [
      { "key": "f10", "command": "debugger.continue" },
    ]""")
    let t0 = sess.snap().tick
    ck t0 == b0
    sess.send(F10)
    sess.waitUntil("F10 continued", proc(s: Snapshot): bool =
      s.tick > stepped)
    ck sess.snap().tick > stepped
    sess.quit()

suite "PLAT-68 Phase B on a real terminal: the program menu from the keyboard":

  test "Alt+` opens the menu, its access keys underlined; Alt+` closes it":
    # A terminal never reports Alt alone; `` Alt+` `` (ESC `) is its chord
    # (CUA-Keymap.md §3.8).
    var sess = open()
    sess.send("\e`")
    sess.waitUntil("the menu", proc(s: Snapshot): bool =
      s.findRow(" View ")[0] >= 0 and s.findRow(" Debug ")[0] >= 0)
    let s = sess.snap()
    # The mnemonic's cell is underlined, its neighbours are not.
    for (label, at) in [(" File ", 1), (" Edit ", 3), (" View ", 4),
                        (" Debug ", 1)]:
      let (row, col) = s.findRow(label)
      checkpoint(label)
      ck s[row][col + at].underline != usNone
      ck s[row][col + at + 1].underline == usNone
    sess.send("\e`")
    sess.waitUntil("the menu closed", proc(s: Snapshot): bool =
      s.findRow(" Reset ")[0] < 0)
    ck sess.snap().findRow(" Reset ")[0] < 0
    sess.quit()

  test "Alt+D opens the Debug folder; Esc closes the menu":
    var sess = open()
    sess.send("\ed")
    sess.waitUntil("the Debug folder", proc(s: Snapshot): bool =
      s.findRow(" Reverse Step Over")[0] >= 0)
    ck sess.snap().findRow(" Step Out")[0] >= 0
    sess.send("\e")
    discard sess.drainOutput(250)
    sess.send("\e")
    sess.waitUntil("the menu closed", proc(s: Snapshot): bool =
      s.findRow(" Reverse Step Over")[0] < 0)
    sess.quit()

suite "PLAT-68 Phase B on a real terminal: assertion count":
  test "the declared count was reached":
    check countedAssertions == ExpectedAssertions
