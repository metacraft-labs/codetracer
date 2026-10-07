## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/scrubber_track.nim — a list pane's SCROLLBAR SCRUBBER, as the
## terminal draws and hit-tests it (Scrollbar-Scrubbers.md §4, "Terminal"):
## the pane's rightmost column, one cell wide, inside the pane's own
## rectangle; the thumb in eighth blocks so its ends are sub-cell; the
## current-position mark in the execution pointer's colour. The model is the
## shared `viewmodels/scrollbar_scrubber.nim` — this module only projects its
## fractions onto cells and feeds a pointer's row back as a fraction ("no
## front-end computes a row from a pointer itself").
##
## Moved out of `terminal_output_pane.nim` (PLAT-52, its first user) by
## PLAT-51, when the Event Log and the Call Trace adopted the same scrubber.

import std/math

import codetracer_embed

import ./styled_row

const
  TrackVerticalGlyph* = "│"
  TrackHorizontalGlyph* = "─"
  ThumbFullGlyph* = "█"
  LowerEighths* = ["", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    ## `LowerEighths[k]`: the lower `k` eighths of a cell filled.
  LeftEighths* = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]
    ## `LeftEighths[k]`: the left `k` eighths of a cell filled.
  TrackStyle* = CellStyle(role: srScrubberTrack)
  ThumbStyle* = CellStyle(role: srScrubberThumb)
  ThumbReversedStyle* = CellStyle(role: srScrubberTrack,
                                  surface: srScrubberThumbGround)
  MarkStyle* = CellStyle(role: srScrubberMark)
  ScrubberTrackCells* = 1
    ## The track's width: one cell, the pane's rightmost column.
  MinThumbEighths* = 8
    ## The shortest thumb a pointer can hit: one cell.

type
  ThumbCellKind* = enum
    tcTrack, tcThumb, tcThumbReversed
  ThumbCell* = object
    kind*: ThumbCellKind
    glyph*: string

proc thumbCells*(span: ThumbSpan; cells: int; vertical: bool): seq[ThumbCell] =
  ## A track of `cells` cells with a thumb covering `span` (in EIGHTHS of a
  ## cell), cell by cell. A cell the thumb covers fully is a full block; the
  ## cell where the thumb starts part-way is the eighth block of its FAR part
  ## (the lower part of a vertical cell, the right part of a horizontal one —
  ## drawn as the complementary block in the track colour on the thumb's
  ## ground, since only lower and left eighths exist); the cell where it ends
  ## part-way is the eighth block of its NEAR part.
  let first = span.start
  let last = span.start + span.length          # exclusive, in eighths
  for c in 0 ..< cells:
    let a = c * 8
    let b = a + 8
    let lo = max(a, first)
    let hi = min(b, last)
    if hi <= lo:
      result.add ThumbCell(kind: tcTrack,
                           glyph: (if vertical: TrackVerticalGlyph
                                   else: TrackHorizontalGlyph))
      continue
    let covered = hi - lo
    if covered >= 8:
      result.add ThumbCell(kind: tcThumb, glyph: ThumbFullGlyph)
    elif lo > a and hi == b:
      # Covers the far part: for a vertical cell the LOWER `covered` eighths;
      # for a horizontal one the RIGHT eighths — the complementary left block
      # reversed.
      if vertical:
        result.add ThumbCell(kind: tcThumb, glyph: LowerEighths[covered])
      else:
        result.add ThumbCell(kind: tcThumbReversed,
                             glyph: LeftEighths[8 - covered])
    elif lo == a and hi < b:
      # Covers the near part: the UPPER eighths of a vertical cell (the
      # complementary lower block reversed), the LEFT eighths of a horizontal
      # one.
      if vertical:
        result.add ThumbCell(kind: tcThumbReversed,
                             glyph: LowerEighths[8 - covered])
      else:
        result.add ThumbCell(kind: tcThumb, glyph: LeftEighths[covered])
    else:
      # A thumb shorter than a cell inside one cell: a full block (the
      # shortest thumb a pointer can hit is one cell).
      result.add ThumbCell(kind: tcThumb, glyph: ThumbFullGlyph)

proc styleOf*(k: ThumbCellKind): CellStyle =
  case k
  of tcTrack: TrackStyle
  of tcThumb: ThumbStyle
  of tcThumbReversed: ThumbReversedStyle


# ---------------------------------------------------------------------------
# A vertical list scrubber in one column
# ---------------------------------------------------------------------------

type
  ScrubberHitKind* = enum
    shNone, shTrack, shThumb
  ScrubberHit* = object
    kind*: ScrubberHitKind
    fraction*: float
      ## Where on the track the pointer is, as the model's fraction (the
      ## centre of the cell it is on).

proc currentMarkRow*(sm: ScrubberModel; top, rows: int): int =
  ## The screen row the current-position mark is painted on (§3.5: the cell
  ## of the row the debugger is at), or -1.
  let f = sm.currentFraction
  if f < 0.0 or rows <= 0: -1
  else: top + min(rows - 1, int(floor(f * float(rows))))

proc paintVerticalScrubber*(g: var StyledGrid; col, top, rows: int;
                            sm: ScrubberModel) =
  ## The track down column `col` from row `top` for `rows` rows, the thumb
  ## over it in eighths, and the current-position mark (§3.5) — the cell of
  ## the row the debugger is at, in the execution pointer's colour.
  if rows <= 0 or col < 0:
    return
  let span = sm.thumbSpan(rows * 8, MinThumbEighths)
  let cells = thumbCells(span, rows, vertical = true)
  for i, cell in cells:
    g.paint(top + i, col, cell.glyph, styleOf(cell.kind))
  let markRow = sm.currentMarkRow(top, rows)
  if markRow >= 0:
    g.paint(markRow, col, ThumbFullGlyph, MarkStyle)

proc verticalScrubberHit*(sm: ScrubberModel; top, rows, row: int): ScrubberHit =
  ## A press at screen row `row` on a track drawn by `paintVerticalScrubber`:
  ## on the thumb (a drag starts) or on the track (a click jumps), with the
  ## fraction the model takes.
  if rows <= 0 or row < top or row >= top + rows:
    return ScrubberHit(kind: shNone)
  let span = sm.thumbSpan(rows * 8, MinThumbEighths)
  let unit = (row - top) * 8 + 4
  let fraction = trackFractionAt(row - top, rows)
  if unit >= span.start and unit < span.start + span.length:
    ScrubberHit(kind: shThumb, fraction: fraction)
  else:
    ScrubberHit(kind: shTrack, fraction: fraction)

proc scrubTo*(sm: ScrubberModel; hit: ScrubberHit; dragging: bool): int =
  ## The new first visible row for a press (`dragging = false`: §3.2's click,
  ## centring the row at the fraction) or a held thumb (`dragging = true`:
  ## §3.3, the thumb follows the pointer, centred on it).
  if dragging: sm.dragTo(hit.fraction - sm.thumbLength / 2.0)
  else: sm.clickAt(hit.fraction)
