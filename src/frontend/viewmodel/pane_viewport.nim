## pane_viewport.nim — a pane's size, in its medium's units, as the
## `Viewport` a windowed ViewModel is told (Viewport-Driven-Loading V1, V3).
##
## Every front-end reports the panes it shows through `setViewport`: the DOM
## panel host from the pixels it measures, the terminal from its layout's
## cell rectangles, GPUI from an element's laid-out bounds, an editor plugin
## from its window's cells. The conversion from the medium's units happens in
## the reporter, never in the ViewModel (V1), and it happens HERE, so a pane of
## the same shape asks for the same window on every front-end: the rows the
## pane shows, the row it is scrolled to, and — for the call trace — how many
## depth levels fit across it (the medium's indent per level).

from std/math import ceil

import viewport
export viewport

func cellPaneViewport*(bodyRows, bodyCols, firstRow: int;
                       colsPerLevel = 0): Viewport =
  ## A pane whose rows its host counts itself (the terminal and an editor
  ## window in cells; GPUI from its laid-out rows): `bodyRows` rows,
  ## `bodyCols` wide in the same unit as `colsPerLevel` (cells, or pixels),
  ## scrolled to `firstRow`.
  ## With `colsPerLevel` > 0 the viewport's `cols` is the depth levels that
  ## fit across the pane at that indent; otherwise `cols` is 0 (unknown).
  ## A pane with no rows is unmeasured and asks for nothing.
  if bodyRows <= 0:
    return Viewport()
  Viewport(rows: bodyRows,
           cols: (if colsPerLevel > 0: max(1, bodyCols div colsPerLevel)
                  else: 0),
           firstRow: max(0, firstRow))

func pixelPaneViewport*(heightPx, widthPx, rowPx, scrollTopPx: float;
                        pxPerLevel = 0.0;
                        countPartialRow = false): Viewport =
  ## A pane measured in pixels (the DOM, GPUI): its body is `heightPx` ×
  ## `widthPx`, its rows `rowPx` apart (the measured row ADVANCE), scrolled by
  ## `scrollTopPx`. A row counts when it fits whole — or, with
  ## `countPartialRow`, when any of it shows; the first row shown is the one
  ## the scroll offset falls in. With `pxPerLevel` > 0 the viewport's
  ## `cols` is the depth levels that fit across the pane. An unmeasured pane
  ## (no height, or no row pitch yet) asks for nothing.
  if heightPx <= 0.0 or rowPx <= 0.0:
    return Viewport()
  # A whole row, measured at a fractional pitch (the desktop's ~25.28 px),
  # divides to a hair under its count; the tolerance keeps it whole.
  const Tolerance = 1e-6
  let exact = heightPx / rowPx
  let rows = max(1, if countPartialRow: int(ceil(exact - Tolerance))
                    else: int(exact + Tolerance))
  let cols = if pxPerLevel > 0.0 and widthPx > 0.0:
               max(1, int(widthPx / pxPerLevel + Tolerance))
             else: 0
  Viewport(rows: rows, cols: cols,
           firstRow: max(0, int(max(0.0, scrollTopPx) / rowPx + Tolerance)))
