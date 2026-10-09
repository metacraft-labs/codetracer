## test_plat47_desktop_parity.nim — PLAT-47, Tier 2. **The terminal front-end
## at desktop parity, read back off a REAL terminal and compared with the REAL
## desktop.**
##
## Every claim is read off the cells libvterm parsed from the SHIPPED
## `codetracer-tui`'s byte stream, on the `calc` recording, in a real pty; the
## desktop's side is `src/tests/visual/answers/plat47-desktop-parity.electron.json`,
## captured from the real Electron app on the SAME recording by
## `just plat47-capture-electron`
## (`src/tests/gui/tests/visual/plat47-desktop-parity-capture.spec.ts`). The
## capture's absence FAILS BY NAME with its recipe.
##
##   * editor colours (deliverable 2): the editor ground, keyword, string,
##     comment, identifier, delimiter, the resting and the active line number
##     and the execution line's band equal the desktop's measured colours;
##   * Files (deliverable 3): the FILES pane lists the desktop's entries;
##   * call trace (deliverable 7): the calltrace pane lists the desktop's
##     `.call-text` entries, in order, at the same stop;
##   * tab bars (deliverable 8): no strip row carries `─` or `[`/`]`; the
##     active tab differs from the inactive ones in foreground and weight and
##     sits on the desktop's own strip colour; under `--no-color` it is
##     reverse + bold and unique;
##   * focus (deliverable 9): for every pane in turn (`Tab`), at the three
##     standard sizes, the divider cells in the focus colour are exactly the
##     outline of ONE pane — since PLAT-50 (no divider rows) its two sides,
##     unbroken over the same rows, no other — the colour is the desktop's
##     measured outline, and its
##     contrast against an unfocused divider does not exceed the desktop's own
##     outline-to-edge contrast;
##   * `--goto` (the user's 2026-09-27 decision): a stop outside the viewport
##     puts the execution line in the source view's middle, as the desktop's
##     `revealLineInCenterIfOutsideViewport` does — not on its last row;
##   * auto-detection (the user's 2026-09-27 decision): a light terminal
##     background does NOT select Light; `--theme=light` still does.
##
## ## No mocks
##
## A real recording, the real `replay-server`, the shipped binary in a real
## pty, and a capture from the real desktop. The one stand-in is PLAT-46's:
## for the OSC 11 case this file types the TERMINAL'S answer to the binary's
## background query into the pty, because libvterm is a parser and answers
## nothing — the binary's own reading of the answer is what is under test.

import std/[algorithm, json, math, monotimes, os, sets, strutils, tables,
            times, unicode, unittest]

import nim_libvterm
import term_assert

import ../../app/theme/colour_math
import ../../../styles/generated/design_tokens
import ../../testing/dual_snap
import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 75

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  CaptureRecipe = "just plat47-capture-electron"
  Sizes = [(80, 24), (120, 40), (200, 60)]
    ## CodeTracer-TUI.md §3.2's three standard sizes.
  DividerGlyphs = ["▏", "│", "─", "┼", "├", "┤", "┬", "┴", "┌", "┐", "└", "┘"]
  VerticalDividerGlyphs = ["▏", "│", "┼", "├", "┤", "┬", "┴", "┌", "┐", "└",
                           "┘"]
    ## PLAT-50: a divider is the edge one-eighth block `▏`
    ## (`shell.DividerGlyph`); the box-drawing glyphs stay for older frames.
    ## The glyphs that END a strip on its row. `─` is not one of them: a
    ## strip bounded by it would stop at the very rule deliverable 8 forbids,
    ## and never see it (the PLAT-47 mutation harness's arm B2 caught exactly
    ## that).

proc answers(): JsonNode =
  let path = lifecycle_support.repoRoot() / "src" / "tests" / "visual" /
             "answers" / "plat47-desktop-parity.electron.json"
  if not fileExists(path):
    checkpoint("missing " & path & " — run `" & CaptureRecipe & "`")
    return newJNull()
  parseFile(path)

