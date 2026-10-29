## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/tui_session.lowLevelModelOf` turns the session's
## `LowLevelCodeVM` into the model below).
##
## app/views/low_level_code_pane.nim — PLAT-60. **THE LOW LEVEL CODE PANE,
## drawn.**
##
## The desktop's view (`viewmodel/views/isonim_low_level_code_view.nim`)
## draws a header — an error the engine reported, the function's load
## address, the source-sync toggle, what a step does, why the listing is not
## kept in step — over the listing: each run of instructions generated from
## one source line after that line, every instruction its offset (the step
## it was reached at; `StepId(…)` for Noir), its text and its source line.
## This pane draws the same parts in the same order with the same words,
## every one of which is the ViewModel's (`low_level_code_vm.displayRows`):
##
##     sync on · steps by line
##       13  let fuel = ship.fuel;
##     ▸ StepId(5)  <no instructions>               src/main.nr:13
##       14  assert(fuel > 0);
##       StepId(9)  <no instructions>               src/main.nr:14
##
## What the terminal adds to a row, from the same model: the EXECUTION
## POINTER (`▸`, on the debugger's line ground) on the instruction the
## debugger is at; the CROSS-REFERENCE — the instructions generated from the
## line the editor's caret is on, and the source line of the selected
## instruction, on the hover ground; the listing's own cursor on the
## selection ground. The fidelity badge and the executed count are drawn
## when the listing carries a mapping (a generated-code listing): the
## recording's own listing has none, and a column saying `unmapped` on every
## row would say nothing in a terminal's width. The rightmost column is the
## list's scrollbar when it overflows (Scrollbar-Scrubbers.md: a list's bar
## moves the VIEW), its mark the execution pointer's row.

import std/strutils

import codetracer_embed
import headless_app/pane_clicks   # the row menu the host builds (K62)

from ../formatters/type_formatters import terminalMeasure
import ../layout/profile
import ../layout/project
import ./styled_row
import ./scrubber_track

export styled_row, scrubber_track

