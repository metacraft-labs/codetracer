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
## ## `itOctant` DRAWS, FROM A TABLE VERIFIED AGAINST UNICODE 16
##
## U+1CD00-U+1CDE5 (Symbols for Legacy Computing Supplement, Unicode 16.0) is
## 230 `BLOCK OCTANT-<cells>` characters for the 256 masks of a 2x4 cell; the
## other 26 masks already had a spelling and the block skips them. See
## `octantGlyph` for the table and for how it was checked.
##
## ## DITHERING IS ERROR DIFFUSION OVER THE SUB-SAMPLE GRID, AND OPT-IN
##
## §2 names dithering beside quantisation. `renderCells(…, dither =
## dmDiffusion)` is Floyd–Steinberg over the grid of SUB-CELL samples: cells
## are decided in raster order, each sample enters the argmin with the error
## its decided neighbours pushed onto it, and once a cell's triple is chosen
## each sample's residual — what it asked for minus the colour its cell gave it
## — is spread 7/16 right, 3/16 below-left, 5/16 below and 1/16 below-right.
## A share that lands in a cell already decided (the current one, or one to
## its left on a row below inside the current cell row) is dropped rather than
## re-deciding it. At the ASCII tier the quantity diffused is LUMINANCE against
## the ramp step a glyph stands for (the middle of its bin), so a field between
## two steps comes out as a mix of both glyphs whose mean is the field's.
##
## WHAT IT CANNOT CHANGE, and the suite asserts both: a flat region has no
## residual, and a tier whose cell carries every sample exactly (the half
## block: two samples, two colours) has none either — so dithering costs those
## pictures nothing. The work bound is unchanged too: diffusion moves the
## samples the argmin sees, never how many candidates it evaluates.
##
## THE DEFAULT IS `dmNone`, because §5's magnifier must show each pixel's OWN
## colour (an EQUALITY against the source) and diffusion would move it. The
## frame viewer's picture asks for `dmDiffusion`; the magnifier never does.
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

  DitherMode* = enum
    ## Whether a cell rendering diffuses its quantisation error. See the
    ## module header.
    dmNone = "none"
    dmDiffusion = "diffusion"

  CellGrid* = object
    cols*: int
    rows*: int
    cells*: seq[RenderedCell]    ## row-major, `cols * rows` long
    tier*: ImageTier
    fit*: CellFit
    candidatesEvaluated*: int
    dither*: DitherMode
      ## The dithering this grid was rendered with, so a test reads it off the
      ## model rather than inferring it from the glyphs.

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

