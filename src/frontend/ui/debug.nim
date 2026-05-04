import
  results,
  ui_imports,
  ../[ renderer, communication, event_helpers ],
  ../../common/ct_event

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The DebugControlsVM reads debugger state from the store but does not
# affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/viewmodels/debug_controls_vm import
  DebugControlsVM, createDebugControlsVM
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_debug_controls_view import
  mountIsoNimDebugControls
from ../viewmodel/views/isonim_debug_shell_view import
  DebugShellId, renderDebugChromeInto
from isonim/web/web_renderer import WebRenderer

# Module-level DebugControlsVM instance. Created once and fed data whenever
# the legacy event-bus handlers fire. Rendering still reads from legacy data
# so behaviour is unchanged.
var debugControlsVMInstance: DebugControlsVM
var debugControlsVMStore: ReplayDataStore
var isoNimDebugMounted: bool = false
var debugShellMountedCommandPaletteId: int = -2

# Reference to the live `DebugComponent` (and its mediator API) that
# was wired with `register()`. Captured by `register()` and consulted
# by every code path that creates a fresh `DebugControlsVM` so the new
# instance gets the `onDapStep` / `onAction` bridge re-applied.
#
# Without this, replacing the stub-backed VM with the shared-store VM
# in `initDebugControlsVMWithStore` leaves the new instance's bridge
# callbacks nil — the IsoNim toolbar's click handlers then call
# `vm.onDapStep` (which is nil) and silently drop the step request.
# That is the root cause of TODO 5.2(i): wasm DB-trace `next` clicks
# never reach the backend.
var debugComponentForBridge: DebugComponent
var debugApiForBridge: MediatorWithSubscribers

# Forward declarations: `initDebugControlsVMWithStore` (defined below)
# needs to call `dapStep` and `action` (both also below) when
# re-applying the bridge after replacing the VM instance.
proc dapStep*(api: MediatorWithSubscribers, action: cstring)
proc action(self: DebugComponent, id: string)

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# ---------------------------------------------------------------------------

proc tryMountIsoNimDebugControls() =
  ## Mount the IsoNim debug controls view into the dedicated
  ## `#isonim-debug-controls` container div (defined in index.html).
  ##
  ## This div lives outside Karax's VDOM tree, so direct DOM manipulation
  ## is safe and won't be overwritten by Karax redraw cycles.
  ## Safe to call multiple times — mounts only once.
  cerror "tryMountIsoNimDebugControls: called, isoNimDebugMounted=" & $isoNimDebugMounted & " vmIsNil=" & $debugControlsVMInstance.isNil
  if isoNimDebugMounted or debugControlsVMInstance.isNil:
    cerror "tryMountIsoNimDebugControls: skipping (already mounted or VM nil)"
    return

  # Try to mount synchronously. If the container doesn't exist yet,
  # retry on the next event loop tick instead of using a fixed delay.
  # Gives up after 100 retries to avoid infinite spinning.
  var debugRetryCount = 0
  proc doMount() =
    if isoNimDebugMounted:
      return
    debugRetryCount += 1
    let container = dom_api.getElementById(dom_api.document, cstring"isonim-debug-controls")
    if dom_api.isNodeNil(dom_api.Node(container)):
      if debugRetryCount > 100:
        cerror "tryMountIsoNimDebugControls: container not found after 100 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 0)
      return
    # Clear any existing children from a previous mount cycle (e.g. when
    # initDebugControlsVMWithStore replaces the stub VM with the real one).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    cerror "tryMountIsoNimDebugControls: container found, mounting now"
    isoNimDebugMounted = true
    mountIsoNimDebugControls(container, debugControlsVMInstance)
    cerror "tryMountIsoNimDebugControls: mount COMPLETE"
    # The legacy Karax `#debug` div is hidden on next Karax redraw
    # cycle — see the `isoNimDebugMounted` check at the top of
    # `DebugComponent.render`.

  doMount()

proc requestDebugShellRender*(self: DebugComponent) =
  ## Ensure the direct IsoNim debug shell exists.
  ##
  ## The shell itself lives outside the direct ``#menu`` renderer. It is
  ## mounted once into the static ``#debug`` host from ``index.html`` so menu
  ## redraws cannot erase the command palette's IsoNim mount point.
  let commandPaletteId =
    if not data.ui.commandPalette.isNil: data.ui.commandPalette.id else: -1
  if debugShellMountedCommandPaletteId == commandPaletteId:
    return

  let container = dom_api.getElementById(
    dom_api.document,
    cstring DebugShellId)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return

  let r = WebRenderer()
  renderDebugChromeInto(r, container, commandPaletteId)
  debugShellMountedCommandPaletteId = commandPaletteId

