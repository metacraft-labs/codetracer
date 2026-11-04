## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/verification_source.paneModelOf` turns the
## window's shared `VerificationVM` into the model below).
##
## app/views/verification_pane.nim — PLAT-63. **THE VERIFICATION PANE,
## drawn.**
##
## The desktop's View › Verification (`viewmodel/views/
## isonim_verification_view.nim`) draws the run's status and command line,
## its Stop control while it runs, the notes that keep a run that answers
## nothing from reading as a verdict, the counterexample offers, then the
## findings BY KIND — each kind's heading over its rows, each row its kind in
## words, its title and the verifier's message — and, while a counterexample
## is open, its steps. This pane draws the same parts in the same order with
## the same words, every one of which is the ViewModel's
## (`VerificationVM.panelModel(...).lines`):
##
##     not proved — 1s                                 ▶ Verify with Verno
##     verno --program-dir . formal-verify -- --rlimit 60
##     ▸ Step through the counterexample  postcondition not satisfied  src/…
##     failed obligation (1)
##       failed obligation  src/main.nr:7  postcondition not satisfied
##
## The Run control is the host's (`canRun`: a project that declares a Verno
## action, and no run in flight). The selected line — the cursor a press and
## the keys share — is drawn on the selection surface; a failed obligation's
## kind on the error role, a limitation's on the notification role. The
## rightmost column is the list's scrollbar when it overflows
## (Scrollbar-Scrubbers.md: a list's bar moves the VIEW).

import std/strutils

import codetracer_embed
import headless_app/pane_clicks   # the row menu the host builds (K65)

from ../formatters/type_formatters import terminalMeasure
import ../layout/profile
import ../layout/project
import ./styled_row
import ./glyph_table
import ./scrubber_track

export styled_row, scrubber_track

type
  VerificationPaneModel* = object
    loaded*: bool
      ## Whether a host supplied the pane at all.
    status*: string
    command*: string
    runLabel*: string
      ## The Run control's words; "" when none is drawn.
    stopShown*: bool
    lines*: seq[VerificationLine]
      ## The shared model's lines, as they are.
    selectedKey*: string
    scrollTop*: int
      ## The first list row shown — the pane's own.

  VerificationTargetKind* = enum
    vtNone, vtRun, vtStop, vtHeader, vtLine, vtTrack

  VerificationTarget* = object
    kind*: VerificationTargetKind
    key*: string
      ## vtLine: the line's key ("" for a line the cursor skips).
    line*: int
      ## vtLine: the list index.

  VerificationPaneScreen* = object
    runCol*, runCells*: int
    stopCol*, stopCells*: int
      ## The header's controls on its first row; cells 0 for none.
    headerRows*: int
    listTop*, listRows*: int
    trackCol*: int
      ## The scrollbar's column, -1 when the list fits.
    top*: int
      ## The list row the first painted row shows (the clamped scroll).
    painted*: seq[string]
      ## Every painted list row's text, in order (for the suites).

  VerificationActKind* = enum
    ## What the pane asks the HOST to do with the window's `VerificationVM`
    ## (`TuiApp.verificationAct`): this layer reads no ViewModel.
    vrPress      ## a press on line `key`: `activateLine`
    vrRowMenu    ## build line `key`'s menu
    vrMenuChoice ## a menu entry chosen (`action`, `target`)
    vrKey        ## a `list.*` move (`operation`, `page`)
    vrActivate   ## Enter on the cursor's line
    vrRun        ## the Run control
    vrStop       ## the Stop control

  VerificationAct* = object
    kind*: VerificationActKind
    key*: string
    action*: ContextAction
    target*: ContextTarget
    operation*: string
    page*: int

  VerificationActResult* = object
    ## The host's answer.
    note*: string
      ## The status line's words, "" for none.
    menu*: ContextMenuModel
      ## A menu to open (vrRowMenu); no entries for none.
    copied*: string
      ## Text for the clipboard.
    opened*: bool
      ## A file was opened in the editor (the editor has the keyboard).

