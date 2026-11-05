## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/constraints_source.paneModelOf` turns the
## window's shared `ConstraintsVM` into the model below).
##
## app/views/constraints_pane.nim — PLAT-62. **THE CONSTRAINTS PANE, drawn.**
##
## The desktop's panel (`viewmodel/views/isonim_constraints_view.nim`) draws
## the headline — the circuit's ACIR and unconstrained opcode counts, with
## `(stale)` when the sources changed since — a notice when the report has
## counts and no printed rows, one row per function the compiler named (its
## name, its kind, its count and the line that declares it), each function's
## printed opcodes under it when there is a listing, and how the counts were
## obtained; with no report, why there is none. This pane draws the same
## parts in the same order with the same words, every one of which is the
## ViewModel's (`constraints_vm`):
##
##     18 ACIR opcodes, 33 unconstrained
##     main                acir           18  src/main.nr:3
##     halve               unconstrained  16  src/main.nr:11
##     directive_invert    unconstrained   9
##     nargo info --json, run just now
##
## The function row's parts are `table_fit.constraintsFit` — the desktop's
## grid: the name takes the slack and is cut with `…`, the kind and the count
## are never cut. The rightmost column is the list's scrollbar when it
## overflows. The selected row — the cursor a press, the keyboard and the
## row menu share — is drawn on the selection surface; a row a press takes to
## its source is drawn in the text colour, one placed nowhere muted.

import std/strutils

import codetracer_embed
import headless_app/pane_clicks   # the row menu the host builds

from ../formatters/type_formatters import terminalMeasure
import ../layout/profile
import ../layout/project
import ./styled_row
import ./scrubber_track

export styled_row, scrubber_track

type
  ConstraintsPaneRow* = object
    index*: int
      ## The row's index in the ViewModel's `rows`.
    opcode*: bool
      ## A printed opcode under its function; else the function's row.
    unconstrained*: bool
      ## A function counted in unconstrained (Brillig) opcodes.
    name*, kind*, count*, where*, args*: string
    linked*: bool
      ## A press goes to a source line.
    title*: string
      ## Where a press goes, or why it goes nowhere (the desktop's tooltip).

  ConstraintsPaneModel* = object
    loaded*: bool
      ## Whether a host supplied the pane at all.
    headline*: string
    stale*: bool
      ## The counts no longer describe the sources (the desktop dims them).
    notice*: string
      ## Why the report has counts and no printed rows; "" for none.
    provenance*: string
      ## How the counts were obtained; "" for none.
    absence*: string
      ## Why there is no report; "" when there is one.
    rows*: seq[ConstraintsPaneRow]
    selected*: int
      ## The selected row's index, -1 for none.
    scrollTop*: int
      ## The first list row shown.

  ConstraintsTargetKind* = enum
    cgNone, cgRow, cgTrack, cgText

  ConstraintsTarget* = object
    kind*: ConstraintsTargetKind
    index*: int
      ## cgRow: the row's index.

  ConstraintsPaneScreen* = object
    noticeRow*: int
      ## The notice's row, -1 for none.
    listTop*, listRows*: int
    trackCol*: int
      ## The scrollbar's column, -1 when the list fits.
    provenanceRow*: int
      ## The provenance line's row, -1 for none.
    fit*: TableFit
    painted*: seq[string]
      ## Every painted list row's text, in order (for the suites).

  ConstraintsActKind* = enum
    ## What the pane asks the HOST to do with the window's `ConstraintsVM`
    ## (`TuiApp.constraintsAct`): this layer reads no ViewModel.
    cakSelect      ## select row `index`
    cakOpen        ## select row `index` and open its source (a press, Enter)
    cakRowMenu     ## build row `index`'s menu
    cakMenuChoice  ## a Constraints menu entry chosen (`action`, `target`)
    cakKey         ## a `list.*` move (`operation`, `page`)
    cakCopy        ## the selected row's name to the clipboard (`list.copy`)

  ConstraintsAct* = object
    kind*: ConstraintsActKind
    index*: int
    action*: ContextAction
    target*: ContextTarget
    operation*: string
    page*: int

  ConstraintsActResult* = object
    ## The host's answer.
    note*: string
      ## The status line's words, "" for none.
    menu*: ContextMenuModel
      ## A menu to open (cakRowMenu); no entries for none.
    copied*: string
      ## Text for the clipboard.
    opened*: bool
      ## A source file was opened (the editor has the keys now).

