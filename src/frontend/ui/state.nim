import
  ui_imports,
  show_code,
  value,
  ../communication,
  ../event_helpers,
  ../../common/ct_event

from std / dom import nil # imports dom, without directly its items: you need to use `dom.Node`

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The StateVM receives the same data but does not affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
import ../viewmodel/viewmodels/state_vm
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_state_view import
  mountIsoNimStatePanel

# Module-level StateVM instance. Created once in `register()` and
# fed data whenever the legacy event-bus handlers fire.  Rendering
# still reads from the legacy `self.locals` so behaviour is unchanged.
var stateVMInstance: StateVM
var stateVMStore: ReplayDataStore
var isoNimStateMounted: bool = false

# let MIN_NAME_WIDTH: float = 15 #%
# let MAX_NAME_WIDTH: float = 85 #%
# let TOTAL_VALUE_COMPONENT_WIDTH: float = 95 #%

proc calculateValueWidth(self: StateComponent):float = self.totalValueWidth - self.nameWidth
proc watchView(self: StateComponent): VNode
proc loadLocals*(self: StateComponent)
# proc headerView(self: StateComponent): VNode
proc excerpt(self: StateComponent): VNode

func watchInputId(self: StateComponent): cstring =
  cstring(fmt"watch-{self.id}")

proc submitWatchExpression(self: StateComponent) =
  if self.stableBusy:
    return

  let selector = cstring(fmt"#{self.watchInputId()}")
  let input = jq(selector)

  if input.isNil or input.toJs.length.to(int) == 0:
    return

  let expression = input.toJs.value.to(cstring)

  if ($expression).find("\n") != NO_INDEX:
    self.api.errorMessage(cstring"newlines forbidden in watch expressions: not registered")
    return

  self.watchExpressions.add(expression)

  # Sync the new watch expression to the StateVM so its auto-load
  # effect re-requests locals with the updated watch list.
  if stateVMInstance != nil:
    stateVMInstance.addWatch($expression)
  else:
    # Fallback: if the ViewModel is not yet initialised, use the
    # legacy path directly.
    self.loadLocals()

  input.toJs.value = cstring""


method restart*(self: StateComponent) =
  discard

when defined(ctInExtension):
  var stateComponentForExtension* {.exportc.}: StateComponent = makeStateComponent(data, 0, inExtension = true)

  proc makeStateComponentForExtension*(id: cstring): StateComponent {.exportc.} =
    if stateComponentForExtension.kxi.isNil:
      stateComponentForExtension.kxi = setRenderer(proc: VNode = stateComponentForExtension.render(), id, proc = discard)
    result = stateComponentForExtension

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# Placed before registerLocals / onCompleteMove so they are visible at
# the call sites without forward declarations.
# ---------------------------------------------------------------------------

proc tryMountIsoNimStatePanel() =
  ## Mount the IsoNim state panel view into the GoldenLayout-managed
  ## state component container. The container is created by GoldenLayout
  ## with the id `stateComponent-0`. The IsoNim view is the primary
  ## renderer — no Karax renderer is involved.
  ##
  ## After mounting:
  ## - `isoNimStateMounted` is set to true
  ## - `registerLocals` still feeds data into the store, and IsoNim's
  ##   reactive effects update the DOM automatically
  ##
  ## Safe to call multiple times — mounts only once.
  cerror "[PIPELINE] tryMountIsoNimStatePanel: called, isoNimStateMounted=" & $isoNimStateMounted & " vmIsNil=" & $stateVMInstance.isNil
  if isoNimStateMounted or stateVMInstance.isNil:
    cerror "[PIPELINE] tryMountIsoNimStatePanel: skipping (already mounted or VM nil)"
    return

  # Wait for the DOM container to exist. GoldenLayout creates it when
  # the component is registered. IsoNim mounts directly into it.
  let key = cstring"stateComponent-0"
  var stateRetryCount = 0
  proc doMount() =
    if isoNimStateMounted:
      return
    stateRetryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if stateRetryCount mod 10 == 0:
        cerror "[PIPELINE] tryMountIsoNimStatePanel: retry #" & $stateRetryCount
      if stateRetryCount > 200:
        cerror "[PIPELINE] tryMountIsoNimStatePanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    cerror "[PIPELINE] tryMountIsoNimStatePanel: container found, mounting now"
    isoNimStateMounted = true
    mountIsoNimStatePanel(container, stateVMInstance)
    cerror "[PIPELINE] tryMountIsoNimStatePanel: mount COMPLETE in #stateComponent-0"

  doMount()

