import
  results,
  ui_imports,
  command,
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
  DebugControlsVM, createDebugControlsVM, invokeToolbarStep
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_debug_controls_view import
  mountIsoNimDebugControls
from ../viewmodel/views/isonim_debug_shell_view import
  DebugShellId, commandPaletteHostId, renderDebugChromeInto
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

proc invokeDebugStepAction*(action: cstring): bool =
  ## Route keyboard/menu debug step actions through the same bridge used by the
  ## IsoNim toolbar buttons.  The older ``data.step`` path bypasses this bridge
  ## and can diverge from the button behaviour after the ViewModel migration.
  if not debugControlsVMInstance.isNil:
    debugControlsVMInstance.invokeToolbarStep($action)
    return true
  if not debugApiForBridge.isNil:
    dapStep(debugApiForBridge, action)
    return true
  false

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
  ## The shell is hosted by the direct ``#menu`` renderer. Menu redraws replace
  ## that host, so the cache must also verify that the expected DOM node still
  ## exists before skipping a render.
  let commandPaletteId =
    if not data.ui.commandPalette.isNil: data.ui.commandPalette.id else: -1
  let expectedHost = commandPaletteHostId(commandPaletteId)
  if debugShellMountedCommandPaletteId == commandPaletteId:
    let host = dom_api.getElementById(dom_api.document, cstring expectedHost)
    if not dom_api.isNodeNil(dom_api.Node(host)):
      return

  let container = dom_api.getElementById(
    dom_api.document,
    cstring DebugShellId)
  if dom_api.isNodeNil(dom_api.Node(container)):
    return

  let r = WebRenderer()
  renderDebugChromeInto(r, container, commandPaletteId)
  debugShellMountedCommandPaletteId = commandPaletteId
  if not data.ui.commandPalette.isNil:
    data.ui.commandPalette.requestCommandPalettePanelRefresh()

proc requestDebugControlsRender*(self: DebugComponent) =
  if self.isNil:
    return
  let container = dom_api.getElementById(
    dom_api.document,
    cstring"isonim-debug-controls")
  if dom_api.isNodeNil(dom_api.Node(container)):
    return
  if isoNimDebugMounted and not dom_api.isNodeNil(dom_api.Node(container).firstChild):
    return
  isoNimDebugMounted = false
  tryMountIsoNimDebugControls()

proc requestDebugActionRefresh(self: DebugComponent) =
  ## Refresh the Debug-owned direct IsoNim surfaces after local action state
  ## changes. The run-tests loading flag no longer belongs to a broad app
  ## redraw path, but keeping this request local preserves the mounted Debug
  ## shell/control contract if the action fires before either host exists.
  self.requestDebugShellRender()
  self.requestDebugControlsRender()

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

proc syncDebugControlsPosition(rrTicks: int, path: cstring, line: int;
                               sourceGeneration: int = 0;
                               sourceDigest: cstring = cstring"") =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the DebugControlsVM's reactive memos see the updated state.
  if debugControlsVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  debugControlsVMStore.updateDebuggerPosition(
    ticks, $path, line,
    sourceGeneration = sourceGeneration,
    sourceDigest = $sourceDigest)
  clog fmt"DebugControlsVM: synced debugger rrTicks={ticks}"

proc rewireDebugControlsBridgeForActiveSession*(data: Data) =
  ## Re-bind singleton debug chrome callbacks after session switching.
  ##
  ## The caption toolbar is mounted once outside each GoldenLayout tree, while
  ## the DebugComponent/Mediator pair is owned by the active ReplaySession.
  ## After switching away to a welcome tab and back, clicks and shortcuts must
  ## emit through the restored session's mediator.
  if data.isNil or data.ui.isNil:
    return
  if not data.ui.componentMapping[Content.Debug].hasKey(0):
    return

  let component = DebugComponent(data.ui.componentMapping[Content.Debug][0])
  if component.isNil or component.api.isNil:
    return

  initDebugControlsVM()
  debugComponentForBridge = component
  debugApiForBridge = component.api
  if not debugControlsVMInstance.isNil:
    debugControlsVMInstance.onDapStep = proc(action: cstring) =
      dapStep(component.api, action)
    debugControlsVMInstance.onAction = proc(id: string) =
      component.action(id)

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

when defined(js):
  ## Mirror DAP step actions into the Playwright-visible request log
  ## installed by ``ui_js.nim``'s ``recordVmBackendRequest`` so that
  ## M4 keyboard-focus specs can observe F10 / step shortcuts that
  ## ride the DAP bridge instead of the RealBackendService channel.
  ## Without this mirror the production code still fires the step
  ## correctly, but the test sees an empty log.
  proc recordDapStep(action: cstring) {.importjs: """
    (function(action) {
      if (typeof window === "undefined") return;
      window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};
      var arr = window.__CODETRACER_TEST__.vmBackendRequests || [];
      arr.push({ command: String(action || ""), args: {}, source: "dapStep" });
      window.__CODETRACER_TEST__.vmBackendRequests = arr;
    })(#);
  """.}

proc dapStep*(api: MediatorWithSubscribers, action: cstring) =
  ## Issue a DAP step (`next`, `stepIn`, `stepOut`, `continue` and their
  ## reverse counterparts) through the mediator API.
  ##
  ## Serialization (FU-E): rapid successive step requests — e.g. the user
  ## clicking step-over multiple times in quick succession or holding the
  ## F10 key — used to race past one another:
  ##   1. The first request was sent to the replay backend.
  ##   2. Before its `stopped` / `CtCompleteMove` notification arrived,
  ##      a second `next` was fired on top of it.
  ##   3. The UI's `data.services.debugger.location` / status counters
  ##      could land on a stale value, and occasionally two requests
  ##      crossed paths so that one was silently dropped by the backend.
  ##
  ## The middleware sets `data.status.stableBusy = true` for every step
  ## (via the `InternalNewOperation(stableBusy: true)` emit below) and
  ## resets it to `false` only after the next `CtCompleteMove` arrives
  ## (see `middleware.nim` — the `CtCompleteMove` handler). We treat
  ## that flag as the in-flight guard for the DAP step pipeline: a
  ## fresh step is accepted only when no prior step is still pending.
  ##
  ## We deliberately skip the guard during Playwright/headless tests
  ## that bypass the real status pipeline (e.g. when `data` is nil) so
  ## the existing scripted step sequences keep working unchanged.
  when defined(js):
    if not data.isNil and not data.status.isNil and data.status.stableBusy:
      clog "dapStep: prior step in flight, dropping rapid duplicate " &
        $action
      return
  echo "dap step ", action
  when defined(js):
    if not data.isNil and data.startOptions.inTest:
      recordDapStep(action)
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
    response.location.line,
    response.location.sourceGeneration,
    response.location.sourceDigest)

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