proc hexOfColor(c: Color): string =
  if c.kind == ckRgb: hexOf((c.r.int, c.g.int, c.b.int)) else: ""

var spawnCount = 0

proc spawnTui(args: seq[string]; cols, rows: int; colorFgBg = "";
              noColor = false): TuiTestSession =
  let resolved = resolveFixture("calc")
  # A FRESH layout directory per launch: the terminal remembers its layout
  # (PLAT-45), and a remembered arrangement is not the default this file
  # compares with the desktop's.
  inc spawnCount
  let layoutDir = getTempDir() / ("plat47-parity-" & $getCurrentProcessId() &
                                  "-" & $spawnCount)
  removeDir(layoutDir)
  createDir(layoutDir)
  var b = newTuiTest(tuiBinary(), args & @[resolved.tracePath])
    .envSet("CODETRACER_TUI_LAYOUT_DIR", layoutDir)
    .width(cols).height(rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("CT_TUI_PROBE_TIMEOUT_MS", "200")
  b = if noColor: b.envRemove("COLORTERM")
      else: b.envSet("COLORTERM", "truecolor")
  b = if colorFgBg.len > 0: b.envSet("COLORFGBG", colorFgBg)
      else: b.envRemove("COLORFGBG")
  b.spawn()

proc quit(sess: var TuiTestSession) =
  sess.send("q")
  discard sess.waitExit(initDuration(seconds = 15))
  sess.close()

proc pointerRowOf(sess: var TuiTestSession; cols, rows: int): int =
  ## The row the source pane's execution pointer is on: ` ▸ ` right after a
  ## line number and its gap (PLAT-51: it was `-->`). The call trace draws
  ## `▸` too, for a collapsed call, but never after a digit.
  for r in 0 ..< rows:
    let t = sess.regionText(r, 0, cols, 1)
    var at = t.find("  ▸ ")
    while at > 0:
      if t[at - 1] in {'0' .. '9'}:
        return r
      at = t.find("  ▸ ", at + 1)
  -1

proc rowOf(sess: var TuiTestSession; cols, rows: int; needle: string;
           start = 0): int =
  for r in start ..< rows:
    if sess.regionText(r, 0, cols, 1).contains(needle):
      return r
  -1

proc colOf(sess: var TuiTestSession; row, cols: int; needle: string): int =
  let text = sess.regionText(row, 0, cols, 1)
  let at = text.find(needle)
  if at < 0: return -1
  text[0 ..< at].runeLen

proc glyph(sess: var TuiTestSession; row, col: int): string =
  $sess.cellAt(row, col).rune

proc isDivider(sess: var TuiTestSession; row, col: int; ground: string): bool =
  ## A divider cell: a box-drawing glyph on the panes' own ground (PLAT-49:
  ## dividers sit on the panel surface, not on a canvas of their own) in a
  ## BORDER colour — the unfocused or the focused divider tier — which is
  ## what tells it from a box-drawing character a pane's content draws.
  ## PLAT-50: the default divider colour is the strip's ground
  ## (`--dividers=strip`, ui/surface/primary/default), the desktop's
  ## splitters'.
  let cell = sess.cellAt(row, col)
  glyph(sess, row, col) in DividerGlyphs and
    hexOfColor(cell.bg) == ground and
    hexOfColor(cell.fg) in [DesignTokenHex[dtColorsUiBorderSecondary][dmDark],
                            DesignTokenHex[dtColorsUiBorderPrimary][dmDark],
                            DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark]]

# ---------------------------------------------------------------------------
# Deliverables 2, 3 and 7: the editor, the Files pane and the call trace
# ---------------------------------------------------------------------------

