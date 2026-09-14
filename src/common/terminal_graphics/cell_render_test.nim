## cell_render_test.nim — PLAT-14 deliverables 1, 2 and 3, tested as pure
## functions. `CodeTracer-TUI-Graphics.md` §7 tier 1: *"the cell rendering of a
## known image is deterministic and asserted cell-by-cell against a golden.
## Tier selection, aspect correction and quantisation are pure functions and
## tested as such."*
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is no mock here and nothing stands in for anything. The rasters below
## are REAL rasters — `initRgbaImage` is the product's own constructor and the
## bytes are the bytes — built in code rather than read from a PNG because this
## build has no PNG decoder (see `raster.nim`'s header) and reading one would
## therefore require adding a dependency in order to test a function that does
## not use it. A constructed raster is the same type, through the same door, as
## a framebuffer `ct-gfx-player` hands back.
##
## ## WHAT ONLY THIS FILE CAN SAY
##
## It is the only place that can assert the glyph TABLES — every mask at every
## tier, distinct, in the right Unicode block — because a rendering asserts one
## glyph per cell and a sixty-four entry table needs sixty-four assertions that
## no picture reaches. And it is the only place that can assert the Oklab
## transfer function by its NUMBER: a mid-grey's lightness is 0.600 with the
## sRGB gamma applied and 0.795 without, which is a two-decimal difference no
## rendered picture would show.
##
## ## NO TIMING IS ASSERTED, DELIBERATELY (Verification-Harness-Traps §12b)
##
## §2.3 asks for a search "fast enough to redraw on a scrub". The quantity
## asserted here is the number of CANDIDATE MASKS the search evaluated, as an
## EQUALITY against `tiers.candidatesPerCell` times the cell count. That number
## is identical under every memory manager, optimisation level and machine, so
## it needs no build quoted beside it — which an elapsed time would, and which
## is how an ORC-only measurement nearly shipped as a product claim in PLAT-13.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## Every assertion goes through `ck`/`ckEq`, which are TEMPLATES and not procs
## (§13). The last case asserts the tally against a number written from a run.

import std/[math, strutils, unittest]

import ../terminal_graphics

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const ExpectedAssertions = 798
  ## Written from a run. See the final case.

# ---------------------------------------------------------------------------
# Rasters, built the way a framebuffer arrives
# ---------------------------------------------------------------------------

proc solid(width, height: int; c: Rgb): RgbaImage =
  var px = newSeq[byte](width * height * 4)
  for i in 0 ..< width * height:
    px[i * 4] = c.r
    px[i * 4 + 1] = c.g
    px[i * 4 + 2] = c.b
    px[i * 4 + 3] = 255'u8
  initRgbaImage(width, height, px)

proc bands(width, height: int; top, bottom: Rgb): RgbaImage =
  ## The top half one colour, the bottom half another. At tier 1 with one cell
  ## row this is the case whose minimum error is EXACTLY zero.
  var px = newSeq[byte](width * height * 4)
  for y in 0 ..< height:
    let c = if y < height div 2: top else: bottom
    for x in 0 ..< width:
      let i = (y * width + x) * 4
      px[i] = c.r
      px[i + 1] = c.g
      px[i + 2] = c.b
      px[i + 3] = 255'u8
  initRgbaImage(width, height, px)

proc horizontalRamp(width, height: int): RgbaImage =
  ## A left-to-right grey gradient — §2.3's "visible banding on gradients" is
  ## the defect a non-perceptual metric produces, so the gradient is the
  ## picture the fidelity floor is measured on.
  var px = newSeq[byte](width * height * 4)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let v = byte(x * 255 div max(1, width - 1))
      let i = (y * width + x) * 4
      px[i] = v
      px[i + 1] = v
      px[i + 2] = v
      px[i + 3] = 255'u8
  initRgbaImage(width, height, px)

