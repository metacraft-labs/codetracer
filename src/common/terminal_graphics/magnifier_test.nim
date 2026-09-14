## magnifier_test.nim — PLAT-15's VERIFICATION GATE.
##
## The milestone states one gate and this file is it:
##
##   *"A picked pixel's coordinate is exact at every tier, asserted against the
##   source image."*
##
## ## WHAT "EXACT" IS ASSERTED AS, AND IN WHICH UNIT
##
## Four quantities are in play (see `magnifier.nim`'s header), and every
## assertion below names which one it is about:
##
##   * **source pixels** — `Magnifier.cursorX/cursorY`, `PixelRect`,
##     `sourcePixelOfCell`. The gate is an EQUALITY in this unit.
##   * **terminal cells** — `magnifiedCols/Rows`, `zoomCols/zoomRows`,
##     `CellGrid.cols/rows`.
##   * **sub-cell samples** — `tiers.subCell`, which is what makes a cell NOT a
##     pixel and is the whole reason §5 exists.
##   * **candidate masks evaluated** — `CellGrid.candidatesEvaluated`, the only
##     WORK quantity this package claims, asserted as an equality because it is
##     identical on every build and memory manager. **No timing is asserted
##     anywhere in this file** (Verification-Harness-Traps §12b): PLAT-13's
##     landing pass recorded a 66.9 s headline that was an ORC measurement of a
##     defect no shipped binary ever had, and an elapsed time would have to
##     quote its build.
##
## The gate is asserted THREE ways over the same fixture, because a coordinate
## that is right in the model and wrong on the screen is the failure a
## coordinate-only assertion cannot see:
##
##   1. `sourcePixelOfCell` answers the pixel — a claim about the MODEL.
##   2. `renderMagnifier` — the PRODUCT'S OWN `cell_render.renderCells`, not a
##      second renderer — paints that cell in exactly that pixel's colour,
##      where the colour is recomputed from the FIXTURE'S OWN FORMULA in this
##      file rather than read back out of the raster the renderer was handed.
##      PLAT-14 established that rule for its Tier-2 decode and it is the same
##      rule here: compare the implementation with the standard, never with
##      itself.
##   3. The round trip `sourcePixelOfCell(cursorCell(mag)) == pickedPixel(mag)`
##      — so the cell the cursor is DRAWN at and the pixel the cursor REPORTS
##      cannot drift apart.
##
## ## THE NEGATIVE CONTROL IS FALSIFIED (§7a)
##
## "A cell does not address a pixel" is a negation, and a negation nothing can
## satisfy is a self-comparison. So `pixelCount(coarsePixelRect(...))` is shown
## to be **> 1** on a fit that down-samples AND **== 1** on a fit that does
## not, through the same function — which is also what falsifies §5's own
## sentence about tier 0 (see `magnifier.nim`'s header correction).
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is none, and nothing stands in for anything. `initRgbaImage` is the
## product's own constructor, `renderCells` is the product's own renderer, and
## the rasters are built in code rather than read from a PNG for
## `cell_render_test.nim`'s reason: this build has no PNG decoder, so reading
## one would mean adding a dependency in order to test a function that does not
## use it. A constructed raster is the same type, through the same door, as a
## framebuffer `ct-gfx-player` hands back.
##
## ## COUNTED ASSERTIONS (§4c) AND TEMPLATES, NEVER PROCS (§13)
##
## Every assertion goes through `ck`/`ckEq`, which are TEMPLATES: a `check`
## inside a plain `proc` assigns a module global and the case still prints
## `[OK]`. The last case asserts the tally against a number written from a run.

import std/[strutils, unittest]

import ../terminal_graphics

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const ExpectedAssertions = 4671
  ## Written from a run. See the final case.

# ---------------------------------------------------------------------------
# The fixture, and its formula
# ---------------------------------------------------------------------------

const
  FixtureWidth = 24
  FixtureHeight = 16

