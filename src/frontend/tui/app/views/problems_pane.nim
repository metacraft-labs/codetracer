## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/problems_source.paneModelOf` turns the window's
## shared `ErrorsVM` into the model below).
##
## app/views/problems_pane.nim — PLAT-55. **THE PROBLEMS PANE, drawn.**
##
## The desktop's panel (`viewmodel/views/isonim_errors_view.nim`) draws a
## header — the error, warning and total counts, what navigation last
## announced, and the All / Errors / Warnings / Group by File buttons — over
## a list of the build's diagnostics, each an icon, its path, its location
## and its message; grouped by file, each file's rows sit under a header
## naming it and its count; with none, "No problems detected.". This pane
## draws the same parts in the same order with the same words, every one of
## which is the ViewModel's (`errors_vm`):
##
##     ● 2  ⚠ 1  Total: 3  error 1 of 2        All Errors Warnings Group by File
##     ⚠ src/main.nr  1:9   unused variable x
##     ● src/util.nr  3:19  Expected type bool, found type Field
##
## The row's parts are `table_fit.problemsFit` — the desktop's flex row: the
## icon fixed, the location never cut, the path and the message cut with `…`
## (`table_overflow.fitCell`) and the message given the slack. The rightmost
## column is the list's scrollbar when it overflows (Scrollbar-Scrubbers.md:
## a list's bar moves the VIEW). The selected diagnostic — the cursor a press,
## the keyboard and `next error` share — is drawn on the selection surface.

import codetracer_embed

from ../formatters/type_formatters import terminalMeasure
import ../layout/profile
import ../layout/project
import ./styled_row
import ./scrubber_track

export styled_row, scrubber_track

type
  ProblemsTone* = enum
    ## A row's severity, as its icon is coloured (the desktop's
    ## `.problems-icon-error` / `-warning` / `-info`).
    ptError, ptWarning, ptInfo

  ProblemsPaneRow* = object
    index*: int
      ## The diagnostic's index in the ViewModel's master list.
    tone*: ProblemsTone
    icon*, path*, location*, message*: string

  ProblemsPaneLineKind* = enum
    plRow, plFileHeader, plEmpty

  ProblemsPaneLine* = object
    ## One entry of the list (`ErrorsVM.displayRows`).
    kind*: ProblemsPaneLineKind
    row*: int
      ## plRow: the index into `rows`; -1 otherwise.
    text*: string

  ProblemsPaneModel* = object
    loaded*: bool
      ## Whether a host supplied the pane at all.
    errorBadge*, warningBadge*, totalBadge*: string
    status*: string
      ## What navigation last announced (`ErrorsVM.statusMessage`).
    filters*: seq[string]
      ## The filter buttons' labels, in `ProblemFilterTag` order.
    filter*: int
      ## The active filter's index into `filters`.
    groupLabel*: string
    grouped*: bool
    rows*: seq[ProblemsPaneRow]
    lines*: seq[ProblemsPaneLine]
    selected*: int
      ## The selected diagnostic's MASTER index, -1 for none.
    scrollTop*: int
      ## The first list row shown.

  ProblemsTargetKind* = enum
    pbNone, pbFilter, pbGroup, pbRow, pbHeader, pbTrack, pbText

  ProblemsTarget* = object
    kind*: ProblemsTargetKind
    index*: int
      ## pbFilter: the filter's index; pbRow: the diagnostic's master index.

  ProblemsPaneScreen* = object
    listTop*, listRows*: int
    trackCol*: int
      ## The scrollbar's column, -1 when the list fits.
    buttons*: seq[tuple[col, width: int]]
      ## Each header button as drawn — the filters in order, then the group
      ## toggle — or none when the header has no room for them.
    fit*: TableFit
    tableLeft*: int
    painted*: seq[string]
      ## Every painted list row's text, in order (for the suites).

  ProblemsCommandKind* = enum
    ## What the pane asks its host to do (`TuiApp.problemsCommand`).
    pcmSelect   ## select diagnostic `index` (master), no jump
    pcmOpen     ## select it and open its file at its line (K35)
    pcmNext     ## `problems.next` (EMT-D22)
    pcmPrevious ## `problems.previous`
    pcmFilter   ## set filter `index`
    pcmGroup    ## toggle Group by File

