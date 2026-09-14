## terminal_graphics/cell_render.nim — PLAT-14 deliverables 1 and 2.
##
## §2: *"What it does not have is any way to draw an image on a terminal that
## supports none of them — which is most terminals over SSH, inside tmux, in a
## CI log, or on a BSD console. This is the gap, and closing it is what makes
## graphics a feature of the TUI rather than a feature of Kitty."*
##
## One raster in, one grid of `(glyph, fg, bg)` out, at whichever of §2.1's
## cell tiers the caller was given.
##
## ## ONE SEARCH, SIX TIERS
##
## §2.3: *"For tiers 2-4 the renderer chooses, per cell, the (glyph, fg, bg)
## triple minimising the error against the source pixels."* Tiers 1 and 5 are
## written as the same search rather than as two special cases, and that is a
## §14 decision rather than a stylistic one: a half block whose fg is "the top
## pixel" and a braille cell whose fg is "the mean of the dots" are two
## spellings of one argmin, and two spellings drift. The tier supplies
##
##   * its sub-cell geometry (`tiers.subCell`), and
##   * a mask-to-glyph table (`glyphFor` below),
##
## and everything else — the sampling, the two means, the Oklab error, the
## argmin — is one loop that does not know which tier it is in.
##
## **The half-block case is exact and that is a check on the search rather than
## an exception to it.** With two sub-pixels the mask `0b01` assigns each
## sub-pixel its own colour, so the minimum error is exactly zero; a search that
## had drifted would not reach zero, and `cell_render_test.nim` asserts the zero
## rather than asserting the glyph.
##
## ## THE WORK IS COUNTED, AND THE COUNT IS THE SAME QUANTITY THE BOUND NAMES
##
## `CellGrid.candidatesEvaluated` is the number of masks the argmin considered,
## and `tiers.candidatesPerCell` is the per-cell bound. The suite asserts
## `candidatesEvaluated == cols * rows * candidatesPerCell(tier)` — an EQUALITY,
## because an inequality generous enough to be safe would pass on a search that
## had stopped early and on one that had started looping. **No timing is
## claimed anywhere in this package**, deliberately: PLAT-13's landing pass
## recorded that a 66.9 s headline was an ORC measurement of a defect no shipped
## build ever had, and a count of candidate masks is identical under every
## memory manager and every optimisation level, so it needs no build named
## beside it.
##
## ## `itOctant` REFUSES
##
## See `tiers.nim`'s header. `glyphFor` raises `CellRenderError` naming the
## reason; it does not fall back to a neighbouring tier, because a silent
## substitution would make "the pane declares its tier in its title" (§4) a lie.
##
## ## SO DOES `itProtocol`, AND `renderCells` ASKS ONE SET ABOUT BOTH
##
## `renderCells` accepts exactly `tiers.CellRenderableTiers` and refuses
## everything else through `glyphFor`, which carries a message per reason.
## **That set is also what a caller asks BEFORE it paints** — one predicate, two
## callers, so a pane cannot be told "yes" by one spelling and refused by the
## other. PLAT-15's landing pass is why this is written down: the pane asked
## `DrawableTiers`, which CONTAINS `itProtocol`, and the refusal below reached a
## user as an exception out of the shell's paint rather than as the report §2.6
## asks for.

import std/[math, unicode]

import ./tiers
import ./raster
import ./oklab
import ./aspect

type
  RenderedCell* = object
    ## One terminal cell of a rendered image.
    glyph*: string   ## exactly one grapheme, UTF-8
    fg*: Rgb
    bg*: Rgb
    errorSq*: float
      ## The residual Oklab error this cell's winning triple carries. Carried
      ## per cell rather than only in aggregate because §7's fidelity rule is
      ## "a perceptual distance below a threshold", and a threshold asserted
      ## over a mean hides one catastrophic cell in a field of good ones.

  CellGrid* = object
    cols*: int
    rows*: int
    cells*: seq[RenderedCell]    ## row-major, `cols * rows` long
    tier*: ImageTier
    fit*: CellFit
    candidatesEvaluated*: int

  CellRenderError* = object of CatchableError