func expectedChannel(x, y: int): Rgb =
  ## THE FIXTURE'S FORMULA, evaluated in the test file.
  ##
  ## Every pixel of the fixture is a DIFFERENT colour — which is what makes
  ## "the magnifier shows pixel (x, y)" falsifiable at all. A fixture with a
  ## repeated colour would let an off-by-one in either axis produce the right
  ## bytes for the wrong reason.
  ##
  ## `3 * x` and `11 * y` are coprime multipliers inside 0..255 over the
  ## fixture's extent, so no two pixels share a `(r, g)` pair: `3x1 + 11y1 ==
  ## 3x2 + 11y2` with `|dx| < 24` and `|dy| < 16` forces `dx == dy == 0`.
  Rgb(r: uint8(17 + 3 * x), g: uint8(9 + 11 * y),
      b: uint8(40 + ((x * 7 + y * 5) mod 90)))

proc fixture(): RgbaImage =
  var px = newSeq[byte](FixtureWidth * FixtureHeight * 4)
  for y in 0 ..< FixtureHeight:
    for x in 0 ..< FixtureWidth:
      let c = expectedChannel(x, y)
      let i = (y * FixtureWidth + x) * 4
      px[i] = c.r
      px[i + 1] = c.g
      px[i + 2] = c.b
      px[i + 3] = 255'u8
  initRgbaImage(FixtureWidth, FixtureHeight, px)

const
  GateTiers = [itHalfBlock, itQuadrant, itSextant, itBraille, itAscii,
               itProtocol]
    ## EVERY tier of `tiers.CellRenderableTiers`, plus `itProtocol`.
    ##
    ## Tier 0 is in the sweep rather than excluded from it, and that is the
    ## point: `magnifierTier` answers `itHalfBlock` for it, so the gate's
    ## sentence "exact at every tier" covers the tier a reader would assume it
    ## does not apply to. `itOctant` is absent because it is in NEITHER set —
    ## it has no glyph table at all — and it has a refusal case of its own
    ## below, with a renderable tier beside it as the positive twin.

  GateTierCount = 6

# ---------------------------------------------------------------------------
# §5's first stage: a cell is not a pixel
# ---------------------------------------------------------------------------

