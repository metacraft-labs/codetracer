## test_plat46_design_tokens.nim — PLAT-46, Tier 2. The terminal front-end
## painted from `codetracer-design-system`, read back off a REAL terminal.
##
## ## What only this file can say
##
## `app/tests/test_degraded_style_tables.nim` asserts the role table and its
## derivation in process. Every one of those assertions would still pass on a
## binary whose driver never resolved a role, whose shell forgot a surface fill,
## whose probe never ran or whose status line said nothing. So every claim here
## is read off the cells libvterm parsed from the SHIPPED binary's byte stream
## (or off a real tmux's own `capture-pane`), and every expected colour is the
## RESOLVED TOKEN HEX from the generated `design_tokens.nim` — never the role
## table asserted against itself:
##
##   * token fidelity: keyword, pane border (ordinary and focused), active and
##     inactive tab, status line, current line, pane body and editor body, in
##     both design-system modes;
##   * surfaces distinct where the design says so, by OKLab distance;
##   * every cell's background is the TUI's (deliverable 8);
##   * WCAG AA contrast of every painted (fg, bg) pair, with the pairs the
##     design system itself fails in a COUNTED register of filed issues;
##   * background detection: an OSC 11 light answer, a dark one, `COLORFGBG`
##     alone, no answer at all, and `--theme` overriding an answer;
##   * `--palette=terminal`: no 24-bit or 256-colour SGR in the byte stream,
##     and every painted cell a palette reference;
##   * truecolor detection: a PTY that answers DECRQSS gets 24-bit under
##     `TERM=xterm` with no `COLORTERM`, and one that does not gets the derived
##     16-colour rung;
##   * a real tmux: the withheld-RGB report with default settings, 24-bit with
##     `terminal-features RGB` (read through tmux's own `capture-pane -e`), and
##     the pane's `window-style` background deciding the mode;
##   * §4.3's `:theme <dark|light>` typed at the live binary repaints every
##     surface in the other mode, and back.
##
## ## The one stand-in, and why it is not a mock
##
## The TERMINAL'S HALF of the start-up query round is typed by this file: when
## the child's byte stream carries `OSC 11 ; ?` (or `DCS $ q m`), this file
## writes the answer a terminal would, through the real pty. `nim-libvterm` is
## a parser, not a terminal, and answers nothing — so without this the
## detection code would only ever be exercised on its "no answer" arm. The
## subject (the binary, its framer, its resolver, its repaint) is untouched;
## the bytes are exactly a terminal's, and the no-answer arm is a case of its
## own. The tmux cases need no stand-in at all: tmux answers for itself.
##
## ## No skips
##
## A missing binary, fixture or `tmux` FAILS by name with the recipe.
##
## ## Templates, not procs, for anything that calls `check`
##
## See `test_real_capability_negotiation.nim`: `check` inside a proc reports
## `[OK]` on failure.

import std/[monotimes, os, osproc, strutils, tables, times, unicode, unittest]

import nim_libvterm
import term_assert

import ../../app/theme/colour_math
import ../../../styles/generated/design_tokens
import ../../testing/dual_snap
import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 159

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  Wide = (cols: 120, rows: 40)
    ## Standard profile: the source shows `def add` (line 29) and the panes sit
    ## side by side.
  Stacked = (cols: 200, rows: 30)
    ## The shared default's Variables stack (`[Variables]  Scratchpad`) with
    ## room to spell its inactive tab, and a rightmost strip with bar left over
    ## past its label (PLAT-45 sizes every region minimum-first, so at 120
    ## columns the strips are cut at their labels).
  MinSurfaceDistance = 0.03
    ## OKLab distance two surfaces the design distinguishes must keep on the
    ## screen. About 1.5 just-noticeable differences.
  ProbeWindowMs = 200
    ## `CT_TUI_PROBE_TIMEOUT_MS` for the cases that do not answer.

type
  FiledPair = tuple[mode: DesignMode; fg, bg: DesignToken; issue: string]

