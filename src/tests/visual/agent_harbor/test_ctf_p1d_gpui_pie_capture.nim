## test_ctf_p1d_gpui_pie_capture.nim — the progress pie's story as the GPUI
## window draws it (`Pie Indicator: Every State`, the captures
## `ci/test/ctf-p1b-gpui-story-capture.sh` takes into `build/ctf-p1b/gpui/`),
## and as the browser draws it when the web captures have been taken
## (`just ctf-p1b-web-captures`, `build/ctf-p1b/web/`): what antialiasing and
## pixel placement do to a pie, which a render plan cannot show.
##
## A pie is a ring in its role's ink with the wedge filled inside it in the
## same ink and the rest left as the ground. For every pie at 0 % and at 16 %
## (the first two columns of every role's row, on every band's ground), in
## both themes, at both sizes:
##
##   * a 0 % pie's REST is the ground: every pixel inside the ring that the
##     ring does not touch (`restPixels`) is within `GroundChannels` of the
##     ground the frame shows beside the pie, per channel -- a tinted rest,
##     or a role drawn as a filled rest disc, fails;
##   * a 16 % pie's WEDGE reads at native size: at least `WedgePixels` of
##     those pixels are at least `DotCoverage` of the way from the ground to
##     the ring's ink (the palette's `edge`) -- a wedge drawn in a mixed ink,
##     or one squeezed by a wider gap, fails. A 12 px pie's 16 % wedge on its
##     8 px disc covers 6 whole pixels by its geometry; the GPUI window and
##     Chromium both draw 6 or more on every ground.
##
## For every unknown pie (the last column of every role's row, on every
## band's ground), in both themes, at both sizes:
##
##   * its RING holds 3:1 against the ground where the frame drew it: the two
##     middle pixels of each side (top, bottom, left, right), each measured
##     with WCAG 2.2's contrast ratio
##     (https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio) against the ground
##     the frame shows beside the pie. The palette resolves the ring's ink at
##     3.3:1 so the 1 px ring's antialiased pixels keep 3:1
##     (SC 1.4.11, https://www.w3.org/TR/WCAG22/#non-text-contrast);
##   * its DOT draws three pixels of the full ink across its centre row, as
##     the web's does: each of the three is at least `DotCoverage` of the way
##     from the ground to the ink, and the pixels either side of them at most
##     `ClearCoverage` -- a dot placed on a half pixel draws two weak pixels
##     and fails.
##
## The pies are found from the `pie-first` region the capture records (the
## window band's first pie) and the story's grid (`PieStoryColumnsPx`,
## `PieStoryRowPx`, `PieStoryBandGapPx`, `pieStoryBands`), the numbers both
## the web and GPUI lay the story out by; the layout test
## (`test_ctf_p1b_gpui_capture_matches_web_layout.nim`) holds the grid where
## the web puts it.
##
## The web half reads the browser's PNGs and its regions and holds the
## ring-and-wedge measures above (the unknown pie's ring and dot measures
## are GPUI's: they were set against GPUI's placement and antialiasing), and
## is measured only when they are there: `just ctf-p1b-gpui-captures` (and
## the CI job that runs it) takes no web capture, so without them it says so
## and is skipped; with them it is held to the same measures with plain
## `check`s (not in the GPUI half's assertion count).
##
## Negative controls: the same measure over planted copies of a real frame,
## a ring pixel faded halfway to the ground, a dot shifted half a pixel
## (spread over four columns at half strength), a 0 % pie's rest tinted
## toward its ink, and a 16 % wedge faded toward the ground, must each fail.
##
## No mocks: real GPUI window and browser captures; the inks are the
## palette's.

import std/[json, math, os, strutils, unittest]

import ./ctf_layout_judge
import ../../../common/png
import ../../../frontend/stories/agent_harbor_pie_stories