type
  LowLevelPaneRowKind* = enum
    lpSource       ## a source line, before the instructions generated from it
    lpInstruction  ## one instruction

  LowLevelPaneRow* = object
    ## One row of the listing as the ViewModel words it (`LowLevelRowView`).
    kind*: LowLevelPaneRowKind
    index*: int
      ## lpInstruction: the instruction's index in the ViewModel's listing;
      ## -1 for a source line.
    path*: string
    line*: int
    text*: string
      ## lpSource: the line's text ("" until it arrives).
    offset*, instruction*, crossRef*, fidelity*, count*: string
      ## lpInstruction: the offset column, the instruction's name, arguments
      ## and annotation as one text, its `path:line`, the fidelity badge and
      ## the executed count.
    active*: bool
      ## The debugger's line marks it.
    linked*: bool
      ## Cross-referenced (the editor's caret line, or the selected
      ## instruction's source line).
    executing*: bool
      ## The execution pointer.
    selected*: bool
      ## The listing's cursor.

  LowLevelPaneModel* = object
    loaded*: bool
      ## Whether a session supplied the pane at all.
    error*: string
      ## What the engine refused, or why nothing could be loaded.
    address*: string
      ## `Originating address: 0x…`, "" for none.
    syncLabel*: string
    syncOn*: bool
    stepping*: string
      ## What a step does while the listing has the focus.
    notice*: string
      ## Why the listing is not kept in step with the source, "" when it is.
    empty*: string
      ## The listing's words when it lists nothing.
    showsFidelity*: bool
      ## The listing carries a mapping, so its rows' fidelity and counts mean
      ## something.
    rows*: seq[LowLevelPaneRow]
    executionRow*: int
      ## The display row of the execution pointer, -1 for none.
    selectedRow*: int
      ## The display row of the listing's cursor, -1 for none.
    linkedRow*: int
      ## The first display row cross-referenced to the editor's caret, -1.
    crossRefPath*: string
    crossRefLine*: int
      ## The source line the selected instruction came from, which the
      ## editor highlights; 0 for none.
    scrollTop*: int
      ## The first list row shown — the pane's own.

  LowLevelTargetKind* = enum
    ltNone, ltSync, ltHeader, ltSource, ltInstruction, ltTrack

  LowLevelTarget* = object
    kind*: LowLevelTargetKind
    index*: int
      ## ltInstruction: the instruction's index; -1 otherwise.
    row*: int
      ## ltSource / ltInstruction: the display row.

  LowLevelPaneScreen* = object
    syncCol*, syncCells*: int
      ## The sync toggle on the header's first row.
    headerRows*: int
    listTop*, listRows*: int
    trackCol*: int
      ## The scrollbar's column, -1 when the list fits.
    top*: int
      ## The display row the first list row shows (the clamped scroll).
    offsetCells*: int
    painted*: seq[string]
      ## Every painted list row's text, in order (for the suites).

  LowLevelActKind* = enum
    ## What the pane asks the HOST to do with the session's `LowLevelCodeVM`
    ## (`TuiApp.lowLevelAct`): this layer reads no ViewModel.
    llaPress        ## a press on instruction `index`: select it and go to its
                    ## source line (the desktop's click)
    llaRowMenu      ## build instruction `index`'s menu
    llaMenuChoice   ## a menu entry chosen (`action`, `target`)
    llaKey          ## a `list.*` move (`operation`, `page`)
    llaActivate     ## Enter: go to the selected instruction's source line
    llaToggleSync   ## the header's sync toggle
    llaClearSelection
    llaStep         ## a step key pressed in the listing (`operation`)
    llaSourceCursor ## the editor's caret is on `path:line` (0: none)

  LowLevelAct* = object
    kind*: LowLevelActKind
    index*: int
    action*: ContextAction
    target*: ContextTarget
    operation*: string
    page*: int
    path*: string
    line*: int

  LowLevelActResult* = object
    ## The host's answer.
    note*: string
      ## The status line's words, "" for none.
    menu*: ContextMenuModel
      ## A menu to open (llaRowMenu); no entries for none.
    copied*: string
      ## Text for the clipboard.
    moved*: bool
      ## The debugger moved (the host has read every pane again).
    handled*: bool
      ## llaStep: the step was done by instruction; false leaves the host's
      ## line step to run.

const
  LowLevelSyncOnStyle = CellStyle(role: srChromeText, surface: srSurfaceField)
  LowLevelSyncOffStyle = CellStyle(role: srChromeMuted,
                                   surface: srSurfaceField)
  LowLevelMutedStyle = CellStyle(role: srChromeMuted)
  LowLevelTextStyle = CellStyle(role: srChromeText)
  LowLevelErrorStyle* = CellStyle(role: srChromeError)
  LowLevelNoticeStyle = CellStyle(role: srChromeNotification)
  LowLevelSourceStyle = CellStyle(role: srChromeText, bold: true)
  LowLevelLineNumberStyle = CellStyle(role: srLineNumber)
  LowLevelActiveLineNumberStyle = CellStyle(role: srLineNumberActive)
  LowLevelPointerStyle* = CellStyle(role: srGutterExecutionPointer)
  LowLevelExecutingSurface* = srSurfaceCurrentLine
    ## The execution pointer's row: the editor's execution-line ground.
  LowLevelLinkedSurface* = srSurfaceActiveRow
    ## A cross-referenced row: the hover ground.
  LowLevelSelectedSurface* = srSurfaceSelection
  LowLevelPointerCells* = 2
    ## The pointer's column and its gap.
  LowLevelGapCells = 1

proc clampLowLevelTop*(total, top, listRows: int): int =
  clamp(top, 0, max(0, total - max(1, listRows)))