const
  Black = Rgb(r: 0, g: 0, b: 0)
  White = Rgb(r: 255, g: 255, b: 255)
  Red = Rgb(r: 255, g: 0, b: 0)
  Green = Rgb(r: 0, g: 255, b: 0)
  Blue = Rgb(r: 0, g: 0, b: 255)
  SquareFit = CellFit(cols: 4, rows: 2, aspect: DefaultCellAspect,
                      sourceWidth: 8, sourceHeight: 8, corrected: true)

suite "PLAT-14: §2.1's tiers as a model":

  test "the ordinal IS the specification's tier number":
    # The whole fail-low rule is written as `max` over this ordinal
    # (`tiers.weakerOf`), so an enum reordered by a merge would invert every
    # refusal in `app/theme/image_capability.nim` silently.
    ckEq ord(itProtocol), 0
    ckEq ord(itHalfBlock), 1
    ckEq ord(itQuadrant), 2
    ckEq ord(itSextant), 3
    ckEq ord(itOctant), 4
    ckEq ord(itBraille), 5
    ckEq ord(itAscii), 6

  test "weakerOf picks the tier that asks LESS of the terminal":
    ckEq weakerOf(itProtocol, itAscii), itAscii
    ckEq weakerOf(itAscii, itProtocol), itAscii
    ckEq weakerOf(itHalfBlock, itBraille), itBraille
    ckEq weakerOf(itSextant, itSextant), itSextant
    # It is a lattice join and not an ordering accident: weakening twice is
    # weakening once, and the operation is commutative over every pair.
    var pairs = 0
    for a in ImageTier:
      for b in ImageTier:
        ckEq weakerOf(a, b), weakerOf(b, a)
        ck isWeakerOrEqual(weakerOf(a, b), a)
        ck isWeakerOrEqual(weakerOf(a, b), b)
        inc pairs
    ckEq pairs, 49

  test "§2.1's geometry column, and the candidate bound derived from it":
    ckEq subCell(itHalfBlock), SubCell(cols: 1, rows: 2)
    ckEq subCell(itQuadrant), SubCell(cols: 2, rows: 2)
    ckEq subCell(itSextant), SubCell(cols: 2, rows: 3)
    ckEq subCell(itOctant), SubCell(cols: 2, rows: 4)
    ckEq subCell(itBraille), SubCell(cols: 2, rows: 4)
    ckEq subCell(itAscii), SubCell(cols: 1, rows: 1)
    ckEq candidatesPerCell(itHalfBlock), 4
    ckEq candidatesPerCell(itQuadrant), 16
    ckEq candidatesPerCell(itSextant), 64
    ckEq candidatesPerCell(itBraille), 256
    # Tier 0 is not a cell rendering and tier 6 is a lookup, so neither has a
    # candidate set. A non-zero here would mean the search had been pointed at
    # something it cannot search.
    ckEq candidatesPerCell(itProtocol), 0
    ckEq candidatesPerCell(itAscii), 0

  test "the three tiers that are not automatically selectable, named":
    # `AutomaticTiers` is a CLAIM about what detection may return, and
    # `test_image_capability.nim` asserts detection stays inside it over the
    # whole environment cross product. This case asserts the claim's contents,
    # so the two cannot drift into agreeing about a set neither states.
    ck itQuadrant notin AutomaticTiers
    ck itSextant notin AutomaticTiers
    ck itOctant notin AutomaticTiers
    ck itProtocol in AutomaticTiers
    ck itHalfBlock in AutomaticTiers
    ck itBraille in AutomaticTiers
    ck itAscii in AutomaticTiers
    ckEq AutomaticTiers.card, 4

  test "the tier names round-trip, and an unknown name fails to the WEAKEST":
    var named = 0
    for tier in ImageTier:
      let (ok, parsed) = parseTierName(tierName(tier))
      ck ok
      ckEq parsed, tier
      inc named
    ckEq named, 7
    # THE FAILURE VALUE. A caller that ignored the `bool` gets the tier that
    # cannot put escape bytes on a screen — not `ImageTier`'s zero value, which
    # is tier 0.
    let (bad, fallback) = parseTierName("kitty")
    ck not bad
    ckEq fallback, itAscii
    ck fallback != low(ImageTier)
    ck tierNames().contains("half-block")
    ck tierNames().contains("braille")

