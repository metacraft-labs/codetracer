## viewmodels/request_panel_vm.nim
##
## RequestPanelVM — ViewModel for the HTTP Request panel.
##
## The Request panel renders the table of captured HTTP requests
## with a filter bar (method dropdown, status-class dropdown,
## free-text URL search) and a body of selectable / double-clickable
## rows.  The legacy ``RequestPanelComponent`` (see
## ``frontend/ui/request_panel.nim``) implemented the panel via a
## Karax ``method render`` that:
##
## - Held the captured ``HttpRequestEntry`` records and the filter
##   signals on the component instance (``panelState``).
## - Recomputed the filtered list on every redraw via
##   ``filteredRequests`` -> ``matchesFilter``.
## - Rendered the toolbar (method / status / search) plus a flat
##   ``request-table-body`` with one row per filtered request.
## - Reacted to row clicks (``selectRequest``) and double-clicks
##   (``jumpToHandler``).
##
## The IsoNim view (``viewmodel/views/isonim_request_panel_view.nim``)
## replaces the Karax render and reads the same state from this VM.
## The legacy component shell still exists to keep the backend event-bus
## subscription wired (RS-M3: ``RequestPanelComponent.register`` subscribes
## to ``CtUpdatedHttpRequests``); each handler mirrors its updates into the
## VM signals so the IsoNim view tracks them.
##
## Live rows do NOT come through ``addRequest``.  They arrive as span deltas
## on ``ReplayDataStore.requestSpans``, which merges them keyed on span id,
## and an effect installed by ``createRequestPanelVM`` mirrors the merged
## list into ``requests``.  That is what makes the ``#`` column equal to the
## span id and what makes an open row settle in place instead of duplicating.
##
## This module is the Embed SDK's ``SpansVM``
## -----------------------------------------
## ``CodeTracer-Embed-SDK.md`` §3.1 lists the seven panel ViewModels the SDK
## exports and calls this one ``SpansVM``.  There is no ``SpansVM`` type here
## and there should not be one: the spec's name describes the *data* — the VM
## over ``ReplayDataStore.requestSpans`` — while this file predates the spec
## and is named after the *panel* it drives.  Renaming it to match would touch
## every desktop call site and the IsoNim view for a synonym, so the naming
## difference is recorded here and in ``codetracer_embed.nim``'s panel-VM
## section rather than papered over.  A reader looking for §3.1's ``SpansVM``
## has arrived at it.
##
## Reactive surface:
## - ``requests``      — captured ``RequestRecord`` list in insertion
##                       order (oldest first; the view renders the
##                       same order — newest at the bottom).
## - ``filterMethod``  — uppercase HTTP method filter.  The empty
##                       string means "all methods".  Mirrors the
##                       legacy ``panelState.filterMethod``.
## - ``filterStatus``  — status-class filter (``""`` / ``"2xx"`` /
##                       ``"3xx"`` / ``"4xx"`` / ``"5xx"``).
## - ``searchText``    — free-text search applied case-insensitively
##                       to ``url``.  Empty matches everything.
## - ``selectedIndex`` — index of the selected row inside the
##                       *filtered* list.  ``-1`` means no selection
##                       (matches the legacy sentinel).
##
## Derived:
## - ``filteredRequests`` — memoised filtered view that depends on
##                       ``requests`` plus the three filter signals.
##                       The view's row-render loop iterates this
##                       memo so a filter change does not require a
##                       re-pass over the unfiltered list.
##
## Actions:
## - ``addRequest``        — append a captured request.  Called by
##                           the backend bridge (M6 / external
##                           tests).
## - ``setRequests``       — bulk-replace the request list (used by
##                           ``syncLegacyRequestPanelIntoVM`` when
##                           the legacy component already carries
##                           captured requests).
## - ``clearRequests``     — wipe every entry (e.g. session restart
##                           or "Clear All" button).
## - ``selectRequest``     — refresh ``selectedIndex`` against the
##                           current filtered list.
## - ``jumpToHandler``     — dispatch ``ct/seek-to-geid`` for the
##                           filtered row's ``startGeid``.  Used by
##                           the IsoNim row's ``ondblclick`` handler.
## - ``setFilterMethod`` /
##   ``setFilterStatus`` /
##   ``setSearchText``     — update each filter signal.  Resets
##                           ``selectedIndex`` to ``-1`` so a stale
##                           selection on a now-filtered-out row
##                           does not bleed through.
##
## ``string`` is used everywhere so the same value works on both
## native (test-vm-native) and JS (test-vm-js) backends without
## the ``cstring`` conversion noise the legacy ``HttpRequestEntry``
## carries.

import std/[json, strutils]

import isonim/core/[signals, computation, owner, batch, async_compat]
import isonim/viewmodel

import ./action_sink

import ../backend/backend_service
import ../store/[replay_data_store, types]
import ../viewport

export viewport

const NO_SELECTED_INDEX* = -1
  ## Sentinel that mirrors the legacy ``panelState.selectedIndex`` "no
  ## row selected" value.

