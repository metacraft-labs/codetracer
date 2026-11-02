## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/tui_session.requestsModelOf` turns the session's
## `RequestPanelVM` into the model below).
##
## app/views/requests_pane.nim — PLAT-58. **THE REQUESTS PANE, drawn.**
##
## The desktop's REQUESTS panel (`viewmodel/views/isonim_request_panel_view.
## nim`) draws a filter bar (the URL field, the Method and Status pickers), the
## refusal of the last activation, the header and one row per request, and the
## selected request's detail. This pane draws the same parts in the same order
## with the same words, every one of which is the ViewModel's
## (`Request-Panel.md` § N.1, N.3):
##
##     Find by URL...                      Method: All ▾  Status: All ▾
##      #  method  URL                      Status  Duration    Size
##     02  GET     /api/users                  200      12ms  2.0 KB
##     03  POST    /api/users                  201      31ms    96 B
##     07  GET     /api/reports/slow             —         —     0 B
##     POST /api/users  201 Created                          Handler ›
##
## The columns are `table_fit.requestsFit`: every column but the URL at its
## widest cell (the header's word included) and never cut, the URL — the
## desktop's one flex column — taking the rest and ending in `…` when cut.
## The id, the status, the duration and the size are right-aligned, as on the
## desktop. The list is the whole MATCHING list (`RequestPanelVM.
## matchingCount`): the rows the engine answered for the window the pane shows
## are drawn where they belong, and the rightmost column is the list's
## scrollbar when it overflows (Scrollbar-Scrubbers.md: a list's bar moves the
## VIEW).

import codetracer_embed
import headless_app/pane_clicks   # the menus the host builds (K59, K60)

from ../formatters/type_formatters import terminalMeasure
import ../layout/profile
import ../layout/project
import ./styled_row
import ./scrubber_track

export styled_row, profile, scrubber_track

type
  RequestsPaneRow* = object
    ## One request as the ViewModel words it (`RequestDisplayRow`).
    position*: int
      ## Its place among all matching requests.
    id*: int
    idText*, httpMethod*, url*, status*, duration*, size*: string
    statusTone*: RequestTone
    methodTone*: MethodTone
    isOpen*: bool

  RequestsPaneDetail* = object
    ## The selected request's detail strip (§ N.3 item 5).
    shown*: bool
    httpMethod*, url*, status*: string
      ## `status` is `detailStatusText` (`200 OK`), or the in-flight `—`.
    methodTone*: MethodTone
    statusTone*: RequestTone
    refused*: string
      ## Why its handler cannot be gone to, "" when it can.

  RequestsPaneModel* = object
    loaded*: bool
      ## Whether a session supplied the pane at all.
    search*: string
      ## The URL search text ("" draws the placeholder).
    methodLabel*, statusLabel*: string
      ## The pickers' labels (`Method: All`, or the chosen value).
    message*: string
      ## The navigation message (why the last activation was refused).
    total*: int
      ## How many requests match the filters — the list's scroll range.
    rows*: seq[RequestsPaneRow]
      ## The rows held, in position order (contiguous).
    selected*: int
      ## The selected request's POSITION, -1 for none.
    detail*: RequestsPaneDetail
    scrollTop*: int
      ## The first list position shown — the pane's own.

  RequestsTargetKind* = enum
    rqNone, rqField, rqMethod, rqStatus, rqHeader, rqRow, rqTrack,
    rqHandler, rqDetail, rqMessage

  RequestsTarget* = object
    kind*: RequestsTargetKind
    position*: int
      ## rqRow: the request's position among the matching ones.
    held*: bool
      ## rqRow: whether that position's request is held (drawn).

  RequestsPaneScreen* = object
    fieldCol*, fieldCells*: int
      ## The URL field (row `area.row`).
    methodCol*, methodCells*: int
    statusCol*, statusCells*: int
      ## The two pickers, -1 when they did not fit.
    messageRow*: int
      ## The navigation message's row, -1 when there is none.
    headerRow*: int
    listTop*, listRows*: int
      ## The rows the list occupies.
    trackCol*: int
      ## The scrollbar's column, -1 when the list fits.
    detailRow*: int
      ## The detail strip's row, -1 when nothing is selected.
    handlerCol*, handlerCells*: int
      ## The detail strip's `Handler ›`, -1 when it did not fit.
    fit*: TableFit
      ## The columns, as drawn.
    tableLeft*: int
    top*: int
      ## The list position the first list row shows (the clamped scroll).
    painted*: seq[string]
      ## Every painted list row's text, in order (for the suites).

  RequestsActKind* = enum
    ## What the pane asks the HOST to do with the session's `RequestPanelVM`
    ## (`TuiApp.requestsAct`): this layer reads no ViewModel.
    rakPress        ## a press on the row at `position`, at `nowMs`
    rakGoToHandler  ## the selected row's handler (`Handler ›`, Enter)
    rakRowMenu      ## build the menu of the row at `position`
    rakPickerMenu   ## build the Method (`text` "method") or Status picker
    rakMenuChoice   ## a Requests menu entry chosen (`action`, `target`)
    rakSearch       ## the URL search becomes `text`
    rakKey          ## a `list.*` move (`operation`, `page`)
    rakCopy         ## the selected row's URL to the clipboard (`list.copy`)
    rakClearSelection
    rakShow         ## the pane shows `rows` rows from `position`

  RequestsAct* = object
    kind*: RequestsActKind
    position*: int
    nowMs*: int64
    action*: ContextAction
    target*: ContextTarget
    text*: string
    operation*: string
    page*: int
    rows*: int

  RequestsActResult* = object
    ## The host's answer.
    note*: string
      ## The status line's words, "" for none.
    menu*: ContextMenuModel
      ## A menu to open (rakRowMenu, rakPickerMenu); no entries for none.
    copied*: string
      ## Text for the clipboard.
    moved*: bool
      ## The debugger moved (the host has read every pane again).

