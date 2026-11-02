## HTTP Request Panel — captured HTTP requests, filterable / sortable.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_request_panel_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``RequestPanelComponent`` keeps its lifecycle methods; the deltas reach
## the shared ``ReplayDataStore`` through the session's own backend event
## handlers, and the IsoNim view over the session's ``RequestPanelVM`` is the
## single source of truth for the panel's DOM.
##
## Live tail (RS-M3):
## - ``startRequestSpanPolling`` ticks ``ct/load-request-spans-since`` with
##   the store's opaque cursor.
## - The backend answers with a delta AND emits ``ct/updated-http-requests``
##   carrying the same body; the store's ``installBackendEventHandlers``
##   subscription consumes it.
## - ``ReplayDataStore.applyRequestSpanDelta`` merges the delta keyed on span
##   id; the VM mirrors the merged list and the view repaints.
##
## Visibility (RS-M4):
## - The panel is registered as a bottom-edge auto-hide panel, so by default
##   it is a collapsed strip tab.  An effect on the store's request rows
##   (``initRequestPanelVMFromSession``) and ``autoRevealRequestPanel`` dock
##   it the first time the recording's requests arrive, so ``ct replay`` on
##   a recorded server opens with the panel showing instead of leaving the
##   user to find it.  Once per renderer only — after
##   that, visibility belongs to the user.
##
## Lifecycle:
## 1. ``utils.nim::makeRequestPanelComponent`` constructs the legacy
##    ``RequestPanelComponent`` and registers it under
##    ``Content.RequestPanel`` (one instance per panel id).
## 2. GoldenLayout's factory (``layout.nim``) creates the
##    ``requestPanelComponent-{id}`` container and the panel host
##    (``ui/panel_host``) mounts the view into it, on the session's
##    ``RequestPanelVM`` (``setPanelRenderer`` below); reactive effects keep
##    the DOM in sync with the VM, and the host reports the rows it shows.
## 3. ``configureMiddleware`` (in ``ui_js.nim``) hands the module the
##    session's VM via ``initRequestPanelVMFromSession``. The VS Code
##    extension, which has no session store, keeps a stub-backed VM fed by
##    the component's own subscription.
## ---------------------------------------------------------------------------

import
  ui_imports,
  auto_hide,
  session_viewmodels,
  ../[ types, communication ],
  ../../common/ct_event

import std/json
from isonim/core/batch import untrack
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import RequestRecord
from ../viewmodel/viewmodels/request_panel_vm import
  RequestPanelVM, createRequestPanelVM, NO_SELECTED_INDEX,
  setRequests, clearRequests, addRequest, selectRequest,
  jumpToHandler, setFilterMethod, setFilterStatus, setSearchText,
  RequestSpanPollIntervalMs
when defined(js):
  from isonim/web/dom_api import nil
  import ../viewmodel/views/isonim_request_panel_view
  import isonim/web/web_renderer
  import ./panel_host
  from ../viewmodel/session_vm import SessionViewModel

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by step_list / search_results / no_source / repl /
# low_level_code.
# ---------------------------------------------------------------------------

var requestPanelVMInstance*: RequestPanelVM
var requestPanelVMStore: ReplayDataStore
var requestPanelComponentRef: RequestPanelComponent

# `RequestSpanPollIntervalMs` — how often the tail is polled — is the
# ViewModel's (PLAT-58), so the native hosts' idle ticks keep the same cadence.

var requestSpanPollingStarted = false
  ## Guards against installing a second timer when the panel is re-mounted
  ## or a second Request panel instance is opened — the tail is per-store,
  ## not per-panel.

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
  let vm = ownPaneVM(self, requestPanelVMInstance, requestPanelVM)
  if not vm.isNil:
    vm.addRequest(
      $httpMethod, $url, statusCode, durationMs, responseSize, startGEID)

proc clearRequests*(self: RequestPanelComponent) =
  ## Wipe every captured entry and reset the selection.  Mirrored
  ## into the VM so the IsoNim view re-renders the empty state.
  self.panelState.requests = @[]
  self.panelState.selectedIndex = -1
  let vm = ownPaneVM(self, requestPanelVMInstance, requestPanelVM)
  if not vm.isNil:
    vm.clearRequests()

proc selectRequest*(self: RequestPanelComponent, index: int) =
  ## Refresh the selected-row reference.  Mirrored into the VM.
  self.panelState.selectedIndex = index
  let vm = ownPaneVM(self, requestPanelVMInstance, requestPanelVM)
  if not vm.isNil:
    vm.selectRequest(index)

