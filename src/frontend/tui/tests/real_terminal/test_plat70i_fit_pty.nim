## test_plat70i_fit_pty.nim — PLAT-70 Part I (Horizontal-Overflow.md §5.5),
## the shipped `codetracer-tui` on a REAL pseudo-terminal (TermAssert: a real
## pty, the screen read back through libvterm), over real recordings against
## the real `replay-server`:
##
##   * the Event Log of `test-programs/wide_lines` — its columns fit the
##     pane, so no bar; `:column-width output 300` (a width wider than the
##     pane, HO-14) makes the columns SCROLL: the pane's last body row becomes
##     the bar and holds no event; a horizontal wheel notch (the exact SGR
##     bytes `CSI < 67 ; c ; r M`, HO-6) moves the header and the rows
##     together by `WheelColumns`; `:column-width output 20` brings the
##     floors back inside the pane and the bar goes (HO-11);
##   * the Call Trace of `test-programs/deep_calls` — a call nested 40 deep,
##     whose indent and name do not fit the pane: the pane SCROLLS, and wheel
##     notches to the right bring the deepest call's whole name,
##     `reached_the_bottom`, on screen (HO-15).
##
## No mocks: the binary, the engine and the recordings are real. State in a
## scratch directory.

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import codetracer_embed

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 9

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 150
  Rows = 44

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc trace(name, program: string): string =
  let resolved = resolveFixture(FixtureSpec(
    name: name, program: program,
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

proc open(recording: string): TuiTestSession =
  inc spawned
  let state = getTempDir() / ("plat70i-pty-" & $getCurrentProcessId() & "-" &
                              $spawned)
  removeDir(state)
  createDir(state)
  # The scrollbars' look is fixed for this suite — `thin`, the track drawn,
  # never faded — so a bar is on screen whenever its pane overflows, however
  # long ago the pane last scrolled (Scrollbar-Scrubbers.md §7.5).
  result = newTuiTest(tuiBinary(), @["--theme=dark", "--scrollbar-thickness=thin",
                                     "--scrollbar-track=on", "--scrollbar-fade=off",
                                     recording])
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

proc glyph(c: Cell): string =
  if int(c.rune) == 0: " " else: $c.rune

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add c.glyph

proc cells(s: Snapshot; r, c0, n: int): string =
  for c in c0 ..< min(Cols, c0 + n):
    result.add s[r][c].glyph

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc findRow(s: Snapshot; needle: string; fromRow = 0): (int, int) =
  for r in fromRow ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc dump(s: Snapshot): string =
  for r in 0 ..< Rows: result.add s.text(r) & "\n"

proc waitUntil(sess: var TuiTestSession; what: string;
               cond: proc(s: Snapshot): bool; timeoutMs = 20000): Snapshot =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.snap()
    if cond(result): return
    sleep(40)
  raise newException(AssertionFailedError, "never: " & what & "\n" &
                     result.dump)

proc mouse(sess: var TuiTestSession; code, row, col: int) =
  ## One SGR-1006 report — the exact bytes a terminal writes.
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) & "M")

proc palette(sess: var TuiTestSession; command: string) =
  sess.send("\x10")        # Ctrl+P, the palette
  sleep(400)
  sess.send(command)
  sleep(250)
  sess.send("\r")

proc quit(sess: var TuiTestSession) =
  sess.send("\x11")  # Ctrl+Q, the CUA base's quit
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

type Pane = tuple[top, bottom, left, width: int]

proc paneOf(s: Snapshot; title: string): Pane =
  ## The body of the pane whose tab says `title`: from the row under its
  ## strip to the row before the next strip (or the status row), between
  ## the dividers (`▏`) around the tab.
  let (row, col) = s.findRow(" " & title & " ")
  doAssert row >= 0, "no '" & title & "' tab\n" & s.dump
  var left = col
  while left > 0 and s[row][left - 1].glyph != "▏": dec left
  var right = col
  while right < Cols and s[row][right].glyph != "▏": inc right
  var bottom = row + 1
  while bottom < Rows - 1:
    let line = s.cells(bottom, left, right - left)
    if line.strip.len > 0 and (line.contains(" Event Log ") or
                               line.contains(" Terminal Output ")):
      break
    inc bottom
  (row + 1, bottom - 1, left, right - left)

