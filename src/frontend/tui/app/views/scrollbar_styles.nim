## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/scrollbar_styles.nim — PLAT-70 Part H (Scrollbar-Scrubbers.md
## §7): EVERY glyph a bar of this front-end draws, in one table, and the one
## painter that draws a scrollbar with it.
##
## ## The table
##
## `ScrollbarGlyphs[tier][thickness]` is a pair of looks — at REST
## and WIDENED (under the pointer, held) — and a look is, per axis, the
## thumb's glyph for every set of sub-cell segments it covers in a cell plus
## the track's glyph (§7.2). Nothing else decides a glyph, and the table's
## first key is a GLYPH TIER (`GlyphTier`): today the classic Block Elements
## and Box Drawing set and `modern-unicode`'s Symbols for Legacy Computing;
## a terminal capability profile (PLAT-71: a `basic` tier, an
## ambiguous-width one) adds a column and a way to choose it, and no painter
## changes. The position sliders (the terminal screen's
## scrubber, the frame viewer's) keep the eighth-block glyphs at the end of
## this module; they are not scrollbars (§1).
##
## ## The painter
##
## `paintBar` draws one bar into a grid from the bar's scrubber model and
## reads everything else off the grid (`StyledGrid.scrollbars`, set by the
## shell): the options, what the pointer is doing to this bar, and how far it
## has faded. It paints FOREGROUND only — each cell keeps the pane's surface
## (SB-2) — in the `srScrollbar*` roles, so every colour rung, the terminal
## palette and monochrome come from the role tables. And it RECORDS the bar
## (`StyledGrid.bars`), which is what the runtime hit-tests the pointer
## against.

import codetracer_embed

import ./styled_row

type
  BarGlyphs* = object
    ## A thumb's glyph for each set of covered segments of a cell.
    segments*: int
      ## Sub-cell steps along the bar: 1, 2 or 8. Segment 0 is the cell's
      ## NEAR end — its top on a vertical bar, its left on a horizontal one.
    byMask*: seq[string]
      ## `byMask[m]`: the glyph when the thumb covers exactly the segments in
      ## bit set `m`. Entry 0 is unused (an uncovered cell is track).
    joined*: seq[string]
      ## The same while the TRACK is drawn, where one glyph can show the
      ## thumb's part and the track's (`╽`). Empty: as `byMask`.

  AxisLook* = object
    thumb*: BarGlyphs
    track*: string
      ## Aligned with the thumb: centred for a centred thumb, against the
      ## pane's edge for an edge-hugging one.

  ThicknessLook* = array[BarAxis, AxisLook]

  ThicknessLooks* = object
    rest*: ThicknessLook
    widened*: ThicknessLook
      ## Under the pointer and while held: one step wider from the edge.

  GlyphTier* = enum
    ## Which glyph set the table's column is drawn from.
    gtClassic = "classic"
      ## Block Elements and Box Drawing (Unicode 1.1).
    gtModern = "modern-unicode"
      ## ... and Symbols for Legacy Computing (Unicode 13), where they draw a
      ## step the classic blocks cannot.

const
  LowerEighths* = ["", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    ## `LowerEighths[k]`: the lower `k` eighths of a cell filled.
  LeftEighths* = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]
    ## `LeftEighths[k]`: the left `k` eighths of a cell filled.
  UpperEighthsClassic = ["", "▔", "▔", "▀", "▀", "▀", "█", "█", "█"]
    ## The upper `k` eighths at the precision Block Elements has: `▔` one
    ## eighth, `▀` a half.
  UpperEighthsModern* = ["", "▔", "🮂", "🮃", "▀", "🮄", "🮅", "🮆", "█"]
    ## ... and exactly, from Symbols for Legacy Computing (U+1FB82 – 1FB86).
  RightEighthsModern* = ["", "▕", "🮇", "🮈", "▐", "🮉", "🮊", "🮋", "█"]
    ## `RightEighthsModern[k]`: the right `k` eighths of a cell filled, which
    ## only Symbols for Legacy Computing (U+1FB87 – 1FB8B) has between `▕`
    ## and `▐`. The position sliders draw a thumb's start with it under
    ## `modern-unicode` (`scrubber_track.thumbCells`) instead of a reversed
    ## cell.

# ---------------------------------------------------------------------------
# Building the table
# ---------------------------------------------------------------------------

func whole(thumb: string): BarGlyphs =
  BarGlyphs(segments: 1, byMask: @["", thumb])

func halves(nearHalf, farHalf, full: string;
            joinedNear = ""; joinedFar = ""): BarGlyphs =
  ## Two segments per cell. `nearHalf` is a cell whose NEAR half (top / left)
  ## the thumb covers — where it ENDS part-way; `farHalf` one whose far half
  ## it covers — where it STARTS part-way.
  result = BarGlyphs(segments: 2, byMask: @["", nearHalf, farHalf, full])
  if joinedNear.len > 0:
    result.joined = @["", joinedNear, joinedFar, full]