const
  DefaultAsciiRamp* = " .:-=+*#%@"
    ## §2.5's "luminance ramp with a configurable character set". Ten steps,
    ## darkest first. ASCII-only by construction — tier 6 exists for `TERM=dumb`
    ## and for a CI log, so a ramp with a Unicode glyph in it would defeat the
    ## tier it belongs to.

  QuadrantGlyphs: array[16, string] = [
    " ",        # 0b0000
    "▘",   # 0b0001 TL          ▘
    "▝",   # 0b0010 TR          ▝
    "▀",   # 0b0011 TL+TR       ▀
    "▖",   # 0b0100 BL          ▖
    "▌",   # 0b0101 TL+BL       ▌
    "▞",   # 0b0110 TR+BL       ▞
    "▛",   # 0b0111 TL+TR+BL    ▛
    "▗",   # 0b1000 BR          ▗
    "▚",   # 0b1001 TL+BR       ▚
    "▐",   # 0b1010 TR+BR       ▐
    "▜",   # 0b1011 TL+TR+BR    ▜
    "▄",   # 0b1100 BL+BR       ▄
    "▙",   # 0b1101 TL+BL+BR    ▙
    "▟",   # 0b1110 TR+BL+BR    ▟
    "█"]   # 0b1111 all         █
    ## Bit `i` is sub-cell `(row i div 2, col i mod 2)` — the same row-major
    ## order `renderCells` samples in, so the table and the sampler cannot
    ## disagree about which corner bit 1 means.

  HalfBlockGlyphs: array[4, string] = [" ", "▀", "▄", "█"]
    ## Bit 0 is the top sample, bit 1 the bottom.

  BrailleDotBits: array[8, int] = [0x01, 0x08, 0x02, 0x10,
                                   0x04, 0x20, 0x40, 0x80]
    ## Index `i` is sub-cell `(row i div 2, col i mod 2)`; the value is the bit
    ## U+2800's encoding gives that dot. Braille numbers its dots 1-3 down the
    ## left column, 4-6 down the right, then 7 and 8 as the bottom row, which is
    ## NOT row-major — this array is the whole of that permutation and it is a
    ## table rather than arithmetic so it can be read against the standard.

func sextantGlyph(mask: int): string =
  ## U+1FB00-U+1FB3B, the Unicode 13 "BLOCK SEXTANT" run.
  ##
  ## The run covers the 60 masks that do NOT already have a legacy spelling:
  ## the empty cell (0), the two full columns (`0b010101` left, `0b101010`
  ## right) and the full cell (63) are U+0020, U+258C, U+2590 and U+2588. Every
  ## other mask is U+1FB00 plus its index with those four removed — which is
  ## the mapping the block's own chart states, and the arithmetic below is that
  ## sentence.
  if mask == 0: return " "
  if mask == 0b010101: return "▌"
  if mask == 0b101010: return "▐"
  if mask == 0b111111: return "█"
  var index = mask
  if mask > 0b101010: dec index
  if mask > 0b010101: dec index
  $Rune(0x1FB00 + index - 1)

func brailleGlyph(mask: int): string =
  var bits = 0
  for i in 0 ..< 8:
    if (mask and (1 shl i)) != 0:
      bits = bits or BrailleDotBits[i]
  $Rune(0x2800 + bits)

func glyphFor*(tier: ImageTier; mask: int): string =
  ## The glyph a sub-cell mask draws at a tier.
  ##
  ## RAISES for `itOctant` rather than returning a placeholder. See `tiers.nim`.
  case tier
  of itHalfBlock: HalfBlockGlyphs[mask]
  of itQuadrant: QuadrantGlyphs[mask]
  of itSextant: sextantGlyph(mask)
  of itBraille: brailleGlyph(mask)
  of itOctant:
    raise newException(CellRenderError,
      "image tier 'octant' (U+1CD00) is not implemented in this build: the " &
      "256 sub-cell masks map onto 230 code points because 26 masks have " &
      "legacy spellings, and this build carries no verified exception table. " &
      "An unverified table draws a DIFFERENT picture rather than a coarser " &
      "one. Pick --image-tier=sextant for 2x3, or --image-tier=braille for " &
      "2x4 shape resolution")
  of itProtocol:
    raise newException(CellRenderError,
      "image tier 'protocol' is a graphics-protocol emission, not a cell " &
      "rendering; call terminal_graphics/emit.emitProtocolImage instead")
  of itAscii:
    raise newException(CellRenderError,
      "image tier 'ascii' selects its glyph from a luminance ramp, not from " &
      "a sub-cell mask")

