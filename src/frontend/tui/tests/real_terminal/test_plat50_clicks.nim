## test_plat50_clicks.nim — PLAT-50 deliverable 3, Tier 2. **The desktop's
## click behaviours, in a real terminal** (the user, 2026-10-02: "clicking a
## file in Files should open it; clicking a call-trace row should navigate to
## that moment in time; clicking an event-log row likewise … a full sweep that
## focuses on the click behaviors of the Electron GUI").
##
## The shipped `codetracer-tui` on a real recording in a real PTY (TermAssert +
## libvterm), a real `replay-server` behind it, driven by the bytes a terminal
## sends: SGR-1006 presses — left, right (button 2), middle (button 1),
## Ctrl+left (16), Alt+left (8), Ctrl+Alt+left (24), button-event motion (32)
## and releases — and keys; what the terminal copies is read back from the
## OSC 52 sequences it writes. One test per row of the milestone's click
## table that the terminal implements (`headless_app/pane_clicks.
## ClickInventory`, rows marked `done`), each asserting the click's
## observable effect: the editor shows the clicked file; the tick and the
## pointer move to the clicked call, event, line or time; the gutter's
## breakpoint mark appears, dims and the replay honours it; a value expands;
## a context menu shows the desktop's entries and its chosen entry does what
## the desktop's does.
##
## No mocks: the real binary, real recordings (`calc`, and `multi_root` for a
## second file to open), a real engine, a real pty, and for the VCS pane a
## real git repository (`scripts/plat47-vcs-fixture.sh`).

