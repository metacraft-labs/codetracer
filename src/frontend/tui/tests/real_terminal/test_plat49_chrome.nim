## test_plat49_chrome.nim — PLAT-49 part A, Tier 2. **The terminal's chrome as
## the user asked for it on 2026-10-01**, read back from a real terminal: the
## shipped `codetracer-tui` on the `calc` recording in a real PTY (TermAssert
## + libvterm), a real `replay-server` behind it, driven by the bytes a
## terminal sends — keys and SGR-1006 mouse reports.
##
##   1. MENU — row 0 holds ONE root button (`≡`) and no folder titles; F12 or
##      a click drops the first level (File … Help) below it, one per row;
##      Right on a folder opens its items as a submenu to the RIGHT of the
##      first level, level with the folder's row; a click on a folder does the
##      same; Esc backs out a level, then closes.
##   2. CLICKS ARE CLICKS — a click in a pane body, a click on a tab, and a
##      press on a tab moved less than the drag threshold produce no drag (no
##      ghost, no drop tint, no "drag"/"release" words on the status line);
##      the tab click activates the tab; a press moved past the threshold IS
##      a drag (tint + ghost), and Esc cancels it.
##   3. NO TITLE ROWS — no pane's first row is a `FILES ───` style heading:
##      every pane's first row is a tab strip on the strip's ground, and no
##      row of the body carries the old upper-cased titles or rules.
##   4. TAB STRIPS — the strip's ground is its own (ui/surface/base/raised),
##      not the pane body's (ui/surface/base/panel); the selected tab has a
##      background (ui/surface/primary/tertiary) AND a foreground
##      (ui/text/primary/headings) of its own, bold; with `--no-color` the
##      selected tab is reverse + bold and the only reversed tab.
##   5. TOOLTIPS — the pointer over a debugger control draws its tooltip (the
##      ViewModel's `transportTooltip`: label and key) on the row under it and
##      on the status line; moving off removes it.
##   6. OMNIBAR — closed, the field shows the Omnibar ViewModel's placeholder
##      on a ground of its own (not the bar's); open, the TERMINAL'S CURSOR is
##      at the caret, a bar (DECSCUSR 6) while inserting and a block after
##      `Insert`; typing and Left / Right / overwrite edit at the caret; with
##      `TERM=linux` (no cursor shapes) the caret is drawn into its cell.
##  10. NO KEY HINTS — the status line carries none, in NORMAL or in a prompt.
##  12. VARIABLES — no separator row per category (`LOCALS`, `ARGUMENTS`,
##      …), no lone expander column: every row starts with its category's
##      one-letter tag (`state_vm.categoryTag`), painted in the category's
##      colour.
##  13. DIVIDERS — every divider cell sits on the panes' own background (the
##      panel's), drawn in the subtle border foreground.
##
## No mocks: the real binary, a real recording, a real engine, a real pty.

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
import ../../../styles/generated/design_tokens
import ../../../viewmodel/viewmodels/omnibar_vm
import ../../../viewmodel/viewmodels/transport_icons
from ../../../viewmodel/viewmodels/debug_controls_vm import transportLabel
from ../../../viewmodel/viewmodels/state_vm import VariableCategory,
  categoryTag, vcLocal

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 566

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  F12 = "\x1b[24~"
  CtrlP = "\x10"
  Esc = "\x1b"
  Down = "\x1b[B"
  Right = "\x1b[C"
  Left = "\x1b[D"
  Insert = "\x1b[2~"

type Snapshot = seq[seq[Cell]]

proc hexOfColor(c: Color): string =
  if c.kind == ckRgb: hexOf((c.r.int, c.g.int, c.b.int)) else: ""

proc dark(t: DesignToken): string = DesignTokenHex[t][dmDark]

var spawned = 0