func eighths(upper: array[9, string]): BarGlyphs =
  ## Eight segments down a cell: the thumb's top end (it covers the LOWER k
  ## eighths) is a lower-eighth block; its bottom end (the UPPER k eighths)
  ## is `upper[k]`.
  result = BarGlyphs(segments: 8, byMask: newSeq[string](256))
  for m in 1 ..< 256:
    var lo, hi = -1
    for s in 0 ..< 8:
      if (m and (1 shl s)) != 0:
        if lo < 0: lo = s
        hi = s
    let k = hi - lo + 1
    result.byMask[m] =
      if k >= 8: "█"
      elif hi == 7: LowerEighths[k]   # reaches the cell's bottom
      elif lo == 0: upper[k]          # reaches the cell's top
      else: "█"

func look(v, h: AxisLook): ThicknessLook = [v, h]

const
  EdgeV = "▕"
  EdgeH = "▁"

let
  QuarterV = AxisLook(thumb: halves("▝", "▗", "▐"), track: EdgeV)
    ## Thick: the right half, quadrant ends.
  QuarterH = AxisLook(thumb: halves("▖", "▗", "▄"), track: EdgeH)
    ## Thick and full across: the lower half, quadrant ends.
  FullClassicV = AxisLook(thumb: eighths(UpperEighthsClassic), track: EdgeV)
  FullModernV = AxisLook(thumb: eighths(UpperEighthsModern), track: EdgeV)

  ScrollbarGlyphs*: array[GlyphTier, array[BarThickness, ThicknessLooks]] = [
    gtClassic: [
      btHairline: ThicknessLooks(
        rest: look(AxisLook(thumb: whole("▕"), track: EdgeV),
                   AxisLook(thumb: whole("▁"), track: EdgeH)),
        widened: look(QuarterV, QuarterH)),
      btThin: ThicknessLooks(
        rest: look(AxisLook(thumb: halves("╹", "╻", "┃", "╿", "╽"),
                            track: "│"),
                   AxisLook(thumb: halves("╸", "╺", "━", "╾", "╼"),
                            track: "─")),
        widened: look(QuarterV, QuarterH)),
      btThick: ThicknessLooks(rest: look(QuarterV, QuarterH),
                              widened: look(FullClassicV, QuarterH)),
      btFull: ThicknessLooks(rest: look(FullClassicV, QuarterH),
                             widened: look(FullClassicV, QuarterH))],
    gtModern: [
      # Symbols for Legacy Computing (Unicode 13): `🮇` / `🮈` are the right
      # one quarter / three eighths, so `thin` and the hairline's widened
      # step hug the edge as `thick` does; the full thumb's bottom end is
      # exact to the eighth.
      btHairline: ThicknessLooks(
        rest: look(AxisLook(thumb: whole("▕"), track: EdgeV),
                   AxisLook(thumb: whole("▁"), track: EdgeH)),
        widened: look(AxisLook(thumb: whole("🮈"), track: EdgeV),
                      AxisLook(thumb: whole("▃"), track: EdgeH))),
      btThin: ThicknessLooks(
        rest: look(AxisLook(thumb: whole("🮇"), track: EdgeV),
                   AxisLook(thumb: whole("▂"), track: EdgeH)),
        widened: look(QuarterV, QuarterH)),
      btThick: ThicknessLooks(rest: look(QuarterV, QuarterH),
                              widened: look(FullModernV, QuarterH)),
      btFull: ThicknessLooks(rest: look(FullModernV, QuarterH),
                             widened: look(FullModernV, QuarterH))]]

func glyphTierOf*(o: ScrollbarOptions): GlyphTier =
  ## The column the options choose. (A capability profile will choose it
  ## from the terminal as well as from `modern-unicode`.)
  if o.modernUnicode: gtModern else: gtClassic

proc lookOf*(o: ScrollbarOptions; axis: BarAxis; state: BarState): AxisLook =
  ## The glyphs a bar draws in `state`.
  let t = ScrollbarGlyphs[o.glyphTierOf][o.thickness]
  if state.widened: t.widened[axis] else: t.rest[axis]

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------

func thumbRole*(o: ScrollbarOptions; state: BarState): SemanticRole =
  case state
  of bsHoverThumb: srScrollbarThumbHover
  of bsHeld: srScrollbarThumbHeld
  of bsIdle, bsHoverTrack:
    if o.thickness in {btThick, btFull}: srScrollbarThumbSolid
    else: srScrollbarThumb

