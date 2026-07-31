## HTTP Request Panel — captured HTTP requests, filterable / sortable.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_request_panel_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``RequestPanelComponent`` retains its event-bus-carrier methods: its
## ``register`` subscribes to ``CtUpdatedHttpRequests`` (RS-M3) and feeds
## the delta into the shared ``ReplayDataStore``; every state mutation
## also mirrors into the parallel ``RequestPanelVM`` so the IsoNim view is
## the single source of truth for the panel's DOM.
##
## Live tail (RS-M3):
## - ``startRequestSpanPolling`` ticks ``ct/load-request-spans-since`` with
##   the store's opaque cursor.
## - The backend answers with a delta AND emits ``ct/updated-http-requests``
##   carrying the same body; ``middleware.nim`` forwards that onto the views
##   mediator, where ``register``'s subscription picks it up.
## - ``ReplayDataStore.applyRequestSpanDelta`` merges the delta keyed on span
##   id; the VM mirrors the merged list and the view repaints.
##
## Visibility (RS-M4):
## - The panel is registered as a bottom-edge auto-hide panel, so by default
##   it is a collapsed strip tab.  ``noteRequestSpanDelta`` /
##   ``autoRevealRequestPanel`` dock it the first time a delta carries request
##   rows, so ``ct replay`` on a recorded server opens with the panel showing
##   instead of leaving the user to find it.  Once per renderer only — after
##   that, visibility belongs to the user.
##
## Lifecycle:
## 1. ``utils.nim::makeRequestPanelComponent`` constructs the legacy
##    ``RequestPanelComponent`` and registers it under
##    ``Content.RequestPanel`` (one instance per panel id).
## 2. ``layout.nim`` registers the GL container, then detects
##    ``Content.RequestPanel`` is in ``isIsoNimComponent`` and calls
##    ``tryMountIsoNimRequestPanel`` instead of invoking Karax.
## 3. The mount helper appends the IsoNim panel inside the
##    ``requestPanelComponent-{id}`` container and the reactive
##    effects keep the DOM in sync with the VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via ``initRequestPanelVMWithStore`` so
##    the panel uses the production ``ReplayDataStore``.
## ---------------------------------------------------------------------------

import
  ui_imports,
  auto_hide,
  ../[ types, communication ],
  ../../common/ct_event

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import RequestRecord
from ../viewmodel/viewmodels/request_panel_vm import
  RequestPanelVM, createRequestPanelVM, NO_SELECTED_INDEX,
  setRequests, clearRequests, addRequest, selectRequest,
  jumpToHandler, setFilterMethod, setFilterStatus, setSearchText
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_request_panel_view import
    mountIsoNimRequestPanel

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by step_list / search_results / no_source / repl /
# low_level_code.
# ---------------------------------------------------------------------------

var requestPanelVMInstance*: RequestPanelVM
var requestPanelVMStore: ReplayDataStore
var requestPanelComponentRef: RequestPanelComponent

const RequestSpanPollIntervalMs* = 500
  ## RS-M3 — how often the panel polls ``ct/load-request-spans-since``.
  ##
  ## Polling is not an implementation detail we could drop: the backend emits
  ## ``ct/updated-http-requests`` *alongside the response to a poll* and
  ## suppresses it when the delta is empty (see
  ## ``db-backend/src/dap_handler.rs::load_request_spans_since`` — "an idle
  ## poll loop must not push an event per tick"), so without a tick there is
  ## no event.  A poll costs only the container chunks that were *added*
  ## since the cursor, so an idle recording makes this loop nearly free.
  ##
  ## Half a second is the "within one poll interval of completing" budget the
  ## milestone's live-tail acceptance test is written against.

var requestSpanPollingStarted = false
  ## Guards against installing a second timer when the panel is re-mounted
  ## or a second Request panel instance is opened — the tail is per-store,
  ## not per-panel.
# Track which RequestPanelComponent ids have already mounted their
# IsoNim view.  The GL container is keyed by
# ``requestPanelComponent-{id}`` so each panel instance gets its own
# mount.
var isoNimRequestPanelMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimRequestPanel*()

# ---------------------------------------------------------------------------
# Component extension (ctInExtension boiler-plate).
#
# Preserved from the legacy module so the extension entry-point still
# resolves to a valid ``RequestPanelComponent``; the in-extension
# surface has no panel markup of its own because the IsoNim view is
# the production renderer.
# ---------------------------------------------------------------------------