suite "PLAT-47: the terminal shows what the desktop shows":

  test "the editor's colours equal the desktop's":
    let desk = answers()
    ck desk.kind == JObject
    require desk.kind == JObject
    let editor = desk["editor"]
    const Cols = 200
    const Rows = 60
    var sess = spawnTui(@["--theme=dark"], Cols, Rows)
    settleOnDebugger(sess, Cols, Rows)
    # Line 29 is `def add(left, right):` — a keyword, an identifier and
    # delimiters; line 30 its docstring; line 1 the `#!` comment and, at
    # the recording's first stop, the execution line.
    let defRow = rowOf(sess, Cols, Rows, "def add")
    let lineOne = rowOf(sess, Cols, Rows, "#!/usr/bin/env")
    ck defRow >= 0 and lineOne >= 0
    if defRow < 0 or lineOne < 0:
      for r in 0 ..< Rows:
        checkpoint(sess.regionText(r, 0, Cols, 1))
      quit(sess)
    require defRow >= 0 and lineOne >= 0
    let defCol = colOf(sess, defRow, Cols, "def add")
    var got = initTable[string, string]()
    got["keyword"] = hexOfColor(sess.cellAt(defRow, defCol).fg)
    got["identifier"] = hexOfColor(sess.cellAt(defRow, defCol + 4).fg)
    got["delimiter"] = hexOfColor(
      sess.cellAt(defRow, colOf(sess, defRow, Cols, "left,") + 4).fg)
    let docRow = rowOf(sess, Cols, Rows, "\"\"\"Integer addition")
    got["string"] = hexOfColor(sess.cellAt(docRow,
      colOf(sess, docRow, Cols, "\"\"\"Integer")).fg)
    let commentRow = rowOf(sess, Cols, Rows, "# The dispatch table")
    got["comment"] = hexOfColor(sess.cellAt(commentRow,
      colOf(sess, commentRow, Cols, "# The dispatch") + 2).fg)
    # The ground: a blank cell of an empty source line (line 3).
    let blankRow = rowOf(sess, Cols, Rows, "   3 ")
    got["background"] = hexOfColor(sess.cellAt(blankRow,
      colOf(sess, blankRow, Cols, "   3 ") + 10).bg)
    # Resting and active line numbers: line 29's number, and line 1's — the
    # stop's line, the desktop's `.active-line-number`.
    got["lineNumber"] = hexOfColor(sess.cellAt(defRow,
      colOf(sess, defRow, Cols, "29")).fg)
    got["activeLineNumber"] = hexOfColor(sess.cellAt(lineOne,
      colOf(sess, lineOne, Cols, "1  ▸ ")).fg)
    got["executionLine"] = hexOfColor(sess.cellAt(lineOne,
      colOf(sess, lineOne, Cols, "#!/usr")).bg)
    # THE BAND IS MONACO'S WHOLE-LINE BAND: every cell from the first code
    # column to the source pane's right edge (the divider on its right) is in
    # the band's colour — past the end of `#!/usr/bin/env python3`, as the
    # desktop's band is read 30px inside its editor's right edge — and the
    # gutter is not (the desktop draws no band under the line numbers).
    let codeCol = colOf(sess, lineOne, Cols, "#!/usr")
    var edge = codeCol
    while edge + 1 < Cols and
          glyph(sess, lineOne, edge + 1) notin VerticalDividerGlyphs:
      inc edge
    var banded = 0
    for c in codeCol .. edge:
      if hexOfColor(sess.cellAt(lineOne, c).bg) == got["executionLine"]:
        inc banded
    checkpoint("execution band: columns " & $codeCol & ".." & $edge &
               ", banded " & $banded)
    ck edge >= codeCol + "#!/usr/bin/env python3".len + 10
    ck banded == edge - codeCol + 1
    ck hexOfColor(sess.cellAt(lineOne, colOf(sess, lineOne, Cols, "1  ▸ ")).bg) !=
       got["executionLine"]
    quit(sess)
    checkpoint("terminal: " & $got)
    checkpoint("desktop:  " & $editor)
    for role in ["background", "keyword", "string", "comment", "identifier",
                 "delimiter", "lineNumber", "activeLineNumber",
                 "executionLine"]:
      let d = editor{role}.getStr("")
      if d != got.getOrDefault(role, ""):
        checkpoint("PARITY BROKEN for " & role & ": desktop " & d &
                   ", terminal " & got.getOrDefault(role, ""))
      ck d.len == 7 and d == got.getOrDefault(role, "")
    # THE SELECTION is not drawn at this stop; its role is the generated
    # token, which must be the desktop's measured band.
    ck DesignTokenHex[dtEditorThemeSelection][dmDark] ==
       editor{"selection"}.getStr("")

  test "FILES lists the desktop's entries, and the call trace its calls":
    let desk = answers()
    ck desk.kind == JObject
    require desk.kind == JObject
    const Cols = 200
    const Rows = 60
    var sess = spawnTui(@["--theme=dark"], Cols, Rows)
    settleOnDebugger(sess, Cols, Rows)
    # FILES: the rows under the pane's tab strip (PLAT-49: no title row),
    # glyphs and indent dropped.
    let title = rowOf(sess, Cols, Rows, " Files ")
    ck title >= 0
    let filesCol = colOf(sess, title, Cols, " Files ")
    var files: seq[string] = @[]
    for r in title + 1 ..< Rows - 1:
      var text = ""
      for c in filesCol ..< Cols:
        let g = glyph(sess, r, c)
        if g in DividerGlyphs: break
        text.add(if g.len == 0 or g == "\0": " " else: g)
      let entry = text.replace("▼", "").strip()
      if entry.len == 0: break
      files.add entry
    var want: seq[string] = @[]
    for e in desk["files"]: want.add e.getStr
    checkpoint("terminal files: " & $files & " desktop: " & $want)
    ck files == want
    # THE CALL TRACE: the visible rows, marker and indent dropped, are the
    # desktop's first entries in order.
    let ct = rowOf(sess, Cols, Rows, " Call Trace ")
    ck ct >= 0
    let ctCol = colOf(sess, ct, Cols, " Call Trace ")
    var calls: seq[string] = @[]
    for r in ct + 1 ..< Rows - 1:
      var text = ""
      for c in ctCol ..< Cols:
        let g = glyph(sess, r, c)
        if g in DividerGlyphs: break
        text.add(if g.len == 0 or g == "\0": " " else: g)
      # PLAT-49 part B: a row is "<toggle> callee #index(args) => return";
      # the desktop's entry is its callee and index.
      var entry = text.strip(chars = {' ', '>'})
      for g in ["▾ ", "▸ ", "· "]:
        if entry.startsWith(g): entry = entry[g.len .. ^1]
      let paren = entry.find('(')
      if paren > 0: entry = entry[0 ..< paren]
      if entry.len == 0 or not entry.contains(" #"): break
      calls.add entry
    var desktopCalls: seq[string] = @[]
    for e in desk["calltrace"]: desktopCalls.add e.getStr
    checkpoint("terminal calls: " & $calls)
    ck calls.len >= 5
    ck desktopCalls.len >= calls.len
    if desktopCalls.len >= calls.len:
      ck calls == desktopCalls[0 ..< calls.len]
    # PLAT-49: the pane's first row is its tab strip, as the desktop's
    # GoldenLayout header is — no upper-cased title row counting the calls.
    ck not sess.regionText(ct, ctCol, 40, 1).contains("call(s)")
    quit(sess)

