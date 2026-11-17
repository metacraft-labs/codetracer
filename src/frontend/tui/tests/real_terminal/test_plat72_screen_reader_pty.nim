## test_plat72_screen_reader_pty.nim — the screen-reader mode on a real pty
## (CodeTracer-TUI-Terminal-Adaptation.md §9.4, SR-D1 – SR-D7):
##
##   * TA-16 — the screen carries no decoration: no box, divider, rule or
##     scrollbar glyph and nothing outside ASCII in the chrome, where the same
##     recording on the ASCII tier without the mode draws its frames (the
##     control);
##   * TA-17 — the terminal's own cursor is SHOWN on the focused element (as
##     libvterm reads it), and follows focus to the next pane and down a row;
##   * TA-18 — every focus change is said on the status line: the pane's name
##     when focus enters it, the row alone when it moves inside it, and a
##     message the keystroke wrote itself (`:set`) is kept;
##   * TA-19 — one pane at a time fills the body, and the next pane replaces
##     it when focus moves;
##   * TA-20 — the pointer resting on a top-bar control says nothing, where
##     without the mode it puts the control's words on the status line (the
##     control);
##   * SR-D2 — `ACCESSIBLE=1` alone turns `auto` on, and the report says so.
##
## ## The one stand-in, and why it is not a mock
##
## The persona peer (`persona_peer`) types the TERMINAL'S half of the start-up
## round with kitty 0.44.0's captured answers, as PLAT-71's suites do. The
## subject — the shipped `codetracer-tui` on a real recording through a real
## `replay-server`, its paint, its cursor, its status line — is real and
## untouched, and every assertion reads libvterm's screen and cursor.
##
## ## No skips
##
## A missing binary or fixture FAILS by name with the recipe.
##
## Templates, not procs, for anything that calls `check`.