proc initStateVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel StateVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel
  ## which is backed by a real DapApi).
  ##
  ## If a stub-backed instance already exists (created by initStateVM
  ## before the real backend was available), it is replaced so that the
  ## panel uses the real DapApi instead of the no-op stub.
  if stateVMInstance != nil:
    clog "StateVM: replacing existing instance with shared-store version"
    isoNimStateMounted = false
  stateVMStore = store
  stateVMInstance = createStateVM(store)
  {.emit: "console.error('[PIPELINE] initStateVMWithStore: storeId=' + `store`.storeId);".}
  clog "StateVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimStatePanel()

proc initStateVM() =
  ## Lazily create the parallel StateVM instance backed by a stub
  ## BackendService.  This fallback is used when no shared store has
  ## been provided via `initStateVMWithStore` (e.g. in the VS Code
  ## extension where the SessionViewModel is not yet wired).
  if stateVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    # Return an immediately-resolved future so the store's loading
    # state transitions correctly but no real I/O happens.
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

  stateVMStore = createReplayDataStore(stubBackend)
  stateVMInstance = createStateVM(stateVMStore)
  clog "StateVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimStatePanel()

proc syncStoreLocals*(legacyLocals: seq[Variable]) =
  ## Mirror the legacy locals into the ViewModel store so the
  ## StateVM's currentVariables memo sees the same data.
  if stateVMStore.isNil:
    return
  var vmLocals = newVariableSeq()
  for v in legacyLocals:
    vmLocals.add(makeVariable(
      name = $v.expression,
      value = (if v.value.isNil: "" else: $v.value.text),
      typeName = (if v.value.isNil: "" else: $v.value.kind),
      hasChildren = (if v.value.isNil: false else: v.value.elements.len > 0),
    ))
  stateVMStore.updateLocals(vmLocals)
  cerror fmt"[PIPELINE] syncStoreLocals: synced {vmLocals.len} locals into store"

proc syncStoreDebuggerPosition*(rrTicks: int, path: cstring, line: int) =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the StateVM's reactive pipeline sees the same rrTicks value.
  if stateVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  stateVMStore.updateDebuggerPosition(ticks, $path, line)
  cerror fmt"[PIPELINE] syncStoreDebuggerPosition(state): synced debugger rrTicks={ticks}"

proc registerLocals*(self: StateComponent, response: CtLoadLocalsResponseBody) {.exportc.} =
  clog fmt"registerLocals"
  self.locals = response.locals

  # Feed the same data into the parallel ViewModel store.
  syncStoreLocals(response.locals)
  for localVariable in response.locals:
    let expression = localVariable.expression

    if self.values.hasKey(expression):
      let value = self.values[expression]

      for chart in value.charts:
        chart.replaceAllValues(expression, localVariable.value.elements)

      # # to not leave history for expressions with older context
      # value.showInline = JsAssoc[cstring, bool]{}
      # value.charts = JsAssoc[cstring, ChartComponent]{}

  self.completeMoveIndex += 1

proc redrawDynamically*(self: StateComponent) =
  # IsoNim is the primary renderer. All DOM updates are handled by
  # IsoNim reactive effects when the store signals change (via
  # syncStoreLocals). No Karax DOM manipulation needed.
  discard

const LOCALS_RR_DEPTH_LIMIT: int = 7

