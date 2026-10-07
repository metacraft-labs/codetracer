## test_plat51_pty.nim — PLAT-51, the shipped `codetracer-tui` on a REAL
## pseudo-terminal (TermAssert: a real pty, the screen read back through
## libvterm), over the real `noir_space_ship` (70 events) and `calc`
## recordings:
##
##   * no Timeline anywhere on the screen; the event stack's tabs are Event
##     Log and Terminal Output;
##   * the Event Log's scrollbar is a SCRUBBER over the whole log: a press at
##     the end of its track shows the log's LAST event (index 69) and the top
##     bar's tick does not move;
##   * the execution pointer is ` ▸ ` (and ` > ` under `--ascii-borders`),
##     never `-->`;
##   * a Shift + right-click report opens no menu (it is the terminal's); a
##     plain right-click opens the editor's menu with the inert "Terminal
##     menu: Shift + right-click" row last;
##   * the omnibox field on the EDITOR's ground (24-bit, read off the cells);
##   * a changed value on the terminal in the desktop's changed-value colour;
##   * a click places the read-only editor's caret and Alt+T, sent as the one
##     `ESC t` burst a terminal sends, opens the tracepoint editor on its line.
##
## No mocks: the binary, the engine and the recordings are real. State in a
## scratch directory.

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
import styles/generated/design_tokens

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 25

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  Events = 70

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc open(name: string; extra: seq[string] = @[]): TuiTestSession =
  let resolved = resolveFixture(name)
  doAssert resolved.outcome == foRecorded, resolved.detail
  inc spawned
  let state = getTempDir() / ("plat51-pty-" & $getCurrentProcessId() & "-" &
                              $spawned)
  removeDir(state)
  createDir(state)
  result = newTuiTest(tuiBinary(), @["--theme=dark"] & extra &
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

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

proc tick(sess: var TuiTestSession): int =
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

const TrackGlyphs = ["│", "█", "▁", "▂", "▃", "▄", "▅", "▆", "▇"]

proc eventLogPane(s: Snapshot): tuple[strip, left, track: int] =
  ## The Event Log's strip row, its first column and its scrubber's column:
  ## the rightmost column of the pane whose cells below the strip are all
  ## track, thumb or mark glyphs.
  for r in 0 ..< Rows:
    let t = s.text(r)
    let c = t.cellFind(" Event Log ")
    if c >= 0 and t.contains(" Terminal Output "):
      var right = Cols - 1
      for x in c + 1 ..< Cols:
        if $s[r][x].rune == "▏":
          right = x - 1
          break
      for col in countdown(right, c):
        var all = true
        for rr in r + 2 .. r + 6:
          if $s[rr][col].rune notin TrackGlyphs:
            all = false
        if all:
          return (r, max(0, c - 1), col)
      return (r, max(0, c - 1), -1)
  (-1, -1, -1)

let editorGround = DesignTokenHex[dtEditorThemeGround][dmDark]
let changedColour = DesignTokenHex[dtColorsUiTextInformationPrimaryHover][dmDark]

suite "PLAT-51 on a real terminal: no Timeline; the Event Log's scrubber":

  test "no Timeline; a press at the track's end shows the last of 70 events":
    var sess = open("noir_space_ship")
    defer: sess.quit()
    var s = sess.snap()
    var all = ""
    for r in 0 ..< Rows: all.add s.text(r) & "\n"
    ck not all.contains("Timeline")
    ck not all.contains("TIMELINE")
    let pane = s.eventLogPane()
    checkpoint("event log strip row " & $pane.strip & " track col " &
               $pane.track)
    ck pane.strip > 0
    ck pane.track > pane.left
    # The track's last row: the row above the pane's bottom edge — found as
    # the lowest row under the strip still holding a track glyph.
    var bottom = pane.strip + 1
    while bottom + 1 < Rows and $s[bottom + 1][pane.track].rune in TrackGlyphs:
      inc bottom
    let before = sess.tick()
    ck before >= 0
    sess.press(bottom, pane.track)
    sleep(400)
    let after = sess.snap()
    var shown = ""
    for r in pane.strip + 1 .. bottom:
      shown.add after.text(r).runeSubStr(pane.left, pane.track - pane.left) &
                "\n"
    checkpoint(shown)
    # Index 69 — the LAST of the whole log — is on screen, 0 is not.
    ck shown.contains(" " & $(Events - 1) & " ")
    ck not shown.contains("    0 ")
    # The VIEW moved; the debugger did not.
    ck sess.tick() == before

suite "PLAT-51 on a real terminal: the editor, its menu, the omnibox, values":

  test "the pointer is ▸ (> under --ascii-borders), never -->":
    block:
      var sess = open("calc")
      defer: sess.quit()
      # The pointer field: a line number, its gap, ` ▸ ` (the call trace's
      # collapsed toggle is `▸` too, never after a digit).
      let (r, c) = sess.waitFor("1  ▸ ")
      ck r > 0
      ck c >= 0
      var all = ""
      let s = sess.snap()
      for row in 0 ..< Rows: all.add s.text(row)
      ck not all.contains("-->")
      ck not all.contains("▶")
    block:
      var sess = open("calc", @["--ascii-borders"])
      defer: sess.quit()
      let s = sess.snap()
      var all = ""
      for row in 0 ..< Rows: all.add s.text(row) & "\n"
      ck not all.contains("▸")
      ck all.contains(" > ")

  test "Shift + right-click is the terminal's; a plain one opens the menu with its hint row":
    var sess = open("calc")
    defer: sess.quit()
    let (r, c) = sess.waitFor("def add")
    sess.press(r, c + 2, 2 + 4)
    sleep(300)
    var s = sess.snap()
    var all = ""
    for row in 0 ..< Rows: all.add s.text(row)
    ck not all.contains("Terminal menu")
    sess.press(r, c + 2, 2)
    let (hr, hc) = sess.waitFor("Terminal menu: Shift + right-click")
    ck hr > r
    ck hc >= 0
    s = sess.snap()
    let (ar, _) = s.findRow("Add tracepoint")
    ck ar > r and ar < hr
    sess.send("\x1b")

  test "a click places the caret; Alt+T, as a terminal sends it, opens the tracepoint editor there":
    # A terminal sends Alt+T as `ESC t` in ONE write; the framer must hand it
    # over as one key (`terminal_driver.feed`), or the runtime sees a bare
    # `t` — the seek-to-tick key — and the chord never arrives. The in-process
    # suite (`test_plat51_parity`) gives the runtime the token directly, so
    # only a real pty can see the framing.
    var sess = open("calc")
    defer: sess.quit()
    let (r, c) = sess.waitFor("def add")
    var line = -1
    let rowText = sess.snap().text(r)
    for word in strutils.splitWhitespace(rowText[0 ..< rowText.find("def add")]):
      if word.len > 0 and word.allCharsInSet({'0' .. '9'}): line = parseInt(word)
    ck line > 0
    sess.press(r, c + 2)
    sleep(300)
    sess.send("\x1b[B")          # Down: the caret, never the debugger
    sleep(200)
    sess.send("\x1bt")           # Alt+T, one burst
    # The tracepoint editor: the command line with `tracepoint ` typed (a
    # bare `t` would have opened the seek prompt instead).
    discard sess.waitFor(":tracepoint ")
    ck sess.snap().findRow("seek to tick")[0] < 0
    # Its expression, run: the hits are reported against the CARET's line.
    sess.send("log(left)\r")
    let (sr, _) = sess.waitFor("main.py:" & $(line + 1) & " — ", timeoutMs = 60000)
    ck sess.snap().text(sr).contains("tracepoint `log(left)` at ")

  test "the omnibox is on the editor's ground; a changed value in the desktop's colour":
    var sess = open("calc")
    defer: sess.quit()
    var s = sess.snap()
    let col = s.text(0).cellFind("⌕")
    ck col >= 0
    checkpoint("field cell bg " & s[0][col + 2].bgHex & " want " & editorGround)
    ck s[0][col + 2].bgHex == editorGround
    for _ in 0 ..< 3:
      sess.send("n")
      sleep(400)
    discard sess.waitFor("__name__")
    s = sess.snap()
    var lit = 0
    for r in 0 ..< Rows:
      for c in 0 ..< Cols:
        if s[r][c].fgHex == changedColour: inc lit
    checkpoint("cells in the changed colour: " & $lit)
    ck lit > 0
    var all = ""
    for r in 0 ..< Rows: all.add s.text(r)
    ck not all.contains("[MOD]")

suite "PLAT-51 PTY: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
