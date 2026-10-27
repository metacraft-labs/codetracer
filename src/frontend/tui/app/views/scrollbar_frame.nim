## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/scrollbar_frame.nim — PLAT-70 Part H (Scrollbar-Scrubbers.md §7):
## what one frame's scrollbars are drawn with, and where they were drawn.
##
## A `StyledGrid` carries both (`styled_row`):
##
##   * `ScrollbarFrame` IN — the options, which bar the pointer is doing what
##     to, and how far each pane's bars have faded. The shell sets it before
##     the panes paint, so a pane painter draws its bar without being told
##     anything new: `scrollbar_styles.paintBar` reads it off the grid.
##   * `BarSpot` OUT — every bar a painter drew, with its pane, axis, cells and
##     scrubber model. The runtime hit-tests the pointer against these: the
##     hover, the grab, the track's two rules and the fade's wake are one
##     implementation over every bar of every pane, read back from the cells
##     the user saw rather than recomputed per pane.

import codetracer_embed
import headless_app/layout_model

type
  BarPointer* = object
    ## The one bar the pointer is doing something to, if any.
    active*: bool
    pane*: PaneKind
    axis*: BarAxis
    state*: BarState

  ScrollbarFrame* = object
    options*: ScrollbarOptions
    pointer*: BarPointer
    faded*: array[PaneKind, float32]
      ## How far each pane's bars have faded (`CellStyle.faded`): 0 drawn as
      ## §7.3 says, 1 gone. The zero value draws every bar.

  BarSpot* = object
    ## One bar as painted.
    pane*: PaneKind
    axis*: BarAxis
    origin*: int
      ## Its fixed coordinate: the column of a vertical bar, the row of a
      ## horizontal one.
    at*: int
      ## Its first cell along the axis.
    cells*: int
    model*: ScrubberModel

func stateOf*(f: ScrollbarFrame; pane: PaneKind; axis: BarAxis): BarState =
  if f.pointer.active and f.pointer.pane == pane and f.pointer.axis == axis:
    f.pointer.state
  else: bsIdle

func contains*(b: BarSpot; row, col: int): bool =
  ## Whether the cell `(row, col)` is one of the bar's.
  case b.axis
  of axVertical: col == b.origin and row >= b.at and row < b.at + b.cells
  of axHorizontal: row == b.origin and col >= b.at and col < b.at + b.cells

func cellAlong*(b: BarSpot; row, col: int): int =
  ## The cell of the bar a pointer at `(row, col)` is level with, clamped
  ## onto the bar (a held thumb follows a pointer that has left it).
  let along = if b.axis == axVertical: row - b.at else: col - b.at
  max(0, min(b.cells - 1, along))