func trackShown*(o: ScrollbarOptions; state: BarState): bool =
  o.track or state.trackRevealed

func trackRole*(state: BarState): SemanticRole =
  if state.trackRevealed: srScrollbarTrackRevealed else: srScrollbarTrack

func isScrollbarThumbRole*(role: SemanticRole): bool =
  role in {srScrollbarThumb, srScrollbarThumbSolid, srScrollbarThumbHover,
           srScrollbarThumbHeld}

func isScrollbarTrackRole*(role: SemanticRole): bool =
  role in {srScrollbarTrack, srScrollbarTrackRevealed}

# ---------------------------------------------------------------------------
# Projection and hit testing
# ---------------------------------------------------------------------------

const MinThumbEighths* = 8
  ## The shortest thumb a pointer can hit: one cell.

func spanOf*(m: ScrubberModel; cells: int): ThumbSpan =
  ## The thumb of model `m` on a bar of `cells` cells, in eighths.
  m.thumbSpan(cells * 8, MinThumbEighths)

func segmentMask*(span: ThumbSpan; cell, segments: int): int =
  ## Which of cell `cell`'s segments the thumb covers: a segment is covered
  ## when its centre (in eighths) lies inside the span.
  let segs = max(1, segments)
  for s in 0 ..< segs:
    let centre = float(cell * 8) + (float(s) + 0.5) * 8.0 / float(segs)
    if centre >= float(span.start) and
       centre < float(span.start + span.length):
      result = result or (1 shl s)

proc thumbCellRange*(o: ScrollbarOptions; axis: BarAxis; span: ThumbSpan;
                     cells: int): (int, int) =
  ## The first and last cell the thumb is drawn in AT REST — what a pointer
  ## must be over to hover or grab it. Widening under the pointer never
  ## moves this boundary. `(-1, -1)` for an empty bar.
  let segs = o.lookOf(axis, bsIdle).thumb.segments
  var first, last = -1
  for c in 0 ..< cells:
    if segmentMask(span, c, segs) != 0:
      if first < 0: first = c
      last = c
  (first, last)

proc onThumb*(o: ScrollbarOptions; bar: BarSpot; cell: int): bool =
  let (first, last) = o.thumbCellRange(bar.axis, bar.model.spanOf(bar.cells),
                                       bar.cells)
  cell >= first and cell <= last

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc paintCell(g: var StyledGrid; axis: BarAxis; origin, at: int;
               glyph: string; style: CellStyle) =
  if glyph.len == 0:
    return
  case axis
  of axVertical: g.paint(at, origin, glyph, style)
  of axHorizontal: g.paint(origin, at, glyph, style)

proc paintBar*(g: var StyledGrid; axis: BarAxis; origin, at, cells: int;
               model: ScrubberModel; markCell = -1) =
  ## One scrollbar of `cells` cells: a vertical bar down column `origin`
  ## from row `at`, or a horizontal one along row `origin` from column `at`,
  ## its thumb from `model`, the current-position mark in cell `markCell`
  ## (or none). Drawn as `g.scrollbars` says for the pane being painted, and
  ## recorded in `g.bars`.
  if cells <= 0:
    return
  let pane = g.painting
  g.bars.add BarSpot(pane: pane, axis: axis, origin: origin, at: at,
                     cells: cells, model: model)
  let frame = g.scrollbars
  let faded = frame.faded[pane]
  if faded >= 1.0:
    return
  let o = frame.options
  let state = frame.stateOf(pane, axis)
  let look = o.lookOf(axis, state)
  let span = model.spanOf(cells)
  let showTrack = o.trackShown(state)
  let glyphs = look.thumb
  let joins = showTrack and glyphs.joined.len > 0
  let trackStyle = CellStyle(role: trackRole(state), faded: faded)
  let thumbStyle = CellStyle(role: o.thumbRole(state), faded: faded)
  for c in 0 ..< cells:
    let mask = segmentMask(span, c, glyphs.segments)
    if mask == 0:
      if showTrack:
        g.paintCell(axis, origin, at + c, look.track, trackStyle)
    else:
      let glyph = if joins: glyphs.joined[mask] else: glyphs.byMask[mask]
      g.paintCell(axis, origin, at + c, glyph, thumbStyle)
  if markCell in 0 ..< cells:
    g.paintCell(axis, origin, at + markCell,
                o.lookOf(axis, bsIdle).thumb.byMask[^1],
                CellStyle(role: srScrubberMark, faded: faded))

# ---------------------------------------------------------------------------
# The position sliders' glyphs (not scrollbars, §1)
# ---------------------------------------------------------------------------

const
  TrackVerticalGlyph* = "│"
  TrackHorizontalGlyph* = "─"
  ThumbFullGlyph* = "█"
