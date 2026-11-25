## code_digits.nim — the code face's digits read by their outlines, for the
## GPUI binding (`ct_gui_binding.nim`).
##
## WHY. The OCR engine is the binding's only reader of text, and for a lone
## digit drawn in the code face it can be wrong while sounding sure. In the
## Variables pane `left:6 Int` read `value="8"`: at the pane's size the 6's
## top-right stroke closes against its bowl, and Tesseract answered 8 from
## the gray reading, the stretched one and a 4x ink-on-paper one alike
## (codetracer-pm issues/2026-11-25-the-gpui-scenario-binding-reads-a-
## variables-lone-digit-6-as-8.md). A binding reads by vision and declares
## what it cannot read; it never answers wrongly. So a digit the engine read
## is read again here, against the face's own glyphs, and either confirmed,
## corrected, or reported as unreadable.
##
## HOW. The window draws code in Space Mono Regular (`chrome.MonoFontFamily`,
## registered by `design_fonts.nim`). Its ten digit outlines are below, as
## the font file stores them: TrueType quadratic contours in font units
## (units per em 1000, y up), read from
## `libs/codetracer-design-system/SpaceGrotesk_Complete/Fonts/Space_Mono/
## SpaceMono-Regular.ttf` (fontRevision 1.003) with fontTools on 2026-11-25
## (`glyf` coordinates and on-curve flags of the cmap's `zero` … `nine`).
## Every digit is 612 units wide, so at 16 px the advance is the 9.792 px the
## binding already measures code columns with. Each is rasterised here at the
## face's size (its height at the share the window's hinting draws it,
## `HintedHeightScale`) with 8x8 supersampled coverage (non-zero winding, as
## TrueType fills) and compared with the frame's glyph, reduced to coverage
## of the glyph's colour over its ground, by zero-mean normalised
## cross-correlation over a small search of sub-pixel placements. The best
## digit is the reading only when it correlates well AND the glyph is
## clearly closer to it than to every close rival on the pixels where their
## outlines differ (`contrast`): at the window's size a 6 and an 8 differ in
## about one row of the top-right stroke, which a whole-patch correlation
## barely notices. Otherwise the glyph is not a digit this module can name.
## The TrueType outline format is described at
## https://learn.microsoft.com/en-us/typography/opentype/spec/glyf
## (on/off-curve points, implied on-curve midpoints between two off-curve
## points).
##
## Pure: no font file, no renderer and no OCR engine at run time.

import std/[algorithm, hashes, math, tables]

type
  OutlinePoint = (int, int, bool)
    ## A contour point in font units (y up) and whether it is on the curve.

  Coverage* = object
    ## How much of each pixel of a patch the glyph's ink covers, 0 … 1,
    ## row-major, y down.
    w*, h*: int
    a*: seq[float]

  DigitReading* = object
    digit*: int          ## 0 … 9, or -1 when no digit is a clear match
    score*: float        ## the best digit's correlation
    runnerUp*: float     ## the next best digit's correlation
    contrast*: float     ## the smallest `contrast` against a close rival

const
  SpaceMonoUnitsPerEm* = 1000.0
  SpaceMonoAdvanceUnits* = 612.0
    ## Every Space Mono glyph's advance (`hmtx`), digits included.
  MinScore* = 0.80
    ## The correlation a reading needs at all. Measured on the fixture of
    ## `code_digits_test.nim`: every digit glyph matches its own outline at
    ## 0.93 or more; no letter or operator of the face matches any digit
    ## above 0.69.
  MinContrast* = 0.06
    ## How much closer (mean coverage error, `contrast`) the glyph must be to
    ## the reading than to each close rival where their outlines differ. The
    ## nearest pairs of this face (6 and 8, 0 and 6, 5 and 6) are what it is
    ## for. Measured on the fixture of `code_digits_test.nim`: every digit
    ## glyph's contrast to its closest rival is 0.15 or more.
  CandidateWindow* = 0.15
    ## A rival is any digit whose correlation is within this of the best.
  HintedHeightScale* = 0.944
    ## The window's text system snaps a glyph's height to whole pixels: at
    ## 16 px a digit's outline (-14 … 714 units, 11.65 px) is drawn 11 px
    ## tall, while its width is as the outline says. Measured on the window's
    ## frames (the fixture of `code_digits_test.nim`): 11 / 11.65. The
    ## outlines are rendered at this share of their height; unhinted (1.0),
    ## an 8 of the call trace was barely told from a 6.
  DifferingCover = 0.3
    ## How far apart two outlines' coverage of a pixel must be for the pixel
    ## to tell them apart (`contrast`).
  Supersample = 8
  CurveSteps = 6

