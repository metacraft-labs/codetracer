## test_plat70a_hscroll_pty.nim — PLAT-70 Part A (Horizontal-Overflow.md §4),
## the shipped `codetracer-tui` on a REAL pseudo-terminal (TermAssert: a real
## pty, the screen read back through libvterm), over a real recording of
## `test-programs/wide_lines` (a source line and an output line far wider
## than any pane) against the real `replay-server`:
##
##   * the EDITOR: the overflow-only bar on the pane's last row, its thumb in
##     the cells `thumbSpan` names; wheel-left / wheel-right sent as the exact
##     bytes `CSI < 66 ; c ; r M` / `CSI < 67 ; c ; r M` move the code area by
##     6 columns and never the rows (HO-6); a track click centres the clicked
##     column; a thumb drag is followed; the caret and the tick are unchanged
##     by all of it (HO-4); `End` brings the line's end into view and a caret
##     walked right stays 4 columns in from the edge (HO-5, §4.5); deleting
##     the long line makes the bar disappear and the view return to column 0
##     (HO-1);
##   * the TERMINAL OUTPUT line view: its bar in the last row, the corner
##     cell left to neither track (HO-7), the SGR wheel bytes, and the view
##     keys — `Left` / `Right` under CUA, `z l` / `z h` / `z Shift+L` / `0`
##     under Vim;
##   * BUILD OUTPUT after a real `:build` whose output line is wider than the
##     pane: the bar, the wheel and `Right`.
##
## No mocks: the binary, the engine and the recording are real; the program
## the build runs is a real `/bin/sh` command. State in a scratch directory.

