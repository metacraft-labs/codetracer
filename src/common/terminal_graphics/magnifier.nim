## terminal_graphics/magnifier.nim — PLAT-15 deliverable 3.
## `CodeTracer-TUI-Graphics.md` §5, "the interaction a terminal changes most".
##
## §5: *"In a terminal, one cell is one pixel only at tier 0; at tier 1 it is
## two, at tier 4 it is eight. **A user cannot address a pixel by clicking a
## cell.** So picking is a two-stage interaction: coarse — move a cell cursor
## over the frame; magnify — open a magnifier that scales the neighbourhood so
## one source pixel occupies one or more whole cells, and move a pixel cursor
## within it. The magnifier reports the exact pixel coordinate, and *that* is
## what `pixel_history_vm` receives. The coordinate is never inferred from a
## cell position without the magnification step, because at any tier above 0
## that inference is a guess."*
##
## ## FOUR UNITS, AND EVERY FIELD BELOW NAMES ITS OWN
##
## PLAT-12, PLAT-13 and PLAT-14 each paid for a bound whose unit was not the
## unit its measurement used, and a magnifier is where that is easiest to do,
## because four different quantities are in play at once:
##
##   | quantity | unit | where it lives |
##   |---|---|---|
##   | the picked coordinate | **source pixels** | `Magnifier.cursorX/cursorY`, `PixelRect` |
##   | what one frame cell shows | **source pixels**, as a RECTANGLE | `coarsePixelRect` |
##   | the magnifier's own extent | **terminal cells** | `magnifiedFit.cols/rows`, `zoomCols/zoomRows` |
##   | what a cell samples | **sub-cell samples** | `tiers.subCell` |
##   | what a scrub costs | **emitted bytes** | `emit.EmittedImage.emittedBytes` |
##
## `zoomCols` and `zoomRows` are spelled "CELLS PER SOURCE PIXEL" everywhere
## they appear, never "zoom", because the reciprocal reading — source pixels
## per cell — is the quantity the COARSE stage has and is exactly the one §5
## forbids picking from.
##
## ## A CORRECTION TO §5, FOUND WHILE IMPLEMENTING IT
##
## §5 says a cell is one pixel "only at tier 0". Measured rather than assumed:
## `coarsePixelRect` on a 640x480 frame fitted into an 80x24 pane answers a
## rectangle of **8x20 source pixels at tier 0** — because tier 0 draws true
## pixels at whatever SIZE the pane gives it, and the pane is 80 cells wide
## however many pixels the terminal puts in a cell. Tier 0 removes the
## SUB-CELL division and removes nothing else.
##
## So the magnifier is required at EVERY tier, including tier 0, and the rule
## §5 states as "above tier 0 that inference is a guess" holds at tier 0 too
## unless the fit happens to be 1:1. `pixelCount(coarsePixelRect(...)) == 1` is
## the only condition under which a cell addresses a pixel, it is a property of
## the FIT rather than of the tier, and `magnifier_test.nim` asserts both
## directions of it. The document is corrected in place.
##
## ## THE MAGNIFIER RENDERS AT A CELL TIER EVEN ON A TIER-0 TERMINAL
##
## `magnifierTier` answers `itHalfBlock` for `itProtocol`, and that is a
## decision with a reason rather than a limitation:
##
##   * At one or more whole cells per source pixel, a half-block cell's two
##     sub-samples are both inside ONE source pixel, so the cell's colour IS
##     that pixel's colour, exactly. Tier 0 cannot be more exact than exact.
##   * A tier-0 magnifier would re-transmit a blown-up raster on every cursor
##     move. §3's bandwidth rule — "an image redrawn on every scrub step at
##     tier 0 can be megabytes" — bites hardest on exactly this interaction,
##     and Kitty's placement ids cannot help because the PICTURE changes.
##
## The frame itself still draws at tier 0 where the terminal allows it; it is
## the magnifier overlay that does not.
##
## ## NOTHING HERE READS AN ENVIRONMENT, OPENS AN FD OR DRAWS A PIXEL
##
## `terminal_graphics/`'s rule, unchanged. Every function is a pure function of
## values, which is what lets the exactness gate — "a picked pixel's coordinate
## is exact at every tier, asserted against the source image" — be swept over
## every drawable tier in a lane with no terminal in it.

import ./tiers
import ./raster
import ./aspect
import ./cell_render