const
  PieCaptureStem = "agent-harbor-pie-indicator-every-state"
  DotCoverage = 0.9
    ## A full-ink pixel of the dot: a 3 px round dot's edge pixels on its
    ## centre row are 97 % covered.
  ClearCoverage = 0.1
  RingFloor = 3.0
  GroundChannels = 2
    ## A rest pixel is the ground: no channel further from it than this.
  WedgePixels = 6
    ## The least full-ink pixels of a 16 % wedge at native size (12 px).

let gpuiDir = getEnv("CTF_P1B_GPUI_OUT", repoRoot / "build" / "ctf-p1b" / "gpui")
let webDir = getEnv("CTF_P1B_WEB_OUT", repoRoot / "build" / "ctf-p1b" / "web")

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's assertion count.
const ExpectedAssertions = 30

proc channels(hex: string): array[3, float] =
  for i in 0 .. 2: result[i] = parseHexInt(hex[1 + 2 * i .. 2 + 2 * i]).float

proc luminance(hex: string): float =
  ## WCAG 2 relative luminance (https://www.w3.org/TR/WCAG22/#dfn-relative-luminance).
  let c = channels(hex)
  for i, weight in [0.2126, 0.7152, 0.0722]:
    let v = c[i] / 255.0
    result += weight * (if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4))

proc ratio(a, b: string): float =
  let (x, y) = (luminance(a), luminance(b))
  (max(x, y) + 0.05) / (min(x, y) + 0.05)

proc coverage(pixel, ground, ink: string): float =
  ## How far `pixel` is from `ground` toward `ink`, 0 to 1: its projection on
  ## the line between them.
  let (p, g, k) = (channels(pixel), channels(ground), channels(ink))
  var num, den = 0.0
  for i in 0 .. 2:
    num += (p[i] - g[i]) * (k[i] - g[i])
    den += (k[i] - g[i]) * (k[i] - g[i])
  if den == 0: 0.0 else: num / den

type
  StoryPie = object
    at: string        ## the band, the row and the capture, for a message
    x, y: int         ## the pie's top-left pixel
    ink: string       ## its ring's ink (the palette's `edge`), the wedge's
                      ## and the dot's as drawn

proc pieSidePx(): int = PieStorySizePx

proc piesInColumn(regionsPath: string; mode: DesignMode; column: int): seq[StoryPie] =
  ## Every pie of one column of a capture, from its `pie-first` region and
  ## the story's grid.
  let doc = parseFile(regionsPath)
  let first = doc{"regions"}{"pie-first"}
  let x0 = first{"x"}.getFloat
  let y0 = first{"y"}.getFloat
  let x = int(round(x0 + pieColumnCentrePx(column) - pieColumnCentrePx(0)))
  let p = ahPalette(mode)
  for b, band in pieStoryBands("every-state", mode):
    let bandTop = y0 + float(b * (PieStoryRowPx * (1 + band.rows.len) + PieStoryBandGapPx))
    for r, row in band.rows:
      result.add StoryPie(
        at: $band.ground & " " & row.word & " " & PieStoryColumns[column],
        x: x, y: int(round(bandTop + float(r * PieStoryRowPx))),
        ink: p.pieInks(row.role, band.ground).edge)

proc unknownPies(regionsPath: string; mode: DesignMode): seq[StoryPie] =
  ## Every unknown pie in a capture (the last column).
  piesInColumn(regionsPath, mode, PieStoryColumns.high)

proc restPixels(): seq[(int, int)] =
  ## The pixels of a pie's box inside its ring that the ring does not touch:
  ## every corner within the ring's inner edge (`PieEdgePx` in from the
  ## rim). The wedge's disc and the gap around it are among them.
  let s = pieSidePx()
  let c = s.float / 2.0
  let inner = c - PieEdgePx.float
  for y in 0 ..< s:
    for x in 0 ..< s:
      var inside = true
      for (cx, cy) in [(x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)]:
        if hypot(cx.float - c, cy.float - c) > inner: inside = false
      if inside: result.add (x, y)

