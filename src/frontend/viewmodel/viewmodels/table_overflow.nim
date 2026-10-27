## viewmodels/table_overflow.nim — what a TABLE pane does with a cell whose
## text is wider than its column: the cut and its `…`, the full text on hover
## and under the row on a detail gesture, and the columns' widths.
##
## Spec: `codetracer-specs/spec/GUI/Layout-And-Navigation/Horizontal-Overflow.md`
## §5 (PLAT-70 Part B). The panes: Variables, Event Log, Call Trace.
##
## **One decision per cell, made here and drawn by every front-end.**
##
##   * `fitCell` cuts a cell's text to its column with the presenter's own
##     clip (`vocabulary.clipToCells`) and says whether it cut (§5.1:
##     `truncated`). A front-end draws `text` and hit-tests `truncated`; none
##     of them measures a cell and decides for itself, so the terminal, GPUI and
##     the desktop agree on which cells carry `…` (HO-8). A VALUE cell is not
##     cut here: the presenter returns it already fitted to the cell's budget,
##     with `Presentation.truncated` (PLAT-2's rule, enforced by
##     `ci/test/value-presentation-boundary.sh`); `presentedCell` wraps that
##     answer in the same `FittedCell`.
##   * `HoverClock` is the 500 ms rest before a truncated cell's tooltip
##     (§5.3), for every front-end's pointer: the terminal's `?1003` motion
##     reports, GPUI's mouse moves, the desktop's `mousemove`.
##   * `DetailToggle` is the one row whose full text is open under it, and
##     `detailView` lays that text out: wrapped in its column, capped at
##     `detailMaxLines` with the copy hint on the last line (OQ-H4).
##   * Column widths are cells. A front-end that lays out in pixels converts at
##     `ColumnCellPx` (§5.2: three cells are 24 px), so a width dragged in the
##     terminal is the width in GPUI and on the desktop (HO-9).
##     `encodeColumnWidths` / `decodeColumnWidths` are the remembered document
##     every front-end reads and writes (`host/table_column_widths.nim` on the
##     native front-ends, Electron's main process on the desktop).
##
## Pure; C and JavaScript backends.

import std/strutils
from std/unicode import runes, `$`

import ../../../common/value_presentation/[vocabulary, value_model, presenter,
                                           surfaces]

export vocabulary.PresentationMeasure, vocabulary.Ellipsis

const
  MinColumnCells* = 3
    ## §5.2: a resize never makes a column narrower than this; hiding is its
    ## own command.
  ColumnCellPx* = 8
    ## §5.2: a cell of column width is 8 px on the pixel front-ends (three
    ## cells, 24 px).
  ColumnStepCells* = 2
    ## How far **Widen Column** / **Narrow Column** move the focused column's
    ## separator.
  HoverDelayMs* = 500
    ## §5.3: VS Code's `workbench.hover.delay`.
  TooltipMaxColumns* = 80
    ## §5.3: the tooltip wraps at `min(80 columns, the window width)`.
  DetailLineCap* = 10
    ## §5.3 (OQ-H4): `DetailMaxLines = min(10, half the pane's body rows)`.
  TableColumnsFileName* = "table-columns"
    ## The remembered widths, in the native state root beside the layout and
    ## preference documents (one file for every front-end).
  VariablesTablePane* = "variables"
  EventLogTablePane* = "event-log"
  CallTraceTablePane* = "call-trace"
    ## The table panes' names in a `DetailToggle`, a `HoverClock` and a cut
    ## cell — one spelling for every front-end.