type
  MagnifierError* = object of CatchableError

  Magnifier* = object
    ## §5's second stage, as a value.
    window*: PixelRect
      ## The neighbourhood on screen, in **SOURCE PIXELS**. Always inside the
      ## image and always at least 1x1.
    zoomCols*: int
      ## **TERMINAL CELLS per source pixel**, horizontally. >= 1 by
      ## construction, which is §5's "one source pixel occupies one or more
      ## whole cells" stated as an invariant rather than as an intention.
    zoomRows*: int
      ## **TERMINAL CELLS per source pixel**, vertically. >= 1.
    cursorX*: int
    cursorY*: int
      ## THE PICKED COORDINATE, in **SOURCE PIXELS**, in the image's own
      ## coordinates — not in the window's. This is the pair
      ## `pixel_history_vm.loadPixelHistory` receives, and the reason it is
      ## absolute is that a window-relative pair would have to be added to a
      ## window somebody else might have scrolled.
    imageWidth*: int
    imageHeight*: int
      ## The image the coordinate is INSIDE, in **SOURCE PIXELS**. Carried so
      ## every clamp in this module has the bound in scope rather than taking
      ## it as a parameter that a caller can get wrong once.
    aspect*: CellAspect
      ## §2.4's cell ratio, carried because `zoomCols` was DERIVED from it and
      ## a reader has to be able to see which ratio produced a 2:1 zoom.

const
  DefaultCellsPerPixel* = 1
    ## The smallest magnification §5 permits: "one source pixel occupies one or
    ## more whole cells". One CELL ROW per source pixel, which at the default
    ## 1:2 cell is two cell COLUMNS — see `cellsPerSourcePixel`.
    ##
    ## THE FLOOR AND NOT A TARGET. A bigger number shows fewer pixels in the
    ## same rectangle, and the interaction §5 describes is about addressing one
    ## pixel rather than about seeing a large neighbourhood.

func cellsPerSourcePixel*(rows: int; aspect: CellAspect): (int, int) =
  ## `(cols, rows)` of **TERMINAL CELLS** one SOURCE PIXEL occupies.
  ##
  ## §2.4's aspect correction, applied to the magnifier instead of to the
  ## frame: a cell is `heightPx / widthPx` times taller than it is wide, so a
  ## SQUARE source pixel needs that many more columns than rows to look square
  ## on screen. At the default 1:2 cell, one cell row per pixel is two cell
  ## columns per pixel — and a magnifier that used one of each would show every
  ## pixel at half width, which is the same stretch §2.4 exists to remove,
  ## arriving through the interaction instead of through the picture.
  ##
  ## The rounding is half-up rather than truncating, so a 2:3 cell gives 2
  ## columns per row rather than 1.
  let r = max(1, rows)
  let c = max(1, (r * max(1, aspect.heightPx) + max(1, aspect.widthPx) div 2) div
                 max(1, aspect.widthPx))
  (c, r)

func magnifierTier*(tier: ImageTier): ImageTier =
  ## The tier the MAGNIFIER OVERLAY renders at, given the tier the FRAME
  ## renders at. See this module's header for why tier 0 becomes tier 1.
  ##
  ## Every other tier is answered unchanged, including `itOctant` — which is
  ## NOT renderable as cells (`tiers.CellRenderableTiers`) and must reach the
  ## caller as the tier it is, so the pane can report a refusal instead of a
  ## `CellRenderError` at draw time. Substituting a neighbouring tier here
  ## would make "the pane declares its tier in its title" (§4) a lie, which is
  ## the same rule `cell_render.glyphFor` refuses octants under.
  if tier == itProtocol: itHalfBlock else: tier

