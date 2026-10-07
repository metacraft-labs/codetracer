## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/terminal_output_pane.nim — PLAT-52. The terminal's **Terminal
## Output** pane: what the recorded program wrote to its terminal, positioned
## in time. Until PLAT-52 it was a report leaf here ("the recorded program's
## terminal output has no terminal view yet").
##
## Spec: `codetracer-specs/spec/GUI/Core-Panes/Terminal-Output-Pane.md`.
##
## Two views over ONE shared model (`viewmodels/terminal_output_model`, which
## the desktop and the GPUI window draw too):
##
##  * the LINE view — the output's lines, each fragment in the colours and
##    weights the program wrote it in (its decoded SGR attributes, painted as
##    literal colours through the desktop's palette), past and active
##    fragments as written and the future ones muted (the desktop's `.future`
##    draws them at half opacity); the rightmost column is a SCRUBBER over
##    every line of the output (Scrollbar-Scrubbers.md §4: an eighth-block
##    thumb, the current position marked in the execution pointer's colour);
##  * the SCREEN view, offered when the output drives a screen — the terminal
##    as the program left it at the current recording position, composited
##    cell for cell (never re-wrapped; clipped, and said so, when the pane is
##    smaller than the recorded screen: a terminal cannot scale a cell), with
##    its BUILT-IN SCRUBBER along the bottom: a one-row track over the writes,
##    an eighth-block thumb, the marks of clears and alternate-screen
##    switches under it. It is REAL-TIME: dragging it moves the debugger to
##    each write it crosses, so every other pane follows the drag.
##
##     Lines  Screen              write 12 / 40 · tick 377
##     ┌──────────────────────────────┐
##     │ top - 12:01  load 0.42       │
##     │ PID  NAME         CPU        │
##     ...
##     ───────────▌─────────────────────────
##       ▲         c                  ▼
##
## Pure functions of `TerminalOutputPaneModel`; `terminalOutputHitAt` reads a
## press back through the SAME geometry (`terminalPaneGeometry`), so a click
## and the drawing cannot disagree.

import std/[math, unicode]

import codetracer_embed

import ../layout/cells
import ../layout/project
import ./header
import ./styled_row
import ./scrubber_track

export scrubber_track

type
  TerminalOutputPaneModel* = object
    loaded*: bool
      ## A session supplied the pane.
    loading*: bool
      ## Its first load has not landed.
    offered*: bool
      ## The output contains screen control: the screen view is offered.
    view*: TerminalView
    lines*: seq[TerminalLine]
      ## Every line of the output (the whole population: the output is
      ## loaded whole).
    currentTicks*: uint64
      ## The debugger's position: fragments are past / active / future
      ## against it.
    currentLine*: int
      ## The line of the current position (the scrubber's mark), -1 for none.
    scrollTop*: int
      ## The first line shown, when the reader scrolled (`follow` false).
    follow*: bool
      ## Keep the current line in view (the default, until the reader
      ## scrolls; `.` follows again).
    screen*: TerminalScreenModel
      ## The screen view's model (snapshots, marks), shared with the
      ## ViewModel.
    shownWrite*: int
      ## The write whose screen is shown: the preview while the scrubber is
      ## dragged, else the last write at or before the current tick.
    previewing*: bool
      ## The screen's scrubber is held: `shownWrite` is the write under the
      ## pointer.
    scrubSent*: int
      ## The write the held scrubber last moved the debugger to — the
      ## scrubber is REAL-TIME (the user, 2026-10-06): a drag moves the
      ## recording position to each write it crosses, one jump per write.

  TerminalPaneGeometry* = object
    ## Where each part of the pane is, for a model painted into an area.
    bodyTop*: int
      ## The first row under the tab strip.
    headerRow*: int
      ## The toggle / position row, -1 when the screen view is not offered.
    contentTop*, contentRows*: int
      ## The line view's rows, or the screen's.
    textCol*, textWidth*: int
    trackCol*: int
      ## The line view's scrubber column, -1 when it has none.
    screenTrackRow*, screenMarksRow*: int
      ## The screen scrubber's track and its marks, -1 in the line view.
    screenTrackCol*, screenTrackWidth*: int
    linesToggle*, screenToggle*: tuple[col, width: int]
      ## The two toggle buttons on `headerRow`.

  TerminalHitKind* = enum
    thNone
    thViewLines        ## the "Lines" toggle
    thViewScreen       ## the "Screen" toggle
    thFragment         ## a fragment (or a line past its text): `eventIndex`
    thLineTrack        ## the line view's scrubber track: `fraction`
    thLineThumb        ## its thumb: `fraction`, `thumbOffset` (track units)
    thScreenTrack      ## the screen scrubber's track: `fraction`
    thScreen           ## the screen itself

  TerminalHit* = object
    kind*: TerminalHitKind
    eventIndex*: int
    line*: int
    fraction*: float