const
  ProblemsIconCells* = 1
  ProblemsGapCells* = 1
  ProblemsButtonGap* = 1
  ProblemsBadgeStyle = CellStyle(role: srChromeText)
  ProblemsStatusStyle = CellStyle(role: srChromeMuted)
  ProblemsButtonStyle = CellStyle(role: srChromeText)
  ProblemsActiveButtonStyle = CellStyle(role: srChromeText, bold: true)
  ProblemsPathStyle = CellStyle(role: srChromeMuted)
  ProblemsMessageStyle = CellStyle(role: srChromeText)
  ProblemsHeaderStyle = CellStyle(role: srChromeMuted, bold: true)
  ProblemsEmptyStyle = CellStyle(role: srChromeMuted)
  ProblemsErrorStyle* = CellStyle(role: srChromeError)
    ## The desktop's `.problems-icon-error` / `.problems-count-error`.
  ProblemsWarningStyle* = CellStyle(role: srChromeNotification)
    ## `.problems-icon-warning` / `.problems-count-warning`: the warning
    ## token.
  ProblemsInfoStyle* = CellStyle(role: srChromeInfo)
    ## `.problems-icon-info`: the information token.
  ProblemsSelectedSurface = srSurfaceSelection
  ProblemsActiveSurface = srSurfaceSelection

proc toneStyle*(tone: ProblemsTone): CellStyle =
  case tone
  of ptError: ProblemsErrorStyle
  of ptWarning: ProblemsWarningStyle
  of ptInfo: ProblemsInfoStyle

proc columnsFor*(model: ProblemsPaneModel; width: int): TableFit =
  ## The row's four parts in a list `width` cells wide, sized to the rows.
  var icon = ProblemsIconCells
  var path, location, message = 0
  for r in model.rows:
    icon = max(icon, cellWidthOf(r.icon))
    path = max(path, cellWidthOf(r.path))
    location = max(location, cellWidthOf(r.location))
    message = max(message, cellWidthOf(r.message))
  problemsFit(icon, path, location, message, width, ProblemsGapCells)

proc clampProblemsTop*(total, top, listRows: int): int =
  clamp(top, 0, max(0, total - max(1, listRows)))

proc listGeometry*(area: CellArea): tuple[top, rows: int] =
  ## The list's rows inside `area`: below the header row.
  (area.row + 1, max(0, area.height - 1))

proc buttonsWidth(model: ProblemsPaneModel): int =
  for label in model.filters:
    result += cellWidthOf(label) + ProblemsButtonGap
  result += cellWidthOf(model.groupLabel)

proc paintCell(g: var StyledGrid; row, col, width: int; text: string;
               style: CellStyle): string =
  if width <= 0:
    return ""
  let cell = fitCell(text, width, terminalMeasure)
  g.paint(row, col, cell.text, style)
  cell.text