proc groundOf(f: Frame; pie: StoryPie): string =
  ## The ground the frame shows beside the pie, in its column.
  f.hexOf(pie.x - 4, pie.y + pieSidePx() div 2)

proc restProblems(f: Frame; pie: StoryPie): seq[string] =
  ## A 0 % pie: every rest pixel is the ground.
  let ground = f.groundOf(pie)
  for (dx, dy) in restPixels():
    let px = f.hexOf(pie.x + dx, pie.y + dy)
    if channelsApart(px, ground) > GroundChannels:
      result.add pie.at & ": rest pixel (" & $dx & ", " & $dy & ") " & px &
        " is not the ground " & ground

proc wedgePixels(f: Frame; pie: StoryPie): int =
  ## How many rest pixels are the ring's full ink.
  let ground = f.groundOf(pie)
  for (dx, dy) in restPixels():
    if coverage(f.hexOf(pie.x + dx, pie.y + dy), ground, pie.ink) >= DotCoverage: inc result

proc wedgeProblems(f: Frame; pie: StoryPie): seq[string] =
  ## A 16 % pie: its wedge draws at least `WedgePixels` full-ink pixels.
  let n = f.wedgePixels(pie)
  if n < WedgePixels:
    result.add pie.at & ": the 16 % wedge draws " & $n & " full-ink pixels of " & pie.ink &
      ", under " & $WedgePixels

proc ringProblems(f: Frame; pie: StoryPie): seq[string] =
  ## The ring's eight middle side pixels against the ground beside the pie.
  let s = pieSidePx()
  let ground = f.hexOf(pie.x - 4, pie.y + s div 2)
  let mid = [s div 2 - 1, s div 2]
  var samples: seq[(int, int)]
  for m in mid:
    samples.add (pie.x + m, pie.y)          # top
    samples.add (pie.x + m, pie.y + s - 1)  # bottom
    samples.add (pie.x, pie.y + m)          # left
    samples.add (pie.x + s - 1, pie.y + m)  # right
  for (x, y) in samples:
    let c = ratio(f.hexOf(x, y), ground)
    if c < RingFloor:
      result.add pie.at & ": ring pixel (" & $x & ", " & $y & ") " & f.hexOf(x, y) &
        " is " & formatFloat(c, ffDecimal, 2) & ":1 on " & ground

proc dotProblems(f: Frame; pie: StoryPie): seq[string] =
  ## The dot's centre row: three full-ink pixels, clear either side.
  let s = pieSidePx()
  let side = int(round(s.float * PieDotFraction))
  let left = int(floor((s - side).float / 2.0 + 0.5))
  let y = pie.y + left + side div 2
  let ground = f.hexOf(pie.x - 4, pie.y + s div 2)
  for k in 0 ..< side:
    let px = f.hexOf(pie.x + left + k, y)
    let c = coverage(px, ground, pie.ink)
    if c < DotCoverage:
      result.add pie.at & ": dot pixel " & $k & " " & px & " is " &
        formatFloat(c * 100, ffDecimal, 0) & "% of " & pie.ink
  for k in [left - 1, left + side]:
    let px = f.hexOf(pie.x + k, y)
    if coverage(px, ground, pie.ink) > ClearCoverage:
      result.add pie.at & ": the dot spreads to pixel " & $k & " " & px

proc captureProblems(f: Frame; pies: seq[StoryPie]): (seq[string], seq[string]) =
  for pie in pies:
    result[0].add f.ringProblems(pie)
    result[1].add f.dotProblems(pie)

proc captures(): seq[(string, DesignMode)] =
  for size in ["laptop", "sidebar"]:
    for (theme, mode) in [("dark", dmDark), ("light", dmLight)]:
      result.add (PieCaptureStem & "-" & size & "-" & theme, mode)

