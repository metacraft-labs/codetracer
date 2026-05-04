## frontend/ui/no_source.nim
##
## NoSource panel host module.  The IsoNim view at
## ``viewmodel/views/isonim_no_source_view.nim`` is the primary
## renderer; this module exposes the direct DOM host helper plus the
## asm-load + history-jump helpers that feed the IsoNim ``NoSourceVM``.
##
## Lifecycle:
## 1. ``openNoSourceView`` (in ``utils.nim``) creates a
##    ``NoSourceComponent`` and stashes it on its parent
##    ``EditorViewComponent.noInfo`` field.
## 2. The editor direct GoldenLayout mount path calls
##    ``renderNoSourceShellDirect`` with the temporary
##    ``editorComponent-{id}`` placeholder.
## 3. ``renderNoSourceShellDirect`` replaces that placeholder with the
##    stable ``<div id="no-source-{id}" class="unknown-location">``
##    shell and asks ``tryMountIsoNimNoSourcePanel`` to mount the
##    IsoNim ``renderNoSourcePanel`` view inside it.  The mount runs
##    once per component id; subsequent renders are driven by the VM's
##    reactive signals.
## 4. Callers feed live data into the VM via ``syncNoSourceVM``.

import
  ui_imports, strutils,
  ../[ communication, event_helpers ],
  ../../common/ct_event
from ../rr_gdb import RRGDBStopSignal

# ---------------------------------------------------------------------------
# ViewModel layer — IsoNim is the primary renderer for the no-source panel.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  NoSourceLocationInfo, NoSourceHistoryInfo
import ../viewmodel/viewmodels/no_source_vm
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_no_source_view import mountIsoNimNoSource

const
  NO_CODE = -1
  NO_PATH = ""

# Shared ViewModel instance.  Created once via ``initNoSourceVMWithStore``
# from ``ui_js.configureMiddleware`` so the panel uses the real DapApi
# backend.  A stub-backed lazy fallback is also provided so unit tests
# and early-render paths can still construct the panel.
var noSourceVMInstance*: NoSourceVM
var noSourceVMStore: ReplayDataStore
# Track which NoSourceComponent ids have already mounted their IsoNim
# view.  The shell ``<div>`` is keyed by ``self.id`` so each editor
# tab that hosts a no-source view gets its own mount.  The map is
# only meaningful on the JS backend (the shell only mounts in real
# DOM); we still declare it unconditionally so the rest of the file
# stays platform-neutral.
var isoNimNoSourceMountedIds {.used.}: JsAssoc[int, bool] = JsAssoc[int, bool]{}

proc asmLoad(self: EditorService, location: types.Location): Future[Instructions] {.async.} =
  var name = cstring""
  var functionLocation = FunctionLocation(
    path: location.path,
    name: location.functionName,
    key: location.key,
    forceReload: location.path.split(".")[^1] == "nr"  # Force reload on move for noir files
  )
  name = cstring(fmt"{functionLocation.path}:{functionLocation.name}:{functionLocation.key}")

  let instructions = await self.data.asyncSend("asm-load", functionLocation, $name, Instructions)
  return instructions

proc getAsmCode(self: NoSourceComponent, location: types.Location) {.async.} =
  self.instructions = await data.services.editor.asmLoad(location)
  self.data.redraw()

