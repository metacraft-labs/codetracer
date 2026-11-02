## views/table_hscroll.nim — a TABLE pane drawn from its horizontal view: the
## terminal's half of Horizontal-Overflow.md §5.5 (PLAT-70 Part I).
##
## The widths and whether the pane scrolls are the shared solver's
## (`viewmodels/table_fit.fitTable`). A pane lays its rows out once, at the
## table's own width (`TableFit.contentUnits` cells, wider than the pane in
## SCROLL), into a scratch grid, and `copySlice` puts the `[leftCol, leftCol +
## width)` window of each row on the screen — the header and the body through
## the same slice, so a header always stands over its cells. The bar is §4's
## overflow-only bar (`scrubber_track.paintHorizontalBar`) on the pane's last
## body row.

import codetracer_embed
import ./styled_row

export table_fit

proc copySlice*(dst: var StyledGrid; dstRow, dstCol: int;
                src: StyledGrid; srcRow, leftCol, width: int) =
  ## Copy the cells `[leftCol, leftCol + width)` of `src`'s row `srcRow` to
  ## `dst` at `(dstRow, dstCol)`. A wide glyph cut by either edge is drawn as
  ## a blank in the cell left of the edge, so nothing outside the window is
  ## written and every later cell stays in its column.
  if width <= 0 or srcRow < 0 or srcRow >= src.height:
    return
  for i in 0 ..< width:
    let c = leftCol + i
    if c >= src.width:
      break
    let rune = src.runeAt(srcRow, c)
    let style = src.styleAt(srcRow, c)
    if rune.len == 0:
      # The trailing half of a wide glyph: its first half was painted with
      # it, or (at the window's left edge) is outside the window.
      if i == 0:
        dst.paint(dstRow, dstCol, " ", style)
      continue
    if i == width - 1 and c + 1 < src.width and src.runeAt(srcRow, c + 1).len == 0:
      # A wide glyph whose second half is past the window's right edge.
      dst.paint(dstRow, dstCol + i, " ", style)
      continue
    dst.paint(dstRow, dstCol + i, rune, style)

func shiftCuts*(cuts: seq[CutCell]; delta, left, right: int): seq[CutCell] =
  ## Cut cells laid out at table columns, moved by `delta` onto the screen
  ## and clipped to `[left, right)`; a cell wholly outside is dropped (its
  ## hover and `…` are not on screen). A cell whose `…` left the screen keeps
  ## its hover and loses its `…` press.
  for c in cuts:
    var s = c
    s.col += delta
    s.ellipsisCol += delta
    let a = max(s.col, left)
    let b = min(s.col + s.width, right)
    if b <= a:
      continue
    s.col = a
    s.width = b - a
    if s.ellipsisCol < left or s.ellipsisCol >= right:
      s.ellipsisCol = -10_000
    result.add s