const
  OctantLegacyGlyphs: array[26, (int, string)] = [
    (0b00000000, " "),          # U+0020 SPACE
    (0b00000001, "\u{1CEA8}"),  # LEFT HALF UPPER ONE QUARTER BLOCK
    (0b00000010, "\u{1CEAB}"),  # RIGHT HALF UPPER ONE QUARTER BLOCK
    (0b00000011, "\u{1FB82}"),  # UPPER ONE QUARTER BLOCK
    (0b00000101, "▘"),     # U+2598 QUADRANT UPPER LEFT
    (0b00001010, "▝"),     # U+259D QUADRANT UPPER RIGHT
    (0b00001111, "▀"),     # U+2580 UPPER HALF BLOCK
    (0b00010100, "\u{1FBE6}"),  # MIDDLE LEFT ONE QUARTER BLOCK
    (0b00101000, "\u{1FBE7}"),  # MIDDLE RIGHT ONE QUARTER BLOCK
    (0b00111111, "\u{1FB85}"),  # UPPER THREE QUARTERS BLOCK
    (0b01000000, "\u{1CEA3}"),  # LEFT HALF LOWER ONE QUARTER BLOCK
    (0b01010000, "▖"),     # U+2596 QUADRANT LOWER LEFT
    (0b01010101, "▌"),     # U+258C LEFT HALF BLOCK
    (0b01011010, "▞"),     # U+259E QUADRANT UPPER RIGHT AND LOWER LEFT
    (0b01011111, "▛"),     # U+259B QUADRANT UPPER LEFT, UPPER RIGHT, LOWER LEFT
    (0b10000000, "\u{1CEA0}"),  # RIGHT HALF LOWER ONE QUARTER BLOCK
    (0b10100000, "▗"),     # U+2597 QUADRANT LOWER RIGHT
    (0b10100101, "▚"),     # U+259A QUADRANT UPPER LEFT AND LOWER RIGHT
    (0b10101010, "▐"),     # U+2590 RIGHT HALF BLOCK
    (0b10101111, "▜"),     # U+259C QUADRANT UPPER LEFT, UPPER RIGHT, LOWER RIGHT
    (0b11000000, "▂"),     # U+2582 LOWER ONE QUARTER BLOCK
    (0b11110000, "▄"),     # U+2584 LOWER HALF BLOCK
    (0b11110101, "▙"),     # U+2599 QUADRANT UPPER LEFT, LOWER LEFT, LOWER RIGHT
    (0b11111010, "▟"),     # U+259F QUADRANT UPPER RIGHT, LOWER LEFT, LOWER RIGHT
    (0b11111100, "▆"),     # U+2586 LOWER THREE QUARTERS BLOCK
    (0b11111111, "█")]     # U+2588 FULL BLOCK
    ## The 26 masks U+1CD00's run SKIPS, with the character Unicode 16 gives
    ## each instead. Bit `i` is octant `i + 1` in Unicode's numbering — 1 2 /
    ## 3 4 / 5 6 / 7 8, row-major — which is also `renderCells`' sampling order
    ## (`(row i div 2, col i mod 2)`), so no permutation sits between them.
    ##
    ## VERIFIED, NOT TRANSCRIBED FROM A CHART. `octant_table_unicode16.py`
    ## (beside this file) reads Unicode 16.0's character names from Python's
    ## `unicodedata` (3.14 carries UCD 16.0.0), parses every
    ## `BLOCK OCTANT-<cells>` name in U+1CD00-U+1CDE5 into its mask, checks the
    ## run is in increasing mask order with exactly these 26 masks absent, and
    ## checks each legacy character's NAME describes the cells its mask sets.
    ## `cell_render_test.nim` asserts the same table from the Nim side: all
    ## 256 glyphs distinct, the 230 in the run in mask order, these 26 by value.

func octantGlyph(mask: int): string =
  ## U+1CD00-U+1CDE5, the Unicode 16 `BLOCK OCTANT` run, or the legacy
  ## spelling of one of the 26 masks the run skips.
  ##
  ## The run is in increasing mask order, so a mask that is not legacy is
  ## U+1CD00 plus the number of non-legacy masks below it — the sextant run's
  ## arithmetic with a table of 26 skips instead of four.
  var skipped = 0
  for (legacyMask, glyph) in OctantLegacyGlyphs:
    if legacyMask == mask:
      return glyph
    if legacyMask < mask:
      inc skipped
  $Rune(0x1CD00 + mask - skipped)

func glyphFor*(tier: ImageTier; mask: int): string =
  ## The glyph a sub-cell mask draws at a tier.
  ##
  ## RAISES for the two tiers that have no mask table: tier 0 and ASCII.
  case tier
  of itHalfBlock: HalfBlockGlyphs[mask]
  of itQuadrant: QuadrantGlyphs[mask]
  of itSextant: sextantGlyph(mask)
  of itBraille: brailleGlyph(mask)
  of itOctant: octantGlyph(mask)
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

type
  DiffusionField = object
    ## The error pushed onto each SUB-CELL sample by its decided neighbours,
    ## in sRGB units per channel (luminance in `r` at the ASCII tier). Empty
    ## when the rendering does not dither.
    subCols, subRows: int
    err: seq[array[3, float]]

func initDiffusion(fit: CellFit; tier: ImageTier;
                   dither: DitherMode): DiffusionField =
  if dither == dmNone:
    return DiffusionField()
  let geom = subCell(tier)
  result.subCols = fit.cols * geom.cols
  result.subRows = fit.rows * geom.rows
  result.err = newSeq[array[3, float]](result.subCols * result.subRows)

func active(d: DiffusionField): bool = d.err.len > 0

func push(d: var DiffusionField; tier: ImageTier; gx, gy, col, row: int;
          residual: array[3, float]) =
  ## Floyd–Steinberg's four shares of one sample's residual, onto the samples
  ## that belong to cells not decided yet.
  let geom = subCell(tier)
  const shares = [(1, 0, 7.0 / 16.0), (-1, 1, 3.0 / 16.0),
                  (0, 1, 5.0 / 16.0), (1, 1, 1.0 / 16.0)]
  for (dx, dy, w) in shares:
    let tx = gx + dx
    let ty = gy + dy
    if tx < 0 or ty < 0 or tx >= d.subCols or ty >= d.subRows:
      continue
    let tc = tx div geom.cols
    let tr = ty div geom.rows
    if tr < row or (tr == row and tc <= col):
      continue   # a decided cell: its triple is chosen and stays chosen
    let i = ty * d.subCols + tx
    for k in 0 .. 2:
      d.err[i][k] += residual[k] * w