type
  RequestPanelVM* = ref object of ViewModel
    ## Reactive state for the HTTP Request panel.
    actionSink*: ActionSink
      ## Set in a mirror session (a VS Code webview, a `ct host` page): the
      ## view's actions run on the primary (`action_sink`,
      ## `sync/action_relay`); nil on a primary.
    store*: ReplayDataStore

    # -- Mutable state --
    requests*: Signal[seq[RequestRecord]]
    filterMethod*: Signal[string]
    filterStatus*: Signal[string]
    searchText*: Signal[string]
    selectedIndex*: Signal[int]
    navigationMessage*: Signal[string]
      ## Local feedback explaining why the last handler activation was refused.

    # -- The window (Viewport-Driven-Loading V2) --
    viewport*: Signal[Viewport]
      ## The rows the view shows (`setViewport`).
    viewportGate: ViewportGate
    windowStart*: Signal[int]
      ## The filtered row `filteredRequests[0]` is, when windowed.
    windowTotal*: Signal[int]
      ## How many requests match the filters, -1 when the panel is not
      ## windowed (a live session's tail, or a view that reports no size):
      ## `filteredRequests` is then every matching row, filtered here.
    windowRows: Signal[seq[RequestRecord]]
    selectedId: int
      ## The selected request's id, so a selection survives the window
      ## moving under it; 0 for none.

    # -- The native front-ends' own clocks (PLAT-58) --
    lastPressId: int
      ## The request the last press (`pressRow`) landed on, 0 for none.
    lastPressMs: int64
      ## When it landed, on the caller's clock.
    lastPollMs: int64
      ## When `pollTail` last asked the engine, -1 before the first poll.
    lastActivatedMs: int64
      ## When `pressRow` last answered `rpActivate`, -1 for never — so a
      ## platform `dblclick` arriving after the same two presses is not a
      ## second activation (`doubleClickRow`).
    revealed: bool
      ## `takeReveal` has answered true once (RS-M4: at most once a window).

    # -- Derived state --
    filteredRequests*: Memo[seq[RequestRecord]]

    # -- Detail panel state --
    detailTab*: Signal[string]
      ## Which tab is active in the request detail panel.
      ## One of "headers" / "request" / "response" / "timing" /
      ## "calltrace" / "asyncflow".  Defaults to "headers".

    # -- Injected side-effect hook --
    openExternalTrace*: proc(tracePath: string; startGeid: int64)
      ## RS-M3 — installed by the frontend shell.  Invoked instead of the
      ## in-session seek when the activated row's span lives in a *different*
      ## container (``RequestRecord.externalTracePath``): there is nothing to
      ## seek to in the currently open recording, so the container has to be
      ## opened first.  ``nil`` in headless tests and before the shell wires
      ## it, in which case ``jumpToHandler`` degrades to the plain seek
      ## envelope carrying the path so the request is still observable.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc statusBucket*(code: int): string =
  ## Status-class bucket text matching the legacy ``request-status-...``
  ## CSS class suffix.  Exposed so the view and headless tests can
  ## share a single source of truth for the status colouring rules.
  if code >= 200 and code < 300: "success"
  elif code >= 300 and code < 400: "redirect"
  elif code >= 400 and code < 500: "client-error"
  elif code >= 500 and code < 600: "server-error"
  else: "unknown"

proc statusClass*(code: int): string =
  ## Full ``request-status-<bucket>`` CSS class.
  "request-status-" & statusBucket(code)

proc formatDuration*(ms: int): string =
  ## Formats a millisecond duration for display in the request panel.
  ## ``< 1000`` ms → ``"NNNms"``; otherwise ``"N.Ns"`` (one decimal place).
  ##
  ## No space before the unit.  This mirrors the legacy Karax column
  ## (``fc0dcf95b``: ``$ms & "ms"`` / ``fmt"{...}.{...}s"``) — the IsoNim
  ## port (``db05fe9f0``) introduced a space here, which
  ## ``isonim_views_test``'s "match the legacy column shapes" case has been
  ## failing on ever since.  Note ``formatSize`` DOES space its unit
  ## (``" B"`` / ``" KB"``), also matching the legacy column; the asymmetry
  ## is deliberate, not an oversight.
  if ms < 1000:
    $ms & "ms"
  else:
    $(ms div 1000) & "." & $((ms mod 1000) div 100) & "s"

proc formatSize*(bytes: int): string =
  ## Mirrors the legacy ``formatSize`` helper: ``B`` for < 1024,
  ## ``KB`` (one decimal) for < 1 MB, ``MB`` (one decimal) above.
  if bytes < 1024:
    $bytes & " B"
  elif bytes < 1024 * 1024:
    $(bytes div 1024) & "." & $((bytes mod 1024) * 10 div 1024) & " KB"
  else:
    let mb = bytes div (1024 * 1024)
    let remainder = (bytes mod (1024 * 1024)) * 10 div (1024 * 1024)
    $mb & "." & $remainder & " MB"

# ---------------------------------------------------------------------------
# The row's words (PLAT-58: moved here from the desktop's view, which
# re-exports them, so the terminal's and GPUI's panes draw the same cells)
# ---------------------------------------------------------------------------

const HttpMethods* = ["GET", "POST", "PUT", "DELETE", "PATCH",
                      "HEAD", "OPTIONS"]
  ## Method-filter dropdown options.  Exposed so the view, the
  ## headless tests, and any future fixture builder share a single
  ## source of truth.  Order mirrors the legacy
  ## ``request_panel.nim::renderFilterBar`` array.

const StatusBucketOptions*: array[4, tuple[value: string; label: string]] = [
  (value: "2xx", label: "2xx Success"),
  (value: "3xx", label: "3xx Redirect"),
  (value: "4xx", label: "4xx Client Error"),
  (value: "5xx", label: "5xx Server Error"),
]
  ## Status-filter dropdown options.  Same ordering and label copy as
  ## the legacy view so visual regressions keep working.

const InFlightPlaceholder* = "—"
  ## Text rendered in the Status and Duration columns of an in-flight row.
  ## The pane spec (GUI/Core-Panes/Request-Panel.md § Live Sessions) says an
  ## in-flight row is "rendered distinctly, with no status or duration" — a
  ## placeholder keeps the column grid aligned while saying "not yet known",
  ## which a literal empty cell would not.

