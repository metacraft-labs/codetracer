import
  ui_imports,
  value,
  ../communication,
  ../event_helpers,
  ../../common/ct_event,
  ../viewmodel/viewmodels/origin_chain_types

from std / dom import nil # imports dom, without directly its items: you need to use `dom.Node`

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The StateVM receives the same data but does not affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as store_types import nil
import ../viewmodel/viewmodels/state_vm
import ../viewmodel/viewmodels/origin_chain_vm
import ../viewmodel/viewmodels/origin_chain_types
import isonim/core/[signals, computation]
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_state_view import
  mountIsoNimStatePanel
import isonim_origin_chain
import origin_chain_runtime

# Module-level StateVM instance. Created once in `register()` and
# fed data whenever the legacy event-bus handlers fire.  Rendering
# still reads from the legacy `self.locals` so behaviour is unchanged.
var stateVMInstance: StateVM
var stateVMStore: ReplayDataStore
var stateHistoryBridge: proc(expression: string)
var isoNimStateMounted: bool = false

# Value Origin Tracking (M4): a single module-level OriginChainVM
# instance is created alongside the StateVM so the State Pane's inline
# badge click handler can both expand the row AND dispatch the
# placeholder-resolve / chain-fetch request through the same VM the
# side-panel uses. The instance is kept module-local because the State
# Pane is the primary entry-point — other surfaces (scratchpad,
# editor) read from the same VM via the host bridges.
var originChainVMInstance: OriginChainVM

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
    # M4 deliverable §3.2.3 + Gap 4 — install the
    # IntersectionObserver-driven lazy-fill bridge once the panel is
    # mounted.  A reactive effect re-walks the State Pane each time
    # the per-row ``originSummaries`` signal changes (which is also
    # the only moment placeholder badges can appear) and registers
    # every fresh placeholder pill with the shared observer.  The
    # observer auto-un-observes each pill on first intersection, so
    # re-walking on later updates only picks up newly-rendered
    # placeholders.
    let panelContainer = container
    createEffect proc() =
      # Reading the signal subscribes us so we re-fire whenever a new
      # batch of locals (and therefore a new batch of placeholder
      # tokens) arrives.
      discard stateVMInstance.originSummaries.val
      # Defer the DOM walk via setTimeout(0) so the IsoNim reactive
      # effect that rebuilds the row list has a chance to finish
      # appending the new badge nodes before we querySelectorAll for
      # them.  Without this defer we'd race the render and miss new
      # placeholder pills.
      discard setTimeout(proc() =
        let containerEl = panelContainer
        let nodeList = containerEl.toJs.querySelectorAll(
          cstring"button.ct-origin-badge.ct-origin-badge-placeholder")
        let count = nodeList.length.to(int)
        for i in 0 ..< count:
          observePlaceholderBadgeJs(nodeList[i])
      , 0)

  doMount()

# ---------------------------------------------------------------------------
# Origin Chain side-panel mount (M4 deliverable #9). The panel lives
# in a floating overlay element on document.body rather than as a
# GoldenLayout pane because the GL ``Content`` enum + component
# registry would require schema migration of saved layouts. The
# overlay approach matches the visual treatment described in the spec
# §3.2.2 (a side panel that opens/closes from the editor zone) and
# keeps the saved-layout schema stable.
# ---------------------------------------------------------------------------

