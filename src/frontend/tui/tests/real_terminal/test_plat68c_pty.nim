## test_plat68c_pty.nim — PLAT-68's real-stack boxes on a real terminal: the
## shipped `codetracer-tui` in a real PTY (TermAssert + libvterm) over a real
## recording and a real `replay-server`, driven by the bytes a terminal
## sends. GPUI's half is `test_plat68c_gpui_plan.nim`; both assert the same
## execution lines for the same keys.
##
##   * DEBUG MODE'S F-KEYS are the desktop's (CUA-Keymap.md §4): `F10` step
##     over, `Shift+F10` back, `F11` step into, `F12` step out — the pointer
##     read off the painted screen (the tick on the top bar, the execution
##     line's gutter) — and `F12` in Edit mode steps nothing and SAYS SO on
##     the status line (Mode-Transitions §8.1);
##   * THE LETTERS (OQ-1, Base-Keymaps §10.1): `n` steps and `p` steps back
##     with the read-only editor focused; `n` steps with the call trace
##     focused; `Ctrl+E` makes the document writable and `n` is TYPED, the
##     pointer staying; `Ctrl+E` again and `n` steps again; with the find
##     field focused `n` goes into the query;
##   * VS CODE'S PRECEDENCE THROUGH INPUT (KL-11): two user rows for one chord
##     in one scope — the later fires, and swapping their order in
##     `keybindings.json` swaps the result; a user row with no `when` takes
##     `Enter` from the call trace's base row, and the shortcut reference
##     (`Ctrl+K Ctrl+S`, `:keys reference`) lists the shadow;
##   * THE LAYER STACK THROUGH INPUT (§5.3, §5.4): the find widget's layer is
##     its owner's — `Escape` in the call trace leaves it open, `Escape` back
##     in the editor closes it; closing the pane that owns it takes the layer
##     away; with it open the reference lists its layer FIRST;
##   * THE PENDING PREFIX (§3.7): `Ctrl+K` shows `Ctrl+K…` and is still
##     waiting past 1000 ms under CUA; Vim's `g` ends at 1000 ms, on the
##     clock (its `g…` leaves the status line without another key).
##
## No mocks: the real binary, a real recording, a real engine, a real pty;
## the user keymap is a real file the binary reads.

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 37

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  StatusRow = Rows - 1
  F10 = "\e[21~"
  ShiftF10 = "\e[21;2~"
  F11 = "\e[23~"
  F12 = "\e[24~"
  CtrlF5 = "\e[15;5~"
  CtrlE = "\x05"
  CtrlF = "\x06"
  CtrlK = "\x0b"
  CtrlQ = "\x11"
  CtrlS = "\x13"
  AltC = "\ec"
  CtrlAltU = "\e\x15"
  Esc = "\e"
  StartLine = 1
  OverLine = 2
    ## calc's execution line at the recording's start and after one step
    ## over — the same lines `test_plat68c_gpui_plan.nim` reads off GPUI's
    ## window for the same keys.

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc freshDir(): string =
  inc spawned
  result = getTempDir() / ("plat68c-pty-" & $getCurrentProcessId() & "-" &
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

proc screenText(s: Snapshot): string =
  for r in 0 ..< Rows:
    result.add s.text(r) & "\n"

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc findRow(s: Snapshot; needle: string): (int, int) =
  for r in 0 ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc status(s: Snapshot): string = s.text(StatusRow).strip()

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

proc press(sess: var TuiTestSession; row, col: int; button = 0) =
  sess.mouse(button, row, col)
  sess.mouse(button, row, col, release = true)

proc quit(sess: var TuiTestSession) =
  sess.send(CtrlQ)
  discard sess.waitExit(initDuration(seconds = 15))
  sess.terminate()
  sess.close()

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

proc executionLine(s: Snapshot): int =
  ## The source line the execution pointer (`▸`) is drawn on, read off its
  ## gutter: the number just left of the mark.
  for r in 1 ..< StatusRow:
    let line = s.text(r)
    let at = line.find("▸")
    if at < 0: continue
    var j = at - 1
    while j >= 0 and line[j] == ' ': dec j
    var digits = ""
    while j >= 0 and line[j] in {'0' .. '9'}:
      digits.insert($line[j], 0)
      dec j
    if digits.len > 0: return parseInt(digits)
  -1

proc settledTick(sess: var TuiTestSession; other: int; what: string): int =
  ## The tick once it moved away from `other`.
  sess.waitUntil(what, proc(s: Snapshot): bool =
    s.tick >= 0 and s.tick != other)
  sess.snap().tick

proc line11(s: Snapshot): tuple[row, code: int] =
  let (r, c) = s.findRow("``src/frontend/tui/tests/fixtures/fixture_provider")
  (r, c - 2)

proc clickCode(sess: var TuiTestSession) =
  ## A left press on calc's line 11, column 5: the editor takes the focus and
  ## the caret.
  let at = sess.snap().line11()
  doAssert at.row >= 0, "calc's line 11 is not on the screen"
  sess.press(at.row, at.code + 4)
  discard sess.drainOutput(200)

proc tabAt(s: Snapshot; label: string): (int, int) =
  ## A tab strip's label (the strip rows, never the top bar).
  for r in 1 ..< StatusRow:
    let c = s.text(r).cellFind(" " & label & " ")
    if c >= 0: return (r, c + 1)
  (-1, -1)

suite "PLAT-68 on a real terminal: Debug mode's F-keys (CUA-Keymap.md §4)":

  test "F10, Shift+F10, F11 and F12 step over, back, into and out":
    var sess = open()
    let s0 = sess.snap()
    let t0 = s0.tick
    let l0 = s0.executionLine
    ck t0 >= 0 and l0 == StartLine
    sess.send(F10)
    let t1 = sess.settledTick(t0, "F10 stepped over")
    ck t1 > t0
    ck sess.snap().executionLine == OverLine
    sess.send(ShiftF10)
    let t2 = sess.settledTick(t1, "Shift+F10 stepped back")
    ck t2 == t0
    ck sess.snap().executionLine == l0
    sess.send(F11)
    let t3 = sess.settledTick(t2, "F11 stepped into")
    ck t3 > t0
    sess.send(F12)
    let t4 = sess.settledTick(t3, "F12 stepped out")
    ck t4 > t3
    sess.quit()

  test "F12 in Edit mode steps nothing, and the status line says why":
    var sess = open()
    sess.send(CtrlF5)
    sess.waitUntil("Edit mode", proc(s: Snapshot): bool =
      "[EDIT]" in s.text(StatusRow))
    let before = sess.snap()
    sess.send(F12)
    sess.waitUntil("the inert note", proc(s: Snapshot): bool =
      "debugger.step-out" in s.text(StatusRow))
    let after = sess.snap()
    ck "replay session" in after.status
    ck after.tick == before.tick
    sess.quit()

suite "PLAT-68 on a real terminal: the letters under CUA (OQ-1)":

  test "n steps and p steps back in the read-only editor; n steps in the call trace":
    var sess = open()
    sess.clickCode()
    let t0 = sess.snap().tick
    let l0 = sess.snap().executionLine
    sess.send("n")
    let t1 = sess.settledTick(t0, "n stepped")
    ck t1 > t0
    ck sess.snap().executionLine == OverLine
    sess.send("p")
    let t2 = sess.settledTick(t1, "p stepped back")
    ck t2 == t0
    ck sess.snap().executionLine == l0
    sess.send(AltC)
    discard sess.drainOutput(300)
    sess.send("n")
    let t3 = sess.settledTick(t2, "n stepped in the call trace")
    ck t3 == t1
    sess.quit()

  test "writable, n is typed and the pointer stays; read-only again, n steps":
    var sess = open()
    sess.clickCode()
    let t0 = sess.snap().tick
    sess.send(CtrlE)
    sess.waitUntil("writable", proc(s: Snapshot): bool =
      "writable" in s.text(StatusRow))
    sess.send("n")
    # The caret is at column 5, the `s` after the two backticks.
    sess.waitUntil("an n typed on line 11", proc(s: Snapshot): bool =
      s.findRow("  ``nsrc/frontend/tui/tests/fixtures")[0] >= 0)
    ck sess.snap().tick == t0
    sess.send(CtrlE)
    sess.waitUntil("read-only", proc(s: Snapshot): bool =
      "read-only" in s.text(StatusRow))
    sess.send("n")
    let t1 = sess.settledTick(t0, "n stepped again")
    ck t1 > t0
    sess.quit()

  test "the find field takes n into its query":
    var sess = open()
    sess.clickCode()
    let t0 = sess.snap().tick
    sess.send(CtrlF)
    sess.waitUntil("the find field", proc(s: Snapshot): bool =
      s.text(StatusRow).startsWith("/"))
    sess.send("n")
    sess.waitUntil("n in the query", proc(s: Snapshot): bool =
      s.text(StatusRow).strip().startsWith("/n"))
    ck sess.snap().tick == t0
    sess.quit()

suite "PLAT-68 on a real terminal: VS Code's precedence through input (KL-11)":

  const RowA = """{ "key": "ctrl+alt+u", "command": "debugger.step-over" }"""
  const RowB = """{ "key": "ctrl+alt+u", "command": "debugger.jump-to-end" }"""

  test "two user rows for one chord in one scope: the later fires, in both orders":
    var later = open(keybindings = "[" & RowA & "," & RowB & "]")
    let t0 = later.snap().tick
    later.send(CtrlAltU)
    let toEnd = later.settledTick(t0, "the later row (jump to the end)")
    later.quit()
    var swapped = open(keybindings = "[" & RowB & "," & RowA & "]")
    ck swapped.snap().tick == t0
    swapped.send(CtrlAltU)
    let stepped = swapped.settledTick(t0, "the later row (step over)")
    swapped.quit()
    ck stepped > t0
    ck toEnd > stepped

  test "a user row with no `when` takes Enter from the call trace; the reference lists the shadow":
    const EnterRow = """[ { "key": "enter", "command": "debugger.continue" } ]"""
    var sess = open(keybindings = EnterRow)
    let t0 = sess.snap().tick
    sess.send(AltC)
    discard sess.drainOutput(300)
    sess.send("\r")
    let t1 = sess.settledTick(t0, "Enter continued")
    ck t1 > t0
    # The reference, from where the focus is (the call trace).
    sess.send(CtrlK)
    sess.send(CtrlS)
    sess.waitUntil("the reference", proc(s: Snapshot): bool =
      s.findRow("Keyboard shortcuts — CUA at ")[0] >= 0)
    let s = sess.snap()
    let (hr, hc) = s.findRow("[user:global]")
    ck hr >= 0
    var shadow = -1
    for r in 0 ..< Rows:
      let t = s.text(r)
      if "Enter  list.activate" in t and "(shadowed by your row 1)" in t:
        shadow = r
    checkpoint(s.screenText)
    ck shadow > hr
    ck hc >= 0
    sess.quit()

  test "`:keys reference` opens the reference from the command line":
    var sess = open()
    sess.clickCode()
    sess.send(":keys reference\r")
    sess.waitUntil("the reference", proc(s: Snapshot): bool =
      s.findRow("Keyboard shortcuts — CUA at ")[0] >= 0)
    ck sess.snap().findRow("[base:editor]")[0] >= 0
    sess.quit()

suite "PLAT-68 on a real terminal: the layer stack through input (§5.3, §5.4)":

  test "find is its owner's: Escape in the call trace leaves it, Escape in the editor closes it":
    var sess = open()
    sess.clickCode()
    sess.send(CtrlF)
    sess.waitUntil("the find field", proc(s: Snapshot): bool =
      s.text(StatusRow).startsWith("/"))
    let (cr, cc) = sess.snap().tabAt("Call Trace")
    ck cr >= 0
    # A press in the call trace's body gives it the focus (its tab only
    # selects the tab).
    sess.press(cr + 2, cc + 8)
    discard sess.drainOutput(300)
    sess.send(Esc)
    discard sess.drainOutput(400)
    ck sess.snap().status.startsWith("/")
    sess.clickCode()
    sess.send(Esc)
    sess.waitUntil("find closed", proc(s: Snapshot): bool =
      not s.text(StatusRow).startsWith("/"))
    ck "CUA [DEBUG]" in sess.snap().status
    sess.quit()

  test "with find open the reference lists its layer first":
    var sess = open()
    sess.clickCode()
    sess.send(CtrlF)
    sess.waitUntil("the find field", proc(s: Snapshot): bool =
      s.text(StatusRow).startsWith("/"))
    sess.send(CtrlK)
    sess.send(CtrlS)
    sess.waitUntil("the reference", proc(s: Snapshot): bool =
      s.findRow("Keyboard shortcuts — CUA at ")[0] >= 0)
    let s = sess.snap()
    let (title, _) = s.findRow("Keyboard shortcuts — CUA at ")
    var first = ""
    for r in title + 1 ..< StatusRow:
      let t = s.text(r)
      let at = t.find("[")
      if at >= 0 and "]" in t[at .. ^1]:
        first = t[at .. t.find("]", at)]
        break
    checkpoint(s.screenText)
    ck first == "[base:find]"
    sess.quit()

  test "closing the pane that owns the find layer takes the layer away":
    var sess = open()
    # `/` in the call trace opens find OWNED BY THE CALL TRACE.
    sess.send(AltC)
    discard sess.drainOutput(300)
    sess.send("/")
    sess.waitUntil("the find field", proc(s: Snapshot): bool =
      s.text(StatusRow).startsWith("/"))
    let (cr, cc) = sess.snap().tabAt("Call Trace")
    ck cr >= 0
    # The tab's right-click menu, its "Close".
    sess.press(cr, cc + 1, button = 2)
    sess.waitUntil("the tab menu", proc(s: Snapshot): bool =
      s.findRow(" Close ")[0] >= 0)
    let (mr, mc) = sess.snap().findRow(" Close ")
    sess.press(mr, mc + 1)
    sess.waitUntil("the find layer gone", proc(s: Snapshot): bool =
      not s.text(StatusRow).startsWith("/"))
    ck "CUA [DEBUG]" in sess.snap().status
    ck sess.snap().tabAt("Call Trace")[0] < 0
    sess.quit()

suite "PLAT-68 on a real terminal: the pending prefix (§3.7)":

  test "CUA's Ctrl+K waits past 1000 ms, and Escape cancels it":
    var sess = open()
    sess.clickCode()
    sess.send(CtrlK)
    sess.waitUntil("Ctrl+K…", proc(s: Snapshot): bool =
      "Ctrl+K…" in s.text(StatusRow))
    sleep(1600)
    ck "Ctrl+K…" in sess.snap().status
    sess.send(Esc)
    sess.waitUntil("the prefix cancelled", proc(s: Snapshot): bool =
      "Ctrl+K…" notin s.text(StatusRow))
    ck "CUA [DEBUG]" in sess.snap().status
    sess.quit()

  test "Vim's g ends at 1000 ms, on the clock":
    var sess = open(@["--keymap=vim"])
    sess.clickCode()
    let started = getMonoTime()
    sess.send("g")
    sess.waitUntil("g…", proc(s: Snapshot): bool = "g…" in s.text(StatusRow))
    sess.waitUntil("g… gone", proc(s: Snapshot): bool =
      "g…" notin s.text(StatusRow), timeoutMs = 5000)
    let waited = (getMonoTime() - started).inMilliseconds
    checkpoint("g… shown for " & $waited & " ms")
    # At or after the 1000 ms timeout, and without another key: a prefix
    # that only ended at the next key would still be shown at the 5 s
    # deadline. The upper bound leaves the loaded host's frame latency room
    # (measured 1.1-2.1 s on a host at load 50-150).
    ck waited >= 1000
    ck waited < 4000
    ck "NORMAL [DEBUG]" in sess.snap().status
    sess.quit()

suite "PLAT-68 on a real terminal (plat68c): assertion count":
  test "the declared count was reached":
    check countedAssertions == ExpectedAssertions