proc historyJump*(self: NoSourceComponent, location: types.Location) =
  self.api.historyJump(location)

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncNoSourceVM*(self: NoSourceComponent) =
  ## Push the legacy component's view of the world into the IsoNim
  ## ``NoSourceVM`` so the IsoNim view re-renders.  Mirrors the data
  ## the legacy Karax ``method render`` consumed: the free-form
  ## message, the current high-level location, the optional jump
  ## history, the originating address, and the optional stop-signal
  ## text.
  ##
  ## Safe to call before the VM exists — early calls are dropped, the
  ## next sync after the VM is created will fill it in.
  if noSourceVMInstance.isNil:
    return

  noSourceVMInstance.setMessage($self.message)

  let metaInfo = data.services.debugger.location
  let location = vmtypes.NoSourceLocationInfo(
    functionName: $metaInfo.highLevelFunctionName,
    path: (if metaInfo.highLevelPath != NO_PATH: $metaInfo.highLevelPath else: ""),
    line: (if metaInfo.highLevelLine != NO_CODE: metaInfo.highLevelLine else: -1),
  )
  noSourceVMInstance.setLocation(location)

  let jumpHistory = self.data.services.debugger.jumpHistory
  if jumpHistory.len >= 2:
    let prev = jumpHistory[^2].location
    let action = jumpHistory[^1].lastOperation
    noSourceVMInstance.setHistory(vmtypes.NoSourceHistoryInfo(
      hasHistory: true,
      previousPath: $prev.path,
      action: $action,
    ))
  else:
    noSourceVMInstance.setHistory(vmtypes.NoSourceHistoryInfo())

  if self.instructions.address != 0:
    noSourceVMInstance.setOriginatingAddress("0x" & toHex(self.instructions.address))
  else:
    noSourceVMInstance.setOriginatingAddress("")

  let signal = self.data.services.debugger.stopSignal
  if signal notin {NoStopSignal, OtherStopSignal}:
    noSourceVMInstance.setStopSignalText($signal)
  else:
    noSourceVMInstance.setStopSignalText("")

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimNoSourcePanel*(self: NoSourceComponent) =
    ## Mount the IsoNim no-source view into the Karax-materialised
    ## ``<div id="no-source-{id}">`` shell.  Idempotent per component
    ## id; subsequent renders are reactive and do not require Karax to
    ## re-run.
    ##
    ## ``method render`` calls this synchronously while Karax is still
    ## computing the VDOM, so the shell ``<div>`` may not yet be in
    ## the live DOM tree.  The proc retries via ``setTimeout`` until
    ## the container appears (mirrors the ``tryMountIsoNimStatePanel``
    ## retry loop in ``state.nim``).
    if noSourceVMInstance.isNil:
      return
    if isoNimNoSourceMountedIds.hasKey(self.id):
      return
    let key = cstring("no-source-" & $self.id)
    let componentId = self.id
    var retryCount = 0

    proc doMount() =
      if isoNimNoSourceMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Tear down anything Karax may have left behind in the container
      # (defensive — the shell render emits no children, but avoid
      # double-mounting the IsoNim subtree if the proc is called
      # twice).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimNoSourceMountedIds[componentId] = true
      mountIsoNimNoSource(container, noSourceVMInstance)
      syncNoSourceVM(self)

    doMount()

  proc renderNoSourceShellDirect*(self: NoSourceComponent;
                                  placeholder: dom_api.Element) =
    ## Materialise the no-source shell without a Karax renderer.
    ##
    ## Preserve the stable ``no-source-{id}`` host, asm-load side effect,
    ## VM sync, and IsoNim mount lifecycle without a Karax VNode shell.
    let history = self.data.services.debugger.jumpHistory
    if history.len >= 1 and self.instructions == Instructions():
      discard self.getAsmCode(history[^1].location)

    syncNoSourceVM(self)

    let shell = dom_api.createElement(dom_api.document, cstring"div")
    dom_api.setAttribute(shell, cstring"id", cstring("no-source-" & $self.id))
    dom_api.setAttribute(shell, cstring"class", cstring"unknown-location")

    let parent = placeholder.parentNode
    if dom_api.isNodeNil(parent):
      return
    discard dom_api.replaceChild(
      parent,
      dom_api.Node(shell),
      dom_api.Node(placeholder))

    self.tryMountIsoNimNoSourcePanel()
# ---------------------------------------------------------------------------
# VM lifecycle hooks called from ui_js.configureMiddleware.
# ---------------------------------------------------------------------------

proc initNoSourceVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or reset) the shared NoSourceVM with the provided
  ## ``ReplayDataStore``.  Called from
  ## ``ui_js.configureMiddleware`` after the SessionVM is created.
  ##
  ## Replacing an existing VM clears the per-id mount table so the
  ## next render call re-mounts the panel against the new VM (mirrors
  ## the calltrace / state pattern after a session swap).
  if noSourceVMInstance != nil:
    # Clear the per-id mount table so the next render re-mounts the
    # panel against the new VM.  ``JsAssoc`` does not provide
    # ``clear``; reassigning to a fresh empty assoc is the idiomatic
    # equivalent.
    isoNimNoSourceMountedIds = JsAssoc[int, bool]{}
  noSourceVMStore = store
  noSourceVMInstance = createNoSourceVM(store)
  clog "NoSourceVM: parallel ViewModel instance created (shared store)"

proc initNoSourceVM*() =
  ## Lazy fallback used when no shared store has been provided yet
  ## (e.g. in the VS Code extension where the SessionViewModel is not
  ## wired before the first render).  Same shape as ``initStateVM``.
  if noSourceVMInstance != nil:
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

  noSourceVMStore = createReplayDataStore(stubBackend)
  noSourceVMInstance = createNoSourceVM(noSourceVMStore)
  clog "NoSourceVM: parallel ViewModel instance created (stub backend)"