func asciiGlyph*(ramp: string; lum: float): string =
  ## §2.5's ramp lookup. `lum` is 0..1; the ramp is darkest-first.
  if ramp.len == 0:
    return " "
  let index = clamp(int(floor(lum * float(ramp.len))), 0, ramp.len - 1)
  $ramp[index]

type
  CellSamples = object
    ## The sub-cell colours of ONE cell, and their Oklab forms, computed once
    ## and reused across every candidate mask. Recomputing `toOklab` inside the
    ## argmin would make the loop's cost depend on the candidate count twice
    ## over, which is the "a bound on the wrong quantity" shape PLAT-12 paid
    ## for: the count would still be right and the work would not be.
    rgbs: seq[Rgb]
    labs: seq[Oklab]

func sourceRectOfSubCell*(sourceWidth, sourceHeight: int; fit: CellFit;
                          tier: ImageTier; gx, gy: int): PixelRect =
  ## The SOURCE-PIXEL rectangle one SUB-CELL covers, where `(gx, gy)` indexes
  ## the SUB-CELL grid — `fit.cols * subCell(tier).cols` wide by
  ## `fit.rows * subCell(tier).rows` tall.
  ##
  ## Computed from the SUB-CELL grid rather than from the cell grid, so the
  ## division happens once and the last cell's overhang is the clamp in
  ## `raster.pixelAt` rather than a rounding that would drop a column of
  ## pixels.
  ##
  ## EXPORTED BY PLAT-15, and the export is the point rather than a
  ## convenience. `magnifier.coarsePixelRect` has to say which source pixels a
  ## CELL covers — which is §5's entire argument for why a magnifier is needed
  ## at all — and a second copy of this arithmetic would be a second thing that
  ## can be wrong while its twin goes on agreeing with itself
  ## (Verification-Harness-Traps §14). There is one copy, `sampleCell` below
  ## calls it, and the magnifier calls the same function.
  let geom = subCell(tier)
  let subCols = max(1, fit.cols * geom.cols)
  let subRows = max(1, fit.rows * geom.rows)
  let x0 = gx * sourceWidth div subCols
  let x1 = max(x0 + 1, (gx + 1) * sourceWidth div subCols)
  let y0 = gy * sourceHeight div subRows
  let y1 = max(y0 + 1, (gy + 1) * sourceHeight div subRows)
  PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)

func sampleCell(img: RgbaImage; fit: CellFit; tier: ImageTier;
                col, row: int): CellSamples =
  let geom = subCell(tier)
  result.rgbs = newSeq[Rgb](geom.cols * geom.rows)
  result.labs = newSeq[Oklab](geom.cols * geom.rows)
  for sy in 0 ..< geom.rows:
    for sx in 0 ..< geom.cols:
      let gx = col * geom.cols + sx
      let gy = row * geom.rows + sy
      let r = sourceRectOfSubCell(img.width, img.height, fit, tier, gx, gy)
      let c = img.boxSample(r.x, r.y, r.x + r.width, r.y + r.height)
      let index = sy * geom.cols + sx
      result.rgbs[index] = c
      result.labs[index] = toOklab(c)

func meanOf(samples: seq[Rgb]; mask: int; want: bool): Rgb =
  var sr, sg, sb, n = 0
  for i in 0 ..< samples.len:
    let on = (mask and (1 shl i)) != 0
    if on == want:
      sr += int(samples[i].r)
      sg += int(samples[i].g)
      sb += int(samples[i].b)
      inc n
  if n == 0:
    return Rgb()
  rgb(int(round(sr / n)), int(round(sg / n)), int(round(sb / n)))

