## test_plat51b_pty.nim — PLAT-51 part B (deliverables 8-11), Tier 2: the
## shipped `codetracer-tui` in a real PTY (TermAssert + libvterm), a real
## `replay-server` behind it, driven by the bytes a terminal sends.
##
##   * 9, THE FOCUS HIGHLIGHT (Native-Front-End-Parity.md §2): the focused
##     pane's tab strip on the focus colour (ui/border/secondary), on ONE
##     strip, moving with Tab; `:set focus-highlight off` removes it and the
##     choice is REMEMBERED across a restart (`tui-preferences` beside the
##     remembered layout); `--focus-highlight=on|off` on the command line;
##   * 11, LIVE REFLOW (Layout-ViewModel §4.3a): a divider held mid-drag has
##     already moved — the panes are re-laid-out, read back from the cells
##     before the release; the remembered layout is not written until the
##     release; one `:undo-layout` restores; with `--live-resize=off` the
##     arrangement stays and a guide is drawn, and `Esc` cancels;
##   * 10, GOLDENLAYOUT'S DROP ZONES (Layout-ViewModel §4.2.2): with no
##     SGR-pixel answer a report is decided at its cell's CENTRE; when the
##     terminal answers DECRQM 1016 (and `CSI 16 t`) the reports are PIXELS
##     and a pixel on the other side of a GoldenLayout boundary from its
##     cell's centre is decided where it is; the outer 50 px band splits the
##     whole layout;
##   * 8, THE WELCOME SCREEN OF A NEW TAB (Multi-Window-Tab-Management.md
##     rule 3): the "+" opens it; "Record new trace" runs a REAL `ct record`
##     of a Python program and the recording opens in that tab; "Open folder"
##     turns the tab into an editing session on the folder.
##
## The terminal's answers in the 1016 case are bytes WRITTEN TO THE CHILD'S
## INPUT — what a terminal that supports SGR-pixel reporting sends back to the
## probe (`\e[?1016;2$y`, `\e[6;40;20t`, the DA1 sentinel). libvterm answers
## none of them, so without them the probe runs to its timeout, which is the
## other case. That is the terminal's side of the conversation, not a stand-in
## for the product: every decision is the shipped binary's.
##
## No mocks: the real binary, real recordings, a real engine, a real `ct
## record`, a real pty.