const
  TerminalViewLinesLabel* = "Lines"
  TerminalViewScreenLabel* = "Screen"
  TerminalMutedStyle = CellStyle(role: srChromeMuted, italic: true)
  ToggleActiveStyle = CellStyle(role: srTabActive)
  ToggleInactiveStyle = CellStyle(role: srTabInactive)
  InfoStyle = CellStyle(role: srChromeMuted)

func emptyText*(m: TerminalOutputPaneModel): string =
  ## The desktop's two overlays, word for word: loading until a session has
  ## supplied the output, then the empty-output sentence.
  if m.loading or not m.loaded: "Loading record output..."
  else: "The current record does not print anything to the terminal."

func screenShown*(m: TerminalOutputPaneModel): bool =
  m.offered and m.view == tvScreen and not m.screen.isNil

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

proc terminalPaneGeometry*(m: TerminalOutputPaneModel;
                           area: CellArea): TerminalPaneGeometry =
  ## The parts of the pane painted into `area` (whose first row is its tab
  ## strip, as every pane's is).
  result = TerminalPaneGeometry(headerRow: -1, trackCol: -1,
                                screenTrackRow: -1, screenMarksRow: -1)
  result.bodyTop = area.row + 1
  let bottom = area.row + area.height       # exclusive
  var top = result.bodyTop
  if m.offered:
    result.headerRow = top
    let linesW = cellWidthOf(TerminalViewLinesLabel) + 2
    let screenW = cellWidthOf(TerminalViewScreenLabel) + 2
    result.linesToggle = (area.col, linesW)
    result.screenToggle = (area.col + linesW, screenW)
    inc top
  result.textCol = area.col
  if m.screenShown:
    result.screenTrackRow = max(top, bottom - 2)
    result.screenMarksRow = bottom - 1
    result.screenTrackCol = area.col
    result.screenTrackWidth = area.width
    result.contentTop = top
    result.contentRows = max(0, result.screenTrackRow - top)
    result.textWidth = area.width
  else:
    result.contentTop = top
    result.contentRows = max(0, bottom - top)
    if area.width >= 2:
      result.trackCol = area.col + area.width - 1
      result.textWidth = area.width - 1
    else:
      result.textWidth = area.width

func lineCount*(m: TerminalOutputPaneModel): int = m.lines.len

proc visibleTop*(m: TerminalOutputPaneModel; rows: int): int =
  ## The first line shown in `rows` rows: the reader's position, or — when
  ## following — the current line at the bottom of the view, as a terminal
  ## shows the output up to now.
  let maxTop = max(0, m.lines.len - rows)
  if m.follow:
    # Before the first write nothing is "up to now": the view starts at the
    # top, where the output will begin.
    if m.currentLine < 0: 0
    else: max(0, min(maxTop, m.currentLine - rows + 1))
  else:
    max(0, min(maxTop, m.scrollTop))

proc scrubberOf*(m: TerminalOutputPaneModel; rows: int): ScrubberModel =
  ## The line view's scrollbar scrubber: the WHOLE output (every line), the
  ## view's first row and height, the current line.
  scrubberModel(m.lines.len, m.visibleTop(rows), rows, m.currentLine)

# ---------------------------------------------------------------------------
# Thumb cells, in eighths
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc literalStyle*(a: TermAttrs): CellStyle =
  ## A run's SGR attributes as a cell style: the colours as LITERALS (content,
  ## not chrome — the frame viewer's rule), through the desktop's palette —
  ## the colours it is DRAWN in (`drawnColours`: reverse video swapped into
  ## explicit colours, as the desktop draws it, rather than left to the
  ## terminal's own default pair).
  let (fg, bg) = drawnColours(a)
  result = CellStyle(fg: termHex(fg), bg: termHex(bg), bold: a.bold,
                     italic: a.italic, underline: a.underline or a.strike)
  if a.faint and result.fg.len == 0:
    result.role = srChromeMuted

proc fragmentStyle*(f: TerminalEventFragment;
                    currentTicks: uint64): CellStyle =
  ## A fragment's cell style: as written in the past and at the current
  ## position, muted in the future (the desktop's `.future`).
  case fragmentTense(currentTicks, f.rrTicks)
  of ttPast, ttActive: literalStyle(f.style)
  of ttFuture:
    CellStyle(role: srChromeMuted, bold: f.style.bold,
              italic: f.style.italic, underline: f.style.underline)