func coarsePixelRect*(sourceWidth, sourceHeight: int; fit: CellFit;
                      tier: ImageTier; col, row: int): PixelRect =
  ## §5's FIRST stage, and the value that says why a second one is needed:
  ## the **SOURCE PIXELS** one FRAME CELL covers.
  ##
  ## This is a RECTANGLE and never a coordinate, deliberately. §5's rule is
  ## that "the coordinate is never inferred from a cell position without the
  ## magnification step", and a function that answered a pixel here would be
  ## that inference with a name. `pixelCount` on the result is the number §5's
  ## argument is about.
  ##
  ## Derived from `cell_render.sourceRectOfSubCell` — the renderer's OWN
  ## sampling arithmetic, not a second copy of it — by taking the first
  ## sub-cell's top-left and the last sub-cell's bottom-right. At `itProtocol`,
  ## whose `subCell` is 0x0 because a protocol emission is not a cell
  ## rendering, the cell is treated as carrying a single sample: tier 0 removes
  ## the sub-cell division and does not make a cell one pixel.
  if fit.cols <= 0 or fit.rows <= 0:
    raise newException(MagnifierError,
      "the frame has no cell fit (" & $fit.cols & "x" & $fit.rows & "); " &
      describeAspect(fit))
  if col < 0 or row < 0 or col >= fit.cols or row >= fit.rows:
    raise newException(MagnifierError,
      "cell (" & $col & "," & $row & ") is outside the frame's " &
      $fit.cols & "x" & $fit.rows & " cell grid")
  let geom = subCell(tier)
  let cols = max(1, geom.cols)
  let rows = max(1, geom.rows)
  let effective = if tier == itProtocol: itAscii else: tier
    # `itAscii`'s geometry is 1x1, which is the "one sample per cell" reading
    # the paragraph above states for tier 0. Named through the tier table
    # rather than by open-coding a 1, so a change to §2.1's geometry column
    # moves this with it.
  let first = sourceRectOfSubCell(sourceWidth, sourceHeight, fit, effective,
                                  col * cols, row * rows)
  let last = sourceRectOfSubCell(sourceWidth, sourceHeight, fit, effective,
                                 col * cols + cols - 1, row * rows + rows - 1)
  PixelRect(x: first.x, y: first.y,
            width: max(1, last.x + last.width - first.x),
            height: max(1, last.y + last.height - first.y))

func clampWindow(mag: var Magnifier) =
  ## Keep the window inside the image AND containing the cursor. Both, in one
  ## place, because a scroll that satisfied one and broke the other would show
  ## a cursor the user cannot see while reporting a coordinate they cannot
  ## check.
  mag.window.width = max(1, min(mag.window.width, mag.imageWidth))
  mag.window.height = max(1, min(mag.window.height, mag.imageHeight))
  if mag.cursorX < mag.window.x:
    mag.window.x = mag.cursorX
  if mag.cursorX >= mag.window.x + mag.window.width:
    mag.window.x = mag.cursorX - mag.window.width + 1
  if mag.cursorY < mag.window.y:
    mag.window.y = mag.cursorY
  if mag.cursorY >= mag.window.y + mag.window.height:
    mag.window.y = mag.cursorY - mag.window.height + 1
  mag.window.x = max(0, min(mag.window.x, mag.imageWidth - mag.window.width))
  mag.window.y = max(0, min(mag.window.y, mag.imageHeight - mag.window.height))

func openMagnifier*(imageWidth, imageHeight: int; fit: CellFit;
                    tier: ImageTier; col, row: int;
                    viewCols, viewRows: int;
                    cellRows = DefaultCellsPerPixel): Magnifier =
  ## §5's TWO STAGES, joined: a cell the user moved a cursor to, opened into a
  ## magnifier over the neighbourhood that cell shows.
  ##
  ## `viewCols` / `viewRows` are the overlay's extent in **TERMINAL CELLS**;
  ## `cellRows` is **CELL ROWS per source pixel**. The pixel cursor starts at
  ## the CENTRE of the coarse rectangle — a defined pixel inside the cell the
  ## user actually pointed at, which is a starting point rather than an answer:
  ## §5's contract is that the reported coordinate comes from moving the pixel
  ## cursor, and `openMagnifier` is the step that makes moving it possible.
  if imageWidth <= 0 or imageHeight <= 0:
    raise newException(MagnifierError,
      "a magnifier needs a raster with positive extent, got " &
      $imageWidth & "x" & $imageHeight)
  if viewCols <= 0 or viewRows <= 0:
    raise newException(MagnifierError,
      "a magnifier needs a rectangle to draw in, got " &
      $viewCols & "x" & $viewRows & " cells")
  let coarse = coarsePixelRect(imageWidth, imageHeight, fit, tier, col, row)
  let (zc, zr) = cellsPerSourcePixel(cellRows, fit.aspect)
  result = Magnifier(
    zoomCols: zc, zoomRows: zr,
    cursorX: min(coarse.x + coarse.width div 2, imageWidth - 1),
    cursorY: min(coarse.y + coarse.height div 2, imageHeight - 1),
    imageWidth: imageWidth, imageHeight: imageHeight, aspect: fit.aspect)
  let winW = max(1, min(viewCols div zc, imageWidth))
  let winH = max(1, min(viewRows div zr, imageHeight))
  result.window = PixelRect(x: result.cursorX - winW div 2,
                            y: result.cursorY - winH div 2,
                            width: winW, height: winH)
  clampWindow(result)