# ---------------------------------------------------------------------------
# Deliverable 8: tab bars
# ---------------------------------------------------------------------------

proc stripSegment(sess: var TuiTestSession; row, col, cols: int): string =
  ## The strip a tab label at `(row, col)` is on: the run of cells between the
  ## dividers (or the screen's edges) around it. A strip shares its ROW with
  ## other regions' first rows (a single pane's title, another stack's strip),
  ## so the claim is made about this run, not the whole row.
  var left = col
  while left > 0 and glyph(sess, row, left - 1) notin VerticalDividerGlyphs:
    dec left
  var right = col
  while right < cols - 1 and
        glyph(sess, row, right + 1) notin VerticalDividerGlyphs:
    inc right
  sess.regionText(row, left, right - left + 1, 1)

suite "PLAT-47: tab bars are shaped by colour and weight":

  test "no rule, no brackets; the active tab differs by colour and weight":
    let desk = answers()
    ck desk.kind == JObject
    const Cols = 200
    const Rows = 60
    var sess = spawnTui(@["--theme=dark"], Cols, Rows)
    settleOnDebugger(sess, Cols, Rows)
    var strips = 0
    for label in ["Files", "Variables", "Call Trace", "Event Log"]:
      let r = rowOf(sess, Cols, Rows, " " & label & " ")
      ck r >= 0
      if r < 0: continue
      let t = stripSegment(sess, r, colOf(sess, r, Cols, label), Cols)
      checkpoint("strip of " & label & ": '" & t & "'")
      # No horizontal rule runs through a strip, and no tab is bracketed.
      ck not t.contains("─")
      ck not t.contains("[") and not t.contains("]")
      inc strips
    ck strips == 4
    # The Variables stack: `Variables` active, `Scratchpad` behind it.
    let r = rowOf(sess, Cols, Rows, " Variables ")
    let active = sess.cellAt(r, colOf(sess, r, Cols, "Variables"))
    let inactive = sess.cellAt(r, colOf(sess, r, Cols, "Scratchpad"))
    ck hexOfColor(active.fg) != hexOfColor(inactive.fg)
    ck caBold in active.attrs
    ck caBold notin inactive.attrs
    # PLAT-49 finding 4, the user's direction over PLAT-47's measured single
    # ground: the strip has a ground of its own, distinct from the pane body
    # (the desktop's panel colour, which the terminal's body also paints),
    # and the selected tab a ground distinct from both.
    if desk.kind == JObject:
      let panel = desk["focus"]["panel"].getStr
      ck hexOfColor(active.bg) != panel and
         hexOfColor(active.bg) != hexOfColor(inactive.bg)
      ck hexOfColor(inactive.bg) != panel
    quit(sess)

  test "in monochrome the active tab is reverse video and bold, and unique":
    const Cols = 200
    const Rows = 60
    var sess = spawnTui(@["--no-color"], Cols, Rows, noColor = true)
    settleOnDebugger(sess, Cols, Rows)
    let r = rowOf(sess, Cols, Rows, " Variables ")
    ck r >= 0
    let active = sess.cellAt(r, colOf(sess, r, Cols, "Variables"))
    let inactive = sess.cellAt(r, colOf(sess, r, Cols, "Scratchpad"))
    ck caReverse in active.attrs and caBold in active.attrs
    ck caReverse notin inactive.attrs
    # Unique on its strip: exactly one reversed run.
    var runs = 0
    var inRun = false
    let span = colOf(sess, r, Cols, "Scratchpad") + 12
    for c in colOf(sess, r, Cols, "Variables") - 2 ..< span:
      let rev = caReverse in sess.cellAt(r, c).attrs
      if rev and not inRun: inc runs
      inRun = rev
    ck runs == 1
    quit(sess)

