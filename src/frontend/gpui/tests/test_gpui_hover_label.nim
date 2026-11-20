## test_gpui_hover_label.nim — the GPUI window's hover label
## (`gpui/hover_label.nim`): its placements, its width with and without the
## leading icon, and the element it draws.
##
## The window's own suites (`test_plat48_gpui_plan.nim`,
## `test_plat51b_gpui_plan.nim`, `test_plat53_gpui_plan.nim`) drive a real
## window and read the label it drew; this suite holds the element's rules
## where a window cannot reach them: every edge of the window, the icon slot
## that no window caller fills yet, and a label drawn with and without it.
##
## No mocks: the real placement functions, and the real isonim-gpui shim's
## element tree for the drawing (read back as its render plan).
##
## Run (the `gpui-shell` lane's flags):
##   nim c -r <gpui-shell flags> src/frontend/gpui/tests/test_gpui_hover_label.nim

import std/[json, strutils, unittest]

import isonim_gpui/[renderer, bindings]

import ../window_geometry
import ../hover_label

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's assertion count.
const ExpectedAssertions = 72

const
  ViewW = 1000
  ViewH = 600
  Icon = HoverLabelIcon(src: "/icons/mark.svg", sizePx: 16)

proc nodesWith(n: JsonNode; attr: string): seq[JsonNode] =
  if n{"attributes"}{attr}.getStr.len > 0: result.add n
  for c in n{"children"}.getElems:
    result.add nodesWith(c, attr)

proc style(n: JsonNode; key: string): string =
  # The shim serializes normalized GPUI names, not the input CSS spelling.
  let normalized = case key
    of "width": "w"
    of "height": "h"
    else: key.replace("-", "_")
  n{"styles"}{normalized}.getStr

proc drawn(at: PxRect; text: string; lines: seq[string] = @[];
           icon = HoverLabelIcon(); passIcon = true): JsonNode =
  ## The label drawn alone under a fresh root, as the shim's render plan.
  ## `passIcon = false` leaves the icon argument out altogether.
  gpui_reset_tree()
  var r: GpuiRenderer
  let root = r.createElement("div")
  let label = if passIcon: drawHoverLabel(r, at, text, lines, icon)
              else: drawHoverLabel(r, at, text, lines)
  r.appendChild(root, label)
  parseJson(renderPlanJson(r, root))

suite "the icon slot":
  test "no icon takes no width":
    ck not HoverLabelIcon().hasIcon
    ck iconSlotPx(HoverLabelIcon()) == 0
    # An icon with no image, or no size, is no icon either.
    ck iconSlotPx(HoverLabelIcon(src: "/x.svg")) == 0
    ck iconSlotPx(HoverLabelIcon(sizePx: 16)) == 0
    ck hoverLabelWidthPx(["Step over"], HoverLabelIcon()) ==
       hoverLabelWidthPx(["Step over"])

  test "an icon takes its size and the gap":
    ck Icon.hasIcon
    ck iconSlotPx(Icon) == 16 + HoverLabelIconGapPx
    ck hoverLabelWidthPx(["Step over"], Icon) ==
       hoverLabelWidthPx(["Step over"]) + 16 + HoverLabelIconGapPx

suite "the width and the lines":
  test "the widest line and the padding either side":
    ck hoverLabelWidthPx(["abc"]) == 3 * TabCharPx + 2 * TabPadPx
    ck hoverLabelWidthPx(["abc", "abcdefg", "ab"]) ==
       7 * TabCharPx + 2 * TabPadPx
    ck hoverLabelWidthPx([]) == 2 * TabPadPx

  test "a label wraps at spaces, and a long word keeps its own line":
    ck hoverLabelLines("one two three four", 9) ==
       @["one two", "three", "four"]
    ck hoverLabelLines("a supercalifragilistic b", 5) ==
       @["a", "supercalifragilistic", "b"]
    let text = "the quick brown fox jumps over the lazy dog"
    ck hoverLabelLines(text, 12).join(" ") == text
    ck hoverLabelLines("", 10).len == 0