const
  VerificationRunGlyph* = grRunControl
    ## The Run control's mark (the glyph table's run control).
  VerificationOfferGlyph* = grExecPointer
  VerificationCurrentStepGlyph* = grExecPointer
    ## An offer's mark and the counterexample's current step: the pointer
    ## mark the Low Level Code pane uses for the instruction it is at.
  VerificationStopLabel* = "Stop"
    ## The desktop's Stop button's words.
  VerificationGapCells = 2
  VerificationIndentCells* = 2
    ## A finding under its kind's heading.
  VerificationStatusStyle = CellStyle(role: srChromeText)
  VerificationCommandStyle = CellStyle(role: srChromeMuted)
  VerificationControlStyle = CellStyle(role: srChromeText,
                                       surface: srSurfaceField)
  VerificationNoteStyle = CellStyle(role: srChromeMuted)
  VerificationHeadingStyle = CellStyle(role: srChromeMuted, bold: true)
  VerificationTextStyle = CellStyle(role: srChromeText)
  VerificationMutedStyle = CellStyle(role: srChromeMuted)
  VerificationFailureStyle* = CellStyle(role: srChromeError)
    ## A failed obligation's kind (the desktop's `-failed-obligation` row).
  VerificationLimitationStyle* = CellStyle(role: srChromeNotification)
    ## A limitation's kind: the verifier, not the program.
  VerificationOtherKindStyle* = CellStyle(role: srChromeInfo)
  VerificationOfferStyle* = CellStyle(role: srChromeAccent)
  VerificationSelectedSurface* = srSurfaceSelection
  VerificationCurrentStepSurface* = srSurfaceCurrentLine

proc kindStyle*(kind: VerificationFindingKind): CellStyle =
  case kind
  of vfkFailedObligation: VerificationFailureStyle
  of vfkLimitation: VerificationLimitationStyle
  else: VerificationOtherKindStyle

proc clampVerificationTop*(total, top, listRows: int): int =
  clamp(top, 0, max(0, total - max(1, listRows)))

proc lineText*(line: VerificationLine; offerMark, currentMark: string):
    string =
  ## A line as the pane writes it — the parts the desktop's row shows, in
  ## its order, two cells apart; the marks are the glyph table's, for this
  ## frame's profile.
  proc join(parts: openArray[string]): string =
    for p in parts:
      if p.len == 0:
        continue
      if result.len > 0:
        result.add "  "
      result.add p
  case line.kind
  of vlNote, vlGroup, vlCounterexample: line.text
  of vlOffer:
    offerMark & " " & join([line.title, line.message, line.location])
  of vlFinding:
    " ".repeat(VerificationIndentCells) &
      join([line.kindLabel, line.title, line.message])
  of vlStep:
    (if line.isCurrent: currentMark else: " ") & " " &
      join([$(line.row + 1) & ". " & line.title, line.message,
            line.location])

proc paintFitted(g: var StyledGrid; row, col, width: int; text: string;
                 style: CellStyle): string =
  if width <= 0:
    return ""
  let cell = fitCell(text, width, terminalMeasure)
  g.paint(row, col, cell.text, style)
  cell.text

proc paintLine(g: var StyledGrid; row, col, width: int;
               line: VerificationLine): string =
  ## One list row: the kind coloured by its tone, the rest as text.
  case line.kind
  of vlNote:
    g.paintFitted(row, col, width, line.text, VerificationNoteStyle)
  of vlGroup:
    g.paintFitted(row, col, width, line.text, VerificationHeadingStyle)
  of vlCounterexample:
    g.paintFitted(row, col, width, line.text,
                  CellStyle(role: srChromeText, bold: true))
  of vlOffer:
    g.paintFitted(row, col, width,
                  lineText(line, g.glyphText(VerificationOfferGlyph), ""),
                  VerificationOfferStyle)
  of vlFinding:
    var used = VerificationIndentCells
    var text = " ".repeat(VerificationIndentCells)
    let kind = g.paintFitted(row, col + used, width - used, line.kindLabel,
                             kindStyle(line.findingKind))
    text.add kind
    used += cellWidthOf(kind) + VerificationGapCells
    for (part, style) in [(line.title, VerificationMutedStyle),
                          (line.message, VerificationTextStyle)]:
      if part.len == 0 or used >= width:
        continue
      let painted = g.paintFitted(row, col + used, width - used, part, style)
      text.add "  " & painted
      used += cellWidthOf(painted) + VerificationGapCells
    text
  of vlStep:
    let mark = g.glyphText(VerificationCurrentStepGlyph)
    let full = lineText(line, mark, mark)
    g.paintFitted(row, col, width, full,
                  if line.isFailure: VerificationFailureStyle
                  else: VerificationTextStyle)