# ---------------------------------------------------------------------------
# Deliverable 9: the focused pane's outline
# ---------------------------------------------------------------------------

proc contrastOf(a, b: string): float =
  proc lum(h: string): float =
    var ch: array[3, float]
    for i in 0 .. 2:
      let c = parseHexInt(h[1 + 2 * i .. 2 + 2 * i]).float / 255.0
      ch[i] = if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4)
    0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]
  let (x, y) = (lum(a), lum(b))
  (max(x, y) + 0.05) / (min(x, y) + 0.05)

type Ring = tuple[top, left, bottom, right: int]

proc focusRingOf(sess: var TuiTestSession; cols, rows: int; canvas,
                 focus: string; ok: var bool): Ring =
  ## The focused pane's outline: its SIDES. PLAT-50 removed the divider rows
  ## between stacked panes (the lower pane's tab strip is the separator, the
  ## user's direction of 2026-10-02), so the outline PLAT-47 drew on four
  ## sides is the two dividers beside the pane's box. `ok` when the
  ## focus-coloured divider cells are one or two COLUMNS, each one unbroken
  ## run over the same rows (the pane's rows below its strip), and every
  ## divider cell of those columns inside that run is in the focus colour —
  ## the outline is symmetric whichever neighbour owns a divider. The answer
  ## is (first row, left column, last row, right column); a side at the
  ## body's edge has no divider and reads -1 / `cols`.
  ## A focus-coloured divider cell may sit on a neighbour's STRIP ground
  ## (where the side meets a stacked neighbour's tab strip), so the focus
  ## cells are read by glyph and colour, not by `isDivider`'s ground.
  var focusCells = initHashSet[(int, int)]()
  for r in 1 ..< rows - 1:
    for c in 0 ..< cols:
      # PLAT-51: a list pane's scrollbar-scrubber TRACK is a `│` in
      # ui/divider/secondary, which in the dark mode is the same hex as the
      # focus colour (ui/border/primary): it is a scrollbar, not a divider
      # (PLAT-50's dividers are `▏`).
      if glyph(sess, r, c) in VerticalDividerGlyphs and
         glyph(sess, r, c) != "│" and
         hexOfColor(sess.cellAt(r, c).fg) == focus:
        focusCells.incl (r, c)
  ok = focusCells.len > 0
  if not ok:
    return (top: -1, left: -1, bottom: -1, right: -1)
  var columns: seq[int] = @[]
  result = (top: high(int), left: -1, bottom: -1, right: cols)
  for (r, c) in focusCells:
    if c notin columns: columns.add c
    result.top = min(result.top, r)
    result.bottom = max(result.bottom, r)
  columns.sort()
  if columns.len > 2:
    ok = false
  for c in columns:
    for r in result.top .. result.bottom:
      if (r, c) notin focusCells: ok = false
  if columns.len == 2:
    result.left = columns[0]
    result.right = columns[1]
  elif columns.len == 1:
    # One side: the other is the body's edge. Which one it is follows from
    # where the divider is.
    if columns[0] < cols div 2: result.left = columns[0]
    else: result.right = columns[0]