suite "below and above":
  test "one line under its anchor, at its left edge":
    let a = PxRect(x: 100, y: 0, w: 30, h: 30)
    ck hoverLabelBelow(a, "Step over", 2) ==
       PxRect(x: 100, y: 32, w: 9 * TabCharPx + 2 * TabPadPx, h: HoverLabelPx)
    ck hoverLabelBelow(a, "Step over", 6).y == 36

  test "under the anchor where there is room":
    let at = placeBelowOrAbove(PxRect(x: 50, y: 100, w: 40, h: 20), 200, 48,
                               2, ViewW, ViewH)
    ck at == PxRect(x: 50, y: 122, w: 200, h: 48)

  test "above the anchor at the window's foot":
    let at = placeBelowOrAbove(PxRect(x: 50, y: 570, w: 40, h: 20), 200, 48,
                               2, ViewW, ViewH)
    ck at.y == 570 - 48 - 2
    ck at.y + at.h <= ViewH

  test "moved left at the window's right edge, never past its left":
    let at = placeBelowOrAbove(PxRect(x: 950, y: 10, w: 40, h: 20), 200, 24,
                               0, ViewW, ViewH)
    ck at.x == ViewW - 200
    let wide = placeBelowOrAbove(PxRect(x: 950, y: 10, w: 40, h: 20), 1200,
                                 24, 0, ViewW, ViewH)
    ck wide.x == 0

  test "taller than the room above too: at the window's top":
    let at = placeBelowOrAbove(PxRect(x: 0, y: 100, w: 40, h: 20), 100, 590,
                               2, ViewW, ViewH)
    ck at.y == 0

  test "a wrapped label is no wider than the window":
    let lines = @["a" .repeat(150)]
    let at = hoverLabelUnder(PxRect(x: 10, y: 10, w: 10, h: 10), lines, 2,
                             ViewW, ViewH)
    ck at.w == ViewW
    ck at.x == 0
    ck at.h == HoverLabelPx
    ck hoverLabelUnder(PxRect(), @["x", "y", "z"], 2, ViewW, ViewH).h ==
       3 * HoverLabelPx

suite "beside a box":
  # A popover in the window's middle, a row of it, and a short text.
  let row = PxRect(x: 300, y: 200, w: 200, h: 24)
  let box = PxRect(x: 300, y: 100, w: 200, h: 300)

  test "right of the box where it fits on one line, level with the row":
    let p = hoverLabelBeside("Not available", box, row, ViewW, ViewH)
    ck p.side == hlsRight
    ck p.lines == @["Not available"]
    ck p.at.x == box.x + box.w + HoverLabelBesideGapPx
    ck p.at.y == row.y + (row.h - HoverLabelPx) div 2
    ck p.at.w == hoverLabelWidthPx(["Not available"])

  test "at the right edge it goes left, flush against the box":
    let edge = PxRect(x: ViewW - 220, y: 100, w: 200, h: 300)
    let p = hoverLabelBeside("Not available", edge, row, ViewW, ViewH)
    ck p.side == hlsLeft
    ck p.at.x + p.at.w == edge.x - HoverLabelBesideGapPx
    ck p.at.x >= 0

  test "at the left edge it stays right":
    let edge = PxRect(x: 0, y: 100, w: 200, h: 300)
    let p = hoverLabelBeside("Not available", edge, row, ViewW, ViewH)
    ck p.side == hlsRight
    ck p.at.x == edge.w + HoverLabelBesideGapPx

  test "wrapped on the roomier side when neither holds one line":
    let text = "word ".repeat(60).strip
    let p = hoverLabelBeside(text, box, row, ViewW, ViewH)
    ck p.side == hlsRight   # 496 px right of the box, 296 px left of it
    ck p.lines.len > 1
    ck p.lines.join(" ") == text
    ck p.at.x == box.x + box.w + HoverLabelBesideGapPx
    ck p.at.x + p.at.w <= ViewW
    ck p.at.h == p.lines.len * HoverLabelPx

  test "over the box when both sides are too narrow, inside the window":
    let narrowBox = PxRect(x: 60, y: 100, w: 880, h: 300)
    let p = hoverLabelBeside("word ".repeat(60).strip, narrowBox, row,
                             ViewW, ViewH)
    ck p.side == hlsOver
    ck p.at.x == 0
    ck p.at.w <= ViewW

  test "kept above the window's foot":
    let low = PxRect(x: 300, y: ViewH - 10, w: 200, h: 24)
    let text = "word ".repeat(60).strip
    let p = hoverLabelBeside(text, box, low, ViewW, ViewH)
    ck p.at.y + p.at.h <= ViewH
    ck p.at.y >= 0

  test "the empty icon places exactly as no icon; an icon widens the label":
    let plain = hoverLabelBeside("Not available", box, row, ViewW, ViewH)
    let empty = hoverLabelBeside("Not available", box, row, ViewW, ViewH,
                                 HoverLabelIcon())
    ck plain == empty
    let iconed = hoverLabelBeside("Not available", box, row, ViewW, ViewH,
                                  Icon)
    ck iconed.at.w == plain.at.w + iconSlotPx(Icon)
    ck iconed.at.x == plain.at.x