proc paintVerification*(g: var StyledGrid; area: CellArea;
                        model: VerificationPaneModel): VerificationPaneScreen =
  ## The pane into `area` (the rows below its tab strip) and nowhere else.
  result = VerificationPaneScreen(trackCol: -1)
  if area.width <= 0 or area.height <= 0:
    return
  # Row 0: the status on the left, the controls on the right — the Run
  # control (the host's) and Stop while a run is in flight.
  var right = area.col + area.width
  if model.stopShown:
    let cells = cellWidthOf(VerificationStopLabel)
    if cells + 4 <= area.width:
      right -= cells
      g.paint(area.row, right, VerificationStopLabel, VerificationControlStyle)
      result.stopCol = right
      result.stopCells = cells
      right -= 1
  if model.runLabel.len > 0:
    let label = g.glyphText(VerificationRunGlyph) & " " & model.runLabel
    let cells = cellWidthOf(label)
    if cells + 4 <= right - area.col:
      right -= cells
      g.paint(area.row, right, label, VerificationControlStyle)
      result.runCol = right
      result.runCells = cells
      right -= 1
  discard g.paintFitted(area.row, area.col, max(0, right - area.col),
                        model.status, VerificationStatusStyle)
  result.headerRows = 1
  if model.command.len > 0 and area.height > 2:
    discard g.paintFitted(area.row + 1, area.col, area.width, model.command,
                          VerificationCommandStyle)
    result.headerRows = 2
  result.listTop = area.row + result.headerRows
  result.listRows = max(0, area.height - result.headerRows)
  let rows = result.listRows
  if rows <= 0:
    return
  var width = area.width
  if model.lines.len > rows:
    width = max(0, area.width - ScrubberTrackCells)
    result.trackCol = area.col + area.width - ScrubberTrackCells
  let first = clampVerificationTop(model.lines.len, model.scrollTop, rows)
  result.top = first
  for k in 0 ..< rows:
    let i = first + k
    if i >= model.lines.len:
      break
    let line = model.lines[i]
    let y = result.listTop + k
    if line.key.len > 0 and line.key == model.selectedKey:
      g.fillSurface(y, area.col, width, 1, VerificationSelectedSurface)
    elif line.kind == vlStep and line.isCurrent:
      g.fillSurface(y, area.col, width, 1, VerificationCurrentStepSurface)
    result.painted.add g.paintLine(y, area.col, width, line)
  if result.trackCol >= 0:
    g.paintVerticalScrubber(result.trackCol, result.listTop, rows,
      scrubberModel(model.lines.len, first, rows))

proc verificationTargetAt*(model: VerificationPaneModel;
                           screen: VerificationPaneScreen; area: CellArea;
                           row, col: int): VerificationTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  result = VerificationTarget(kind: vtNone, line: -1)
  if area.width <= 0 or not area.contains(row, col):
    return
  if row == area.row:
    if screen.runCells > 0 and col >= screen.runCol and
       col < screen.runCol + screen.runCells:
      return VerificationTarget(kind: vtRun, line: -1)
    if screen.stopCells > 0 and col >= screen.stopCol and
       col < screen.stopCol + screen.stopCells:
      return VerificationTarget(kind: vtStop, line: -1)
  if row < screen.listTop:
    return VerificationTarget(kind: vtHeader, line: -1)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row < screen.listTop + screen.listRows:
    return VerificationTarget(kind: vtTrack, line: -1)
  if row >= screen.listTop + screen.listRows:
    return
  let i = screen.top + (row - screen.listTop)
  if i < 0 or i >= model.lines.len:
    return
  result = VerificationTarget(kind: vtLine, key: model.lines[i].key, line: i)

proc lineOfSelected*(model: VerificationPaneModel): int =
  lineOfKey(model.lines, model.selectedKey)

proc revealLine*(model: VerificationPaneModel; listRows, line: int): int =
  ## The scroll top that keeps list row `line` in view.
  let rows = max(1, listRows)
  let top = clampVerificationTop(model.lines.len, model.scrollTop, rows)
  if line < 0: top
  elif line < top: line
  elif line >= top + rows: line - rows + 1
  else: top
