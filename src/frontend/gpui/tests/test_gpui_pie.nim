## test_gpui_pie.nim — the progress pie in GPUI (`gpui/agent_harbor/ah_pie.nim`
## `drawPie`), read back from isonim-gpui's own render plan: each of the
## pie's three shapes draws what it says, and a pie at 0 % and a pie with no
## known progress never draw the same tree.
##
## - a DISC (0 % or any known share): the two-stop conic gradient over the
##   whole element, from the palette (`pieConicGradient`), under the edge
##   ring; no dot;
## - UNKNOWN: no gradient anywhere, the ring and a dot a quarter of the
##   diameter across, in the wedge's ink, on whole pixels (5 px into a 12 px
##   pie, as the browser lays out the web's dot);
## - HOLLOW (idle with a known share): the gradient on a disc inset a sixth
##   of the diameter inside the ring, so a whole idle pie is a ring around a
##   disc and never the solid disc an ended one is.
##
## And the story's head: each column's words centred over its pies, two
## neighbouring heads at least 8 px apart in the face GPUI sets them in.
##
## No mocks: the real shim's shadow tree and render plan (`renderPlanJson`),
## the interface face's own metrics (`textWidth`).

import std/[json, sequtils, strutils, unittest]

import isonim_gpui/[renderer, bindings]

import ../agent_harbor/[ah_pie, ah_theme]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's assertion count.
const ExpectedAssertions = 209

proc drawn(pie: ProgressPie; mode = dmDark): JsonNode =
  ## One pie on the panel, alone under a fresh root, as the render plan.
  gpui_reset_tree()
  var r: GpuiRenderer
  let p = ahPalette(mode)
  let root = r.createElement("div")
  r.appendChild(root, r.drawPie(p, pie, p.panel))
  parseJson(renderPlanJson(r, root)){"children"}[0]

proc style(n: JsonNode; key: string): string =
  # The shim serializes normalized GPUI names, not the input CSS spelling.
  let normalized = case key
    of "width": "w"
    of "height": "h"
    else: key.replace("-", "_")
  n{"styles"}{normalized}.getStr

proc all(n: JsonNode; pred: proc(n: JsonNode): bool): seq[JsonNode] =
  if pred(n): result.add n
  for c in n{"children"}.getElems: result.add all(c, pred)

proc gradients(n: JsonNode): seq[JsonNode] =
  n.all(proc(x: JsonNode): bool = x.style("background-image").len > 0)

proc dots(n: JsonNode): seq[JsonNode] =
  n.all(proc(x: JsonNode): bool = x{"attributes"}{"data-ah-pie-dot"} != nil)

suite "0 % and unknown draw differently":
  test "for every state, in both modes":
    for mode in [dmDark, dmLight]:
      for state in [saRunning, saIdle, saEnded]:
        let zero = drawn(pieOf(state, 0, 50), mode)
        let unknown = drawn(pieOf(state, 0, 0), mode)
        ck $zero != $unknown
        ck unknown.gradients.len == 0
        ck unknown.dots.len == 1
        ck zero.dots.len == 0
        ck zero.gradients.len == 1

suite "each shape draws what it says":
  test "a disc: the gradient on the element itself, under the ring":
    let pie = pieOf(saRunning, 8, 50)
    let n = drawn(pie)
    let p = ahPalette(dmDark)
    ck n{"attributes"}{"data-ah-pie-shape"}.getStr == "disc"
    ck n.style("background-image") ==
      p.pieInks(prSuccess, p.panel).pieConicGradient(pie)

  test "unknown: the ring and a centred dot of the wedge's ink":
    let n = drawn(pieOf(saFailed, 0, 0))
    let p = ahPalette(dmDark)
    let dot = n.dots[0]
    ck n{"attributes"}{"data-ah-pie-shape"}.getStr == "unknown"
    ck dot.style("width") == "3px" and dot.style("height") == "3px"
    # Whole pixels: no part-pixel offset that smears the dot over four.
    ck dot.style("top") == "5px" and dot.style("left") == "5px"
    # Round: GPUI takes a corner radius as a length, half the dot's side.
    ck dot{"styles"}{"rounded"}.getStr == "1.5px"
    # Well short of a hollow pie's inner disc (8 px), so a whole idle pie and
    # an unknown one never read alike at native size.
    let inner = drawn(pieOf(saIdle, 50, 50)).gradients[0]
    ck parseFloat(dot.style("width").strip(chars = {'p', 'x'})) * 2.0 <
       parseFloat(inner.style("width").strip(chars = {'p', 'x'}))
    ck dot{"styles"}{"bg"}.getStr.toLowerAscii == p.pieInks(prError, p.panel).wedge

  test "hollow: an idle pie's gradient inset inside the ring, even when whole":
    let n = drawn(pieOf(saIdle, 50, 50))
    ck n{"attributes"}{"data-ah-pie-shape"}.getStr == "hollow"
    ck n.style("background-image").len == 0
    let inner = n.gradients
    ck inner.len == 1
    ck inner[0].style("top") == "2px" and inner[0].style("width") == "8px"
    # An ended pie at 100 % is a solid disc on the element itself.
    let ended = drawn(pieOf(saEnded, 50, 50))
    ck ended.style("background-image").len > 0
    ck ended.dots.len == 0

suite "the story's head":
  test "each column centres its pie and its head; heads 8 px apart":
    gpui_reset_tree()
    var r: GpuiRenderer
    let host = r.createElement("div")
    r.drawPieStory(host, "every-state", ahPalette(dmDark), 360, 900)
    let plan = parseJson(renderPlanJson(r, host))
    let words = plan.all(proc(x: JsonNode): bool =
      x{"attributes"}{"data-ah-pie-head-word"} != nil)
    ck words.len == PieStoryColumns.len
    for i, name in PieStoryColumns:
      ck words[i]{"attributes"}{"data-ah-pie-head-word"}.getStr == name
    # Every pie column, the head's and the rows', centres what it holds.
    let columns = plan.all(proc(x: JsonNode): bool =
      x.style("width") in PieStoryColumnsPx.mapIt($it & "px") and
        x.style("justify").len > 0)
    ck columns.len > 0
    for c in columns: ck c.style("justify") == "center"
    # Centred, the heads' edges are where the face sets them; neighbours
    # stand at least `PieStoryHeadGapPx` apart.
    var least = Inf
    for i in 1 ..< PieStoryColumns.len:
      let a = textWidth(PieStoryColumns[i - 1], CaptionPx)
      let b = textWidth(PieStoryColumns[i], CaptionPx)
      let gap = pieColumnCentrePx(i) - pieColumnCentrePx(i - 1) - (a + b) / 2.0
      checkpoint PieStoryColumns[i - 1] & " / " & PieStoryColumns[i] & ": " & $gap
      ck gap >= PieStoryHeadGapPx.float
      least = min(least, gap)
    echo "    nearest heads: ", least, " px apart"
    ck PieStoryHeadGapPx >= 8
    # The last head ends inside its column.
    let last = PieStoryColumns.high
    ck pieColumnCentrePx(last) + textWidth(PieStoryColumns[last], CaptionPx) / 2.0 <=
      pieColumnCentrePx(last) + PieStoryColumnsPx[last].float / 2.0

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