import std/[monotimes, os, sets, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
import ../../../styles/generated/design_tokens

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 38

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  StatusRow = Rows - 1
  PixelW = 20
  PixelH = 40
    ## The cell the 1016 case's terminal reports (`CSI 6 ; 40 ; 20 t`).

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc freshDir(tag: string): string =
  inc spawned
  result = getTempDir() / ("plat51b-pty-" & tag & "-" & $getCurrentProcessId() &
                           "-" & $spawned)
  removeDir(result)
  createDir(result)

proc builder(args: seq[string]; layoutDir: string;
             subject = ""): TuiTestBuilder =
  let target =
    if subject.len > 0: subject
    else:
      let resolved = resolveFixture("calc")
      doAssert resolved.outcome == foRecorded
      resolved.tracePath
  result = newTuiTest(tuiBinary(), @["--theme=dark"] & args & @[target])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", layoutDir / "xdg")
    .envSet("CODETRACER_HOME", layoutDir / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", layoutDir)
  let ct = lifecycle_support.repoRoot() / "src" / "build-debug" / "bin" / "ct"
  if fileExists(ct):
    result = result.envSet("CT_BIN", ct)

proc open(args: seq[string]; layoutDir: string): TuiTestSession =
  result = builder(args, layoutDir).spawn()
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

proc status(sess: var TuiTestSession): string =
  discard sess.drainOutput(40)
  sess.regionText(StatusRow, 0, Cols, 1).split('\n')[0]

proc findRow(s: Snapshot; needle: string): (int, int) =
  for r in 0 ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0:
      return (r, c)
  (-1, -1)

proc waitFor(sess: var TuiTestSession; needle: string; timeoutMs = 20000):
    (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let at = sess.snap().findRow(needle)
    if at[0] >= 0:
      return at
    sleep(40)
  raise newException(AssertionFailedError, "never showed '" & needle & "'")

proc waitStatus(sess: var TuiTestSession; needle: string;
                timeoutMs = 20000): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.status()
    if result.contains(needle):
      return
    sleep(30)
  raise newException(AssertionFailedError,
    "status never said '" & needle & "': " & result)

proc report(sess: var TuiTestSession; code, x, y: int; release = false) =
  ## An SGR report at 1-based `(x, y)` — cells, or pixels under 1016.
  sess.send("\x1b[<" & $code & ";" & $x & ";" & $y &
            (if release: "m" else: "M"))

proc cellReport(sess: var TuiTestSession; code, row, col: int;
                release = false) =
  sess.report(code, col + 1, row + 1, release)

proc click(sess: var TuiTestSession; row, col: int) =
  sess.cellReport(0, row, col)
  sess.cellReport(0, row, col, release = true)

proc quit(sess: var TuiTestSession) =
  sess.send(":quit\r")
  discard sess.waitExit(initDuration(seconds = 15))
  sess.terminate()
  sess.close()

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

let focusHex = DesignTokenHex[dtColorsUiBorderSecondary][dmDark]

proc focusCells(s: Snapshot): seq[(int, int)] =
  ## Every body cell on the focus colour.
  for r in 1 ..< StatusRow:
    for c in 0 ..< Cols:
      if s[r][c].bgHex == focusHex:
        result.add (r, c)

proc fgHex(c: Cell): string =
  if c.fg.kind == ckRgb: hexOf((c.fg.r.int, c.fg.g.int, c.fg.b.int)) else: ""

let stripHex = DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark]

proc edgeProblems(s: Snapshot; cells: seq[(int, int)];
                  checkedLeft, checkedRight, bodyRows: var int): seq[string] =
  ## The two edges of the focused pane, read off the terminal's cells. A
  ## divider cell's fill is what lies RIGHT of its left-aligned `▏`, so:
  ##   * the cell RIGHT of the focused strip belongs to the next pane: it is
  ##     an ordinary strip-row divider — the strip colour on the unfocused
  ##     strip ground (PLAT-50's rule), never on the focus colour;
  ##   * the cell LEFT of the focused strip is on the focused ground with its
  ##     line in the strip colour — visible, never drawn in its own ground;
  ##   * on the pane's body rows both side lines are the focus colour and
  ##     neither cell's ground is.
  if cells.len == 0:
    return @["no focused strip"]
  let row = cells[0][0]
  var cmin = Cols
  var cmax = -1
  for (_, c) in cells:
    cmin = min(cmin, c)
    cmax = max(cmax, c)
  let where = "strip row " & $row & " cols " & $cmin & ".." & $cmax & ": "
  let right = cmax + 1
  if right < Cols and $s[row][right].rune == "▏":
    inc checkedRight
    let c = s[row][right]
    if c.bgHex == focusHex:
      result.add where & "the cell right of it is on the focus ground"
    if c.bgHex != stripHex or c.fgHex != stripHex:
      result.add where & "the cell right of it is not an ordinary strip " &
        "divider: " & c.fgHex & " on " & c.bgHex
  if $s[row][cmin].rune == "▏":
    inc checkedLeft
    let c = s[row][cmin]
    if c.fgHex == c.bgHex:
      result.add where & "the left edge's line is drawn in its own ground"
    if c.fgHex != stripHex:
      result.add where & "the left edge's line is not the strip colour: " & c.fgHex
  for r in row + 1 ..< StatusRow:
    var any = false
    for col in [cmin, right]:
      if col < Cols and $s[r][col].rune == "▏" and s[r][col].fgHex == focusHex:
        any = true
        inc bodyRows
        if s[r][col].bgHex == focusHex:
          result.add "body row " & $r & " col " & $col & " is on the focus ground"
    if not any: break

proc rowsOf(cells: seq[(int, int)]): HashSet[int] =
  result.init()
  for (r, _) in cells:
    result.incl r

proc dividerCols(s: Snapshot; row: int): seq[int] =
  for c in 0 ..< Cols:
    if $s[row][c].rune == "▏":
      result.add c

suite "PLAT-51 part B on a real terminal: the focus highlight":

  test "one strip on the focus colour, moving with Tab; :set off is remembered; the flag":
    let dir = freshDir("focus")
    var sess = open(@[], dir)
    let first = sess.snap().focusCells()
    checkpoint("focus cells at start: " & $first.len & " rows " &
               $first.rowsOf())
    # ONE strip row, a strip's worth of cells.
    ck first.len >= 6 and first.rowsOf().len == 1
    # Tab moves the focus, and the strip with it.
    sess.send("\t")
    var moved: seq[(int, int)] = @[]
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while getMonoTime() < deadline:
      moved = sess.snap().focusCells()
      if moved != first and moved.len > 0: break
      sleep(50)
    ck moved.len >= 3 and moved != first and moved.rowsOf().len == 1
    # Off at runtime: no cell on the focus colour.
    sess.send(":set focus-highlight off\r")
    discard sess.waitStatus("focus-highlight")
    sleep(300)
    ck sess.snap().focusCells().len == 0
    sess.quit()
    # REMEMBERED: the preference beside the remembered layout, and a restart
    # reads it.
    let prefs = dir / "tui-preferences"
    ck fileExists(prefs) and readFile(prefs).contains("focus-highlight=off")
    var again = open(@[], dir)
    ck again.snap().focusCells().len == 0
    again.quit()
    # The command line overrides the remembered choice, for that run.
    var forced = open(@["--focus-highlight=on"], dir)
    ck forced.snap().focusCells().len >= 6
    forced.quit()
    var fresh = open(@["--focus-highlight=off"], freshDir("focus-flag"))
    ck fresh.snap().focusCells().len == 0
    fresh.quit()

  test "the focused pane's edges: its ground stops at its own cells; the lines are the dividers'":
    # The user, 2026-10-09: the focus ground leaked into the first cell of
    # the pane on the right, and the divider line was drawn in its own
    # ground. Every pane focused in turn (Tab), at a size where the shared
    # default puts panes side by side.
    var sess = open(@[], freshDir("edges"))
    var seen: seq[seq[(int, int)]] = @[]
    var problems: seq[string] = @[]
    var checkedLeft, checkedRight, bodyRows = 0
    for step in 0 ..< 8:
      var cells: seq[(int, int)] = @[]
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while getMonoTime() < deadline:
        cells = sess.snap().focusCells()
        if cells.len > 0 and cells notin seen: break
        sleep(50)
      if cells.len > 0 and cells notin seen:
        seen.add cells
        problems.add sess.snap().edgeProblems(cells, checkedLeft,
                                               checkedRight, bodyRows)
      sess.send("\t")
    sess.quit()
    checkpoint("focus positions " & $seen.len & ", left edges " &
               $checkedLeft & ", right edges " & $checkedRight &
               ", body-row line cells " & $bodyRows)
    for p in problems: checkpoint(p)
    ck seen.len >= 4
    ck checkedLeft >= 1
    ck checkedRight >= 1
    ck bodyRows >= 2
    ck problems.len == 0

suite "PLAT-51 part B on a real terminal: live reflow while a divider is dragged":

  test "mid-drag the panes are re-laid-out; the release writes; one undo restores":
    let dir = freshDir("live")
    var sess = open(@[], dir)
    let row = 10
    let s0 = sess.snap()
    let divs = s0.dividerCols(row)
    ck divs.len >= 2
    let d = divs[0]
    let srcAt = s0.text(1).cellFind(" main.py ")
    sess.cellReport(0, row, d)
    for dc in [2, 4, 6, 8]:
      sess.cellReport(32, row, d + dc)
    sleep(400)
    let mid = sess.snap()
    let midDivs = mid.dividerCols(row)
    checkpoint("dividers before " & $divs & ", mid-drag " & $midDivs)
    # THE DIVIDER HAS MOVED BEFORE THE RELEASE, and the pane right of it
    # was laid out again: its tab label moved with it.
    ck d notin midDivs and (d + 8 in midDivs or d + 7 in midDivs or
                            d + 9 in midDivs)
    ck mid.text(1).cellFind(" main.py ") > srcAt
    # The committed layout has not been written yet.
    ck not fileExists(dir / "tui-layout.json")
    sess.cellReport(0, row, d + 8, release = true)
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while getMonoTime() < deadline and not fileExists(dir / "tui-layout.json"):
      sleep(50)
    ck fileExists(dir / "tui-layout.json")
    ck sess.snap().dividerCols(row) == midDivs
    # One undo: the divider is back.
    sess.send(":undo-layout\r")
    discard sess.waitStatus("layout undone")
    sleep(300)
    ck sess.snap().dividerCols(row) == divs
    sess.quit()

  test "with --live-resize=off a guide is drawn and nothing moves; Esc cancels":
    var sess = open(@["--live-resize=off"], freshDir("guide"))
    let row = 10
    let s0 = sess.snap()
    let divs = s0.dividerCols(row)
    let d = divs[0]
    sess.cellReport(0, row, d)
    for dc in [2, 4, 6, 8]:
      sess.cellReport(32, row, d + dc)
    sleep(400)
    let mid = sess.snap()
    ck mid.dividerCols(row) == divs
    # The guide: the edge the release would make, drawn down the body near
    # the pointer's column (the glyph `binding.ResizeGuideGlyph`).
    var guideRows = 0
    for r in 2 ..< StatusRow - 1:
      var drawn = false
      for c in d + 6 .. d + 10:
        if $mid[r][c].rune != $s0[r][c].rune or
           mid[r][c].bgHex != s0[r][c].bgHex:
          drawn = true
      if drawn: inc guideRows
    checkpoint("guide rows: " & $guideRows)
    ck guideRows >= 10
    sess.send("\x1b")
    discard sess.waitStatus("cancelled")
    sleep(300)
    let after = sess.snap()
    var changed = 0
    for r in 1 ..< StatusRow:
      for c in 0 ..< Cols:
        if after[r][c].bgHex != s0[r][c].bgHex: inc changed
    ck changed == 0
    sess.quit()

# ---------------------------------------------------------------------------
# Drop zones: cells and pixels
# ---------------------------------------------------------------------------

type Box = object
  left, right, top, bottom: int      ## cells, inclusive

proc decisionOf(status: string): string =
  for d in ["splitBefore(editor, row", "splitAfter(editor, row",
            "splitBefore(editor, column", "splitAfter(editor, column",
            "intoStack(editor", "splitRoot(right)"]:
    if status.contains("would " & d): return d
  ""

proc segmentIn(b: Box; x, y: float): string =
  ## GoldenLayout's body segments with the smaller middle, RESTATED in cell
  ## units over the editor's content (its box below its strip). Used only to
  ## CHOOSE a sample where a pixel and its cell's centre disagree; the
  ## verdict is the binary's status line.
  let x1 = float(b.left)
  let w = float(b.right - b.left + 1)
  let y1 = float(b.top + 1)
  let h = float(b.bottom - b.top)
  let fx = (x - x1) / w
  let fy = (y - y1) / h
  if fx <= 0 or fx >= 1 or fy <= 0 or fy >= 1: return ""
  if fx < 0.25: return "splitBefore(editor, row"
  if fx > 1/3 and fx < 2/3 and fy > 1/3 and fy < 2/3: return "intoStack(editor"
  if fx > 0.75: return "splitAfter(editor, row"
  # GoldenLayout's tests are strict: on a boundary no segment matches.
  if fx > 0.25 and fx < 0.75 and fy < 0.5: return "splitBefore(editor, column"
  if fx > 0.25 and fx < 0.75 and fy > 0.5: return "splitAfter(editor, column"
  ""

proc editorBox(s: Snapshot): Box =
  ## The Source pane's BOX, read off the screen: its tab on the strip row,
  ## the dividers either side of it on a body row (its own divider column is
  ## a splitter, in no stack's area); the whole body tall.
  let at = s.text(1).cellFind(" main.py ")
  let divs = s.dividerCols(10)
  var left = 0
  var right = Cols - 1
  for dv in divs:
    if dv < at: left = dv + 1
    elif right == Cols - 1: right = dv - 1
  Box(left: left, right: right, top: 1, bottom: StatusRow - 1)

proc discriminating(b: Box): tuple[row, col, px, py: int; atPixel,
                                   atCentre: string] =
  ## A cell of the editor and a pixel in it whose GoldenLayout decisions
  ## differ — searched along every row and every column of the box, across
  ## both axes' boundaries (a box whose sides divide evenly puts some
  ## boundaries on cell edges, where a pixel and a centre cannot disagree).
  for row in b.top + 1 .. b.bottom:
    for col in b.left .. b.right:
      let centre = segmentIn(b, float(col) + 0.5, float(row) + 0.5)
      if centre.len == 0: continue
      for j in 0 ..< PixelH:
        for i in 0 ..< PixelW:
          let px = col * PixelW + i
          let py = row * PixelH + j
          let atPx = segmentIn(b, float(px) / PixelW, float(py) / PixelH)
          if atPx.len > 0 and atPx != centre:
            return (row, col, px, py, atPx, centre)
  (-1, -1, -1, -1, "", "")

suite "PLAT-51 part B on a real terminal: GoldenLayout's decisions, cells and pixels":

  test "without 1016 a report is its cell's centre; with 1016 it is its pixel":
    # The cell-mode terminal first: the decision at the chosen cell is the
    # one its CENTRE gets.
    var cells = open(@[], freshDir("cells"))
    let s0 = cells.snap()
    let box = s0.editorBox()
    let pick = discriminating(box)
    let row = pick.row
    checkpoint("editor box " & $box & "; pick " & $pick)
    ck pick.col >= 0
    let (vr, vc) = s0.findRow(" Variables ")
    ck vr > 0
    cells.cellReport(0, vr, vc + 2)
    cells.cellReport(32, vr, vc + 6)
    discard cells.waitStatus("would ")
    cells.cellReport(32, row, pick.col)
    sleep(400)
    let atCell = cells.status().decisionOf()
    checkpoint("cell report: " & cells.status())
    ck atCell == pick.atCentre
    cells.send("\x1b")
    cells.quit()

    # The SGR-pixel terminal: it answers the probe — DECRQM 1016 "reset",
    # the cell size, and the DA1 sentinel — and from then on reports pixels.
    # Answered once the question is ON THE WIRE: bytes typed before the
    # product put the terminal in raw mode are discarded by that switch, as
    # they would be from any terminal.
    var px = builder(@[], freshDir("pixels"))
      .envSet("CT_TUI_PROBE_TIMEOUT_MS", "4000").spawn()
    let asked = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < asked and
          not px.transcriptBytes().contains("\x1b[?1016$p"):
      discard px.drainOutput(20)
    px.send("\x1b[?1016;2$y\x1b[6;" & $PixelH & ";" & $PixelW & "t" &
            "\x1b[?62;22c")
    settleOnDebugger(px, Cols, Rows)
    let sent = px.transcriptBytes()
    checkpoint("probe asked 1016: " & $sent.contains("\x1b[?1016$p") &
               ", cell size: " & $sent.contains("\x1b[16t") &
               ", switched 1016 on: " & $sent.contains("\x1b[?1016h"))
    # THE PRODUCT SWITCHED SGR-PIXEL REPORTING ON, having been answered.
    ck sent.contains("\x1b[?1016h")
    let p0 = px.snap()
    let pbox = p0.editorBox()
    ck pbox == box
    let (pr, pc) = p0.findRow(" Variables ")
    proc centreOf(r, c: int): (int, int) =
      (c * PixelW + PixelW div 2 + 1, r * PixelH + PixelH div 2 + 1)
    let (sx, sy) = centreOf(pr, pc + 2)
    px.report(0, sx, sy)
    px.report(32, sx + 4 * PixelW, sy)
    discard px.waitStatus("would ")
    let y = row * PixelH + PixelH div 2 + 1
    # The pixel: decided where it is.
    px.report(32, pick.px + 1, pick.py + 1)
    sleep(400)
    checkpoint("pixel report: " & px.status())
    ck px.status().decisionOf() == pick.atPixel
    # The same cell's centre, as a pixel: the cell report's decision.
    px.report(32, pick.col * PixelW + PixelW div 2 + 1, y)
    sleep(400)
    ck px.status().decisionOf() == pick.atCentre
    # GoldenLayout's 50 px ground band along the right edge: the whole
    # layout splits there.
    px.report(32, Cols * PixelW - 10, y)
    sleep(400)
    checkpoint("right band: " & px.status())
    ck px.status().decisionOf() == "splitRoot(right)"
    px.send("\x1b")
    px.quit()

# ---------------------------------------------------------------------------
# The Welcome Screen
# ---------------------------------------------------------------------------

suite "PLAT-51 part B on a real terminal: a new tab's Welcome Screen":

  test "Record new trace runs a real ct record and opens the recording in the tab":
    let ct = lifecycle_support.repoRoot() / "src" / "build-debug" / "bin" / "ct"
    if not fileExists(ct):
      checkpoint("prerequisite missing: " & ct & " (just build-once)")
    ck fileExists(ct)
    let dir = freshDir("record")
    let work = dir / "program"
    createDir(work)
    let program = work / "greeter.py"
    writeFile(program, "def greet(name):\n    return 'hello ' + name\n\n" &
                       "print(greet('plat51'))\n")
    var sess = open(@[], dir)
    let plus = sess.snap().text(0).cellFind(" + ")
    ck plus > 0
    sess.click(0, plus + 1)
    discard sess.waitFor("Welcome to CodeTracer")
    let (rr, rc) = sess.waitFor(" Record new trace ")
    sess.click(rr, rc + 2)
    discard sess.waitFor("Program to record")
    sess.send(program)
    sess.send("\r")
    # The recording runs in the background; when it is done it opens HERE.
    discard sess.waitFor("greet #", timeoutMs = 240000)
    let top = sess.snap().text(0)
    checkpoint("top bar: " & top)
    ck top.contains("greeter")
    ck not sess.snap().text(2).contains("Welcome to CodeTracer")
    # Recorded under the product's state root.
    var recorded = 0
    if dirExists(dir / "recordings"):
      for kind, path in walkDir(dir / "recordings"):
        if kind == pcDir and path.extractFilename.startsWith("greeter-"):
          inc recorded
    ck recorded == 1
    sess.quit()

  test "Open folder turns the tab into an editing session on that folder":
    let dir = freshDir("folder")
    let project = dir / "plat51proj"
    createDir(project)
    writeFile(project / "main.py", "answer = 42\nprint(answer)\n")
    var sess = open(@[], dir)
    let plus = sess.snap().text(0).cellFind(" + ")
    sess.click(0, plus + 1)
    discard sess.waitFor("Welcome to CodeTracer")
    let (fr, fc) = sess.waitFor(" Open folder ")
    sess.click(fr, fc + 2)
    discard sess.waitFor("Folder to open")
    sess.send(project)
    sess.send("\r")
    discard sess.waitFor("plat51proj", timeoutMs = 30000)
    let (mr, _) = sess.waitFor("main.py", timeoutMs = 30000)
    ck mr > 0
    ck sess.snap().text(0).contains("plat51proj")
    ck sess.snap().findRow("Welcome to CodeTracer")[0] < 0
    sess.quit()

suite "PLAT-51 part B real terminal: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
