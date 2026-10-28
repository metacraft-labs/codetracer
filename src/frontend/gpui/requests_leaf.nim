## gpui/requests_leaf.nim — PLAT-58. The GPUI window's **Requests** pane,
## drawn natively from the session's `RequestPanelVM` (the model the desktop's
## REQUESTS panel and the terminal's pane draw).
##
## What the desktop's panel draws, in its order and words
## (`Request-Panel.md` § N.3): the filter bar — the URL field (`Find by
## URL...`, or the search; the window's field is the omnibox's `:requests`
## line, as the terminal's is) and the Method and Status pickers — the
## refusal of the last activation, the header (`#  method  URL  Status
## Duration  Size`), one row per request with its method and status in the
## desktop's colours, and the selected request's detail strip with
## `Handler ›`. Every word is the ViewModel's. Rows have a fixed pitch, so a
## press and the drawing go through one layout (`requestsLayout`); the list is
## the whole MATCHING list, the engine answering the window shown, and its
## scrollbar is the shared list scrubber, moving the VIEW.
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-requests-*`, `data-ct-request-*`).

import std/strutils

import isonim_gpui/renderer
import isonim/core/signals

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
import ../viewmodel/viewmodels/request_panel_vm
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GRequestsPane* = object
    ## The window's own state for the pane: where the reader scrolled, and a
    ## held scrubber thumb.
    scrollTop*: int
    dragging*: bool

  RequestsLayout* = object
    body*: PxRect
    field*: PxRect
    methodPicker*, statusPicker*: PxRect
    message*: PxRect
      ## Zero height when there is no refusal to say.
    header*: PxRect
    list*: PxRect
      ## The rows' area (the scrubber's column off when the list overflows).
    rows*: int
    overflow*: bool
    detail*: PxRect
      ## Zero height when nothing is selected.
    handler*: PxRect
      ## `Handler ›`, zero width when the selected request cannot be gone to.
    fit*: TableFit
      ## The columns, in pixels from `list.x`.

  GRequestsHitKind* = enum
    grqNone, grqField, grqMethod, grqStatus, grqRow, grqTrack, grqThumb,
    grqHandler, grqOther

  GRequestsHit* = object
    kind*: GRequestsHitKind
    position*: int
      ## grqRow: the request's position among the matching ones.
    index*: int
      ## grqRow: the held row, -1 when that position is not held yet.
    fraction*: float

const
  RequestsRowPx* = 22
  RequestsBarPx* = 26
  RequestsGapPx = 6
  RequestsPickerPadPx = 10
  RequestsAttribute* = "data-ct-requests"
    ## On the pane: how many requests match.
  RequestRowAttribute* = "data-ct-request-id"
    ## On a request's row: its id; `data-ct-request-position`,
    ## `data-ct-request-status-tone`, `data-ct-request-method-tone`.
  RequestsPickerAttribute* = "data-ct-requests-picker"
    ## On a picker: `method` / `status`; its label is the text.
  RequestsTextColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  RequestsMutedColour = DesignTokenHex[dtColorsUiTextPrimaryBodySubtle][dmDark]
  RequestsLabelColour = DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark]
  RequestsSelectedGround = DesignTokenHex[dtColorsUiSurfaceActionPrimary][dmDark]
    ## `.request-row.selected`.
  RequestsFieldGround = DesignTokenHex[dtColorsUiSurfaceInputDefault][dmDark]
  RequestsPickerGround =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondary][dmDark]
  RequestsErrorColour = DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
  RequestsHandlerColour =
    DesignTokenHex[dtColorsUiTextInformationPrimary][dmDark]
  IdFloorCells = 2
  MethodFloorCells = 7
  StatusFloorCells = 6
  DurationFloorCells = 8
  SizeFloorCells = 7
  RightAligned = [true, false, false, true, true, true]
    ## The id, the status, the duration and the size are right-aligned
    ## (`request_panel.styl`).

proc initGRequestsPane*(): GRequestsPane = GRequestsPane()

proc statusColour*(tone: RequestTone): string =
  ## `request-status-<bucket>`: 2xx success, 3xx information, 4xx warning,
  ## 5xx error, the rest the label colour.
  case tone
  of rtSuccess: DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]
  of rtRedirect: DesignTokenHex[dtColorsUiTextInformationPrimary][dmDark]
  of rtClientError: DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark]
  of rtServerError: DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
  of rtUnknown: RequestsLabelColour

proc methodColours*(tone: MethodTone): tuple[text, ground: string] =
  ## `request-method-<verb>`: the badge's text and ground.
  case tone
  of mtInformation:
    (DesignTokenHex[dtColorsUiTextInformationPrimary][dmDark],
     DesignTokenHex[dtColorsUiSurfaceAlertInformation][dmDark])
  of mtSuccess:
    (DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark],
     DesignTokenHex[dtColorsUiSurfaceAlertSuccess][dmDark])
  of mtError:
    (DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark],
     DesignTokenHex[dtColorsUiSurfaceAlertError][dmDark])
  of mtWarning:
    (DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark],
     DesignTokenHex[dtColorsUiSurfaceAlertWarning][dmDark])
  of mtLabel:
    (RequestsLabelColour, RequestsPickerGround)

proc px(cells: int): int = int(float(cells) * EditorColumnPx + 0.5)
proc cellsOf(px: int): int = int(float(px) / EditorColumnPx)

proc pickerText(label: string): string = label & " ▾"

proc widest(rows: seq[RequestDisplayRow]; floor: int; title: string;
            cell: proc(r: RequestDisplayRow): string): int =
  result = max(floor, table_overflow.runeMeasure(title))
  for r in rows:
    result = max(result, table_overflow.runeMeasure(cell(r)))

proc requestsLayout*(vm: RequestPanelVM; body: PxRect): RequestsLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  let mw = px(table_overflow.runeMeasure(pickerText(vm.methodPickerLabel))) +
           2 * RequestsPickerPadPx
  let sw = px(table_overflow.runeMeasure(pickerText(vm.statusPickerLabel))) +
           2 * RequestsPickerPadPx
  result.statusPicker = PxRect(x: inner.x + inner.w - sw, y: inner.y, w: sw,
                               h: RequestsBarPx)
  result.methodPicker = PxRect(x: result.statusPicker.x - 4 - mw, y: inner.y,
                               w: mw, h: RequestsBarPx)
  result.field = PxRect(x: inner.x, y: inner.y,
                        w: max(0, result.methodPicker.x - 4 - inner.x),
                        h: RequestsBarPx)
  var y = inner.y + RequestsBarPx + 2
  if vm.navigationMessage.val.len > 0:
    result.message = PxRect(x: inner.x, y: y, w: inner.w, h: RequestsRowPx)
    y += RequestsRowPx
  result.header = PxRect(x: inner.x, y: y, w: inner.w, h: RequestsRowPx)
  y += RequestsRowPx
  var bottom = inner.y + inner.h
  let (selected, req) = vm.selectedRequest()
  if selected and bottom - y >= 3 * RequestsRowPx:
    result.detail = PxRect(x: inner.x, y: bottom - RequestsRowPx, w: inner.w,
                           h: RequestsRowPx)
    bottom -= RequestsRowPx
    if req.seekUnavailableReason.len == 0:
      let hw = px(table_overflow.runeMeasure(HandlerControlLabel & " ›")) +
               2 * RequestsPickerPadPx
      result.handler = PxRect(x: inner.x + inner.w - hw, y: result.detail.y,
                              w: hw, h: RequestsRowPx)
  result.rows = max(0, (bottom - y) div RequestsRowPx)
  result.overflow = vm.matchingCount > result.rows
  result.list = PxRect(x: inner.x, y: y,
                       w: max(0, inner.w - (if result.overflow: ListTrackPx + 2
                                            else: 0)),
                       h: result.rows * RequestsRowPx)
  let rows = vm.displayRows()
  result.fit = requestsFit(
    px(widest(rows, IdFloorCells, RequestsColumnTitles[0],
              proc(r: RequestDisplayRow): string = r.idText)),
    px(widest(rows, MethodFloorCells, RequestsColumnTitles[1],
              proc(r: RequestDisplayRow): string = r.httpMethod)),
    px(widest(rows, 0, RequestsColumnTitles[2],
              proc(r: RequestDisplayRow): string = r.url)),
    px(widest(rows, StatusFloorCells, RequestsColumnTitles[3],
              proc(r: RequestDisplayRow): string = r.status)),
    px(widest(rows, DurationFloorCells, RequestsColumnTitles[4],
              proc(r: RequestDisplayRow): string = r.duration)),
    px(widest(rows, SizeFloorCells, RequestsColumnTitles[5],
              proc(r: RequestDisplayRow): string = r.size)),
    result.list.w, unit = px(1), gap = RequestsGapPx)

proc listBody(lay: RequestsLayout): PxRect =
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc visibleTop*(st: GRequestsPane; total, rows: int): int =
  max(0, min(st.scrollTop, total - max(1, rows)))

proc scrubberOf*(st: GRequestsPane; total, rows: int): ScrubberModel =
  scrubberModel(total, st.visibleTop(total, rows), rows)

proc revealPosition*(st: var GRequestsPane; vm: RequestPanelVM; body: PxRect;
                     position: int) =
  ## Keep the request at `position` in view.
  let lay = requestsLayout(vm, body)
  if position < 0 or lay.rows <= 0:
    return
  let top = st.visibleTop(vm.matchingCount, lay.rows)
  if position < top: st.scrollTop = position
  elif position >= top + lay.rows: st.scrollTop = position - lay.rows + 1

proc scrollBy*(st: var GRequestsPane; vm: RequestPanelVM; body: PxRect;
               delta: int) =
  let lay = requestsLayout(vm, body)
  st.scrollTop = max(0, min(st.visibleTop(vm.matchingCount, lay.rows) + delta,
                            vm.matchingCount - max(1, lay.rows)))

proc shownRows*(st: GRequestsPane; vm: RequestPanelVM;
                body: PxRect): tuple[rows, top: int] =
  ## The window the pane shows — what it reports to the ViewModel.
  let lay = requestsLayout(vm, body)
  (lay.rows, st.visibleTop(vm.matchingCount, lay.rows))

proc textRun(r: GpuiRenderer; text, colour: string; widthPx = -1;
             right = false): GpuiElement =
  result = r.createElement("span")
  r.setStyle(result, "color", colour)
  r.setStyle(result, "white-space", "pre")
  r.setStyle(result, "flex-shrink", "0")
  if widthPx >= 0:
    r.setStyle(result, "width", $widthPx & "px")
    r.setStyle(result, "overflow", "hidden")
    if right:
      r.setStyle(result, "text-align", "right")
  let shown =
    if widthPx < 0: text
    else:
      let cut = fitCell(text, cellsOf(widthPx)).text
      if right: spaces(max(0, cellsOf(widthPx) - table_overflow.runeMeasure(cut))) & cut
      else: cut
  r.appendChild(result, r.createTextNode(shown))

proc rowElement(r: GpuiRenderer; widthPx, heightPx: int): GpuiElement =
  result = r.createElement("div")
  for (k, v) in [("display", "flex"), ("white-space", "nowrap"),
                 ("overflow", "hidden"), ("flex-shrink", "0"),
                 ("items", "center")]:
    r.setStyle(result, k, v)
  r.setStyle(result, "height", $heightPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  r.setStyle(result, "gap", $RequestsGapPx & "px")
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc box(r: GpuiRenderer; rect: PxRect; ground, colour, text: string;
         attr, value: string): GpuiElement =
  result = r.createElement("div")
  r.setStyle(result, "width", $rect.w & "px")
  r.setStyle(result, "height", $rect.h & "px")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "background", ground)
  r.setStyle(result, "color", colour)
  r.setStyle(result, "padding-left", $RequestsPickerPadPx & "px")
  r.setStyle(result, "white-space", "pre")
  r.setStyle(result, "overflow", "hidden")
  if attr.len > 0:
    r.setAttribute(result, attr, value)
  r.appendChild(result, r.createTextNode(text))

proc drawRequests*(r: GpuiRenderer; pane: GpuiElement; vm: RequestPanelVM;
                   st: GRequestsPane; body: PxRect): bool =
  ## Draw the pane into `pane` (its children replaced), its body at `body` in
  ## window pixels. False when there is nothing to draw it from.
  if pane.isNil or vm.isNil:
    return false
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  let lay = requestsLayout(vm, body)
  let total = vm.matchingCount
  r.setAttribute(pane, RequestsAttribute, $total)
  # The filter bar.
  let bar = rowElement(r, lay.body.w - 2 * ChromePaddingPx, RequestsBarPx)
  r.setStyle(bar, "gap", "4px")
  let search = vm.searchText.val
  let field = box(r, lay.field, RequestsFieldGround,
                  (if search.len > 0: RequestsTextColour
                   else: RequestsMutedColour),
                  (if search.len > 0: search else: RequestSearchPlaceholder),
                  "data-ct-requests-search", search)
  r.appendChild(bar, field)
  r.appendChild(bar, box(r, lay.methodPicker, RequestsPickerGround,
                         RequestsTextColour, pickerText(vm.methodPickerLabel),
                         RequestsPickerAttribute, "method"))
  r.appendChild(bar, box(r, lay.statusPicker, RequestsPickerGround,
                         RequestsTextColour, pickerText(vm.statusPickerLabel),
                         RequestsPickerAttribute, "status"))
  r.appendChild(pane, bar)
  if lay.message.h > 0:
    let m = rowElement(r, lay.message.w, RequestsRowPx)
    r.setAttribute(m, "data-ct-requests-message", vm.navigationMessage.val)
    r.appendChild(m, textRun(r, vm.navigationMessage.val, RequestsErrorColour))
    r.appendChild(pane, m)
  let f = lay.fit
  # The header.
  let header = rowElement(r, lay.list.w, RequestsRowPx)
  r.setAttribute(header, "data-ct-requests-header", "true")
  for i, title in RequestsColumnTitles:
    r.appendChild(header, textRun(r, title, RequestsLabelColour, f.widths[i],
                                  RightAligned[i]))
  r.appendChild(pane, header)
  # The rows: every position the view shows, the held ones drawn.
  let top = st.visibleTop(total, lay.rows)
  r.setAttribute(pane, "data-ct-requests-top", $top)
  r.setAttribute(pane, "data-ct-requests-rows", $lay.rows)
  let rows = vm.displayRows()
  for k in 0 ..< lay.rows:
    let position = top + k
    if position >= total:
      break
    let el = rowElement(r, lay.list.w, RequestsRowPx)
    let i = vm.heldIndexOf(position)
    if i >= 0:
      let d = rows[i]
      r.setAttribute(el, RequestRowAttribute, $d.id)
      r.setAttribute(el, "data-ct-request-position", $position)
      r.setAttribute(el, "data-ct-request-status-tone", $d.statusTone)
      r.setAttribute(el, "data-ct-request-method-tone", $d.methodTone)
      if d.isOpen:
        r.setAttribute(el, "data-ct-request-open", "true")
      if d.selected:
        r.setAttribute(el, "data-ct-selected", "true")
        r.setStyle(el, "background", RequestsSelectedGround)
      r.appendChild(el, textRun(r, d.idText, RequestsLabelColour, f.widths[0],
                                true))
      let (mText, mGround) = methodColours(d.methodTone)
      let m = textRun(r, d.httpMethod, mText, f.widths[1])
      r.setStyle(m, "background", mGround)
      r.appendChild(el, m)
      r.appendChild(el, textRun(r, d.url, RequestsTextColour, f.widths[2]))
      r.appendChild(el, textRun(r, d.status, statusColour(d.statusTone),
                                f.widths[3], true))
      r.appendChild(el, textRun(r, d.duration, RequestsLabelColour,
                                f.widths[4], true))
      r.appendChild(el, textRun(r, d.size, RequestsLabelColour, f.widths[5],
                                true))
    else:
      r.setAttribute(el, "data-ct-request-position", $position)
      r.setAttribute(el, "data-ct-request-pending", "true")
    r.appendChild(pane, el)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody, st.scrubberOf(total, lay.rows),
                     "requests")
  # The detail strip.
  if lay.detail.h > 0:
    let (_, req) = vm.selectedRequest()
    let strip = rowElement(r, lay.detail.w, RequestsRowPx)
    r.setAttribute(strip, "data-ct-requests-detail", $req.id)
    let (mText, _) = methodColours(methodTone(req.httpMethod))
    r.appendChild(strip, textRun(r, req.httpMethod, mText))
    let status = if req.isOpen: InFlightPlaceholder
                 else: detailStatusText(req.statusCode)
    let room = lay.detail.w - lay.handler.w -
               px(table_overflow.runeMeasure(req.httpMethod) + table_overflow.runeMeasure(status) + 2) -
               3 * RequestsGapPx
    r.appendChild(strip, textRun(r, req.url, RequestsTextColour, max(0, room)))
    r.appendChild(strip, textRun(r, status, statusColour(statusTone(req))))
    if lay.handler.w > 0:
      let h = box(r, lay.handler, RequestsPickerGround, RequestsHandlerColour,
                  HandlerControlLabel & " ›", "data-ct-requests-handler",
                  $req.id)
      r.setStyle(h, "margin-left", "auto")
      r.appendChild(strip, h)
    r.appendChild(pane, strip)
  true

proc requestsHitAt*(vm: RequestPanelVM; st: GRequestsPane; body: PxRect;
                    x, y: int): GRequestsHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GRequestsHit(kind: grqNone, position: -1, index: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = requestsLayout(vm, body)
  if lay.field.contains(x, y):
    return GRequestsHit(kind: grqField, position: -1, index: -1)
  if lay.methodPicker.contains(x, y):
    return GRequestsHit(kind: grqMethod, position: -1, index: -1)
  if lay.statusPicker.contains(x, y):
    return GRequestsHit(kind: grqStatus, position: -1, index: -1)
  if lay.handler.w > 0 and lay.handler.contains(x, y):
    return GRequestsHit(kind: grqHandler, position: -1, index: -1)
  let total = vm.matchingCount
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, st.scrubberOf(total, lay.rows), x, y)
    if hit.onTrack:
      return GRequestsHit(kind: (if hit.onThumb: grqThumb else: grqTrack),
                          position: -1, index: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return GRequestsHit(kind: grqOther, position: -1, index: -1)
  let position = st.visibleTop(total, lay.rows) +
                 (y - lay.list.y) div RequestsRowPx
  if position < 0 or position >= total:
    return GRequestsHit(kind: grqOther, position: -1, index: -1)
  result = GRequestsHit(kind: grqRow, position: position,
                        index: vm.heldIndexOf(position))

proc scrubRequests*(st: var GRequestsPane; vm: RequestPanelVM; body: PxRect;
                    y: int; dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let lay = requestsLayout(vm, body)
  if not lay.overflow:
    return
  let track = listTrackRect(lay.listBody)
  let sm = st.scrubberOf(vm.matchingCount, lay.rows)
  st.scrollTop = sm.scrubTop(trackFractionAt(y - track.y, track.h), dragging)

proc rowCentre*(vm: RequestPanelVM; st: GRequestsPane; body: PxRect;
                position: int): tuple[x, y: int] =
  ## Where a press on the request at `position` lands (for `--window-ops`),
  ## (-1, -1) when it is not in view.
  let lay = requestsLayout(vm, body)
  let top = st.visibleTop(vm.matchingCount, lay.rows)
  if position < top or position >= top + lay.rows:
    return (-1, -1)
  (lay.list.x + lay.fit.starts[2] + 8,
   lay.list.y + (position - top) * RequestsRowPx + RequestsRowPx div 2)
