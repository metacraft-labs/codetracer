## path_raster.nim — PLAT-48 deliverable 4 (`graphics` icons). SVG PATH DATA
## TO PIXELS, so the desktop's own debugger marks can be drawn in a medium
## that has no SVG renderer: the terminal's image tiers.
##
## The desktop draws its toolbar marks as inline SVG
## (`viewmodel/views/debug_control_marks.ControlMarks`): `<path>`s in a
## viewBox, each filled or stroked in `currentColor`. This module rasterises
## exactly that — the SAME path strings, not a redrawing — into an
## `RgbaImage`, which `cell_render.renderCells` turns into cells at any cell
## tier and a terminal-graphics protocol can transmit as pixels. So a
## `graphics` control in the terminal is the desktop's mark, drawn.
##
## ## What it supports, stated exactly
##
##   * path commands `M L H V C S Q T A Z`, absolute and relative, implicit
##     repeats, the number spellings SVG allows (`-7.8281e-08`, `.5`, a
##     leading sign that separates two numbers);
##   * fill with the non-zero winding rule (SVG's default `fill-rule`);
##   * stroke of a given width with `butt` or `round` caps. Joins are ROUND
##     (the union of each segment's stroke). The marks' strokes are 1–1.6
##     units wide on 16-unit boxes, so a mitred join differs from a round one
##     by well under a pixel at icon size; said here rather than hidden.
##   * `viewBox` mapping with `xMidYMid meet`, the SVG default.
##   * 4x4 supersampling for anti-aliased edges.
##
## Pure: floats in, bytes out, no I/O. C and JavaScript backends.

import std/[math, strutils]

import ./raster

type
  PathPoint = tuple[x, y: float]

  SubPath = object
    points: seq[PathPoint]
    closed: bool

  MarkShape* = object
    ## One `<path>`: its data, and how it is painted.
    d*: string
    stroked*: bool
    strokeWidth*: float
    roundCaps*: bool

  PathSyntaxError* = object of CatchableError

const
  CurveSegments = 16
  Supersample* = 4

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

type Tokenizer = object
  s: string
  i: int

proc skipSeparators(t: var Tokenizer) =
  while t.i < t.s.len and t.s[t.i] in {' ', ',', '\t', '\n', '\r'}:
    inc t.i

proc atNumber(t: var Tokenizer): bool =
  t.skipSeparators()
  t.i < t.s.len and t.s[t.i] in {'0' .. '9', '-', '+', '.'}

proc number(t: var Tokenizer): float =
  t.skipSeparators()
  let start = t.i
  if t.i < t.s.len and t.s[t.i] in {'-', '+'}:
    inc t.i
  var sawDot = false
  while t.i < t.s.len:
    let c = t.s[t.i]
    if c in {'0' .. '9'}:
      inc t.i
    elif c == '.' and not sawDot:
      sawDot = true
      inc t.i
    elif c in {'e', 'E'}:
      inc t.i
      if t.i < t.s.len and t.s[t.i] in {'-', '+'}:
        inc t.i
      while t.i < t.s.len and t.s[t.i] in {'0' .. '9'}:
        inc t.i
      break
    else:
      break
  if t.i == start:
    raise newException(PathSyntaxError, "a number was expected at " &
                       $start & " in '" & t.s & "'")
  parseFloat(t.s[start ..< t.i])

proc flag(t: var Tokenizer): bool =
  ## An arc flag: a single `0` or `1`, which SVG lets run into the next number.
  t.skipSeparators()
  if t.i < t.s.len and t.s[t.i] in {'0', '1'}:
    result = t.s[t.i] == '1'
    inc t.i
  else:
    raise newException(PathSyntaxError, "an arc flag was expected in '" &
                       t.s & "'")

proc cubic(p0, p1, p2, p3: PathPoint; acc: var seq[PathPoint]) =
  for k in 1 .. CurveSegments:
    let t = float(k) / float(CurveSegments)
    let u = 1.0 - t
    acc.add (x: u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x,
             y: u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y)