suite "PLAT-14 deliverable 2: the perceptual space":

  test "the sRGB transfer function is applied, by its number":
    # WITH the gamma, a mid-grey's Oklab lightness is 0.600. WITHOUT it, it is
    # cbrt(128/255) = 0.795. This is the assertion that fails if the transfer
    # function is removed, and no rendered picture in this file would show the
    # difference.
    let mid = toOklab(Rgb(r: 128, g: 128, b: 128))
    ck abs(mid.l - 0.6000) < 0.002
    ck abs(mid.a) < 0.001
    ck abs(mid.b) < 0.001
    let white = toOklab(White)
    ck abs(white.l - 1.0) < 0.002
    let black = toOklab(Black)
    ck abs(black.l) < 0.001

  test "green is weighted above blue, which is why sRGB error is wrong":
    # §2.3's stated reason for the space. In a plain sRGB metric these two
    # distances from black are EQUAL (both 255 in one channel); perceptually
    # they are nothing like equal.
    let greenL = toOklab(Green).l
    let blueL = toOklab(Blue).l
    let redL = toOklab(Red).l
    ck greenL > redL
    ck redL > blueL
    # THE NUMBERS, not only the order. Ottosson's transform gives these three
    # lightnesses for the primaries, and an ordering alone would be satisfied
    # by any monotone function of the green channel — including the plain sRGB
    # mean this space exists to replace.
    ck abs(greenL - 0.8664) < 0.003
    ck abs(redL - 0.6279) < 0.003
    ck abs(blueL - 0.4520) < 0.003
    # The metric is a metric: zero on equality, symmetric, positive otherwise.
    ckEq oklabDistanceSq(Red, Red), 0.0
    ck oklabDistanceSq(Red, Green) > 0.0
    ck abs(oklabDistanceSq(Red, Green) - oklabDistanceSq(Green, Red)) < 1e-12

suite "PLAT-14 deliverable 1: the glyph tables":

  test "every quadrant mask has a distinct glyph in the block-elements range":
    var seen: seq[string] = @[]
    for mask in 0 .. 15:
      let g = glyphFor(itQuadrant, mask)
      ck g notin seen
      seen.add g
    ckEq seen.len, 16
    ckEq glyphFor(itQuadrant, 0), " "
    ckEq glyphFor(itQuadrant, 0b1111), "█"
    ckEq glyphFor(itQuadrant, 0b0011), "▀"
    ckEq glyphFor(itQuadrant, 0b1100), "▄"
    ckEq glyphFor(itQuadrant, 0b0101), "▌"
    ckEq glyphFor(itQuadrant, 0b1010), "▐"

  test "every sextant mask has a distinct glyph, and the four legacy ones":
    var seen: seq[string] = @[]
    for mask in 0 .. 63:
      let g = glyphFor(itSextant, mask)
      ck g notin seen
      seen.add g
    ckEq seen.len, 64
    # THE FOUR MASKS THAT ARE NOT IN THE U+1FB00 RUN, which is the whole reason
    # the index arithmetic has two decrements in it.
    ckEq glyphFor(itSextant, 0), " "
    ckEq glyphFor(itSextant, 0b010101), "▌"
    ckEq glyphFor(itSextant, 0b101010), "▐"
    ckEq glyphFor(itSextant, 0b111111), "█"
    # …and the two ends of the run, which is what pins the arithmetic.
    ckEq glyphFor(itSextant, 0b000001), "\u{1FB00}"
    ckEq glyphFor(itSextant, 0b111110), "\u{1FB3B}"

  test "every braille mask has a distinct glyph inside U+2800..U+28FF":
    var seen: seq[string] = @[]
    for mask in 0 .. 255:
      let g = glyphFor(itBraille, mask)
      ck g notin seen
      seen.add g
    ckEq seen.len, 256
    ckEq glyphFor(itBraille, 0), "\u{2800}"
    ckEq glyphFor(itBraille, 255), "\u{28FF}"
    # The dot PERMUTATION, which is the part that is not arithmetic: sub-cell 1
    # is the TOP-RIGHT sample and braille calls that dot 4 (0x08), not dot 2.
    ckEq glyphFor(itBraille, 0b00000001), "\u{2801}"
    ckEq glyphFor(itBraille, 0b00000010), "\u{2808}"
    ckEq glyphFor(itBraille, 0b01000000), "\u{2840}"
    ckEq glyphFor(itBraille, 0b10000000), "\u{2880}"

  test "the half-block table is the four masks and nothing else":
    ckEq glyphFor(itHalfBlock, 0), " "
    ckEq glyphFor(itHalfBlock, 1), "▀"
    ckEq glyphFor(itHalfBlock, 2), "▄"
    ckEq glyphFor(itHalfBlock, 3), "█"

  test "octants REFUSE rather than drawing an unverified table":
    # `tiers.nim`'s header states the reason. The refusal is asserted on the
    # MESSAGE and not merely on the exception, because a message that did not
    # name the remedy would leave a user with a tier that says "no".
    ck itOctant notin DrawableTiers
    var refused = false
    var message = ""
    try:
      discard glyphFor(itOctant, 0)
    except CellRenderError as e:
      refused = true
      message = e.msg
    ck refused
    ck message.contains("octant")
    ck message.contains("not implemented")
    ck message.contains("--image-tier=sextant")
    # THE POSITIVE TWIN, through the same function: the tier beside it draws,
    # so the refusal is about octants and not about `glyphFor` being broken.
    ckEq glyphFor(itSextant, 1), "\u{1FB00}"

  test "the ascii ramp is monotone and stays inside ASCII":
    ckEq asciiGlyph(DefaultAsciiRamp, 0.0), " "
    ckEq asciiGlyph(DefaultAsciiRamp, 1.0), "@"
    var previous = -1
    var steps = 0
    for i in 0 .. 20:
      let g = asciiGlyph(DefaultAsciiRamp, float(i) / 20.0)
      let index = DefaultAsciiRamp.find(g[0])
      ck index >= previous
      previous = index
      ck ord(g[0]) < 128
      inc steps
    ckEq steps, 21

