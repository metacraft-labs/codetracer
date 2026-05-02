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
## The legacy component shell still exists to keep any backend event-
## bus subscriptions wired (M6 will subscribe to
## ``CtUpdatedHttpRequests``); each handler now mirrors its updates
## into the VM signals so the IsoNim view tracks them.
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

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

const NO_SELECTED_INDEX* = -1
  ## Sentinel that mirrors the legacy ``panelState.selectedIndex`` "no
  ## row selected" value.

type
  RequestPanelVM* = ref object of ViewModel
    ## Reactive state for the HTTP Request panel.
    store*: ReplayDataStore

    # -- Mutable state --
    requests*: Signal[seq[RequestRecord]]
    filterMethod*: Signal[string]
    filterStatus*: Signal[string]
    searchText*: Signal[string]
    selectedIndex*: Signal[int]

    # -- Derived state --
    filteredRequests*: Memo[seq[RequestRecord]]

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
  ## Mirrors the legacy ``formatDuration`` helper:
  ## ``< 1000`` ms renders as ``"NNNms"``, otherwise as
  ## ``"N.Ns"`` (one decimal place, truncated like the legacy code).
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
                 startGeid: int64) =
  ## Append a captured request.  The new ``id`` is the previous count
  ## + 1 — matches the legacy ``self.panelState.requests.len + 1``
  ## numbering so any historical fixtures keep their column values.
  var entries = vm.requests.val
  entries.add(RequestRecord(
    id: entries.len + 1,
    httpMethod: httpMethod,
    url: url,
    statusCode: statusCode,
    durationMs: durationMs,
    responseSize: responseSize,
    startGeid: startGeid,
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
  vm.requests.val = @[]
  vm.selectedIndex.val = NO_SELECTED_INDEX

proc selectRequest*(vm: RequestPanelVM; index: int) =
  ## Refresh the selected-row reference.  ``index`` is interpreted
  ## relative to the *filtered* list so the view's iteration index
  ## maps directly onto this signal.  ``NO_SELECTED_INDEX`` clears
  ## the selection.
  vm.selectedIndex.val = index

proc setFilterMethod*(vm: RequestPanelVM; methodFilter: string) =
  ## Update the method filter and reset the selected-row reference —
  ## any prior selection refers to a row in the previously-filtered
  ## list whose index may no longer be valid.
  vm.filterMethod.val = methodFilter
  vm.selectedIndex.val = NO_SELECTED_INDEX

proc setFilterStatus*(vm: RequestPanelVM; statusFilter: string) =
  ## Update the status-bucket filter; same selection-reset reasoning
  ## as ``setFilterMethod``.
  vm.filterStatus.val = statusFilter
  vm.selectedIndex.val = NO_SELECTED_INDEX

proc setSearchText*(vm: RequestPanelVM; searchText: string) =
  ## Update the URL search text; same selection-reset reasoning as
  ## ``setFilterMethod``.
  vm.searchText.val = searchText
  vm.selectedIndex.val = NO_SELECTED_INDEX

proc jumpToHandler*(vm: RequestPanelVM; index: int) =
  ## Dispatch ``ct/seek-to-geid`` for the filtered row at ``index``.
  ## The legacy proc only logged a console message because the M6
  ## wiring was outstanding; we make the wire shape explicit here so
  ## headless tests can verify the future production path.  An out-
  ## of-range index is a silent no-op.
  let filtered = vm.filteredRequests.val
  if index < 0 or index >= filtered.len:
    return
  let req = filtered[index]
  let args = %*{
    "geid": req.startGeid,
    "url": req.url,
    "httpMethod": req.httpMethod,
  }
  discard vm.store.backend.send("ct/seek-to-geid", args)

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

    let filteredRequests = createMemo[seq[RequestRecord]] proc(): seq[RequestRecord] =
      let all = requests.val
      let m = filterMethod.val
      let s = filterStatus.val
      let q = searchText.val
      result = newSeqOfCap[RequestRecord](all.len)
      for req in all:
        if matchesFilter(req, m, s, q):
          result.add(req)

    RequestPanelVM(
      store: store,
      requests: requests,
      filterMethod: filterMethod,
      filterStatus: filterStatus,
      searchText: searchText,
      selectedIndex: selectedIndex,
      filteredRequests: filteredRequests,
      disposeProc: dispose,
    )