suite "the drawn label":
  let at = PxRect(x: 40, y: 50, w: 110, h: HoverLabelPx)

  test "one line: the window's ground, the padding, the outline, the text":
    let plan = drawn(at, "Step over")
    let labels = plan.nodesWith(HoverLabelAttribute)
    ck labels.len == 1
    let l = labels[0]
    ck l{"attributes"}{HoverLabelAttribute}.getStr == "Step over"
    ck l.style("left") == "40px"
    ck l.style("top") == "50px"
    ck l.style("width") == "110px"
    ck l.style("padding-left") == $TabPadPx & "px"
    ck l.style("border-width") == "1px"
    ck l.nodesWith(HoverLabelLineAttribute).len == 0
    ck l.nodesWith(HoverLabelIconAttribute).len == 0

  test "wrapped: one row per line, each a line high":
    let lines = @["first line", "second line", "third"]
    let plan = drawn(PxRect(x: 0, y: 0, w: 200, h: 3 * HoverLabelPx),
                     lines.join(" "), lines)
    let rows = plan.nodesWith(HoverLabelLineAttribute)
    ck rows.len == 3
    ck rows[1]{"attributes"}{HoverLabelLineAttribute}.getStr == "second line"
    ck rows[2].style("height") == $HoverLabelPx & "px"

  test "the empty icon draws exactly what no icon draws":
    ck $drawn(at, "Step over", icon = HoverLabelIcon()) ==
       $drawn(at, "Step over", passIcon = false)
    let lines = @["first line", "second line"]
    ck $drawn(at, lines.join(" "), lines, HoverLabelIcon()) ==
       $drawn(at, lines.join(" "), lines, passIcon = false)

  test "an icon leads the first line; the others are indented under its words":
    let one = drawn(at, "Step over", icon = Icon)
    let icons = one.nodesWith(HoverLabelIconAttribute)
    ck icons.len == 1
    ck icons[0].style("width") == "16px"
    ck icons[0].style("margin-right") == $HoverLabelIconGapPx & "px"
    let lines = @["first line", "second line"]
    let two = drawn(at, lines.join(" "), lines, Icon)
    let rows = two.nodesWith(HoverLabelLineAttribute)
    ck rows.len == 2
    ck rows[0].nodesWith(HoverLabelIconAttribute).len == 1
    ck rows[1].nodesWith(HoverLabelIconAttribute).len == 0
    ck rows[1].style("padding-left") == $iconSlotPx(Icon) & "px"

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
