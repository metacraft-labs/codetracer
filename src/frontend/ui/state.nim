import
  ui_imports,
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
proc loadLocals*(self: StateComponent)

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

  # Sync the new watch expression to the StateVM and use the legacy
  # load path so language-specific locals requests keep the right shape.
  if stateVMInstance != nil:
    stateVMInstance.addWatch($expression)
  self.loadLocals()

  input.toJs.value = cstring""


method restart*(self: StateComponent) =
  discard

when defined(ctInExtension):
  var stateComponentForExtension* {.exportc.}: StateComponent = makeStateComponent(data, 0, inExtension = true)

  proc bindStateExtensionHost(component: StateComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    # The extension state surface has no panel markup of its own; keep the
    # exported component usable without retaining an empty Karax renderer.
    host.innerHTML = cstring""

  proc makeStateComponentForExtension*(id: cstring): StateComponent {.exportc.} =
    if stateComponentForExtension.extensionRendererId.len == 0:
      stateComponentForExtension.extensionRendererId = id
      stateComponentForExtension.bindStateExtensionHost()
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

proc valueDisplayText(v: Value): string =
  ## Rendered text representation matching what the legacy value row emitted
  ## for atom values.
  ##
  ## Atomic kinds are stringified via ``$v`` (which dispatches into
  ## ``common_types/utils/text_representation.text(value, depth)`` —
  ## that pulls `value.i` for ``Int``, `value.f` for ``Float``,
  ## ``"\"<text>\""`` for ``String``, etc.).  The legacy code relied on
  ## the same proc, so the IsoNim view shows the exact same text the
  ## Karax code did, including for languages whose recorder fills
  ## ``value.i`` (wasm `i32`) but leaves ``value.text`` empty.
  ##
  ## Compound kinds (Seq, Instance, etc.) come back here as the
  ## composite text representation produced by ``$v``; the row's
  ## "expanded" rendering still happens via the ``hasChildren`` flag
  ## populated below.
  if v.isNil:
    return ""
  $v

proc valueDisplayType(v: Value): string =
  ## Original-language type name (``i32``, ``int``, ``string`` …)
  ## matching the legacy ``span.value-type`` text. The legacy value
  ## renderer used ``value.typ.langType`` directly for atom rows;
  ## fall back to the ``TypeKind`` enum string when the type metadata
  ## is missing so something useful still shows up in the view.
  if v.isNil:
    return ""
  if not v.typ.isNil and v.typ.langType.len > 0:
    return $v.typ.langType
  $v.kind

proc syncStoreLocals*(legacyLocals: seq[Variable]) =
  ## Mirror the legacy locals into the ViewModel store so the
  ## StateVM's currentVariables memo sees the same data.
  ##
  ## Both RR and Materialized (DB) traces flow through this path;
  ## the only difference is *which* values arrive, not how the sync
  ## happens. Earlier versions of this proc read ``v.value.text`` as
  ## the rendered text — that field is only populated for Strings, so
  ## DB traces (whose primitives expose ``value.i`` / ``value.f`` /
  ## ``value.b``) reached the IsoNim view as empty rows.  The
  ## ``valueDisplayText`` helper now mirrors the legacy atom-value
  ## ``$value`` call which dispatches into the
  ## proper field per ``TypeKind``.
  if stateVMStore.isNil:
    return
  var vmLocals = newVariableSeq()
  for v in legacyLocals:
    vmLocals.add(makeVariable(
      name = $v.expression,
      value = valueDisplayText(v.value),
      typeName = valueDisplayType(v.value),
      hasChildren = (if v.value.isNil: false else: v.value.elements.len > 0),
    ))
  stateVMStore.updateLocals(vmLocals)
  cerror fmt"[PIPELINE] syncStoreLocals: synced {vmLocals.len} locals into store"

proc lookupSourceLine(path: cstring; line: int): string =
  ## Look up the source code at `<path>:<line>` from the editor cache.
  ## Mirrors the legacy ``StateComponent.excerpt`` lookup which read
  ## ``data.ui.editors[path].tabInfo.sourceLines[line - 1]``. Returns
  ## an empty string when:
  ##   * the editor for this file has not been opened / its source
  ##     lines have not yet been populated, or
  ##   * the requested line is outside the source-lines bounds (1-based
  ##     line numbers, so ``line < 1`` or ``line > sourceLines.len``).
  ## In either case the caller (``syncStoreCodeStateLine``) routes the
  ## empty string into the IsoNim view's ``no-code`` fallback so the
  ## ``#code-state-line-{id}`` element is still emitted.
  if line < 1:
    return ""
  if not data.ui.editors.hasKey(path):
    return ""
  let editor = data.ui.editors[path]
  if editor.isNil or editor.tabInfo.isNil:
    return ""
  let lines = editor.tabInfo.sourceLines
  if line > lines.len:
    return ""
  $lines[line - 1]

proc syncStoreCodeStateLine*(path: cstring; line: int) =
  ## Mirror the active source line into the ViewModel store so the
  ## IsoNim state view can render the ``#code-state-line-{id}``
  ## element. The lookup uses the in-memory editor cache populated as
  ## the user opens files; that cache is shared with the legacy
  ## ``StateComponent.excerpt`` proc.  Pushed unconditionally on every
  ## move event — DB-trace traces (where rrTicks is always 0) need
  ## this signal to flip from "no source" to "populated" when the
  ## editor finishes loading, just like RR traces.
  ##
  ## When the editor for ``path`` has not yet loaded its source lines
  ## (a typical race on the very first CtCompleteMove of a session),
  ## we schedule short retries so the populated text shows up as soon
  ## as the source arrives.  The retries stop once source is found or
  ## after a small budget — the caller will hit this proc again on
  ## the next move event.
  if stateVMStore.isNil:
    return
  let initial = lookupSourceLine(path, line)
  stateVMStore.updateCodeStateLine(line, initial)
  if initial.len > 0:
    return

  # Re-poll every 100 ms for up to ~3 s. The editor's source-lines
  # field is populated synchronously when the file content arrives
  # (see frontend/utils.nim ~line 1160 and renderer.nim
  # ``onTabReloaded``); the IsoNim view stays on the ``no-code``
  # fallback until then. The captured ``path`` / ``line`` are stable
  # for the duration of this scheduled re-check; any subsequent move
  # cancels the relevance of older retries because the next call to
  # ``syncStoreCodeStateLine`` overwrites the signal anyway.
  let capturedPath = path
  let capturedLine = line
  var attempts = 0
  proc retry() =
    if stateVMStore.isNil:
      return
    attempts += 1
    let cur = lookupSourceLine(capturedPath, capturedLine)
    if cur.len > 0:
      stateVMStore.updateCodeStateLine(capturedLine, cur)
      return
    if attempts < 30:
      discard setTimeout(proc() = retry(), 100)
  discard setTimeout(proc() = retry(), 100)

proc syncStoreDebuggerPosition*(rrTicks: int, path: cstring, line: int) =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the StateVM's reactive pipeline sees the same rrTicks value.
  if stateVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  stateVMStore.updateDebuggerPosition(ticks, $path, line)
  syncStoreCodeStateLine(path, line)
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
  self.loadLocals()

method register*(self: StateComponent, api: MediatorWithSubscribers) =
  self.api = api

  # Initialize the parallel ViewModel instance (no-op if already created).
  initStateVM()
  let stateComponent = self
  stateVMInstance.onToggleHistory = proc(expression: string) =
    if not stateComponent.api.isNil:
      stateComponent.api.emit(
        CtLoadHistory,
        LoadHistoryArg(expression: cstring(expression),
                       location: stateComponent.location))

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
# Generic callers are expected to use direct IsoNim mount paths. All
# real rendering is handled by tryMountIsoNimStatePanel().

when defined(ctInExtension):
  method redrawForExtension*(self: StateComponent) =
    self.bindStateExtensionHost()

method onCompleteMove*(self: StateComponent, response: MoveState) {.async.} =
  self.location = response.location
  for value in self.values:
    value.location = response.location

  # Mirror the debugger position into the parallel ViewModel store.
  syncStoreDebuggerPosition(
    response.location.rrTicks, response.location.path, response.location.line)

  await self.onMove()