proc readPngFrame(path: string): Frame =
  ## A browser capture as a `Frame` (its alpha dropped: the page is opaque).
  let png = decodePng(readFile(path))
  result.width = png.width
  result.height = png.height
  result.rgb = newString(png.width * png.height * 3)
  for i in 0 ..< png.width * png.height:
    for k in 0 .. 2: result.rgb[i * 3 + k] = char(png.rgba[i * 4 + k])

type ShapeMeasure = object
  rests, wedges: seq[string]   ## the problems found
  zeroPies, sixteenPies: int   ## the pies measured
  leastWedge: int              ## the fewest full-ink pixels of a 16 % wedge

proc measureShapes(f: Frame; id, regions: string; mode: DesignMode;
                   m: var ShapeMeasure) =
  for pie in piesInColumn(regions, mode, 0):
    for p in f.restProblems(pie): m.rests.add id & " " & p
    inc m.zeroPies
  for pie in piesInColumn(regions, mode, 1):
    for p in f.wedgeProblems(pie): m.wedges.add id & " " & p
    m.leastWedge = min(m.leastWedge, f.wedgePixels(pie))
    inc m.sixteenPies

proc report(host: string; m: ShapeMeasure) =
  for p in m.rests: echo "  ", host, " REST ", p
  for p in m.wedges: echo "  ", host, " WEDGE ", p
  echo "  ", host, ": 0 % pies measured ", m.zeroPies, ", 16 % pies ", m.sixteenPies,
    ", the fewest full-ink wedge pixels ", m.leastWedge

suite "CTF-P1d: the GPUI window draws an unknown pie's ring and dot whole":
  test "every unknown pie, every ground, both themes, both sizes":
    var rings, dots: seq[string]
    var measured = 0
    for (id, mode) in captures():
      let ppm = gpuiDir / id & ".ppm"
      let regions = gpuiDir / id & ".regions.json"
      ck fileExists(ppm) and fileExists(regions)
      if not (fileExists(ppm) and fileExists(regions)): continue
      let f = readPpm(ppm)
      let pies = unknownPies(regions, mode)
      ck pies.len == 6 * pieStoryBands("every-state", mode).len
      let (r, d) = f.captureProblems(pies)
      for p in r: rings.add id & " " & p
      for p in d: dots.add id & " " & p
      measured += pies.len
    for p in rings: echo "  RING ", p
    for p in dots: echo "  DOT ", p
    echo "  unknown pies measured: ", measured
    ck measured == 2 * (6 * 4 + 6 * 5)
    ck rings.len == 0
    ck dots.len == 0

suite "CTF-P1d: the GPUI window draws every pie as a ring with its wedge inside":
  test "0 % is the ground inside the ring; 16 % reads, every ground, both themes and sizes":
    var m = ShapeMeasure(leastWedge: high(int))
    for (id, mode) in captures():
      let ppm = gpuiDir / id & ".ppm"
      let regions = gpuiDir / id & ".regions.json"
      ck fileExists(ppm) and fileExists(regions)
      if not (fileExists(ppm) and fileExists(regions)): continue
      readPpm(ppm).measureShapes(id, regions, mode, m)
    report("GPUI", m)
    ck m.zeroPies == 2 * (6 * 4 + 6 * 5)
    ck m.sixteenPies == m.zeroPies
    ck m.rests.len == 0
    ck m.wedges.len == 0

suite "CTF-P1d: the browser draws every pie as GPUI does (when the web captures are taken)":
  test "0 % is the ground inside the ring; 16 % reads":
    var missing: seq[string]
    for (id, _) in captures():
      for ext in [".png", ".regions.json"]:
        if not fileExists(webDir / id & ext): missing.add webDir / id & ext
    if missing.len > 0:
      echo "  web captures not taken (just ctf-p1b-web-captures): ", missing.len,
        " files missing, first ", missing[0]
      skip()
    else:
      var m = ShapeMeasure(leastWedge: high(int))
      for (id, mode) in captures():
        readPngFrame(webDir / id & ".png").measureShapes(id, webDir / id & ".regions.json", mode, m)
      report("web", m)
      check m.zeroPies == 2 * (6 * 4 + 6 * 5)
      check m.sixteenPies == m.zeroPies
      check m.rests.len == 0
      check m.wedges.len == 0

