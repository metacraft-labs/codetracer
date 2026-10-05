## test_plat49_panes.nim — PLAT-49 part B, Tier 2. **The terminal's panes as
## the user asked for them on 2026-10-01**, read back from a real terminal: the
## shipped `codetracer-tui` on the `calc` recording in a real PTY (TermAssert
## + libvterm), a real `replay-server` behind it, driven by the bytes a
## terminal sends — keys, SGR-1006 presses and `?1003` motion reports.
##
##   8. CALL TRACE — the rows carry the desktop's parts: arguments with their
##      values (`evaluate #2(expression="2 + 3")`), the return value
##      (` => 5`), the toggle (expanded / collapsed / leaf); the call the
##      debugger is in, bold on the active-row ground; a click on a row GOES there
##      (the tick moves); a click on a toggle collapses that call's children
##      and a second one expands them again.
##   9. FOOTER — the auto-hide labels are on the STATUS ROW (the last row),
##      left of the mode indicator; hovering a label shows its pane as an
##      overlay only after a moment, leaving closes it a moment later; a CLICK
##      docks the pane open — the arrangement gives up rows for it, nothing is
##      drawn over it — and a second click closes it.
##  11. DROP ZONES — dragging a tab over a pane: its centre would JOIN the
##      stack, a quarter of its width from the left would split on the left;
##      a release at the centre joins.
##  14. EVENT LOG — a header of the visible columns (tick, #, kind, output),
##      no file:line by default; `:column-show location` shows it,
##      `:column-left output` moves output left.
##   2. CLICKS SAY NOTHING — a tab click activates the tab and writes no
##      layout command on the status line.
##
## The review (2026-10-03) adds: the status row in the DESKTOP'S ORDER (the
## file info — `Python | UTF-8` — first, then the labels, then the mode);
## the call the debugger is in on the active-row ground; a drag over the
## layout's own right edge splitting the WHOLE layout (GoldenLayout's ground
## band); and the strip's "+" — the omnibar on `:open `, a second recording
## opened in its own tab with its own engine, a tab click switching the
## panes, its close control stopping that engine.
##
## No mocks: the real binary, a real recording, a real engine, a real pty.

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
from ../../app/views/shell import DividerGlyph
import ../../../styles/generated/design_tokens

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 71
  ## 67 -> 71 (2026-10-04): the call-trace rows are found by what each call
  ## is, and the first descent's numbers are asserted to follow one another
  ## (+3), and the root row found before its colours are read (+1).

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  StatusRow = Rows - 1

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc open(args: seq[string] = @[]): TuiTestSession =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded
  inc spawned
  let state = getTempDir() / ("plat49b-pty-" & $getCurrentProcessId() & "-" &
                              $spawned)
  removeDir(state)
  createDir(state)
  result = newTuiTest(tuiBinary(), @["--theme=dark"] & args &
                                   @[resolved.tracePath])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
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

proc cellFind(line, needle: string; start = 0): int =
  let at = line.find(needle, start)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc rowText(sess: var TuiTestSession; row: int): string =
  discard sess.drainOutput(40)
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc findRow(s: Snapshot; needle: string; below = Rows): (int, int) =
  ## The first row above `below` holding `needle`, and its column.
  for r in 0 ..< min(below, Rows):
    let c = s.text(r).cellFind(needle)
    if c >= 0:
      return (r, c)
  (-1, -1)

proc findCall(s: Snapshot; head, args: string; below = Rows):
    tuple[row, col, index: int] =
  ## The call-trace row that reads `head`, a number, then `args` — e.g.
  ## `findCall(s, "▾ evaluate #", "(expression=\"2 +")` — its row, the column
  ## `head` starts at, and the call's number. Found by WHAT the call is, not
  ## by its number: the number depends on the frames the recorder wraps the
  ## program in (the Python recorder roots the trace in `<toplevel>` above the
  ## `<__main__>` module frame).
  for r in 0 ..< min(below, Rows):
    let line = s.text(r)
    var at = line.find(head)
    while at >= 0:
      var i = at + head.len
      var n = ""
      while i < line.len and line[i].isDigit:
        n.add line[i]
        inc i
      if n.len > 0 and line.continuesWith(args, i):
        return (r, line[0 ..< at].runeLen, parseInt(n))
      at = line.find(head, at + 1)
  (-1, -1, -1)