proc requestDebugActionRefresh(self: DebugComponent) =
  ## Refresh the Debug-owned direct IsoNim surfaces after local action state
  ## changes. The run-tests loading flag no longer belongs to a broad app
  ## redraw path, but keeping this request local preserves the mounted Debug
  ## shell/control contract if the action fires before either host exists.
  self.requestDebugShellRender()
  tryMountIsoNimDebugControls()

proc initDebugControlsVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel DebugControlsVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel).
  ##
  ## If a stub-backed instance already exists (created by initDebugControlsVM
  ## before the real backend was available), it is replaced so that the
  ## panel uses the real DapApi instead of the no-op stub.
  ##
  ## After the replacement, re-apply the `onDapStep` / `onAction` bridge
  ## callbacks if `register()` has already wired the `DebugComponent` to
  ## the middleware API. Without this, IsoNim toolbar clicks call a nil
  ## `onDapStep` on the new instance and the DAP step request is silently
  ## dropped — TODO 5.2(i).
  if debugControlsVMInstance != nil:
    clog "DebugControlsVM: replacing existing instance with shared-store version"
    isoNimDebugMounted = false
  debugControlsVMStore = store
  debugControlsVMInstance = createDebugControlsVM(store)
  clog "DebugControlsVM: parallel ViewModel instance created (shared store)"
  if not debugComponentForBridge.isNil and not debugApiForBridge.isNil:
    let component = debugComponentForBridge
    let api = debugApiForBridge
    debugControlsVMInstance.onDapStep = proc(action: cstring) =
      dapStep(api, action)
    debugControlsVMInstance.onAction = proc(id: string) =
      component.action(id)
    clog "DebugControlsVM: re-wired onDapStep/onAction bridge after replacement"
  tryMountIsoNimDebugControls()

proc initDebugControlsVM() =
  ## Lazily create the parallel DebugControlsVM backed by a stub
  ## BackendService.  Fallback when no shared store has been provided
  ## via `initDebugControlsVMWithStore`.
  if debugControlsVMInstance != nil:
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

  debugControlsVMStore = createReplayDataStore(stubBackend)
  debugControlsVMInstance = createDebugControlsVM(debugControlsVMStore)
  clog "DebugControlsVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimDebugControls()

proc syncDebugControlsPosition(rrTicks: int, path: cstring, line: int) =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the DebugControlsVM's reactive memos see the updated state.
  if debugControlsVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  debugControlsVMStore.updateDebuggerPosition(ticks, $path, line)
  clog fmt"DebugControlsVM: synced debugger rrTicks={ticks}"

proc jumpBeforeList*(self: DebugComponent) =
  self.after = false
  self.before = true
  self.data.redraw()

proc jumpAfterList*(self: DebugComponent) =
  self.before = false
  self.after = true
  self.data.redraw()

proc stopJump*(self: DebugComponent) =
  self.before = false
  self.after = false
  self.data.redraw()

proc resetOperation*(self: DebugComponent) =
  clog "reset-operation: for now restarting replay-server"
  self.data.restartSubsystem(name="replay-server")
  if self.jumpHistory.len != 0:
    self.jumpHistory[^1].lastOperation = cstring"reset-operation"

  # previously called like that, outdated now:
  #   this is specifically for the "full reset operation":
  #   self.service.resetOperation(full=true, resetLastLocation=true, taskId=taskId)

proc runToEntry*(self: DebugComponent) =
  self.api.emit(CtRunToEntry, EmptyArg())
  self.api.emit(InternalNewOperation, NewOperation(name: "run to entry", stableBusy: true))

proc historyJump(self: DebugComponent, location: types.Location) =
  self.api.historyJump(location)

proc handleHistoryJump*(self: DebugComponent, isForward: bool) =
  if isForward:
    if self.jumpHistory.len != 0 and self.jumpHistory.len - self.historyIndex > 0:
      self.historyIndex += 1
      let location = self.jumpHistory[^self.historyIndex].location

      self.historyJump(location)
  else:
    if self.jumpHistory.len != 0 and self.historyIndex >= 2:
      self.historyIndex -= 1
      let location = self.jumpHistory[^self.historyIndex].location

      self.historyJump(location)

