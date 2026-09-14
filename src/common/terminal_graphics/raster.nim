## terminal_graphics/raster.nim — PLAT-14. The pixels a cell tier reads.
##
## A cell rendering is a function from a RASTER to a grid of (glyph, fg, bg).
## This module is the raster half: an 8-bit RGBA image and the box-filter
## sampling the tier renderers use to collapse a rectangle of source pixels
## into one sub-cell colour.
##
## ## WHY THE INPUT IS RGBA AND NOT `image/png`
##
## Because this build has no PNG or JPEG decoder, and saying otherwise would be
## the scaffolding this repository's milestone hygiene rules out. The split is
## recorded here because it decides which media a terminal surface may claim
## (`terminal_graphics/media.terminalMediaCapability` — which is where the
## function lives; `value_presentation/surfaces.nim` is its CONSUMER and names
## it in a comment, which is how this header came to name the wrong module):
##
##   * **Tier 0 needs no decoder.** Kitty's `f=100` and iTerm2's `File=inline`
##     both take the ENCODED bytes and decode them in the terminal, so a
##     `image/png` value on a Kitty terminal is drawn by handing the bytes
##     across unchanged.
##   * **Tiers 1-6 need pixels**, and the pixels are what a visual-replay
##     framebuffer already is: `ct-gfx-player` reconstructs frames against a
##     real GPU and hands back a raster, which is PLAT-15's input and is why
##     this module's shape is the one it is.
##
## So an `image/png` on a terminal with no graphics protocol degrades, through
## PLAT-9's `pdDependencyMissing`, naming the missing decoder. That is a real
## bound of this milestone rather than a rendering nobody wrote, and it is
## asserted as a degradation rather than described in a comment.
##
## Nothing here allocates per pixel, does I/O, or depends on anything outside
## `std/math`.

import std/math

type
  Rgb* = object
    ## One colour, 8 bits per channel, as the terminal will be told it.
    r*: uint8
    g*: uint8
    b*: uint8

  RgbaImage* = object
    ## An 8-bit RGBA raster. `pixels.len == width * height * 4`, checked by
    ## `initRgbaImage`; a raster that does not satisfy it cannot be built.
    width*: int
    height*: int
    pixels*: seq[byte]

  PixelRect* = object
    ## A rectangle of SOURCE PIXELS — `[x, x+width) x [y, y+height)` in the
    ## raster's own coordinates, and in no other unit.
    ##
    ## PLAT-15 added this type here, one level below both of its users, for
    ## Verification-Harness-Traps §14's reason. `cell_render.sampleCell` and
    ## `magnifier.coarsePixelRect` both have to answer "which source pixels
    ## does this sub-cell cover?", and the campaign's rule is one predicate in
    ## one function that the rule and its control both call — so the answer is
    ## `cell_render.sourceRectOfSubCell` and this is the value it returns.
    ##
    ## THE UNIT IS IN THE TYPE, which is the other half of why it exists.
    ## PLAT-15's magnifier juggles four of them — source pixels, terminal
    ## cells, sub-cell samples and emitted bytes — and a bare `(int, int,
    ## int, int)` would let any two be swapped silently.
    x*: int
    y*: int
    width*: int
    height*: int

  RasterError* = object of CatchableError

func pixelCount*(r: PixelRect): int =
  ## How many SOURCE PIXELS the rectangle holds.
  ##
  ## §5's whole argument is a statement about this number: "one cell is one
  ## pixel *only at tier 0*; at tier 1 it is two, at tier 4 it is eight", so
  ## `pixelCount(coarsePixelRect(...)) == 1` is the only condition under which
  ## a cell ADDRESSES a pixel, and the magnifier exists because it normally
  ## does not hold.
  max(0, r.width) * max(0, r.height)

func containsPixel*(r: PixelRect; x, y: int): bool =
  x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height