suite "PLAT-15 §5: a cell does not address a pixel":

  test "one frame cell covers MORE THAN ONE source pixel, at every tier":
    # THE NEGATIVE, WITH ITS POSITIVE TWIN THROUGH THE SAME FUNCTION (§7a).
    # `pixelCount` is asked for a number > 1 here and for exactly 1 in the next
    # case, so "a cell is not a pixel" is a measurement rather than a sentence.
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 6, 6)
    checkpoint("fit: " & describeAspect(fit))
    var tiersChecked = 0
    for tier in GateTiers:
      let r = coarsePixelRect(FixtureWidth, FixtureHeight, fit, tier, 0, 0)
      checkpoint($tier & " cell (0,0) covers " & $r.width & "x" & $r.height &
                 " source pixels")
      ck pixelCount(r) > 1
      # AND THE RECTANGLE IS INSIDE THE IMAGE.
      ck r.x >= 0
      ck r.y >= 0
      ck r.x + r.width <= FixtureWidth
      ck r.y + r.height <= FixtureHeight
      inc tiersChecked
    ckEq tiersChecked, GateTierCount

  test "a 1:1 fit DOES address a pixel — §5's own sentence, falsified":
    # §5 says a cell is one pixel "only at tier 0". MEASURED: a cell is one
    # pixel exactly when the FIT is 1:1, and that is a property of the
    # rectangle, not of the tier.
    #
    # A 24x16 source into a 24x16 cell grid is 1:1, and the coarse rectangle is
    # then a single pixel AT EVERY TIER — including tier 1, whose two sub-cell
    # samples both land inside that one pixel. So "tier 0" is neither
    # sufficient (the next case) nor necessary (this one) for a cell to address
    # a pixel.
    let oneToOne = CellFit(cols: FixtureWidth, rows: FixtureHeight,
                           aspect: DefaultCellAspect,
                           sourceWidth: FixtureWidth,
                           sourceHeight: FixtureHeight, corrected: false)
    let r = coarsePixelRect(FixtureWidth, FixtureHeight, oneToOne, itProtocol,
                            5, 3)
    ckEq pixelCount(r), 1
    ckEq r.x, 5
    ckEq r.y, 3
    var oneEverywhere = 0
    for tier in GateTiers:
      ckEq pixelCount(coarsePixelRect(FixtureWidth, FixtureHeight, oneToOne,
                                      tier, 5, 3)), 1
      inc oneEverywhere
    ckEq oneEverywhere, GateTierCount
    # THE SUB-CELL COUNT IS STILL TWO. What tier 1 buys is two SAMPLES inside
    # that one pixel, not two pixels — which is the distinction §5's sentence
    # collapses and the reason the correction in `magnifier.nim`'s header
    # reads the way it does.
    ckEq subCellCount(itHalfBlock), 2
    ckEq subCellCount(itOctant), 8

  test "the cell's FOOTPRINT is the fit's, and is the same at every tier":
    # The other half of the correction, as an EQUALITY across tiers. A cell's
    # footprint in SOURCE PIXELS is `source / fit`, whatever the tier packs
    # inside it — the same statement `aspect.nim` makes about the fit itself
    # ("a fit that folded the sub-cell geometry in would stretch braille by 2
    # relative to half blocks"), one level down.
    #
    # THIS IS WHY TIER 0 NEEDS THE MAGNIFIER TOO. On a fit that down-samples,
    # the tier-0 cell covers exactly as many pixels as the braille one.
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 12, 12)
    checkpoint("down-sampling fit: " & describeAspect(fit))
    ckEq fit.cols, 12
    ckEq fit.rows, 4
    let reference = coarsePixelRect(FixtureWidth, FixtureHeight, fit,
                                    itProtocol, 5, 2)
    # The numbers, written out rather than compared with the function's own
    # answer: 24 source columns over 12 cells is 2, 16 source rows over 4 cells
    # is 4, so one cell is EIGHT source pixels — at tier 0.
    ckEq reference.x, 10
    ckEq reference.y, 8
    ckEq reference.width, 2
    ckEq reference.height, 4
    ckEq pixelCount(reference), 8
    var agreed = 0
    for tier in GateTiers:
      ckEq coarsePixelRect(FixtureWidth, FixtureHeight, fit, tier, 5, 2),
           reference
      inc agreed
    ckEq agreed, GateTierCount

  test "the coarse rectangle is the RENDERER's own sampling, not a copy":
    # Verification-Harness-Traps §14: one predicate, and both callers reach it.
    # The union of the sub-cell rectangles `cell_render` samples IS the coarse
    # rectangle, asserted here rather than assumed, over every cell of a real
    # fit at the two tiers with the most and the fewest sub-cells.
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 8, 8)
    var cellsChecked = 0
    for tier in [itHalfBlock, itBraille]:
      let geom = subCell(tier)
      for row in 0 ..< fit.rows:
        for col in 0 ..< fit.cols:
          let coarse = coarsePixelRect(FixtureWidth, FixtureHeight, fit, tier,
                                       col, row)
          var lo = sourceRectOfSubCell(FixtureWidth, FixtureHeight, fit, tier,
                                       col * geom.cols, row * geom.rows)
          var hiX = 0
          var hiY = 0
          for sy in 0 ..< geom.rows:
            for sx in 0 ..< geom.cols:
              let sub = sourceRectOfSubCell(
                FixtureWidth, FixtureHeight, fit, tier,
                col * geom.cols + sx, row * geom.rows + sy)
              lo.x = min(lo.x, sub.x)
              lo.y = min(lo.y, sub.y)
              hiX = max(hiX, sub.x + sub.width)
              hiY = max(hiY, sub.y + sub.height)
          ckEq coarse.x, lo.x
          ckEq coarse.y, lo.y
          ckEq coarse.width, hiX - lo.x
          ckEq coarse.height, hiY - lo.y
          inc cellsChecked
    checkpoint("cells compared against the renderer's sampling: " &
               $cellsChecked)
    ck cellsChecked > 0

  test "a cell outside the frame is refused, not clamped to an edge pixel":
    # A clamp here would hand `pixel_history_vm` the coordinate of a pixel the
    # user did not point at, which is the guess §5 forbids wearing a defensive
    # coding style.
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 6, 6)
    var refused = 0
    for (c, r) in [(-1, 0), (0, -1), (fit.cols, 0), (0, fit.rows)]:
      try:
        discard coarsePixelRect(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                                c, r)
      except MagnifierError as e:
        ck e.msg.contains("outside the frame")
        inc refused
    ckEq refused, 4
    # THE POSITIVE TWIN: an IN-range cell through the same function answers.
    ck pixelCount(coarsePixelRect(FixtureWidth, FixtureHeight, fit,
                                  itHalfBlock, fit.cols - 1, fit.rows - 1)) >= 1