proc loadLocals*(self: StateComponent) =
  let countBudget = 3000
  let minCountLimit = 50
  let arguments = CtLoadLocalsArguments(
    rrTicks: self.rrTicks,
    countBudget: countBudget,
    minCountLimit: minCountLimit,
    depthLimit: LOCALS_RR_DEPTH_LIMIT,
    watchExpressions: self.watchExpressions,
    lang: toLangFromFilename(self.location.path),
  )
  self.api.emit(CtLoadLocals, arguments)

method onMove(self: StateComponent) {.async.} =
  # Data loading is driven by the StateVM's auto-load effect which fires
  # when syncStoreDebuggerPosition (called in onCompleteMove) updates the
  # store's rrTicks signal. IsoNim reactive effects handle all DOM updates.
  discard

method register*(self: StateComponent, api: MediatorWithSubscribers) =
  self.api = api

  # Initialize the parallel ViewModel instance (no-op if already created).
  initStateVM()

  # api.subscribe(DapStopped, proc(kind: CtEventKind, response: DapStoppedEvent, sub: Subscriber) =
    # discard self.onMove())
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtLoadLocalsResponse, proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
    self.registerLocals(response)
  )
  api.emit(InternalLastCompleteMove, EmptyArg())

# think if it's possible to directly exportc in this way the method
proc registerStateComponent*(component: StateComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

# StateComponent.render() removed: IsoNim is the primary renderer.
# The base Component.render() returns a valid empty VNode for any
# generic callers (auto-hide, vnodeToDom bridge). All real rendering
# is handled by tryMountIsoNimStatePanel().

# Show the current active debugger line on top of the search bar in the state component
proc excerpt(self: StateComponent): VNode =
  let path = self.location.path
  let id = cstring(fmt"code-state-line-{self.id}")

  if data.ui.editors.hasKey(path):
    let editor = data.ui.editors[path]
    let codeLine = self.location.line
    let sourceCode = editor.tabInfo.sourceLines[codeLine - 1]

    result = buildHtml(
      tdiv(
        id = id,
        class = "code-state-line"
      )
    ):
      span(): text cstring(fmt"{codeLine} | {sourceCode}")
      showCode(id, path, codeLine-3, codeLine+5, codeLine)
  else:
    result = buildHtml(
      tdiv(
        id = id,
        class = "code-state-line no-code"
      )
    ):
      span(): text ""

# proc headerView(self: StateComponent): VNode =
#   result = buildHtml(
#     tdiv(
#       id = "chevron-container"
#     )
#   ):
#     span(
#       class = cstring(fmt"chevron chevron-width-{(self.nameWidth * 100).floor.int}"),
#       style = style(StyleAttr.left, cstring(fmt"{self.nameWidth}%")),
#       onmousedown = proc(ev:Event, tg:VNode) =
#       self.chevronClicked = true,
#       onmouseup = proc =
#       self.chevronClicked = false
#     )

proc watchView(self: StateComponent): VNode =
  result = buildHtml(
    tdiv(id = "gdb-evaluate")
  ):
    form(
      onsubmit = proc(ev: Event, v: VNode) =
        ev.stopPropagation()
        ev.preventDefault()
        self.submitWatchExpression(),
      onmousemove = proc(ev: Event, tg:VNode) = ev.stopPropagation(),
      onclick = proc(ev: Event, tg:VNode) = ev.stopPropagation()
    ):
      input(
        `type`="text",
        placeholder="Enter a watch expression",
        id = self.watchInputId(),
        class="ct-input-panel ct-fill-available",
        onkeydown = proc(ev: KeyboardEvent, v: VNode) =
          if ev.keyCode == ENTER_KEY_CODE:
            ev.stopPropagation()
            ev.preventDefault()
            self.submitWatchExpression()
      )


method onCompleteMove*(self: StateComponent, response: MoveState) {.async.} =
  self.location = response.location
  for value in self.values:
    value.location = response.location

  # Mirror the debugger position into the parallel ViewModel store.
  syncStoreDebuggerPosition(
    response.location.rrTicks, response.location.path, response.location.line)

  await self.onMove()
