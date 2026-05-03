## REPL panel — interactive prompt over the live debugger session.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_repl_view.nim``) that mounts directly
## into the GoldenLayout container.  The legacy ``ReplComponent``
## retains its event-bus subscriptions so the existing wiring
## (``onDebugOutput`` dispatched from
## ``services/debugger_service.nim::onDebugOutput`` via the
## ``debug-output`` IPC handler) keeps feeding data; the component now
## mirrors every update into a parallel ``ReplVM`` whose signals drive
## the IsoNim view.
##
## Lifecycle:
## 1. ``utils.nim::makeReplComponent`` constructs the legacy
##    ``ReplComponent`` and registers it under ``Content.Repl`` (one
##    instance per panel id — typically id = 0 since the layout opens
##    a single REPL pane).
## 2. ``layout.nim`` registers the GL container, then detects
##    ``Content.Repl`` is in ``isIsoNimComponent`` and calls
##    ``tryMountIsoNimReplPanel`` instead of invoking Karax.
## 3. The mount helper appends the IsoNim panel inside the
##    ``replComponent-{id}`` container and the reactive effects keep
##    the DOM in sync with the VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via ``initReplVMWithStore`` so the panel
##    uses the production ``ReplayDataStore``.
## ---------------------------------------------------------------------------

import
  std/[strutils, json],
  ui_imports, value, ../[types, communication]

from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import isonim/core/signals
import ../viewmodel/store/replay_data_store
import ../viewmodel/viewmodels/repl_vm
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_repl_view import mountIsoNimRepl

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by step_list / search_results / no_source.
# ---------------------------------------------------------------------------

var replVMInstance*: ReplVM
var replVMStore: ReplayDataStore
var replComponentRef: ReplComponent
# Track which ReplComponent ids have already mounted their IsoNim
# view.  The GL container is keyed by ``replComponent-{id}`` so each
# panel instance gets its own mount.
var isoNimReplMountedIds {.used.}: JsAssoc[int, bool] = JsAssoc[int, bool]{}

proc tryMountIsoNimReplPanel*()

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers.
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper used by step_list — E2E paths can land a null cstring in
  ## the legacy record, and naive ``$`` would throw inside
  ## ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc debugOutputKindToVm(kind: DebugOutputKind): ReplOutputKind =
  ## Map the legacy ``DebugOutputKind`` (in ``common_types/graveyard``)
  ## to the platform-neutral ``ReplOutputKind`` used by the VM.
  case kind
  of DebugLoading: rokLoading
  of DebugResult: rokResult
  of DebugMove: rokMove
  of DebugError: rokError

proc debugOutputToVm(o: DebugOutput): ReplOutput =
  ReplOutput(
    kind: debugOutputKindToVm(o.kind),
    output: safeStr(cast[cstring](o.output)))

proc debugInteractionToVm(i: DebugInteraction): ReplInteraction =
  ReplInteraction(
    input: safeStr(cast[cstring](i.input)),
    output: debugOutputToVm(i.output))

proc historyToVm(history: seq[DebugInteraction]): seq[ReplInteraction] =
  result = newSeqOfCap[ReplInteraction](history.len)
  for entry in history:
    result.add(debugInteractionToVm(entry))

# ---------------------------------------------------------------------------
# Legacy event-bus handlers — kept so the existing IPC + mediator wiring
# keeps flowing.  Each handler also feeds the IsoNim VM so the panel
# stays in sync.
# ---------------------------------------------------------------------------

method onDebugOutput*(self: ReplComponent, response: DebugOutput) {.async.} =
  ## Dispatched by the ``debug-output`` IPC subscription whenever the
  ## live debugger streams a response back.  Updates the legacy cache
  ## (still consulted by other Karax-driven fallback paths) AND the
  ## parallel ``ReplVM`` so the IsoNim view re-renders.
  if self.history.len > 0:
    self.history[^1].output = response
    self.data.redraw()
  if not replVMInstance.isNil:
    replVMInstance.onDebugOutput(debugOutputToVm(response))

