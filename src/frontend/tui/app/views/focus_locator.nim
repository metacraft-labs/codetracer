## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/focus_locator.nim — the screen-reader mode's FOCUSED ELEMENT
## (CodeTracer-TUI-Terminal-Adaptation.md §9.4, SR-D5 and SR-D7): where on a
## painted frame the focused pane's focused element is, so the terminal's
## real cursor can be shown on it, and what that element's row says, so a
## focus change can be announced on the status line.
##
## ## Read off the painted frame, not asked of each pane
##
## Every list, tree and table already paints its selected row on the
## selection or active-row SURFACE, and the editors paint the caret's line on
## the current-line surface with the caret's own cell reversed. Reading those
## surfaces back off the frame finds the focused element in every pane the
## same way — a pane added later follows focus without a rule of its own —
## and it is exactly what a sighted user sees highlighted, so the cursor
## cannot disagree with the screen. Pure: rows in, a spot out.

import std/strutils

import headless_app/layout_model

import ../layout/cells
import ./styled_row

type
  FocusHow* = enum
    ## Which rule found the spot, most specific first.
    fhNone = "none"
    fhCaret = "caret"
      ## A reversed cell on the current-line surface: an editor's caret.
    fhSelection = "selection"
      ## The first row on the selection surface.
    fhActiveRow = "active row"
      ## The first row on the active-row surface (a list's current entry).
    fhCurrentLine = "current line"
      ## The first row on the current-line surface (the execution line).
    fhFirstRow = "first row"
      ## Nothing is highlighted: the pane's first body row.

  FocusSpot* = object
    ## The focused element of one pane on one frame.
    found*: bool
    pane*: PaneKind
    row*, col*: int
      ## The screen cell the cursor goes to.
    text*: string
      ## The element's row inside the pane: trimmed, runs of spaces as one.
    how*: FocusHow

const
  SelectionSurfaces = [(fhSelection, srSurfaceSelection),
                       (fhActiveRow, srSurfaceActiveRow),
                       (fhCurrentLine, srSurfaceCurrentLine)]

proc gridOf(rows: seq[StyledRow]; width: int;
            ambiguous: AmbiguousWidth): StyledGrid =
  ## The frame's rows as cells, painted the way the shell painted them.
  result = newStyledGrid(width, rows.len)
  result.ambiguous = ambiguous
  for r, row in rows:
    var col = 0
    for span in row:
      result.paint(r, col, span.text, span.style)
      col += cellWidthOf(span.text, ambiguous)

proc rowTextIn(g: StyledGrid; row, col, width: int): string =
  ## The row's text inside `[col, col + width)`, its runs of blanks as one.
  var raw = ""
  for c in col ..< min(g.width, col + width):
    let r = g.runeAt(row, c)
    raw.add (if r.len == 0: "" else: r)
  var last = ' '
  for ch in raw.strip:
    if ch == ' ' and last == ' ':
      continue
    result.add ch
    last = ch

proc focusSpotIn*(rows: seq[StyledRow]; area: CellArea;
                  ambiguous = awNarrow): FocusSpot =
  ## The focused element inside `area` — a pane's painted rectangle, its
  ## strip (title) row first. The caret, else the first selected, active or
  ## current row at its first cell, else the first body row.
  if area.width <= 0 or area.height <= 1 or rows.len == 0:
    return FocusSpot()
  var width = area.col + area.width
  for row in rows:
    width = max(width, cellCount(row, ambiguous))
  let g = gridOf(rows, width, ambiguous)
  let top = area.row + 1
  let bottom = min(g.height, area.row + area.height)
  let left = area.col
  let right = min(g.width, area.col + area.width)
  if top >= bottom:
    return FocusSpot()
  template spot(r, c: int; h: FocusHow): FocusSpot =
    FocusSpot(found: true, row: r, col: c, how: h,
              text: g.rowTextIn(r, left, right - left))
  # The caret: a reversed cell on the current-line surface.
  for r in top ..< bottom:
    for c in left ..< right:
      let s = g.styleAt(r, c)
      if s.reverse and s.surface == srSurfaceCurrentLine:
        return spot(r, c, fhCaret)
  for (how, surface) in SelectionSurfaces:
    for r in top ..< bottom:
      for c in left ..< right:
        if g.styleAt(r, c).surface == surface:
          return spot(r, left, how)
  spot(top, left, fhFirstRow)

proc announcementOf*(spot: FocusSpot; enteredPane: bool;
                     paneName: string): string =
  ## §9.4 SR-D7: `<Pane>: <row>` when focus enters a pane, `<row>` alone
  ## when it moves inside one. An empty row is said as "blank".
  let row = if spot.text.len > 0: spot.text else: "blank"
  if enteredPane: paneName & ": " & row else: row