proc waitFor(sess: var TuiTestSession; needle: string; present = true;
             timeoutMs = 20000; below = Rows): (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let at = sess.snap().findRow(needle, below)
    if (at[0] >= 0) == present:
      return at
    sleep(40)
  raise newException(AssertionFailedError,
    (if present: "never showed '" else: "kept showing '") & needle & "'")

proc waitForCall(sess: var TuiTestSession; head, args: string; present = true;
                 timeoutMs = 20000): tuple[row, col, index: int] =
  ## `findCall`, waited for (or, with `present = false`, waited away).
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let at = sess.snap().findCall(head, args)
    if (at.row >= 0) == present:
      return at
    sleep(40)
  raise newException(AssertionFailedError,
    (if present: "never showed '" else: "kept showing '") & head & "…" &
    args & "'")

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc click(sess: var TuiTestSession; row, col: int) =
  sess.mouse(0, row, col)
  sess.mouse(0, row, col, release = true)

proc hover(sess: var TuiTestSession; row, col: int) =
  ## A `?1003` motion report with no button held.
  sess.mouse(35, row, col)

proc quit(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

proc tickOf(line: string): int =
  ## The header's `tick: N`.
  let at = line.find("tick: ")
  if at < 0: return -1
  var i = at + 6
  var n = ""
  while i < line.len and line[i].isDigit:
    n.add line[i]
    inc i
  if n.len == 0: -1 else: parseInt(n)

suite "PLAT-49 part B on a real terminal: the call trace's rows":

  test "the rows carry arguments, returns and toggles; the current call selected":
    var sess = open()
    let ev = sess.waitForCall("▾ evaluate #", "(expression=\"2 +")
    ck ev.row > 0
    let s = sess.snap()
    let main = s.findCall("▾ main #", "() => @[5, 7, 42")
    let op = s.findCall("▾ apply_op #", "(symbol=\"+\", l")
    let add = s.findCall("· add #", "(left=2, right=3)")
    ck main.row > 0
    ck op.row > 0
    ck add.row > 0
    # One call after another down the first descent: main, the first
    # evaluate, its apply_op, its add.
    ck ev.index == main.index + 1
    ck op.index == ev.index + 1
    ck add.index == op.index + 1
    ck s.findCall("▾ <__main__> #", "()").row > 0
    # The pane is narrower than these rows: a wider terminal shows the
    # returns of the deeper calls too (the shell suite reads whole rows).
    # The current call — the debugger is at the entry, in the module's
    # frame — is the desktop's selected row: bold, on the design system's active-row
    # ground (ui/surface/primary/secondary-hover, #333333 Dark), the other
    # rows on the pane's own (#282828).
    # The current call at the entry is the call that encloses `main` — the
    # module's frame, one row above it on the first descent.
    let entryHead = " #" & $(main.index - 1) & "("
    var (r0, c0) = (-1, -1)
    for r in 0 ..< Rows:
      let line = s.text(r)
      let at = line.find("▾ <")
      if at >= 0 and line.find(entryHead, at) > at:
        (r0, c0) = (r, line[0 ..< at].runeLen + 2)
        break
    let (r4, c4) = (add.row, add.col + 2)
    ck r0 > 0
    ck s[r0][c0].bgHex == "#333333"
    ck s[r4][c4].bgHex == "#282828"
    ck caBold in s[r0][c0 + 2].attrs
    ck caBold notin s[r4][c4 + 2].attrs
    sess.quit()

  test "a click on a row goes to that call; a toggle collapses and expands":
    var sess = open()
    let add = sess.waitForCall("· add #", "(left=2, right=3)")
    let addText = "add #" & $add.index & "(left=2, right=3)"
    # The entry stop's tick (the program's first step, after the trace
    # format's `<toplevel>` entry step): read, so the jump below is measured
    # from it.
    let before = sess.rowText(0).tickOf
    ck before >= 0
    let (ra, ca) = (add.row, add.col + 2)
    sess.click(ra, ca + 2)
    let deadline = getMonoTime() + initDuration(seconds = 20)
    var after = before
    while getMonoTime() < deadline and after == before:
      sleep(100)
      after = sess.rowText(0).tickOf
    checkpoint("tick " & $before & " -> " & $after)
    ck after > before
    # The status line echoes nothing for the click.
    ck not sess.rowText(StatusRow).contains("calltrace")
    # Collapse add's apply_op: its child add goes, the toggle reads ▸.
    let s2 = sess.snap()
    let opHead = "apply_op #" & $(add.index - 1) & "("
    let (rt, ct) = s2.findRow("▾ " & opHead)
    ck rt > 0
    sess.click(rt, ct)
    discard sess.waitFor("▸ " & opHead)
    discard sess.waitFor(addText, present = false)
    let (rt2, ct2) = sess.snap().findRow("▸ " & opHead)
    ck rt2 == rt and ct2 == ct
    sess.click(rt2, ct2)
    discard sess.waitFor("▾ " & opHead)
    let (r4, _) = sess.waitFor(addText)
    ck r4 == rt + 1
    sess.quit()

suite "PLAT-49 part B on a real terminal: the event log's columns":

  test "a header of tick, #, kind, output; location only when shown":
    var sess = open()
    let (hr, hc) = sess.waitFor("tick    # kind output")
    ck hr > 0
    let s = sess.snap()
    ck s.findRow("2 + 3 = 5")[0] == hr + 1
    ck s.findRow("main.py:111")[0] < 0
    ck not s.text(hr).contains("location")
    sess.send(":column-show location\r")
    discard sess.waitFor("main.py:111")
    let s2 = sess.snap()
    ck s2.text(hr).contains("location")
    ck s2.text(hr).cellFind("location") < s2.text(hr).cellFind("kind")
    # The choice survives a step: the log is rebuilt at every stop, the
    # columns are the user's.
    let before = sess.rowText(0).tickOf
    sess.send("n")
    let deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline and sess.rowText(0).tickOf == before:
      sleep(100)
    ck sess.rowText(0).tickOf != before
    ck sess.snap().text(hr).contains("location")
    ck sess.snap().findRow("main.py:111")[0] > hr
    sess.send(":column-left output\r")
    let (_, _) = sess.waitFor("output kind")
    ck sess.rowText(StatusRow).contains("event log columns")
    sess.send(":column-hide nope\r")
    discard sess.waitFor("no event log column 'nope'")
    ck hc >= 0
    sess.quit()

suite "PLAT-49 part B on a real terminal: the footer's auto-hide panels":

  test "the labels are on the status row; a hover previews after a moment":
    var sess = open()
    let last = sess.rowText(StatusRow)
    # THE DESKTOP'S ORDER: the file info first, then the labels, then the
    # status text (the review's fix; the desktop's status bar measured).
    ck last.startsWith(" Python | UTF-8   BUILD  PROBLEMS  FIND IN FILES  REQUESTS")
    ck last.contains("NORMAL")
    ck last.cellFind("NORMAL") > last.cellFind("REQUESTS")
    ck not sess.rowText(StatusRow - 1).contains("PROBLEMS")
    let buildCol = last.cellFind("BUILD")
    # The pointer onto BUILD: nothing at once.
    let t0 = getMonoTime()
    sess.hover(StatusRow, buildCol + 1)
    sleep(100)
    let early = sess.snap()
    ck early.findRow(" BUILD ", below = StatusRow)[0] < 0
    # …the overlay after the preview delay: the build pane, over the body.
    let (br, bc) = sess.waitFor(" BUILD ", timeoutMs = 3000, below = StatusRow)
    let waited = (getMonoTime() - t0).inMilliseconds
    checkpoint("preview after " & $waited & " ms")
    ck waited >= 250
    ck br > StatusRow div 2 and bc == 0
    ck sess.snap().findRow("no build has been run", below = StatusRow)[0] > br
    # Off the label and the overlay: still shown a moment later, then gone.
    sess.hover(10, 100)
    sleep(60)
    ck sess.snap().findRow(" BUILD ", below = StatusRow)[0] == br
    discard sess.waitFor(" BUILD ", present = false, timeoutMs = 3000,
                         below = StatusRow)
    sess.quit()

  test "a click docks the pane open in the arrangement; a second closes it":
    var sess = open()
    let s0 = sess.snap()
    let buildCol = s0.text(StatusRow).cellFind("BUILD")
    ck buildCol > 0
    # Before: the editor runs to the row above the status line (its left
    # divider is PLAT-50's `DividerGlyph`).
    ck s0.text(StatusRow - 1).contains(DividerGlyph & "  47 ")
    sess.click(StatusRow, buildCol + 1)
    let (br, bc) = sess.waitFor(" BUILD ", timeoutMs = 5000, below = StatusRow)
    ck br > StatusRow div 2 and bc == 0
    let s1 = sess.snap()
    # DOCKED, NOT OVER THE ARRANGEMENT: the band runs to the status line, and
    # the arrangement ends above it — the editor's last rows are gone, not
    # covered (the row above the band is still the editor's, renumbered
    # nothing: it is line `br - 2`'s).
    ck s1.text(br - 1).contains(DividerGlyph & "  " & $(br - 2) & " ")
    ck not s1.text(StatusRow - 1).contains(DividerGlyph & "  47 ")
    ck s1.findRow("no build has been run", below = StatusRow)[0] > br
    # The label lit while its pane is open.
    ck s1[StatusRow][buildCol + 1].bgHex ==
       DesignTokenHex[dtColorsUiSurfacePrimaryTertiary][dmDark]
    # The status line says nothing about the click.
    ck not sess.rowText(StatusRow).contains("openDocked")
    # It stays without the pointer on it (docked, not a preview).
    sess.hover(10, 100)
    sleep(900)
    ck sess.snap().findRow(" BUILD ", below = StatusRow)[0] == br
    sess.click(StatusRow, buildCol + 1)
    discard sess.waitFor(" BUILD ", present = false, timeoutMs = 5000,
                         below = StatusRow)
    ck sess.snap().text(StatusRow - 1).contains(DividerGlyph & "  47 ")
    sess.quit()

suite "PLAT-49 part B on a real terminal: GoldenLayout's drop zones":

  test "the centre joins the stack, a quarter from the left splits":
    var sess = open()
    let s = sess.snap()
    let (tr, tc) = s.findRow(" Call Trace ")
    let (vr, vc) = s.findRow(" Variables ")
    ck tr > 0 and vr > 0
    # Pick up the Call Trace tab: a press, then motion past the threshold.
    sess.mouse(0, tr, tc + 2)
    sess.mouse(32, tr + 1, tc + 8)
    # The Variables pane's body: its strip row + 1 to the divider, between
    # its left divider and the Call Trace stack.
    let bodyTop = vr + 1
    let bodyBottom = vr + 18
    let bodyLeft = vc - 1
    let bodyRight = tc - 3
    let midRow = (bodyTop + bodyBottom) div 2
    let midCol = (bodyLeft + bodyRight) div 2
    sess.mouse(32, midRow, midCol)
    discard sess.waitFor("would intoStack(state", timeoutMs = 5000)
    sess.mouse(32, midRow, bodyLeft + 1)
    discard sess.waitFor("would splitBefore(state", timeoutMs = 5000)
    sess.mouse(32, midRow, midCol)
    discard sess.waitFor("would intoStack(state", timeoutMs = 5000)
    sess.mouse(0, midRow, midCol, release = true)
    discard sess.waitFor("applied", timeoutMs = 5000)
    ck sess.rowText(StatusRow).contains("moveTab(calltrace")
    sess.quit()

suite "PLAT-49 part B review on a real terminal: the layout's own edge":

  test "a drag to the layout's right edge splits the whole layout there":
    var sess = open()
    let s = sess.snap()
    let (tr, tc) = s.findRow(" Call Trace ")
    ck tr > 0
    # Pick up the Event Log tab, and carry it over the Call Trace stack's
    # body near the screen's right edge — the layout's own edge: GoldenLayout's
    # ground band (50 px, five columns here), a split of the WHOLE layout.
    let (er, ec) = s.findRow(" Event Log ")
    ck er > 0
    sess.mouse(0, er, ec + 2)
    sess.mouse(32, er - 1, ec + 8)
    let row = tr + 6
    sess.mouse(32, row, Cols - 3)
    discard sess.waitFor("would splitRoot(right)", timeoutMs = 5000)
    # The band is five cells deep: eight in from the edge is the stack's own
    # right quarter again.
    sess.mouse(32, row, Cols - 8)
    discard sess.waitFor("would splitAfter(calltrace", timeoutMs = 5000)
    sess.mouse(32, row, Cols - 3)
    discard sess.waitFor("would splitRoot(right)", timeoutMs = 5000)
    sess.mouse(0, row, Cols - 3, release = true)
    discard sess.waitFor("applied", timeoutMs = 5000)
    ck sess.rowText(StatusRow).contains("splitRoot(eventLog, row, after)")
    # The event log is the layout's right side now: its tab on the top
    # strip row, at the right, the full height below it.
    let after = sess.snap()
    let (nr, nc) = after.findRow(" Event Log ")
    ck nr == 1
    ck nc > Cols div 2
    sess.quit()

suite "PLAT-49 part B review on a real terminal: the strip's +":

  test "a recording opened in a new tab, switched to and back, closed":
    var sess = open()
    let row0 = sess.rowText(0)
    let plus = row0.cellFind(" + ")
    ck plus > 0
    # One session: no tab drawn, the "+" alone (the desktop's single-session).
    ck not row0.contains(" × ")
    let before = replayServerPids().len
    sess.click(0, plus + 1)
    discard sess.waitFor(":open", timeoutMs = 5000, below = 1)
    discard sess.waitFor("call_pages-", timeoutMs = 5000)
    ck sess.rowText(StatusRow).contains("new tab: choose a recording")
    # Type the recording's own name: the list narrows to it.
    for ch in "call_pages": sess.send($ch)
    discard sess.waitFor(":open call_pages", timeoutMs = 5000, below = 1)
    sess.send("\r")
    # Its own tab, its own engine, its own panes.
    discard sess.waitFor("call_pages-d6745afd1e2e ×", timeoutMs = 30000,
                         below = 1)
    discard sess.waitForCall("step #", "(i=0)", timeoutMs = 30000)
    ck sess.rowText(0).contains("calc-")
    ck sess.rowText(0).contains("trace: call_pages")
    ck replayServerPids().len == before + 1
    # The first tab: calc's panes again.
    let (_, c0) = sess.snap().findRow("calc-2f0")
    ck c0 > 0
    sess.click(0, c0 + 2)
    discard sess.waitForCall("evaluate #", "(expression=", timeoutMs = 20000)
    ck sess.rowText(0).contains("trace: calc-")
    ck sess.snap().findCall("step #", "(i=0)").row < 0
    # Close the second: its engine stops; one session, the "+" alone.
    let line = sess.rowText(0)
    let at = line.cellFind("call_pages-d6745afd1e2e ×")
    ck at > 0
    sess.click(0, at + "call_pages-d6745afd1e2e ".len)
    discard sess.waitFor(" × ", present = false, timeoutMs = 10000, below = 1)
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while getMonoTime() < deadline and replayServerPids().len > before:
      sleep(100)
    ck replayServerPids().len == before
    ck sess.rowText(0).cellFind(" + ") > 0
    sess.quit()

suite "PLAT-49 part B on a real terminal: a tab click says nothing":

  test "a tab click activates it and writes no layout command":
    var sess = open()
    let (sr, sc) = sess.snap().findRow(" Scratchpad ")
    ck sr > 0
    sess.click(sr, sc + 2)
    sleep(600)
    let line = sess.rowText(StatusRow)
    ck not line.contains("activateTab")
    ck not line.contains("applied")
    sess.quit()

suite "PLAT-49 part B real terminal: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
