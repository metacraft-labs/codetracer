## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/scratchpad_pane.nim — PLAT-50. The terminal's **Scratchpad**
## pane: the values the user pinned ("Add value to scratchpad" on a call-trace
## argument or an inline value), one row each, as the desktop's scratchpad
## lists them (`viewmodel/views/isonim_scratchpad_view.nim`): a close button,
## then `expression: value` — a repeated capture of one expression is one row
## whose value lists the samples (`ScratchpadVM.addValue`).
##
## Until PLAT-50 the pane was a report leaf here ("the terminal has no
## scratchpad view yet"), and nothing in the terminal could add to it.
##
##     ✕ left: 2
##     ✕ expression: "2 + 3", "10 - 4 + 1"
##
## A pure function of `ScratchpadPaneModel` (the host converts the
## ViewModel's rows); `scratchpadHitAt` reads a press back against the same
## arithmetic, so a click and the drawing cannot disagree.

import std/[strutils, wordwrap]

import ../layout/profile
import ../layout/project
import ./header
import ./styled_row

type
  ScratchpadPaneRow* = object
    expression*: string
    value*: string

  ScratchpadPaneModel* = object
    rows*: seq[ScratchpadPaneRow]
    loaded*: bool
      ## Whether a session supplied the pane at all.

  ScratchpadHit* = object
    ## What a press on the pane is on.
    row*: int
      ## The pinned value's index, -1 for none.
    close*: bool
      ## On its close button.

const
  ScratchpadCloseGlyph* = "✕"
    ## The desktop's `close-element` button (`ScratchpadVM.removeValue`).
  ScratchpadCloseCells* = 2
    ## The button and the space after it.
  ScratchpadEmptyText* =
    "You can add values from other components by right clicking on them " &
    "and then click on 'Add value to scratchpad'."
    ## The desktop's empty state (`isonim_scratchpad_view.
    ## ScratchpadEmptyStateText`), word for word.
  ScratchpadEmptyStyle = CellStyle(role: srChromeMuted, italic: true)
  ScratchpadNameStyle = CellStyle(role: srChromeTitle)
  ScratchpadCloseStyle = CellStyle(role: srChromeMuted)

proc rowText*(r: ScratchpadPaneRow): string =
  ## A row after its close button, as the pane draws it.
  r.expression & ": " & r.value

proc paintScratchpad*(g: var StyledGrid; area: CellArea;
                      model: ScratchpadPaneModel): seq[string] =
  ## Paint the pane into `area` (its first row is under the tab strip, as
  ## every pane's is), and answer the rows' texts as painted.
  if area.width <= 0 or area.height <= 1:
    return
  let body = area.row + 1
  if model.rows.len == 0:
    var line = 0
    for piece in wrapWords(ScratchpadEmptyText, max(1, area.width)).splitLines():
      if body + line >= area.row + area.height: break
      g.paint(body + line, area.col, fitCells(piece, area.width),
              ScratchpadEmptyStyle)
      inc line
    return
  for i, r in model.rows:
    let y = body + i
    if y >= area.row + area.height: break
    g.paint(y, area.col, ScratchpadCloseGlyph & " ", ScratchpadCloseStyle)
    let room = area.width - ScratchpadCloseCells
    if room <= 0: continue
    let name = truncateToCells(r.expression & ": ", room)
    g.paint(y, area.col + ScratchpadCloseCells, name, ScratchpadNameStyle)
    let used = cellWidthOf(name)
    if used < room:
      g.paint(y, area.col + ScratchpadCloseCells + used,
              fitCells(r.value, room - used))
    result.add fitCells(r.rowText(), room)

proc scratchpadHitAt*(model: ScratchpadPaneModel; area: CellArea;
                      row, col: int): ScratchpadHit =
  ## The pinned value a press at `(row, col)` is on, for the pane painted into
  ## `area` by `paintScratchpad`, and whether it is on the close button.
  result = ScratchpadHit(row: -1)
  if area.width <= 0 or not area.contains(row, col):
    return
  let i = row - area.row - 1
  if i < 0 or i >= model.rows.len:
    return
  result = ScratchpadHit(row: i, close: col == area.col)