when defined(js):
  import std/dom as kdom_state
  var originSidePanelHost: kdom_state.Node
  var originSidePanelState = newOriginChainPanel()
  var originSidePanelEffectInstalled = false

  proc ensureOriginSidePanelHost(): kdom_state.Node =
    ## Return the singleton overlay container. Created lazily inside
    ## the document body on first use; subsequent calls reuse it.
    if not originSidePanelHost.isNil:
      return originSidePanelHost
    let host = kdom_state.document.createElement(cstring"aside")
    host.setAttribute(cstring"id", cstring"ct-origin-chain-side-panel")
    host.setAttribute(cstring"class", cstring"ct-origin-chain-side-panel")
    host.setAttribute(cstring"aria-label", cstring"Value origin chain panel")
    host.setAttribute(cstring"role", cstring"complementary")
    host.style.display = cstring"none"
    kdom_state.document.body.appendChild(host)
    # ↑/↓/Enter/→/←/Esc per spec §13.0 — wire once on host creation.
    proc onKey(ev: kdom_state.Event) =
      let keyEv = cast[kdom_state.KeyboardEvent](ev)
      let key = $keyEv.key
      if originChainVMInstance.isNil:
        return
      let chainOpt = originChainVMInstance.activeChain.val
      if chainOpt.isNone:
        return
      let chain = chainOpt.get
      case key
      of "ArrowDown":
        focusNextHop(originSidePanelState, chain)
      of "ArrowUp":
        focusPrevHop(originSidePanelState, chain)
      of "Enter":
        enterHop(originSidePanelState, chain, originChainVMInstance)
      of "ArrowRight":
        expandFocusedOperands(originSidePanelState, chain)
      of "ArrowLeft":
        collapseFocusedOperands(originSidePanelState)
      of "Escape":
        dismissPanel(originSidePanelState)
        originChainVMInstance.closeSidePanel()
      else:
        return
    host.addEventListener(cstring"keydown", onKey)
    host.setAttribute(cstring"tabindex", cstring"-1")
    originSidePanelHost = host
    host

  proc renderOriginSidePanelDomReactive() =
    ## Mount or refresh the side panel.  Driven by an isonim render
    ## effect: subscribes to ``sidePanelOpen`` + ``activeChain`` and
    ## re-emits the DOM whenever either changes.
    if originChainVMInstance.isNil:
      return
    if originSidePanelEffectInstalled:
      return
    originSidePanelEffectInstalled = true
    createEffect proc() =
      let open = originChainVMInstance.sidePanelOpen.val
      let chain = originChainVMInstance.activeChain.val
      let host = ensureOriginSidePanelHost()
      if open and chain.isSome:
        host.style.display = cstring"block"
        renderPanelDom(host, originChainVMInstance, originSidePanelState)
        # focus the host so keyboard nav is immediately active
        try:
          host.focus()
        except:
          discard
      else:
        host.style.display = cstring"none"
        while not host.firstChild.isNil:
          host.removeChild(host.firstChild)

proc tryMountOriginSidePanel*() =
  ## Public entry-point invoked once the OriginChainVM is created.
  ## Idempotent — safe to call multiple times.
  when defined(js):
    renderOriginSidePanelDomReactive()

proc wireOriginChainBridges(stateVM: StateVM; originVM: OriginChainVM) =
  ## Wire the StateVM → OriginChainVM bridges so the State Pane's
  ## inline origin badge click handler dispatches the same
  ## ``ct/originChain`` request the side-panel uses (M4 deliverable
  ## §3.2.1 + §3.2.3). The chain-lookup bridge lets the per-row
  ## expansion block (M4 deliverable §3.2.2 "expanded chain") render
  ## as soon as the active chain matches the row's variable name.
  # Construct the bridge closure by capturing the OriginChainVM via
  # the surrounding scope.  The ``Location`` type the StateVM's
  # ``onShowOriginProc`` field uses is
  # ``viewmodel/store/types.Location``; we reach it through the
  # StateVM's own field type so the JS backend resolves the symbol
  # unambiguously.
  type StateLocation = typeof(stateVM.store.debugger.val.location)
  proc forwardShowOrigin(expression: string; location: StateLocation) =
    originVM.onShowOrigin(expression, location)
  stateVM.onShowOriginProc = forwardShowOrigin
  stateVM.originChainLookup = proc(name: string): origin_chain_types.Option[OriginChain] =
    # NB: ``origin_chain_types`` re-exports ``std/options``, which is
    # how we reach ``Option``/``some``/``none`` here without pulling
    # ``std/options`` directly (importing it in this file would
    # introduce a ``data`` ambiguity with the legacy global from
    # ``frontend/types.nim``).
    let active = originVM.activeChain.val
    if active.isSome and active.get.queryVariable == name:
      active
    else:
      origin_chain_types.none(OriginChain)
  # Sync the OriginChainVM preferences signal into the StateVM mirror
  # so badge text / icon / function-suffix follow the user's chosen
  # style.  The OriginChainVM owns the canonical preferences; the
  # StateVM mirror is read by the row renderer.
  stateVM.originPreferences.val = originVM.preferences.val