func moveCursor*(mag: Magnifier; dx, dy: int): Magnifier =
  ## Move the PIXEL cursor by `(dx, dy)` **SOURCE PIXELS**, scrolling the
  ## window the least amount that keeps the cursor visible.
  ##
  ## Clamped to the IMAGE rather than to the window, so the cursor reaches
  ## every pixel of the frame and the window follows; a cursor clamped to the
  ## window would make the edge pixels of a large frame unpickable, which is
  ## exactly the precision §5 says the magnifier exists to provide.
  result = mag
  result.cursorX = max(0, min(mag.cursorX + dx, mag.imageWidth - 1))
  result.cursorY = max(0, min(mag.cursorY + dy, mag.imageHeight - 1))
  clampWindow(result)

func magnifiedCols*(mag: Magnifier): int =
  ## The overlay's width in **TERMINAL CELLS**.
  mag.window.width * mag.zoomCols

func magnifiedRows*(mag: Magnifier): int =
  ## The overlay's height in **TERMINAL CELLS**.
  mag.window.height * mag.zoomRows

func sourcePixelOfCell*(mag: Magnifier; col, row: int): (int, int) =
  ## THE WHOLE CLAIM OF THIS MODULE: which **SOURCE PIXEL** the magnifier cell
  ## at `(col, row)` shows.
  ##
  ## Exact by construction rather than by rounding — one source pixel is
  ## `zoomCols x zoomRows` WHOLE cells, so the division has no remainder to
  ## lose. `magnifier_test.nim` asserts the claim against the raster's own
  ## colour formula, at every drawable tier, through `cell_render.renderCells`:
  ## the cell a coordinate names carries that pixel's colour and no other's.
  if col < 0 or row < 0 or col >= mag.magnifiedCols() or
     row >= mag.magnifiedRows():
    raise newException(MagnifierError,
      "magnifier cell (" & $col & "," & $row & ") is outside a " &
      $mag.magnifiedCols() & "x" & $mag.magnifiedRows() & " overlay")
  (mag.window.x + col div mag.zoomCols, mag.window.y + row div mag.zoomRows)

func cursorCell*(mag: Magnifier): (int, int) =
  ## The TOP-LEFT **TERMINAL CELL** of the cursor's pixel block. The inverse of
  ## `sourcePixelOfCell` at the cursor, and `sourcePixelOfCell(mag,
  ## cursorCell(mag))` is asserted equal to `(cursorX, cursorY)` — a round trip
  ## rather than two independent derivations.
  ((mag.cursorX - mag.window.x) * mag.zoomCols,
   (mag.cursorY - mag.window.y) * mag.zoomRows)

func magnifiedFit*(mag: Magnifier; tier: ImageTier): CellFit =
  ## The `CellFit` the overlay renders through.
  ##
  ## Built rather than solved: the magnifier's extent is DECIDED by the zoom
  ## (`window.width * zoomCols` cells), so `aspect.fitToCells` — which solves
  ## for the largest rectangle matching a source's shape — would be answering a
  ## question that is already answered, and answering it slightly differently.
  ## The aspect is still carried and is still the thing that produced
  ## `zoomCols`, so `describeAspect` on this fit names the ratio the overlay
  ## was corrected by.
  ##
  ## `corrected` is TRUE exactly when the zoom is not square, which is the same
  ## statement `CellFit.corrected` makes for a frame: the displayed rectangle's
  ## shape differs from the uncorrected one.
  let geom = subCell(magnifierTier(tier))
  CellFit(cols: mag.magnifiedCols(), rows: mag.magnifiedRows(),
          aspect: mag.aspect,
          sourceWidth: mag.magnifiedCols() * max(1, geom.cols),
          sourceHeight: mag.magnifiedRows() * max(1, geom.rows),
          corrected: mag.zoomCols != mag.zoomRows)

