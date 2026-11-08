## THE EDITOR GUTTER'S BAND MAP — which concern owns which strip of pixels.
##
## WHY THIS IS A MODULE AND NOT A COMMENT IN A STYLESHEET
## -----------------------------------------------------
## The gutter carries FOUR concerns that a pointer must be able to tell apart:
##
##   * the breakpoint and tracepoint marks, in the glyph lane at the far left
##     (VS Code's layout, Editor-Pane.md MC.5),
##   * the VCS change indicator,
##   * the line number,
##   * the run-test control.
##
## Three of them were placed by three different people at three different
## times, each reading `components/text_editor.styl` and adding an offset that
## looked free. That is how the breakpoint and the tracepoint came to share a
## hit area (`elementFromPoint` at the centre of the breakpoint dot returned
## the tracepoint), and it is how the VCS slot came to be `<div class="diff-
## line">` measuring **73 x 0 px** — a box spanning the WHOLE gutter, lying
## across the line number, the breakpoint and the tracepoint at once, with no
## height and therefore no hit area and no indicator.
##
## Measured on `cloud` 402c1d35, `/noir`, line 1, before this module existed:
##
##     gutter        left 293  right 366   width 73
##     .diff-line    left 293  right 366   width 73   HEIGHT 0
##     .gutter-line  left 306  right 335
##     breakpoint    left 336  right 345
##     tracepoint    left 347  right 357
##     overlaps      vcs/lineNumber 29px, vcs/breakpoint 9px, vcs/tracepoint 10px
##
## Nothing was wrong on screen, because a zero-height box paints nothing. The
## defect is that the strip had no room for the fourth concern and every check
## over it was green anyway.
##
## So the ORDER and the OWNERS live here, in one place, in a form a test can
## read — and `ci/test/web_renderer_probe.mjs` reads the PAINTED geometry back
## so the declaration below and the stylesheet can be compared to each other
## rather than each being believed on its own.
##
## WHAT THIS MODULE IS NOT. It does not generate CSS. The widths below are the
## same numbers `components/text_editor.styl` writes as custom properties, and
## keeping them in step is what `test_editor_gutter_lanes.nim` and the browser
## gate exist for. A generator would be the obvious improvement and is not
## worth the Stylus build step it would cost for six constants.
##
## ORDER OF THE BANDS, LEFT TO RIGHT, and this is the whole point of the file.
## `gbLineNumber` takes the remainder; everything else is a fixed width that is
## RESERVED on every line of every file. Reserved, because a band that appeared
## only on some lines would make the line numbers jitter as a reader scrolled —
## which is the one thing the run-test control is exempt from, and the reason
## it is an overlay of `gbPointer` rather than a band of its own.

import std/[algorithm, sequtils]

type
  GutterBand* = enum
    ## Left to right. The declaration order IS the layout order and
    ## `resolveBands` depends on it.
    gbGlyph = "glyph"
    gbPointer = "pointer"
    gbLineNumber = "line-number"
    gbVcs = "vcs"
    gbVcsSplit = "vcs-split"
    gbFolding = "folding"

  GutterConcern* = enum
    gcCurrentLineArrow = "current-line-arrow"
    gcRunTestControl = "run-test-control"
    gcLineNumber = "line-number"
    gcVcsChange = "vcs-change"
    gcBreakpoint = "breakpoint"
    gcTracepoint = "tracepoint"
    gcFoldingChevron = "folding-chevron"

  ResolvedBand* = object
    band*: GutterBand
    leftPx*: int
    rightPx*: int

const
  RemainderWidth* = -1
    ## `gbLineNumber`'s width: whatever the other bands leave.

proc widthEmMilli*(band: GutterBand): int =
  ## The band's width in THOUSANDTHS OF AN EM.
  ##
  ## Milli-em and not a float because this module is compiled on both the C and
  ## the JS backend and the two must agree to the pixel; integer arithmetic is
  ## the only way to say that without arguing about rounding.
  ##
  ## Each number is the custom property of the same name in
  ## `components/text_editor.styl`. They are asserted against the PAINTED boxes
  ## by `ci/test/web-renderer-mounts.sh`, so a change to one that is not made
  ## to the other reddens a gate rather than drifting quietly.
  case band
  # THE GLYPH MARGIN'S WIDTH IS MONACO'S: its `glyphMarginWidth` is the line
  # height, one lane, and Monaco's line height is `GOLDEN_LINE_HEIGHT_RATIO` em,
  # rounded (`widthPx`). GPUI draws the same box.
  of gbGlyph:
    when defined(macosx): 1500 else: 1350
  of gbPointer: 750       # --ct-gutter-pointer-lane:   0.75em
  of gbLineNumber: RemainderWidth
  of gbVcs: 350           # --ct-gutter-vcs-lane:       0.35em
  # Small, but it must not be zero: two hit areas that merely touch are one hit
  # area to a rounding error.
  of gbVcsSplit: 250      # --ct-gutter-vcs-split:      0.25em
  of gbFolding: 850       # --ct-gutter-folding-lane:   0.85em

