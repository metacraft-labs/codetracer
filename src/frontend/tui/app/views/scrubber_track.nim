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
##
## PLAT-70 Part H: a SCROLLBAR is drawn by `scrollbar_styles.paintBar` (the
## options' glyphs and roles, the pointer's states, the fade); this module
## keeps the projection — where the mark is, where a press falls — and the
## eighth-block cells of the position SLIDERS (the terminal screen's
## scrubber, the frame viewer's), which are not scrollbars.

import std/math

import codetracer_embed

import ./styled_row
import ./scrollbar_styles

export scrollbar_styles

const
  TrackStyle* = CellStyle(role: srScrubberTrack)
  ThumbStyle* = CellStyle(role: srScrubberThumb)
  ThumbReversedStyle* = CellStyle(role: srScrubberTrack,
                                  surface: srScrubberThumbGround)
  MarkStyle* = CellStyle(role: srScrubberMark)
  ScrubberTrackCells* = 1
    ## The track's width: one cell, the pane's rightmost column.

type
  ThumbCellKind* = enum
    tcTrack, tcThumb, tcThumbReversed,
    tcThumbSpace
      ## PLAT-71: a reverse-video space in the thumb's colour — the thumb on
      ## the ambiguous-wide column, where every block glyph is two cells.
  ThumbCell* = object
    kind*: ThumbCellKind
    glyph*: string

proc wholeCellThumbs(span: ThumbSpan; cells: int; vertical: bool;
                     glyphs: GlyphProfile): seq[ThumbCell] =
  ## PLAT-71 (Terminal-Adaptation §6.4): a slider on the `basic`, ASCII or
  ## ambiguous-wide column — whole cells only, the eighths need `extended`
  ## and narrow widths. A cell is thumb when the thumb covers its centre.
  let track =
    if glyphs.tier == tierAscii or glyphs.ambiguousWide:
      (if vertical: "|" else: "-")
    else: (if vertical: TrackVerticalGlyph else: TrackHorizontalGlyph)
  for c in 0 ..< cells:
    let centre = c * 8 + 4
    if centre >= span.start and centre < span.start + max(1, span.length):
      if glyphs.tier == tierAscii:
        result.add ThumbCell(kind: tcThumb, glyph: "#")
      elif glyphs.ambiguousWide:
        result.add ThumbCell(kind: tcThumbSpace, glyph: " ")
      else:
        result.add ThumbCell(kind: tcThumb, glyph: ThumbFullGlyph)
    else:
      result.add ThumbCell(kind: tcTrack, glyph: track)

proc thumbCells*(span: ThumbSpan; cells: int; vertical: bool;
                 modern = false; glyphs = DefaultGlyphs): seq[ThumbCell] =
  ## A track of `cells` cells with a thumb covering `span` (in EIGHTHS of a
  ## cell), cell by cell. A cell the thumb covers fully is a full block; the
  ## cell where the thumb starts part-way is the eighth block of its FAR part
  ## (the lower part of a vertical cell, the right part of a horizontal one —
  ## drawn as the complementary block in the track colour on the thumb's
  ## ground, since the classic blocks have only lower and left eighths); the
  ## cell where it ends part-way is the eighth block of its NEAR part.
  ## `modern` (the `modern-unicode` setting, Scrollbar-Scrubbers.md §7.1):
  ## the upper and right eighths are Symbols for Legacy Computing's, drawn
  ## in the thumb's own colour — no reversed cell.
  if glyphs.tier != tierExtended or glyphs.ambiguousWide:
    return wholeCellThumbs(span, cells, vertical, glyphs)
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
      elif modern:
        result.add ThumbCell(kind: tcThumb, glyph: RightEighthsModern[covered])
      else:
        result.add ThumbCell(kind: tcThumbReversed,
                             glyph: LeftEighths[8 - covered])
    elif lo == a and hi < b:
      # Covers the near part: the UPPER eighths of a vertical cell (the
      # complementary lower block reversed), the LEFT eighths of a horizontal
      # one.
      if vertical and modern:
        result.add ThumbCell(kind: tcThumb, glyph: UpperEighthsModern[covered])
      elif vertical:
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
  of tcThumbSpace:
    var s = ThumbStyle
    s.reverse = true
    s


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
  ## The scrollbar down column `col` from row `top` for `rows` rows, and the
  ## current-position mark (§3.5) — the cell of the row the debugger is at —
  ## drawn as the scrollbar options say (`scrollbar_styles.paintBar`).
  if rows <= 0 or col < 0:
    return
  let markRow = sm.currentMarkRow(top, rows)
  g.paintBar(axVertical, col, top, rows, sm,
             (if markRow >= 0: markRow - top else: -1))

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