const
  ConstraintsHeadlineStyle = CellStyle(role: srChromeText)
  ConstraintsMutedStyle = CellStyle(role: srChromeMuted)
  ConstraintsTextStyle = CellStyle(role: srChromeText)
  ConstraintsCountStyle = CellStyle(role: srChromeText)
  ConstraintsSelectedSurface = srSurfaceSelection
  ConstraintsGapCells* = 1
  ConstraintsOpcodeIndent* = 2
    ## An opcode row sits under its function, indented (the desktop's
    ## `padding-left: 1em`).

proc columnsFor*(model: ConstraintsPaneModel; width: int): TableFit =
  ## The function rows' four parts in a list `width` cells wide, sized to
  ## the rows.
  var name, kind, count, where = 0
  for r in model.rows:
    if r.opcode:
      continue
    name = max(name, cellWidthOf(r.name))
    kind = max(kind, cellWidthOf(r.kind))
    count = max(count, cellWidthOf(r.count))
    where = max(where, cellWidthOf(r.where))
  constraintsFit(name, kind, count, where, width, gap = ConstraintsGapCells)

proc clampConstraintsTop*(total, top, listRows: int): int =
  clamp(top, 0, max(0, total - max(1, listRows)))

proc paintCell(g: var StyledGrid; row, col, width: int; text: string;
               style: CellStyle): string =
  if width <= 0:
    return ""
  let cell = fitCell(text, width, terminalMeasure)
  g.paint(row, col, cell.text, style)
  cell.text

proc paintRight(g: var StyledGrid; row, col, width: int; text: string;
                style: CellStyle): string =
  ## A right-aligned cell — the count, as the desktop's `text-align: right`.
  if width <= 0:
    return ""
  let t = truncateToCells(text, width)
  let pad = max(0, width - cellWidthOf(t))
  g.paint(row, col + pad, t, style)
  repeat(' ', pad) & t

proc wrapped(text: string; width: int): seq[string] =
  ## `text` broken into lines `width` cells wide at spaces.
  if width <= 0:
    return @[]
  var line = ""
  for word in text.splitWhitespace():
    let candidate = if line.len == 0: word else: line & " " & word
    if cellWidthOf(candidate) <= width:
      line = candidate
    else:
      if line.len > 0:
        result.add line
      line = truncateToCells(word, width)
  if line.len > 0:
    result.add line