proc statusText*(req: RequestRecord): string =
  ## Status-column text.  An in-flight row has no status code yet (the open
  ## record carries ``statusCode == 0``), so it renders the placeholder
  ## rather than a misleading ``0``.
  if req.isOpen:
    InFlightPlaceholder
  else:
    $req.statusCode

proc statusCellClass*(req: RequestRecord): string =
  ## Status-column span class.  In flight the span's own status byte is
  ## ``"unknown"``, which is exactly the ``request-status-unknown`` bucket
  ## ``statusClass(0)`` already yields — spelled out here so the intent
  ## survives any future change to the bucket ranges.
  if req.isOpen:
    "request-status-unknown"
  else:
    statusClass(req.statusCode)

proc durationText*(req: RequestRecord): string =
  ## Duration-column text; the placeholder while in flight, since the
  ## wall-clock duration is only known at completion.
  if req.isOpen:
    InFlightPlaceholder
  else:
    formatDuration(req.durationMs)

proc formatReqId*(id: int): string =
  ## Zero-pads single-digit IDs so the ``#`` column aligns nicely
  ## (matches the reference design: 01, 02 … 09, 10, 11 …).
  if id < 10: "0" & $id else: $id

proc statusCodeText*(code: int): string =
  ## Standard HTTP reason phrase for common status codes.
  ## Returns an empty string for unrecognised codes.
  case code
  of 100: "Continue"
  of 101: "Switching Protocols"
  of 200: "OK"
  of 201: "Created"
  of 202: "Accepted"
  of 204: "No Content"
  of 206: "Partial Content"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 303: "See Other"
  of 304: "Not Modified"
  of 307: "Temporary Redirect"
  of 308: "Permanent Redirect"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 408: "Request Timeout"
  of 409: "Conflict"
  of 410: "Gone"
  of 413: "Content Too Large"
  of 422: "Unprocessable Content"
  of 429: "Too Many Requests"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
  else: ""

proc detailStatusText*(code: int): string =
  ## Full status display string for the detail panel header:
  ## "NNN Reason Phrase" for known codes, just "NNN" otherwise.
  let reason = statusCodeText(code)
  if reason.len > 0: $code & " " & reason else: $code

const MethodPickerOptions*: array[8, (string, string)] = [
  ("", "Method: All"),
  ("GET", "GET"),
  ("POST", "POST"),
  ("PUT", "PUT"),
  ("DELETE", "DELETE"),
  ("PATCH", "PATCH"),
  ("HEAD", "HEAD"),
  ("OPTIONS", "OPTIONS"),
]
  ## (filterValue, displayLabel) pairs for the Method filter picker.
  ## An empty ``filterValue`` means "all methods".

const StatusPickerOptions*: array[5, (string, string)] = [
  ("", "Status: All"),
  ("2xx", "2xx Success"),
  ("3xx", "3xx Redirect"),
  ("4xx", "4xx Client Error"),
  ("5xx", "5xx Server Error"),
]
  ## (filterValue, displayLabel) pairs for the Status filter picker.


proc matchesFilter(req: RequestRecord; filterMethod, filterStatus, searchText: string): bool =
  ## Returns true when ``req`` passes the currently active filters.
  ## Mirrors the legacy ``RequestPanelComponent.matchesFilter`` proc
  ## verbatim — same case-insensitive URL search, same status-bucket
  ## ranges, same exact-match method comparison.
  if filterMethod.len > 0 and req.httpMethod != filterMethod:
    return false

  if filterStatus.len > 0:
    case filterStatus
    of "2xx":
      if req.statusCode < 200 or req.statusCode >= 300: return false
    of "3xx":
      if req.statusCode < 300 or req.statusCode >= 400: return false
    of "4xx":
      if req.statusCode < 400 or req.statusCode >= 500: return false
    of "5xx":
      if req.statusCode < 500 or req.statusCode >= 600: return false
    else:
      discard

  if searchText.len > 0:
    if searchText.toLowerAscii notin req.url.toLowerAscii:
      return false

  return true

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc addRequest*(vm: RequestPanelVM; httpMethod, url: string;
                 statusCode, durationMs, responseSize: int;
                 startGeid: int64;
                 isOpen: bool = false;
                 status: string = "";
                 externalTracePath: string = "") =
  ## Append a captured request.  The new ``id`` is the previous count
  ## + 1 — matches the legacy ``self.panelState.requests.len + 1``
  ## numbering so any historical fixtures keep their column values.
  ##
  ## This is the *legacy / fixture* entry point.  Live rows do not come
  ## through here: they arrive as span deltas on ``ReplayDataStore`` and are
  ## mirrored into ``requests`` by the effect installed in
  ## ``createRequestPanelVM``, which is what keeps ids equal to span ids.
  ##
  ## ``status`` defaults to the bucket implied by ``statusCode`` so a caller
  ## that predates the span model still produces a coherent record.
  var entries = vm.requests.val
  entries.add(RequestRecord(
    id: entries.len + 1,
    httpMethod: httpMethod,
    url: url,
    statusCode: statusCode,
    durationMs: durationMs,
    responseSize: responseSize,
    startGeid: startGeid,
    isOpen: isOpen,
    status:
      if status.len > 0: status
      elif isOpen: "unknown"
      elif statusCode >= 200 and statusCode < 400: "ok"
      elif statusCode >= 400: "error"
      else: "unknown",
    externalTracePath: externalTracePath,
  ))
  vm.requests.val = entries

