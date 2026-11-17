## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/tui_session.refreshMacroExpansion` turns the
## session's `MacroExpansionVM` into the model below).
##
## app/views/macro_expansion_pane.nim — Editor-Hosted-Front-Ends §E15. **THE
## MACRO EXPANSION PANE, drawn.**
##
## Toggle Macro Expansion on a macro call shows the code it expanded to. The
## desktop opens it inline under the call (a Monaco view zone); the terminal
## shows it beside the source, as it shows the Low Level Code, so the call
## and its expansion are both in view:
##
##     main.nim:17 · expanded.nim 1–4
##        1  # addTwice expansion in main internal line 2
##        2
##     ▸  3  counter += 3
##        4  counter += 3
##
## Every word is the ViewModel's (`macro_expansion_vm.displayRows`): each
## open expansion's heading — a press on it closes that expansion — over its
## lines, numbered from 1 as the desktop's expansion editor numbers them. The
## terminal adds the EXECUTION POINTER (`▸`, on the debugger's line ground) on
## the row the debugger is at, and the list's scrollbar when it overflows.

import std/strutils

import codetracer_embed

from ../formatters/type_formatters import terminalMeasure
import ../layout/profile
import ../layout/project
import ./styled_row
import ./scrubber_track

export styled_row, scrubber_track

type
  MacroExpansionPaneRowKind* = enum
    mpHeading
    mpLine
    mpNotice

  MacroExpansionPaneRow* = object
    kind*: MacroExpansionPaneRowKind
    text*: string
    number*: int
    executing*: bool
    callPath*: string
    callLine*: int
      ## The expansion the row belongs to: a press on a heading toggles it.

  MacroExpansionPaneModel* = object
    loaded*: bool
      ## Whether a session supplied the pane at all.
    rows*: seq[MacroExpansionPaneRow]
    empty*: string
      ## The pane's words when no expansion is open.
    executionRow*: int
      ## The display row of the execution pointer, -1 for none.
    scrollTop*: int

  MacroExpansionPaneScreen* = object
    listTop*, listRows*: int
    top*: int
      ## The display row the first list row shows (the clamped scroll).
    trackCol*: int
      ## The scrollbar's column, -1 when the list fits.
    painted*: seq[string]
      ## Every painted row's text, in order (for the suites).

const
  MacroHeadingStyle = CellStyle(role: srChromeText, bold: true)
  MacroMutedStyle = CellStyle(role: srChromeMuted)
  MacroTextStyle = CellStyle(role: srChromeText)
  MacroLineNumberStyle = CellStyle(role: srLineNumber)
  MacroActiveLineNumberStyle = CellStyle(role: srLineNumberActive)
  MacroPointerStyle = CellStyle(role: srGutterExecutionPointer)
  MacroExecutingSurface = srSurfaceCurrentLine
    ## The execution pointer's row: the editor's execution-line ground, as
    ## the Low Level Code pane marks its own.
  MacroPointerCells = 2
    ## The pointer's column and its gap.

proc clampMacroTop*(total, top, listRows: int): int =
  clamp(top, 0, max(0, total - max(1, listRows)))

proc numberWidth(model: MacroExpansionPaneModel): int =
  for r in model.rows:
    if r.kind == mpLine:
      result = max(result, cellWidthOf($r.number))

proc paintFitted(g: var StyledGrid; row, col, width: int; text: string;
                 style: CellStyle): string =
  if width <= 0 or text.len == 0:
    return ""
  let cell = fitCell(text, width, terminalMeasure)
  g.paint(row, col, cell.text, style)
  cell.text

proc paintMacroExpansion*(g: var StyledGrid; area: CellArea;
                          model: MacroExpansionPaneModel):
    MacroExpansionPaneScreen =
  ## The pane into `area` (the rows below its tab strip) and nowhere else.
  result = MacroExpansionPaneScreen(trackCol: -1, listTop: area.row,
                                    listRows: max(0, area.height))
  if area.width <= 0 or area.height <= 0:
    return
  if model.rows.len == 0:
    let t = g.paintFitted(area.row, area.col, area.width, model.empty,
                          MacroMutedStyle)
    result.painted.add t
    return
  var width = area.width
  let total = model.rows.len
  if total > result.listRows:
    width = max(0, area.width - ScrubberTrackCells)
    result.trackCol = area.col + area.width - ScrubberTrackCells
  let numberW = model.numberWidth
  let first = clampMacroTop(total, model.scrollTop, result.listRows)
  result.top = first
  for k in 0 ..< result.listRows:
    let i = first + k
    if i >= total:
      break
    let r = model.rows[i]
    let ry = result.listTop + k
    var text = ""
    case r.kind
    of mpHeading:
      text = g.paintFitted(ry, area.col, width, r.text, MacroHeadingStyle)
    of mpNotice:
      text = repeat(' ', MacroPointerCells) &
        g.paintFitted(ry, area.col + MacroPointerCells,
                      width - MacroPointerCells, r.text, MacroMutedStyle)
    of mpLine:
      if r.executing:
        g.fillSurface(ry, area.col, width, 1, MacroExecutingSurface)
        g.paintGlyph(ry, area.col, grExecPointer, MacroPointerStyle)
        text = g.glyphText(grExecPointer) & " "
      else:
        text = "  "
      var col = area.col + MacroPointerCells
      let number = padLeft($r.number, numberW)
      text.add g.paintFitted(ry, col, area.col + width - col, number,
        if r.executing: MacroActiveLineNumberStyle else: MacroLineNumberStyle)
      col += numberW + 2
      # TEXT: the compiler's rendering of the expanded code, never markup.
      if col < area.col + width and r.text.len > 0:
        text.add "  " & g.paintFitted(ry, col, area.col + width - col, r.text,
                                      MacroTextStyle)
    result.painted.add text
  if result.trackCol >= 0:
    g.paintVerticalScrubber(result.trackCol, result.listTop, result.listRows,
      scrubberModel(total, first, result.listRows, current = model.executionRow))

proc macroExpansionRowAt*(model: MacroExpansionPaneModel;
                          screen: MacroExpansionPaneScreen;
                          area: CellArea; row, col: int): int =
  ## The display row a press at `(row, col)` is on, -1 for none (the
  ## scrollbar, or past the rows).
  if area.width <= 0 or not area.contains(row, col):
    return -1
  if screen.trackCol >= 0 and col == screen.trackCol:
    return -1
  if row < screen.listTop or row >= screen.listTop + screen.listRows:
    return -1
  let i = screen.top + (row - screen.listTop)
  if i < 0 or i >= model.rows.len: -1 else: i

proc revealMacroRow*(model: MacroExpansionPaneModel; listRows, row: int): int =
  ## The scroll top that keeps display row `row` in view.
  let rows = max(1, listRows)
  let top = clampMacroTop(model.rows.len, model.scrollTop, rows)
  if row < 0: top
  elif row < top: row
  elif row >= top + rows: row - rows + 1
  else: top
