## Trace Log Panel — tabular tracepoint-result inspector.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_trace_log_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``TraceLogComponent`` retains its Component shell so any historical
## non-render legacy callers (event-bus subscriptions, generic
## ``Component.afterInit`` wiring) still resolve; every state mutation
## now mirrors into the parallel ``TraceLogVM`` so the IsoNim view is
## the single source of truth for the panel's DOM.
##
## Lifecycle:
## 1. ``utils.nim::makeTraceLogComponent`` constructs the legacy
##    ``TraceLogComponent`` and registers it under
##    ``Content.TraceLog`` (one instance per panel id).
## 2. ``layout.nim`` registers the GL container, then detects
##    ``Content.TraceLog`` is in ``isIsoNimComponent`` and calls
##    ``tryMountIsoNimTraceLogPanel`` instead of invoking Karax.
## 3. The mount helper appends the IsoNim panel inside the
##    ``traceLogComponent-{id}`` container and the reactive effects
##    keep the DOM in sync with the VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via ``initTraceLogVMWithStore`` so the
##    panel uses the production ``ReplayDataStore``.
## ---------------------------------------------------------------------------

import
  ui_imports, strutils,
  ../[ types, communication ],
  ../../common/ct_event

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import TraceLogEntry
from ../viewmodel/viewmodels/trace_log_vm import
  TraceLogVM, createTraceLogVM, NO_SELECTED_INDEX,
  setEntries, addEntry, clearEntries, selectEntry, jumpToEntry
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_trace_log_view import
    mountIsoNimTraceLogPanel

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by step_list / search_results / no_source / repl /
# low_level_code / request_panel.
# ---------------------------------------------------------------------------

var traceLogVMInstance*: TraceLogVM
var traceLogVMStore: ReplayDataStore
var traceLogComponentRef: TraceLogComponent
# Track which TraceLogComponent ids have already mounted their IsoNim
# view.  The GL container is keyed by ``traceLogComponent-{id}`` so
# each panel instance gets its own mount.
var isoNimTraceLogMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimTraceLogPanel*()

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers.
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper used by request_panel / step_list / repl / low_level_code
  ## — E2E paths can land a null cstring in the legacy record, and a
  ## naive ``$`` would throw inside ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc localsToText(locals: seq[(cstring, Value)]): string =
  ## Mirror of the legacy column-4 renderer in ``trace_log.nim`` (see
  ## the ``data: cstring"locals"`` column definition that was dropped
  ## with ``method render``).  Literal string values render as bare
  ## text (e.g. ``$msg`` arguments to ``log``); error values are
  ## prefixed with ``name=`` and surrounded by an
  ## ``<span class="error-trace">`` marker so CSS can style them; all
  ## other values render as ``name=textRepr(value)``.  The IsoNim
  ## view emits this string verbatim into a ``trace-col-locals``
  ## ``<div>`` — CSS handles the colour rules for ``error-trace``.
  var parts: seq[string] = @[]
  for (rawName, value) in locals:
    let name = safeStr(rawName)
    if value.kind != types.Error:
      if value.isLiteral and value.kind == types.String:
        parts.add(safeStr(value.text))
      else:
        parts.add(name & "=" & value.textRepr)
    else:
      parts.add(name & "=<span class=\"error-trace\">" &
                safeStr(value.msg) & "</span>")
  parts.join(" ")

proc legacyStopToVm(stop: Stop;
                    minRRTicks, maxRRTicks: int): TraceLogEntry =
  ## Map the legacy ``Stop`` ref-object to the platform-neutral
  ## ``TraceLogEntry`` value type the ViewModel layer consumes.
  TraceLogEntry(
    rrTicks: stop.rrTicks,
    minRRTicks: minRRTicks,
    maxRRTicks: maxRRTicks,
    path: safeStr(stop.path),
    line: stop.line,
    functionName: safeStr(stop.functionName),
    localsText: localsToText(stop.locals),
    eventId: stop.event,
    tracepointId: stop.tracepointId,
  )