proc setRequests*(vm: RequestPanelVM; entries: seq[RequestRecord]) =
  ## Bulk-replace the request list.  Used by the legacy bridge to
  ## replay a previously-accumulated ``panelState.requests`` cache
  ## into the VM when the panel is mounted after some captures
  ## already happened.
  vm.requests.val = entries

proc clearRequests*(vm: RequestPanelVM) =
  ## Drop every captured request and reset the selection.  Mirrors
  ## the legacy ``clearRequests`` proc.
  ##
  ## The store's tail is cleared too — otherwise the mirror effect would
  ## immediately repaint the rows the user just dismissed on the next delta,
  ## and the stale cursor would suppress the snapshot that should follow.
  if not vm.store.isNil:
    vm.store.clearRequestSpans()
  vm.requests.val = @[]
  vm.selectedIndex.val = NO_SELECTED_INDEX
  vm.selectedId = 0

proc selectRequest*(vm: RequestPanelVM; index: int) =
  ## Refresh the selected-row reference.  ``index`` is interpreted
  ## relative to the *filtered* list so the view's iteration index
  ## maps directly onto this signal.  ``NO_SELECTED_INDEX`` clears
  ## the selection.
  if vm.actionSink.forwards("requestPanel", "selectRequest",
      %*{"index": index}):
    return
  vm.selectedIndex.val = index
  let rows = vm.filteredRequests.val
  vm.selectedId = if index >= 0 and index < rows.len: rows[index].id else: 0

proc windowed*(vm: RequestPanelVM): bool =
  ## The engine serves the rows by window (a completed recording).
  vm.windowTotal.val >= 0

proc matchingCount*(vm: RequestPanelVM): int =
  ## How many requests match the filters — the list's scroll range.
  if vm.windowed: vm.windowTotal.val else: vm.filteredRequests.val.len

proc recordedCount*(vm: RequestPanelVM): int =
  ## How many requests the recording served.
  if vm.windowed and not vm.store.isNil and
     vm.store.requestSpans.recordedTotal.val >= 0:
    vm.store.requestSpans.recordedTotal.val
  else:
    vm.requests.val.len

proc setViewport*(vm: RequestPanelVM; v: Viewport) =
  ## The rows the view shows — the ONE way a view tells this ViewModel what
  ## it shows (Viewport-Driven-Loading V1). For a completed recording the
  ## window of matching requests is then asked for, filtered by the engine.
  # A mirror reports its measured size to the primary and keeps it too.
  discard vm.actionSink.forwards("viewport", "set", %*{
    "pane": "requestPanel", "rows": v.rows, "depth": v.cols,
    "firstRow": v.firstRow})
  vm.viewportGate.submit(v)

proc setFilterMethod*(vm: RequestPanelVM; methodFilter: string) =
  ## Update the method filter and reset the selected-row reference —
  ## any prior selection refers to a row in the previously-filtered
  ## list whose index may no longer be valid.
  if vm.actionSink.forwards("requestPanel", "setFilterMethod",
      %*{"filter": methodFilter}):
    return
  vm.filterMethod.val = methodFilter
  vm.selectedIndex.val = NO_SELECTED_INDEX
  vm.selectedId = 0

proc setFilterStatus*(vm: RequestPanelVM; statusFilter: string) =
  ## Update the status-bucket filter; same selection-reset reasoning
  ## as ``setFilterMethod``.
  if vm.actionSink.forwards("requestPanel", "setFilterStatus",
      %*{"filter": statusFilter}):
    return
  vm.filterStatus.val = statusFilter
  vm.selectedIndex.val = NO_SELECTED_INDEX
  vm.selectedId = 0

proc setDetailTab*(vm: RequestPanelVM; tab: string) =
  ## Switch the active tab in the request detail panel.
  if vm.actionSink.forwards("requestPanel", "setDetailTab", %*{"tab": tab}):
    return
  vm.detailTab.val = tab

proc setSearchText*(vm: RequestPanelVM; searchText: string) =
  ## Update the URL search text; same selection-reset reasoning as
  ## ``setFilterMethod``.
  if vm.actionSink.forwards("requestPanel", "setSearchText",
      %*{"text": searchText}):
    return
  vm.searchText.val = searchText
  vm.selectedIndex.val = NO_SELECTED_INDEX
  vm.selectedId = 0

proc jumpToHandler*(vm: RequestPanelVM; index: int) =
  ## Activate the filtered row at ``index`` — the double-click action.
  ##
  ## Two destinations, per the pane spec's *Interactions* section ("a request
  ## span names a coordinate … activating a row moves the existing replay
  ## session to the handler's first step"):
  ##
  ## - The span's execution is in the container already open (the normal
  ##   case): dispatch ``ct/seek-to-geid`` for the span's ``startGeid``.
  ## - The span carries an external binding (``externalTracePath``): the
  ##   handler's steps are not in this container at all, so the container is
  ##   opened instead through the injected ``openExternalTrace`` hook.
  ##
  ## An out-of-range index is a silent no-op.
  if vm.actionSink.forwards("requestPanel", "jumpToHandler",
      %*{"index": index}):
    return
  let filtered = vm.filteredRequests.val
  if index < 0 or index >= filtered.len:
    return
  let req = filtered[index]
  vm.navigationMessage.val = req.seekUnavailableReason
  # Scheduler bookkeeping may bound an uninstrumented handler. Never present
  # that coordinate as source entry, including for an external container.
  if req.seekUnavailableReason.len > 0:
    return

  if req.externalTracePath.len > 0 and not vm.openExternalTrace.isNil:
    vm.openExternalTrace(req.externalTracePath, req.startGeid)
    return

  # ``externalTracePath`` is carried on the envelope even when the hook is
  # absent: the backend can then route the seek itself, and a headless test
  # can still observe which container the row pointed at.  The seek args are
  # tolerant of extra fields (``SeekToGeidArguments`` does not deny unknown
  # keys), which is also why ``url`` / ``httpMethod`` ride along.
  let args = %*{
    "geid": req.startGeid,
    "url": req.url,
    "httpMethod": req.httpMethod,
    "externalTracePath": req.externalTracePath,
  }
  vm.store.requestHistoricalNavigation("ct/seek-to-geid", args)


