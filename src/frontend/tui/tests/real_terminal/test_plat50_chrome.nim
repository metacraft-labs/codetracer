## test_plat50_chrome.nim — PLAT-50 deliverables 4-6, Tier 2. **The chrome
## the user asked for on 2026-10-02, read back from a real terminal**: the
## shipped `codetracer-tui` on `calc` in a real PTY (TermAssert + libvterm),
## every cell's colours as the terminal received them.
##
##   2. COLOURS, the desktop's subtle contrasts (measured on the real desktop,
##      `plat50-desktop-capture.spec.ts`): the top bar on
##      ui/surface/primary/default (#1b1b1b — the desktop's `#menu`); the
##      transport controls on that ground with NO fill of their own; the
##      omnibox on the input surface (#242424, not the old #161616 / Light
##      #f3f3f3) bounded by ui/border/secondary edge lines (#3a3a3a); inactive
##      tabs and the strip on #1b1b1b (not #161616); the open menu on the
##      desktop's dropdown surface (#1b1b1b) inside a ui/border/primary frame
##      (#565656) over the #282828 panes.
##   3. THE OMNIBOX IS CENTRED in the top bar, the desktop's
##      `clamp(24em, 24vw, 40em)` wide (48 cells of 200).
##   4. DIVIDERS AND TAB BARS: no `─` row above a tab strip (the strip is the
##      separator); a divider cell in a strip row is the strip's ground, so
##      two strips connect; a body divider is `▏` in the chosen colour —
##      the strip's ground (`--dividers=strip`, the default) or
##      ui/border/secondary (`--dividers=subtle`); monochrome keeps the `▏`
##      glyph and the selected tab's reverse (CTUI-11). With no rule row
##      between stacked panes, the lower pane's strip off its tabs is the
##      split's handle: dragging it up gives the lower pane rows.
##
## No mocks: the real binary, a real recording, a real engine, a real pty.