type
  FittedCell* = object
    ## One table cell, decided once.
    text*: string
      ## What is drawn: at most the column's cells, ending in `…` when cut.
    full*: string
      ## The whole text — what the tooltip, the detail and `list.copy` show.
    truncated*: bool
      ## The cell was cut (§5.1). Only a cut cell carries `…`, the hover and
      ## the `…` click.

  DetailView* = object
    ## The full text laid out under its row, or in a tooltip.
    lines*: seq[string]
      ## The lines drawn, the hint (when there is one) the last of them.
    hiddenLines*: int
      ## Wrapped lines past the cap, counted by the hint.
    capped*: bool

  DetailToggle* = object
    ## §5.3: "One row may be open at a time." The pane and its row's key (a
    ## variable's path, an event's number, a call's index) and the column whose
    ## text is shown.
    pane*: string
    key*: string
    column*: string

  CutCell* = object
    ## Where a TRUNCATED cell was drawn, in the front-end's own units (terminal
    ## cells, GPUI pixels), so the pointer and the `…` click are hit-tested
    ## against the paint rather than against a second layout.
    row*, col*, width*: int
    height*: int
      ## How tall the cell is, in the same units (a GPUI row's pixels); 0
      ## reads as 1 (a terminal row).
    ellipsisCol*: int
      ## Where the `…` is: the cell's last drawn cell (one left of its edge
      ## when a wide glyph made room for it).
    ellipsisWidth*: int
      ## How wide the `…` is drawn (one terminal cell; one character's pixels
      ## in GPUI). 0 reads as 1.
    key*, column*: string
      ## The row's key and the column's name — what a detail or a hover names.
    full*: string

  HoverClock* = object
    ## §5.3's tooltip: the cell under the pointer, since when, and whether its
    ## tooltip is shown. A cell is named by its pane, row key and column.
    pane*, key*, column*: string
    full*: string
      ## The text the tooltip shows.
    sinceMs*: int64
    shown*: bool

func runeMeasure*(s: string): int {.gcsafe, raises: [].} =
  ## One cell per character: the pixel front-ends' monospace columns.
  defaultMeasure(s)

func oneLine*(text: string): string =
  ## A table cell is one line: newlines and runs of white space collapse to
  ## one space, as the desktop's `white-space: nowrap` collapses them.
  strutils.splitWhitespace(text).join(" ")

func fitCell*(full: string; cells: int;
              measure: PresentationMeasure = runeMeasure): FittedCell =
  ## `full` in a column `cells` wide: drawn as one line, cut with `…` as its
  ## last cell when it does not fit (§5.1). The cut never splits a wide
  ## glyph (`clipToCells` drops it and the `…` moves one cell left).
  let line = oneLine(full)
  result.full = full
  if cells <= 0:
    result.text = ""
    result.truncated = line.len > 0
    return
  let ctx = PresentationContext(measure: measure)
  let (text, clipped) = ctx.clipToCells(line, cells)
  result.text = text
  result.truncated = clipped

func presentedCell*(text, full: string; truncated: bool): FittedCell =
  ## A value cell: the presenter's answer at the cell's budget (already
  ## fitted) and its `Presentation.truncated`, with the whole value beside it.
  FittedCell(text: text, full: full, truncated: truncated)

func fullValueText*(v: PValue; fallback: string;
                    presenters: PresenterSet = BuiltinPresenters): string =
  ## A value cell's WHOLE text (§5.3): the presenter at `tableFullBudget` —
  ## the state panel's caps on one line — so the tooltip, the detail and
  ## `list.copy` show the same untruncated value on every front-end.
  ## `fallback` (the store's own rendering) when there is no value.
  if v.isNil: fallback
  else: present(v, tableFullBudget(), presenters = presenters).root.text

func cellsOfPx*(px: int): int =
  ## A pixel width as column cells, for the pixel front-ends (§5.2).
  max(0, px div ColumnCellPx)

func pxOfCells*(cells: int): int =
  cells * ColumnCellPx

func clampColumnCells*(cells: int): int =
  ## §5.2's minimum.
  max(MinColumnCells, cells)

func cutCellAt*(cuts: openArray[CutCell]; row, col: int): int =
  ## The cut cell under `(row, col)`, -1 for none (a cell that fits is never
  ## here, so the hover and the `…` click cannot reach it).
  for i, c in cuts:
    if row >= c.row and row < c.row + max(1, c.height) and col >= c.col and
       col < c.col + c.width:
      return i
  -1

func ellipsisAt*(cuts: openArray[CutCell]; row, col: int): int =
  ## The cut cell whose `…` is under `(row, col)`, -1 for none (§5.3: "Click
  ## on the `…`").
  for i, c in cuts:
    if row >= c.row and row < c.row + max(1, c.height) and
       col >= c.ellipsisCol and
       col < c.ellipsisCol + max(1, c.ellipsisWidth):
      return i
  -1