# ---------------------------------------------------------------------------
# PLAT-58 — what the terminal's and GPUI's panes read
#
# `Request-Panel.md` § "The terminal and the GPUI window (PLAT-58)". Every
# decision a native painter would otherwise make for itself — a row's cells
# and colours, the columns, a double press, the row's menu, the pickers'
# entries, the tail's cadence, the one-time reveal — is made here, once, so the
# three front-ends cannot disagree.
# ---------------------------------------------------------------------------

const
  RequestSpanPollIntervalMs* = 500
    ## RS-M3 — how often a live session's tail is polled
    ## (`ct/load-request-spans-since`). The desktop's interval, moved here so
    ## the native hosts' idle ticks keep the same cadence (`pollTail`).
    ##
    ## Polling is not an implementation detail we could drop: the backend emits
    ## ``ct/updated-http-requests`` *alongside the response to a poll* and
    ## suppresses it when the delta is empty (see
    ## ``db-backend/src/dap_handler.rs::load_request_spans_since`` — "an idle
    ## poll loop must not push an event per tick"), so without a tick there is
    ## no event. Half a second is the "within one poll interval of completing"
    ## budget the RS-M3 live-tail acceptance test is written against.
  RequestDoubleClickMs* = 500
    ## Two presses on the same row this close together are a double click —
    ## the desktop's `ondblclick`. Neither native platform hands the pane a
    ## click count, so the ViewModel counts (`pressRow`).
  RequestsColumnTitles* = ["#", "method", "URL", "Status", "Duration", "Size"]
    ## The header's words, the desktop's (`isonim_request_panel_view`'s
    ## `request-table-header`), in column order.
  RequestSearchPlaceholder* = "Find by URL..."
    ## The URL field's placeholder, the desktop's.
  HandlerControlLabel* = "Handler"
    ## The detail strip's activation control's word; each front-end draws its
    ## own arrow after it (the desktop's button reads "Handler >").
  GoToHandlerLabel* = "Go to Handler"
  CopyUrlLabel* = "Copy URL"
  FilterByMethodPrefix* = "Filter by Method: "
  FilterByStatusPrefix* = "Filter by Status: "
  ClearFiltersLabel* = "Clear Filters"

type
  RequestTone* = enum
    ## How a row's status is coloured — the `request-status-<bucket>` class.
    rtUnknown = "unknown"            ## `colors-ui-text-primary-label`
    rtSuccess = "success"            ## 2xx: `colors-ui-text-success-primary`
    rtRedirect = "redirect"          ## 3xx: `colors-ui-text-information-primary`
    rtClientError = "client-error"   ## 4xx: `colors-ui-text-warning-primary`
    rtServerError = "server-error"   ## 5xx: `colors-ui-text-error-primary`

  MethodTone* = enum
    ## How a row's method is coloured — the `request-method-<verb>` badge.
    mtLabel = "label"                ## HEAD, OPTIONS, anything else
    mtInformation = "information"    ## GET
    mtSuccess = "success"            ## POST
    mtWarning = "warning"            ## PUT, PATCH
    mtError = "error"                ## DELETE

  RequestDisplayRow* = object
    ## One request as a native pane draws it: every cell already in words.
    index*: int
      ## Into `filteredRequests` (the rows held).
    position*: int
      ## Its place among ALL matching requests (`windowStart + index` while
      ## windowed) — the row a native list scrolls to.
    id*: int
    idText*, httpMethod*, url*, status*, duration*, size*: string
    statusTone*: RequestTone
    methodTone*: MethodTone
    isOpen*: bool
    selected*: bool
    seekUnavailableReason*: string

  RequestPress* = enum
    ## What a press on a row did (`pressRow`).
    rpNone       ## no such row
    rpSelected   ## the desktop's click: the row is selected
    rpActivate   ## the desktop's double click: go to its handler

  RequestActivationKind* = enum
    raNone       ## no such row
    raSeek       ## `ct/seek-to-geid` sent: the host waits for the move
    raRefused    ## the recorder reported no handler step; nothing was sent
    raExternal   ## the span lives in another container, handed to
                 ## `openExternalTrace`

  RequestActivation* = object
    kind*: RequestActivationKind
    reason*: string
      ## raRefused: why, in words.
    tracePath*: string
      ## raExternal: the container's path.
    startGeid*: int64
    url*: string

  RequestMenuAction* = enum
    rmGoToHandler = "go-to-handler"
    rmCopyUrl = "copy-url"
    rmFilterMethod = "filter-method"
    rmFilterStatus = "filter-status"
    rmClearFilters = "clear-filters"

  RequestMenuEntry* = object
    label*: string
    action*: RequestMenuAction
    enabled*: bool
    reason*: string
      ## Why a disabled entry is disabled (shown beside it).

  RequestMenuOutcome* = object
    ## What choosing an entry did; the host performs the part only it can
    ## (a seek's move, the clipboard).
    activation*: RequestActivation
      ## rmGoToHandler.
    copied*: string
      ## rmCopyUrl: the text for the clipboard.
    done*: bool
      ## The entry ran (false for a disabled one or no such row).

