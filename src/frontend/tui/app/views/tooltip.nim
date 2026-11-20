## app/views/tooltip.nim — the terminal's TOOLTIP: a few lines of text on the
## menu's card surface, over everything, near the cell they explain. The
## terminal's spelling of a desktop tooltip; first drawn for a truncated
## table cell's full text (PLAT-70 Part B, Horizontal-Overflow.md §5.3).
##
## The module places and paints a tooltip; what it says, and when it shows,
## is the caller's (`tui_app.cellTooltip`, set by the runtime's hover clock).
## Two placements:
##
##   * `tpBelow` (the default): under the anchor cell, above it when the
##     screen has no room below, moved left to stay on the screen.
##   * `tpBeside`: level with the anchor's row, right of the anchor's `span`
##     cells, left of them where the screen ends first, and over the anchor,
##     kept on the screen, only when neither side holds it. For a line whose
##     tooltip must not cover the lines under it (a list's line).
##
## A tooltip is one cell of padding each side of its widest line, as many
## rows as it has lines, never larger than the screen.

import ../layout/cells
import ./styled_row

type
  TooltipPlacement* = enum
    ## Where a tooltip goes relative to its anchor (see the module's doc).
    tpBelow
    tpBeside

  CellTooltip* = object
    ## The tooltip's lines and the cell it belongs to (its anchor's first
    ## screen cell). No lines, no tooltip.
    lines*: seq[string]
    row*, col*: int
    placement*: TooltipPlacement
      ## `tpBelow` unless the caller asks for `tpBeside`.
    span*: int
      ## `tpBeside` only: how many cells the anchor takes from `col`, so the
      ## tooltip goes past its end; 0 counts as one cell.

const CellTooltipStyle* = CellStyle(role: srChromeText, surface: srSurfaceMenu)
  ## The tooltip's text on the menu's card surface.

proc tooltipSize(t: CellTooltip; width, height: int): tuple[w, h: int] =
  ## One cell of padding each side of the widest line, a row per line, both
  ## capped at the screen.
  var w = 0
  for l in t.lines:
    w = max(w, cellWidthOf(l))
  (min(width, w + 2), min(height, t.lines.len))

proc cellTooltipArea*(t: CellTooltip; width, height: int): CellArea =
  ## Where the tooltip goes on a `width` × `height` screen, by its
  ## placement. An empty area for no lines or no screen.
  if t.lines.len == 0 or width <= 0 or height <= 0:
    return CellArea()
  let (w, h) = tooltipSize(t, width, height)
  case t.placement
  of tpBelow:
    let below = t.row + 1
    let row = if below + h <= height - 1: below else: max(0, t.row - h)
    let col = max(0, min(t.col, width - w))
    CellArea(row: row, col: col, width: w, height: h)
  of tpBeside:
    # Level with the anchor, kept off the screen's last row the way `tpBelow`
    # is, and moved up where it would run past it.
    let row = if t.row + h <= height - 1: t.row else: max(0, height - 1 - h)
    let right = t.col + max(1, t.span)
    let col =
      if right + w <= width: right             # right of the anchor
      elif t.col - w >= 0: t.col - w           # left of it, flush
      elif width - right >= t.col: max(0, width - w)   # over it, from the right
      else: 0                                  # over it, from the left
    CellArea(row: row, col: col, width: w, height: h)

proc paintCellTooltip*(g: var StyledGrid; t: CellTooltip; width, height: int) =
  ## The tooltip at `cellTooltipArea`, each line truncated to the inside of
  ## its padding.
  let a = cellTooltipArea(t, width, height)
  if a.width <= 0 or a.height <= 0:
    return
  g.fillSurface(a.row, a.col, a.width, a.height, srSurfaceMenu)
  for i in 0 ..< a.height:
    g.paint(a.row + i, a.col + 1, truncateToCells(t.lines[i], a.width - 2),
            CellTooltipStyle)