const
  ContrastIssue = "codetracer-specs/issues/2026-09-26-design-system-contrast-failures.md"
  CurrentLineIssue = "codetracer-specs/issues/2026-09-26-design-system-current-line-equals-comment.md"
  FiledContrastFailures: array[36, FiledPair] = [
    (dmDark, dtColorsUiBorderSecondary, dtColorsUiSurfaceBasePanel, ContrastIssue),
    (dmDark, dtColorsUiBorderSecondary, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmDark, dtColorsUiDividerSecondary, dtColorsUiSurfaceBasePanel, ContrastIssue),
    (dmDark, dtColorsEditorSyntaxComment, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmDark, dtColorsUiTextPrimaryCaptionSubtle, dtColorsEditorSyntaxSelection, ContrastIssue),
    (dmDark, dtColorsEditorSyntaxComment, dtColorsEditorSyntaxCurrentLine, CurrentLineIssue),
    (dmDark, dtColorsEditorSyntaxPrimary, dtColorsEditorSyntaxCurrentLine, CurrentLineIssue),
    (dmDark, dtColorsEditorSyntaxKeyword, dtColorsEditorSyntaxCurrentLine, CurrentLineIssue),
    (dmDark, dtColorsEditorSyntaxTertiary, dtColorsEditorSyntaxCurrentLine, CurrentLineIssue),
    (dmLight, dtColorsUiBorderSecondary, dtColorsUiSurfaceBasePanel, ContrastIssue),
    (dmLight, dtColorsUiBorderFocus, dtColorsUiSurfaceBasePanel, ContrastIssue),
    (dmLight, dtColorsUiDividerSecondary, dtColorsUiSurfaceBasePanel, ContrastIssue),
    (dmLight, dtColorsUiTextPrimaryCaptionSubtle, dtColorsUiSurfaceBasePanel, ContrastIssue),
    (dmLight, dtColorsUiTextPrimaryCaption, dtColorsUiSurfaceBaseRaised, ContrastIssue),
    (dmLight, dtColorsUiTextSuccessPrimary, dtColorsUiSurfaceBasePanel, ContrastIssue),
    (dmLight, dtColorsUiTextSuccessPrimary, dtColorsUiSurfaceBaseRaised, ContrastIssue),
    (dmLight, dtColorsEditorActionPrimary, dtColorsUiSurfaceBasePanel, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxKeyword, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxType, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxString, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxNumber, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxComment, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxPrimary, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxPunctuation, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxTertiary, dtColorsEditorSurfacePrimary, ContrastIssue),
    (dmLight, dtColorsEditorActionSecondary, dtColorsEditorSyntaxSelection, ContrastIssue),
    (dmLight, dtColorsUiTextInformationPrimary, dtColorsEditorSyntaxSelection, ContrastIssue),
    (dmLight, dtColorsUiTextPrimaryCaptionSubtle, dtColorsEditorSyntaxSelection, ContrastIssue),
    (dmLight, dtColorsUiTextSuccessPrimary, dtColorsEditorSyntaxSelection, ContrastIssue),
    (dmLight, dtColorsEditorSyntaxComment, dtColorsEditorSyntaxCurrentLine, CurrentLineIssue),
    (dmLight, dtColorsEditorSyntaxPrimary, dtColorsEditorSyntaxCurrentLine, CurrentLineIssue),
    (dmLight, dtColorsEditorSyntaxTertiary, dtColorsEditorSyntaxCurrentLine, CurrentLineIssue),
    # Not new: the design system's yellow on its own light panel was matched,
    # until the light editor ground was measured (2026-09-28), by the
    # desktop register's (action/secondary, editor ground) entry, because the
    # composed light ground WAS the light panel. Filed where it belongs.
    (dmLight, dtColorsEditorActionSecondary, dtColorsUiSurfaceBasePanel, ContrastIssue),
    # PLAT-49 part B: the call trace's return value, painted in the design
    # system's information colour (the desktop's Light return colour,
    # exactly), on the Light panel — already in the issue's table (4.00:1);
    # the terminal had not painted it on a panel before.
    (dmLight, dtColorsUiTextInformationPrimary, dtColorsUiSurfaceBasePanel, ContrastIssue),
    # PLAT-49 part B review: the call the debugger is in sits on the active-
    # row ground (ui/surface/primary/secondary-hover), as the desktop puts it
    # on a ground of its own. Its argument and return colours clear 4.5:1 on
    # it in Dark; their Light values fail on every Light ground, the panel
    # above included (1.86:1 and 2.91:1 here) — the same two tokens, filed.
    (dmLight, dtColorsUiTextSuccessPrimary, dtColorsUiSurfacePrimarySecondaryHover, ContrastIssue),
    (dmLight, dtColorsUiTextInformationPrimary, dtColorsUiSurfacePrimarySecondaryHover, ContrastIssue)]
    ## THE PAIRS THE DESIGN SYSTEM ITSELF FAILS, where this front-end paints
    ## them — filed, not silently adjusted (PLAT-46's contrast requirement).
    ## COUNTED: a new failing pair reddens the sweep until it is filed here
    ## and in the issue.

  DesktopIssue = "codetracer-specs/issues/2026-09-27-desktop-editor-and-focus-contrast-below-aa.md"
  DesktopParityPairs: array[10, FiledPair] = [
    (dmDark, dtColorsUiBorderPrimary, dtColorsUiSurfaceBaseCanvas, DesktopIssue),
    (dmDark, dtEditorThemeRuleComment, dtEditorThemeExecutionLine, DesktopIssue),
    (dmDark, dtEditorThemeLineNumber, dtEditorThemeGround, DesktopIssue),
    (dmLight, dtColorsUiBorderPrimary, dtColorsUiSurfaceBaseCanvas, DesktopIssue),
    (dmLight, dtColorsUiBorderSecondary, dtColorsUiSurfaceBaseCanvas, DesktopIssue),
    (dmLight, dtColorsEditorActionSecondary, dtEditorThemeExecutionLine, DesktopIssue),
    (dmLight, dtEditorThemeRuleComment, dtEditorThemeExecutionLine, DesktopIssue),
    (dmLight, dtEditorThemeLineNumber, dtEditorThemeGround, DesktopIssue),
    (dmLight, dtEditorThemeRuleString, dtEditorThemeGround, DesktopIssue),
    (dmLight, dtEditorThemeRuleDefault, dtEditorThemeGround, DesktopIssue)]
    ## PLAT-47: THE PAIRS THE DESKTOP ITSELF RENDERS BELOW THE FLOOR, which the
    ## terminal now reproduces because it must EQUAL the desktop: its editor is
    ## the desktop's Monaco theme (measured resting line numbers 2.04:1, a
    ## comment on the execution line 3.80:1), and its focused pane carries the
    ## desktop's selected-panel outline (`ui/border/primary`, 2.01:1 against
    ## the desktop's own panel, 2.35:1 against the terminal's divider ground).
    ## Light is opt-in (`--theme=light`; detection never selects it) and its
    ## editor is the desktop's `codetracerWhite` theme on the ground the
    ## desktop's light theme measurably draws (its dark panel, #282828). A
    ## SEPARATE register from the design system's, which does
    ## not grow: these are the desktop's pairs, filed against the desktop.
    ## COUNTED, like the other.

  ChromeTokens = [dtColorsUiBorderSecondary, dtColorsUiBorderFocus,
                  dtColorsUiBorderPrimary, dtColorsUiDividerSecondary,
                  dtColorsUiBorderAction,
                  dtColorsUiTextPrimaryCaptionSubtle,
                  dtColorsUiTextPrimaryDisabled, dtColorsEditorSyntaxTertiary,
                  dtColorsEditorSyntaxSubtle, dtColorsEditorSyntaxDisabled,
                  dtColorsEditorActionSecondary,
                  dtEditorThemeLineNumber, dtEditorThemeActiveLineNumber]
    ## Tokens painted as CHROME (borders, rules, muted captions, line numbers,
    ## de-emphasised code, the gutter's execution pointer), held to WCAG's
    ## 3:1 rather than 4.5:1.