const RequestsCommandVerb* = "requests"
  ## `:requests` — the omnibox's (the terminal's command line's) URL field.

func requestsCommandOf*(line: string): tuple[isRequests, openField: bool;
                                             search: string] =
  ## `Request-Panel.md` § N.4: `:requests <text>` sets the URL search to
  ## `text`; `:requests ` with nothing after the verb clears it; `:requests`
  ## alone answers `openField` — the front-end opens the field (the omnibox on
  ## `:requests <search>`) when no search is on, and clears the search when
  ## one is (the field, emptied and submitted, arrives as the bare verb: an
  ## omnibox trims its line). `line` is the raw line, its leading `:`
  ## optional.
  var t = line.strip(trailing = false)
  if t.startsWith(":"):
    t = t[1 .. ^1].strip(trailing = false)
  let n = RequestsCommandVerb.len
  if t.len < n or t[0 ..< n].toLowerAscii != RequestsCommandVerb or
     (t.len > n and t[n] notin Whitespace):
    return (false, false, "")
  let rest = t[n .. ^1]
  if rest.len == 0:
    return (true, true, "")
  (true, false, rest.strip())

proc statusTone*(req: RequestRecord): RequestTone =
  ## The status cell's tone: `statusCellClass`'s bucket as a value.
  if req.isOpen:
    return rtUnknown
  case statusBucket(req.statusCode)
  of "success": rtSuccess
  of "redirect": rtRedirect
  of "client-error": rtClientError
  of "server-error": rtServerError
  else: rtUnknown

proc methodTone*(httpMethod: string): MethodTone =
  ## The method cell's tone: `request_panel.styl`'s badge rules.
  case httpMethod.toUpperAscii
  of "GET": mtInformation
  of "POST": mtSuccess
  of "DELETE": mtError
  of "PUT", "PATCH": mtWarning
  else: mtLabel

proc statusClassOf*(code: int): string =
  ## The status filter value a code belongs to (`"2xx"` … `"5xx"`), "" for
  ## none.
  if code >= 200 and code < 600: $(code div 100) & "xx" else: ""

proc positionOf*(vm: RequestPanelVM; index: int): int =
  ## The place of held row `index` among all matching requests.
  if vm.windowed: vm.windowStart.val + index else: index

proc displayRows*(vm: RequestPanelVM): seq[RequestDisplayRow] =
  ## The held rows, every cell in the desktop's words, in the order drawn.
  let rows = vm.filteredRequests.val
  let selected = vm.selectedIndex.val
  result = newSeqOfCap[RequestDisplayRow](rows.len)
  for i, req in rows:
    result.add RequestDisplayRow(
      index: i, position: vm.positionOf(i), id: req.id,
      idText: formatReqId(req.id), httpMethod: req.httpMethod, url: req.url,
      status: statusText(req), duration: durationText(req),
      size: formatSize(req.responseSize), statusTone: statusTone(req),
      methodTone: methodTone(req.httpMethod), isOpen: req.isOpen,
      selected: i == selected,
      seekUnavailableReason: req.seekUnavailableReason)

proc selectedRequest*(vm: RequestPanelVM): tuple[ok: bool; req: RequestRecord] =
  ## The selected request, when one is selected and held.
  let rows = vm.filteredRequests.val
  let i = vm.selectedIndex.val
  if i >= 0 and i < rows.len: (true, rows[i]) else: (false, RequestRecord())

proc heldIndexOf*(vm: RequestPanelVM; position: int): int =
  ## The held row at `position` among all matching requests, -1 when that
  ## row is not held (outside the window the engine answered).
  let i = if vm.windowed: position - vm.windowStart.val else: position
  if i >= 0 and i < vm.filteredRequests.val.len: i else: -1

proc methodPickerLabel*(vm: RequestPanelVM): string =
  ## The Method picker's label: `Method: All`, or the chosen verb — the
  ## desktop's `renderFilterPicker` (`currentValue` when set).
  if vm.filterMethod.val.len == 0: MethodPickerOptions[0][1]
  else: vm.filterMethod.val

proc statusPickerLabel*(vm: RequestPanelVM): string =
  if vm.filterStatus.val.len == 0: StatusPickerOptions[0][1]
  else: vm.filterStatus.val

proc anyFilter*(vm: RequestPanelVM): bool =
  vm.filterMethod.val.len > 0 or vm.filterStatus.val.len > 0 or
    vm.searchText.val.len > 0

proc clearFilters*(vm: RequestPanelVM) =
  ## Every filter off — the menu's "Clear Filters" (selection cleared, as by
  ## any filter change).
  batch(proc() =
    vm.setFilterMethod("")
    vm.setFilterStatus("")
    vm.setSearchText(""))

proc activate*(vm: RequestPanelVM; index: int): RequestActivation =
  ## Go to held row `index`'s handler — the desktop's double click
  ## (`jumpToHandler`), with what it did said, so a native host knows whether
  ## to wait for a move.
  let rows = vm.filteredRequests.val
  if index < 0 or index >= rows.len:
    return RequestActivation(kind: raNone)
  let req = rows[index]
  result = RequestActivation(startGeid: req.startGeid, url: req.url)
  if req.seekUnavailableReason.len > 0:
    vm.jumpToHandler(index)   # sets the navigation message, sends nothing
    result.kind = raRefused
    result.reason = req.seekUnavailableReason
    return
  if req.externalTracePath.len > 0 and not vm.openExternalTrace.isNil:
    result.kind = raExternal
    result.tracePath = req.externalTracePath
  else:
    result.kind = raSeek
  vm.jumpToHandler(index)