# ---------------------------------------------------------------------------
# The full text: wrapping, the cap and the hint
# ---------------------------------------------------------------------------

func detailMaxLines*(bodyRows: int): int =
  ## §5.3 (OQ-H4): `min(10, half the pane's body rows)`, and at least one.
  max(1, min(DetailLineCap, bodyRows div 2))

func wrapCells*(text: string; cells: int;
                measure: PresentationMeasure = runeMeasure): seq[string] =
  ## `text` as lines of at most `cells` cells: its own newlines kept, each
  ## line broken at the last space that fits, or mid-word when no space does.
  ## A wide glyph is never split. An empty text is one empty line.
  if cells <= 0:
    return @[]
  for raw in text.splitLines:
    if raw.len == 0:
      result.add ""
      continue
    var line = ""
    var used = 0
    var lastSpace = -1      # byte index in `line` of its last space
    var usedAtSpace = 0
    for r in raw.runes:
      let piece = $r
      let w = max(1, measure(piece))
      if used + w > cells and line.len > 0 and lastSpace > 0:
        # Break at the last space: the word that did not fit moves down.
        result.add line[0 ..< lastSpace]
        line = line[lastSpace + 1 .. ^1]
        used = used - usedAtSpace - 1
        lastSpace = -1
      if used + w > cells and line.len > 0:
        # No space to break at (or the moved word is still too long).
        result.add line
        line = ""
        used = 0
        lastSpace = -1
      if piece == " ":
        lastSpace = line.len
        usedAtSpace = used
      line.add piece
      used += w
    result.add line

func copyHint*(hiddenLines: int; copyChord: string): string =
  ## §5.3: the last line past the cap — `… <n> more lines — Ctrl+C copies the
  ## value`, with the resolved `list.copy` chord (KL-8). Without a chord the
  ## palette's **Copy** is named.
  Ellipsis & " " & $hiddenLines & " more line" &
    (if hiddenLines == 1: "" else: "s") & " — " &
    (if copyChord.len > 0: copyChord & " copies the value"
     else: "Copy (the palette) copies the value")

func capLines(wrapped: seq[string]; cap: int; copyChord: string;
              cells: int; measure: PresentationMeasure): DetailView =
  if wrapped.len <= cap:
    return DetailView(lines: wrapped)
  let kept = max(0, cap - 1)
  result.hiddenLines = wrapped.len - kept
  result.capped = true
  result.lines = wrapped[0 ..< kept]
  let hint = copyHint(result.hiddenLines, copyChord)
  # The hint is one line too: cut at the width like any other line.
  let ctx = PresentationContext(measure: measure)
  result.lines.add ctx.clipToCells(hint, cells).text

func detailView*(full: string; cells, bodyRows: int; copyChord: string;
                 measure: PresentationMeasure = runeMeasure): DetailView =
  ## §5.3's detail: `full` wrapped inside its column (`cells` wide), at most
  ## `detailMaxLines(bodyRows)` lines, the last of them the hint when cut.
  capLines(wrapCells(full, cells, measure), detailMaxLines(bodyRows),
           copyChord, cells, measure)

func tooltipColumns*(windowCols: int): int =
  ## §5.3: `min(80 columns, the window width)`.
  max(1, min(TooltipMaxColumns, windowCols))

func tooltipView*(full: string; windowCols, bodyRows: int; copyChord: string;
                  measure: PresentationMeasure = runeMeasure): DetailView =
  ## §5.3's tooltip: the same text wrapped at `tooltipColumns`, at most
  ## `detailMaxLines` lines.
  let cols = tooltipColumns(windowCols)
  capLines(wrapCells(full, cols, measure), detailMaxLines(bodyRows),
           copyChord, cols, measure)

# ---------------------------------------------------------------------------
# The open detail — one row at a time
# ---------------------------------------------------------------------------

func isOpen*(d: DetailToggle; pane, key: string): bool =
  d.pane.len > 0 and d.pane == pane and d.key == key