suite "CTF-P1d: the pie capture measure can fail":
  proc planted(): (Frame, StoryPie, string) =
    let (id, mode) = captures()[2]   # the sidebar in Dark
    let f = readPpm(gpuiDir / id & ".ppm")
    let pie = unknownPies(gpuiDir / id & ".regions.json", mode)[0]
    (f, pie, f.hexOf(pie.x - 4, pie.y + pieSidePx() div 2))

  proc put(f: var Frame; x, y: int; hex: string) =
    let o = (y * f.width + x) * 3
    let c = channels(hex)
    for i in 0 .. 2: f.rgb[o + i] = char(int(c[i]))

  proc between(a, b: string; t: float): string =
    let (x, y) = (channels(a), channels(b))
    result = "#"
    for i in 0 .. 2:
      result.add toHex(int(round(x[i] * (1 - t) + y[i] * t)), 2).toLowerAscii

  test "the untouched frame passes":
    let (f, pie, _) = planted()
    ck f.ringProblems(pie).len == 0
    ck f.dotProblems(pie).len == 0

  test "a ring pixel faded halfway to the ground fails":
    var (f, pie, ground) = planted()
    let top = (pie.x + pieSidePx() div 2, pie.y)
    f.put(top[0], top[1], between(f.hexOf(top[0], top[1]), ground, 0.6))
    ck f.ringProblems(pie).len == 1
    ck f.dotProblems(pie).len == 0

  test "a dot half a pixel off fails":
    var (f, pie, ground) = planted()
    let s = pieSidePx()
    let side = int(round(s.float * PieDotFraction))
    let left = int(floor((s - side).float / 2.0 + 0.5))
    let y = pie.y + left + side div 2
    # Three pixels moved half a pixel left: four columns, the outer two at
    # half strength and the inner two whole.
    f.put(pie.x + left - 1, y, between(ground, pie.ink, 0.5))
    f.put(pie.x + left + side - 1, y, between(ground, pie.ink, 0.5))
    ck f.dotProblems(pie).len >= 2
    ck f.ringProblems(pie).len == 0

  proc plantedColumn(column: int): (Frame, StoryPie, string) =
    let (id, mode) = captures()[2]   # the sidebar in Dark
    let f = readPpm(gpuiDir / id & ".ppm")
    let pie = piesInColumn(gpuiDir / id & ".regions.json", mode, column)[1]  # running
    (f, pie, f.groundOf(pie))

  test "the untouched 0 % and 16 % pies pass":
    let (f0, zero, _) = plantedColumn(0)
    ck f0.restProblems(zero).len == 0
    let (f1, sixteen, _) = plantedColumn(1)
    ck f1.wedgeProblems(sixteen).len == 0

  test "a 0 % pie's rest tinted a tenth toward its ink fails":
    var (f, pie, ground) = plantedColumn(0)
    for (dx, dy) in restPixels():
      f.put(pie.x + dx, pie.y + dy, between(ground, pie.ink, 0.1))
    ck f.restProblems(pie).len == restPixels().len

  test "a 16 % wedge faded a third toward the ground fails":
    var (f, pie, ground) = plantedColumn(1)
    for (dx, dy) in restPixels():
      let px = f.hexOf(pie.x + dx, pie.y + dy)
      if coverage(px, ground, pie.ink) >= DotCoverage:
        f.put(pie.x + dx, pie.y + dy, between(px, ground, 0.33))
    ck f.wedgePixels(pie) == 0
    ck f.wedgeProblems(pie).len == 1

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