proc pressRow*(vm: RequestPanelVM; index: int; nowMs: int64): RequestPress =
  ## A press on held row `index` at `nowMs`: the first selects it (the
  ## desktop's click), a second on the same request within
  ## `RequestDoubleClickMs` is the double click — the caller then activates
  ## it (`activate`). A third press starts counting again.
  let rows = vm.filteredRequests.val
  if index < 0 or index >= rows.len:
    vm.lastPressId = 0
    return rpNone
  let id = rows[index].id
  let double = vm.lastPressId == id and nowMs >= vm.lastPressMs and
               nowMs - vm.lastPressMs <= RequestDoubleClickMs
  vm.selectRequest(index)
  if double:
    vm.lastPressId = 0
    vm.lastActivatedMs = nowMs
    return rpActivate
  vm.lastPressId = id
  vm.lastPressMs = nowMs
  rpSelected

proc doubleClickRow*(vm: RequestPanelVM; index: int; nowMs: int64): bool =
  ## A platform double click on held row `index` (the desktop's
  ## `ondblclick`): go to its handler — unless `pressRow` already did for the
  ## two presses that made it (within `RequestDoubleClickMs`). The desktop
  ## counts presses with `pressRow` too, because its row is rebuilt by the
  ## first click's selection and the browser's `dblclick` then never reaches
  ## the new element. Whether it activated.
  if vm.lastActivatedMs >= 0 and nowMs >= vm.lastActivatedMs and
     nowMs - vm.lastActivatedMs <= RequestDoubleClickMs:
    return false
  vm.jumpToHandler(index)
  true

proc moveSelection*(vm: RequestPanelVM; operation: string; page: int): int =
  ## The keyboard's `list.*` moves over the held rows: the new selected index
  ## (selected), or -1 when there is no row or `operation` is not a move.
  ## A move stays inside the rows held; a host keeps the selection in view,
  ## which moves the window the engine answers.
  let n = vm.filteredRequests.val.len
  if n == 0:
    return -1
  let sel = vm.selectedIndex.val
  let next =
    case operation
    of "list.focus-first": 0
    of "list.focus-last": n - 1
    of "list.focus-page-down": (if sel < 0: 0 else: sel + max(1, page))
    of "list.focus-page-up": (if sel < 0: 0 else: sel - max(1, page))
    of "list.focus-next": (if sel < 0: 0 else: sel + 1)
    of "list.focus-previous": (if sel < 0: n - 1 else: sel - 1)
    else: -2
  if next == -2:
    return -1
  let at = clamp(next, 0, n - 1)
  vm.selectRequest(at)
  at

proc rowMenu*(vm: RequestPanelVM; index: int): seq[RequestMenuEntry] =
  ## Held row `index`'s context menu (`Request-Panel.md` § N.5), in order;
  ## empty for no such row.
  let rows = vm.filteredRequests.val
  if index < 0 or index >= rows.len:
    return @[]
  let req = rows[index]
  let refused = req.seekUnavailableReason
  result.add RequestMenuEntry(label: GoToHandlerLabel, action: rmGoToHandler,
                              enabled: refused.len == 0, reason: refused)
  result.add RequestMenuEntry(label: CopyUrlLabel, action: rmCopyUrl,
                              enabled: true)
  let verb = req.httpMethod.toUpperAscii
  let methodOn = vm.filterMethod.val == verb
  result.add RequestMenuEntry(label: FilterByMethodPrefix & verb,
    action: rmFilterMethod, enabled: verb.len > 0 and not methodOn,
    reason: (if methodOn: "the method filter is already " & verb
             elif verb.len == 0: "the request has no method"
             else: ""))
  let cls = if req.isOpen: "" else: statusClassOf(req.statusCode)
  let statusOn = cls.len > 0 and vm.filterStatus.val == cls
  result.add RequestMenuEntry(
    label: FilterByStatusPrefix & (if cls.len > 0: cls else: InFlightPlaceholder),
    action: rmFilterStatus, enabled: cls.len > 0 and not statusOn,
    reason: (if req.isOpen: "the request is still in flight"
             elif cls.len == 0: "the status has no class"
             elif statusOn: "the status filter is already " & cls
             else: ""))
  let any = vm.anyFilter
  result.add RequestMenuEntry(label: ClearFiltersLabel, action: rmClearFilters,
    enabled: any, reason: (if any: "" else: "no filter is on"))

proc runRowMenu*(vm: RequestPanelVM; index: int;
                 action: RequestMenuAction): RequestMenuOutcome =
  ## Choose `action` of held row `index`'s menu. A disabled entry does
  ## nothing (`done` false), as the desktop's disabled entries do.
  let rows = vm.filteredRequests.val
  if index < 0 or index >= rows.len:
    return
  var enabled = false
  for e in vm.rowMenu(index):
    if e.action == action:
      enabled = e.enabled
  if not enabled:
    return
  let req = rows[index]
  result.done = true
  case action
  of rmGoToHandler:
    result.activation = vm.activate(index)
  of rmCopyUrl:
    result.copied = req.url
  of rmFilterMethod:
    vm.setFilterMethod(req.httpMethod.toUpperAscii)
  of rmFilterStatus:
    vm.setFilterStatus(statusClassOf(req.statusCode))
  of rmClearFilters:
    vm.clearFilters()