# ---------------------------------------------------------------------------
# §2.4's correction, applied to the magnifier
# ---------------------------------------------------------------------------

suite "PLAT-15 §5: one source pixel is one or more WHOLE cells":

  test "the zoom is at least one cell per pixel, in both axes, always":
    var checked = 0
    for rows in [1, 2, 3, 7]:
      for a in [DefaultCellAspect, initCellAspect(1, 1),
                initCellAspect(2, 3), initCellAspect(9, 20)]:
        let (zc, zr) = cellsPerSourcePixel(rows, a)
        ck zc >= 1
        ck zr >= 1
        ckEq zr, rows
        inc checked
    ckEq checked, 16

  test "a square cell needs no correction and a 1:2 cell needs a 2x one":
    # §2.4's correction, in the magnifier's own unit. The DEFAULT cell is
    # 1 wide by 2 tall, so a square source pixel is 2 cells wide and 1 tall;
    # a square cell is 1 and 1. The identity case and the corrected case, side
    # by side, so "corrected" is distinguishable from "this function stopped
    # correcting" (§7a).
    ckEq cellsPerSourcePixel(1, DefaultCellAspect), (2, 1)
    ckEq cellsPerSourcePixel(1, initCellAspect(1, 1)), (1, 1)
    ckEq cellsPerSourcePixel(2, DefaultCellAspect), (4, 2)
    # A 2:3 cell rounds HALF-UP to 2 rather than truncating to 1: truncation
    # would put the picture back at 2/3 width on every non-integer ratio.
    ckEq cellsPerSourcePixel(1, initCellAspect(2, 3)), (2, 1)

  test "the fit reports the correction, so a title can say it":
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 8, 8)
    let mag = openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                            2, 2, viewCols = 16, viewRows = 8)
    ck mag.magnifiedFit(itHalfBlock).corrected
    ckEq mag.magnifiedFit(itHalfBlock).aspect, DefaultCellAspect
    let square = fitToCells(FixtureWidth, FixtureHeight, initCellAspect(1, 1),
                            8, 8)
    let magSquare = openMagnifier(FixtureWidth, FixtureHeight, square,
                                  itHalfBlock, 2, 2,
                                  viewCols = 16, viewRows = 8)
    ck not magSquare.magnifiedFit(itHalfBlock).corrected

# ---------------------------------------------------------------------------
# THE GATE
# ---------------------------------------------------------------------------