const
  SpaceMonoDigits: array[10, seq[seq[OutlinePoint]]] = [
  @[ # 0
    @[(306, -14, true), (191, -14, false), (60, 133, false), (60, 272, true), (60, 428, true),
      (60, 563, false), (191, 714, false), (306, 714, true), (422, 714, false), (552, 563, false),
      (552, 428, true), (552, 272, true), (552, 133, false), (422, -14, false)],
    @[(306, 62, true), (387, 62, false), (468, 176, false), (468, 278, true), (468, 422, true),
      (468, 518, false), (387, 638, false), (306, 638, true), (225, 638, false), (144, 518, false),
      (144, 422, true), (144, 278, true), (144, 176, false), (225, 62, false)],
    @[(306, 286, true), (281, 286, false), (242, 325, false), (242, 350, true), (242, 376, false),
      (281, 414, false), (306, 414, true), (332, 414, false), (370, 376, false), (370, 350, true),
      (370, 325, false), (332, 286, false)]],
  @[ # 1
    @[(71, 0, true), (71, 78, true), (269, 78, true), (269, 663, true), (257, 663, true),
      (142, 400, true), (59, 400, true), (59, 406, true), (190, 700, true), (353, 700, true),
      (353, 78, true), (551, 78, true), (551, 0, true)]],
  @[ # 2
    @[(70, 0, true), (70, 120, true), (70, 184, false), (126, 268, false), (228, 321, false),
      (298, 336, true), (387, 356, false), (466, 431, false), (466, 484, true), (466, 490, true),
      (466, 526, false), (434, 593, false), (365, 636, false), (310, 636, true), (234, 636, false),
      (148, 542, false), (148, 464, true), (148, 420, true), (64, 420, true), (64, 470, true),
      (64, 534, false), (120, 645, false), (230, 714, false), (310, 714, true), (391, 714, false),
      (497, 651, false), (550, 553, false), (550, 499, true), (550, 481, true), (550, 402, false),
      (450, 288, false), (340, 264, true), (245, 243, false), (154, 174, false), (154, 108, true),
      (154, 78, true), (544, 78, true), (544, 0, true)]],
  @[ # 3
    @[(317, -14, true), (238, -14, false), (124, 49, false), (63, 154, false), (63, 218, true),
      (63, 272, true), (147, 272, true), (147, 224, true), (147, 149, false), (243, 64, false),
      (315, 64, true), (359, 64, false), (430, 103, false), (471, 168, false), (471, 208, true),
      (471, 214, true), (471, 277, false), (391, 348, false), (331, 348, true), (237, 348, true),
      (237, 464, true), (465, 610, true), (465, 622, true), (69, 622, true), (69, 700, true),
      (537, 700, true), (537, 572, true), (309, 426, true), (309, 414, true), (349, 414, true),
      (402, 414, false), (496, 368, false), (555, 281, false), (555, 217, true), (555, 199, true),
      (555, 139, false), (493, 42, false), (385, -14, false)]],
  @[ # 4
    @[(373, 0, true), (373, 132, true), (49, 132, true), (49, 248, true), (294, 700, true),
      (457, 700, true), (457, 210, true), (565, 210, true), (565, 132, true), (457, 132, true),
      (457, 0, true)],
    @[(121, 210, true), (373, 210, true), (373, 664, true), (361, 664, true), (121, 222, true)]],
  @[ # 5
    @[(318, -14, true), (237, -14, false), (124, 48, false), (66, 156, false), (66, 224, true),
      (66, 252, true), (150, 252, true), (150, 230, true), (150, 148, false), (243, 64, false),
      (318, 64, true), (372, 64, false), (444, 114, false), (480, 195, false), (480, 242, true),
      (480, 248, true), (480, 289, false), (444, 356, false), (380, 396, false), (338, 396, true),
      (296, 396, false), (242, 353, false), (236, 330, true), (78, 330, true), (78, 700, true),
      (516, 700, true), (516, 622, true), (160, 622, true), (160, 372, true), (172, 372, true),
      (193, 413, false), (278, 474, false), (344, 474, true), (408, 474, false), (507, 419, false),
      (564, 319, false), (564, 252, true), (564, 234, true), (564, 168, false), (508, 55, false),
      (398, -14, false)]],
  @[ # 6
    @[(306, -14, true), (237, -14, false), (127, 45, false), (63, 149, false), (63, 217, true),
      (63, 472, true), (63, 546, false), (129, 655, false), (238, 714, false), (304, 714, true),
      (371, 714, false), (476, 661, false), (537, 563, false), (537, 496, true), (453, 496, true),
      (453, 561, false), (373, 640, false), (302, 640, true), (235, 640, false), (147, 547, false),
      (147, 472, true), (147, 368, true), (159, 368, true), (183, 412, false), (272, 462, false),
      (327, 462, true), (392, 462, false), (492, 407, false), (549, 304, false), (549, 232, true),
      (549, 220, true), (549, 151, false), (485, 46, false), (375, -14, false)],
    @[(306, 60, true), (379, 60, false), (465, 149, false), (465, 218, true), (465, 230, true),
      (465, 277, false), (424, 348, false), (352, 388, false), (306, 388, true), (261, 388, false),
      (189, 347, false), (147, 277, false), (147, 234, true), (147, 215, true), (147, 148, false),
      (233, 60, false)]],
  @[ # 7
    @[(120, 0, true), (120, 36, true), (120, 72, false), (150, 133, false), (181, 180, true),
      (468, 610, true), (468, 622, true), (72, 622, true), (72, 700, true), (540, 700, true),
      (540, 578, true), (245, 132, true), (224, 101, false), (202, 54, false), (202, 30, true),
      (202, 0, true)]],
  @[ # 8
    @[(297, -14, true), (227, -14, false), (121, 36, false), (63, 122, false), (63, 176, true),
      (63, 188, true), (63, 236, false), (101, 305, false), (160, 348, false), (193, 357, true),
      (193, 369, true), (148, 384, false), (81, 462, false), (81, 520, true), (81, 532, true),
      (81, 585, false), (137, 667, false), (237, 714, false), (303, 714, true), (309, 714, true),
      (375, 714, false), (475, 667, false), (531, 585, false), (531, 532, true), (531, 520, true),
      (531, 462, false), (464, 384, false), (419, 369, true), (419, 357, true), (452, 348, false),
      (511, 305, false), (549, 236, false), (549, 188, true), (549, 176, true), (549, 122, false),
      (491, 36, false), (386, -14, false), (315, -14, true)],
    @[(306, 402, true), (368, 402, false), (447, 469, false), (447, 518, true), (447, 524, true),
      (447, 575, false), (370, 638, false), (306, 638, true), (242, 638, false), (165, 575, false),
      (165, 524, true), (165, 518, true), (165, 469, false), (244, 402, false)],
    @[(300, 62, true), (312, 62, true), (380, 62, false), (465, 133, false), (465, 188, true),
      (465, 194, true), (465, 256, false), (378, 324, false), (309, 324, true), (303, 324, true),
      (234, 324, false), (147, 256, false), (147, 194, true), (147, 188, true), (147, 133, false),
      (233, 62, false)]],
  @[ # 9
    @[(308, -14, true), (239, -14, false), (134, 39, false), (75, 137, false), (75, 204, true),
      (159, 204, true), (159, 140, false), (240, 60, false), (310, 60, true), (378, 60, false),
      (465, 153, false), (465, 228, true), (465, 332, true), (453, 332, true), (431, 289, false),
      (344, 238, false), (287, 238, true), (222, 238, false), (121, 292, false), (63, 393, false),
      (63, 465, true), (63, 477, true), (63, 546, false), (126, 653, false), (236, 714, false),
      (306, 714, true), (377, 714, false), (486, 654, false), (549, 548, false), (549, 480, true),
      (549, 228, true), (549, 154, false), (485, 45, false), (376, -14, false)],
    @[(306, 312, true), (351, 312, false), (423, 352, false), (465, 420, false), (465, 463, true),
      (465, 482, true), (465, 527, false), (426, 598, false), (355, 640, false), (306, 640, true),
      (233, 640, false), (147, 548, false), (147, 479, true), (147, 467, true), (147, 397, false),
      (237, 312, false)]]]