proc activeOriginChainVM*(): OriginChainVM =
  ## M29 §14.8 — expose the module-local `OriginChainVM` so the
  ## bootstrap code path (`ui_js.nim`) can attach it to the active
  ## `SessionViewModel` after `initStateVMWithStore` finishes.
  ## Returns ``nil`` until the VM has been created.
  originChainVMInstance

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
  stateVMInstance.onToggleHistory = stateHistoryBridge
  # Create the companion OriginChainVM and wire the bridges so the
  # State Pane row renderer can dispatch ``ct/originChain`` requests
  # through the same VM the side-panel uses (M4 deliverable §3.2.1 +
  # §3.2.3).
  originChainVMInstance = createOriginChainVM(store)
  wireOriginChainBridges(stateVMInstance, originChainVMInstance)
  # Publish the VM through the shared runtime so other surfaces
  # (history popover in ``ui/value.nim``, omniscience-flow overlay in
  # ``ui/flow.nim``, scratchpad chain cards) can enqueue placeholder
  # tokens into the same lazy-fill batch (spec §3.2.3).
  setOriginChainVM(originChainVMInstance)
  tryMountOriginSidePanel()
  cerror "[PIPELINE] initStateVMWithStore: storeId=" & $store.storeId
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
  # Companion OriginChainVM + bridges so the inline badge click
  # handler can dispatch through the same VM the side-panel uses
  # (M4 deliverable §3.2.1 + §3.2.3) even on the stub-backend code path.
  originChainVMInstance = createOriginChainVM(stateVMStore)
  wireOriginChainBridges(stateVMInstance, originChainVMInstance)
  setOriginChainVM(originChainVMInstance)
  tryMountOriginSidePanel()
  clog "StateVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimStatePanel()

proc valueDisplayText*(v: Value): string =
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

proc valueDisplayType*(v: Value): string =
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