func sampleCell(img: RgbaImage; fit: CellFit; tier: ImageTier;
                col, row: int; diffusion: DiffusionField): CellSamples =
  let geom = subCell(tier)
  result.rgbs = newSeq[Rgb](geom.cols * geom.rows)
  result.labs = newSeq[Oklab](geom.cols * geom.rows)
  for sy in 0 ..< geom.rows:
    for sx in 0 ..< geom.cols:
      let gx = col * geom.cols + sx
      let gy = row * geom.rows + sy
      let r = sourceRectOfSubCell(img.width, img.height, fit, tier, gx, gy)
      var c = img.boxSample(r.x, r.y, r.x + r.width, r.y + r.height)
      if diffusion.active and tier != itAscii:
        # The error the decided neighbours pushed here, added before the
        # argmin sees the sample. (At the ASCII tier the error is luminance
        # and is added to the ramp lookup instead.)
        let e = diffusion.err[gy * diffusion.subCols + gx]
        c = rgb(int(round(float(c.r) + e[0])), int(round(float(c.g) + e[1])),
                int(round(float(c.b) + e[2])))
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
                   evaluated: var int; chosenMask: var int): RenderedCell =
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
  chosenMask = bestMask
  RenderedCell(glyph: glyphFor(tier, bestMask), fg: bestFg, bg: bestBg,
               errorSq: bestErr)

func renderCells*(img: RgbaImage; tier: ImageTier; fit: CellFit;
                  ramp = DefaultAsciiRamp; dither = dmNone): CellGrid =
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
    # `glyphFor`'s, which names the reason for the one non-member — tier 0,
    # whose bytes are `emit.emitProtocolImage`'s. This used to be two guards,
    # the second of which
    # wrote a second protocol message beside the first; the pane that met it
    # could report neither.
    discard glyphFor(tier, 0)
  if fit.cols <= 0 or fit.rows <= 0:
    raise newException(CellRenderError,
      "cell fit is empty (" & $fit.cols & "x" & $fit.rows & "); " &
      describeAspect(fit))
  result = CellGrid(cols: fit.cols, rows: fit.rows, tier: tier, fit: fit,
                    cells: newSeq[RenderedCell](fit.cols * fit.rows),
                    candidatesEvaluated: 0, dither: dither)
  var diffusion = initDiffusion(fit, tier, dither)
  let geom = subCell(tier)
  for row in 0 ..< fit.rows:
    for col in 0 ..< fit.cols:
      let s = sampleCell(img, fit, tier, col, row, diffusion)
      if tier == itAscii:
        let c = s.rgbs[0]
        var lum = luminance(c)
        if diffusion.active:
          lum += diffusion.err[row * diffusion.subCols + col][0]
        result.cells[row * fit.cols + col] =
          RenderedCell(glyph: asciiGlyph(ramp, lum), fg: c, bg: Rgb(),
                       errorSq: 0.0)
        if diffusion.active and ramp.len > 0:
          # The glyph stands for the middle of its ramp bin.
          let bin = clamp(int(floor(lum * float(ramp.len))), 0, ramp.len - 1)
          let level = (float(bin) + 0.5) / float(ramp.len)
          diffusion.push(tier, col, row, col, row, [lum - level, 0.0, 0.0])
      else:
        var mask = 0
        let cell = bestTripleFor(tier, s, result.candidatesEvaluated, mask)
        result.cells[row * fit.cols + col] = cell
        if diffusion.active:
          for sy in 0 ..< geom.rows:
            for sx in 0 ..< geom.cols:
              let i = sy * geom.cols + sx
              let given = if (mask and (1 shl i)) != 0: cell.fg else: cell.bg
              let asked = s.rgbs[i]
              diffusion.push(tier, col * geom.cols + sx, row * geom.rows + sy,
                             col, row,
                             [float(asked.r) - float(given.r),
                              float(asked.g) - float(given.g),
                              float(asked.b) - float(given.b)])

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