proc clipNote*(m: TerminalOutputPaneModel; geo: TerminalPaneGeometry;
               area: CellArea): string =
  ## What the header says when the recorded screen does not fit the pane:
  ## the part shown, of the whole (the screen is never re-wrapped).
  if not m.screenShown:
    return ""
  let cols = m.screen.cols
  let rows = m.screen.rows
  if rows <= geo.contentRows and cols <= area.width:
    return ""
  " · clipped " & $min(cols, area.width) & "x" & $min(rows, geo.contentRows) &
    " of " & $cols & "x" & $rows

proc paintToggle(g: var StyledGrid; geo: TerminalPaneGeometry;
                 m: TerminalOutputPaneModel; area: CellArea) =
  if geo.headerRow < 0:
    return
  let screen = m.view == tvScreen
  g.paint(geo.headerRow, geo.linesToggle.col,
          " " & TerminalViewLinesLabel & " ",
          (if screen: ToggleInactiveStyle else: ToggleActiveStyle))
  g.paint(geo.headerRow, geo.screenToggle.col,
          " " & TerminalViewScreenLabel & " ",
          (if screen: ToggleActiveStyle else: ToggleInactiveStyle))
  let info =
    if screen and not m.screen.isNil:
      let n = m.screen.writeCount
      (if m.shownWrite < 0: "before the first write"
       else: "write " & $(m.shownWrite + 1) & " / " & $n & " · tick " &
             $m.screen.writes[m.shownWrite].rrTicks) &
      (if m.previewing: " · scrubbing" else: "") & clipNote(m, geo, area)
    else:
      $m.lines.len & " line" & (if m.lines.len == 1: "" else: "s")
  let used = geo.linesToggle.width + geo.screenToggle.width + 1
  let room = area.width - used
  if room > 0:
    g.paint(geo.headerRow, area.col + used, fitCells(info, room), InfoStyle)

proc paintLineAt(g: var StyledGrid; row, col, width: int;
                 line: TerminalLine; currentTicks: uint64) =
  var c = col
  let stop = col + width
  for f in line.fragments:
    if c >= stop: break
    if f.text.len == 0: continue
    let text = truncateToCells(f.text, stop - c)
    g.paint(row, c, text, fragmentStyle(f, currentTicks))
    c += cellWidthOf(text)

proc paintLineScrubber(g: var StyledGrid; geo: TerminalPaneGeometry;
                       m: TerminalOutputPaneModel) =
  if geo.trackCol < 0 or geo.contentRows <= 0:
    return
  let sm = m.scrubberOf(geo.contentRows)
  let span = sm.thumbSpan(geo.contentRows * 8, 8)
  let cells = thumbCells(span, geo.contentRows, vertical = true)
  for i, cell in cells:
    g.paint(geo.contentTop + i, geo.trackCol, cell.glyph, styleOf(cell.kind))
  let f = sm.currentFraction
  if f >= 0.0:
    let r = min(geo.contentRows - 1, int(floor(f * float(geo.contentRows))))
    g.paint(geo.contentTop + r, geo.trackCol, ThumbFullGlyph, MarkStyle)

proc paintScreen(g: var StyledGrid; geo: TerminalPaneGeometry;
                 m: TerminalOutputPaneModel; area: CellArea): TermScreen =
  result = m.screen.screenAfter(m.shownWrite)
  let rows = min(result.rows, geo.contentRows)
  for r in 0 ..< rows:
    for run in result.screenRowRuns(r):
      if run.col >= area.width: break
      let blank = run.attrs == TermAttrs() and run.text.strip.len == 0
      if blank: continue
      let text = truncateToCells(run.text, area.width - run.col)
      g.paint(geo.contentTop + r, area.col + run.col, text,
              literalStyle(run.attrs))
  # Clipped when the pane is smaller than the recorded screen — a terminal
  # cannot scale a cell — and the header row says so (`clipNote`).

proc paintScreenScrubber(g: var StyledGrid; geo: TerminalPaneGeometry;
                         m: TerminalOutputPaneModel) =
  if geo.screenTrackRow < 0 or geo.screenTrackWidth <= 0:
    return
  let n = m.screen.writeCount
  let w = geo.screenTrackWidth
  let units = w * 8
  # The thumb is one cell long, centred on the shown write's position.
  let pos =
    if n <= 1 or m.shownWrite < 0: 0
    else: int(round(fractionOfWrite(n, m.shownWrite) * float(units - 8)))
  let cells = thumbCells(ThumbSpan(start: pos, length: 8), w,
                         vertical = false)
  for i, cell in cells:
    g.paint(geo.screenTrackRow, geo.screenTrackCol + i, cell.glyph,
            styleOf(cell.kind))
  if geo.screenMarksRow >= 0 and geo.screenMarksRow != geo.screenTrackRow:
    for mark in m.screen.marks:
      let x = int(round(fractionOfWrite(n, mark.write) * float(w - 1)))
      g.paint(geo.screenMarksRow, geo.screenTrackCol + x, markGlyph(mark.kind),
              MarkStyle)