proc action(self: DebugComponent, id: string) =
  case id:
  of "reset-operation": self.resetOperation()

  # TODO: a special case: or remove, as currently we
  #   directly restart replay-server anyway?
  #   or make several options for
  #     * ) again, restoring a more gradual/internal for replay-server restart
  #     * ) replay-server restart
  #     * ) session-manager (+ replay-server) restart
  # ?
  of "full-reset-operation": self.resetOperation()

  of "stop": stopAction()

  of "jump-before": self.jumpBeforeList()

  of "jump-after": self.jumpAfterList()

  of "run-to-entry": self.runToEntry()

  of "run-tests":
    # copied from alt+l shorcut handling in shortcuts.nim
    let options = RunTestOptions(newWindow: true, path: data.services.debugger.location.path, testName: "")
    self.isLoading = true
    data.runTests(options)
    # TODO: For now hardcode the animation reset
    discard setTimeout(proc() =
      self.isLoading = false
      self.requestDebugActionRefresh(),
      10000
    )

  of "history-back":
    self.handleHistoryJump(isForward = true)

  of "history-forward":
    self.handleHistoryJump(isForward = false)

  else:
    discard

func toDapStepActionEnum(action: cstring): Result[CtEventKind, cstring] =
  case $action:
  of "step-in": result.ok(DapStepIn)
  of "step-out": result.ok(DapStepOut)
  of "next": result.ok(DapNext)
  of "continue": result.ok(DapContinue)
  of "reverse-step-in": result.ok(CtReverseStepIn)
  of "reverse-step-out": result.ok(CtReverseStepOut)
  of "reverse-next": result.ok(DapStepBack)
  of "reverse-continue": result.ok(DapReverseContinue)
  else: result.err(cstring(fmt"not added dap equivalent for {action} for now"))

proc dapStep*(api: MediatorWithSubscribers, action: cstring) =
  echo "dap step ", action
  let dapActionRes = toDapStepActionEnum(action)
  if dapActionRes.isOk:
    let dapAction = dapActionRes.value
    # for now hardcoded threadId, eventually base on location/other
    if not api.isNil:
      api.emit(dapAction, DapStepArguments(threadId: 1))
      api.emit(InternalNewOperation, NewOperation(name: action, stableBusy: true))
  else:
    cerror cstring(fmt"dap step to action enum error: {dapActionRes.error}")

proc resetJumpHistoryFromStartIndex(self: DebugComponent) =
  let startIndex = self.jumpHistory.len - self.historyIndex + 1

  if self.jumpHistory.len > startIndex:
    self.jumpHistory.delete(startIndex ..< self.jumpHistory.len)
  self.historyIndex = 1

method resetBeforeRestart*(self: DebugComponent) =
  self.jumpHistory = @[]
  self.currentOperation = nil
  # not sure why 1, but resetJumpHistoryFromStartIndex does it
  # and that's what the onCompleteMove checks for
  self.historyIndex = 1

method onCompleteMove*(self: DebugComponent, response: MoveState) {.async.} =
  # Feed the same position into the parallel ViewModel store.
  initDebugControlsVM()
  syncDebugControlsPosition(
    response.location.rrTicks,
    response.location.path,
    response.location.line)

  echo "onCompleteMove for debug "
  console.log(response.location)
  if self.jumpHistory.len() > 0:
    console.log(self.jumpHistory[^1].location)
  if self.jumpHistory == @[] or response.location != self.jumpHistory[^1].location:
    if self.currentOperation != HISTORY_JUMP_VALUE:
      echo "in if"
      if self.historyIndex != 1:
        self.resetJumpHistoryFromStartIndex()
      let action = if self.currentOperation.isNil:
          cstring""
        else:
          self.currentOperation
      echo "action ", action
      self.jumpHistory.add(
        JumpHistory(
          location: response.location,
          lastOperation: action
        )
      )
      console.log cstring"after add", self.jumpHistory

method register*(self: DebugComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )

  # Wire up the legacy bridge callbacks on the DebugControlsVM so that
  # IsoNim view button clicks route through the existing DAP event mediator.
  # We also memoise `self` and `api` so that any later
  # `initDebugControlsVMWithStore` call (which replaces the VM instance
  # with a shared-store one) can re-apply the bridge — see the
  # `debugComponentForBridge` / `debugApiForBridge` doc above for the
  # TODO 5.2(i) failure mode this fixes.
  initDebugControlsVM()
  debugComponentForBridge = self
  debugApiForBridge = api
  if not debugControlsVMInstance.isNil:
    debugControlsVMInstance.onDapStep = proc(action: cstring) =
      dapStep(api, action)
    debugControlsVMInstance.onAction = proc(id: string) =
      self.action(id)