suite "PLAT-47: the focused pane is outlined as the desktop outlines it":

  test "every pane in turn, at the three sizes: a closed ring in the desktop's colour":
    let desk = answers()
    ck desk.kind == JObject
    require desk.kind == JObject
    let deskHex = desk["focus"]["outline"].getStr
    # PLAT-49: dividers sit on the panes' own ground, the panel.
    let canvas = DesignTokenHex[dtColorsUiSurfaceBasePanel][dmDark]
    # The colour relationship. The desktop's outline is ui/border/primary
    # (measured); PLAT-51 (the user: both focus contrasts SUBTLER) moved the
    # native front-ends' one step down the border ramp, ui/border/secondary —
    # a declared deviation (Native-Front-End-Parity.md §2): it stands off
    # the panel by less than the desktop's does, and is still a ring.
    let focusHex = DesignTokenHex[dtColorsUiBorderSecondary][dmDark]
    ck DesignTokenHex[dtColorsUiBorderPrimary][dmDark] == deskHex
    ck contrastOf(focusHex, canvas) < contrastOf(deskHex, canvas)
    for (cols, rows) in Sizes:
      var sess = spawnTui(@["--theme=dark"], cols, rows)
      settleOnDebugger(sess, cols, rows)
      var seen: seq[Ring] = @[]
      for i in 0 ..< 12:
        var ok = false
        let ring = focusRingOf(sess, cols, rows, canvas, focusHex, ok)
        checkpoint($cols & "x" & $rows & " focus " & $i & ": " & $ring &
                   " closed=" & $ok)
        ck ok
        if ring in seen: break
        seen.add ring
        sess.send("\t")
        # WAIT FOR THE REPAINT THE KEY CAUSES, not for 300 ms: on a loaded
        # host the frame read after a fixed pause can still be the one from
        # BEFORE the Tab, and then this loop meets its own previous ring and
        # stops at one pane — a timing artefact, not a focus defect. Polled
        # until the ring moves, bounded; a Tab that moves nothing still ends
        # the loop below with `ring in seen`, and the count fails.
        let tabDeadline = getMonoTime() + initDuration(seconds = 10)
        while getMonoTime() < tabDeadline:
          discard sess.drainOutput(100)
          waitForCompleteFrame(sess, cols, rows, timeoutMs = 10000)
          var moved = false
          if focusRingOf(sess, cols, rows, canvas, focusHex, moved) != ring:
            break
      # Tab visited more than one pane, and each was ringed on its own.
      ck seen.len >= 2
      quit(sess)