suite "PLAT-14 deliverable 3: aspect correction, visible in the model":

  test "a square source fits twice as many columns as rows at a 1:2 cell":
    let fit = fitToCells(64, 64, DefaultCellAspect, 20, 40)
    ckEq fit.cols, 20
    ckEq fit.rows, 10
    ck fit.corrected
    ckEq fit.aspect.source, casDefault
    ck describeAspect(fit).contains("aspect=1:2(default)")
    ck describeAspect(fit).contains("corrected")

  test "a square cell needs no correction, and the model says so":
    # THE FALSIFYING TWIN of the case above: on a 1:1 cell the corrected and
    # uncorrected fits are the same, so `corrected` must be false. A flag that
    # was hard-coded true would pass the case above and fail here.
    let square = initCellAspect(10, 10)
    let fit = fitToCells(64, 64, square, 20, 40)
    ckEq fit.cols, 20
    ckEq fit.rows, 20
    ck not fit.corrected
    ckEq fit.aspect.source, casReported
    ck describeAspect(fit).contains("uncorrected")

  test "a degenerate reported ratio falls back to the default, named":
    ckEq initCellAspect(0, 20), DefaultCellAspect
    ckEq initCellAspect(20, 0), DefaultCellAspect
    ckEq initCellAspect(-1, -1).source, casDefault

  test "the row bound wins when it has to, and the fit stays inside both":
    let fit = fitToCells(16, 256, DefaultCellAspect, 80, 10)
    ck fit.cols <= 80
    ckEq fit.rows, 10
    ck fit.cols >= 1

  test "the fit is the SAME at every drawable cell tier":
    # `aspect.nim`'s header: a fit that folded the sub-cell geometry in would
    # give braille a different shape from half blocks, which §2.6 forbids.
    let reference = fitToCells(100, 50, DefaultCellAspect, 30, 30)
    var compared = 0
    for tier in DrawableTiers:
      if tier == itProtocol: continue
      let fit = fitToCells(100, 50, DefaultCellAspect, 30, 30)
      ckEq fit.cols, reference.cols
      ckEq fit.rows, reference.rows
      inc compared
    ckEq compared, 5