func bestTripleFor(tier: ImageTier; s: CellSamples;
                   evaluated: var int): RenderedCell =
  ## §2.3's argmin over the fixed candidate set.
  let n = s.rgbs.len
  let candidates = 1 shl n
  var bestMask = 0
  var bestFg = Rgb()
  var bestBg = Rgb()
  var bestErr = Inf
  for mask in 0 ..< candidates:
    inc evaluated
    var fg = meanOf(s.rgbs, mask, true)
    var bg = meanOf(s.rgbs, mask, false)
    # A mask with no "on" sub-pixels has no foreground and a mask with no "off"
    # sub-pixels has no background. Both are legitimate candidates (the empty
    # and the full glyph), and giving the absent half the OTHER half's colour
    # is what makes their error comparable with every other candidate's
    # instead of being decided by an arbitrary black.
    if mask == 0: fg = bg
    if mask == candidates - 1: bg = fg
    let fgLab = toOklab(fg)
    let bgLab = toOklab(bg)
    var err = 0.0
    for i in 0 ..< n:
      let on = (mask and (1 shl i)) != 0
      err += oklabDistanceSq(s.labs[i], if on: fgLab else: bgLab)
    # STRICTLY LESS, so the LOWEST mask wins a tie. Ties are common and the
    # rule matters: a uniform cell has zero error for every mask (both means
    # are the same colour), and the lowest mask is the empty glyph — one byte
    # instead of three, with the cell's colour carried by its background.
    # §3's bandwidth constraint is the reason to prefer the cheap spelling, and
    # a flat region of an image is exactly where the choice is made most often.
    if err < bestErr:
      bestErr = err
      bestMask = mask
      bestFg = fg
      bestBg = bg
  RenderedCell(glyph: glyphFor(tier, bestMask), fg: bestFg, bg: bestBg,
               errorSq: bestErr)

func renderCells*(img: RgbaImage; tier: ImageTier; fit: CellFit;
                  ramp = DefaultAsciiRamp): CellGrid =
  ## One raster into one grid of cells, at `tier`.
  ##
  ## `fit` carries the aspect correction (`aspect.fitToCells`) and this
  ## function never recomputes it: the correction is a property of the
  ## RENDERING and is on the model so a test can assert it, and a second
  ## derivation here would be a second answer to the same question.
  if tier notin CellRenderableTiers:
    # ONE PREDICATE AND ONE MESSAGE. `CellRenderableTiers` is the set a CALLER
    # asks before it paints (`app/views/frame_viewer.resolveGap`), so the
    # refusal here and the pre-check there are the same question asked through
    # the same function (Verification-Harness-Traps §14); and the diagnosis is
    # `glyphFor`'s, which already has an arm naming the reason for each of the
    # two non-members — the octant's missing table and tier 0's
    # `emit.emitProtocolImage`. This used to be two guards, the second of which
    # wrote a second protocol message beside the first; the pane that met it
    # could report neither.
    discard glyphFor(tier, 0)
  if fit.cols <= 0 or fit.rows <= 0:
    raise newException(CellRenderError,
      "cell fit is empty (" & $fit.cols & "x" & $fit.rows & "); " &
      describeAspect(fit))
  result = CellGrid(cols: fit.cols, rows: fit.rows, tier: tier, fit: fit,
                    cells: newSeq[RenderedCell](fit.cols * fit.rows),
                    candidatesEvaluated: 0)
  for row in 0 ..< fit.rows:
    for col in 0 ..< fit.cols:
      let s = sampleCell(img, fit, tier, col, row)
      if tier == itAscii:
        let c = s.rgbs[0]
        result.cells[row * fit.cols + col] =
          RenderedCell(glyph: asciiGlyph(ramp, luminance(c)), fg: c, bg: Rgb(),
                       errorSq: 0.0)
      else:
        result.cells[row * fit.cols + col] =
          bestTripleFor(tier, s, result.candidatesEvaluated)

func cellAt*(grid: CellGrid; col, row: int): RenderedCell =
  if col < 0 or row < 0 or col >= grid.cols or row >= grid.rows:
    raise newException(CellRenderError,
      "cell (" & $col & "," & $row & ") is outside a " & $grid.cols & "x" &
      $grid.rows & " grid")
  grid.cells[row * grid.cols + col]

func meanErrorSq*(grid: CellGrid): float =
  if grid.cells.len == 0: return 0.0
  var total = 0.0
  for c in grid.cells:
    total += c.errorSq
  total / float(grid.cells.len)

func maxErrorSq*(grid: CellGrid): float =
  for c in grid.cells:
    result = max(result, c.errorSq)