import std/[algorithm, monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import codetracer_embed

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 43

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 150
  Rows = 44
  Program = "test-programs/wide_lines/main.py"
  TrackGlyph = "─"
  WheelLeft = 66
  WheelRight = 67
  WheelShiftUp = 64 or 4
  WheelShiftDown = 65 or 4

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc trace(): string =
  let resolved = resolveFixture(FixtureSpec(
    name: "wide_lines", program: Program,
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

proc open(extra: seq[string] = @[]): TuiTestSession =
  inc spawned
  let state = getTempDir() / ("plat70a-pty-" & $getCurrentProcessId() & "-" &
                              $spawned)
  removeDir(state)
  createDir(state)
  # PLAT-70 Part H: the bars' look is fixed for this suite — `thin`, the
  # track drawn, never faded — so a cell's glyph says thumb or track.
  result = newTuiTest(tuiBinary(), @["--theme=dark", "--scrollbar-thickness=thin",
                                     "--scrollbar-track=on",
                                     "--scrollbar-fade=off"] &
                                   extra & @[trace()])
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

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc cells(s: Snapshot; r, c0, n: int): string =
  ## `n` cells of row `r` from column `c0`, as text.
  for c in c0 ..< min(Cols, c0 + n):
    result.add s[r][c].glyph

proc findRow(s: Snapshot; needle: string): (int, int) =
  for r in 0 ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc waitUntil(sess: var TuiTestSession; what: string;
               cond: proc(s: Snapshot): bool; timeoutMs = 20000): Snapshot =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.snap()
    if cond(result): return
    sleep(40)
  var dump = ""
  for r in 0 ..< Rows: dump.add result.text(r) & "\n"
  raise newException(AssertionFailedError, "never: " & what & "\n" & dump)

proc waitFor(sess: var TuiTestSession; needle: string): (int, int) =
  let s = sess.waitUntil("'" & needle & "' on screen",
                         proc(s: Snapshot): bool = s.findRow(needle)[0] >= 0)
  s.findRow(needle)

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  ## One SGR-1006 report — the exact bytes a terminal writes.
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int) =
  sess.mouse(0, row, col)
  sess.mouse(0, row, col, release = true)

proc tick(sess: var TuiTestSession): int =
  let line = sess.snap().text(0)
  let at = line.find("tick: ")
  if at < 0: return -1
  var digits = ""
  for c in line[at + "tick: ".len .. ^1]:
    if c in {'0' .. '9'}: digits.add c
    elif c == ',': discard
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc omnibox(sess: var TuiTestSession; line: string) =
  sess.send("\x10")  # Ctrl+P
  sleep(200)
  sess.send(line)
  sleep(150)
  sess.send("\r")

proc quit(sess: var TuiTestSession) =
  sess.send("\x11")  # Ctrl+Q, the CUA base's quit
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc sourceLine(n: int): string =
  ## Line `n` (1-based) of the recorded program — the oracle for what the
  ## code area shows at any left column.
  readFile(lifecycle_support.repoRoot() / Program).splitLines()[n - 1]

proc sliceCells(s: string; left, width: int): string =
  ## Columns `[left, left + width)` of `s` padded with blanks.
  let r = s.toRunes
  for i in left ..< left + width:
    result.add(if i < r.len: $r[i] else: " ")

proc widestSourceLine(): int =
  ## The editor's content width, read off the file independently: every line
  ## is ASCII or one-cell punctuation, with no tab.
  for line in readFile(lifecycle_support.repoRoot() / Program).splitLines():
    result = max(result, line.runeLen)


proc isBarGlyph(g: string): bool =
  ## PLAT-70 Part H: the bars are drawn `thin` with the track on
  ## (`BarLook`, below): a `─` track under a `━` thumb with half-cell ends.
  g == TrackGlyph or g in ["━", "╸", "╺", "╾", "╼"]

type Bar = tuple[row, left, cols: int]

proc textCols(s: Snapshot; row, left: int): int =
  ## How many text columns a pane has from `left` on `row`: to the divider
  ## (`▏`) or the vertical track (`│`, eighth blocks, `█`) or the screen's
  ## edge. (A bar row cannot say it: its thumb is drawn with the divider's
  ## glyph.)
  var c = left
  while c < Cols and s[row][c].glyph notin ["▏", "│", "┃", "╹", "╻", "╿", "╽",
                                             "█", "▁", "▂", "▃",
                                             "▄", "▅", "▆", "▇"]:
    inc c
  c - left

proc barBelow(s: Snapshot; fromRow, left, cols: int): Bar =
  ## The horizontal bar under `fromRow`: the first row whose `cols` cells
  ## from `left` are all bar glyphs.
  for r in fromRow + 1 ..< Rows - 1:
    var all = true
    for i in 0 ..< cols:
      if not s[r][left + i].glyph.isBarGlyph:
        all = false
        break
    if all: return (r, left, cols)
  (-1, -1, 0)

proc shown(line: string; left, cols: int): string =
  ## What a text row of `cols` columns shows of `line` from column `left`
  ## with the overflow markers on (§4.6, the terminal's default): `‹` in the
  ## first column when the line continues left of the view, `›` in the last
  ## when it continues right of it — an independent statement of the rule.
  var r = line.sliceCells(left, cols).toRunes
  if left > 0 and line.len > 0: r[0] = "‹".runeAt(0)
  if line.runeLen > left + cols: r[^1] = "›".runeAt(0)
  $r

proc thumbCellsOf(s: Snapshot; bar: Bar): seq[int] =
  for i in 0 ..< bar.cols:
    if s[bar.row][bar.left + i].glyph != TrackGlyph: result.add i

proc expectedThumb(content, left, cols, mark: int): seq[int] =
  ## The cells the shared model's thumb covers (`thumbSpan`, in eighths),
  ## plus the mark's cell (the caret's column, Horizontal-Overflow §4.2).
  ## PLAT-70 Part H: a `thin` thumb is drawn in half cells — a cell is the
  ## thumb's when the centre of either of its halves is inside the span.
  let sm = scrubberModel(content, left, cols, current = mark)
  let span = sm.thumbSpan(cols * 8, 8)
  for i in 0 ..< cols:
    var covered = false
    for centre in [i * 8 + 2, i * 8 + 6]:
      if centre >= span.start and centre < span.start + span.length:
        covered = true
    if covered: result.add i
  if mark >= 0:
    let f = sm.currentFraction
    let m = min(cols - 1, int(f * float(cols)))
    if m notin result:
      result.add m
      result.sort(system.cmp)

proc reverseCol(s: Snapshot; r, c0, n: int): int =
  ## The column of the reverse-video cell (the caret) in `[c0, c0 + n)`.
  for c in c0 ..< min(Cols, c0 + n):
    if caReverse in s[r][c].attrs: return c
  -1

suite "PLAT-70 Part A: the editor scrolls sideways on a real terminal":

  test "the bar, the SGR wheel bytes, track click and drag — the view only":
    var sess = open()
    defer: sess.quit()
    var (row, col) = sess.waitFor("WIDE_SOURCE = \"<<LEFT-EDGE>>")
    let codeLeft = col - 4        # the line is indented four columns
    let line = sourceLine(26)
    ck line.strip.startsWith("WIDE_SOURCE")
    var s = sess.snap()
    let cols = s.textCols(row, codeLeft)
    let content = widestSourceLine()
    checkpoint("code columns " & $cols & ", content " & $content)
    ck content > cols
    ck s.cells(row, codeLeft, cols) == line.shown(0, cols)
    # The caret onto column 10 of the long line: a click on its text.
    sess.press(row, codeLeft + 10)
    s = sess.waitUntil("the caret on the clicked cell",
      proc(s: Snapshot): bool = s.reverseCol(row, codeLeft, cols) == codeLeft + 10)
    let tick0 = sess.tick()
    ck tick0 >= 0
    # THE BAR: the editor's last row, over the code columns, the thumb where
    # the model says, the caret's column marked.
    let bar = s.barBelow(row, codeLeft, cols)
    checkpoint("bar " & $bar)
    ck bar.row > row
    ck s.thumbCellsOf(bar) == expectedThumb(content, 0, cols, 10)
    # WHEEL RIGHT, button 67: the code area moves 6 columns; the rows stay.
    let gutter = s.cells(row, 0, codeLeft)
    sess.mouse(WheelRight, row, codeLeft + 20)
    s = sess.waitUntil("wheel-right moved the view 6 columns",
      proc(s: Snapshot): bool = s.cells(row, codeLeft, cols) == line.shown(6, cols))
    ck s.cells(row, 0, codeLeft) == gutter                 # never the rows
    ck s.text(row).contains("_SOURCE = \"<<LEFT-EDGE>>")
    ck s.reverseCol(row, codeLeft, cols) == codeLeft + 10 - 6
    ck s.thumbCellsOf(bar) == expectedThumb(content, 6, cols, 10)
    # WHEEL LEFT, button 66: back.
    sess.mouse(WheelLeft, row, codeLeft + 20)
    s = sess.waitUntil("wheel-left moved the view back",
      proc(s: Snapshot): bool = s.cells(row, codeLeft, cols) == line.shown(0, cols))
    ck s.cells(row, 0, codeLeft) == gutter
    # SHIFT + WHEEL (§4.3): the vertical wheel with SGR's Shift bit (4) —
    # 69 is wheel-down + Shift, 68 wheel-up + Shift — scrolls sideways when
    # the terminal delivers it.
    sess.mouse(WheelShiftDown, row, codeLeft + 20)
    s = sess.waitUntil("Shift + wheel-down moved the view right",
      proc(s: Snapshot): bool = s.cells(row, codeLeft, cols) == line.shown(6, cols))
    ck s.cells(row, 0, codeLeft) == gutter
    sess.mouse(WheelShiftUp, row, codeLeft + 20)
    s = sess.waitUntil("Shift + wheel-up moved it back",
      proc(s: Snapshot): bool = s.cells(row, codeLeft, cols) == line.shown(0, cols))
    ck s.cells(row, 0, codeLeft) == gutter
    # A TRACK CLICK centres the clicked column (§4.2, HO-3).
    let at = bar.left + cols - 2
    var hv = HorizontalView(contentCols: content, viewportCols: cols)
    discard hv.clickTrack(trackFractionAt(at - bar.left, cols))
    let clicked = hv.leftCol
    checkpoint("track click -> leftCol " & $clicked)
    ck clicked > 6
    sess.press(bar.row, at)
    # The pointer off the bar again: hovered, a bar is drawn widened with its
    # track revealed (PLAT-70 Part H, Scrollbar-Scrubbers.md §7.4).
    sess.mouse(35, row, codeLeft + 2)
    s = sess.waitUntil("the track click centred its column",
      proc(s: Snapshot): bool =
        s.cells(row, codeLeft, cols) == line.shown(clicked, cols))
    ck s.cells(row, 0, codeLeft) == gutter
    ck s.thumbCellsOf(bar) == expectedThumb(content, clicked, cols, 10)
    # THE CARET AND THE TICK DID NOT MOVE (HO-4): column 10 is scrolled off.
    ck s.reverseCol(row, codeLeft, cols) == -1
    ck sess.tick() == tick0
    # A THUMB DRAG is followed: pressed on the thumb, carried left, released.
    let thumb = s.thumbCellsOf(bar)
    let grab = bar.left + thumb[thumb.len div 2]
    let to = bar.left + 4
    sess.mouse(0, bar.row, grab)
    sess.mouse(32, bar.row, to)
    sess.mouse(0, bar.row, to, release = true)
    sess.mouse(35, row, codeLeft + 2)
    var dragged = HorizontalView(contentCols: content, viewportCols: cols,
                                 leftCol: clicked)
    let f = trackFractionAt(to - bar.left, cols)
    # PLAT-70 Part H (Scrollbar-Scrubbers.md §3.3): the thumb keeps the
    # point it was grabbed by.
    let offset = dragged.barModel.grabOffset(
      trackFractionAt(grab - bar.left, cols))
    discard dragged.dragThumb(f - offset)
    checkpoint("drag -> leftCol " & $dragged.leftCol)
    s = sess.waitUntil("the drag was followed",
      proc(s: Snapshot): bool =
        s.cells(row, codeLeft, cols) == line.shown(dragged.leftCol, cols))
    ck s.cells(row, 0, codeLeft) == gutter
    ck sess.tick() == tick0
    # The caret, untouched, is where it was in the document.
    ck s.reverseCol(row, codeLeft, cols) ==
       (if dragged.leftCol <= 10: codeLeft + 10 - dragged.leftCol else: -1)
    # And back at column 0 it is on its line and column: no press on the bar
    # was a click on the text under it (HO-4).
    for _ in 0 .. (dragged.leftCol div 6) + 1:
      sess.mouse(WheelLeft, row, codeLeft + 5)
    s = sess.waitUntil("wheel-left brought the view back to column 0",
      proc(s: Snapshot): bool = s.cells(row, codeLeft, cols) == line.shown(0, cols))
    ck s.reverseCol(row, codeLeft, cols) == codeLeft + 10

  test "caret-follow: End, Home, a caret walked right (§4.5, HO-5)":
    var sess = open()
    defer: sess.quit()
    var (row, col) = sess.waitFor("WIDE_SOURCE = \"<<LEFT-EDGE>>")
    let codeLeft = col - 4
    let line = sourceLine(26)
    var s = sess.snap()
    let cols = s.textCols(row, codeLeft)
    sess.press(row, codeLeft)
    s = sess.waitUntil("the caret at the line's first column",
      proc(s: Snapshot): bool = s.reverseCol(row, codeLeft, cols) == codeLeft)
    let tick0 = sess.tick()
    # `End`: the line's end in view and the caret on the view's last column
    # — the margin is not applied past the line's end.
    sess.send("\x1b[F")
    let endLeft = line.runeLen - cols + 1
    s = sess.waitUntil("End brought the end into view",
      proc(s: Snapshot): bool =
        s.cells(row, codeLeft, cols) == line.shown(endLeft, cols))
    ck s.reverseCol(row, codeLeft, cols) == codeLeft + cols - 1
    ck s.text(row).contains("<<RIGHT-EDGE>>\"")
    # `Home` (to the first non-blank, column 4): column 0 is in view again.
    sess.send("\x1b[H")
    s = sess.waitUntil("Home showed column 0",
      proc(s: Snapshot): bool =
        s.cells(row, codeLeft, cols) == line.shown(0, cols))
    ck s.reverseCol(row, codeLeft, cols) == codeLeft + 4
    # A caret walked right past the edge: the view follows it with the
    # margin — 4 columns in from the right edge, never on it.
    let walk = cols + 5
    var keys = ""
    for i in 0 ..< walk: keys.add "\x1b[C"
    sess.send(keys)
    let caret = 4 + walk
    let left = caret - cols + 4 + 1
    s = sess.waitUntil("the caret walked right",
      proc(s: Snapshot): bool =
        s.reverseCol(row, codeLeft, cols) == codeLeft + cols - 5)
    ck s.cells(row, codeLeft, cols) == line.shown(left, cols)
    ck sess.tick() == tick0

  test "deleting the wide line takes the bar away and the view to 0 (HO-1)":
    var sess = open()
    defer: sess.quit()
    var (row, col) = sess.waitFor("WIDE_SOURCE = \"<<LEFT-EDGE>>")
    let codeLeft = col - 4
    var s = sess.snap()
    let cols = s.textCols(row, codeLeft)
    sess.press(row, codeLeft)
    discard sess.waitUntil("the caret on the long line",
      proc(s: Snapshot): bool = s.reverseCol(row, codeLeft, cols) == codeLeft)
    s = sess.snap()
    let bar = s.barBelow(row, codeLeft, cols)
    ck bar.row > row
    sess.send("\x1b[F")           # End: the view scrolled right
    discard sess.waitUntil("scrolled to the end",
      proc(s: Snapshot): bool = s.text(row).contains("<<RIGHT-EDGE>>"))
    sess.send("\x05")             # Ctrl+E: the document made writable
    sleep(300)
    sess.send("\x1b[1;2H")        # Shift+Home: the line's text selected
    sleep(200)
    sess.send("\x1b[3~")          # Delete
    s = sess.waitUntil("the bar went with the wide line",
      proc(s: Snapshot): bool =
        not s.text(row).contains("<<LEFT-EDGE>>") and
        s.barBelow(row, codeLeft, cols).row < 0)
    # The view is back at column 0: the line above starts where it did.
    ck s.cells(row - 1, codeLeft, 11) == "def main():"
    ck s.findRow("    emit(WIDE_SOURCE)")[0] >= 0

const OutputLine = "<<LEFT-EDGE>> the quick brown fox jumps over the lazy " &
  "dog, 0123456789 the quick brown fox jumps over the lazy dog, 0123456789 " &
  "the quick brown fox jumps over the lazy dog, 0123456789 the quick brown " &
  "fox jumps over the lazy dog, 0123456789 <<RIGHT-EDGE>>"

proc showTerminalOutput(sess: var TuiTestSession): int =
  ## Press the pane's tab in the Event Log's stack; answers the strip's row.
  let s = sess.snap()
  for r in 0 ..< Rows:
    let t = s.text(r)
    if t.contains(" Event Log ") and t.contains(" Terminal Output "):
      sess.press(r, t.cellFind(" Terminal Output ") + 2)
      return r
  raise newException(AssertionFailedError, "no Terminal Output tab drawn")

suite "PLAT-70 Part A: the output panes scroll sideways on a real terminal":

  test "Terminal Output's line view: the bar, the corner, the wheel, the keys":
    var sess = open()
    defer: sess.quit()
    let tabRow = sess.showTerminalOutput()
    discard sess.waitUntil("the Terminal Output pane shown",
      proc(s: Snapshot): bool = s.findRow("tick    # kind output")[0] < 0)
    var (row, col) = sess.waitFor("<<LEFT-EDGE>> the quick brown fox jumps")
    # The editor's own line 26 carries the text too: the pane's row is the
    # one a divider precedes directly.
    let s0 = sess.snap()
    for r in 0 ..< Rows:
      let c = s0.text(r).cellFind("<<LEFT-EDGE>> the quick brown fox jumps")
      if c > 0 and s0[r][c - 1].glyph == "▏":
        (row, col) = (r, c)
    let textLeft = col
    var s = sess.snap()
    let cols = s.textCols(row, textLeft)
    let bar = s.barBelow(row, textLeft, cols)
    checkpoint("terminal output bar " & $bar)
    ck bar.row > row
    ck s.cells(row, textLeft, cols) == OutputLine.shown(0, cols)
    # THE CORNER (HO-7): the cell right of the bar, under the vertical
    # track, is blank — neither track's — and the track stops above it.
    ck s[bar.row][textLeft + cols].glyph == " "
    ck s[bar.row - 1][textLeft + cols].glyph != " "
    ck s.thumbCellsOf(bar) == expectedThumb(OutputLine.runeLen, 0, cols, -1)
    let tick0 = sess.tick()
    # The wheel, as the exact SGR bytes.
    sess.mouse(WheelRight, row, textLeft + 10)
    s = sess.waitUntil("wheel-right scrolled the output",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == OutputLine.shown(6, cols))
    ck s.cells(row + 1, textLeft, cols) ==                 # never the rows
       "a short line".shown(6, cols)
    sess.mouse(WheelLeft, row, textLeft + 10)
    s = sess.waitUntil("wheel-left scrolled it back",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == OutputLine.shown(0, cols))
    # The corner takes no press.
    sess.press(bar.row, textLeft + cols)
    sleep(400)
    s = sess.snap()
    ck s.cells(row, textLeft, cols) == OutputLine.shown(0, cols)
    # CUA: `Right` / `Left` in the focused pane (the tab press focused it).
    sess.send("\x1b[C")
    s = sess.waitUntil("Right scrolled the output",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == OutputLine.shown(6, cols))
    sess.send("\x1b[D")
    s = sess.waitUntil("Left scrolled it back",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == OutputLine.shown(0, cols))
    ck sess.tick() == tick0
    # VIM: `z l`, `z h`, `z Shift+L`, `0`.
    sess.omnibox(":keymap vim")
    sleep(500)
    discard sess.showTerminalOutput()
    sleep(300)
    sess.send("zl")
    s = sess.waitUntil("z l scrolled the output",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == OutputLine.shown(6, cols))
    sess.send("zh")
    s = sess.waitUntil("z h scrolled it back",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == OutputLine.shown(0, cols))
    sess.send("zL")
    let half = cols div 2
    s = sess.waitUntil("z L scrolled half the view",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == OutputLine.shown(half, cols))
    sess.send("0")
    s = sess.waitUntil("0 went back to column 0",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == OutputLine.shown(0, cols))
    ck sess.tick() == tick0
    discard tabRow

  test "Build Output after a real build: the bar, the wheel and the track":
    var sess = open()
    defer: sess.quit()
    const Wide = "<<BUILD-LEFT>>" & "0123456789".repeat(24) & "<<BUILD-RIGHT>>"
    # `:build` is an Edit-mode command: Ctrl+F5 switches the session there.
    sess.send("\x1b[15;5~")
    discard sess.waitUntil("Edit mode",
      proc(s: Snapshot): bool = s.text(Rows - 1).contains("[EDIT]"))
    sess.omnibox(":build printf '%s\\n' '" & Wide & "'")
    discard sess.waitUntil("the build succeeded",
      proc(s: Snapshot): bool = s.findRow("[succeeded]")[0] >= 0)
    # Back to Debug mode, where the bottom dock's BUILD label docks the
    # pane open over the debugger's arrangement.
    sess.send("\x1b[15;5~")
    discard sess.waitUntil("Debug mode",
      proc(s: Snapshot): bool = s.text(Rows - 1).contains("[DEBUG]"))
    var s = sess.waitUntil("the build ran",
      proc(s: Snapshot): bool = s.text(Rows - 1).contains("BUILD"))
    let label = s.text(Rows - 1).cellFind(" BUILD ")
    require label >= 0
    sess.press(Rows - 1, label + 2)
    # The output's own line, not the verdict row that names the command: the
    # row that BEGINS with the text.
    var s1 = sess.waitUntil("the build output shown",
      proc(s: Snapshot): bool =
        for r in 0 ..< Rows:
          if s.text(r).startsWith("<<BUILD-LEFT>>"): return true
        false)
    var row = -1
    for r in 0 ..< Rows:
      if s1.text(r).startsWith("<<BUILD-LEFT>>"): row = r
    let textLeft = 0
    s = sess.snap()
    let cols = s.textCols(row, textLeft)
    let bar = s.barBelow(row, textLeft, cols)
    checkpoint("build output bar " & $bar)
    ck bar.row > row
    ck s.cells(row, textLeft, cols) == Wide.shown(0, cols)
    ck s.thumbCellsOf(bar) == expectedThumb(Wide.len, 0, cols, -1)
    sess.mouse(WheelRight, row, textLeft + 5)
    s = sess.waitUntil("wheel-right scrolled the build output",
      proc(s: Snapshot): bool = s.cells(row, textLeft, cols) == Wide.shown(6, cols))
    sess.mouse(WheelLeft, row, textLeft + 5)
    s = sess.waitUntil("wheel-left scrolled it back",
      proc(s: Snapshot): bool = s.cells(row, textLeft, cols) == Wide.shown(0, cols))
    # A press at the track's far end shows the line's end.
    sess.press(bar.row, bar.left + cols - 1)
    s = sess.waitUntil("the track's end shows the end of the line",
      proc(s: Snapshot): bool =
        s.cells(row, textLeft, cols) == Wide.shown(Wide.len - cols, cols))
    ck s.text(row).contains("<<BUILD-RIGHT>>")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