const
  RequestsFieldStyle = CellStyle(role: srSurfaceInput, surface: srSurfaceInput)
  RequestsPlaceholderStyle = CellStyle(role: srChromeMuted,
                                       surface: srSurfaceInput, italic: true)
  RequestsPickerStyle = CellStyle(role: srChromeText, surface: srSurfaceField)
  RequestsHeaderStyle = CellStyle(role: srChromeMuted, bold: true)
  RequestsMutedStyle = CellStyle(role: srChromeMuted)
  RequestsTextStyle = CellStyle(role: srChromeText)
  RequestsMessageStyle* = CellStyle(role: srChromeError)
  RequestsHandlerStyle = CellStyle(role: srChromeAccent)
  RequestsSelectedSurface = srSurfaceSelection
  RequestsGapCells* = 1
  RequestsPickerGapCells = 1
  # The desktop's column widths (`request_panel.styl`, in ems ≈ cells), the
  # floor of each never-cut column so the columns hold still while the
  # window the engine answers moves under them.
  IdFloorCells = 2
  MethodFloorCells = 7
  StatusFloorCells = 6
  DurationFloorCells = 8
  SizeFloorCells = 7

proc toneStyle*(tone: RequestTone): CellStyle =
  ## A status's colour — the desktop's `request-status-<bucket>` rules
  ## (2xx success, 3xx information, 4xx warning, 5xx error, the rest the
  ## label colour).
  case tone
  of rtSuccess: CellStyle(role: srChromeSuccess)
  of rtRedirect: CellStyle(role: srChromeInfo)
  # `srChromeNotification` is the role on `colors-ui-text-warning-primary`,
  # the desktop's 4xx colour.
  of rtClientError: CellStyle(role: srChromeNotification)
  of rtServerError: CellStyle(role: srChromeError)
  of rtUnknown: RequestsMutedStyle

proc methodStyle*(tone: MethodTone): CellStyle =
  ## A method's colour — the text colour of its desktop badge.
  case tone
  of mtInformation: CellStyle(role: srChromeInfo)
  of mtSuccess: CellStyle(role: srChromeSuccess)
  of mtWarning: CellStyle(role: srChromeNotification)
  of mtError: CellStyle(role: srChromeError)
  of mtLabel: RequestsMutedStyle

proc widest(model: RequestsPaneModel; floor: int; title: string;
            cell: proc(r: RequestsPaneRow): string): int =
  result = max(floor, cellWidthOf(title))
  for r in model.rows:
    result = max(result, cellWidthOf(cell(r)))

proc columnsFor*(model: RequestsPaneModel; width: int): TableFit =
  ## The six columns in a list `width` cells wide.
  requestsFit(
    model.widest(IdFloorCells, RequestsColumnTitles[0],
                 proc(r: RequestsPaneRow): string = r.idText),
    model.widest(MethodFloorCells, RequestsColumnTitles[1],
                 proc(r: RequestsPaneRow): string = r.httpMethod),
    model.widest(0, RequestsColumnTitles[2],
                 proc(r: RequestsPaneRow): string = r.url),
    model.widest(StatusFloorCells, RequestsColumnTitles[3],
                 proc(r: RequestsPaneRow): string = r.status),
    model.widest(DurationFloorCells, RequestsColumnTitles[4],
                 proc(r: RequestsPaneRow): string = r.duration),
    model.widest(SizeFloorCells, RequestsColumnTitles[5],
                 proc(r: RequestsPaneRow): string = r.size),
    width, gap = RequestsGapCells)