proc headerLines(model: LowLevelPaneModel): seq[tuple[text: string;
                                                       style: CellStyle]] =
  ## The header's rows after the controls row: the error, the address and the
  ## notice, as the desktop's header stacks them.
  if model.error.len > 0: result.add (model.error, LowLevelErrorStyle)
  if model.address.len > 0: result.add (model.address, LowLevelMutedStyle)
  if model.notice.len > 0: result.add (model.notice, LowLevelNoticeStyle)

proc offsetWidth(model: LowLevelPaneModel): int =
  for r in model.rows:
    if r.kind == lpInstruction:
      result = max(result, cellWidthOf(r.offset))

proc lineNumberWidth(model: LowLevelPaneModel): int =
  for r in model.rows:
    if r.kind == lpSource:
      result = max(result, cellWidthOf($r.line))

proc rowSurface(r: LowLevelPaneRow): tuple[shown: bool; role: SemanticRole] =
  ## The row's ground: the cursor over the cross-reference over the pointer.
  if r.selected: (true, LowLevelSelectedSurface)
  elif r.linked: (true, LowLevelLinkedSurface)
  elif r.executing: (true, LowLevelExecutingSurface)
  else: (false, srNone)

proc paintFitted(g: var StyledGrid; row, col, width: int; text: string;
                 style: CellStyle): string =
  if width <= 0 or text.len == 0:
    return ""
  let cell = fitCell(text, width, terminalMeasure)
  g.paint(row, col, cell.text, style)
  cell.text

proc paintLowLevelCode*(g: var StyledGrid; area: CellArea;
                        model: LowLevelPaneModel): LowLevelPaneScreen =
  ## The pane into `area` (the rows below its tab strip) and nowhere else.
  result = LowLevelPaneScreen(trackCol: -1, syncCol: -1)
  if area.width <= 0 or area.height <= 0:
    return
  # Row 0: the controls — the sync toggle, then what a step does.
  let sync = " " & model.syncLabel & " "
  let syncCells = min(cellWidthOf(sync), area.width)
  result.syncCol = area.col
  result.syncCells = syncCells
  g.paint(area.row, area.col, truncateToCells(sync, syncCells),
          if model.syncOn: LowLevelSyncOnStyle else: LowLevelSyncOffStyle)
  let stepping = " " & g.glyphText(grSeparator) & " " & model.stepping
  if area.width > syncCells:
    g.paint(area.row, area.col + syncCells,
            truncateToCells(stepping, area.width - syncCells),
            LowLevelMutedStyle)
  var y = area.row + 1
  let bottom = area.row + area.height
  for (text, style) in model.headerLines:
    if y >= bottom - 1:
      break
    g.paint(y, area.col, truncateToCells(text, area.width), style)
    inc y
  result.headerRows = y - area.row
  result.listTop = y
  result.listRows = max(0, bottom - y)
  if result.listRows <= 0:
    return
  if model.rows.len == 0:
    if model.empty.len > 0:
      let t = truncateToCells(model.empty, area.width)
      g.paint(y, area.col, t, LowLevelMutedStyle)
      result.painted.add t
    return
  var width = area.width
  let total = model.rows.len
  if total > result.listRows:
    width = max(0, area.width - ScrubberTrackCells)
    result.trackCol = area.col + area.width - ScrubberTrackCells
  let offsetW = model.offsetWidth
  result.offsetCells = offsetW
  let numberW = model.lineNumberWidth
  let first = clampLowLevelTop(total, model.scrollTop, result.listRows)
  result.top = first
  for k in 0 ..< result.listRows:
    let i = first + k
    if i >= total:
      break
    let r = model.rows[i]
    let ry = result.listTop + k
    let (hasGround, ground) = r.rowSurface
    if hasGround:
      g.fillSurface(ry, area.col, width, 1, ground)
    var text = ""
    case r.kind
    of lpSource:
      # `  13  let fuel = ship.fuel;` — under the pointer's column, the line
      # number right-aligned, then the line's own text (TEXT: the recorded
      # program's source, never markup).
      var col = area.col + LowLevelPointerCells
      let number = padLeft($r.line, numberW)
      text = repeat(' ', LowLevelPointerCells) & number
      col += cellWidthOf(g.paintFitted(ry, col, area.col + width - col,
        number, if r.active: LowLevelActiveLineNumberStyle
                else: LowLevelLineNumberStyle))
      col += LowLevelGapCells + 1
      if col < area.col + width and r.text.len > 0:
        let src = g.paintFitted(ry, col, area.col + width - col, r.text,
                                LowLevelSourceStyle)
        text.add "  " & src
    of lpInstruction:
      var col = area.col
      if r.executing:
        g.paintGlyph(ry, col, grExecPointer, LowLevelPointerStyle)
        text = g.glyphText(grExecPointer) & " "
      else:
        text = "  "
      col += LowLevelPointerCells
      let offset = padLeft(r.offset, offsetW)
      text.add g.paintFitted(ry, col, area.col + width - col, offset,
                             LowLevelMutedStyle)
      col += offsetW + 2 * LowLevelGapCells
      # The right part, never cut before the instruction: its source line,
      # then (with a mapping) the fidelity and the count.
      var right = r.crossRef
      if model.showsFidelity:
        if r.fidelity.len > 0: right.add "  " & r.fidelity
        if r.count.len > 0: right.add "  " & r.count
      let room = area.col + width - col
      let rightCells = cellWidthOf(right)
      let instrRoom = if right.len > 0 and room > rightCells + 12:
                        room - rightCells - LowLevelGapCells * 2
                      else: room
      let instr = g.paintFitted(ry, col, instrRoom, r.instruction,
                                LowLevelTextStyle)
      text.add "  " & instr
      if right.len > 0 and instrRoom < room:
        let rcol = area.col + width - rightCells
        g.paint(ry, rcol, right, LowLevelMutedStyle)
        text.add "  " & right
    result.painted.add text
  if result.trackCol >= 0:
    let mark = model.executionRow
    g.paintVerticalScrubber(result.trackCol, result.listTop, result.listRows,
      scrubberModel(total, first, result.listRows, current = mark))