proc pollTail*(vm: RequestPanelVM; nowMs: int64): bool =
  ## A native host's idle tick: ask the engine for the requests committed
  ## since the store's cursor, at most once every `RequestSpanPollIntervalMs`
  ## — the desktop's poll timer (`ui/request_panel.startRequestSpanPolling`).
  ## The store applies the desktop's rule: a live session is tailed; a
  ## completed recording is asked once how many requests it served and is
  ## then read by window. Whether a poll was due.
  if vm.store.isNil or vm.store.backend.isNil:
    return false
  if vm.lastPollMs >= 0 and nowMs >= vm.lastPollMs and
     nowMs - vm.lastPollMs < RequestSpanPollIntervalMs:
    return false
  vm.lastPollMs = nowMs
  vm.store.requestRequestSpansSince()
  true

proc takeReveal*(vm: RequestPanelVM): bool =
  ## True ONCE, the first time the session's requests are known to be
  ## non-empty (`recordedCount > 0`): the moment the desktop docks its
  ## REQUESTS panel (RS-M4). After that visibility is the user's.
  if vm.revealed:
    return false
  let recorded = if vm.store.isNil: -1
                 else: vm.store.requestSpans.recordedTotal.val
  if recorded > 0 or vm.recordedCount > 0 or vm.requests.val.len > 0:
    vm.revealed = true
    return true
  false

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createRequestPanelVM*(store: ReplayDataStore): RequestPanelVM =
  ## Create a RequestPanelVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty/inert default
  ## so the view renders the empty-state placeholder on first paint.
  withViewModel proc(dispose: proc()): RequestPanelVM =
    let requests = createSignal(newSeq[RequestRecord]())
    let filterMethod = createSignal("")
    let filterStatus = createSignal("")
    let searchText = createSignal("")
    let selectedIndex = createSignal(NO_SELECTED_INDEX)
    let navigationMessage = createSignal("")
    let detailTab = createSignal("headers")

    let viewport = createSignal(Viewport())
    let windowStart = createSignal(0)
    let windowTotal = createSignal(-1)
    let windowRows = createSignal(newSeq[RequestRecord]())
    let viewportGate = newViewportGate(
      proc(): ViewportScheduler =
        if store.isNil: nil else: store.viewportScheduler,
      proc(v: Viewport) = viewport.val = v)

    let filteredRequests = createMemo[seq[RequestRecord]] proc(): seq[RequestRecord] =
      if windowTotal.val >= 0:
        # The engine filtered and windowed them (a completed recording).
        return windowRows.val
      let all = requests.val
      let m = filterMethod.val
      let s = filterStatus.val
      let q = searchText.val
      result = newSeqOfCap[RequestRecord](all.len)
      for req in all:
        if matchesFilter(req, m, s, q):
          result.add(req)

    # RS-M3 — mirror the store's live span tail into the panel's own
    # ``requests`` signal.
    #
    # The store is the producer: it merges every ``ct/updated-http-requests``
    # delta keyed on span id, so by the time the effect runs the list is
    # already deduplicated and ordered.  Mirroring (rather than making
    # ``requests`` a memo over the store) keeps ``addRequest`` /
    # ``setRequests`` — the legacy bridge, Storybook fixtures and the 14
    # existing view tests — writing to a plain signal.
    #
    # The very first run assigns the store's list (empty for a fresh
    # session) over the VM's empty list, so a VM created *after* rows were
    # already tailed picks them up on construction.  Only the store signal is
    # dereferenced inside the effect — reading ``requests`` here would make
    # the effect depend on its own output.
    if not store.isNil:
      createEffect proc() =
        requests.val = store.requestSpans.requests.val

    let vm = RequestPanelVM(
      store: store,
      requests: requests,
      filterMethod: filterMethod,
      filterStatus: filterStatus,
      searchText: searchText,
      selectedIndex: selectedIndex,
      navigationMessage: navigationMessage,
      viewport: viewport,
      viewportGate: viewportGate,
      windowStart: windowStart,
      windowTotal: windowTotal,
      windowRows: windowRows,
      filteredRequests: filteredRequests,
      detailTab: detailTab,
      openExternalTrace: nil,
      lastPollMs: -1,
      lastActivatedMs: -1,
      disposeProc: dispose,
    )

    if not store.isNil and not store.backend.isNil:
      # THE WINDOW OF A COMPLETED RECORDING (Viewport-Driven-Loading V2;
      # issue 2026-10-20 "the request panel loads a whole snapshot and
      # filters it on the client"): the rows the view shows plus the 20/10
      # buffers, filtered by the engine (`ct/load-request-spans`), once per
      # distinct window and filter. A live session keeps its tail
      # (`requestRequestSpansSince`), which the panel filters itself; an
      # unmeasured view asks nothing.
      var lastKey = ""
      createEffect proc() =
        let w = listWindow(viewport.val)
        let m = filterMethod.val
        let st = filterStatus.val
        let q = searchText.val
        let live = store.session.val.debugSessionMode.historicalModeTarget()
        if w.count <= 0 or live:
          return
        let args = %*{"start": w.start, "limit": w.count,
                      "filters": {"method": m, "statusClass": st,
                                  "urlContains": q}}
        let key = $args
        if key == lastKey:
          return
        lastKey = key
        onComplete(store.backend.send("ct/load-request-spans", args),
          proc(response: JsonNode) =
            if not responseSucceeded(response) or key != lastKey:
              return
            let body = responseBody(response)
            var rows: seq[RequestRecord] = @[]
            for item in body{"requests"}.getElems:
              rows.add parseRequestRecord(item)
            batch(proc() =
              windowStart.val = w.start
              windowTotal.val = body{"total"}.getInt(0)
              windowRows.val = rows
              # The selection follows its request, wherever the window put it.
              var at = NO_SELECTED_INDEX
              if vm.selectedId != 0:
                for i, r in rows:
                  if r.id == vm.selectedId:
                    at = i
              selectedIndex.val = at),
          proc(message: string) = discard)

    vm