import std/[base64, monotimes, os, osproc, strutils, tempfiles, times, unicode,
            unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 112

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  StatusRow = Rows - 1
  RightButton = 2
  MiddleButton = 1
  CtrlLeft = 16
  AltLeft = 8
  CtrlAltLeft = 24

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc open(fixture = "calc"; args: seq[string] = @[];
          workDir = ""): TuiTestSession =
  let resolved =
    if fixture == "multi_root":
      resolveFixture(FixtureSpec(
        name: "multi_root",
        program: "test-programs/multi_root/app/main.py",
        recorder: "codetracer-python-recorder",
        probe: FixtureProbe(kind: pkPythonRecorder),
        buildHint: "Install codetracer_python_recorder into the interpreter " &
                   "`ct` will use.",
        blockedOn: ""))
    else: resolveFixture(fixture)
  doAssert resolved.outcome == foRecorded, resolved.detail
  inc spawned
  let state = getTempDir() / ("plat50-clicks-" & $getCurrentProcessId() &
                              "-" & $spawned)
  removeDir(state)
  createDir(state)
  var builder = newTuiTest(tuiBinary(), @["--theme=dark"] & args &
                                       @[resolved.tracePath])
  if workDir.len > 0:
    builder = builder.workDir(workDir)
  result = builder
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

proc findRow(s: Snapshot; needle: string; below = Rows;
             fromCol = 0): (int, int) =
  ## The first row above `below` holding `needle` at or right of `fromCol`.
  for r in 0 ..< min(below, Rows):
    let line = s.text(r)
    var c = line.cellFind(needle)
    while c >= 0 and c < fromCol:
      let byteAt = line.find(needle, line.runeOffset(c) + 1)
      c = if byteAt < 0: -1 else: line[0 ..< byteAt].runeLen
    if c >= 0:
      return (r, c)
  (-1, -1)

proc waitFor(sess: var TuiTestSession; needle: string; present = true;
             timeoutMs = 20000; below = Rows; fromCol = 0): (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let at = sess.snap().findRow(needle, below, fromCol)
    if (at[0] >= 0) == present:
      return at
    sleep(40)
  raise newException(AssertionFailedError,
    (if present: "never showed '" else: "kept showing '") & needle & "'")

proc waitForCall(sess: var TuiTestSession; head, args: string;
                 present = true): (int, int) =
  ## The call-trace row that starts with `head` (its toggle and name, e.g.
  ## "· add #") and lists `args` — found by WHAT the call is, not by its
  ## number, which depends on the frames the recorder wraps the program in.
  let deadline = getMonoTime() + initDuration(milliseconds = 20000)
  while getMonoTime() < deadline:
    let s = sess.snap()
    var found = (-1, -1)
    for r in 0 ..< Rows:
      let t = s.text(r)
      let a = t.find(args)
      let h = t.find(head)
      if a > 0 and h >= 0 and h < a:
        found = (r, t[0 ..< h].runeLen)
        break
    if (found[0] >= 0) == present:
      return found
    sleep(40)
  raise newException(AssertionFailedError,
    (if present: "never showed '" else: "kept showing '") & head & "…" &
    args & "'")

proc overlayRowsBelow(sess: var TuiTestSession; titleRow: int;
                      accept: proc(line: string): bool;
                      timeoutMs = 20000): bool =
  ## Whether a line of the content overlay below `titleRow` (its text after
  ## the frame's "│ ") satisfies `accept` — read from the overlay alone, not
  ## from the panes beside or behind it.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let s = sess.snap()
    for r in titleRow + 1 ..< min(Rows, titleRow + 12):
      let t = s.text(r)
      let at = t.find("│ ")
      if at >= 0 and accept(t[at + "│ ".len .. ^1]):
        return true
    sleep(40)
  false

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int; code = 0) =
  sess.mouse(code, row, col)
  sess.mouse(code, row, col, release = true)

proc quit(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc fgHex(c: Cell): string =
  if c.fg.kind == ckRgb: hexOf((c.fg.r.int, c.fg.g.int, c.fg.b.int)) else: ""

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

proc waitTick(sess: var TuiTestSession; changedFrom: int;
              timeoutMs = 20000): int =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  result = sess.rowText(0).tickOf
  while getMonoTime() < deadline and result == changedFrom:
    sleep(80)
    result = sess.rowText(0).tickOf

proc editorRowOfLine(s: Snapshot; line: int): (int, int) =
  ## The screen row the editor draws source line `line` on, and the column
  ## of its number — the gutter's line-number field, right of the Files
  ## pane's divider.
  let needle = " " & $line & " "
  for r in 2 ..< Rows - 1:
    let t = s.text(r)
    let bar = t.cellFind("▏")
    if bar < 0: continue
    let c = t.cellFind(needle, t.runeOffset(bar))
    if c >= 0 and c < bar + 8:
      return (r, c + 1)
  (-1, -1)

proc pointerLine(s: Snapshot): int =
  ## The source line the execution pointer `-->` is on, or -1.
  for r in 2 ..< Rows - 1:
    let t = s.text(r)
    let at = t.cellFind("-->")
    if at > 0:
      var digits = ""
      var i = at - 1
      let runes = t.toRunes
      while i >= 0 and runes[i] == Rune(' '): dec i
      while i >= 0 and ($runes[i])[0].isDigit:
        digits = $runes[i] & digits
        dec i
      if digits.len > 0: return parseInt(digits)
  -1

suite "PLAT-50 on a real terminal: Files (K17, K18, K19)":

  test "a file click opens it in the editor; a folder click collapses it":
    var sess = open("multi_root")
    let (rh, ch) = sess.waitFor("helpers.py", below = Rows - 1)
    ck rh > 1
    # The editor opens on the runner; helpers.py is a file of the tree.
    ck not sess.snap().text(1).contains(" helpers.py ")
    sess.press(rh, ch + 2)
    discard sess.waitFor("def add(left, right):")
    let s = sess.snap()
    # The editor's tab names the opened file, and the status line says so.
    ck s.text(1).contains(" helpers.py ")
    ck sess.rowText(StatusRow).contains("opened ")
    # A folder: `shared` collapses (its files go, its twisty turns) and
    # expands again.
    let (rs, cs) = sess.snap().findRow("▼ shared")
    ck rs > 1
    sess.press(rs, cs + 3)
    discard sess.waitFor("▶ shared")
    ck sess.snap().findRow("extra.py")[0] < 0
    sess.press(rs, cs + 3)
    discard sess.waitFor("▼ shared")
    ck sess.snap().findRow("extra.py")[0] > rs
    sess.quit()

  test "a right-click on a node opens no menu (the desktop has none)":
    var sess = open()
    let (rm, cm) = sess.waitFor("    main.py", below = Rows - 1)
    ck cm < 20
    sess.press(rm, cm + 5, RightButton)
    # Give a menu the time it would take to appear, then look for its frame
    # and the four entries the desktop used to offer.
    sleep(600)
    let s = sess.snap()
    for label in ["Create", "Rename", "Delete", "Edit"]:
      ck s.findRow(label)[0] < 0
    ck s.findRow("┌")[0] < 0
    sess.quit()

suite "PLAT-50 on a real terminal: the editor (K10-K13)":

  test "a gutter click sets a breakpoint the replay stops at; a right click disables it":
    var sess = open()
    discard sess.waitFor("return left + right")
    let (r31, c31) = sess.snap().editorRowOfLine(31)
    ck r31 > 1
    sess.press(r31, c31)
    discard sess.waitFor("● 31")
    let t0 = sess.rowText(0).tickOf
    sess.send("c")
    let t1 = sess.waitTick(t0)
    ck t1 > t0
    discard sess.waitFor("-->")
    ck sess.snap().pointerLine == 31
    # Right click on the gutter: disabled (dimmed), kept in the gutter.
    let (r31b, c31b) = sess.snap().editorRowOfLine(31)
    sess.press(r31b, c31b, RightButton)
    discard sess.waitFor("○ 31")
    ck sess.rowText(StatusRow).contains("disabled the breakpoint at line 31")
    # The replay no longer stops there: continue runs to the end.
    sess.send("c")
    let t2 = sess.waitTick(t1)
    ck t2 == 171
    sess.quit()

  test "Ctrl+click and a middle click on a line go to it; the status line says where":
    var sess = open()
    discard sess.waitFor("return left + right")
    let (r31, c31) = sess.snap().editorRowOfLine(31)
    sess.press(r31, c31 + 12, CtrlLeft)
    discard sess.waitFor("--> ", timeoutMs = 20000)
    var deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline and sess.snap().pointerLine != 31:
      sleep(80)
    ck sess.snap().pointerLine == 31
    ck sess.rowText(StatusRow).contains("main.py:31")
    ck sess.rowText(0).tickOf > 0
    let (r36, c36) = sess.snap().editorRowOfLine(36)
    ck r36 > 1
    sess.press(r36, c36 + 12, MiddleButton)
    deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline and sess.snap().pointerLine != 36:
      sleep(80)
    ck sess.snap().pointerLine == 36
    ck sess.rowText(StatusRow).contains("main.py:36")
    sess.quit()

  test "a right click in the text: the desktop's menu, and Run to Cursor runs there":
    var sess = open()
    discard sess.waitFor("return left + right")
    let (r31, c31) = sess.snap().editorRowOfLine(31)
    sess.press(r31, c31 + 12, RightButton)
    let (rc, cc) = sess.waitFor("Run to Cursor")
    let s = sess.snap()
    # The desktop's entries, in its order (`plat50-desktop.electron.json`,
    # `menus.editorText`).
    let (rcopy, ccopy) = s.findRow("Copy", fromCol = cc - 4)
    var order: seq[int] = @[]
    for label in ["Find", "Jump to line", "Run to Cursor",
                  "Jump backward to line", "Jump to call",
                  "Jump forward to call", "Jump backward to call",
                  "Add breakpoint", "Add tracepoint"]:
      order.add s.findRow(label, fromCol = cc - 4)[0]
    ck rcopy >= 0
    ck order == @[rcopy + 1, rcopy + 2, rcopy + 3, rcopy + 4, rcopy + 5,
                  rcopy + 6, rcopy + 7, rcopy + 8, rcopy + 9]
    ck rc == rcopy + 3
    # Every entry is enabled, as on the desktop: none drawn in the
    # disabled (italic) tier.
    ck caItalic notin s[rcopy][ccopy].attrs
    let (rjc, cjc) = s.findRow("Jump to call", fromCol = cc - 4)
    ck caItalic notin s[rjc][cjc].attrs
    let (rat, cat) = s.findRow("Add tracepoint", fromCol = cc - 4)
    ck caItalic notin s[rat][cat].attrs
    ck caItalic notin s[rc][cc].attrs
    # The menu is framed in the desktop's dropdown border.
    ck s.findRow("┌", fromCol = cc - 4)[0] == rcopy - 1
    sess.press(rc, cc + 2)
    var deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline and sess.snap().pointerLine != 31:
      sleep(80)
    ck sess.snap().pointerLine == 31
    ck sess.snap().findRow("Run to Cursor")[0] < 0
    sess.quit()

  test "the menu on a breakpoint's line: disable, delete, and delete them all":
    var sess = open()
    discard sess.waitFor("return left + right")
    let (r31, c31) = sess.snap().editorRowOfLine(31)
    sess.press(r31, c31)
    discard sess.waitFor("● 31")
    sess.press(r31, c31 + 12, RightButton)
    let (rd, cd) = sess.waitFor("Disable breakpoint")
    let s = sess.snap()
    ck s.findRow("Delete breakpoint", fromCol = cd - 2)[0] == rd + 1
    ck s.findRow("Delete breakpoints in file", fromCol = cd - 2)[0] == rd + 2
    ck s.findRow("Delete ALL breakpoints", fromCol = cd - 2)[0] == rd + 3
    ck s.findRow("Add breakpoint", fromCol = cd - 2)[0] < 0
    sess.press(rd, cd + 2)
    discard sess.waitFor("○ 31")
    sess.press(r31, c31 + 12, RightButton)
    let (ra, ca) = sess.waitFor("Delete ALL breakpoints")
    ck sess.snap().findRow("Enable breakpoint", fromCol = ca - 2)[0] == ra - 3
    sess.press(ra, ca + 2)
    discard sess.waitFor("○ 31", present = false)
    ck sess.rowText(StatusRow).contains("deleted the breakpoints")
    sess.quit()

suite "PLAT-50 on a real terminal: the event log (K24, K25)":

  test "a click on an event goes to it; a right click shows its whole content":
    var sess = open()
    let (re, ce) = sess.waitFor("10 - 4 + 1 = 7")
    let t0 = sess.rowText(0).tickOf
    sess.press(re, ce + 2)
    let t1 = sess.waitTick(t0)
    ck t1 == 68
    ck sess.rowText(StatusRow).contains("tick 68")
    ck sess.snap().pointerLine == 111
    let (rr, cr) = sess.snap().findRow("6 * 7 = 42")
    sess.press(rr, cr + 2, RightButton)
    let (ro, _) = sess.waitFor("event #2 at tick 88")
    ck ro > 0
    # The content inside the overlay (its own row, under the title).
    ck sess.snap().findRow("6 * 7 = 42")[0] > ro
    ck sess.rowText(0).tickOf == 68
    sess.send("\x1b")
    discard sess.waitFor("event #2 at tick 88", present = false)
    sess.quit()

suite "PLAT-50 on a real terminal: the call trace's menu (K22)":

  test "right-click a call: Collapse Call Children, and choosing it collapses":
    var sess = open()
    # A leaf's menu offers expanding, disabled (it made no calls).
    let (rl, cl) = sess.waitForCall("· add #", "(left=2, right=3)")
    ck rl > 0
    sess.press(rl, cl + 4, RightButton)
    let (rx, cx) = sess.waitFor("Expand Call Children")
    ck caItalic in sess.snap()[rx][cx].attrs
    sess.send("\x1b")
    discard sess.waitFor("Expand Call Children", present = false)
    let (ra, ca) = sess.waitForCall("▾ apply_op #", "(symbol=\"+\", left=2")
    sess.press(ra, ca + 4, RightButton)
    let (rc, cc) = sess.waitFor("Collapse Call Children")
    let s = sess.snap()
    # The desktop's menu: the one entry ("Expand Full Callstack" was
    # removed — it could change nothing), enabled.
    ck s.findRow("Expand Full Callstack")[0] < 0
    ck caItalic notin s[rc][cc].attrs
    sess.press(rc, cc + 2)
    discard sess.waitForCall("▸ apply_op #", "(symbol=\"+\", left=2")
    discard sess.waitForCall("· add #", "(left=2, right=3)", present = false)
    sess.quit()

suite "PLAT-50 on a real terminal: a tab's menu (K7)":

  test "right-click a tab: pin, close, maximise; Close removes it":
    var sess = open()
    let (rv, cv) = sess.waitFor(" VCS ")
    ck rv == 1
    sess.press(rv, cv + 2, RightButton)
    let (rp, _) = sess.waitFor("Pin to Left")
    let s = sess.snap()
    ck s.findRow("Pin to Bottom")[0] == rp + 1
    ck s.findRow("Pin to Right")[0] == rp + 2
    ck s.findRow("Close")[0] == rp + 3
    ck s.findRow("Maximise container")[0] == rp + 4
    let (rcl, ccl) = s.findRow("Close")
    sess.press(rcl, ccl + 1)
    discard sess.waitFor("Pin to Left", present = false)
    var deadline = getMonoTime() + initDuration(seconds = 10)
    while getMonoTime() < deadline and sess.rowText(1).contains(" VCS "):
      sleep(80)
    ck not sess.rowText(1).contains(" VCS ")
    ck sess.rowText(1).contains(" Files ")
    sess.quit()

suite "PLAT-50 on a real terminal: Variables and the timeline (K27, K28, K30)":

  test "a click on a value expands it; a right click offers history and origin":
    var sess = open()
    sess.send(":goto 114\r")
    let (rx, cx) = sess.waitFor("▶ EXPRESSION")
    sess.press(rx, cx + 4)
    discard sess.waitFor("▼ EXPRESSION")
    ck sess.snap().findRow("[0]", fromCol = cx)[0] == rx + 1
    sess.press(rx, cx + 4)
    discard sess.waitFor("▶ EXPRESSION")
    sess.press(rx, cx + 4, RightButton)
    let (rh, ch) = sess.waitFor("Toggle value history")
    let s = sess.snap()
    let (ro, co) = s.findRow("Show value origin")
    ck ro == rh + 1
    ck caItalic notin s[rh][ch].attrs
    ck caItalic notin s[ro][co].attrs
    # Toggle value history: the value's recorded history (`ct/load-history`)
    # over the body — every value it had, with the tick of each.
    sess.press(rh, ch + 2)
    let (rt, _) = sess.waitFor("history of EXPRESSIONS (")
    ck rt > 0
    # A history row is `<tick>  <value>`, and the value is there (the
    # Variables pane beside it shows the same text, so the overlay's own
    # rows are read).
    ck sess.overlayRowsBelow(rt, proc(l: string): bool =
      let parts = l.strip.split("  ", maxsplit = 1)
      parts.len == 2 and parts[0].len > 0 and
        parts[0].allCharsInSet(Digits) and parts[1].strip.len > 0 and
        not parts[1].strip.startsWith("│"))
    sess.send("\x1b")
    discard sess.waitFor("history of EXPRESSIONS", present = false)
    # Show value origin: the chain the engine answers (`ct/originChain`),
    # hop by hop, over the body.
    sess.press(rx, cx + 4, RightButton)
    let (ro2, co2) = sess.waitFor("Show value origin")
    sess.press(ro2, co2 + 2)
    let (rg, _) = sess.waitFor("origin of EXPRESSIONS")
    # A hop: `tick N  kind  target <- source  file:line`.
    ck sess.overlayRowsBelow(rg, proc(l: string): bool =
      l.strip.startsWith("tick ") and l.contains(" <- "))
    sess.send("\x1b")
    discard sess.waitFor("origin of EXPRESSIONS", present = false)
    # And `:origin` — the walk, which froze the terminal before: it answers.
    sess.send(":origin EXPRESSIONS\r")
    discard sess.waitFor("EXPRESSIONS computed from", timeoutMs = 30000)
    sess.send("n")
    let t = sess.waitTick(114)
    ck t > 114
    sess.quit()

  test "`o` on the selected variable asks for its origin and answers":
    var sess = open()
    sess.send(":goto 114\r")
    let (rx, cx) = sess.waitFor("▶ EXPRESSION")
    sess.press(rx, cx + 4)                    # selects (and expands) it
    discard sess.waitFor("▼ EXPRESSION")
    sess.send("o")
    # The walk's first hop, as `:origin` answers it: no freeze on the query.
    discard sess.waitFor("EXPRESSIONS computed from", timeoutMs = 30000)
    ck true
    sess.quit()

  test "a click on the timeline's track seeks there":
    var sess = open()
    let (rt, ct) = sess.waitFor("Timeline")
    sess.press(rt, ct + 2)
    let (rb, _) = sess.waitFor("TIMELINE tick")
    ck rb == rt + 1
    let s = sess.snap()
    let track = s.text(rb + 1)
    let start = track.cellFind("[")
    let stop = track.cellFind("]")
    ck start > 0 and stop > start + 10
    let t0 = sess.rowText(0).tickOf
    # Four fifths of the way along: a tick near four fifths of 171.
    sess.press(rb + 1, start + 1 + (stop - start - 1) * 4 div 5)
    let t1 = sess.waitTick(t0)
    ck t1 > 120 and t1 < 150
    ck sess.rowText(StatusRow).contains("tick " & $t1)
    sess.quit()

suite "PLAT-50 on a real terminal: the call-trace click's status (F2)":

  test "after a click moves the debugger the status line says where it landed":
    var sess = open()
    let (ra, ca) = sess.waitForCall("· add #", "(left=2, right=3)")
    ck sess.rowText(StatusRow).contains("main.py:1 ")
    sess.press(ra, ca + 4)
    let t1 = sess.waitTick(0)
    ck t1 > 0
    var deadline = getMonoTime() + initDuration(seconds = 10)
    while getMonoTime() < deadline and
          not sess.rowText(StatusRow).contains("tick " & $t1):
      sleep(80)
    ck sess.rowText(StatusRow).contains("tick " & $t1)
    ck not sess.rowText(StatusRow).contains("main.py:1 ")
    sess.quit()

proc stepToAdd(sess: var TuiTestSession) =
  ## Into `add`'s body (line 31, `left: 2, right: 3` beside it).
  sess.send(":goto 32\r")
  discard sess.waitFor("--> def add(")
  sess.send("n")
  discard sess.waitFor("/* left: 2, right: 3 */")

proc osc52(sess: var TuiTestSession): seq[string] =
  ## Every text the terminal was asked to put on its clipboard (OSC 52).
  let bytes = sess.transcriptBytes()
  var at = 0
  while true:
    let start = bytes.find("\e]52;c;", at)
    if start < 0: break
    let stop = bytes.find("\a", start)
    if stop < 0: break
    result.add base64.decode(bytes[start + 7 ..< stop])
    at = stop + 1

suite "PLAT-50 on a real terminal: column breakpoints and call jumps (K14, K15)":

  test "Alt+click anchors a breakpoint at the column; the replay honours it":
    var sess = open()
    sess.stepToAdd()
    let (r31, _) = sess.snap().editorRowOfLine(31)
    let line = sess.snap().text(r31)
    let at = line.cellFind("left + right")
    ck at > 0
    sess.press(r31, at, AltLeft)
    discard sess.waitFor("a breakpoint at line 31, column 12")
    let s = sess.snap()
    # The gutter's mark, and the anchored cell underlined in the
    # breakpoint's colour (the desktop's `ct-column-breakpoint-marker`).
    ck s.text(r31).contains("● 31")
    ck s[r31][at].underline != usNone
    ck s[r31][at + 1].underline == usNone
    # `calc` records one step per statement, at its first column: a
    # breakpoint anchored at column 12 is never reached, so continuing from
    # the start runs to the end, where a line breakpoint would stop at 31.
    sess.send(":goto 0\r")
    discard sess.waitFor("tick: 0 ")
    sess.send("c")
    ck sess.waitTick(0) == 171
    sess.quit()

  test "Ctrl+Alt+click on a call goes into it; the menu's call jumps too":
    var sess = open()
    sess.send(":goto 21\r")
    discard sess.waitFor("--> def evaluate(")
    let (rc, cc) = sess.waitFor("total = apply_op(symbol")
    sess.press(rc, cc + 9, CtrlAltLeft)
    var deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline and sess.snap().pointerLine != 61:
      sleep(80)
    ck sess.snap().pointerLine == 61
    ck sess.rowText(StatusRow).contains("main.py:61")
    # A word no function is named: the engine finds no call of it ahead and
    # goes to the LINE (`dap_handler.get_call_target`'s fallback) — the
    # pointer on 85, not inside a call.
    sess.send(":goto 21\r")
    discard sess.waitFor("--> def evaluate(")
    let (rt, ct) = sess.waitFor("total = apply_op(symbol")
    sess.press(rt, ct + 2, CtrlAltLeft)
    deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline and sess.snap().pointerLine != 85:
      sleep(80)
    ck sess.snap().pointerLine == 85
    ck sess.rowText(StatusRow).contains("main.py:85")
    sess.send(":goto 21\r")
    discard sess.waitFor("--> def evaluate(")
    # The editor menu's "Jump to call" on the call's name.
    sess.press(rt, ct + 9, RightButton)
    let (rj, cj) = sess.waitFor("Jump to call")
    sess.press(rj, cj + 2)
    deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline and sess.snap().pointerLine != 61:
      sleep(80)
    ck sess.snap().pointerLine == 61
    sess.quit()

suite "PLAT-50 on a real terminal: the editor menu's Copy and Add tracepoint":

  test "Copy puts the line on the clipboard (OSC 52)":
    var sess = open()
    discard sess.waitFor("return left + right")
    let (r31, c31) = sess.snap().editorRowOfLine(31)
    sess.press(r31, c31 + 12, RightButton)
    let (rc, cc) = sess.waitFor("Copy")
    sess.press(rc, cc + 1)
    discard sess.waitFor("copied line 31")
    ck "    return left + right\n" in sess.osc52()
    sess.quit()

  test "Add tracepoint: the prompt, then the sweep's hits on that line":
    var sess = open()
    discard sess.waitFor("return left + right")
    let (r31, c31) = sess.snap().editorRowOfLine(31)
    sess.press(r31, c31 + 12, RightButton)
    let (ra, ca) = sess.waitFor("Add tracepoint")
    sess.press(ra, ca + 2)
    discard sess.waitFor(":tracepoint ")
    sess.send("log(left)\r")
    let (rh, _) = sess.waitFor("tracepoint `log(left)` at main.py:31")
    ck rh > 0
    # `add` ran three times on `calc`: three hits, each with its `left`.
    ck sess.snap().findRow("3 hit(s)")[0] == rh
    discard sess.waitFor("left = 2")
    discard sess.waitFor("left = 6")
    sess.send("\x1b")
    discard sess.waitFor("tracepoint `log(left)` at main.py", present = false)
    sess.quit()

suite "PLAT-50 on a real terminal: the scratchpad (K23, K33, K36)":

  test "an argument and an inline value pinned; a close button removes one":
    var sess = open()
    let (ra, ca) = sess.waitForCall("· add #", "(left=2, right=3)")
    let argAt = sess.snap().text(ra).cellFind("left=2")
    ck argAt > ca
    # On the argument's VALUE: the desktop's `.call-arg` is the name, the
    # `=` and the value together.
    sess.press(ra, argAt + "left=".len, RightButton)
    let (rm, cm) = sess.waitFor("Add value to scratchpad")
    sess.press(rm, cm + 2)
    discard sess.waitFor("added left to the scratchpad")
    # The inline value `right: 3`: Ctrl+click pins it; its menu offers the
    # desktop's three entries.
    sess.stepToAdd()
    let (rv, cv) = sess.waitFor("right: 3")
    sess.press(rv, cv + 1, RightButton)
    let (rj, _) = sess.waitFor("Jump to value")
    let menu = sess.snap()
    ck menu.findRow("Add value to scratchpad")[0] == rj + 1
    ck menu.findRow("Add all values to scratchpad")[0] == rj + 2
    sess.send("\x1b")
    discard sess.waitFor("Jump to value", present = false)
    sess.press(rv, cv + 1, CtrlLeft)
    discard sess.waitFor("added right to the scratchpad")
    # The Scratchpad tab: both pinned, each with its close button.
    let (rs, cs) = sess.waitFor(" Scratchpad ")
    sess.press(rs, cs + 2)
    let (rl, cl) = sess.waitFor("✕ left: 2")
    ck sess.snap().findRow("✕ right: 3")[0] == rl + 1
    sess.press(rl, cl)
    discard sess.waitFor("✕ left: 2", present = false)
    ck sess.snap().findRow("✕ right: 3")[0] == rl
    sess.quit()

suite "PLAT-50 on a real terminal: the event log's order (K26)":

  test "a header click orders the log by its column; again reverses it":
    var sess = open()
    let (rh, ch) = sess.waitFor("tick    # kind output")
    let col = sess.snap().text(rh).cellFind("output")
    sess.press(rh, col + 1)
    discard sess.waitFor("output ▲")
    discard sess.waitFor("event log ordered by output, ascending")
    var s = sess.snap()
    # By output: `1 + 2 * 3 …` first, `checksum = 73` last of the six.
    ck s.findRow("1 + 2 * 3 - 4 / 2 = 2")[0] == rh + 1
    ck s.findRow("checksum = 73")[0] == rh + 6
    # The `#` column keeps each event's number in the recorded log.
    ck s.text(rh + 1).contains(" 4 out")
    sess.press(rh, col + 1)
    discard sess.waitFor("output ▼")
    s = sess.snap()
    ck s.findRow("checksum = 73")[0] == rh + 1
    # A click on an event still goes to IT, whatever the order.
    let (re, ce) = s.findRow("6 * 7 = 42")
    sess.press(re, ce + 2)
    ck sess.waitTick(0) == 88
    sess.quit()

suite "PLAT-50 on a real terminal: the status line, a dock label, the timeline (K37, K42, K45)":

  test "a click on the status line copies the location":
    var sess = open()
    discard sess.waitFor("return left + right")
    sess.press(StatusRow, Cols - 20)
    discard sess.waitFor("copied the path ")
    var copied = false
    for t in sess.osc52():
      # The path, as the desktop's copy control copies it (no line).
      if t.endsWith("test-programs/calc/main.py"): copied = true
    ck copied
    sess.quit()

  test "a right-click on a dock label: the desktop's strip menu; Unpin":
    var sess = open()
    let (rb, cb) = sess.waitFor("BUILD", fromCol = 10)
    ck rb == StatusRow
    sess.press(rb, cb + 1, RightButton)
    let (ru, cu) = sess.waitFor("Unpin")
    let s = sess.snap()
    ck s.findRow("Pin to Left")[0] == ru - 2
    ck s.findRow("Pin to Right")[0] == ru - 1
    ck s.findRow("Close", fromCol = cu - 2)[0] == ru + 1
    ck s.findRow("Pin to Bottom")[0] < 0     # it is pinned to the bottom
    sess.press(ru, cu + 1)
    # Unpinned: a pane of the layout, its tab in a strip; the label gone
    # from the status row.
    var deadline = getMonoTime() + initDuration(seconds = 10)
    while getMonoTime() < deadline and
          sess.rowText(StatusRow).contains("BUILD"):
      sleep(80)
    ck not sess.rowText(StatusRow).contains("BUILD")
    # Back in the layout: a pane at the body's right edge (its divider now
    # ends the strip row, which ended in the call trace's strip before).
    ck sess.rowText(1).strip(leading = false).endsWith("▏")
    sess.quit()

  test "a drag along the timeline's track seeks where it is released":
    var sess = open()
    let (rt, ct) = sess.waitFor("Timeline")
    sess.press(rt, ct + 2)
    let (rb, _) = sess.waitFor("TIMELINE tick")
    let track = sess.snap().text(rb + 1)
    let start = track.cellFind("[")
    let stop = track.cellFind("]")
    let a = start + 1 + (stop - start - 1) div 5
    let b = start + 1 + (stop - start - 1) * 4 div 5
    # Press at a fifth, move, release at four fifths (button-event motion,
    # code 32: the left button held).
    sess.mouse(0, rb + 1, a)
    let t1 = sess.waitTick(0)
    ck t1 > 20 and t1 < 50
    sess.mouse(32, rb + 1, (a + b) div 2)
    sess.mouse(32, rb + 1, b)
    sess.mouse(0, rb + 1, b, release = true)
    let t2 = sess.waitTick(t1)
    ck t2 > 120 and t2 < 150
    sess.quit()

suite "PLAT-50 on a real terminal: the Points pane from the View menu (K31)":

  test "the menu opens the Points pane; a click selects a point":
    var sess = open()
    discard sess.waitFor("return left + right")
    let (r31, c31) = sess.snap().editorRowOfLine(31)
    sess.press(r31, c31)
    discard sess.waitFor("● 31")
    let (r36, c36) = sess.snap().editorRowOfLine(36)
    sess.press(r36, c36)
    discard sess.waitFor("● 36")
    # The omnibar's View command, as the desktop's View menu opens it.
    sess.send("\x10")   # Ctrl+p: the omnibar
    sleep(300)
    sess.send(":Breakp")
    discard sess.waitFor("View › Breakpoints & Tracepoints")
    sess.send("\r")
    discard sess.waitFor("opened pointList")
    let (rp, cp) = sess.waitFor("breakpoint main.py:36")
    ck sess.snap().findRow("breakpoint main.py:31")[0] == rp - 1
    sess.press(rp, cp + 2)
    sleep(400)
    let s = sess.snap()
    ck s[rp][cp].bg != s[rp - 1][cp].bg      # the selection's ground
    sess.quit()

suite "PLAT-50 on a real terminal: the VCS pane (K34, K53)":

  test "a changed file shows its diff; a commit lists its files":
    let repo = createTempDir("plat50-vcs-tui-", "") / "repo"
    let (output, code) = execCmdEx("bash " &
      quoteShell(lifecycle_support.repoRoot() / "scripts" /
                 "plat47-vcs-fixture.sh") & " " & quoteShell(repo))
    if code != 0: checkpoint(output)
    ck code == 0
    var sess = open(workDir = repo)
    let (rv, cv) = sess.waitFor(" VCS ")
    sess.press(rv, cv + 2)
    let (rm, cm) = sess.waitFor(" M notes.txt")
    sess.press(rm, cm + 4)
    discard sess.waitFor("diff notes.txt  (working tree)")
    let s = sess.snap()
    var added, removed = false
    for r in 0 ..< Rows:
      let t = s.text(r)
      if t.contains("│ +") : added = true
      if t.contains("│ -"): removed = true
    ck added or removed
    sess.send("\x1b")
    discard sess.waitFor("(working tree)", present = false)
    # The commit: its files listed under it, indented; a second click
    # closes it.
    let (rc, cc) = sess.waitFor(" 496ddf7 ")
    sess.press(rc, cc + 2)
    discard sess.waitFor("   A notes.txt")
    ck sess.snap().findRow("   A notes.txt")[0] == rc + 1
    sess.press(rc, cc + 2)
    discard sess.waitFor("   A notes.txt", present = false)
    sess.quit()

suite "PLAT-50 real terminal clicks: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