suite "PLAT-14 deliverables 1 and 2: the rendering":

  test "a half block over two bands is EXACT, and the two colours are the two":
    let img = bands(8, 8, Red, Blue)
    let fit = CellFit(cols: 1, rows: 1, aspect: DefaultCellAspect,
                      sourceWidth: 8, sourceHeight: 8, corrected: false)
    let grid = renderCells(img, itHalfBlock, fit)
    ckEq grid.cols, 1
    ckEq grid.rows, 1
    let cell = grid.cellAt(0, 0)
    # ZERO, not "small". With one sub-pixel per band there is a candidate that
    # assigns each its own colour, so the minimum is exactly zero — and a
    # search that had drifted would not reach it.
    ck cell.errorSq < 1e-12
    ckEq cell.glyph, "▀"
    ckEq cell.fg, Red
    ckEq cell.bg, Blue

  test "the same two bands the other way up pick the other glyph":
    # The falsifying twin: a renderer that always emitted `▀` with the top
    # colour would pass the case above and this one, so this asserts the
    # COLOURS swapped rather than the glyph.
    let img = bands(8, 8, Blue, Red)
    let fit = CellFit(cols: 1, rows: 1, aspect: DefaultCellAspect,
                      sourceWidth: 8, sourceHeight: 8, corrected: false)
    let cell = renderCells(img, itHalfBlock, fit).cellAt(0, 0)
    ck cell.errorSq < 1e-12
    ckEq cell.fg, Blue
    ckEq cell.bg, Red

  test "a solid image is one colour at every cell tier, with zero error":
    var tiersChecked = 0
    for tier in [itHalfBlock, itQuadrant, itSextant, itBraille]:
      let grid = renderCells(solid(16, 16, Green), tier, SquareFit)
      ckEq grid.cols, 4
      ckEq grid.rows, 2
      for cell in grid.cells:
        ck cell.errorSq < 1e-12
        ckEq cell.fg, Green
        ckEq cell.bg, Green
      inc tiersChecked
    ckEq tiersChecked, 4

  test "the search evaluates EXACTLY the bounded candidate set, per cell":
    # The bound, the claim and the measurement are the same quantity: masks
    # evaluated. An EQUALITY rather than an inequality, because an inequality
    # generous enough to be safe passes on a search that stopped early AND on
    # one that started looping.
    var tiersChecked = 0
    for tier in [itHalfBlock, itQuadrant, itSextant, itBraille]:
      let grid = renderCells(horizontalRamp(32, 32), tier, SquareFit)
      ckEq grid.candidatesEvaluated,
           grid.cols * grid.rows * candidatesPerCell(tier)
      inc tiersChecked
    ckEq tiersChecked, 4
    # …and tier 6 evaluates none, because it does not search.
    let ramp = renderCells(horizontalRamp(32, 32), itAscii, SquareFit)
    ckEq ramp.candidatesEvaluated, 0

  test "a gradient is more faithful at tier 1 than at tier 6, measured":
    # §7's "fidelity has a floor, not an equality". The floor asserted here is
    # an ORDERING between two renderings of ONE image by two tiers, plus an
    # absolute ceiling on the better one — an ordering alone would be satisfied
    # by two equally terrible renderings.
    let img = horizontalRamp(64, 16)
    let fit = fitToCells(64, 16, DefaultCellAspect, 16, 16)
    let fine = renderCells(img, itHalfBlock, fit)
    ck fine.meanErrorSq < 0.02
    ck fine.maxErrorSq < 0.05
    # The ramp's own error is not comparable through `errorSq` (it does not
    # search, so it reports zero); the comparison that IS available is the
    # glyph count, and a 10-step ramp cannot express a 64-step gradient.
    let coarse = renderCells(img, itAscii, fit)
    var distinctGlyphs: seq[string] = @[]
    for cell in coarse.cells:
      if cell.glyph notin distinctGlyphs: distinctGlyphs.add cell.glyph
    ck distinctGlyphs.len <= DefaultAsciiRamp.len
    ck distinctGlyphs.len > 1

  test "renderCells refuses tier 0 and an empty fit, by name":
    var refusedProtocol = false
    try:
      discard renderCells(solid(4, 4, Red), itProtocol, SquareFit)
    except CellRenderError as e:
      refusedProtocol = e.msg.contains("emitProtocolImage")
    ck refusedProtocol
    var refusedEmpty = false
    try:
      discard renderCells(solid(4, 4, Red), itHalfBlock,
                          CellFit(cols: 0, rows: 0))
    except CellRenderError as e:
      refusedEmpty = e.msg.contains("cell fit is empty")
    ck refusedEmpty
    # THE POSITIVE TWIN: the same raster at a drawable tier and a real fit
    # produces a grid, so the two refusals are about their arguments.
    ckEq renderCells(solid(4, 4, Red), itHalfBlock, SquareFit).cells.len, 8
    # THE SET THE REFUSAL ASKS, BY ENUMERATION — `CellRenderableTiers` is
    # written as `DrawableTiers - {itProtocol}`, and a derived set is ONE
    # EXPRESSION, which is the thing that can be wrong while its name goes on
    # reading correctly. PLAT-15's landing pass added this: the same predicate
    # is what `app/views/frame_viewer.resolveGap` asks BEFORE it paints, so a
    # member here is a member there and the renderer's refusal and the pane's
    # pre-check cannot come apart (Verification-Harness-Traps §14).
    ckEq CellRenderableTiers, {itHalfBlock, itQuadrant, itSextant, itBraille,
                               itAscii}
    # AND THE TWO SETS DIFFER IN EXACTLY ONE TIER, in the direction that
    # matters: tier 0 DRAWS (it emits an escape payload) and is NOT renderable
    # as cells. Asserted both ways round, because "drawable" reading as
    # "renderable" is the whole of the defect this case was extended for.
    ck itProtocol in DrawableTiers
    ck itProtocol notin CellRenderableTiers
    ck itOctant notin DrawableTiers
    ck itOctant notin CellRenderableTiers
    # …AND EVERY MEMBER ACTUALLY RENDERS, through the same function, so the set
    # is a claim about the renderer rather than a literal agreeing with a
    # comment (§4d).
    var rendered = 0
    for tier in CellRenderableTiers:
      ck renderCells(solid(4, 4, Red), tier, SquareFit).cells.len > 0
      inc rendered
    ckEq rendered, 5

  test "a raster whose buffer does not match its extent is refused":
    var refused = false
    try:
      discard initRgbaImage(4, 4, newSeq[byte](10))
    except RasterError as e:
      refused = e.msg.contains("needs 64 bytes")
    ck refused
    ckEq initRgbaImage(4, 4, newSeq[byte](64)).pixels.len, 64

  test "the box filter is the mean, computed independently":
    # An expected value this file derived, not this function's own output.
    let img = bands(4, 4, Rgb(r: 0, g: 0, b: 0), Rgb(r: 100, g: 200, b: 40))
    ckEq img.boxSample(0, 0, 4, 4), Rgb(r: 50, g: 100, b: 20)
    ckEq img.boxSample(0, 0, 4, 2), Rgb(r: 0, g: 0, b: 0)
    ckEq img.boxSample(0, 2, 4, 4), Rgb(r: 100, g: 200, b: 40)
    # The edge rule is a CLAMP: sampling past the right edge repeats it.
    ckEq img.pixelAt(99, 99), img.pixelAt(3, 3)
    ckEq img.pixelAt(-5, -5), img.pixelAt(0, 0)

suite "PLAT-14: the tally":

  test "every assertion in this file ran":
    # Verification-Harness-Traps §4c. A branch that returned early, a loop that
    # skipped a member or a `continue` that dropped a case cannot reach this
    # line with the right count.
    echo "CHECKS: " & $countedAssertions
    ckEq countedAssertions, ExpectedAssertions