func rgb*(r, g, b: int): Rgb =
  ## Clamping constructor. The tier renderers average colours in floating
  ## point and round back; a rounding that landed on 256 would wrap to 0 and
  ## put a black pixel in the brightest part of an image.
  Rgb(r: uint8(clamp(r, 0, 255)), g: uint8(clamp(g, 0, 255)),
      b: uint8(clamp(b, 0, 255)))

func initRgbaImage*(width, height: int; pixels: seq[byte]): RgbaImage =
  ## The only constructor. Raises rather than truncating: a raster whose buffer
  ## does not match its declared size is a bug in the caller, and a renderer
  ## that silently read past the end of it would produce a picture whose defect
  ## is invisible in the output.
  if width <= 0 or height <= 0:
    raise newException(RasterError,
      "raster must have positive extent, got " & $width & "x" & $height)
  if pixels.len != width * height * 4:
    raise newException(RasterError,
      "raster " & $width & "x" & $height & " needs " & $(width * height * 4) &
      " bytes of RGBA, got " & $pixels.len)
  RgbaImage(width: width, height: height, pixels: pixels)

func pixelAt*(img: RgbaImage; x, y: int): Rgb =
  ## One source pixel, with the coordinate CLAMPED to the raster.
  ##
  ## Clamped rather than wrapped and rather than checked, because the sampler
  ## below walks a rectangle computed from a cell grid and the last cell's
  ## rectangle can overhang the right or bottom edge by up to one sub-pixel
  ## when the extents do not divide. Clamping repeats the edge pixel, which is
  ## the standard edge rule for a box filter and is the only one of the three
  ## that neither raises on a legitimate picture nor folds the opposite edge
  ## into it.
  let cx = clamp(x, 0, img.width - 1)
  let cy = clamp(y, 0, img.height - 1)
  let base = (cy * img.width + cx) * 4
  Rgb(r: img.pixels[base], g: img.pixels[base + 1], b: img.pixels[base + 2])

func alphaAt*(img: RgbaImage; x, y: int): uint8 =
  let cx = clamp(x, 0, img.width - 1)
  let cy = clamp(y, 0, img.height - 1)
  img.pixels[(cy * img.width + cx) * 4 + 3]

func boxSample*(img: RgbaImage; x0, y0, x1, y1: int): Rgb =
  ## The mean colour of the half-open source rectangle `[x0,x1) x [y0,y1)`.
  ##
  ## An UNWEIGHTED box filter, on purpose. §2.3 asks for error minimisation in
  ## a perceptual space over the GLYPH choice; the down-sample that feeds it is
  ## a separate step, and a fancier kernel here would change the numbers the
  ## glyph search compares without changing which comparison it makes. A box
  ## filter is also the only kernel whose result a test can compute by hand,
  ## which is what lets `raster_test.nim` assert a sample against an expected
  ## value it derived itself rather than against this function's own output.
  ##
  ## The average is taken in LINEAR-LIGHT-free sRGB byte space deliberately:
  ## the sub-cell colours it produces are what the terminal is TOLD, and the
  ## terminal's SGR triples are sRGB bytes. Perceptual weighting enters one
  ## step later, in `oklab.nim`, where the comparison happens.
  let lx = max(x0, 0)
  let ly = max(y0, 0)
  let hx = max(x1, lx + 1)
  let hy = max(y1, ly + 1)
  var sr, sg, sb, n = 0
  for y in ly ..< hy:
    for x in lx ..< hx:
      let p = img.pixelAt(x, y)
      sr += int(p.r)
      sg += int(p.g)
      sb += int(p.b)
      inc n
  if n == 0:
    return Rgb()
  rgb(int(round(sr / n)), int(round(sg / n)), int(round(sb / n)))

func luminance*(c: Rgb): float =
  ## Rec. 709 relative luminance in 0..1, for tier 6's ramp and for the
  ## `ihMask` hint's threshold. sRGB-weighted rather than a plain mean: a mean
  ## makes pure blue as bright as pure green, and an ASCII ramp built on one
  ## draws a different picture from the source rather than a coarser one.
  (0.2126 * float(c.r) + 0.7152 * float(c.g) + 0.0722 * float(c.b)) / 255.0