func isOpenIn*(d: DetailToggle; pane: string): bool =
  d.pane.len > 0 and d.pane == pane

func toggleDetail*(d: var DetailToggle; pane, key: string;
                   column = ""): bool =
  ## §5.3: "Doing it again closes it. One row may be open at a time." True
  ## when the row is now open.
  if d.isOpen(pane, key) and (column.len == 0 or d.column == column):
    d = DetailToggle()
    return false
  d = DetailToggle(pane: pane, key: key, column: column)
  true

# ---------------------------------------------------------------------------
# Hover — the 500 ms rest on a truncated cell
# ---------------------------------------------------------------------------

func sameCell*(h: HoverClock; pane, key, column: string): bool =
  h.pane == pane and h.key == key and h.column == column

func pointerOver*(h: var HoverClock; pane, key, column, full: string;
                  truncated: bool; nowMs: int64): bool =
  ## The pointer is on a cell (`pane` "" for none). Only a TRUNCATED cell
  ## starts the clock (§5.3: a tooltip repeating what is on screen is noise);
  ## leaving the cell hides its tooltip. True when a shown tooltip changed.
  if pane.len > 0 and truncated:
    if h.pane.len > 0 and h.sameCell(pane, key, column):
      return false
    result = h.shown
    h = HoverClock(pane: pane, key: key, column: column, full: full,
                   sinceMs: nowMs)
  else:
    result = h.shown
    h = HoverClock()

func tick*(h: var HoverClock; nowMs: int64): bool =
  ## The clock: the tooltip shows once the pointer has rested
  ## `HoverDelayMs`. True when it became shown.
  if h.pane.len == 0 or h.shown:
    return false
  if nowMs - h.sinceMs >= HoverDelayMs:
    h.shown = true
    return true
  false

func dueMs*(h: HoverClock): int64 =
  ## When `tick` next has something to do, -1 for never.
  if h.pane.len == 0 or h.shown: -1'i64
  else: h.sinceMs + HoverDelayMs

func dismiss*(h: var HoverClock): bool =
  ## A key press, or the pointer leaving the pane (§5.3). True when a shown
  ## tooltip went away.
  result = h.shown
  h = HoverClock()

# ---------------------------------------------------------------------------
# Remembered widths
# ---------------------------------------------------------------------------

type
  ColumnWidthEntry* = tuple[table, column: string; cells: int]

func encodeColumnWidths*(entries: openArray[ColumnWidthEntry]): string =
  ## One `<table>.<column>=<cells>` line per width that was set.
  for e in entries:
    if e.cells > 0:
      result.add e.table & "." & e.column & "=" & $e.cells & "\n"

func mergeColumnWidths*(stored: openArray[ColumnWidthEntry]; table: string;
                        mine: openArray[ColumnWidthEntry]): seq[ColumnWidthEntry] =
  ## The remembered document with `table`'s widths replaced by `mine` and
  ## every other table's kept — what each front-end writes back.
  for e in stored:
    if e.table != table:
      result.add e
  for e in mine:
    result.add e

func decodeColumnWidths*(text: string):
    tuple[ok: bool; entries: seq[ColumnWidthEntry]; message: string] =
  ## The document back; a line that is not `<table>.<column>=<cells>` refuses
  ## the whole document by name (a remembered state that is half applied is
  ## worse than the defaults).
  result.ok = true
  for raw in text.splitLines:
    let line = raw.strip
    if line.len == 0 or line.startsWith("#"):
      continue
    let eq = line.find('=')
    let dot = line.find('.')
    if eq <= 0 or dot <= 0 or dot > eq:
      return (false, @[], "not a column width: `" & line & "`")
    var cells = 0
    try:
      cells = parseInt(line[eq + 1 .. ^1].strip)
    except ValueError:
      return (false, @[], "not a number of cells: `" & line & "`")
    if cells < MinColumnCells:
      return (false, @[], "narrower than " & $MinColumnCells & " cells: `" &
                          line & "`")
    result.entries.add (table: line[0 ..< dot], column: line[dot + 1 ..< eq],
                        cells: cells)