proc toVariableChildren*(val: Value): seq[store_types.Variable] =
  result = @[]
  if val.isNil:
    return

  var value = val
  if value.kind in {TypeKind.Pointer, TypeKind.Ref} and not value.refValue.isNil:
    value = value.refValue

  case value.kind:
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    for i, element in value.elements:
      let childName = "[" & $i & "]"
      let hasChild = (if element.isNil: false else: element.elements.len > 0 or element.kind in {TypeKind.Pointer, TypeKind.Ref} or element.kind in {TypeKind.Instance, TypeKind.Union, TypeKind.Tuple, TypeKind.TableKind, TypeKind.Variant})
      result.add(makeVariable(
        name = childName,
        value = valueDisplayText(element),
        typeName = valueDisplayType(element),
        hasChildren = hasChild,
        children = toVariableChildren(element)
      ))
  of Variant:
    if not value.activeVariantValue.isNil:
      result = toVariableChildren(value.activeVariantValue)
  of TableKind:
    for items in value.items:
      let childName = $items[0]
      let element = items[1]
      let hasChild = (if element.isNil: false else: element.elements.len > 0 or element.kind in {TypeKind.Pointer, TypeKind.Ref} or element.kind in {TypeKind.Instance, TypeKind.Union, TypeKind.Tuple, TypeKind.TableKind, TypeKind.Variant})
      result.add(makeVariable(
        name = childName,
        value = valueDisplayText(element),
        typeName = valueDisplayType(element),
        hasChildren = hasChild,
        children = toVariableChildren(element)
      ))
  of Instance, Union, Tuple:
    if value.kind == Union:
      if not value.activeVariantValue.isNil:
        result = toVariableChildren(value.activeVariantValue)
    else:
      for i, label in value.typ.labels:
        if i < value.elements.len:
          let element = value.elements[i]
          let childName = $label
          let hasChild = (if element.isNil: false else: element.elements.len > 0 or element.kind in {TypeKind.Pointer, TypeKind.Ref} or element.kind in {TypeKind.Instance, TypeKind.Union, TypeKind.Tuple, TypeKind.TableKind, TypeKind.Variant})
          result.add(makeVariable(
            name = childName,
            value = valueDisplayText(element),
            typeName = valueDisplayType(element),
            hasChildren = hasChild,
            children = toVariableChildren(element)
          ))
  else:
    discard

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
    let hasChild = (if v.value.isNil: false else: v.value.elements.len > 0 or v.value.kind in {TypeKind.Pointer, TypeKind.Ref} or v.value.kind in {TypeKind.Instance, TypeKind.Union, TypeKind.Tuple, TypeKind.TableKind, TypeKind.Variant})
    vmLocals.add(makeVariable(
      name = $v.expression,
      value = valueDisplayText(v.value),
      typeName = valueDisplayType(v.value),
      hasChildren = hasChild,
      children = toVariableChildren(v.value),
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

proc syncStoreDebuggerPosition*(rrTicks: int, path: cstring, line: int;
                                sourceGeneration: int = 0;
                                sourceDigest: cstring = cstring"") =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the StateVM's reactive pipeline sees the same rrTicks value.
  if stateVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  stateVMStore.updateDebuggerPosition(
    ticks, $path, line,
    sourceGeneration = sourceGeneration,
    sourceDigest = $sourceDigest)
  syncStoreCodeStateLine(path, line)
  cerror fmt"[PIPELINE] syncStoreDebuggerPosition(state): synced debugger rrTicks={ticks}"

proc jsObjectToJson(raw: JsObject): cstring {.importjs: "JSON.stringify(#)".}
  ## Round-trip a JS object to its JSON serialisation. Used by the
  ## origin-summary bridge below to feed the per-row ``originSummary``
  ## payload into the Nim ``parseOriginSummary`` decoder.

proc syncOriginSummaries(response: CtLoadLocalsResponseBody) =
  ## Value Origin Tracking (M4) — mirror the per-variable
  ## ``originSummary`` field the backend attaches to every
  ## ``ct/load-locals`` response (spec §3.2.3) into the StateVM so
  ## the IsoNim view's inline badge renders correctly. The wire field
  ## is JSON-encoded (because ``CtLoadLocalsResponseBody.locals`` is
  ## the JS-only ``Variable`` ref-object that does not yet carry the
  ## summary as a typed field — extending the ref-object would ripple
  ## through every consumer), so we walk the raw JS object and decode
  ## each summary through ``parseOriginSummary``. The fall-back behaviour
  ## when the field is missing (older backends, non-materialized
  ## traces) is an empty per-row table — the view then renders no
  ## badge for that row, matching the legacy contract.
  if stateVMInstance.isNil:
    return
  var summaries: seq[(string, OriginSummary)] = @[]
  for localVariable in response.locals:
    let expression = $localVariable.expression
    let raw = localVariable.toJs[cstring("originSummary")]
    if raw.isNil or raw.isUndefined:
      continue
    let asJson = parseJson($jsObjectToJson(raw))
    summaries.add((expression, parseOriginSummary(asJson)))
  stateVMInstance.updateOriginSummaries(summaries)

proc registerLocals*(self: StateComponent, response: CtLoadLocalsResponseBody) {.exportc.} =
  clog fmt"registerLocals"
  self.locals = response.locals

  # Feed the same data into the parallel ViewModel store.
  syncStoreLocals(response.locals)
  syncOriginSummaries(response)
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
  stateHistoryBridge = proc(expression: string) =
    if not stateComponent.api.isNil:
      stateComponent.api.emit(
        CtLoadHistory,
        LoadHistoryArg(expression: cstring(expression),
                       location: stateComponent.location))
  stateVMInstance.onToggleHistory = stateHistoryBridge

  # api.subscribe(DapStopped, proc(kind: CtEventKind, response: DapStoppedEvent, sub: Subscriber) =
    # discard self.onMove())
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtLoadLocalsResponse, proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
    self.registerLocals(response)
  )
  api.subscribe(CtUpdatedHistory, proc(kind: CtEventKind, response: HistoryUpdate, sub: Subscriber) =
    if not stateVMInstance.isNil:
      stateVMInstance.updateHistory($response.expression, response.results)
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
    response.location.rrTicks, response.location.path, response.location.line,
    response.location.sourceGeneration, response.location.sourceDigest)

  await self.onMove()