proc lowLevelTargetAt*(model: LowLevelPaneModel; screen: LowLevelPaneScreen;
                       area: CellArea; row, col: int): LowLevelTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  result = LowLevelTarget(kind: ltNone, index: -1, row: -1)
  if area.width <= 0 or not area.contains(row, col):
    return
  if row == area.row:
    if col >= screen.syncCol and col < screen.syncCol + screen.syncCells:
      return LowLevelTarget(kind: ltSync, index: -1, row: -1)
    return LowLevelTarget(kind: ltHeader, index: -1, row: -1)
  if row < screen.listTop:
    return LowLevelTarget(kind: ltHeader, index: -1, row: -1)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row >= screen.listTop and row < screen.listTop + screen.listRows:
    return LowLevelTarget(kind: ltTrack, index: -1, row: -1)
  if row >= screen.listTop + screen.listRows:
    return
  let i = screen.top + (row - screen.listTop)
  if i < 0 or i >= model.rows.len:
    return
  let r = model.rows[i]
  result = case r.kind
    of lpSource: LowLevelTarget(kind: ltSource, index: -1, row: i)
    of lpInstruction: LowLevelTarget(kind: ltInstruction, index: r.index,
                                     row: i)

proc revealRow*(model: LowLevelPaneModel; listRows, row: int): int =
  ## The scroll top that keeps display row `row` in view.
  let rows = max(1, listRows)
  let top = clampLowLevelTop(model.rows.len, model.scrollTop, rows)
  if row < 0: top
  elif row < top: row
  elif row >= top + rows: row - rows + 1
  else: top

proc rowOfInstruction*(model: LowLevelPaneModel; index: int): int =
  ## The display row of instruction `index`, -1 when it is not listed.
  for i, r in model.rows:
    if r.kind == lpInstruction and r.index == index:
      return i
  -1
