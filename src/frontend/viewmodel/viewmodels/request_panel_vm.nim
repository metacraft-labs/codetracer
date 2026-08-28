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

proc setDetailTab*(vm: RequestPanelVM; tab: string) =
  ## Switch the active tab in the request detail panel.
  vm.detailTab.val = tab

proc setSearchText*(vm: RequestPanelVM; searchText: string) =
  ## Update the URL search text; same selection-reset reasoning as
  ## ``setFilterMethod``.
  vm.searchText.val = searchText
  vm.selectedIndex.val = NO_SELECTED_INDEX

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
  let filtered = vm.filteredRequests.val
  if index < 0 or index >= filtered.len:
    return
  let req = filtered[index]

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
    let detailTab = createSignal("headers")

    let filteredRequests = createMemo[seq[RequestRecord]] proc(): seq[RequestRecord] =
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

    RequestPanelVM(
      store: store,
      requests: requests,
      filterMethod: filterMethod,
      filterStatus: filterStatus,
      searchText: searchText,
      selectedIndex: selectedIndex,
      filteredRequests: filteredRequests,
      detailTab: detailTab,
      openExternalTrace: nil,
      disposeProc: dispose,
    )