var tracePath = ""

proc hexOfColor(c: Color): string =
  if c.kind == ckRgb: hexOf((c.r.int, c.g.int, c.b.int)) else: ""

proc hexT(t: DesignToken; mode: DesignMode): string = DesignTokenHex[t][mode]

proc builderFor(args: seq[string]; cols, rows: int; term = "xterm-256color";
                colorterm = "truecolor"; colorFgBg = "";
                probeMs = ProbeWindowMs): TuiTestBuilder =
  ## The shipped binary with a KNOWN colour environment and its bytes kept.
  var b = newTuiTest(tuiBinary(), args).width(cols).height(rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
    .envSet("TERM", term).envSet("LANG", "en_US.UTF-8")
    .envSet("CT_TUI_PROBE_TIMEOUT_MS", $probeMs)
  b = if colorterm.len > 0: b.envSet("COLORTERM", colorterm)
      else: b.envRemove("COLORTERM")
  b = if colorFgBg.len > 0: b.envSet("COLORFGBG", colorFgBg)
      else: b.envRemove("COLORFGBG")
  b

proc rowOf(sess: var TuiTestSession; cols, rows: int; needle: string): int =
  for r in 0 ..< rows:
    if sess.regionText(r, 0, cols, 1).contains(needle):
      return r
  -1

proc colOf(sess: var TuiTestSession; row, cols: int; needle: string): int =
  ## The CELL column of `needle` on `row` (box glyphs are multi-byte, so a
  ## byte offset is not a column).
  let text = sess.regionText(row, 0, cols, 1)
  let at = text.find(needle)
  if at < 0: return -1
  text[0 ..< at].runeLen

proc waitForTranscript(sess: var TuiTestSession; needle: string;
                       timeoutMs = 20000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(20)
    if sess.transcriptBytes().contains(needle):
      return true
    if not sess.isAlive:
      return false
  false

proc waitForStatus(sess: var TuiTestSession; cols, rows: int; needle: string;
                   timeoutMs = 60000): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    let row = statusRowText(sess, cols, rows)
    if row.contains(needle):
      waitForCompleteFrame(sess, cols, rows, timeoutMs = 30000)
      return row
    if not sess.isAlive:
      break
  statusRowText(sess, cols, rows)

proc finish(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 15))
  sess.close()

type
  Fidelity = object
    ## What one screen says, read off its cells.
    keywordFg, statusBg, modeFg: string
    ruleFgs: seq[string]
    currentLineBg, panelBg, editorBg: string
    unfilled, cells: int

proc lastColBeforeRule(sess: var TuiTestSession; row, fromCol, cols: int): int =
  ## The column just left of the first divider (`│`, since PLAT-50 `▏`) at or
  ## right of `fromCol` on `row` — the last body cell of the region `fromCol`
  ## is in — or `cols - 2` when the region runs to the screen's edge.
  for c in fromCol ..< cols:
    if $sess.cellAt(row, c).rune in ["│", "▏"]:
      return max(fromCol, c - 1)
  cols - 2

proc readWide(sess: var TuiTestSession): Fidelity =
  let (cols, rows) = Wide
  let defRow = rowOf(sess, cols, rows, "def add")
  if defRow >= 0:
    result.keywordFg = hexOfColor(sess.cellAt(defRow, colOf(sess, defRow, cols, "def add")).fg)
  # Every line glyph of the top three rows is a border — the focused pane's
  # in the focus role, the others in the ordinary one. Both are collected.
  # PLAT-50: there are no rule rows; the top bar's field and menu button are
  # bounded by edge lines (`▕` `▏`) in ui/border/secondary on row 0, and the
  # focused region at start — the Files STACK (PLAT-45) — has its right-hand
  # divider `▏` in the focus role on its body rows (row 2). A divider in a
  # strip row (row 1) is the strip's own ground (`srDividerStrip`).
  for r in 0 .. 2:
    for c in 0 ..< cols:
      let cell = sess.cellAt(r, c)
      if $cell.rune in ["─", "│", "▏", "▕"]:
        let h = hexOfColor(cell.fg)
        if h notin result.ruleFgs:
          result.ruleFgs.add h
  let execRow = rowOf(sess, cols, rows, "-->")
  if execRow >= 0:
    let c = colOf(sess, execRow, cols, "-->") + 6
    result.currentLineBg = hexOfColor(sess.cellAt(execRow, c).bg)
  result.statusBg = hexOfColor(sess.cellAt(rows - 1, cols - 1).bg)
  # The mode indicator, found by its text: since PLAT-49 part B the footer's
  # auto-hide labels open the status row, and the mode follows them.
  let modeCol = colOf(sess, rows - 1, cols, "NORMAL")
  result.modeFg = hexOfColor(sess.cellAt(rows - 1, max(0, modeCol)).fg)
  # A pane body: the Variables pane's last column before its separator, three
  # rows under its tab strip (PLAT-49: the strip is the pane's first row).
  # Found by the separator rather than by the screen's edge: since PLAT-45
  # the Variables pane is not the rightmost region.
  let varRow = rowOf(sess, cols, rows, " Variables ")
  if varRow >= 0:
    let c = lastColBeforeRule(sess, varRow + 3,
                              colOf(sess, varRow, cols, " Variables "), cols)
    result.panelBg = hexOfColor(sess.cellAt(varRow + 3, c).bg)
  # The editor body: the last cell of a short source line (line 3 is empty)
  # before the Source pane's separator — found by the separator, because the
  # shared default's Source pane is narrower than a fixed offset.
  # Searched in the Source pane's own columns (from its `main.py` tab on):
  # since PLAT-49 part B the event log's `#` column spells `   3 ` too.
  var srcRow = -1
  let tabRow = rowOf(sess, cols, rows, " main.py ")
  if tabRow >= 0:
    let srcCol = max(0, colOf(sess, tabRow, cols, " main.py ") - 1)
    for r in tabRow + 1 ..< rows:
      if sess.regionText(r, srcCol, 8, 1).contains("   3 "):
        srcRow = r
        break
  if srcRow >= 0:
    let c = lastColBeforeRule(sess, srcRow,
                              colOf(sess, srcRow, cols, "   3 "), cols)
    result.editorBg = hexOfColor(sess.cellAt(srcRow, c).bg)
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      inc result.cells
      if sess.cellAt(r, c).bg.kind != ckRgb:
        inc result.unfilled

proc focusedBorders(sess: var TuiTestSession; cols, rows: int;
                    focusHex: string): int =
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let cell = sess.cellAt(r, c)
      if $cell.rune in ["─", "│", "▏"] and
         hexOfColor(cell.fg) == focusHex:
        inc result

type
  TabRead = object
    activeBg, inactiveBg, barBg, activeFg, inactiveFg: string
    activeBold, inactiveBold: bool

proc readTabs(sess: var TuiTestSession): TabRead =
  let (cols, rows) = Stacked
  let r = rowOf(sess, cols, rows, " Variables ")
  if r < 0: return
  let active = colOf(sess, r, cols, "Variables")
  # The Variables stack's inactive tab: Scratchpad, in the shared default
  # (PLAT-45) — the Timeline is a tab of the events stack, on another row.
  let inactive = colOf(sess, r, cols, "Scratch")
  result.activeBg = hexOfColor(sess.cellAt(r, active).bg)
  result.activeFg = hexOfColor(sess.cellAt(r, active).fg)
  result.inactiveBg = hexOfColor(sess.cellAt(r, inactive).bg)
  result.inactiveFg = hexOfColor(sess.cellAt(r, inactive).fg)
  result.barBg = hexOfColor(sess.cellAt(r, cols - 3).bg)
  result.activeBold = caBold in sess.cellAt(r, active).attrs
  result.inactiveBold = caBold in sess.cellAt(r, inactive).attrs

proc tokensWithHex(hex: string; mode: DesignMode): seq[DesignToken] =
  for t in DesignToken:
    if DesignTokenHex[t][mode] == hex:
      result.add t

proc isFiled(mode: DesignMode; fgHex, bgHex: string): bool =
  for f in FiledContrastFailures:
    if f.mode == mode and hexT(f.fg, mode) == fgHex and hexT(f.bg, mode) == bgHex:
      return true
  for f in DesktopParityPairs:
    if f.mode == mode and hexT(f.fg, mode) == fgHex and hexT(f.bg, mode) == bgHex:
      return true
  false

proc contrastViolations(sess: var TuiTestSession; cols, rows: int;
                        mode: DesignMode; pairs: var int): seq[string] =
  ## Every distinct (fg, bg) pair painted under a GLYPH, against WCAG AA.
  var seen = initTable[string, bool]()
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let cell = sess.cellAt(r, c)
      let ch = $cell.rune
      if cell.rune.int32 == 0 or ch.strip().len == 0:
        continue
      # PLAT-50: THE EDGE LINES ARE BOUNDARIES, NOT TEXT. A divider `▏` and
      # a field / menu-button edge `▕` `▏` are drawn in the colours the
      # desktop's own splitters and borders measure (#1b1b1b splitters
      # against #282828 panels; ui/border/secondary round the omnibox), and a
      # divider in a tab-strip row is deliberately the strip's own ground (the
      # user, 2026-10-02) — legible as a line only in monochrome. Those pairs
      # are asserted against the desktop in `test_plat50_desktop_reference`
      # and `test_plat50_chrome`; the text-contrast floor is not theirs.
      if ch in ["▏", "▕"]:
        continue
      let fg = hexOfColor(cell.fg)
      let bg = hexOfColor(cell.bg)
      if fg.len == 0 or bg.len == 0:
        continue
      let key = fg & "/" & bg
      if key in seen:
        continue
      seen[key] = true
      inc pairs
      let ratio = contrastRatio(parseHexColour(fg), parseHexColour(bg))
      if ratio >= 4.5:
        continue
      var chrome = false
      for t in tokensWithHex(fg, mode):
        if t in ChromeTokens: chrome = true
      if chrome and ratio >= 3.0:
        continue
      if isFiled(mode, fg, bg):
        continue
      result.add key & " at (" & $r & "," & $c & ") '" & ch & "' ratio " &
        formatFloat(ratio, ffDecimal, 2) & " fg tokens " &
        $tokensWithHex(fg, mode) & " bg tokens " & $tokensWithHex(bg, mode)

suite "PLAT-46 Tier 2: the terminal painted from the design system":

  test "the binary and the fixture exist":
    if not fileExists(tuiBinary()):
      checkpoint("missing " & tuiBinary() & " — run `just build-tui`")
    ck fileExists(tuiBinary())
    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      checkpoint("the `calc` fixture is unavailable: " & resolved.detail &
                 " — `just test-tui` records and caches it")
    ck resolved.outcome == foRecorded
    tracePath = resolved.tracePath
    ck dirExists(tracePath)

  for mode in [dmDark, dmLight]:
    let modeName = if mode == dmDark: "dark" else: "light"
    test "token fidelity and surfaces, read back, in the " & modeName & " mode":
      # `--theme` pins the mode so the case asserts ONE mode's hexes; the
      # detection is the background cases' subject.
      var sess = builderFor(@["--theme=" & modeName, tracePath],
                            Wide.cols, Wide.rows).spawn()
      settleOnDebugger(sess, Wide.cols, Wide.rows)
      let f = readWide(sess)
      checkpoint(modeName & " read back: " & $f)
      # PLAT-47: the editor is the desktop's Monaco theme, and the focused
      # pane's outline is the desktop's selected-panel colour.
      ck f.keywordFg == hexT(dtEditorThemeRuleKeyword, mode)
      ck hexT(dtColorsUiBorderSecondary, mode) in f.ruleFgs
      ck hexT(dtColorsUiBorderPrimary, mode) in f.ruleFgs
      ck focusedBorders(sess, Wide.cols, Wide.rows,
                        hexT(dtColorsUiBorderPrimary, mode)) > 0
      ck f.statusBg == hexT(dtColorsUiSurfaceBaseRaised, mode)
      ck f.modeFg == hexT(dtColorsUiTextSuccessPrimary, mode)
      ck f.currentLineBg == hexT(dtEditorThemeExecutionLine, mode)
      ck f.panelBg == hexT(dtColorsUiSurfaceBasePanel, mode)
      ck f.editorBg == hexT(dtEditorThemeGround, mode)
      # DELIVERABLE 8: NO CELL shows the terminal's own background.
      ck f.cells == Wide.cols * Wide.rows
      ck f.unfilled == 0
      # THE EDITOR SITS WHERE THE DESKTOP'S DOES (PLAT-47). Dark: on the
      # pane's own surface — the desktop renders Monaco transparent over its
      # pane (PLAT-46 had kept the two apart by OKLab distance). Light: on the
      # ground the desktop's light theme MEASURABLY draws, its dark panel
      # (`plat47-desktop-parity-light.electron.json`), which is not the design
      # system's light panel the terminal's chrome uses.
      if mode == dmDark:
        ck f.editorBg == f.panelBg
      else:
        ck f.editorBg != f.panelBg
      # CONTRAST, over every painted pair on this screen.
      var pairs = 0
      let bad = contrastViolations(sess, Wide.cols, Wide.rows, mode, pairs)
      checkpoint(modeName & ": " & $pairs & " distinct painted pair(s)")
      for b in bad:
        checkpoint("UNFILED CONTRAST FAILURE (" & modeName & "): " & b)
      ck pairs >= 10
      ck bad.len == 0
      finish(sess)

      var tabs = builderFor(@["--theme=" & modeName, tracePath],
                            Stacked.cols, Stacked.rows).spawn()
      settleOnDebugger(tabs, Stacked.cols, Stacked.rows)
      let t = readTabs(tabs)
      checkpoint(modeName & " tabs: " & $t)
      # PLAT-49, the user's direction over PLAT-47's measured single ground:
      # the strip on its own ground, the selected tab on a background
      # (ui/surface/primary/tertiary) and in a foreground
      # (ui/text/primary/headings) of its own, bold; inactive tabs on the
      # strip in the disabled tier. PLAT-50 (the user, 2026-10-02: inactive
      # tabs "not black"): the strip's ground is ui/surface/primary/default,
      # the ground the desktop's tabs sit on, no longer base/raised.
      ck t.activeBg == hexT(dtColorsUiSurfacePrimaryTertiary, mode)
      ck t.inactiveBg == hexT(dtColorsUiSurfacePrimaryDefault, mode)
      ck t.barBg == hexT(dtColorsUiSurfacePrimaryDefault, mode)
      ck t.barBg != hexT(dtColorsUiSurfaceBasePanel, mode)
      ck t.activeFg == hexT(dtColorsUiTextPrimaryHeadings, mode)
      ck t.inactiveFg == hexT(dtColorsUiTextPrimaryDisabled, mode)
      ck t.activeBold and not t.inactiveBold
      ck oklabDistance(parseHexColour(t.activeFg),
                       parseHexColour(t.inactiveFg)) >= MinSurfaceDistance
      var tabPairs = 0
      let tabBad = contrastViolations(tabs, Stacked.cols, Stacked.rows, mode,
                                      tabPairs)
      for b in tabBad:
        checkpoint("UNFILED CONTRAST FAILURE (" & modeName & ", stacked): " & b)
      ck tabBad.len == 0
      finish(tabs)

  test "every entry of the filed-failure register is a genuine failure":
    # The register may not become a place to park a pair that PASSES: every
    # entry is recomputed from the tokens and must fail its floor (4.5:1, or
    # 3:1 for a chrome token), and must name its issue.
    ck FiledContrastFailures.len == 36   # 32 + the pair the composed light ground masked
                                         # + PLAT-49 part B's return colour
                                         # + its two on the active-row ground
    var genuine = 0
    for f in FiledContrastFailures:
      let ratio = contrastRatio(parseHexColour(hexT(f.fg, f.mode)),
                                parseHexColour(hexT(f.bg, f.mode)))
      let floor = if f.fg in ChromeTokens: 3.0 else: 4.5
      if ratio >= floor:
        checkpoint("NOT A FAILURE: " & $f & " ratio " & $ratio)
      else:
        inc genuine
      ck f.issue.startsWith("codetracer-specs/issues/2026-09-26-design-system-")
    ck genuine == FiledContrastFailures.len
    # …and the desktop's own pairs (PLAT-47), on the same terms.
    ck DesktopParityPairs.len == 10
    var desktopGenuine = 0
    for f in DesktopParityPairs:
      let ratio = contrastRatio(parseHexColour(hexT(f.fg, f.mode)),
                                parseHexColour(hexT(f.bg, f.mode)))
      let floor = if f.fg in ChromeTokens: 3.0 else: 4.5
      if ratio >= floor:
        checkpoint("NOT A FAILURE: " & $f & " ratio " & $ratio)
      else:
        inc desktopGenuine
      ck f.issue == DesktopIssue
    ck desktopGenuine == DesktopParityPairs.len

  test "OSC 11: a light answer is REPORTED and still paints Dark; a dark answer Dark":
    # PLAT-47: the user's decision of 2026-09-27 — background detection does
    # not select Light until the design system's Light editor surface is fixed
    # (`capabilities.AutoDetectSelectsLight`); the answer is still read and
    # named on the status line, with the flag that selects Light.
    for (reply, hex, expectMode) in [
        ("\x1b]11;rgb:ffff/ffff/ffff\x1b\\", "#ffffff", dmDark),
        ("\x1b]11;rgb:1e1e/1e1e/2e2e\x07", "#1e1e2e", dmDark)]:
      # THE NOTE, read at the Stacked width: since PLAT-49 part B the footer's
      # auto-hide labels open the status row, and at 120 columns the light
      # answer's whole sentence (with the flag that selects Light) no longer
      # fits beside them — the note is cut at its end, as every note is.
      var wide = builderFor(@[tracePath], Stacked.cols, Stacked.rows).spawn()
      let asked = waitForTranscript(wide, "\x1b]11;?")
      ck asked
      wide.send(reply)
      let want = "bg: osc11 " & hex &
                 (if hex == "#ffffff": " (light; --theme=light to use it)"
                  else: "") & " -> dark"
      let status = waitForStatus(wide, Stacked.cols, Stacked.rows, want)
      checkpoint("status after " & hex & ": " & status)
      ck status.contains(want)
      finish(wide)
      # THE CELLS, at the Wide geometry the readers know, on a session whose
      # status row names the answer's source as far as 120 columns allow. The
      # answer may land inside the bounded start-up wait (frame 0 already
      # says so) or after it (a repaint says so); either way the DEBUGGER's
      # frame is what the cells are read from.
      var sess = builderFor(@[tracePath], Wide.cols, Wide.rows).spawn()
      ck waitForTranscript(sess, "\x1b]11;?")
      sess.send(reply)
      ck waitForStatus(sess, Wide.cols, Wide.rows,
                       "bg: osc11 " & hex).contains("bg: osc11 " & hex)
      # Frame 1 by its own note (the debugger's position): at 120 columns,
      # beside the footer's labels, frame 0's long light note is cut before
      # its `opening …`, which is what `settleOnDebugger` tells frames by.
      ck waitForStatus(sess, Wide.cols, Wide.rows, " tick ").contains(" tick ")
      settleOnDebugger(sess, Wide.cols, Wide.rows)
      let f = readWide(sess)
      ck f.editorBg == hexT(dtEditorThemeGround, expectMode)
      ck f.panelBg == hexT(dtColorsUiSurfaceBasePanel, expectMode)
      finish(sess)

  test "COLORFGBG is read but does not select Light, and no answer at all is Dark in time":
    var fgbg = builderFor(@[tracePath], Wide.cols, Wide.rows,
                          colorFgBg = "0;15").spawn()
    waitForOpeningFrame(fgbg, Wide.cols, Wide.rows)
    let opening = statusRowText(fgbg, Wide.cols, Wide.rows)
    checkpoint("COLORFGBG=0;15 frame 0: " & opening)
    # PLAT-47: read, reported, and Dark (`AutoDetectSelectsLight`).
    ck opening.contains("bg: colorfgbg -> dark")
    settleOnDebugger(fgbg, Wide.cols, Wide.rows)
    ck readWide(fgbg).editorBg == hexT(dtEditorThemeGround, dmDark)
    finish(fgbg)

    let started = getMonoTime()
    var silent = builderFor(@[tracePath], Wide.cols, Wide.rows).spawn()
    waitForOpeningFrame(silent, Wide.cols, Wide.rows)
    let frame0Ms = (getMonoTime() - started).inMilliseconds
    let silentRow = statusRowText(silent, Wide.cols, Wide.rows)
    checkpoint("no answer: frame 0 at " & $frame0Ms & " ms: " & silentRow)
    ck silentRow.contains("bg: default -> dark")
    # WITHIN THE TIMEOUT: the wait is bounded by `CT_TUI_PROBE_TIMEOUT_MS`,
    # and the rest of a cold start fits in far less than the 5 s allowed here.
    ck frame0Ms < 5000
    settleOnDebugger(silent, Wide.cols, Wide.rows)
    ck readWide(silent).editorBg == hexT(dtEditorThemeGround, dmDark)
    finish(silent)

  test "--theme overrides every detected background":
    var sess = builderFor(@["--theme=dark", tracePath], Wide.cols, Wide.rows,
                          colorFgBg = "0;15").spawn()
    waitForOpeningFrame(sess, Wide.cols, Wide.rows)
    ck statusRowText(sess, Wide.cols, Wide.rows).contains("bg: flag -> dark")
    # The OSC 11 query is not even sent: the mode is not a question.
    ck not sess.transcriptBytes().contains("\x1b]11;?")
    sess.send("\x1b]11;rgb:ffff/ffff/ffff\x1b\\")
    settleOnDebugger(sess, Wide.cols, Wide.rows)
    discard sess.drainOutput(300)
    ck readWide(sess).editorBg == hexT(dtEditorThemeGround, dmDark)
    finish(sess)

  test "--palette=terminal: only the sixteen colours and the defaults":
    var sess = builderFor(@["--palette=terminal", tracePath],
                          Wide.cols, Wide.rows).spawn()
    settleOnDebugger(sess, Wide.cols, Wide.rows)
    let bytes = sess.transcriptBytes()
    ck sess.transcriptDroppedBytes() == 0
    # Every SGR in the stream, parameter by parameter.
    var sgrs = 0
    var extended: seq[string] = @[]
    var i = 0
    while true:
      let at = bytes.find("\x1b[", i)
      if at < 0: break
      var j = at + 2
      while j < bytes.len and bytes[j] in {'0' .. '9', ';', ':'}:
        inc j
      if j < bytes.len and bytes[j] == 'm':
        inc sgrs
        let params = bytes[at + 2 ..< j]
        for p in params.split(';'):
          if p.contains(':') or p in ["38", "48", "58"]:
            extended.add params
            break
      i = at + 2
    checkpoint($sgrs & " SGR sequence(s); extended-colour ones: " & $extended)
    ck sgrs > 20
    ck extended.len == 0
    # …and every painted cell is a PALETTE REFERENCE (an index 0–15 or the
    # default), so the terminal's own palette decides every colour on screen.
    var absolute = 0
    var indexed = 0
    for r in 0 ..< Wide.rows:
      for c in 0 ..< Wide.cols:
        let cell = sess.cellAt(r, c)
        for col in [cell.fg, cell.bg]:
          case col.kind
          of ckRgb: inc absolute
          of ckIndexed:
            if col.idx > 15: inc absolute else: inc indexed
          of ckDefault: discard
    checkpoint("palette-indexed colours: " & $indexed & ", absolute: " &
               $absolute)
    ck absolute == 0
    ck indexed > 0
    finish(sess)

  test "truecolor detection: DECRQSS answered => 24-bit under TERM=xterm":
    # TERM=xterm and no COLORTERM: the environment says sixteen colours.
    var plain = builderFor(@[tracePath], Wide.cols, Wide.rows, term = "xterm",
                           colorterm = "").spawn()
    settleOnDebugger(plain, Wide.cols, Wide.rows)
    let row = rowOf(plain, Wide.cols, Wide.rows, "def add")
    let cell = plain.cellAt(row, colOf(plain, row, Wide.cols, "def add"))
    checkpoint("unanswered: keyword fg kind " & $cell.fg.kind)
    ck cell.fg.kind == ckIndexed
    ck cell.fg.idx.int == nearestAnsi16Family(
      parseHexColour(hexT(dtEditorThemeRuleKeyword, dmDark)))
    finish(plain)

    var answered = builderFor(@[tracePath], Wide.cols, Wide.rows,
                              term = "xterm", colorterm = "").spawn()
    ck waitForTranscript(answered, "\x1bP$qm")
    answered.send("\x1bP1$r0;48:2::1:2:3m\x1b\\" & "\x1b[?62;22c")
    settleOnDebugger(answered, Wide.cols, Wide.rows)
    discard answered.drainOutput(400)
    waitForCompleteFrame(answered, Wide.cols, Wide.rows)
    let f = readWide(answered)
    checkpoint("answered: " & $f)
    ck f.keywordFg == hexT(dtEditorThemeRuleKeyword, dmDark)
    ck f.unfilled == 0
    finish(answered)

  test "a real tmux: withheld RGB is reported, RGB paints 24-bit, window-style decides the mode":
    let tmuxBin = findExe("tmux")
    if tmuxBin.len == 0:
      checkpoint("tmux is not on PATH — the dev shell provides it")
    ck tmuxBin.len > 0
    let scratch = getTempDir() / "plat46-tmux-" & $getCurrentProcessId()
    createDir(scratch)
    defer: removeDir(scratch)
    let inner = "env -u COLORTERM -u COLORFGBG TERM=tmux-256color " &
      "CT_TUI_PROBE_TIMEOUT_MS=500 REPLAY_SERVER_BIN=" &
      quoteShell(replayServerPath()) & " " & quoteShell(tuiBinary()) & " " &
      quoteShell(tracePath) & "; sleep 60"
    for (name, conf) in [
        ("default", ""),
        ("rgb", "set -as terminal-features ',xterm*:RGB'\n"),
        ("light", "set -as terminal-features ',xterm*:RGB'\n" &
                  "set -g window-style bg=#ffffff\n")]:
      let sock = "plat46-" & name & "-" & $getCurrentProcessId()
      let confPath = scratch / (name & ".conf")
      writeFile(confPath, conf)
      var client = newTuiTest(tmuxBin, @["-L", sock, "-f", confPath,
                                         "new-session", "-x", $Wide.cols,
                                         "-y", $(Wide.rows - 1), inner])
        .width(Wide.cols).height(Wide.rows)
        .envRemove("TMUX", "COLORTERM", "TERM_PROGRAM", "NO_COLOR")
        .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
        .spawn()
      let paneRows = Wide.rows - 1
      var status = ""
      let deadline = getMonoTime() + initDuration(seconds = 180)
      var capture = ""
      while getMonoTime() < deadline:
        discard client.drainOutput(100)
        let (captured, _) = execCmdEx(quoteShell(tmuxBin) & " -L " & sock &
                                 " capture-pane -p -e")
        capture = captured
        let lines = capture.splitLines()
        if lines.len >= paneRows:
          status = lines[paneRows - 1]
          if status.contains("NORMAL") and not status.contains("opening"):
            break
      checkpoint(name & " status: " & status.substr(0, 400))
      case name
      of "default":
        # tmux's default `terminal-features` gives an xterm client no RGB.
        ck status.contains("tmux withholds 24-bit colour")
        ck not capture.contains("38;2;")
      of "rgb":
        ck not status.contains("tmux withholds")
        let kw = parseHexColour(hexT(dtEditorThemeRuleKeyword, dmDark))
        ck capture.contains("38;2;" & $kw.r & ";" & $kw.g & ";" & $kw.b)
      else:
        # tmux answers OSC 11 with the pane's own background — reported, and
        # (PLAT-47, `AutoDetectSelectsLight`) still painted Dark.
        let ed = parseHexColour(hexT(dtEditorThemeGround, dmDark))
        ck capture.contains("48;2;" & $ed.r & ";" & $ed.g & ";" & $ed.b)
        # The LIGHT panel is the marker: the light editor's ground is the
        # desktop's measured #282828, the same as the dark one.
        let light = parseHexColour(hexT(dtColorsUiSurfaceBasePanel, dmLight))
        ck not capture.contains("48;2;" & $light.r & ";" & $light.g & ";" &
                                $light.b)
      discard execCmdEx(quoteShell(tmuxBin) & " -L " & sock & " kill-server")
      client.close()

  test ":theme switches the design-system mode on a live session":
    # §4.3's `:theme <dark|light>`, typed at the running binary: the whole
    # screen is repainted from the other mode's tokens, read back off the
    # cells — and back again. A name §4.3 does not publish changes nothing.
    # The session starts on a DETECTED mode (`COLORFGBG` says light, no
    # `--theme`; since PLAT-47 the detection keeps it Dark), so the command
    # must pin its mode over the detection rather than merely agree with a
    # flag that was already pinned.
    var sess = builderFor(@[tracePath], Wide.cols, Wide.rows,
                          colorFgBg = "0;15").spawn()
    settleOnDebugger(sess, Wide.cols, Wide.rows)
    ck readWide(sess).editorBg == hexT(dtEditorThemeGround, dmDark)
    proc typeCommand(sess: var TuiTestSession; line: string) =
      sess.send(":")
      discard sess.drainOutput(100)
      for ch in line:
        sess.send($ch)
        discard sess.drainOutput(10)
      sess.send("\r")
    for (name, mode) in [("light", dmLight), ("dark", dmDark),
                         ("light", dmLight)]:
      typeCommand(sess, "theme " & name)
      let status = waitForStatus(sess, Wide.cols, Wide.rows, "theme " & name)
      checkpoint(":theme " & name & " -> " & status)
      ck status.contains("theme " & name)
      discard sess.drainOutput(300)
      waitForCompleteFrame(sess, Wide.cols, Wide.rows)
      let f = readWide(sess)
      checkpoint(":theme " & name & " read back: " & $f)
      ck f.editorBg == hexT(dtEditorThemeGround, mode)
      ck f.panelBg == hexT(dtColorsUiSurfaceBasePanel, mode)
      ck f.keywordFg == hexT(dtEditorThemeRuleKeyword, mode)
      ck f.statusBg == hexT(dtColorsUiSurfaceBaseRaised, mode)
      ck f.unfilled == 0
    typeCommand(sess, "theme neon")
    let refused = waitForStatus(sess, Wide.cols, Wide.rows, "neon")
    checkpoint(":theme neon -> " & refused)
    ck refused.contains("neon")
    discard sess.drainOutput(200)
    ck readWide(sess).editorBg == hexT(dtEditorThemeGround, dmLight)
    finish(sess)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