proc paintConstraints*(g: var StyledGrid; area: CellArea;
                       model: ConstraintsPaneModel): ConstraintsPaneScreen =
  ## The pane into `area` (the rows below its tab strip) and nowhere else.
  result = ConstraintsPaneScreen(noticeRow: -1, trackCol: -1,
                                 provenanceRow: -1)
  if area.width <= 0 or area.height <= 0:
    return
  var y = area.row
  let bottom = area.row + area.height
  # The headline, dimmed with the rows while stale (its `(stale)` says why).
  discard g.paintCell(y, area.col, area.width, model.headline,
                      if model.stale: ConstraintsMutedStyle
                      else: ConstraintsHeadlineStyle)
  inc y
  if model.absence.len > 0:
    for line in wrapped(model.absence, area.width):
      if y >= bottom:
        break
      g.paint(y, area.col, line, ConstraintsMutedStyle)
      result.painted.add line
      inc y
    return
  if model.notice.len > 0 and y < bottom:
    result.noticeRow = y
    discard g.paintCell(y, area.col, area.width, model.notice,
                        ConstraintsMutedStyle)
    inc y
  var listEnd = bottom
  if model.provenance.len > 0 and bottom - y >= 2:
    result.provenanceRow = bottom - 1
    discard g.paintCell(result.provenanceRow, area.col, area.width,
                        model.provenance, ConstraintsMutedStyle)
    listEnd = bottom - 1
  result.listTop = y
  result.listRows = max(0, listEnd - y)
  let rows = result.listRows
  if rows <= 0:
    return
  var width = area.width
  if model.rows.len > rows:
    width = max(0, area.width - ScrubberTrackCells)
    result.trackCol = area.col + area.width - ScrubberTrackCells
  let fit = model.columnsFor(width)
  result.fit = fit
  let first = clampConstraintsTop(model.rows.len, model.scrollTop, rows)
  for k in 0 ..< rows:
    let i = first + k
    if i >= model.rows.len:
      break
    let r = model.rows[i]
    let ry = result.listTop + k
    if r.index == model.selected:
      g.fillSurface(ry, area.col, width, 1, ConstraintsSelectedSurface)
    let muted = model.stale or not r.linked
    let main = if model.stale or r.unconstrained or not r.linked:
                 ConstraintsMutedStyle
               else: ConstraintsTextStyle
    if r.opcode:
      let text = r.count & " " & r.name &
                 (if r.args.len > 0: " " & r.args else: "")
      result.painted.add repeat(' ', ConstraintsOpcodeIndent) &
        g.paintCell(ry, area.col + ConstraintsOpcodeIndent,
                    width - ConstraintsOpcodeIndent, text,
                    if muted: ConstraintsMutedStyle
                    else: ConstraintsTextStyle)
      continue
    template col(i: int): int = area.col + fit.starts[i]
    var text = g.paintCell(ry, col(0), fit.widths[0], r.name, main)
    text.add " " & g.paintCell(ry, col(1), fit.widths[1], r.kind,
                               ConstraintsMutedStyle)
    text.add " " & g.paintRight(ry, col(2), fit.widths[2], r.count,
                                if model.stale: ConstraintsMutedStyle
                                else: ConstraintsCountStyle)
    text.add " " & g.paintCell(ry, col(3), fit.widths[3], r.where,
                               ConstraintsMutedStyle)
    result.painted.add text
  if result.trackCol >= 0:
    g.paintVerticalScrubber(result.trackCol, result.listTop, rows,
      scrubberModel(model.rows.len, first, rows))

proc constraintsTargetAt*(model: ConstraintsPaneModel;
                          screen: ConstraintsPaneScreen; area: CellArea;
                          row, col: int): ConstraintsTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  if area.width <= 0 or not area.contains(row, col):
    return ConstraintsTarget(kind: cgNone, index: -1)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row >= screen.listTop and row < screen.listTop + screen.listRows:
    return ConstraintsTarget(kind: cgTrack, index: -1)
  if row < screen.listTop or row >= screen.listTop + screen.listRows:
    return ConstraintsTarget(kind: cgText, index: -1)
  let i = clampConstraintsTop(model.rows.len, model.scrollTop,
                              screen.listRows) + (row - screen.listTop)
  if i < 0 or i >= model.rows.len:
    return ConstraintsTarget(kind: cgNone, index: -1)
  ConstraintsTarget(kind: cgRow, index: model.rows[i].index)

proc lineOfIndex*(model: ConstraintsPaneModel; index: int): int =
  ## The list row of row `index`, -1 when it is not listed.
  for i, r in model.rows:
    if r.index == index:
      return i
  -1

proc revealIndex*(model: ConstraintsPaneModel; listRows, index: int): int =
  ## The scroll top that keeps row `index` in view.
  let at = model.lineOfIndex(index)
  let rows = max(1, listRows)
  let top = clampConstraintsTop(model.rows.len, model.scrollTop, rows)
  if at < 0: top
  elif at < top: at
  elif at >= top + rows: at - rows + 1
  else: top