proc quadratic(p0, p1, p2: PathPoint; acc: var seq[PathPoint]) =
  for k in 1 .. CurveSegments:
    let t = float(k) / float(CurveSegments)
    let u = 1.0 - t
    acc.add (x: u*u*p0.x + 2*u*t*p1.x + t*t*p2.x,
             y: u*u*p0.y + 2*u*t*p1.y + t*t*p2.y)

proc arc(p0: PathPoint; rx0, ry0, phiDeg: float; large, sweep: bool;
         p1: PathPoint; acc: var seq[PathPoint]) =
  ## SVG's endpoint parameterisation, converted to centre form
  ## (SVG 1.1 implementation notes, F.6.5) and flattened.
  if p0 == p1:
    return
  var rx = abs(rx0)
  var ry = abs(ry0)
  if rx == 0 or ry == 0:
    acc.add p1
    return
  let phi = degToRad(phiDeg)
  let cp = cos(phi)
  let sp = sin(phi)
  let dx = (p0.x - p1.x) / 2
  let dy = (p0.y - p1.y) / 2
  let x1 = cp * dx + sp * dy
  let y1 = -sp * dx + cp * dy
  let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
  if lambda > 1:
    rx *= sqrt(lambda)
    ry *= sqrt(lambda)
  let num = rx*rx*ry*ry - rx*rx*y1*y1 - ry*ry*x1*x1
  let den = rx*rx*y1*y1 + ry*ry*x1*x1
  var coef = if den == 0: 0.0 else: sqrt(max(0.0, num / den))
  if large == sweep:
    coef = -coef
  let cx1 = coef * rx * y1 / ry
  let cy1 = -coef * ry * x1 / rx
  let cx = cp * cx1 - sp * cy1 + (p0.x + p1.x) / 2
  let cy = sp * cx1 + cp * cy1 + (p0.y + p1.y) / 2
  proc angle(ux, uy, vx, vy: float): float =
    let a = arctan2(ux * vy - uy * vx, ux * vx + uy * vy)
    a
  let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
  var dtheta = angle((x1 - cx1) / rx, (y1 - cy1) / ry,
                     (-x1 - cx1) / rx, (-y1 - cy1) / ry)
  if not sweep and dtheta > 0:
    dtheta -= 2 * PI
  elif sweep and dtheta < 0:
    dtheta += 2 * PI
  let steps = max(4, int(ceil(abs(dtheta) / (PI / 2) * CurveSegments / 2)))
  for k in 1 .. steps:
    let th = theta1 + dtheta * float(k) / float(steps)
    let ex = rx * cos(th)
    let ey = ry * sin(th)
    acc.add (x: cp * ex - sp * ey + cx, y: sp * ex + cp * ey + cy)