proc owners*(band: GutterBand): seq[GutterConcern] =
  ## Which concerns paint in this band. A band with none is a SPACER and says
  ## so by returning an empty sequence rather than by a comment.
  ##
  ## `gbPointer` has two, and that is the one deliberate sharing in the strip:
  ## the current-line arrow is on exactly one line at a time and the run-test
  ## control on the handful carrying a `#[test]`, so reserving a sixth band for
  ## the control would cost its width on every line of every file in every
  ## language. When both want the band the control wins, and only while the row
  ## is hovered — see the stylesheet's `.gutter:hover` rules.
  case band
  of gbGlyph: @[gcBreakpoint, gcTracepoint]
  of gbPointer: @[gcCurrentLineArrow, gcRunTestControl]
  of gbLineNumber: @[gcLineNumber]
  of gbVcs: @[gcVcsChange]
  of gbVcsSplit: @[]
  of gbFolding: @[gcFoldingChevron]

proc isOurs*(band: GutterBand): bool =
  ## Whether CodeTracer's own markup lays this band out.
  ##
  ## `gbFolding` and `gbGlyph` are MONACO'S on the desktop (the glyph margin,
  ## with `glyphMargin: true`). `.gutter` subtracts its width from its own so the
  ## chevron is never underneath us, which is the arrangement the reported
  ## "clicking the gutter also collapses the function" would need broken to
  ## occur — and the reason `--ct-gutter-folding-lane: 0` is a mutation arm.
  band notin {gbFolding, gbGlyph}

proc bandFor*(concern: GutterConcern): GutterBand =
  ## The one band a concern paints in. Total by construction: adding a concern
  ## without giving it a band does not compile.
  case concern
  of gcCurrentLineArrow, gcRunTestControl: gbPointer
  of gcLineNumber: gbLineNumber
  of gcVcsChange: gbVcs
  of gcBreakpoint, gcTracepoint: gbGlyph
  of gcFoldingChevron: gbFolding

proc widthPx*(band: GutterBand; fontSizePx: int): int =
  ## The band's width at a given editor font size, or `RemainderWidth`.
  if band.widthEmMilli == RemainderWidth: RemainderWidth
  elif band == gbGlyph: (band.widthEmMilli * fontSizePx + 500) div 1000
  else: (band.widthEmMilli * fontSizePx) div 1000

proc lineDecorationsWidthPx*(fontSizePx: int): int =
  ## What Monaco must reserve to the RIGHT of the line-number column.
  ##
  ## THE VCS BAND IS IN HERE AND THAT IS THE POINT. Monaco sizes the margin as
  ## the line-number column plus this; the line-number column is sized
  ## separately by `lineNumbersMinChars`. So a band added to our markup without
  ## being added here does not widen the margin — it takes its width out of the
  ## line number, and the numbers start clipping in any file long enough to
  ## need the digits. The VCS band was the fourth concern this strip had to
  ## hold and it is the one that would have paid for it.
  ##
  ## The glyph lane is not in here: it is Monaco's own glyph margin, to the left
  ## of the numbers.
  let vcsLane = gbVcs.widthPx(fontSizePx) + gbVcsSplit.widthPx(fontSizePx)
  let foldingLane = fontSizePx div 2
  max(20, vcsLane + foldingLane)

