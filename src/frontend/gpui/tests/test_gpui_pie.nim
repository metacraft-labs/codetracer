## test_gpui_pie.nim — the progress pie in GPUI (`gpui/agent_harbor/ah_pie.nim`
## `drawPie`), read back from isonim-gpui's own render plan: each of the
## pie's two shapes draws what it says, and a pie at 0 % and a pie with no
## known progress never draw the same tree.
##
## - a RING (every role, at 0 % or any known share): the edge ring in the
##   role's ink and, inside it past a gap of the ground (`pieWedgeInsetPx`:
##   2 px of a 12 px pie, an 8 px disc), the two-stop conic gradient from the
##   palette (`pieConicGradient`) whose rest stop is the ground itself, never
##   a tint; nothing painted on the element itself; no dot;
## - UNKNOWN: no gradient anywhere, the ring and a dot a quarter of the
##   diameter across, in the wedge's ink, on whole pixels (5 px into a 12 px
##   pie, as the browser lays out the web's dot).
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
const ExpectedAssertions = 528

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

suite "every role is a ring, its rest the ground":
  test "every role at every share, in both modes":
    # The wedge's disc is the only thing painted inside the ring: inset past
    # the ring and the gap, its gradient's wedge the role's full ink and its
    # rest the ground; the element itself paints no gradient and no fill, so
    # a 0 % pie inside its ring is the ground and nothing else.
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for state in PieStoryStates:
        for done in PieStoryDone:
          let pie = pieOf(state, done, PieStoryTotal)
          let n = drawn(pie, mode)
          let inks = p.pieInks(pie.role, p.panel)
          checkpoint $mode & " " & $state & " " & $done
          ck n{"attributes"}{"data-ah-pie-shape"}.getStr == "ring"
          ck n.style("background-image").len == 0 and n.style("bg").len == 0
          let inner = n.gradients
          ck inner.len == 1
          ck inner[0].style("background-image") ==
            "conic-gradient(" & inks.wedge & " 0 " & pie.pieStopPercent & ", " &
              p.panel & " " & pie.pieStopPercent & " 100%)"
          ck inner[0].style("top") == "2px" and inner[0].style("width") == "8px"

suite "each shape draws what it says":
  test "a ring: the gradient on the inset disc, the ring over it":
    let pie = pieOf(saRunning, 8, 50)
    let n = drawn(pie)
    let p = ahPalette(dmDark)
    ck n{"attributes"}{"data-ah-pie-shape"}.getStr == "ring"
    ck n.gradients[0].style("background-image") ==
      p.pieInks(prSuccess, p.panel).pieConicGradient(pie)
    # The ring is the last child, over the disc, in the edge's ink.
    let ring = n{"children"}[^1]
    ck ring.style("border_color").toLowerAscii == p.pieInks(prSuccess, p.panel).edge

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
    # Well short of the wedge's disc (8 px), so a whole pie and an unknown
    # one never read alike at native size.
    let inner = drawn(pieOf(saEnded, 50, 50)).gradients[0]
    ck parseFloat(dot.style("width").strip(chars = {'p', 'x'})) * 2.0 <
       parseFloat(inner.style("width").strip(chars = {'p', 'x'}))
    ck dot{"styles"}{"bg"}.getStr.toLowerAscii == p.pieInks(prError, p.panel).wedge

  test "a whole pie is a full disc inside the ring, for every role":
    for state in PieStoryStates:
      let n = drawn(pieOf(state, 50, 50))
      checkpoint $state
      ck n.style("background-image").len == 0
      ck n.gradients.len == 1
      ck n.gradients[0].style("background-image").startsWith(
        "conic-gradient(" & n{"attributes"}{"data-ah-pie-wedge"}.getStr & " 0 100%, ")
      ck n.dots.len == 0

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
