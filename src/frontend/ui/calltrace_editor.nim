## frontend/ui/calltrace_editor.nim
##
## Calltrace Editor panel host module.  The IsoNim view at
## ``viewmodel/views/isonim_calltrace_editor_view.nim`` is the primary
## (and currently only) renderer; this module keeps the legacy Karax
## surface area minimal — registering the component lifecycle, owning
## the parallel ``CalltraceEditorVM``, and mounting the IsoNim view
## inside the GoldenLayout-managed container.
##
## The legacy Karax ``method render`` was dropped (it emitted only an
## empty container ``<div>`` and never invoked the dead per-call
## helpers).  The pair of helpers (``openNewCall`` / ``callView``)
## that historically built nested editor instances inside this panel
## are also removed: a code-base scan confirmed neither was reachable
## from any caller outside this file.  See section 5.4 of the IsoNim
## migration handoff and the section-1.45 entry for the full rationale.
##
## Lifecycle:
## 1. ``frontend/renderer.nim::openCallViewer`` creates a GoldenLayout
##    panel with ``content = Content.CalltraceEditor`` and
##    ``label = "calls"`` (the panel is single-instance — only one
##    Calltrace Editor lives at a time).
## 2. ``frontend/ui/layout.nim`` registers the GL container, then
##    detects ``Content.CalltraceEditor`` is in ``isIsoNimComponent``
##    and calls ``tryMountIsoNimCalltraceEditorPanel`` instead of
##    invoking Karax.
## 3. The mount helper appends the IsoNim panel inside the
##    ``<div id="calls">`` container and flips the VM's ``mounted``
##    signal.

import ui_imports, ../[ types, communication ]

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
import ../viewmodel/viewmodels/calltrace_editor_vm
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_calltrace_editor_view import
    mountIsoNimCalltraceEditor

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots
# ---------------------------------------------------------------------------
#
# The Calltrace Editor panel is single-instance (the GoldenLayout
# label is the literal string ``"calls"`` rather than a per-id slug),
# so a single VM/store/component triple suffices.  We still track a
# per-id mount table to keep the mount idempotent across re-mount
# attempts; today only id = 0 ever appears.
var calltraceEditorVMInstance*: CalltraceEditorVM
var calltraceEditorVMStore: ReplayDataStore
var calltraceEditorComponentRef: CalltraceEditorComponent
var isoNimCalltraceEditorMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

const CALLTRACE_EDITOR_CONTAINER_ID = "calls"
  ## GoldenLayout container id used by ``openCallViewer`` (see
  ## ``frontend/renderer.nim``).  Exposed as a constant so the mount
  ## helper does not silently drift from the renderer.

proc tryMountIsoNimCalltraceEditorPanel*()

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initCalltraceEditorVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``CalltraceEditorVM`` using
  ## an externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance already
  ## exists (created by ``initCalltraceEditorVM`` before the real
  ## backend was available) it is replaced so the panel uses the real
  ## backend.
  if calltraceEditorVMInstance != nil:
    clog "CalltraceEditorVM: replacing existing instance with shared-store version"
    isoNimCalltraceEditorMountedIds = JsAssoc[int, bool]{}
  calltraceEditorVMStore = store
  calltraceEditorVMInstance = createCalltraceEditorVM(store)
  clog "CalltraceEditorVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimCalltraceEditorPanel()

proc initCalltraceEditorVM*() =
  ## Lazy fallback used when no shared store has been provided yet
  ## (e.g. early-render paths or tests that bypass
  ## ``configureMiddleware``).  Same shape as ``initStepListVM`` /
  ## ``initNoSourceVM`` — a stub backend so the panel can still
  ## render before the real session VM is wired.
  if calltraceEditorVMInstance != nil:
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

  calltraceEditorVMStore = createReplayDataStore(stubBackend)
  calltraceEditorVMInstance = createCalltraceEditorVM(calltraceEditorVMStore)
  clog "CalltraceEditorVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimCalltraceEditorPanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimCalltraceEditorPanel*() =
    ## Mount the IsoNim calltrace-editor placeholder into the
    ## GoldenLayout-managed container ``<div id="calls">``.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container appears
    ## (capped at 200 attempts, ~2 s) since GoldenLayout creates the
    ## host slightly after the layout state changes (mirrors
    ## ``tryMountIsoNimStepListPanel``).
    if calltraceEditorVMInstance.isNil:
      return
    if calltraceEditorComponentRef.isNil:
      return
    let componentId = calltraceEditorComponentRef.id
    if isoNimCalltraceEditorMountedIds.hasKey(componentId):
      return

    let key = cstring(CALLTRACE_EDITOR_CONTAINER_ID)
    var retryCount = 0
    proc doMount() =
      if isoNimCalltraceEditorMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimCalltraceEditorPanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimCalltraceEditorMountedIds[componentId] = true
      try:
        mountIsoNimCalltraceEditor(container, calltraceEditorVMInstance)
      except:
        cerror "tryMountIsoNimCalltraceEditorPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

    doMount()
else:
  proc tryMountIsoNimCalltraceEditorPanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initCalltraceEditorVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

method register*(self: CalltraceEditorComponent, api: MediatorWithSubscribers) =
  ## Register the CalltraceEditorComponent with the mediator.  Bring up
  ## the IsoNim CalltraceEditorVM lazily so the mount procedure can
  ## find it; the shared-store version is installed by
  ## ``configureMiddleware`` if the ViewModel layer is enabled.
  self.api = api
  initCalltraceEditorVM()
  if calltraceEditorComponentRef.isNil:
    calltraceEditorComponentRef = self
    tryMountIsoNimCalltraceEditorPanel()
