## HTTP Request Panel — captured HTTP requests, filterable / sortable.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_request_panel_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``RequestPanelComponent`` retains its event-bus-carrier methods so the
## frontend's existing wiring (M6 will subscribe to
## ``CtUpdatedHttpRequests``) keeps feeding the panel; every state
## mutation now mirrors into the parallel ``RequestPanelVM`` so the
## IsoNim view is the single source of truth for the panel's DOM.
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
# render path installs an empty Karax shell since the IsoNim view is
# the production renderer.
# ---------------------------------------------------------------------------

when defined(ctInExtension):
  var requestPanelComponentForExtension* {.exportc.}: RequestPanelComponent =
    makeRequestPanelComponent(data, 0, inExtension = true)

  proc makeRequestPanelComponentForExtension*(id: cstring): RequestPanelComponent {.exportc.} =
    if requestPanelComponentForExtension.kxi.isNil:
      requestPanelComponentForExtension.kxi = setRenderer(
        proc: VNode = buildHtml(tdiv()), id, proc = discard)
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
  RequestRecord(
    id: entry.id,
    httpMethod: safeStr(entry.httpMethod),
    url: safeStr(entry.url),
    statusCode: entry.statusCode,
    durationMs: entry.durationMs,
    responseSize: entry.responseSize,
    startGeid: entry.startGEID,
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
  tryMountIsoNimRequestPanel()

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

method register*(self: RequestPanelComponent, api: MediatorWithSubscribers) =
  ## Register the RequestPanelComponent with the mediator.  Bring up
  ## the IsoNim RequestPanelVM lazily so the mount procedure can find
  ## it; the shared-store version is installed by
  ## ``configureMiddleware`` if the ViewModel layer is enabled.
  ##
  ## M6 will subscribe to backend events here, e.g.:
  ##   api.subscribe(CtUpdatedHttpRequests, ...)
  self.api = api
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