proc jumpToHandler*(self: RequestPanelComponent, index: int) =
  ## Seek the debugger to the captured handler entry point.  The
  ## legacy implementation only logged because M6 wiring was
  ## outstanding; we keep the same behaviour at the legacy entry
  ## point and let the VM layer dispatch the canonical
  ## ``ct/seek-to-geid`` envelope (used by headless tests and the
  ## eventual M6 production path).
  let vm = ownPaneVM(self, requestPanelVMInstance, requestPanelVM)
  if not vm.isNil:
    vm.jumpToHandler(index)

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
  if self.isNil:
    return
  # The ViewModel of this component's own tab (`ownPaneVM`).
  let vm = ownPaneVM(self, requestPanelVMInstance, requestPanelVM)
  if vm.isNil:
    return
  vm.setRequests(legacyEntriesToVm(self.panelState.requests))
  vm.setFilterMethod(safeStr(self.panelState.filterMethod))
  vm.setFilterStatus(safeStr(self.panelState.filterStatus))
  vm.setSearchText(safeStr(self.panelState.searchText))
  vm.selectRequest(self.panelState.selectedIndex)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# RS-M3 — live span tail
# ---------------------------------------------------------------------------

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
  ## ``autoRevealBuildPanel`` does): the
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

proc initRequestPanelVMFromSession*(vm: RequestPanelVM) =
  ## Hand the pane the session's `RequestPanelVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ##
  ## If a stub-backed instance already exists (created before the session
  ## was available), it is replaced so the panel uses the real backend.
  let store = vm.store
  requestPanelVMStore = store
  requestPanelVMInstance = vm
  clog "RequestPanelVM: parallel ViewModel instance created (shared store)"
  # Once per ViewModel: this is called again for the shown tab's session on
  # every tab switch, and the effect below must not stack.
  if firstBinding(vm):
    # RS-M3 — a row whose execution lives in another container cannot be
    # reached by seeking inside this one, so activating it opens that
    # container instead.
    vm.openExternalTrace =
      proc(tracePath: string; startGeid: int64) =
        openExternalRequestTrace(tracePath, startGeid)
    # RS-M4 — the panel is hidden behind an edge strip by default; a
    # recording that actually serves requests brings it on screen once. The
    # store merges every delta (the poll's answer and the
    # `ct/updated-http-requests` event), so its rows are the signal.
    #
    # A COMPLETED recording's rows are read by window, so its tail list stays
    # empty and only its count (`recordedTotal`, the first poll's answer) says
    # it serves requests — the same two facts `RequestPanelVM.takeReveal`
    # reads for the native panes (PLAT-58). Watching the rows alone stopped
    # revealing the panel for every completed recording when the window
    # replaced the snapshot.
    createEffect proc() =
      if store.requestSpans.requests.val.len > 0 or
         store.requestSpans.recordedTotal.val > 0:
        untrack(proc() = scheduleRequestPanelReveal())
  # The poll tails the SHOWN tab's store (`requestPanelVMStore`, moved by
  # every tab switch); a hidden tab's live deltas still reach its own store
  # through its own session's `ct/updated-http-requests` events.
  startRequestSpanPolling()


# The panel host mounts the pane into the container GoldenLayout (or the
# auto-hide strip) creates (`ui/panel_host`), on the session's ViewModel.
setPanelRenderer(Content.RequestPanel,
  proc(r: WebRenderer; host: dom_api.Element;
       session: SessionViewModel): dom_api.Element =
    # `session` is the tab's whose container holds `host`; its own component
    # is replayed into its own ViewModel.
    let shown = data.shownTabComponent(Content.RequestPanel)
    let component =
      if shown.isNil: requestPanelComponentRef
      else: RequestPanelComponent(shown)
    if not component.isNil and
       ownPaneVM(component, requestPanelVMInstance, requestPanelVM) ==
         session.requestPanelVM:
      syncLegacyRequestPanelIntoVM(component)
    renderRequestPanel[WebRenderer, dom_api.Element](
      r, session.requestPanelVM))

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------


method unregister*(self: RequestPanelComponent) =
  ## Release the module-global slot before the base implementation drops the
  ## event-bus subscriptions, so a component handed the same id after a
  ## teardown (GoldenLayout reuses ids, and they restart from 0 after a
  ## layout reset) becomes the module's component. The VM is deliberately NOT
  ## reset: it holds state about the trace, not about this panel.
  if requestPanelComponentRef == self:
    requestPanelComponentRef = nil
  procCall unregister(Component(self))

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
  if requestPanelComponentRef.isNil:
    requestPanelComponentRef = self

method restart*(self: RequestPanelComponent) =
  self.clearRequests()

method clear*(self: RequestPanelComponent) =
  self.clearRequests()