import std/[monotimes, os, osproc, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
import ../../../styles/generated/design_tokens

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 60
  ## PLAT-51: +1 — the light omnibox is the editor's ground, and not white.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  StripGround = "#1b1b1b"   # ui/surface/primary/default, Dark
  PanelGround = "#282828"   # ui/surface/base/panel, Dark
  FieldGround = DesignTokenHex[dtEditorThemeGround][dmDark]
  LightEditorGround = DesignTokenHex[dtEditorThemeGround][dmLight]
    ## PLAT-51: the omnibox is on the EDITOR's ground (Commands-And-Omnibox.md,
    ## "Omnibox colours on every front-end"); it was ui/surface/input/default.
  FieldEdge = "#3a3a3a"     # ui/border/secondary, Dark
  MenuFrame = "#565656"     # ui/border/primary, Dark
  ActiveTab = "#333333"     # ui/surface/primary/tertiary, Dark

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc open(args: seq[string] = @[]; theme = "--theme=dark"): TuiTestSession =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded
  inc spawned
  let state = getTempDir() / ("plat50-chrome-" & $getCurrentProcessId() &
                              "-" & $spawned)
  removeDir(state)
  createDir(state)
  result = newTuiTest(tuiBinary(), @[theme] & args & @[resolved.tracePath])
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

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add(if int(c.rune) == 0: " " else: $c.rune)

proc cellFind(line, needle: string; start = 0): int =
  let at = line.find(needle, start)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc findRow(s: Snapshot; needle: string): (int, int) =
  for r in 0 ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0:
      return (r, c)
  (-1, -1)

proc waitFor(sess: var TuiTestSession; needle: string; present = true;
             timeoutMs = 20000): (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let at = sess.snap().findRow(needle)
    if (at[0] >= 0) == present:
      return at
    sleep(40)
  raise newException(AssertionFailedError,
    (if present: "never showed '" else: "kept showing '") & needle & "'")

proc press(sess: var TuiTestSession; row, col: int) =
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m")

proc quit(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

proc fgHex(c: Cell): string =
  if c.fg.kind == ckRgb: hexOf((c.fg.r.int, c.fg.g.int, c.fg.b.int)) else: ""

proc glyph(c: Cell): string =
  if int(c.rune) == 0: " " else: $c.rune

proc dividerCols(s: Snapshot; row: int): seq[int] =
  ## The columns of `row` holding a divider glyph.
  for c in 0 ..< Cols:
    if s[row][c].glyph == "▏": result.add c

suite "PLAT-50 on a real terminal: the top bar":

  test "the bar is the desktop's ground; controls have no fill; the omnibox is centred and bordered":
    var sess = open()
    discard sess.waitFor("Navigate to file")
    let s = sess.snap()
    let bar = s.text(0)
    # The menu button: `▕≡▏`, its border lines on the bar's ground.
    ck s[0][0].glyph == "▕" and s[0][1].glyph == "≡" and s[0][2].glyph == "▏"
    ck s[0][0].fgHex == FieldEdge and s[0][0].bgHex == StripGround
    ck s[0][1].bgHex == StripGround
    # Every transport control on the bar's own ground.
    let undo = bar.cellFind("↶")
    let last = bar.cellFind("⏮")
    ck undo > 2 and last > undo
    var controlsOnBar = true
    for c in undo - 1 .. last + 1:
      if s[0][c].bgHex != StripGround: controlsOnBar = false
    ck controlsOnBar
    # The omnibox: edge, field, edge.
    let left = bar.cellFind("▕", 3)
    let right = bar.cellFind("▏", left + 1)
    ck left > last and right > left
    # The bar's EMPTY cells — between the controls and the omnibox — are its
    # ground too: the row, not only what is painted on it.
    var gapOnBar = left - last > 4
    for c in last + 2 ..< left:
      if s[0][c].bgHex != StripGround: gapOnBar = false
    ck gapOnBar
    ck s[0][left].fgHex == FieldEdge and s[0][left].bgHex == StripGround
    ck s[0][right].fgHex == FieldEdge and s[0][right].bgHex == StripGround
    ck s[0][left + 1].bgHex == FieldGround
    ck s[0][right - 1].bgHex == FieldGround
    # `clamp(24em, 24vw, 40em)` of a 200-cell row: 48 cells, centred.
    let width = right - left + 1
    ck width == 48
    let centre = left + width div 2
    ck abs(centre - Cols div 2) <= 1
    ck bar.contains("Navigate to file")
    sess.quit()

  test "the open menu stands apart: the dropdown surface inside a frame":
    var sess = open()
    discard sess.waitFor("Navigate to file")
    sess.press(0, 1)
    let (rf, cf) = sess.waitFor("File")
    let s = sess.snap()
    # The frame: `┌` one row above the first item, in ui/border/primary.
    ck s[rf - 1][cf - 2].glyph == "┌"
    ck s[rf - 1][cf - 2].fgHex == MenuFrame
    ck s[rf][cf - 2].glyph == "│"
    ck s[rf][cf - 2].fgHex == MenuFrame
    # The items on the dropdown surface, over panes on the panel ground (the
    # second item: the first may be the keyboard's highlighted one).
    checkpoint("item grounds " & s[rf][cf].bgHex & " " & s[rf + 1][cf].bgHex)
    ck s[rf + 1][cf].bgHex == StripGround
    var bottom = rf
    while bottom < Rows - 1 and s[bottom][cf - 2].glyph != "└": inc bottom
    ck s[bottom][cf - 2].glyph == "└"
    ck s[bottom][cf - 2].fgHex == MenuFrame
    # What is beside the frame at mid-height is a pane body, a different
    # ground — the menu no longer melts into it.
    var right = cf
    while right < Cols - 1 and s[rf + 2][right].glyph != "│": inc right
    ck s[rf + 2][right + 1].bgHex == PanelGround
    ck s[rf + 2][right - 1].bgHex == StripGround
    sess.send("\x1b")
    discard sess.waitFor("┌", present = false)
    sess.quit()

suite "PLAT-50 on a real terminal: tab strips and dividers":

  test "strips on the desktop's ground; no rule above a strip; strips connect across a divider":
    # PLAT-51 part B: the FOCUSED pane's strip (the Files stack's, at start)
    # takes the focus colour; these are the unfocused strips' rules, so the
    # highlight is off here (`test_plat51b_pty` reads the focused strip).
    var sess = open(@["--focus-highlight=off"])
    let (re, ce) = sess.waitFor(" Event Log ")
    let s = sess.snap()
    # The inactive tabs and the strip: #1b1b1b, not the old #161616.
    let (rv, cv) = s.findRow(" VCS ")
    ck rv == 1
    ck s[rv][cv + 1].bgHex == StripGround
    ck s[rv][cv + 1].fgHex == "#727272"
    let (_, cfl) = s.findRow(" Files ")
    ck s[1][cfl + 1].bgHex == ActiveTab
    # The row above the Event Log's strip is a pane's last row of content —
    # no `─`, no junction glyph.
    let above = s.text(re - 1)
    for glyph in ["─", "┴", "┬", "├", "┤", "┼"]:
      ck not above.contains(glyph)
    # The divider cells in row 1 (the top strips): the strip's ground, so the
    # strips run on as one bar; the glyph drawn in that same ground.
    let cols = s.dividerCols(1)
    ck cols.len >= 2
    for c in cols:
      ck s[1][c].bgHex == StripGround and s[1][c].fgHex == StripGround
    # The Event Log's strip: the divider cell left of it is strip ground too.
    ck s[re][ce - 1].bgHex == StripGround
    sess.quit()

  test "body dividers: the strip's colour by default, ui/border/secondary with --dividers=subtle":
    var sess = open()
    discard sess.waitFor(" Event Log ")
    let s = sess.snap()
    let row = 10
    let cols = s.dividerCols(row)
    ck cols.len >= 2
    # The Variables / Call Trace divider (not the focused pane's side): the
    # strip's ground as a line on the panel ground beside it.
    let c = cols[^1]
    ck s[row][c].fgHex == StripGround
    ck s[row][c].bgHex == PanelGround
    sess.quit()
    var sub = open(@["--dividers=subtle", "--focus-highlight=off"])
    discard sub.waitFor(" Event Log ")
    let t = sub.snap()
    let cols2 = t.dividerCols(row)
    ck cols2 == cols
    ck t[row][cols2[^1]].fgHex == FieldEdge
    ck t[row][cols2[^1]].bgHex == PanelGround
    # Strip rows are the strip's ground in both choices.
    for c2 in t.dividerCols(1):
      ck t[1][c2].bgHex == StripGround
    sub.quit()

  test "a strip off its tabs is the split above it: dragging it up resizes":
    # With no `─` row between stacked panes, the lower pane's strip IS the
    # divider: a press on its empty ground picks the split up.
    var sess = open()
    let (re, ce) = sess.waitFor(" Event Log ")
    let s = sess.snap()
    let tabsEnd = s.text(re).cellFind("Terminal Output") +
                  "Terminal Output".len + 4
    ck tabsEnd > ce
    sess.send("\x1b[<0;" & $(tabsEnd + 1) & ";" & $(re + 1) & "M")
    for k in 1 .. 5:
      sess.send("\x1b[<32;" & $(tabsEnd + 1) & ";" & $(re + 1 - k) & "M")
    sess.send("\x1b[<0;" & $(tabsEnd + 1) & ";" & $(re + 1 - 5) & "m")
    let deadline = getMonoTime() + initDuration(seconds = 10)
    var moved = re
    while getMonoTime() < deadline and moved == re:
      moved = sess.snap().findRow(" Event Log ")[0]
      sleep(40)
    ck moved < re
    ck moved >= re - 5
    sess.quit()

  test "monochrome keeps the dividers and the selected tab legible":
    var sess = open(@["--no-color"])
    discard sess.waitFor(" Event Log ")
    let s = sess.snap()
    ck s.dividerCols(10).len >= 2
    let (_, cfl) = s.findRow(" Files ")
    ck caReverse in s[1][cfl + 1].attrs
    ck caBold in s[1][cfl + 1].attrs
    sess.quit()

  test "an unknown --dividers is refused":
    let resolved = resolveFixture("calc")
    let (output, code) = execCmdEx(tuiBinary() & " --dividers=loud " &
                                   resolved.tracePath)
    ck code == 2
    ck output.contains("unknown dividers 'loud'")

suite "PLAT-50 on a real terminal: Light":

  test "the omnibox is not white on white: the input surface inside its border":
    var sess = open(theme = "--theme=light")
    discard sess.waitFor("Navigate to file")
    let s = sess.snap()
    let bar = s.text(0)
    let left = bar.cellFind("▕", 3)
    let right = bar.cellFind("▏", left + 1)
    ck left > 0 and right > left
    # Light: the field is the EDITOR's ground as the light theme draws its
    # editor (PLAT-51; it was ui/surface/input/default #f8f6f2), its border
    # ui/border/secondary (#bfb8aa) — not white on white either way.
    ck s[0][left + 1].bgHex == LightEditorGround
    ck s[0][left + 1].bgHex != "#ffffff"
    ck s[0][left].fgHex == "#bfb8aa"
    ck s[1][1].bgHex != "#f3f3f3"
    sess.quit()

suite "PLAT-50 real terminal chrome: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
