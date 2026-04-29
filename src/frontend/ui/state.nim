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
  ## with the id `stateComponent-0`. The IsoNim view replaces all Karax
  ## content and becomes the primary renderer.
  ##
  ## After mounting:
  ## - `isoNimStateMounted` is set to true
  ## - `redrawDynamically` / `redrawForSinglePage` become no-ops
  ## - `registerLocals` still feeds data into the store, and IsoNim's
  ##   reactive effects update the DOM automatically
  ##
  ## Safe to call multiple times — mounts only once.
  if isoNimStateMounted or stateVMInstance.isNil:
    return

  # Short delay to ensure the GoldenLayout container has been created
  # and the initial Karax render has populated it.
  discard setTimeout(proc() =
    if isoNimStateMounted:
      return
    let container = dom_api.getElementById(dom_api.document, cstring"stateComponent-0")
    if dom_api.isNodeNil(dom_api.Node(container)):
      clog "IsoNim state panel: #stateComponent-0 element not found"
      return

    # Clear existing Karax-rendered content so the IsoNim view has a
    # clean container. We also remove the Karax renderer from kxiMap
    # so that `redrawAll()` no longer triggers Karax VDOM diffing for
    # this component (which would corrupt the IsoNim-managed DOM).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    # Remove the Karax instance so redrawAll() skips this component.
    # The `del` call is safe even if the key is absent (JS delete on
    # a missing property is a no-op that returns true).
    kxiMap.del(cstring"stateComponent-0")

    isoNimStateMounted = true
    mountIsoNimStatePanel(container, stateVMInstance)
    clog "IsoNim state panel: mounted as primary renderer in #stateComponent-0"
  , 500)

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

proc syncStoreLocals(legacyLocals: seq[Variable]) =
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
  clog fmt"StateVM: synced {vmLocals.len} locals into store"

proc syncStoreDebuggerPosition(rrTicks: int, path: cstring, line: int) =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the StateVM's reactive pipeline sees the same rrTicks value.
  if stateVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  stateVMStore.updateDebuggerPosition(ticks, $path, line)
  clog fmt"StateVM: synced debugger rrTicks={ticks}"

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
  self.redraw()

proc redrawDynamically*(self: StateComponent) =
  # IsoNim is the primary renderer. All DOM updates are handled by
  # IsoNim reactive effects when the store signals change (via
  # syncStoreLocals). No Karax DOM manipulation needed.
  discard

method redrawForSinglePage*(self: StateComponent) =
  # IsoNim is the primary renderer. Data flow:
  # registerLocals -> syncStoreLocals -> store signals ->
  # IsoNim reactive effects automatically update the DOM.
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
  # The legacy self.loadLocals() call has been removed.  Data loading
  # is now driven by the StateVM's auto-load effect which fires when
  # syncStoreDebuggerPosition (called in onCompleteMove) updates the
  # store's rrTicks signal.  The effect calls store.requestLocals()
  # which sends the ct/load-locals command through the real backend.
  # The response still arrives via the CtLoadLocalsResponse event-bus
  # subscription → registerLocals, so rendering is unchanged.
  self.redraw()

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

method render*(self: StateComponent): VNode =
  # IsoNim is the primary renderer. Return a minimal empty container
  # with the correct ID so that GoldenLayout's container exists and
  # the IsoNim tryMountIsoNimStatePanel() can find and populate it.
  # All rendering is handled by the IsoNim reactive view; Karax
  # produces no DOM content for this panel.
  result = buildHtml(
    tdiv(id = cstring(fmt"stateComponent-{self.id}"),
      class = componentContainerClass("active-state") & cstring" " & cstring"state-component"))

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