proc paintProblems*(g: var StyledGrid; area: CellArea;
                    model: ProblemsPaneModel): ProblemsPaneScreen =
  ## The pane into `area` (the rows below its tab strip) and nowhere else.
  result = ProblemsPaneScreen(trackCol: -1)
  if area.width <= 0 or area.height <= 0:
    return
  # Row 0: the counts and the status on the left, the buttons on the right
  # (the desktop's `justify-content: space-between`) when they fit beside at
  # least the error count.
  let bw = model.buttonsWidth
  var leftCells = area.width
  if bw + 2 + cellWidthOf(model.errorBadge) <= area.width:
    var col = area.col + area.width - bw
    leftCells = area.width - bw - 1
    for i, label in model.filters:
      let active = i == model.filter
      let w = cellWidthOf(label)
      if active:
        g.fillSurface(area.row, col, w, 1, ProblemsActiveSurface)
      g.paint(area.row, col, label,
              if active: ProblemsActiveButtonStyle else: ProblemsButtonStyle)
      result.buttons.add (col: col, width: w)
      col += w + ProblemsButtonGap
    let w = cellWidthOf(model.groupLabel)
    if model.grouped:
      g.fillSurface(area.row, col, w, 1, ProblemsActiveSurface)
    g.paint(area.row, col, model.groupLabel,
            if model.grouped: ProblemsActiveButtonStyle
            else: ProblemsButtonStyle)
    result.buttons.add (col: col, width: w)
  block counts:
    var col = area.col
    let stop = area.col + leftCells
    for (text, style) in [(model.errorBadge, ProblemsErrorStyle),
                          (model.warningBadge, ProblemsWarningStyle),
                          (model.totalBadge, ProblemsBadgeStyle),
                          (model.status, ProblemsStatusStyle)]:
      if text.len == 0 or col >= stop:
        continue
      col += cellWidthOf(g.paintCell(area.row, col, stop - col, text, style))
      col += 2
  let (top, rows) = listGeometry(area)
  result.listTop = top
  result.listRows = rows
  if rows <= 0:
    return
  var width = area.width
  if model.lines.len > rows:
    width = max(0, area.width - ScrubberTrackCells)
    result.trackCol = area.col + area.width - ScrubberTrackCells
  result.tableLeft = area.col
  let fit = model.columnsFor(width)
  result.fit = fit
  let first = clampProblemsTop(model.lines.len, model.scrollTop, rows)
  for k in 0 ..< rows:
    let i = first + k
    if i >= model.lines.len:
      break
    let line = model.lines[i]
    let y = top + k
    case line.kind
    of plRow:
      let r = model.rows[line.row]
      if r.index == model.selected:
        g.fillSurface(y, area.col, width, 1, ProblemsSelectedSurface)
      template col(i: int): int = area.col + fit.starts[i]
      var text = g.paintCell(y, col(0), fit.widths[0], r.icon,
                             toneStyle(r.tone))
      text.add " " & g.paintCell(y, col(1), fit.widths[1], r.path,
                                 ProblemsPathStyle)
      text.add " " & g.paintCell(y, col(2), fit.widths[2], r.location,
                                 ProblemsPathStyle)
      text.add " " & g.paintCell(y, col(3), fit.widths[3], r.message,
                                 ProblemsMessageStyle)
      result.painted.add text
    of plFileHeader:
      let t = truncateToCells(line.text, width)
      g.paint(y, area.col, t, ProblemsHeaderStyle)
      result.painted.add t
    of plEmpty:
      let t = truncateToCells(line.text, width)
      g.paint(y, area.col, t, ProblemsEmptyStyle)
      result.painted.add t
  if result.trackCol >= 0:
    g.paintVerticalScrubber(result.trackCol, top, rows,
      scrubberModel(model.lines.len, first, rows))

proc problemsTargetAt*(model: ProblemsPaneModel; screen: ProblemsPaneScreen;
                       area: CellArea; row, col: int): ProblemsTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  if area.width <= 0 or not area.contains(row, col):
    return ProblemsTarget(kind: pbNone, index: -1)
  if row == area.row:
    for i, b in screen.buttons:
      if col >= b.col and col < b.col + b.width:
        if i < model.filters.len:
          return ProblemsTarget(kind: pbFilter, index: i)
        return ProblemsTarget(kind: pbGroup, index: -1)
    return ProblemsTarget(kind: pbNone, index: -1)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row >= screen.listTop and row < screen.listTop + screen.listRows:
    return ProblemsTarget(kind: pbTrack, index: -1)
  if row < screen.listTop or row >= screen.listTop + screen.listRows:
    return ProblemsTarget(kind: pbNone, index: -1)
  let i = clampProblemsTop(model.lines.len, model.scrollTop,
                           screen.listRows) + (row - screen.listTop)
  if i < 0 or i >= model.lines.len:
    return ProblemsTarget(kind: pbNone, index: -1)
  let line = model.lines[i]
  case line.kind
  of plRow: ProblemsTarget(kind: pbRow, index: model.rows[line.row].index)
  of plFileHeader: ProblemsTarget(kind: pbHeader, index: -1)
  of plEmpty: ProblemsTarget(kind: pbText, index: -1)

proc lineOfIndex*(model: ProblemsPaneModel; index: int): int =
  ## The list row of diagnostic `index` (master), -1 when it is not listed.
  for i, line in model.lines:
    if line.kind == plRow and model.rows[line.row].index == index:
      return i
  -1

proc revealIndex*(model: ProblemsPaneModel; listRows, index: int): int =
  ## The scroll top that keeps diagnostic `index` in view.
  let at = model.lineOfIndex(index)
  let rows = max(1, listRows)
  let top = clampProblemsTop(model.lines.len, model.scrollTop, rows)
  if at < 0: top
  elif at < top: at
  elif at >= top + rows: at - rows + 1
  else: top

proc listedIndices*(model: ProblemsPaneModel): seq[int] =
  ## The diagnostics in list order (master indices) — what the keyboard
  ## moves through.
  for line in model.lines:
    if line.kind == plRow:
      result.add model.rows[line.row].index
