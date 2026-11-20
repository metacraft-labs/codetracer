## test_tui_tooltip.nim — the terminal's tooltip (`app/views/tooltip.nim`):
## where each placement puts it, at every edge of the screen, and what it
## paints there.
##
## `tpBelow` is the placement a truncated table cell's tooltip has always had
## (`test_plat70b_tables.nim` holds its first cases through the shell); it is
## pinned here again at the screen's edges, so the move into its own module
## and the new placement beside it cannot have changed it. `tpBeside` is new:
## level with its anchor, right of it, left of it where the screen ends, and
## over it, on the screen, when neither side holds it.
##
## No mocks: the real placement over the real `CellTooltip`, and the real
## `StyledGrid` for the paint.

import std/[strutils, unittest]

import ../app/layout/cells
import ../app/views/styled_row
import ../app/views/tooltip

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's assertion count.
const ExpectedAssertions = 41

const
  W = 80
  H = 24

proc inside(a: CellArea): bool =
  a.row >= 0 and a.col >= 0 and a.row + a.height <= H and a.col + a.width <= W

suite "below (the default placement)":
  test "an unset placement is below":
    ck CellTooltip().placement == tpBelow

  test "under the cell, one cell of padding each side of the widest line":
    let a = cellTooltipArea(CellTooltip(lines: @["abc", "defgh"], row: 5,
                                        col: 10), W, H)
    ck a == CellArea(row: 6, col: 10, width: 7, height: 2)

  test "above the cell where the screen's last row would be reached":
    let a = cellTooltipArea(CellTooltip(lines: @["x", "y", "z"], row: 20,
                                        col: 0), W, H)
    ck a.row == 17
    let fits = cellTooltipArea(CellTooltip(lines: @["x", "y"], row: 20,
                                           col: 0), W, H)
    ck fits.row == 21   # rows 21 and 22: the last row stays free

  test "moved left at the right edge, never off the left":
    let a = cellTooltipArea(CellTooltip(lines: @["abcdef"], row: 3, col: 78),
                            W, H)
    ck a.col == W - 8
    ck a.inside
    let wide = cellTooltipArea(CellTooltip(lines: @["a".repeat(100)], row: 3,
                                           col: 40), W, H)
    ck wide.width == W
    ck wide.col == 0

  test "no lines or no screen: nothing":
    ck cellTooltipArea(CellTooltip(), W, H).width == 0
    ck cellTooltipArea(CellTooltip(lines: @["x"]), 0, H).width == 0
    ck cellTooltipArea(CellTooltip(lines: @["x"]), W, 0).height == 0

suite "beside":
  test "right of the anchor's span, level with its row":
    let a = cellTooltipArea(CellTooltip(lines: @["Version 12", "built here"],
                                        row: 4, col: 2, span: 20,
                                        placement: tpBeside), W, H)
    ck a == CellArea(row: 4, col: 22, width: 12, height: 2)

  test "a span of 0 counts as one cell":
    let a = cellTooltipArea(CellTooltip(lines: @["abc"], row: 4, col: 2,
                                        placement: tpBeside), W, H)
    ck a.col == 3

  test "at the right edge it flips to the left, flush against the anchor":
    let a = cellTooltipArea(CellTooltip(lines: @["abcdef"], row: 4, col: 60,
                                        span: 15, placement: tpBeside), W, H)
    ck a.width == 8
    ck a.col == 60 - 8
    ck a.col + a.width == 60
    ck a.row == 4

  test "exactly fitting on the right stays right":
    let a = cellTooltipArea(CellTooltip(lines: @["abcdef"], row: 4, col: 60,
                                        span: 12, placement: tpBeside), W, H)
    ck a.col == 72
    ck a.col + a.width == W

  test "neither side holds it: over the anchor, on the screen":
    # A 40-cell tooltip beside a line from column 30 to 70: 10 cells right,
    # 30 left.
    let fromRight = cellTooltipArea(
      CellTooltip(lines: @["b".repeat(38)], row: 4, col: 30, span: 40,
                  placement: tpBeside), W, H)
    ck fromRight.width == 40
    ck fromRight.inside
    ck fromRight.col == 0   # the left (30) is roomier than the right (10)
    let fromLeft = cellTooltipArea(
      CellTooltip(lines: @["b".repeat(38)], row: 4, col: 5, span: 40,
                  placement: tpBeside), W, H)
    ck fromLeft.inside
    ck fromLeft.col == W - 40   # the right (35) is roomier than the left (5)

  test "at the left edge it stays right":
    let a = cellTooltipArea(CellTooltip(lines: @["abc"], row: 4, col: 0,
                                        span: 10, placement: tpBeside), W, H)
    ck a.col == 10

  test "at the foot it moves up, off the last row":
    let a = cellTooltipArea(CellTooltip(lines: @["x", "y", "z"], row: 22,
                                        col: 0, span: 10,
                                        placement: tpBeside), W, H)
    ck a.row == H - 1 - 3
    ck a.row + a.height <= H - 1
    let top = cellTooltipArea(CellTooltip(lines: @["x"], row: 0, col: 0,
                                          span: 10, placement: tpBeside), W, H)
    ck top.row == 0

  test "taller or wider than the screen: capped, on the screen":
    var many: seq[string]
    for i in 0 ..< 40: many.add "line " & $i
    let a = cellTooltipArea(CellTooltip(lines: many, row: 10, col: 70,
                                        span: 5, placement: tpBeside), W, H)
    ck a.height == H
    ck a.row == 0
    ck a.inside
    let wide = cellTooltipArea(CellTooltip(lines: @["a".repeat(120)], row: 3,
                                           col: 40, span: 5,
                                           placement: tpBeside), W, H)
    ck wide.width == W
    ck wide.col == 0
    ck wide.inside

suite "the paint":
  test "the lines inside the padding, on the menu's surface":
    var g = newStyledGrid(W, H)
    let t = CellTooltip(lines: @["Version 12", "built here"], row: 4, col: 2,
                        span: 20, placement: tpBeside)
    paintCellTooltip(g, t, W, H)
    ck g.rowText(4)[23 ..< 33] == "Version 12"
    ck g.rowText(5)[23 ..< 33] == "built here"
    ck g.rowText(4)[22] == ' '   # the left padding
    ck g.rowText(3).strip.len == 0
    let spans = g.rowSpansIn(4, 23, 10)
    ck spans.len == 1
    ck spans[0].text == "Version 12" and spans[0].style == CellTooltipStyle

  test "a line too long for the screen is cut inside the padding":
    var g = newStyledGrid(10, 5)
    paintCellTooltip(g, CellTooltip(lines: @["abcdefghijklmnop"], row: 1,
                                    col: 0), 10, 5)
    ck g.rowText(2) == " abcdefgh "

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