proc rowAt*(model: RequestsPaneModel; position: int): int =
  ## The index into `rows` of the request at `position`, -1 when not held.
  if model.rows.len == 0:
    return -1
  let i = position - model.rows[0].position
  if i >= 0 and i < model.rows.len and model.rows[i].position == position: i
  else: -1

proc clampRequestsTop*(total, top, listRows: int): int =
  clamp(top, 0, max(0, total - max(1, listRows)))

proc pickerText(g: StyledGrid; label: string): string =
  ## A picker as drawn: its label and the dropdown chevron.
  " " & label & " " & g.glyphText(grDropdown) & " "

proc paintAligned(g: var StyledGrid; row, col, width: int; text: string;
                  style: CellStyle; right: bool): string =
  ## `text` in a column `width` cells wide (cut with `…` when it does not
  ## fit), left- or right-aligned.
  if width <= 0:
    return ""
  let cell = fitCell(text, width, terminalMeasure)
  let pad = if right: max(0, width - cellWidthOf(cell.text)) else: 0
  g.paint(row, col + pad, cell.text, style)
  cell.text

const RightAligned = [true, false, false, true, true, true]
  ## Which columns are right-aligned: the id, the status, the duration and
  ## the size (`request_panel.styl`'s `text-align: right` / `flex-end`).

proc paintRequests*(g: var StyledGrid; area: CellArea;
                    model: RequestsPaneModel): RequestsPaneScreen =
  ## The pane into `area` (the rows below its tab strip) and nowhere else.
  result = RequestsPaneScreen(methodCol: -1, statusCol: -1, messageRow: -1,
                              headerRow: -1, trackCol: -1, detailRow: -1,
                              handlerCol: -1, fieldCol: area.col)
  if area.width <= 0 or area.height <= 0:
    return
  # Row 0: the filter bar — the field, then the two pickers at the right.
  let methodText = g.pickerText(model.methodLabel)
  let statusText = g.pickerText(model.statusLabel)
  let mw = cellWidthOf(methodText)
  let sw = cellWidthOf(statusText)
  var fieldCells = area.width
  if area.width >= mw + sw + 2 * RequestsPickerGapCells + 4:
    result.statusCol = area.col + area.width - sw
    result.statusCells = sw
    result.methodCol = result.statusCol - RequestsPickerGapCells - mw
    result.methodCells = mw
    fieldCells = result.methodCol - RequestsPickerGapCells - area.col
    g.paint(area.row, result.methodCol, methodText, RequestsPickerStyle)
    g.paint(area.row, result.statusCol, statusText, RequestsPickerStyle)
  result.fieldCells = fieldCells
  g.fillSurface(area.row, area.col, fieldCells, 1, srSurfaceInput)
  if model.search.len > 0:
    g.paint(area.row, area.col, truncateToCells(model.search, fieldCells),
            RequestsFieldStyle)
  else:
    g.paint(area.row, area.col,
            truncateToCells(RequestSearchPlaceholder, fieldCells),
            RequestsPlaceholderStyle)
  var y = area.row + 1
  let bottom = area.row + area.height
  if model.message.len > 0 and y < bottom:
    result.messageRow = y
    g.paint(y, area.col, truncateToCells(model.message, area.width),
            RequestsMessageStyle)
    inc y
  if y >= bottom:
    return
  # The detail strip takes the last row while a request is selected.
  var listBottom = bottom
  if model.detail.shown and bottom - y >= 3:
    result.detailRow = bottom - 1
    listBottom = bottom - 1
  # The header.
  result.headerRow = y
  inc y
  result.listTop = y
  result.listRows = max(0, listBottom - y)
  var width = area.width
  if model.total > result.listRows:
    width = max(0, area.width - ScrubberTrackCells)
    result.trackCol = area.col + area.width - ScrubberTrackCells
  let fit = model.columnsFor(width)
  result.fit = fit
  result.tableLeft = area.col
  template col(i: int): int = area.col + fit.starts[i]
  for i, title in RequestsColumnTitles:
    discard g.paintAligned(result.headerRow, col(i), fit.widths[i], title,
                           RequestsHeaderStyle, RightAligned[i])
  let first = clampRequestsTop(model.total, model.scrollTop, result.listRows)
  result.top = first
  for k in 0 ..< result.listRows:
    let position = first + k
    if position >= model.total:
      break
    let ry = result.listTop + k
    let i = model.rowAt(position)
    if i < 0:
      # Not held yet: the window the engine answers has not reached it.
      result.painted.add ""
      continue
    let r = model.rows[i]
    if position == model.selected:
      g.fillSurface(ry, area.col, width, 1, RequestsSelectedSurface)
    var text = ""
    text.add g.paintAligned(ry, col(0), fit.widths[0], r.idText,
                            RequestsMutedStyle, RightAligned[0])
    text.add " " & g.paintAligned(ry, col(1), fit.widths[1], r.httpMethod,
                                  methodStyle(r.methodTone), RightAligned[1])
    text.add " " & g.paintAligned(ry, col(2), fit.widths[2], r.url,
                                  RequestsTextStyle, RightAligned[2])
    text.add " " & g.paintAligned(ry, col(3), fit.widths[3], r.status,
                                  toneStyle(r.statusTone), RightAligned[3])
    text.add " " & g.paintAligned(ry, col(4), fit.widths[4], r.duration,
                                  RequestsMutedStyle, RightAligned[4])
    text.add " " & g.paintAligned(ry, col(5), fit.widths[5], r.size,
                                  RequestsMutedStyle, RightAligned[5])
    result.painted.add text
  if result.trackCol >= 0:
    g.paintVerticalScrubber(result.trackCol, result.listTop, result.listRows,
      scrubberModel(model.total, first, result.listRows))
  if result.detailRow >= 0:
    let d = model.detail
    let handler = HandlerControlLabel & " " & g.glyphText(grOverflowRight)
    let hw = cellWidthOf(handler)
    var right = area.col + area.width
    if d.refused.len == 0 and area.width > hw + 8:
      result.handlerCol = right - hw
      result.handlerCells = hw
      g.paint(result.detailRow, result.handlerCol, handler,
              RequestsHandlerStyle)
      right = result.handlerCol - 1
    var x = area.col
    let left = right - x
    let m = truncateToCells(d.httpMethod, left)
    g.paint(result.detailRow, x, m, methodStyle(d.methodTone))
    x += cellWidthOf(m) + 1
    let statusCells = cellWidthOf(d.status)
    let urlRoom = right - x - statusCells - 1
    if urlRoom > 0:
      let u = fitCell(d.url, urlRoom, terminalMeasure).text
      g.paint(result.detailRow, x, u, RequestsTextStyle)
      x += cellWidthOf(u) + 1
    if x + statusCells <= right:
      g.paint(result.detailRow, x, d.status, toneStyle(d.statusTone))