suite "PLAT-15 gate: a picked pixel's coordinate is exact at every tier":

  test "every magnifier cell shows the pixel it names, through the renderer":
    # THE MILESTONE'S VERIFICATION GATE, swept rather than sampled.
    #
    # For every tier, for every cell of the magnified overlay: the model says
    # which SOURCE PIXEL the cell shows, and the grid the PRODUCT'S OWN
    # renderer produced carries that pixel's colour — recomputed here from
    # `expectedChannel`, the fixture's formula, and never read back out of the
    # raster the renderer was handed.
    let img = fixture()
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    checkpoint("frame fit: " & describeAspect(fit))
    var tiersSwept = 0
    var cellsAsserted = 0
    for tier in GateTiers:
      let mag = openMagnifier(FixtureWidth, FixtureHeight, fit, tier,
                              col = 3, row = 2,
                              viewCols = 12, viewRows = 6)
      let effective = magnifierTier(tier)
      let grid = renderMagnifier(img, mag, tier)
      checkpoint($tier & " -> overlay tier " & $effective & ": " &
                 describeMagnifier(mag))
      # THE OVERLAY'S EXTENT IS IN CELLS AND THE GRID AGREES WITH THE MODEL.
      ckEq grid.cols, mag.magnifiedCols()
      ckEq grid.rows, mag.magnifiedRows()
      ckEq grid.tier, effective
      # THE WORK BOUND, as an equality in the one unit this package counts.
      ckEq grid.candidatesEvaluated,
           grid.cols * grid.rows * candidatesPerCell(effective)
      for row in 0 ..< grid.rows:
        for col in 0 ..< grid.cols:
          let (px, py) = mag.sourcePixelOfCell(col, row)
          let want = expectedChannel(px, py)
          let cell = grid.cellAt(col, row)
          # THE COORDINATE IS INSIDE THE IMAGE, in SOURCE PIXELS.
          ck px >= 0 and px < FixtureWidth
          ck py >= 0 and py < FixtureHeight
          # THE COLOUR IS THAT PIXEL'S, EXACTLY. A cell of the overlay lies
          # wholly inside one source pixel's block, so every sub-cell sample is
          # the same colour, every candidate mask has zero error, and the
          # argmin's tie-break picks mask 0 — whose fg and bg are both that
          # colour. This is an EQUALITY and not a perceptual threshold, which
          # is the difference between a magnifier and a picture.
          ckEq cell.fg, want
          if effective != itAscii:
            # §2.5's ramp puts the picture in the GLYPH and leaves `bg` at the
            # zero `Rgb` — "no opinion", not black. Asserting a background
            # there would be asserting the defect PLAT-14's M32 removed.
            ckEq cell.bg, want
          ckEq cell.errorSq, 0.0
          inc cellsAsserted
      inc tiersSwept
    checkpoint("tiers swept: " & $tiersSwept & "; magnifier cells asserted: " &
               $cellsAsserted)
    ckEq tiersSwept, GateTierCount
    # THE NON-VACUITY FLOOR (§4b): a sweep over zero cells passes every
    # assertion inside it.
    ck cellsAsserted > 200

  test "the magnifier OPENS inside the cell it was opened at, at every tier":
    # §5'S TWO STAGES, JOINED — and the join is what nothing here asserted.
    #
    # The coarse stage says which SOURCE PIXELS a cell covers
    # (`coarsePixelRect`) and the magnified stage starts a pixel cursor
    # somewhere (`openMagnifier`). Every case above asserts one stage or the
    # other. None of them asserts that the cursor lands in the rectangle the
    # user actually pointed at, so `cursorX: 0, cursorY: 0` — a magnifier that
    # opens at the top-left of the image whichever cell was clicked — passed the
    # whole suite: the window follows the cursor, the round trip still closes,
    # and every colour in the gate is still the colour of the pixel the model
    # names. It is simply a DIFFERENT pixel from the one that was picked, which
    # is §5's guess arriving through the opening rather than through an
    # inference.
    #
    # Swept over EVERY (tier, cell) pair of a real fit rather than sampled: the
    # interesting cells are the last column and the last row, where the
    # division's remainder lives, and a spot check picks the middle.
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    checkpoint("fit: " & describeAspect(fit))
    var pairs = 0
    for tier in GateTiers:
      for row in 0 ..< fit.rows:
        for col in 0 ..< fit.cols:
          let coarse = coarsePixelRect(FixtureWidth, FixtureHeight, fit, tier,
                                       col, row)
          let mag = openMagnifier(FixtureWidth, FixtureHeight, fit, tier,
                                  col, row, viewCols = 12, viewRows = 6)
          # THE CURSOR IS IN THE CELL'S OWN FOOTPRINT, in SOURCE PIXELS.
          ck coarse.containsPixel(mag.cursorX, mag.cursorY)
          # …AND VISIBLE, so the pixel it names can be checked against a screen.
          ck mag.window.containsPixel(mag.cursorX, mag.cursorY)
          inc pairs
    checkpoint("(tier, cell) pairs swept: " & $pairs)
    ckEq pairs, GateTierCount * fit.cols * fit.rows
    ck pairs > 0
    # THE NEGATIVE, THROUGH THE SAME FUNCTION (§7a): on a fit that down-samples,
    # a NEIGHBOURING cell's footprint does NOT contain this cell's opening
    # cursor — so "inside" is a measurement and not a rectangle big enough to
    # hold anything. Asserted in both axes, because an off-by-one in one of them
    # is exactly what the sweep above is for.
    let here = openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                             2, 1, viewCols = 12, viewRows = 6)
    ck coarsePixelRect(FixtureWidth, FixtureHeight, fit, itHalfBlock, 2, 1)
         .containsPixel(here.cursorX, here.cursorY)
    ck not coarsePixelRect(FixtureWidth, FixtureHeight, fit, itHalfBlock, 3, 1)
             .containsPixel(here.cursorX, here.cursorY)
    ck not coarsePixelRect(FixtureWidth, FixtureHeight, fit, itHalfBlock, 2, 2)
             .containsPixel(here.cursorX, here.cursorY)

  test "the cursor's cell and the cursor's pixel are the same fact":
    # The round trip, so the cell the cursor is DRAWN at and the coordinate it
    # REPORTS cannot drift. Swept over every pixel of the fixture, because the
    # interesting cases are the window's edges and a spot check picks the
    # middle.
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    var mag = openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                            0, 0, viewCols = 12, viewRows = 6)
    var visited = 0
    for y in 0 ..< FixtureHeight:
      for x in 0 ..< FixtureWidth:
        mag = mag.moveCursor(x - mag.cursorX, y - mag.cursorY)
        ckEq mag.pickedPixel(), (x, y)
        let (cc, cr) = mag.cursorCell()
        ckEq mag.sourcePixelOfCell(cc, cr), (x, y)
        # AND THE CURSOR IS ON SCREEN: a coordinate the user cannot see is a
        # coordinate they cannot check.
        ck cc >= 0 and cc < mag.magnifiedCols()
        ck cr >= 0 and cr < mag.magnifiedRows()
        inc visited
    ckEq visited, FixtureWidth * FixtureHeight

  test "the cursor reaches every pixel and never leaves the image":
    # Clamped to the IMAGE, not to the window — a cursor clamped to the window
    # would make the edge pixels of a large frame unpickable.
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    var mag = openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                            2, 2, viewCols = 12, viewRows = 6)
    mag = mag.moveCursor(-1000, -1000)
    ckEq mag.pickedPixel(), (0, 0)
    ck mag.window.x == 0
    ck mag.window.y == 0
    mag = mag.moveCursor(1000, 1000)
    ckEq mag.pickedPixel(), (FixtureWidth - 1, FixtureHeight - 1)
    ck mag.window.x + mag.window.width == FixtureWidth
    ck mag.window.y + mag.window.height == FixtureHeight
    # THE WINDOW ALWAYS CONTAINS THE CURSOR, swept over a walk that crosses
    # both edges twice.
    var steps = 0
    for dx in [-3, 5, -9, 40, -40, 7, 7, 7]:
      for dy in [2, -5, 11, -30, 30]:
        mag = mag.moveCursor(dx, dy)
        ck mag.window.containsPixel(mag.cursorX, mag.cursorY)
        ck mag.window.x >= 0
        ck mag.window.y >= 0
        ck mag.window.x + mag.window.width <= FixtureWidth
        ck mag.window.y + mag.window.height <= FixtureHeight
        inc steps
    ckEq steps, 40

  test "a magnifier smaller than one pixel still shows one whole pixel":
    # §5's "one or more WHOLE cells" at the degenerate end. A 1x1-cell overlay
    # cannot show a 2x1-cell pixel, and the answer is a window of one pixel
    # drawn at the zoom it was asked for — never a fractional cell, which would
    # put two pixels in one cell and put the guess back.
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    let mag = openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                            4, 2, viewCols = 1, viewRows = 1)
    ckEq mag.window.width, 1
    ckEq mag.window.height, 1
    ckEq mag.magnifiedCols(), mag.zoomCols
    ckEq mag.magnifiedRows(), mag.zoomRows
    ckEq mag.sourcePixelOfCell(0, 0), mag.pickedPixel()

  test "a magnifier cell outside the overlay is refused":
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    let mag = openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                            4, 2, viewCols = 8, viewRows = 4)
    var refused = 0
    for (c, r) in [(-1, 0), (0, -1), (mag.magnifiedCols(), 0),
                   (0, mag.magnifiedRows())]:
      try:
        discard mag.sourcePixelOfCell(c, r)
      except MagnifierError as e:
        ck e.msg.contains("outside a")
        inc refused
    ckEq refused, 4
    # THE POSITIVE TWIN through the same function.
    ckEq mag.sourcePixelOfCell(0, 0),
         (mag.window.x, mag.window.y)