proc parsePath*(d: string): seq[seq[PathPoint]] =
  ## The path flattened to polylines, one per subpath. A closed subpath's last
  ## point equals its first.
  var t = Tokenizer(s: d, i: 0)
  var subs: seq[SubPath] = @[]
  var cur: PathPoint = (0.0, 0.0)
  var start: PathPoint = (0.0, 0.0)
  var lastCtrl: PathPoint = (0.0, 0.0)
  var lastCmd = ' '
  var cmd = ' '
  template ensureSub() =
    if subs.len == 0:
      subs.add SubPath(points: @[cur])
  while true:
    t.skipSeparators()
    if t.i >= t.s.len:
      break
    let c = t.s[t.i]
    if c.isAlphaAscii:
      cmd = c
      inc t.i
    elif cmd == ' ':
      raise newException(PathSyntaxError, "path data must start with a " &
                         "command: '" & d & "'")
    let rel = cmd.isLowerAscii
    let base = if rel: cur else: (x: 0.0, y: 0.0)
    case cmd.toUpperAscii
    of 'M':
      let p = (x: base.x + t.number(), y: base.y + t.number())
      cur = p
      start = p
      subs.add SubPath(points: @[p])
      # Implicit repeats of a moveto are linetos.
      cmd = if rel: 'l' else: 'L'
    of 'L':
      ensureSub()
      cur = (x: base.x + t.number(), y: base.y + t.number())
      subs[^1].points.add cur
    of 'H':
      ensureSub()
      cur = (x: base.x + t.number(), y: cur.y)
      subs[^1].points.add cur
    of 'V':
      ensureSub()
      cur = (x: cur.x, y: (if rel: cur.y else: 0.0) + t.number())
      subs[^1].points.add cur
    of 'C':
      ensureSub()
      let p1 = (x: base.x + t.number(), y: base.y + t.number())
      let p2 = (x: base.x + t.number(), y: base.y + t.number())
      let p3 = (x: base.x + t.number(), y: base.y + t.number())
      cubic(cur, p1, p2, p3, subs[^1].points)
      lastCtrl = p2
      cur = p3
    of 'S':
      ensureSub()
      let p1 =
        if lastCmd.toUpperAscii in {'C', 'S'}:
          (x: 2 * cur.x - lastCtrl.x, y: 2 * cur.y - lastCtrl.y)
        else: cur
      let p2 = (x: base.x + t.number(), y: base.y + t.number())
      let p3 = (x: base.x + t.number(), y: base.y + t.number())
      cubic(cur, p1, p2, p3, subs[^1].points)
      lastCtrl = p2
      cur = p3
    of 'Q':
      ensureSub()
      let p1 = (x: base.x + t.number(), y: base.y + t.number())
      let p2 = (x: base.x + t.number(), y: base.y + t.number())
      quadratic(cur, p1, p2, subs[^1].points)
      lastCtrl = p1
      cur = p2
    of 'T':
      ensureSub()
      let p1 =
        if lastCmd.toUpperAscii in {'Q', 'T'}:
          (x: 2 * cur.x - lastCtrl.x, y: 2 * cur.y - lastCtrl.y)
        else: cur
      let p2 = (x: base.x + t.number(), y: base.y + t.number())
      quadratic(cur, p1, p2, subs[^1].points)
      lastCtrl = p1
      cur = p2
    of 'A':
      ensureSub()
      let rx = t.number()
      let ry = t.number()
      let rot = t.number()
      let large = t.flag()
      let sweep = t.flag()
      let p = (x: base.x + t.number(), y: base.y + t.number())
      arc(cur, rx, ry, rot, large, sweep, p, subs[^1].points)
      cur = p
    of 'Z':
      if subs.len > 0:
        subs[^1].closed = true
        if subs[^1].points[^1] != start:
          subs[^1].points.add start
      cur = start
      # A command after Z starts at the subpath's start point.
      lastCmd = cmd
      cmd = ' '
      continue
    else:
      raise newException(PathSyntaxError, "unsupported path command '" & cmd &
                         "' in '" & d & "'")
    lastCmd = cmd
    # A command letter must be followed by its numbers; stop a malformed
    # string rather than loop on it.
    if not t.atNumber() and t.i < t.s.len and not t.s[t.i].isAlphaAscii:
      raise newException(PathSyntaxError, "unexpected '" & t.s[t.i] &
                         "' in '" & d & "'")
  for s in subs:
    if s.points.len > 0:
      result.add s.points

# ---------------------------------------------------------------------------
# Coverage
# ---------------------------------------------------------------------------

func winding(polys: seq[seq[PathPoint]]; x, y: float): int =
  ## The non-zero winding number of `(x, y)` with every subpath closed.
  for poly in polys:
    let n = poly.len
    if n < 2:
      continue
    for k in 0 ..< n:
      let a = poly[k]
      let b = poly[(k + 1) mod n]
      if a.y <= y:
        if b.y > y and (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y) > 0:
          inc result
      elif b.y <= y and (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y) < 0:
        dec result

func onStroke(polys: seq[seq[PathPoint]]; x, y, half: float;
              roundCaps: bool): bool =
  for poly in polys:
    for k in 0 ..< poly.len - 1:
      let a = poly[k]
      let b = poly[k + 1]
      let dx = b.x - a.x
      let dy = b.y - a.y
      let len2 = dx * dx + dy * dy
      var t = if len2 == 0: 0.0 else: ((x - a.x) * dx + (y - a.y) * dy) / len2
      let isFirst = k == 0
      let isLast = k == poly.len - 2
      let closed = poly.len > 2 and poly[0] == poly[^1]
      # A butt cap ends the stroke flush at the path's open ends; interior
      # vertices are joined round (the union of the neighbours' strokes).
      if not roundCaps and not closed:
        if isFirst and t < 0: continue
        if isLast and t > 1: continue
      t = clamp(t, 0.0, 1.0)
      let px = a.x + t * dx - x
      let py = a.y + t * dy - y
      if px * px + py * py <= half * half:
        return true
  false