proc collectLatestSessionEntries(self: TraceLogComponent): seq[TraceLogEntry] =
  ## Walk the latest trace session's results and project each
  ## ``Stop`` into a ``TraceLogEntry``.  Mirrors the inner loops of
  ## the legacy ``refreshTraces`` proc which rebuilt the DataTables
  ## row source on each redraw.  Returns an empty seq if no trace
  ## session has been captured yet (matches the legacy
  ## ``traceSessions.len > 0`` guard).
  result = @[]
  if self.isNil or self.service.isNil:
    return
  if self.service.traceSessions.len == 0:
    return
  let session = self.service.traceSessions[^1]
  let minTicks =
    if not self.data.isNil: self.data.minRRTicks else: 0
  let maxTicks =
    if not self.data.isNil: self.data.maxRRTicks else: 0
  for _, sessionResults in session.results:
    for stop in sessionResults:
      result.add(legacyStopToVm(stop, minTicks, maxTicks))

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyTraceLogIntoVM*(self: TraceLogComponent) =
  ## Bulk-replay the legacy ``traceSessions`` cache into the VM.
  ## Used by the layout when the panel container becomes visible (or
  ## is rebuilt) so the panel reflects every entry already
  ## accumulated by the previous trace session.  Per-entry updates
  ## go through ``addEntry`` directly via the event-bus carrier;
  ## this proc covers the bulk-replace scenario (e.g. opening the
  ## panel after some captures already happened).
  if traceLogVMInstance.isNil or self.isNil:
    return
  traceLogVMInstance.setEntries(collectLatestSessionEntries(self))

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initTraceLogVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``TraceLogVM`` using an
  ## externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance already
  ## exists (created by ``initTraceLogVM`` before the real backend
  ## was available) it is replaced so the panel uses the real backend.
  if traceLogVMInstance != nil:
    clog "TraceLogVM: replacing existing instance with shared-store version"
    isoNimTraceLogMountedIds = JsAssoc[int, bool]{}
  traceLogVMStore = store
  traceLogVMInstance = createTraceLogVM(store)
  clog "TraceLogVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimTraceLogPanel()

proc initTraceLogVM*() =
  ## Lazy fallback used when no shared store has been provided yet.
  ## Same shape as ``initStepListVM`` / ``initReplVM`` /
  ## ``initLowLevelCodeVM`` / ``initRequestPanelVM`` — a stub backend
  ## so the panel can still render before ``configureMiddleware``
  ## runs.
  if traceLogVMInstance != nil:
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

  traceLogVMStore = createReplayDataStore(stubBackend)
  traceLogVMInstance = createTraceLogVM(traceLogVMStore)
  clog "TraceLogVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimTraceLogPanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimTraceLogPanel*() =
    ## Mount the IsoNim Trace Log panel view into the GoldenLayout-
    ## managed container.  The container's id is
    ## ``traceLogComponent-{id}`` — each open Trace Log panel
    ## instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container appears
    ## (capped at 200 attempts, ~2 s) since GoldenLayout creates the
    ## host slightly after the layout state changes (mirrors
    ## ``tryMountIsoNimRequestPanel``).
    if traceLogVMInstance.isNil:
      return
    if traceLogComponentRef.isNil:
      return
    let componentId = traceLogComponentRef.id
    if isoNimTraceLogMountedIds.hasKey(componentId):
      return

    let key = cstring("traceLogComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimTraceLogMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimTraceLogPanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimTraceLogMountedIds[componentId] = true
      try:
        mountIsoNimTraceLogPanel(container, traceLogVMInstance)
      except:
        cerror "tryMountIsoNimTraceLogPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync any rows the legacy component already carries so the
      # freshly-mounted view reflects the latest list.
      if not traceLogComponentRef.isNil:
        syncLegacyTraceLogIntoVM(traceLogComponentRef)

    doMount()
else:
  proc tryMountIsoNimTraceLogPanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initTraceLogVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

method register*(self: TraceLogComponent, api: MediatorWithSubscribers) =
  ## Register the TraceLogComponent with the mediator.  Bring up the
  ## IsoNim TraceLogVM lazily so the mount procedure can find it; the
  ## shared-store version is installed by ``configureMiddleware`` if
  ## the ViewModel layer is enabled.
  self.api = api
  initTraceLogVM()
  if traceLogComponentRef.isNil:
    traceLogComponentRef = self
    tryMountIsoNimTraceLogPanel()

proc registerTraceLogComponent*(component: TraceLogComponent,
                                 api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