proc paintTerminalOutput*(g: var StyledGrid; area: CellArea;
                          m: TerminalOutputPaneModel): seq[string] =
  ## Paint the pane into `area` (its first row is under the tab strip) and
  ## answer the content rows' texts as painted (the line view's lines or the
  ## screen's rows), for a test to read.
  if area.width <= 0 or area.height <= 1:
    return
  let geo = terminalPaneGeometry(m, area)
  paintToggle(g, geo, m, area)
  if m.lines.len == 0 and not m.screenShown:
    if geo.contentTop < area.row + area.height:
      g.paint(geo.contentTop, area.col, fitCells(emptyText(m), area.width),
              TerminalMutedStyle)
      result.add emptyText(m)
    return
  if m.screenShown:
    let screen = paintScreen(g, geo, m, area)
    for r in 0 ..< min(screen.rows, geo.contentRows):
      result.add screen.screenRowText(r)
    paintScreenScrubber(g, geo, m)
    return
  let top = m.visibleTop(geo.contentRows)
  for i in 0 ..< geo.contentRows:
    let li = top + i
    if li >= m.lines.len: break
    paintLineAt(g, geo.contentTop + i, geo.textCol, geo.textWidth,
                m.lines[li], m.currentTicks)
    result.add truncateToCells(lineText(m.lines[li]), geo.textWidth)
  paintLineScrubber(g, geo, m)

# ---------------------------------------------------------------------------
# Hit testing
# ---------------------------------------------------------------------------

proc fragmentAt*(line: TerminalLine; cell: int): int =
  ## The index of the fragment drawn over `cell` (0-based from the line's
  ## start); a cell past the text is the line's LAST fragment (a click on
  ## the line goes to the write that completed it); -1 for an empty line.
  if line.fragments.len == 0:
    return -1
  var c = 0
  for i, f in line.fragments:
    let w = cellWidthOf(f.text)
    if cell >= c and cell < c + w:
      return i
    c += w
  line.fragments.len - 1

proc terminalOutputHitAt*(m: TerminalOutputPaneModel; area: CellArea;
                          row, col: int): TerminalHit =
  ## What a press at `(row, col)` is on, for the pane painted into `area` by
  ## `paintTerminalOutput`.
  result = TerminalHit(kind: thNone, eventIndex: -1, line: -1)
  if area.width <= 0 or not area.contains(row, col):
    return
  let geo = terminalPaneGeometry(m, area)
  if row == geo.headerRow and geo.headerRow >= 0:
    if col >= geo.linesToggle.col and
       col < geo.linesToggle.col + geo.linesToggle.width:
      return TerminalHit(kind: thViewLines, eventIndex: -1, line: -1)
    if col >= geo.screenToggle.col and
       col < geo.screenToggle.col + geo.screenToggle.width:
      return TerminalHit(kind: thViewScreen, eventIndex: -1, line: -1)
    return
  if m.screenShown:
    if row == geo.screenTrackRow or row == geo.screenMarksRow:
      return TerminalHit(kind: thScreenTrack, eventIndex: -1, line: -1,
                         fraction: fractionAt(col - geo.screenTrackCol,
                                              geo.screenTrackWidth))
    if row >= geo.contentTop and row < geo.contentTop + geo.contentRows:
      return TerminalHit(kind: thScreen, eventIndex: -1, line: -1)
    return
  if row < geo.contentTop or row >= geo.contentTop + geo.contentRows:
    return
  if col == geo.trackCol:
    let sm = m.scrubberOf(geo.contentRows)
    let span = sm.thumbSpan(geo.contentRows * 8, 8)
    let unit = (row - geo.contentTop) * 8 + 4
    let fraction = trackFractionAt(row - geo.contentTop, geo.contentRows)
    if unit >= span.start and unit < span.start + span.length:
      return TerminalHit(kind: thLineThumb, eventIndex: -1, line: -1,
                         fraction: fraction)
    return TerminalHit(kind: thLineTrack, eventIndex: -1, line: -1,
                       fraction: fraction)
  let li = m.visibleTop(geo.contentRows) + (row - geo.contentTop)
  if li < 0 or li >= m.lines.len:
    return
  let fi = fragmentAt(m.lines[li], col - geo.textCol)
  if fi < 0:
    return
  result = TerminalHit(kind: thFragment, line: li,
                       eventIndex: m.lines[li].fragments[fi].eventIndex)