proc resolveBands*(fontSizePx: int; totalWidthPx: int): seq[ResolvedBand] =
  ## Where every band lands, left to right, across `totalWidthPx`.
  ##
  ## Returned as pixel EDGES rather than as widths because the property worth
  ## asserting is that no two bands overlap, and that is a statement about
  ## edges. A caller comparing widths can add them up and be wrong about the
  ## order at the same time.
  ##
  ## `gbLineNumber` absorbs what is left, and may come out at zero or negative
  ## width if the caller passes a `totalWidthPx` too small to hold the fixed
  ## bands. That is reported rather than clamped: a gutter too narrow for its
  ## own bands is a fact the caller needs, and silently flooring it at zero is
  ## how a clipped line number becomes invisible to a test.
  var fixed = 0
  for band in GutterBand:
    let w = band.widthPx(fontSizePx)
    if w != RemainderWidth:
      fixed += w
  var x = 0
  for band in GutterBand:
    let w = band.widthPx(fontSizePx)
    let width = if w == RemainderWidth: totalWidthPx - fixed else: w
    result.add ResolvedBand(band: band, leftPx: x, rightPx: x + width)
    x += width

type
  GutterZone* = enum
    ## Editor-Pane.md MC.5: what a position in the gutter means. Every pixel
    ## of a zone acts alike, and the boundary between the two zones is the
    ## glyph column's right edge on every front-end.
    gzGlyph = "glyph"
    gzLineNumber = "line-number"
    gzControl = "control"
      ## Named controls that are neither zone: the VCS lane, the fold chevron
      ## and the run-test control.
    gzNone = "none"

  GutterGeometry* = object
    ## A front-end's gutter, in its own unit (cells or pixels), from its left
    ## edge.
    glyphRight*: int
    totalWidth*: int
    controls*: seq[tuple[left, right: int]]

func terminalGutterGeometry*(gutterCells, markCells: int): GutterGeometry =
  ## The terminal's: the mark cell, then every other cell the line numbers.
  GutterGeometry(glyphRight: markCells, totalWidth: gutterCells)

func windowGutterGeometry*(fontSizePx, totalWidthPx: int;
                           runTestControl = false): GutterGeometry =
  ## GPUI's and the desktop's, from the band map. The run-test control, on a
  ## line that declares a test, lies over the pointer band.
  result.totalWidth = totalWidthPx
  for b in resolveBands(fontSizePx, totalWidthPx):
    case b.band
    of gbGlyph: result.glyphRight = b.rightPx
    of gbVcs, gbVcsSplit, gbFolding:
      result.controls.add (b.leftPx, b.rightPx)
    of gbPointer:
      if runTestControl:
        result.controls.add (b.leftPx, b.rightPx)
    of gbLineNumber: discard

func gutterZoneAt*(g: GutterGeometry; x: int): GutterZone =
  ## The one answer to "which zone is `x` in"; no view decides this itself.
  if x < 0 or x >= g.totalWidth:
    return gzNone
  if x < g.glyphRight:
    return gzGlyph
  for c in g.controls:
    if x >= c.left and x < c.right:
      return gzControl
  gzLineNumber

proc overlappingBands*(resolved: seq[ResolvedBand]):
    seq[tuple[a, b: GutterBand, px: int]] =
  ## Every pair of bands that shares a pixel.
  ##
  ## Zero-width bands are skipped, because a band with no width overlaps
  ## nothing and reporting it as touching its neighbours would drown the real
  ## answer. Bands that merely ABUT are not an overlap: `[0,10)` and `[10,20)`
  ## share no pixel.
  for i in 0 ..< resolved.len:
    for j in i + 1 ..< resolved.len:
      let a = resolved[i]
      let b = resolved[j]
      if a.rightPx <= a.leftPx or b.rightPx <= b.leftPx:
        continue
      let ov = min(a.rightPx, b.rightPx) - max(a.leftPx, b.leftPx)
      if ov > 0:
        result.add (a: a.band, b: b.band, px: ov)

proc concernsInOrder*(): seq[GutterConcern] =
  ## Every concern, ordered by the band it paints in, left to right.
  ##
  ## This is the sentence the user's report turns into: breakpoints and
  ## tracepoints, VCS change indicators, line numbers and the run-test control
  ## must each have somewhere of their own to be. A concern that shares a band
  ## is still listed once; `owners` is where the sharing is stated.
  var withBand: seq[(int, GutterConcern)] = @[]
  for concern in GutterConcern:
    withBand.add (ord(concern.bandFor), concern)
  withBand.sort proc(x, y: (int, GutterConcern)): int =
    result = cmp(x[0], y[0])
    if result == 0:
      result = cmp(ord(x[1]), ord(y[1]))
  withBand.mapIt(it[1])