import std/[os, sequtils, strutils, tables, times, unicode, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support
import ./persona_peer

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 32

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 120
  Rows = 40

var stateRoot = getTempDir() / ("plat72-state-" & $getCurrentProcessId())
var runs = 0

proc freshState(tag: string): string =
  result = stateRoot / tag
  removeDir(result)
  createDir(result)

proc builder(args: seq[string]; extra: seq[(string, string)] = @[]):
    TuiTestBuilder =
  # BLOCKED OR SET, NEVER BOTH (`lifecycle_support.tuiSession`'s rule).
  var blocked: seq[string] = @[]
  for v in ["COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE",
            "TMUX", "STY", "ZELLIJ", "KITTY_WINDOW_ID", "VTE_VERSION",
            "SSH_CONNECTION", "SSH_TTY", "CODETRACER_TUI_GLYPHS",
            "CODETRACER_TUI_MODERN_UNICODE", "CODETRACER_TUI_PROBE",
            "CODETRACER_TUI_AMBIGUOUS_WIDTH", "CODETRACER_TUI_COLORS",
            "CODETRACER_TUI_SCREEN_READER", "ACCESSIBLE", "CODETRACER_HOME"]:
    var setHere = false
    for (k, _) in extra:
      if k == v: setHere = true
    if not setHere: blocked.add v
  inc runs
  let root = freshState("s" & $runs)
  result = newTuiTest(tuiBinary(), args).width(Cols).height(Rows).transcript()
    .envRemove(blocked)
    .envSet("TERM", "xterm-kitty").envSet("LANG", "en_US.UTF-8")
    .envSet("CT_TUI_PROBE_TIMEOUT_MS", "1500")
    .envSet("XDG_STATE_HOME", root)
    .envSet("CODETRACER_TUI_LAYOUT_DIR", root / "layout")
    .carryRunMark()
  for (k, v) in extra:
    result = result.envSet(k, v)

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

proc screenText(sess: var TuiTestSession): string =
  sess.regionText(0, 0, Cols, Rows)

proc rowAt(sess: var TuiTestSession; row: int): string =
  strutils.strip(sess.regionText(row, 0, Cols, 1), leading = false)

proc statusRow(sess: var TuiTestSession): string =
  sess.rowAt(Rows - 1)

proc settle(sess: var TuiTestSession; timeoutMs = 3000) =
  ## Until the screen and the cursor have not changed for 400 ms.
  let deadline = epochTime() + timeoutMs.float / 1000
  var last = ""
  var since = epochTime()
  while epochTime() < deadline:
    discard sess.drainOutput(40)
    let pos = sess.cursorPosition()
    let now = sess.screenText() & "@" & $pos.row & "," & $pos.col & "," &
              $sess.cursorVisible()
    if now != last:
      last = now
      since = epochTime()
    elif epochTime() - since > 0.4:
      return

proc cellMouse(p: Persona): Persona =
  ## kitty without its pixel-mouse answers (DECRQM 1016 and the cell size):
  ## with them the binary asks for SGR-pixel reports, and TermAssert's
  ## `sendMouseMove` writes CELL reports (`test_plat70f_pointer_pty.nim`'s
  ## reason, the same helper).
  result = p
  result.modes.del 1016
  result.verbatim.del "\x1b[16t"

proc open(args: seq[string]; extra: seq[(string, string)] = @[]):
    TuiTestSession =
  let calc = resolveFixture(pythonSpec("calc"))
  if calc.outcome != foRecorded:
    raise newException(AssertionFailedError, calc.detail)
  result = builder(@[calc.tracePath] & args, extra).spawn()
  discard result.serve(cellMouse(kitty()))
  # The debugger, then a quiet screen: the top bar names the trace once it
  # is open (`trace: -` before), and the status line has left `opening …`.
  let deadline = epochTime() + 180
  while epochTime() < deadline:
    discard result.drainOutput(40)
    let top = result.rowAt(0)
    let status = result.statusRow()
    if status.len > 0 and not status.contains("opening ") and
       not top.contains("trace: - "):
      break
    if not result.isAlive:
      raise newException(AssertionFailedError,
                         "the binary exited: " & result.screenText())
  result.settle()

proc waitStatus(sess: var TuiTestSession; pred: proc(s: string): bool;
                timeoutMs = 8000): string =
  let deadline = epochTime() + timeoutMs.float / 1000
  while epochTime() < deadline:
    discard sess.drainOutput(40)
    result = sess.statusRow()
    if pred(result):
      sess.settle()
      return sess.statusRow()
  sess.settle()
  result = sess.statusRow()

proc finish(sess: var TuiTestSession) =
  sess.send("\x11")  # Ctrl+Q, the CUA base's quit
  discard sess.waitExit(initDuration(seconds = 20))
  discard sess.drainOutput(100)
  sess.close()

proc decorations(sess: var TuiTestSession): seq[string] =
  ## What on the screen is drawing, not text: a column holding a divider or a
  ## scrollbar glyph down ten body rows or more (a program's text does not
  ## line up so), a run of eight scrollbar cells along a row, a box-drawing,
  ## block or Legacy Computing glyph anywhere.
  var rows: seq[seq[Rune]] = @[]
  for r in 0 ..< Rows:
    rows.add toSeq(sess.regionText(r, 0, Cols, 1).runes)
  for c in 0 ..< Cols:
    var n = 0
    for r in 2 ..< Rows - 1:
      if c < rows[r].len and $rows[r][c] in ["|", "#"]: inc n
    if n >= 10: result.add "column " & $c
  for r in 0 ..< Rows:
    let text = $rows[r]
    if text.contains("########"): result.add "row " & $r
    for rune in rows[r]:
      if int(rune) in 0x2500 .. 0x259F or int(rune) in 0x1FB00 .. 0x1FBFF:
        result.add "row " & $r & ": " & $rune
        break

proc saidPane(status: string): string =
  ## The pane an announcement names: the status line starts with the
  ## message in the screen-reader mode, `<Pane>: <row>` on entry.
  let s = status.strip
  let at = s.find(": ")
  if at > 0: s[0 ..< at] else: ""

suite "the screen-reader mode on a real pty (§9.4)":

  test "the binary exists":
    ck fileExists(tuiBinary())

  test "TA-16 to TA-19: no decoration, one pane, the cursor on focus, focus said":
    # THE CONTROL: the ASCII tier without the mode draws its frames.
    var plain = open(@["--glyphs=ascii", "--screen-reader=off"])
    let plainScreen = plain.screenText()
    checkpoint("ASCII tier, mode off:\n" & plainScreen)
    checkpoint("its decorations: " & $plain.decorations)
    ck plain.decorations.len > 0
    ck not plain.cursorVisible()
    plain.finish()

    var s = open(@["--screen-reader=on"])
    let screen = s.screenText()
    checkpoint("mode on:\n" & screen)
    checkpoint("its decorations: " & $s.decorations)
    ck s.decorations.len == 0
    # TA-17: the cursor is shown, inside the body, on the focused row.
    ck s.cursorVisible()
    let at = s.cursorPosition()
    ck at.row > 1 and at.row < Rows - 1
    let first = s.statusRow()
    checkpoint("status: " & first)
    # TA-18: entering the first pane names it, at the start of the line, and
    # it is the pane the strip row shows.
    let firstPane = saidPane(first)
    ck firstPane.len > 0
    ck s.rowAt(1).toLowerAscii.contains(firstPane.toLowerAscii)
    # The row the cursor is on is the row the status line names.
    let said = first.strip[firstPane.len + 2 .. ^1].strip
    ck said.len > 0
    ck strutils.splitWhitespace(s.rowAt(at.row)).join(" ").contains(
         strutils.splitWhitespace(said)[0])
    # TA-19: one pane fills the body: its title alone on the strip row,
    # where the control's strip row named several.
    ck strutils.splitWhitespace(s.rowAt(1)).len <
       strutils.splitWhitespace(plainScreen.splitLines[1]).len
    # F6: the next pane. Its name, the screen follows, the cursor follows.
    s.send("\x1b[17~")
    let second = s.waitStatus(proc(t: string): bool =
      saidPane(t).len > 0 and saidPane(t) != firstPane)
    checkpoint("after F6: " & second & "\n" & s.screenText())
    let secondPane = saidPane(second)
    ck secondPane.len > 0 and secondPane != firstPane
    ck s.rowAt(1).toLowerAscii.contains(secondPane.toLowerAscii)
    ck not s.rowAt(1).toLowerAscii.contains(firstPane.toLowerAscii)
    ck s.cursorVisible()
    # A move inside a list: the row alone (the pane was named on entry), and
    # the cursor with it. The Files tree, reached with F6; a click selects
    # its file row.
    var current = second
    for i in 0 ..< 12:
      if saidPane(current) == "Files": break
      s.send("\x1b[17~")
      let was = current
      current = s.waitStatus(proc(t: string): bool =
        saidPane(t).len > 0 and t != was)
    checkpoint("list pane: " & current & "\n" & s.screenText())
    ck saidPane(current) == "Files"
    var fileRow = -1
    for r in 2 ..< Rows - 1:
      if s.rowAt(r).contains("main.py"): fileRow = r
    ck fileRow > 0
    s.sendMouseClick(fileRow, 4)
    let moved = s.waitStatus(proc(t: string): bool = t != current)
    checkpoint("after the click: " & moved)
    let after = s.cursorPosition()
    ck after.row == fileRow
    ck moved.contains("main.py")
    ck not moved.strip.startsWith("Files: ")
    s.finish()

  test "TA-18: a message the keystroke wrote is kept":
    var s = open(@["--screen-reader=off"])
    ck not s.cursorVisible()
    s.send(":set screen-reader on\r")
    let status = s.waitStatus(proc(t: string): bool =
      t.contains("screen reader on"))
    checkpoint(status)
    ck status.contains("screen-reader") and status.contains("screen reader on")
    ck s.cursorVisible()
    # And the next focus change is said again.
    s.send("\x1b[17~")
    let next = s.waitStatus(proc(t: string): bool = t != status)
    checkpoint(next)
    ck next != status and saidPane(next).len > 0
    s.finish()

  test "TA-20: the pointer resting on a control says nothing":
    for (mode, speaks) in [("off", true), ("on", false)]:
      var s = open(@["--screen-reader=" & mode])
      let top = s.rowAt(0)
      let quiet = s.statusRow()
      # A transport control the top bar draws: its word on the ASCII tier,
      # its mark otherwise; the column counted in cells (one per rune here).
      var col = -1
      for label in ["Continue", "Next", "\u23F5", "\u2193"]:
        let at = top.find(label)
        if at >= 0:
          col = top[0 ..< at].runeLen
          break
      checkpoint(mode & ": top bar '" & top & "', control at " & $col)
      ck col >= 0
      s.sendMouseMove(0, col + 1)
      sleep(800)
      s.settle()
      let status = s.statusRow()
      checkpoint(mode & ": status after hover '" & status & "'")
      ck (status != quiet) == speaks
      s.finish()

  test "SR-D2: ACCESSIBLE turns auto on, and the report says why":
    var s = open(@[], extra = @[("ACCESSIBLE", "1")])
    ck s.cursorVisible()
    checkpoint(s.statusRow())
    ck saidPane(s.statusRow()).len > 0
    s.finish()
    var report = builder(@["--capabilities"], @[("ACCESSIBLE", "1")]).spawn()
    discard report.serve(kitty())
    discard report.waitExit(initDuration(seconds = 20))
    discard report.drainOutput(100)
    let bytes = report.transcriptBytes()
    checkpoint(bytes)
    ck bytes.contains("Screen reader on:")
    ck bytes.contains("(environment: ACCESSIBLE=1)")
    report.close()

  test "the count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions

removeDir(stateRoot)