# ---------------------------------------------------------------------------
# §2.6: where a tier cannot show it, the pane says so
# ---------------------------------------------------------------------------

suite "PLAT-15 §2.6: a tier that cannot draw REFUSES by name":

  test "octants refuse a magnifier, and a sextant magnifier is the twin":
    # PLAT-14 recorded this as residue 3: `--image-tier=octant` parses and
    # resolves, and refuses only at DRAW time, where a pane meets a
    # `CellRenderError` rather than a refusal it can report. The refusal is
    # named here so a caller can ask BEFORE it paints.
    let img = fixture()
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    let mag = openMagnifier(FixtureWidth, FixtureHeight, fit, itOctant,
                            3, 2, viewCols = 8, viewRows = 4)
    var raised = false
    try:
      discard renderMagnifier(img, mag, itOctant)
    except MagnifierError as e:
      raised = true
      checkpoint(e.msg)
      ck e.msg.contains("octant")
      ck e.msg.contains("--image-tier=sextant")
      ck e.msg.contains("--image-tier=braille")
    ck raised
    # THE POSITIVE TWIN, through the same function: the remedy the message
    # names actually draws.
    let sextant = openMagnifier(FixtureWidth, FixtureHeight, fit, itSextant,
                                3, 2, viewCols = 8, viewRows = 4)
    let grid = renderMagnifier(img, sextant, itSextant)
    ckEq grid.tier, itSextant
    ck grid.cells.len > 0
    # AND THE TIER IS NOT SUBSTITUTED ON THE WAY IN: `magnifierTier` answers
    # `itOctant` for `itOctant`, so a pane that pins it reports the tier it
    # pinned rather than a neighbouring one (§4's "declares its tier").
    ckEq magnifierTier(itOctant), itOctant

  test "tier 0 magnifies at tier 1, and says so":
    # `magnifierTier`'s one substitution, with its reason in the module header.
    ckEq magnifierTier(itProtocol), itHalfBlock
    for tier in [itHalfBlock, itQuadrant, itSextant, itOctant, itBraille,
                 itAscii]:
      ckEq magnifierTier(tier), tier

  test "a magnifier over an empty raster is refused rather than sized to zero":
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    var refused = 0
    try:
      discard openMagnifier(0, 0, fit, itHalfBlock, 0, 0, 8, 4)
    except MagnifierError as e:
      ck e.msg.contains("positive extent")
      inc refused
    try:
      discard openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                            0, 0, 0, 4)
    except MagnifierError as e:
      ck e.msg.contains("rectangle to draw in")
      inc refused
    ckEq refused, 2