func parseViewBox*(s: string): tuple[x, y, w, h: float] =
  let parts = s.splitWhitespace()
  if parts.len != 4:
    return (0.0, 0.0, 16.0, 16.0)
  (parseFloat(parts[0]), parseFloat(parts[1]), parseFloat(parts[2]),
   parseFloat(parts[3]))

proc rasterizeShapes*(shapes: openArray[MarkShape]; viewBox: string;
                      width, height: int; ink, ground: Rgb;
                      groundAlpha: uint8 = 255): RgbaImage =
  ## The shapes painted in `ink` over `ground`, `width` x `height` pixels, the
  ## viewBox fitted `xMidYMid meet`. `groundAlpha = 0` gives a transparent
  ## ground (the ink's coverage is then the alpha channel).
  let vb = parseViewBox(viewBox)
  let scale = min(float(width) / vb.w, float(height) / vb.h)
  let offX = (float(width) - vb.w * scale) / 2
  let offY = (float(height) - vb.h * scale) / 2
  var parsed: seq[tuple[polys: seq[seq[PathPoint]], shape: MarkShape]] = @[]
  for s in shapes:
    parsed.add (polys: parsePath(s.d), shape: s)
  var pixels = newSeq[byte](width * height * 4)
  let n = Supersample * Supersample
  for py in 0 ..< height:
    for px in 0 ..< width:
      var hits = 0
      for sy in 0 ..< Supersample:
        for sx in 0 ..< Supersample:
          let fx = float(px) + (float(sx) + 0.5) / Supersample
          let fy = float(py) + (float(sy) + 0.5) / Supersample
          # Back into viewBox units.
          let ux = (fx - offX) / scale + vb.x
          let uy = (fy - offY) / scale + vb.y
          var covered = false
          for (polys, shape) in parsed:
            if shape.stroked:
              if onStroke(polys, ux, uy, shape.strokeWidth / 2,
                          shape.roundCaps):
                covered = true
            elif winding(polys, ux, uy) != 0:
              covered = true
            if covered:
              break
          if covered:
            inc hits
      let cov = hits / n
      let base = (py * width + px) * 4
      if groundAlpha == 0:
        pixels[base] = ink.r
        pixels[base + 1] = ink.g
        pixels[base + 2] = ink.b
        pixels[base + 3] = uint8(round(cov * 255))
      else:
        pixels[base] = uint8(round(float(ground.r) * (1 - cov) +
                                   float(ink.r) * cov))
        pixels[base + 1] = uint8(round(float(ground.g) * (1 - cov) +
                                       float(ink.g) * cov))
        pixels[base + 2] = uint8(round(float(ground.b) * (1 - cov) +
                                       float(ink.b) * cov))
        pixels[base + 3] = groundAlpha
  initRgbaImage(width, height, pixels)

func coverage*(img: RgbaImage; ground: Rgb): float =
  ## How much of the image differs from `ground` — the fraction of pixels
  ## that carry ink. A test's measure that a picture was drawn at all.
  var inked = 0
  for y in 0 ..< img.height:
    for x in 0 ..< img.width:
      if img.pixelAt(x, y) != ground:
        inc inked
  inked / (img.width * img.height)

func parseHexRgb*(hex: string): Rgb =
  ## `#rrggbb` (or `rrggbb`) as an `Rgb`; black for anything else.
  let h = if hex.startsWith("#"): hex[1 .. ^1] else: hex
  if h.len < 6:
    return rgb(0, 0, 0)
  try:
    rgb(parseHexInt(h[0 .. 1]), parseHexInt(h[2 .. 3]), parseHexInt(h[4 .. 5]))
  except ValueError:
    rgb(0, 0, 0)