# ---------------------------------------------------------------------------
# A horizontal bar in one row (Horizontal-Overflow.md §4)
# ---------------------------------------------------------------------------

proc currentMarkCol*(sm: ScrubberModel; left, cols: int): int =
  ## The screen column the bar's mark (the editor's caret column) is painted
  ## on, or -1.
  let f = sm.currentFraction
  if f < 0.0 or cols <= 0: -1
  else: left + min(cols - 1, int(floor(f * float(cols))))

proc paintHorizontalBar*(g: var StyledGrid; row, left, cols: int;
                         sm: ScrubberModel) =
  ## The overflow-only horizontal bar (§4.7): along `row` from column `left`
  ## for `cols` cells, with the editor's caret column marked as the vertical
  ## scrubber marks "now" — drawn as the scrollbar options say.
  if cols <= 0 or row < 0:
    return
  let markCol = sm.currentMarkCol(left, cols)
  g.paintBar(axHorizontal, row, left, cols, sm,
             (if markCol >= 0: markCol - left else: -1))

proc horizontalBarHit*(sm: ScrubberModel; left, cols, col: int;
                       cellX = -1.0): ScrubberHit =
  ## A press at screen column `col` on a bar drawn by `paintHorizontalBar`:
  ## on the thumb (a drag starts) or on the track (a click centres), with the
  ## fraction the model takes. `cellX` is the pointer in fractional CELLS
  ## when the terminal reported pixels (SGR-pixel, DECSET 1016): the fraction
  ## is then taken to an eighth of a cell, the thumb's own resolution.
  if cols <= 0 or col < left or col >= left + cols:
    return ScrubberHit(kind: shNone)
  let span = sm.thumbSpan(cols * 8, MinThumbEighths)
  let unit = if cellX >= 0.0:
               clamp(int(floor((cellX - float(left)) * 8.0)), 0, cols * 8 - 1)
             else: (col - left) * 8 + 4
  let fraction = if cellX >= 0.0: trackFractionAt(unit, cols * 8)
                 else: trackFractionAt(col - left, cols)
  if unit >= span.start and unit < span.start + span.length:
    ScrubberHit(kind: shThumb, fraction: fraction)
  else:
    ScrubberHit(kind: shTrack, fraction: fraction)

proc barScrollTo(v: var HorizontalView; hit: ScrubberHit;
                  dragging: bool): bool =
  ## What a press (`dragging = false`: the column at the fraction centred) or
  ## a held thumb (`dragging = true`: the thumb follows, centred on the
  ## pointer) does to the view — the view only (HO-4).
  if dragging: v.dragThumb(hit.fraction - v.barModel.thumbLength / 2.0)
  else: v.clickTrack(hit.fraction)

const
  PrecedesGlyph* = canonical(grOverflowLeft)
    ## §4.6: U+2039, in the first text column of a row whose text continues
    ## left of the view (Vim's `listchars` `precedes:`); `<` on the ASCII tier.
  ExtendsGlyph* = canonical(grOverflowRight)
    ## U+203A, in the last text column of a row that continues right of it
    ## (`extends:`); `>` on the ASCII tier.
  OverflowMarkerStyle* = CellStyle(role: srChromeMuted)
    ## The dimmed chrome style.

proc paintOverflowMarkers*(g: var StyledGrid; row, left: int;
                           rowWidth: int; v: HorizontalView) =
  ## §4.6: the `‹` / `›` markers of one row drawn from column `left` over a
  ## view `v` (its `viewportCols` wide), each replacing the text cell it is
  ## drawn on.
  if v.viewportCols <= 0:
    return
  let marks = overflowMarkers(rowWidth, v)
  if marks.precedes:
    g.paint(row, left, g.glyphText(grOverflowLeft), OverflowMarkerStyle)
  if marks.extends:
    g.paint(row, left + v.viewportCols - 1, g.glyphText(grOverflowRight),
            OverflowMarkerStyle)