proc requestsTargetAt*(model: RequestsPaneModel; screen: RequestsPaneScreen;
                       area: CellArea; row, col: int): RequestsTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  result = RequestsTarget(kind: rqNone, position: -1)
  if area.width <= 0 or not area.contains(row, col):
    return
  if row == area.row:
    if screen.methodCol >= 0 and col >= screen.methodCol and
       col < screen.methodCol + screen.methodCells:
      return RequestsTarget(kind: rqMethod, position: -1)
    if screen.statusCol >= 0 and col >= screen.statusCol and
       col < screen.statusCol + screen.statusCells:
      return RequestsTarget(kind: rqStatus, position: -1)
    if col < screen.fieldCol + screen.fieldCells:
      return RequestsTarget(kind: rqField, position: -1)
    return
  if row == screen.messageRow:
    return RequestsTarget(kind: rqMessage, position: -1)
  if row == screen.headerRow:
    return RequestsTarget(kind: rqHeader, position: -1)
  if row == screen.detailRow:
    if screen.handlerCol >= 0 and col >= screen.handlerCol and
       col < screen.handlerCol + screen.handlerCells:
      return RequestsTarget(kind: rqHandler, position: model.selected,
                            held: true)
    return RequestsTarget(kind: rqDetail, position: model.selected)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row >= screen.listTop and row < screen.listTop + screen.listRows:
    return RequestsTarget(kind: rqTrack, position: -1)
  if row < screen.listTop or row >= screen.listTop + screen.listRows:
    return
  let position = screen.top + (row - screen.listTop)
  if position < 0 or position >= model.total:
    return
  result = RequestsTarget(kind: rqRow, position: position,
                          held: model.rowAt(position) >= 0)

proc revealPosition*(model: RequestsPaneModel; listRows, position: int): int =
  ## The scroll top that keeps `position` in view.
  let rows = max(1, listRows)
  let top = clampRequestsTop(model.total, model.scrollTop, rows)
  if position < 0: top
  elif position < top: position
  elif position >= top + rows: position - rows + 1
  else: top