type Polyline = seq[(float, float)]

func lerp(a, b: (float, float); t: float): (float, float) =
  (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)

func flatten(c: seq[OutlinePoint]): Polyline =
  ## One closed TrueType contour as a polyline in font units: lines between
  ## on-curve points, quadratic Béziers through each off-curve point, and an
  ## implied on-curve point midway between two consecutive off-curve ones.
  let n = c.len
  if n == 0: return
  proc pt(i: int): (float, float) = (float(c[i mod n][0]), float(c[i mod n][1]))
  proc on(i: int): bool = c[i mod n][2]
  var s = -1
  for i in 0 ..< n:
    if on(i):
      s = i
      break
  var start: (float, float)
  var first: int                 ## the first point after `start`
  if s >= 0:
    start = pt(s)
    first = s + 1
  else:
    start = lerp(pt(0), pt(1), 0.5)
    first = 1
  result.add start
  var cur = start
  var i = first
  let last = first + n - 1       ## the contour's points after `start`, once
  while i <= last:
    if on(i):
      cur = pt(i)
      result.add cur
      inc i
    else:
      let ctrl = pt(i)
      let nextOn = i + 1 > last or on(i + 1)
      let endp = if i + 1 > last: start
                 elif on(i + 1): pt(i + 1)
                 else: lerp(ctrl, pt(i + 1), 0.5)
      for k in 1 .. CurveSteps:
        let t = float(k) / float(CurveSteps)
        result.add lerp(lerp(cur, ctrl, t), lerp(ctrl, endp, t), t)
      cur = endp
      i += (if nextOn and i + 1 <= last: 2 else: 1)
  if result[^1] != start: result.add start