suite "PLAT-70 Part I on a real terminal: fit or scroll":

  test "the Event Log: no bar while the columns fit; a wide column scrolls":
    var sess = open(trace("wide_lines", "test-programs/wide_lines/main.py"))
    defer: sess.quit()
    discard sess.waitUntil("the wide output line in the Event Log",
      proc(s: Snapshot): bool = s.findRow("<<LEFT-EDGE>>")[0] >= 0)
    var s = sess.snap()
    let events = s.paneOf("Event Log")
    let header = events.top
    let outputAt = s.text(header).cellFind("output")
    checkpoint("event log " & $events & " output title at " & $outputAt)
    ck outputAt > events.left
    # FIT / SHRINK: the last body row is not a bar — the panes' bodies end
    # in event text or blank, never in thumb glyphs.
    proc barOn(s: Snapshot; r: int): bool =
      let line = s.cells(r, events.left, events.width - 1)
      for g in ["█", "▉", "▊", "▋", "▌", "▍", "▎", "▏", "▄", "▁", "━", "─"]:
        if line.contains(g) and line.strip.len > 0 and
           not line.contains("<<") and not line.contains("short"):
          return true
    let lastRow = events.bottom
    ck not s.barOn(lastRow)
    # HO-14: a width wider than the pane — the columns SCROLL.
    sess.palette(":column-width output 300")
    s = sess.waitUntil("the bar on the Event Log's last row",
      proc(s: Snapshot): bool = s.barOn(lastRow))
    ck s.barOn(lastRow)
    # HO-6 / §4.3: one wheel-right notch (SGR 67) over the pane moves the
    # header and the rows together.
    let before = s.text(header).cellFind("output")
    sess.mouse(67, events.top + 3, events.left + 10)
    s = sess.waitUntil("the header moved by a notch",
      proc(s: Snapshot): bool =
        s.text(header).cellFind("output") == before - WheelColumns)
    ck s.text(header).cellFind("output") == before - WheelColumns
    # The floors fit again: the bar goes (HO-11), the view back at 0.
    sess.palette(":column-width output 20")
    s = sess.waitUntil("the bar gone",
      proc(s: Snapshot): bool = not s.barOn(lastRow) and
        s.text(header).cellFind("output") == outputAt)
    ck not s.barOn(lastRow)
    ck s.text(header).cellFind("output") == outputAt

  test "HO-15: a deep call scrolls the Call Trace to its whole name":
    var sess = open(trace("deep_calls", "test-programs/deep_calls/main.py"))
    defer: sess.quit()
    var s = sess.waitUntil("the Call Trace's rows",
      proc(s: Snapshot): bool = s.findRow("descend #")[0] >= 0)
    let calls = s.paneOf("Call Trace")
    checkpoint("call trace " & $calls)
    ck calls.width < 2 * 40 + 2 + "reached_the_bottom".len
    # Bring the deepest call on screen: the trace's last rows (wheel notches
    # down over the pane, SGR 65), then scroll the view right (SGR 67).
    for _ in 0 ..< 30:
      sess.mouse(65, calls.top + 2, calls.left + 4)
      sleep(30)
    discard sess.waitUntil("the trace's last calls",
      proc(s: Snapshot): bool = s.text(Rows - 1).contains("of 46"))
    sleep(500)
    var found = false
    for _ in 0 ..< 40:
      s = sess.snap()
      for r in calls.top .. calls.bottom:
        if s.cells(r, calls.left, calls.width).contains("reached_the_bottom"):
          found = true
      if found: break
      sess.mouse(67, calls.top + 2, calls.left + 4)
      sleep(150)
    checkpoint(s.dump)
    ck found
    # The floor keeps the name whole (§5.5.3): the row shows all of
    # `reached_the_bottom`, then either the rest of its text or the `…` that
    # says there is more.
    var whole = false
    for r in calls.top .. calls.bottom:
      let line = s.cells(r, calls.left, calls.width)
      if line.contains("reached_the_bottom…") or
         line.contains("reached_the_bottom #"):
        whole = true
    ck whole

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