func magnifiedRaster*(img: RgbaImage; mag: Magnifier;
                      tier: ImageTier): RgbaImage =
  ## The window, blown up so that ONE SUB-CELL SAMPLE is ONE SOURCE PIXEL.
  ##
  ## Nearest-neighbour, and that is the only kernel that can be used here: a
  ## magnifier exists to show a user which pixel they have picked, and any
  ## interpolation would put a colour on screen that no pixel of the recording
  ## has — a DIFFERENT picture, which §2.5 forbids in as many words. The frame
  ## itself is box-filtered (`raster.boxSample`); the magnifier is not, and the
  ## two are different jobs.
  ##
  ## The dimensions are exactly `magnifiedCols * subCell.cols` by
  ## `magnifiedRows * subCell.rows`, so `cell_render.sourceRectOfSubCell`
  ## resolves each sub-cell to exactly one magnified pixel and the argmin has
  ## no averaging to do. That is what makes the exactness an EQUALITY rather
  ## than a perceptual threshold.
  let effective = magnifierTier(tier)
  if effective notin CellRenderableTiers:
    # `CellRenderableTiers` AND NOT `DrawableTiers`, which contains `itProtocol`
    # — the one tier `cell_render.renderCells` refuses. The overlay IS a cell
    # rendering, so the set to ask is the renderer's own
    # (Verification-Harness-Traps §14). `magnifierTier` never answers
    # `itProtocol`, so the two sets agree on every input this function can
    # receive today; asking the wrong one anyway is how the pane's tier-0
    # defect was written, one layer up.
    raise newException(MagnifierError,
      "image tier '" & tierName(effective) & "' cannot draw a magnifier: " &
      "it is not in CellRenderableTiers, so there is no glyph table to blow " &
      "the neighbourhood up with. Pick --image-tier=sextant for 2x3 or " &
      "--image-tier=braille for 2x4 shape resolution")
  let geom = subCell(effective)
  let w = mag.magnifiedCols() * max(1, geom.cols)
  let h = mag.magnifiedRows() * max(1, geom.rows)
  var px = newSeq[byte](w * h * 4)
  for my in 0 ..< h:
    let sy = mag.window.y + my div (mag.zoomRows * max(1, geom.rows))
    for mx in 0 ..< w:
      let sx = mag.window.x + mx div (mag.zoomCols * max(1, geom.cols))
      let c = img.pixelAt(sx, sy)
      let base = (my * w + mx) * 4
      px[base] = c.r
      px[base + 1] = c.g
      px[base + 2] = c.b
      px[base + 3] = img.alphaAt(sx, sy)
  initRgbaImage(w, h, px)

func renderMagnifier*(img: RgbaImage; mag: Magnifier;
                      tier: ImageTier): CellGrid =
  ## The overlay, through the PRODUCT'S OWN RENDERER.
  ##
  ## `cell_render.renderCells` and no second path: the magnifier is a picture
  ## of the same raster at a different scale, and a renderer of its own would
  ## be a second thing that can disagree about a colour while both agree with
  ## themselves (§14). The only thing this function decides is the tier
  ## (`magnifierTier`) and the fit (`magnifiedFit`).
  renderCells(img.magnifiedRaster(mag, tier), magnifierTier(tier),
              mag.magnifiedFit(tier))

func pickedPixel*(mag: Magnifier): (int, int) =
  ## The coordinate `pixel_history_vm.loadPixelHistory` receives, in **SOURCE
  ## PIXELS**.
  ##
  ## A named function rather than two field reads, so the one value §5 calls
  ## "the exact pixel coordinate" has a single spelling that a test, a pane
  ## title and a binding all quote.
  (mag.cursorX, mag.cursorY)

func describeMagnifier*(mag: Magnifier): string =
  ## One line for a pane title or a failure message, naming every unit.
  ##
  ## `capabilities.describe`'s rule: a report that named the coordinate without
  ## naming the zoom and the window leaves a reader unable to check it against
  ## a screen they can see.
  "pixel=" & $mag.cursorX & "," & $mag.cursorY &
    " of " & $mag.imageWidth & "x" & $mag.imageHeight &
    " window=" & $mag.window.width & "x" & $mag.window.height & "px@" &
    $mag.window.x & "," & $mag.window.y &
    " zoom=" & $mag.zoomCols & "x" & $mag.zoomRows & "cells/px" &
    " overlay=" & $mag.magnifiedCols() & "x" & $mag.magnifiedRows() & "cells"