func flattenAll(): array[10, seq[Polyline]] =
  for d in 0 .. 9:
    for c in SpaceMonoDigits[d]: result[d].add flatten(c)

const DigitPolylines = flattenAll()

func render*(digit: int; px, ox, oy: float; w, h: int; pyScale = 1.0): Coverage =
  ## `digit` drawn at `px` pixels per em with its origin (the baseline's left
  ## end) at (`ox`, `oy`) in a `w` x `h` patch, as coverage.
  result = Coverage(w: w, h: h, a: newSeq[float](w * h))
  let s = px / SpaceMonoUnitsPerEm
  let sy = s * pyScale
  var edges: seq[(float, float, float, float)]
  for pl in DigitPolylines[digit]:
    for k in 0 ..< pl.len - 1:
      let (x0, y0) = pl[k]
      let (x1, y1) = pl[k + 1]
      if y0 != y1:
        edges.add (ox + x0 * s, oy - y0 * sy, ox + x1 * s, oy - y1 * sy)
  const unit = 1.0 / float(Supersample * Supersample)
  var xs: seq[(float, int)]
  for sy in 0 ..< h * Supersample:
    let yc = (float(sy) + 0.5) / float(Supersample)
    xs.setLen 0
    for (x0, y0, x1, y1) in edges:
      if (y0 <= yc and yc < y1) or (y1 <= yc and yc < y0):
        xs.add (x0 + (yc - y0) * (x1 - x0) / (y1 - y0), (if y1 > y0: 1 else: -1))
    if xs.len < 2: continue
    xs.sort(proc (a, b: (float, int)): int = cmp(a[0], b[0]))
    var wind = 0
    let row = (sy div Supersample) * w
    for k in 0 ..< xs.len - 1:
      wind += xs[k][1]
      if wind == 0: continue
      let a = max(0, int(ceil(xs[k][0] * float(Supersample) - 0.5)))
      let b = min(w * Supersample, int(ceil(xs[k + 1][0] * float(Supersample) - 0.5)))
      for sx in a ..< b:
        result.a[row + sx div Supersample] += unit