proc open(args: seq[string] = @[]; term = "xterm-256color";
          cols = Cols; rows = Rows): TuiTestSession =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded
  inc spawned
  let state = getTempDir() / ("plat49-pty-" & $getCurrentProcessId() & "-" &
                              $spawned)
  removeDir(state)
  createDir(state)
  result = newTuiTest(tuiBinary(), @["--theme=dark"] & args &
                                   @[resolved.tracePath])
    .width(cols).height(rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", term).envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .spawn()
  settleOnDebugger(result, cols, rows)

proc snap(sess: var TuiTestSession; cols = Cols; rows = Rows): Snapshot =
  discard sess.drainOutput(80)
  for r in 0 ..< rows:
    var row: seq[Cell] = @[]
    for c in 0 ..< cols:
      row.add sess.cellAt(r, c)
    result.add row

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add(if int(c.rune) == 0: " " else: $c.rune)

proc cellFind(line, needle: string; start = 0): int =
  let at = line.find(needle, start)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc rowText(sess: var TuiTestSession; row: int; cols = Cols): string =
  discard sess.drainOutput(40)
  sess.regionText(row, 0, cols, 1).split('\n')[0]

proc waitRow(sess: var TuiTestSession; row: int; needle: string;
             present = true; timeoutMs = 20000): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.rowText(row)
    if result.contains(needle) == present:
      return
  raise newException(AssertionFailedError,
    "row " & $row & (if present: " never showed '" else: " kept showing '") &
    needle & "': " & result)

proc esc(sess: var TuiTestSession) =
  sess.send(Esc)
  sleep(200)
  discard sess.drainOutput(40)

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc click(sess: var TuiTestSession; row, col: int) =
  sess.mouse(0, row, col)
  sess.mouse(0, row, col, release = true)

proc quit(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc status(sess: var TuiTestSession): string =
  discard sess.drainOutput(60)
  sess.statusRowText(Cols, Rows)

const DragWords = ["drag", "release", "no gesture", "focus ", "pressed", "click"]

proc saysNothingOfDrags(line: string): bool =
  for w in DragWords:
    if line.toLowerAscii.contains(w):
      return false
  true

suite "PLAT-49 on a real terminal: the menu is one root button with cascades":

  test "row 0 holds one root button; F12 drops the first level; Right cascades":
    var sess = open()
    let top = sess.rowText(0)
    # PLAT-50: the button bounded by edge lines (the desktop's `#menu-root`).
    ck top.startsWith("▕≡▏")
    for title in ["File", "Edit", "View", "Build", "Debug", "Help"]:
      ck not top.contains(" " & title & " ")
    sess.send(F12)
    # Row 1 already says "Files" (the Files stack's strip): wait for the
    # dropdown's SECOND item instead, which nothing else on that row spells.
    # PLAT-50: the dropdown is framed — row 1 is its top edge, its items
    # start on row 2, one cell in.
    discard sess.waitRow(3, " Edit ")
    let s = sess.snap()
    # The first level, one folder per row, starting under the button.
    var firstCol = -1
    var rows: seq[(string, int)] = @[]
    for r in 1 ..< 12:
      let line = s.text(r)
      for title in ["File", "Edit", "View", "Build", "Reset", "Debug", "Help"]:
        let at = line.cellFind(" " & title & " ")
        if at >= 0 and at < 6:
          rows.add (title, r)
          if firstCol < 0: firstCol = at
    ck rows.len == 7
    ck firstCol == 1                    # inside the frame's left edge
    var debugRow = -1
    for (t, r) in rows:
      if t == "Debug": debugRow = r
    ck debugRow > 0
    # Walk to Debug and open its submenu to the right.
    for _ in 0 ..< 5:
      sess.send(Down)
    sess.send(Right)
    discard sess.waitRow(debugRow, "Continue")
    let s2 = sess.snap()
    let line = s2.text(debugRow)
    let folderAt = line.cellFind(" Debug ")
    let itemAt = line.cellFind(" Continue ")
    ck folderAt >= 0
    ck itemAt > folderAt + 8            # BESIDE the first level, not below it
    # Esc backs out of the submenu, then closes.
    sess.esc()
    discard sess.waitRow(debugRow, "Continue", present = false)
    ck sess.rowText(2).contains(" File ")
    sess.esc()
    discard sess.waitRow(2, " File ", present = false)
    # A click on the button, then on a folder: the same cascade.
    sess.click(0, 1)
    discard sess.waitRow(3, " Edit ")
    sess.click(debugRow, 2)
    discard sess.waitRow(debugRow, "Continue")
    ck sess.rowText(debugRow).cellFind(" Continue ") > folderAt + 8
    sess.esc()
    sess.esc()
    sess.quit()

suite "PLAT-49 on a real terminal: a click is a click":

  test "clicks never drag; a tab click activates; past the threshold is a drag":
    var sess = open()
    let s0 = sess.snap()
    # A click in the editor's body.
    sess.click(20, 60)
    sleep(300)
    ck sess.status().saysNothingOfDrags()
    # A click in the call trace's body, and in the variables pane.
    sess.click(10, 170)
    sess.click(10, 130)
    sleep(300)
    ck sess.status().saysNothingOfDrags()
    let s1 = sess.snap()
    # No ghost, no tint: the strips' rows read as they did.
    ck s1.text(1) == s0.text(1)
    # A click on the VCS tab activates it (it is drawn active: bold).
    let strip = s0.text(1)
    let vcsAt = strip.cellFind(" VCS ") + 1
    ck vcsAt > 0
    sess.click(1, vcsAt + 1)
    discard sess.waitRow(1, " VCS ")
    sleep(300)
    let s2 = sess.snap()
    ck caBold in s2[1][vcsAt + 1].attrs
    ck sess.status().saysNothingOfDrags()
    # A press on the Files tab moved ONE column (under the threshold), then
    # released: a click — Files active again, the layout unchanged, no drag.
    let filesAt = strip.cellFind(" Files ") + 1
    sess.mouse(0, 1, filesAt + 1)
    sess.mouse(32, 1, filesAt + 2)            # motion, button held
    sess.mouse(0, 1, filesAt + 2, release = true)
    sleep(400)
    let s3 = sess.snap()
    ck caBold in s3[1][filesAt + 1].attrs
    ck s3.text(1).cellFind(" Files ") == filesAt - 1
    ck sess.status().saysNothingOfDrags()
    # PAST the threshold: a drag — the tint over the editor and the ghost.
    sess.mouse(0, 1, filesAt + 1)
    for c in [filesAt + 5, filesAt + 20, 60]:
      sess.mouse(32, 20, c)
    sleep(400)
    let s4 = sess.snap()
    var changed = 0
    for r in 2 ..< Rows - 2:
      for c in 30 ..< 110:
        if hexOfColor(s4[r][c].bg) != hexOfColor(s3[r][c].bg):
          inc changed
    ck changed > 100
    sess.esc()
    let s5 = sess.snap()
    var restored = true
    for r in 2 ..< Rows - 2:
      for c in 30 ..< 110:
        if hexOfColor(s5[r][c].bg) != hexOfColor(s3[r][c].bg):
          restored = false
    ck restored
    sess.quit()

suite "PLAT-49 on a real terminal: panes, strips and dividers":

  test "no title rows; strips on their own ground; the selected tab its own bg and fg; dividers on the panes' ground":
    var sess = open()
    let s = sess.snap()
    # 3. NO TITLE ROW anywhere in the body.
    for r in 1 ..< Rows - 2:
      let line = s.text(r)
      for old in ["FILES", "CALL TRACE", "VARIABLES", "TRACEPOINTS",
                  "SOURCE main.py", "TIMELINE", "AGENT"]:
        ck not line.contains(old & " ")
    # Every pane's first row is a strip: row 1 across the three top panes.
    # PLAT-50: the strip on ui/surface/primary/default, the ground the
    # desktop's tabs sit on (it was ui/surface/base/raised).
    let strip = dark(dtColorsUiSurfacePrimaryDefault)
    let activeBg = dark(dtColorsUiSurfacePrimaryTertiary)
    let activeFg = dark(dtColorsUiTextPrimaryHeadings)
    let inactiveFg = dark(dtColorsUiTextPrimaryDisabled)
    let panel = dark(dtColorsUiSurfaceBasePanel)
    let row1 = s.text(1)
    let filesAt = row1.cellFind(" Files ") + 1
    let vcsAt = row1.cellFind(" VCS ") + 1
    let editorAt = row1.cellFind(" main.py ") + 1
    ck filesAt > 0 and vcsAt > 0 and editorAt > 0
    # 4. The strip's own ground, distinct from the pane body below it.
    ck hexOfColor(s[1][vcsAt + 6].bg) == strip
    ck hexOfColor(s[3][vcsAt + 6].bg) == panel
    ck strip != panel
    # The selected tab: its own background AND foreground, bold.
    ck hexOfColor(s[1][filesAt + 1].bg) == activeBg
    ck hexOfColor(s[1][filesAt + 1].fg) == activeFg
    ck caBold in s[1][filesAt + 1].attrs
    # An inactive tab: on the strip, in the disabled tier, not bold.
    ck hexOfColor(s[1][vcsAt + 1].bg) == strip
    ck hexOfColor(s[1][vcsAt + 1].fg) == inactiveFg
    ck caBold notin s[1][vcsAt + 1].attrs
    ck activeBg != strip
    # …and the strip's EMPTY RUN past its last tab (the Variables stack's,
    # wide enough at this size to leave one) is the strip's ground too: the
    # bar itself, not only its tabs.
    let varRow = block:
      var found = -1
      for r in 1 ..< Rows - 2:
        if s.text(r).contains(" Scratchpad "):
          found = r
          break
      found
    let emptyAt = s.text(varRow).cellFind(" Scratchpad ") + 14
    ck varRow > 0 and $s[varRow][emptyAt].rune == " " and
       hexOfColor(s[varRow][emptyAt].bg) == strip
    # A LONE pane (the editor) has a one-tab strip naming its file.
    ck hexOfColor(s[1][editorAt + 1].bg) == activeBg
    # 13. Every divider cell on the panes' own ground. PLAT-50: a divider is
    # the edge line `▏` in the default (`--dividers=strip`) colour — the
    # strip's ground, the desktop's splitters' — or the focused pane's
    # border tier; in a tab-strip row it is the strip's own ground, glyph
    # and cell alike, so strips connect. No box-drawing divider is left.
    let focused = dark(dtColorsUiBorderPrimary)
    var dividers = 0
    var onPanel = 0
    var inStrip = 0
    var lineFg = 0
    var boxDrawn = 0
    for r in 1 ..< Rows - 2:
      for c in 0 ..< Cols:
        let ch = $s[r][c].rune
        # PLAT-51: a list pane's scrollbar SCRUBBER track is a `│` in
        # ui/divider/secondary in the pane's last column — a scrollbar, not a
        # box-drawing rule (Scrollbar-Scrubbers.md §4).
        let scrubberTrack = ch == "│" and
          hexOfColor(s[r][c].fg) == dark(dtColorsUiDividerSecondary)
        if ch in ["│", "─", "┼", "┬", "┴", "├", "┤"] and not scrubberTrack:
          inc boxDrawn
        if ch == "▏":
          inc dividers
          let bg = hexOfColor(s[r][c].bg)
          let fg = hexOfColor(s[r][c].fg)
          if bg == panel: inc onPanel
          if bg == strip and fg == strip: inc inStrip
          if fg in [strip, focused]: inc lineFg
    ck dividers > 50
    ck onPanel + inStrip == dividers
    ck inStrip > 0
    ck lineFg == dividers
    ck boxDrawn == 0
    # 10. No key hints on the status line.
    let st = sess.status()
    for hint in ["step-over", "rev-step", "F10", ":command", "/:find"]:
      ck not st.contains(hint)
    sess.send(":")
    sleep(300)
    ck not sess.status().contains("Enter:run")
    sess.esc()
    sess.quit()

  test "monochrome: the selected tab is reverse + bold and the only reversed tab":
    var sess = open(@["--no-color"])
    let s = sess.snap()
    let row1 = s.text(1)
    let filesAt = row1.cellFind(" Files ") + 1
    let vcsAt = row1.cellFind(" VCS ") + 1
    ck caReverse in s[1][filesAt + 1].attrs
    ck caBold in s[1][filesAt + 1].attrs
    ck caReverse notin s[1][vcsAt + 1].attrs
    sess.quit()

suite "PLAT-49 on a real terminal: tooltips and the omnibar":

  test "the pointer over a control shows the ViewModel's tooltip under it":
    var sess = open()
    let top = sess.rowText(0)
    let nextCol = top.cellFind(" " & TransportControls[controlIndex("next")].unicode & " ") + 1
    ck nextCol > 0
    sess.mouse(35, 0, nextCol)                # any-motion, no button
    let row1 = sess.waitRow(1, transportLabel("next") & " (")
    let at = row1.cellFind(" " & transportLabel("next") & " (")
    ck at >= nextCol - 2 and at <= nextCol + 1
    let tip = row1.runeSubStr(at + 1).split(')')[0] & ")"
    ck tip.startsWith("Next (")
    ck sess.status().contains(tip)
    sess.mouse(35, 20, 60)
    discard sess.waitRow(1, tip, present = false)
    sess.quit()

  test "placeholder from the ViewModel on its own ground; the caret is the terminal's cursor":
    var sess = open()
    let s = sess.snap()
    let top = s.text(0)
    let field = top.cellFind("⌕ ")
    ck field > 0
    ck top.contains("⌕ " & OmnibarPlaceholder[0 ..< 16])
    let fieldBg = hexOfColor(s[0][field].bg)
    let barBg = hexOfColor(s[0][1].bg)
    checkpoint("row 0: " & top & " field at " & $field & " bg " & fieldBg &
               " bar bg " & barBg)
    # PLAT-51 (Commands-And-Omnibox.md, "Omnibox colours on every
    # front-end"): the EDITOR's ground, superseding PLAT-50's input surface.
    ck fieldBg == dark(dtEditorThemeGround)
    ck fieldBg != barBg
    ck caItalic in s[0][field + 3].attrs
    sess.send(CtrlP)
    sleep(400)
    discard sess.drainOutput(80)
    let open0 = sess.rowText(0)
    let lead = open0.cellFind("⌕ ")
    ck sess.cursorVisible()
    ck sess.cursorPosition() == (0, lead + 2)
    ck sess.cursorShape() == csBar
    sess.send("calc")
    discard sess.waitRow(0, "⌕ calc")
    ck sess.cursorPosition() == (0, lead + 6)
    sess.send(Left)
    sleep(300)
    discard sess.drainOutput(40)
    ck sess.cursorPosition() == (0, lead + 5)
    sess.send(Insert)
    sleep(300)
    discard sess.drainOutput(40)
    ck sess.cursorShape() == csBlock
    sess.send("X")
    discard sess.waitRow(0, "⌕ calX")
    ck not sess.rowText(0).contains("⌕ calXc")
    sess.send(Right)
    sess.send(Insert)
    sleep(300)
    discard sess.drainOutput(40)
    ck sess.cursorShape() == csBar
    sess.esc()
    discard sess.waitRow(0, "⌕ calX", present = false)
    ck not sess.cursorVisible()
    sess.quit()

  test "a terminal without cursor shapes gets the caret drawn into its cell":
    var sess = open(term = "linux")
    sess.send(CtrlP)
    sess.send("ab")
    discard sess.waitRow(0, "⌕ ab")
    let s = sess.snap()
    let lead = s.text(0).cellFind("⌕ ")
    ck not sess.cursorVisible()
    # The insert caret: the cell after the query, underlined.
    ck s[0][lead + 4].underline != usNone
    sess.send(Insert)
    sleep(300)
    let s2 = sess.snap()
    ck caReverse in s2[0][lead + 4].attrs
    sess.esc()
    sess.quit()

suite "PLAT-49 on a real terminal: the variables pane":

  test "no category rows, no lone first column: each row starts with its tag":
    var sess = open(@["--goto=60"])
    let s = sess.snap()
    let row1 = s.text(1)
    let varsAt = row1.cellFind(" Variables ")
    ck varsAt > 0
    # The pane's left edge: the column after the divider left of its strip.
    let col0 = varsAt
    var tagged = 0
    for r in 2 ..< 20:
      let line = s.text(r)
      let body = line.runeSubStr(col0, 40)
      for sep in ["LOCALS", "ARGUMENTS", "GLOBALS", "WATCHES", "REGISTERS",
                  "RETURN VALUES"]:
        ck not body.contains(sep)
      let first = $s[r][col0].rune
      if first.strip.len == 0:
        continue
      ck first in ["L", "A", "G", "R", "X", "W"]
      inc tagged
      if first == categoryTag(vcLocal):
        ck hexOfColor(s[r][col0].fg) == dark(dtColorsEditorSyntaxType)
        ck caBold in s[r][col0].attrs
    ck tagged >= 10
    sess.quit()

suite "PLAT-49 pty: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