# ---------------------------------------------------------------------------
# The magnified raster itself
# ---------------------------------------------------------------------------

suite "PLAT-15: the blow-up is nearest-neighbour and introduces no colour":

  test "every magnified pixel is a colour the source has":
    # §2.5's "a correct picture, not a good one", applied to magnification: an
    # interpolating blow-up would put a colour on screen that no pixel of the
    # recording carries, and a user picking a pixel by eye would be picking a
    # colour the program never drew.
    let img = fixture()
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    let mag = openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                            4, 2, viewCols = 10, viewRows = 5)
    let blown = magnifiedRaster(img, mag, itHalfBlock)
    let geom = subCell(itHalfBlock)
    ckEq blown.width, mag.magnifiedCols() * geom.cols
    ckEq blown.height, mag.magnifiedRows() * geom.rows
    var sampled = 0
    for my in 0 ..< blown.height:
      for mx in 0 ..< blown.width:
        let sx = mag.window.x + mx div (mag.zoomCols * geom.cols)
        let sy = mag.window.y + my div (mag.zoomRows * geom.rows)
        ckEq blown.pixelAt(mx, my), expectedChannel(sx, sy)
        inc sampled
    ck sampled > 0

  test "the description names every unit it reports":
    let fit = fitToCells(FixtureWidth, FixtureHeight, DefaultCellAspect, 10, 10)
    let mag = openMagnifier(FixtureWidth, FixtureHeight, fit, itHalfBlock,
                            4, 2, viewCols = 10, viewRows = 5)
    let text = describeMagnifier(mag)
    checkpoint(text)
    ck text.contains("pixel=" & $mag.cursorX & "," & $mag.cursorY)
    ck text.contains("cells/px")
    ck text.contains("cells")
    ck text.contains($FixtureWidth & "x" & $FixtureHeight)

suite "PLAT-15: the tally":

  test "every assertion in this file ran":
    # Verification-Harness-Traps §4c. A branch that returned early, a loop that
    # skipped a member or a `continue` that dropped a case cannot reach this
    # line with the right count.
    echo "CHECKS: " & $countedAssertions
    ckEq countedAssertions, ExpectedAssertions