func centroid*(c: Coverage): (float, float, float) =
  ## The coverage-weighted centre of a patch's ink, in pixel coordinates
  ## (pixel centres at +0.5), and its total.
  var sx, sy, t = 0.0
  for y in 0 ..< c.h:
    for x in 0 ..< c.w:
      let v = c.a[y * c.w + x]
      sx += v * (float(x) + 0.5)
      sy += v * (float(y) + 0.5)
      t += v
  if t <= 0: return (0.0, 0.0, 0.0)
  (sx / t, sy / t, t)

func correlation(a, b: seq[float]): float =
  ## Zero-mean normalised cross-correlation, -1 … 1 (0 when either is flat).
  let n = float(a.len)
  var ma, mb = 0.0
  for i in 0 ..< a.len:
    ma += a[i]
    mb += b[i]
  ma /= n
  mb /= n
  var num, da, db = 0.0
  for i in 0 ..< a.len:
    let u = a[i] - ma
    let v = b[i] - mb
    num += u * v
    da += u * u
    db += v * v
  if da <= 1e-9 or db <= 1e-9: return 0.0
  num / sqrt(da * db)

type Placement* = object
  ## A digit's outline where it matches a glyph best.
  score*: float          ## the correlation there
  ox*, oy*: float        ## the outline's origin in the glyph's patch

func place*(glyph: Coverage; digit: int; px: float; gx, gy: float; pyScale = 1.0): Placement =
  ## Where `digit` matches the glyph best, and how well: the outline's ink
  ## centre put on the glyph's, then moved half a pixel at a time up to a
  ## pixel each way, and refined by a quarter pixel around the best.
  let margin = 2.0 * px
  let probe = render(digit, px, margin, margin + px, int(px * 4), int(px * 4), pyScale)
  let (tx, ty, _) = centroid(probe)
  let ox0 = gx - (tx - margin)
  let oy0 = gy - (ty - margin - px)
  result = Placement(score: -2.0)
  proc consider(r: var Placement; ox, oy: float) =
    let s = correlation(glyph.a, render(digit, px, ox, oy, glyph.w, glyph.h, pyScale).a)
    if s > r.score: r = Placement(score: s, ox: ox, oy: oy)
  for iy in -2 .. 2:
    for ix in -2 .. 2:
      result.consider(ox0 + float(ix) * 0.5, oy0 + float(iy) * 0.5)
  let (cx, cy) = (result.ox, result.oy)
  for iy in -1 .. 1:
    for ix in -1 .. 1:
      if ix != 0 or iy != 0:
        result.consider(cx + float(ix) * 0.25, cy + float(iy) * 0.25)