when defined(ctInExtension):
  var requestPanelComponentForExtension* {.exportc.}: RequestPanelComponent =
    makeRequestPanelComponent(data, 0, inExtension = true)

  proc bindRequestPanelExtensionHost(component: RequestPanelComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    # The extension request-panel surface is an empty compatibility host; keep
    # the exported component usable without retaining a Karax renderer.
    host.innerHTML = cstring""

  proc makeRequestPanelComponentForExtension*(id: cstring): RequestPanelComponent {.exportc.} =
    if requestPanelComponentForExtension.extensionRendererId.len == 0:
      requestPanelComponentForExtension.extensionRendererId = id
      requestPanelComponentForExtension.bindRequestPanelExtensionHost()
    result = requestPanelComponentForExtension

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers.
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper used by step_list / repl / low_level_code — E2E paths can
  ## land a null cstring in the legacy record, and naive ``$`` would
  ## throw inside ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc legacyEntryToVm(entry: HttpRequestEntry): RequestRecord =
  ## Map the legacy ``HttpRequestEntry`` (cstring fields) to the
  ## platform-neutral ``RequestRecord`` value type the ViewModel
  ## layer consumes.
  ##
  ## The legacy record predates spans, so it can only describe a *completed*
  ## request: ``isOpen`` is false and ``externalTracePath`` empty by
  ## construction.  Live in-flight rows come through the span-delta path.
  RequestRecord(
    id: entry.id,
    httpMethod: safeStr(entry.httpMethod),
    url: safeStr(entry.url),
    statusCode: entry.statusCode,
    durationMs: entry.durationMs,
    responseSize: entry.responseSize,
    startGeid: entry.startGEID,
    isOpen: false,
    status: "unknown",
    externalTracePath: "",
  )

proc legacyEntriesToVm(entries: seq[HttpRequestEntry]): seq[RequestRecord] =
  result = newSeqOfCap[RequestRecord](entries.len)
  for entry in entries:
    result.add(legacyEntryToVm(entry))

# ---------------------------------------------------------------------------
# Public API — called by the backend bridge when new data arrives.
# Mirrors the legacy proc surface so any historical caller keeps
# compiling; each mutator now feeds the parallel VM.
# ---------------------------------------------------------------------------

proc addRequest*(self: RequestPanelComponent,
                 httpMethod, url: cstring,
                 statusCode, durationMs, responseSize: int,
                 startGEID: int64) =
  ## Append a captured request.  Updates the legacy cache (still
  ## carried for any non-render legacy callers) AND mirrors into the
  ## VM so the IsoNim view re-renders.
  let id = self.panelState.requests.len + 1
  self.panelState.requests.add(HttpRequestEntry(
    id: id,
    httpMethod: httpMethod,
    url: url,
    statusCode: statusCode,
    durationMs: durationMs,
    responseSize: responseSize,
    startGEID: startGEID,
    sliceFile: cstring"",
  ))
  if not requestPanelVMInstance.isNil:
    requestPanelVMInstance.addRequest(
      $httpMethod, $url, statusCode, durationMs, responseSize, startGEID)

proc clearRequests*(self: RequestPanelComponent) =
  ## Wipe every captured entry and reset the selection.  Mirrored
  ## into the VM so the IsoNim view re-renders the empty state.
  self.panelState.requests = @[]
  self.panelState.selectedIndex = -1
  if not requestPanelVMInstance.isNil:
    requestPanelVMInstance.clearRequests()

proc selectRequest*(self: RequestPanelComponent, index: int) =
  ## Refresh the selected-row reference.  Mirrored into the VM.
  self.panelState.selectedIndex = index
  if not requestPanelVMInstance.isNil:
    requestPanelVMInstance.selectRequest(index)

proc jumpToHandler*(self: RequestPanelComponent, index: int) =
  ## Seek the debugger to the captured handler entry point.  The
  ## legacy implementation only logged because M6 wiring was
  ## outstanding; we keep the same behaviour at the legacy entry
  ## point and let the VM layer dispatch the canonical
  ## ``ct/seek-to-geid`` envelope (used by headless tests and the
  ## eventual M6 production path).
  if not requestPanelVMInstance.isNil:
    requestPanelVMInstance.jumpToHandler(index)

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyRequestPanelIntoVM*(self: RequestPanelComponent) =
  ## Bulk-replay the legacy ``self.panelState.requests`` cache into
  ## the VM.  Used by the layout when the panel container becomes
  ## visible (or is rebuilt) so the panel reflects every entry
  ## already accumulated by the previous IPC stream.  Per-entry
  ## updates go through ``addRequest`` directly; this proc covers
  ## the bulk-replace scenario (e.g. opening the panel after some
  ## captures already happened).
  if requestPanelVMInstance.isNil or self.isNil:
    return
  requestPanelVMInstance.setRequests(legacyEntriesToVm(self.panelState.requests))
  requestPanelVMInstance.setFilterMethod(safeStr(self.panelState.filterMethod))
  requestPanelVMInstance.setFilterStatus(safeStr(self.panelState.filterStatus))
  requestPanelVMInstance.setSearchText(safeStr(self.panelState.searchText))
  requestPanelVMInstance.selectRequest(self.panelState.selectedIndex)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# RS-M3 — live span tail
# ---------------------------------------------------------------------------

when defined(js):
  proc stringifyDeltaJs(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}

  proc requestSpanDeltaToJson(raw: JsObject): JsonNode =
    ## Convert the raw DAP event body to a stdlib ``JsonNode``.
    ##
    ## Nim's JS backend models ``JsonNode`` as a tagged object, so a plain
    ## JavaScript value cannot be cast to one — it has to go through a
    ## stringify/parse round trip (the same conversion
    ## ``viewmodel/backend/real_backend.nim`` performs).  A body that fails to
    ## round-trip yields ``null``, which ``applyRequestSpanDelta`` ignores
    ## rather than treating as an empty delta.
    if raw.isNil:
      return newJNull()
    try:
      parseJson($stringifyDeltaJs(raw))
    except CatchableError:
      cerror "requestSpanDeltaToJson: unparsable ct/updated-http-requests body"
      newJNull()
else:
  proc requestSpanDeltaToJson(raw: JsObject): JsonNode =
    ## Native builds have no DAP event source; the store is driven directly.
    newJNull()

proc openExternalRequestTrace*(tracePath: string; startGeid: int64) =
  ## RS-M3 — activate a row whose span carries an external binding.
  ##
  ## The handler's steps are not in the container currently open, so there is
  ## nothing for ``ct/seek-to-geid`` to seek to; the referenced container has
  ## to be loaded first.  ``CODETRACER::load-trace-file`` is the existing
  ## main-process path for "open this ``.ct`` by path" (see
  ## ``index/traces.nim::onLoadTraceFile``).
  ##
  ## ``startGeid`` is carried on the payload so the load handler can seek to
  ## the handler entry once cross-container seek-after-load exists; today it
  ## ignores unknown fields and simply opens the recording.
  if tracePath.len == 0:
    return
  when defined(js):
    clog "RequestPanel: opening external container " & tracePath
    data.ipc.send("CODETRACER::load-trace-file",
                  js{tracePath: cstring(tracePath), startGeid: startGeid})
  else:
    discard

# ---------------------------------------------------------------------------
# RS-M4 — surface the panel when the recording actually carries requests
# ---------------------------------------------------------------------------

var requestPanelRevealAttempts = 0
var requestPanelRevealPending = false
var requestPanelRevealSettled = false
  ## The reveal happens at most ONCE per renderer.  After that the panel's
  ## visibility is the user's: docking it again because a later delta arrived
  ## would fight whoever just closed it.

proc autoRevealRequestPanel*(): bool =
  ## Dock the REQUESTS panel if it is sitting collapsed on an auto-hide edge
  ## strip.  Returns true once the panel is actually on screen.
  ##
  ## ``layout.nim`` registers this panel through ``standaloneAutoHidePanels``,
  ## so it never enters Golden Layout and is not in
  ## ``src/config/default_layout.json`` — by default it is a collapsed bottom
  ## strip tab that a user has to know about and click.  That is the right
  ## default for the overwhelming majority of recordings, which serve no HTTP
  ## requests at all; it is the wrong default for a recorded server.
  ##
  ## Docks rather than showing the hover overlay (which is what
  ## ``autoRevealBuildPanel`` / ``autoRevealSearchResultsPanel`` do): the
  ## overlay is dismissed by the next click outside it, and a request list is
  ## something the developer reads *while* stepping through a handler.  Falls
  ## back to the overlay if the docked sidebar could not take the panel, so a
  ## missing docked container degrades to "visible" rather than "silently not
  ## revealed".
  when defined(js):
    if autoHideState.isNil:
      return false
    let panel = autoHideState.findPanelByContent(Content.RequestPanel)
    if panel.isNil:
      # Registration is on a 500 ms timer after the layout settles, so "not
      # yet" is the normal answer for the first few attempts.
      return false
    if autoHideState.dockedVisible and autoHideState.dockedPanel == panel:
      return true
    showDockedPanel(panel)
    if autoHideState.dockedVisible and autoHideState.dockedPanel == panel:
      return true
    showOverlay(panel)
    autoHideState.overlayVisible and autoHideState.activeOverlay == panel
  else:
    false

proc tryRevealRequestPanel() {.gcsafe.}

proc scheduleRequestPanelReveal() =
  ## Note that the open recording carries web requests, and get the panel on
  ## screen as soon as the layout has registered it.
  ##
  ## The retry matters: the FIRST delta usually arrives before the auto-hide
  ## panel exists, and every later poll of an idle recording returns an empty
  ## delta and emits no event (``dap_handler.rs`` suppresses the event when a
  ## delta carries nothing).  Waiting for a second delta would therefore mean
  ## waiting for a second request — on a finished recording, forever.
  if requestPanelRevealSettled or requestPanelRevealPending:
    return
  requestPanelRevealPending = true
  requestPanelRevealAttempts = 0
  tryRevealRequestPanel()

proc tryRevealRequestPanel() {.gcsafe.} =
  when defined(js):
    if not requestPanelRevealPending:
      return
    if autoRevealRequestPanel():
      requestPanelRevealPending = false
      requestPanelRevealSettled = true
      clog "RequestPanel: revealed — the recording carries web-request spans"
      return
    requestPanelRevealAttempts += 1
    if requestPanelRevealAttempts > 40:
      # ~10 s.  Give up quietly rather than retrying forever: a layout in
      # which the panel never registers is a layout problem, not something
      # this timer can fix.
      requestPanelRevealPending = false
      cwarn "RequestPanel: auto-reveal gave up; REQUESTS panel not registered"
      return
    discard setTimeout(proc() = tryRevealRequestPanel(), 250)
  else:
    requestPanelRevealPending = false

proc noteRequestSpanDelta(body: JsonNode) =
  ## Decide from one delta body whether the panel is worth surfacing.
  ##
  ## The signal is "this delta carried at least one request row", not
  ## ``meta.dat`` bit 13 on its own.  Bit 13 only says a span STREAM exists:
  ## an RS-M1b container carries ``span_type: "process"`` descriptors and sets
  ## the same bit, and the backend filters those out of the delta (see
  ## ``request_spans.rs`` — a delta holds only ``web-request`` records).  So a
  ## non-empty delta is exactly "the recording served HTTP requests", which is
  ## the condition the panel should appear for; bit 13 alone would pop an empty
  ## table open on every multi-process native recording.
  if requestPanelRevealSettled or body.isNil or body.kind != JObject:
    return
  let spans = body{"spans"}
  if spans.isNil or spans.kind != JArray or spans.len == 0:
    return
  scheduleRequestPanelReveal()

proc applyRequestSpanDeltaEvent*(raw: JsObject) =
  ## Feed one ``ct/updated-http-requests`` body into the store that backs the
  ## panel.
  ##
  ## The shared ``ReplayDataStore`` also consumes this event through its own
  ## ``installBackendEventHandlers`` subscription (the RealBackendService
  ## forwards every DAP-mapped kind).  Both paths land in
  ## ``applyRequestSpanDelta``, which is idempotent — merging a delta keyed on
  ## span id twice yields the same rows and the same cursor — so the overlap
  ## costs a redundant merge and nothing else.  The panel keeps its own
  ## subscription because it must also work when the ViewModel layer's real
  ## backend is not wired (``-d:ctInExtension``, stub-backed bootstrap).
  if requestPanelVMStore.isNil:
    return
  let body = requestSpanDeltaToJson(raw)
  requestPanelVMStore.applyRequestSpanDelta(body)
  # RS-M4 — the panel is hidden behind an edge strip by default; a recording
  # that actually serves requests brings it on screen once.
  noteRequestSpanDelta(body)

proc pollRequestSpans*() =
  ## Ask the backend for spans committed since the stored cursor.
  ## Safe before the store exists — the panel bootstraps lazily.
  if requestPanelVMStore.isNil:
    return
  requestPanelVMStore.requestRequestSpansSince()

when defined(js):
  proc startRequestSpanPolling() =
    ## Install the tail's poll timer once per renderer process.
    if requestSpanPollingStarted:
      return
    requestSpanPollingStarted = true
    # Kick off immediately so the panel shows the already-recorded requests
    # without waiting a full interval, then tail.
    pollRequestSpans()
    discard windowSetInterval(proc =
      pollRequestSpans(), RequestSpanPollIntervalMs)
else:
  proc startRequestSpanPolling() =
    ## Native builds have no timer loop here; headless tests drive
    ## ``pollRequestSpans`` / the store directly.
    discard

proc initRequestPanelVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``RequestPanelVM`` using an
  ## externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance already
  ## exists (created by ``initRequestPanelVM`` before the real backend
  ## was available) it is replaced so the panel uses the real backend.
  if requestPanelVMInstance != nil:
    clog "RequestPanelVM: replacing existing instance with shared-store version"
    isoNimRequestPanelMountedIds = JsAssoc[int, bool]{}
  requestPanelVMStore = store
  requestPanelVMInstance = createRequestPanelVM(store)
  clog "RequestPanelVM: parallel ViewModel instance created (shared store)"
  # RS-M3 — a row whose execution lives in another container cannot be reached
  # by seeking inside this one, so activating it opens that container instead.
  requestPanelVMInstance.openExternalTrace =
    proc(tracePath: string; startGeid: int64) =
      openExternalRequestTrace(tracePath, startGeid)
  tryMountIsoNimRequestPanel()
  startRequestSpanPolling()

proc initRequestPanelVM*() =
  ## Lazy fallback used when no shared store has been provided yet.
  ## Same shape as ``initStepListVM`` / ``initReplVM`` /
  ## ``initLowLevelCodeVM`` — a stub backend so the panel can still
  ## render before ``configureMiddleware`` runs.
  if requestPanelVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  requestPanelVMStore = createReplayDataStore(stubBackend)
  requestPanelVMInstance = createRequestPanelVM(requestPanelVMStore)
  clog "RequestPanelVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimRequestPanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimRequestPanel*() =
    ## Mount the IsoNim Request panel view into the GoldenLayout-
    ## managed container.  The container's id is
    ## ``requestPanelComponent-{id}`` — each open Request panel
    ## instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container appears
    ## (capped at 200 attempts, ~2 s) since GoldenLayout creates the
    ## host slightly after the layout state changes (mirrors
    ## ``tryMountIsoNimReplPanel``).
    if requestPanelVMInstance.isNil:
      return
    if requestPanelComponentRef.isNil:
      return
    let componentId = requestPanelComponentRef.id
    if isoNimRequestPanelMountedIds.hasKey(componentId):
      return

    let key = cstring("requestPanelComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimRequestPanelMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimRequestPanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimRequestPanelMountedIds[componentId] = true
      try:
        mountIsoNimRequestPanel(container, requestPanelVMInstance)
      except:
        cerror "tryMountIsoNimRequestPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync any rows the legacy component already carries so the
      # freshly-mounted view reflects the latest list.
      if not requestPanelComponentRef.isNil:
        syncLegacyRequestPanelIntoVM(requestPanelComponentRef)

    doMount()
else:
  proc tryMountIsoNimRequestPanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initRequestPanelVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

when defined(ctInExtension):
  method redrawForExtension*(self: RequestPanelComponent) =
    self.bindRequestPanelExtensionHost()

method register*(self: RequestPanelComponent, api: MediatorWithSubscribers) =
  ## Register the RequestPanelComponent with the mediator.  Bring up
  ## the IsoNim RequestPanelVM lazily so the mount procedure can find
  ## it; the shared-store version is installed by
  ## ``configureMiddleware`` if the ViewModel layer is enabled.
  ##
  ## RS-M3 — subscribe to the live span feed.  ``ct/updated-http-requests``
  ## carries a delta body (``spans`` / ``cursor`` / ``reset`` / ``source``)
  ## which goes straight into the store; the store merges it keyed on span
  ## id and the VM's mirror effect repaints the table.  ``middleware.nim``
  ## forwards the DAP event onto this mediator.
  self.api = api
  api.subscribe(CtUpdatedHttpRequests,
    proc(kind: CtEventKind, raw: JsObject, sub: Subscriber) =
      applyRequestSpanDeltaEvent(raw))
  initRequestPanelVM()
  if requestPanelComponentRef.isNil:
    requestPanelComponentRef = self
    tryMountIsoNimRequestPanel()

method restart*(self: RequestPanelComponent) =
  self.clearRequests()

method clear*(self: RequestPanelComponent) =
  self.clearRequests()

proc registerRequestPanelComponent*(component: RequestPanelComponent,
                                     api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