# ---------------------------------------------------------------------------
# The user's two decisions of 2026-09-27
# ---------------------------------------------------------------------------

suite "PLAT-47: --goto centres the stop, and auto-detection keeps Dark":

  test "a stop outside the viewport lands in the source view's middle":
    const Cols = 160
    const Rows = 24
    # Tick 25 stops in `evaluate`'s loop (line 82), far below the first
    # screen's 21 source rows and far from the file's end.
    var sess = spawnTui(@["--theme=dark", "--goto=25"], Cols, Rows)
    settleOnDebugger(sess, Cols, Rows)
    let pointer = pointerRowOf(sess, Cols, Rows)   # PLAT-51: was `-->`
    ck pointer > 0
    # The source view's rows: from its tab strip (the file's tab, PLAT-49) to
    # the last row with a gutter.
    let title = rowOf(sess, Cols, Rows, " main.py ")
    var last = title
    for r in title + 1 ..< Rows - 1:
      let t = sess.regionText(r, 0, Cols, 1)
      if t.len > 0 and t.contains(DividerGlyphs[0]) and
         (t.split(DividerGlyphs[0])[1].strip().len > 0 or last == r - 1):
        last = r
    let first = title + 1
    let height = last - first + 1
    let middle = first + (height - 1) div 2
    checkpoint("pointer row " & $pointer & ", source rows " & $first & ".." &
               $last & ", middle " & $middle)
    # Monaco centres to within a line; the terminal to within one row.
    ck abs(pointer - middle) <= 1
    ck pointer < last
    quit(sess)

  test "a light background is reported but does not select Light":
    const Cols = 120
    const Rows = 30
    var sess = spawnTui(@[], Cols, Rows, colorFgBg = "0;15")
    settleOnDebugger(sess, Cols, Rows)
    let ground = rowOf(sess, Cols, Rows, "   3 ")
    ck ground >= 0
    let bg = hexOfColor(sess.cellAt(ground,
      colOf(sess, ground, Cols, "   3 ") + 10).bg)
    ck bg == DesignTokenHex[dtEditorThemeGround][dmDark]
    quit(sess)
    # `--theme=light` still selects it.
    var light = spawnTui(@["--theme=light"], Cols, Rows)
    settleOnDebugger(light, Cols, Rows)
    let g2 = rowOf(light, Cols, Rows, "   3 ")
    ck g2 >= 0
    ck hexOfColor(light.cellAt(g2, colOf(light, g2, Cols, "   3 ") + 10).bg) ==
       DesignTokenHex[dtEditorThemeGround][dmLight]
    quit(light)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