func contrast*(glyph: Coverage; px: float; a: int; pa: Placement; b: int; pb: Placement;
               pyScale = 1.0): float =
  ## How much closer the glyph is to digit `a` than to digit `b` where the
  ## two outlines differ: the mean absolute coverage error against `b` less
  ## the one against `a`, over the pixels one of them covers and the other
  ## does not (at least `DifferingCover` apart). The whole-patch correlation
  ## is dominated by what close digits share (the bowl of a 3, 5, 6, 8 and
  ## 9); this looks only at the strokes that tell them apart. 0 when the two
  ## outlines differ on too few pixels to say.
  let ta = render(a, px, pa.ox, pa.oy, glyph.w, glyph.h, pyScale).a
  let tb = render(b, px, pb.ox, pb.oy, glyph.w, glyph.h, pyScale).a
  var ea, eb = 0.0
  var n = 0
  for i in 0 ..< glyph.a.len:
    if abs(ta[i] - tb[i]) >= DifferingCover:
      ea += abs(glyph.a[i] - ta[i])
      eb += abs(glyph.a[i] - tb[i])
      inc n
  if n < 3: return 0.0
  (eb - ea) / float(n)

func contrastOf*(glyph: Coverage; px: float; a, b: int; pyScale = 1.0): float =
  ## `contrast` of digits `a` and `b`, each at its own best placement.
  let (gx, gy, _) = centroid(glyph)
  contrast(glyph, px, a, place(glyph, a, px, gx, gy, pyScale), b,
           place(glyph, b, px, gx, gy, pyScale), pyScale)

func digitScores*(glyph: Coverage; px: float; pyScale = HintedHeightScale): array[10, float] =
  ## Each digit's correlation with `glyph` at its best placement (all -1 when
  ## the patch holds no ink).
  for d in 0 .. 9: result[d] = -1.0
  let (gx, gy, total) = centroid(glyph)
  if total < 1.0 or glyph.w <= 0 or glyph.h <= 0: return
  for d in 0 .. 9: result[d] = place(glyph, d, px, gx, gy, pyScale).score

func readDigit*(glyph: Coverage; px: float; pyScale = HintedHeightScale): DigitReading =
  ## The digit `glyph` is, drawn in Space Mono at `px` pixels per em: the
  ## digit whose outline correlates best, when that is good (`MinScore`) and
  ## the glyph is clearly closer to it than to every digit that correlates
  ## nearly as well (`contrast` at least `MinContrast` against each digit
  ## within `CandidateWindow` of it). Otherwise -1.
  result = DigitReading(digit: -1, score: -1.0, runnerUp: -1.0, contrast: 0.0)
  let (gx, gy, total) = centroid(glyph)
  if total < 1.0 or glyph.w <= 0 or glyph.h <= 0: return
  var p: array[10, Placement]
  var best = 0
  for d in 0 .. 9:
    p[d] = place(glyph, d, px, gx, gy, pyScale)
    if p[d].score > p[best].score: best = d
  result.score = p[best].score
  result.contrast = 1.0
  for d in 0 .. 9:
    if d == best: continue
    result.runnerUp = max(result.runnerUp, p[d].score)
    if p[d].score >= p[best].score - CandidateWindow:
      result.contrast = min(result.contrast,
                            contrast(glyph, px, best, p[best], d, p[d], pyScale))
  if result.score >= MinScore and result.contrast >= MinContrast:
    result.digit = best

var readings {.threadvar.}: Table[Hash, DigitReading]

proc readDigitCached*(glyph: Coverage; px: float): DigitReading =
  ## `readDigit`, remembered per glyph patch: a wait reads the same rows of
  ## the same pane over and over.
  let k = hash(glyph.a) !& hash(glyph.w) !& hash(px)
  if readings.hasKey(k): return readings[k]
  result = readDigit(glyph, px)
  if readings.len > 4096: readings.clear()
  readings[k] = result