method run*(self: ReplComponent, input: cstring) {.async.} =
  ## Submit a user-entered REPL expression.  Mirrors the legacy
  ## ``run`` method semantics: append a pending interaction to the
  ## legacy cache, mirror it into the VM, and dispatch the
  ## ``debugRepl`` IPC call.  The ``stableBusy`` gate stays here so
  ## any callers that hit ``run`` directly preserve the legacy
  ## guard; the VM dispatcher path also goes through ``debugRepl``
  ## which has the same gate at the service layer.
  if not self.service.stableBusy:
    self.history.add(
      DebugInteraction(
        input: input,
        output: DebugOutput(kind: DebugLoading, output: cstring"")
      )
    )
    debugRepl(self.history[^1].input)
    if not replVMInstance.isNil:
      # Append directly so we do not double-dispatch ``debugRepl``
      # (the VM action would call it again via the dispatcher).
      var entries = replVMInstance.history.val
      entries.add(ReplInteraction(
        input: safeStr(input),
        output: ReplOutput(kind: rokLoading, output: ""),
      ))
      replVMInstance.history.val = entries

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyReplIntoVM*(self: ReplComponent) =
  ## Bulk-replay the legacy ``self.history`` cache into the VM.
  ## Used by the layout when the panel container becomes visible (or
  ## is rebuilt) so the panel reflects every interaction already
  ## accumulated by the previous IPC stream.
  if replVMInstance.isNil or self.isNil:
    return
  replVMInstance.setHistory(historyToVm(self.history))

proc syncReplConfigIntoVM*() =
  ## Refresh the materialized / replEnabled / langName signals from
  ## the live ``data`` global.  Called whenever the panel is mounted
  ## so the view picks up the latest config without waiting for an
  ## interaction.  Defensive: ``data`` may be partially initialised
  ## during early renderer bring-up, so each access is guarded.
  if replVMInstance.isNil:
    return
  when defined(js):
    if data.isNil:
      return
    var langUsesMaterialized = false
    var langDisplayName = ""
    if not data.trace.isNil:
      langUsesMaterialized = data.trace.lang.usesMaterializedTraces()
      langDisplayName = data.trace.lang.toName()
    replVMInstance.setMaterialized(langUsesMaterialized)
    replVMInstance.setLangName(langDisplayName)
    replVMInstance.setReplEnabled(data.config.repl)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc replDispatcher(): ReplDispatcher =
  ## Production dispatcher: forwards the user-entered expression to
  ## the IPC layer via ``debugRepl``.  ``debugRepl`` has its own
  ## ``stableBusy`` gate at the service layer so the VM path is safe
  ## to call even while a request is in flight.
  result = proc(input: string) =
    debugRepl(cstring(input))

proc initReplVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``ReplVM`` using an
  ## externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance already
  ## exists (created by ``initReplVM`` before the real backend was
  ## available) it is replaced so the panel uses the real backend.
  if replVMInstance != nil:
    clog "ReplVM: replacing existing instance with shared-store version"
    isoNimReplMountedIds = JsAssoc[int, bool]{}
  replVMStore = store
  replVMInstance = createReplVM(store, replDispatcher())
  clog "ReplVM: parallel ViewModel instance created (shared store)"
  syncReplConfigIntoVM()
  tryMountIsoNimReplPanel()

proc initReplVM*() =
  ## Lazy fallback used when no shared store has been provided yet
  ## (e.g. early-render paths or tests that bypass
  ## ``configureMiddleware``).  Same shape as ``initStepListVM`` /
  ## ``initNoSourceVM`` — a stub backend so the panel can still
  ## render before the real session VM is wired.
  if replVMInstance != nil:
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

  replVMStore = createReplayDataStore(stubBackend)
  replVMInstance = createReplVM(replVMStore, replDispatcher())
  clog "ReplVM: parallel ViewModel instance created (stub backend)"
  syncReplConfigIntoVM()
  tryMountIsoNimReplPanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimReplPanel*() =
    ## Mount the IsoNim REPL view into the GoldenLayout-managed
    ## container.  The container's id is ``replComponent-{id}`` —
    ## each open REPL panel instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container appears
    ## (capped at 200 attempts, ~2 s) since GoldenLayout creates the
    ## host slightly after the layout state changes (mirrors
    ## ``tryMountIsoNimStepListPanel``).
    if replVMInstance.isNil:
      return
    if replComponentRef.isNil:
      return
    let componentId = replComponentRef.id
    if isoNimReplMountedIds.hasKey(componentId):
      return

    let key = cstring("replComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimReplMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimReplPanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimReplMountedIds[componentId] = true
      try:
        mountIsoNimRepl(container, replVMInstance)
      except:
        cerror "tryMountIsoNimReplPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync config + history so the freshly-mounted view reflects
      # the latest state.
      syncReplConfigIntoVM()
      if not replComponentRef.isNil:
        syncLegacyReplIntoVM(replComponentRef)

    doMount()
else:
  proc tryMountIsoNimReplPanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initReplVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

method register*(self: ReplComponent, api: MediatorWithSubscribers) =
  ## Register the ReplComponent with the mediator.  Bring up the
  ## IsoNim ReplVM lazily so the mount procedure can find it; the
  ## shared-store version is installed by ``configureMiddleware`` if
  ## the ViewModel layer is enabled.
  self.api = api
  initReplVM()
  if replComponentRef.isNil:
    replComponentRef = self
    tryMountIsoNimReplPanel()
