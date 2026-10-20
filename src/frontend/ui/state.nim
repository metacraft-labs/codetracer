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
from ../dap import trackCtRequests, ctRequestIdOf
import ./presented_value
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as store_types import nil
import ../viewmodel/viewmodels/state_vm
import ../viewmodel/viewmodels/origin_chain_vm
import ../viewmodel/viewmodels/origin_chain_types
import ../viewmodel/viewmodels/origin_chain_bridges as origin_chain_bridges
from ../viewmodel/viewmodels/scratchpad_vm import ScratchpadVM
import isonim/core/[signals, computation]
from isonim/web/dom_api import nil
when defined(ctInExtension):
  from ../viewmodel/views/isonim_state_view import
    mountIsoNimStatePanel
else:
  import ./panel_host
  from ../viewmodel/session_vm import SessionViewModel
import isonim_origin_chain
import origin_chain_runtime

# The pane's StateVM. On the desktop and the web page it is the session's
# (`initStateVMFromSession`), rendered by the panel host (`ui/panel_host`).
# The VS Code extension's webview has no session store: `register` builds a
# stub-backed one (`initStateVM`) that the component's events feed.
var stateVMInstance: StateVM
var stateVMStore: ReplayDataStore
when defined(ctInExtension):
  var stateHistoryBridge: proc(expression: string)

when defined(js):
  proc setTimeoutWithArg[T](cb: proc(x: T) {.cdecl.}, delay: int, arg: T) {.importjs: "setTimeout(#, #, #)".}


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

var storeSendsLocals = false
  ## Set by `initStateVMFromSession`: the session's stop loader is the one
  ## `ct/load-locals` sender (`loadLocals`).

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

  # Sync the new watch expression to the StateVM, whose auto-load re-asks
  # with it; `loadLocals` asks itself only where that auto-load runs over a
  # stub store (the VS Code extension).
  if stateVMInstance != nil:
    stateVMInstance.addWatch($expression)
  self.loadLocals()

  input.toJs.value = cstring""


method restart*(self: StateComponent) =
  discard

when defined(ctInExtension):
  var mountedStateVM: StateVM
    ## The ViewModel the webview's State pane shows, or `nil`.
  var mountedStateHost: dom_api.Element
    ## The element it was mounted into.

  proc mountStatePanelForExtension()

  var stateComponentForExtension* {.exportc.}: StateComponent

  proc bindStateExtensionHost(component: StateComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    # Mount the IsoNim state panel into the container the extension webview
    # provides. Idempotent: a host already showing this VM is left alone.
    mountStatePanelForExtension()

  proc makeStateComponentForExtension*(id: cstring): StateComponent {.exportc.} =
    if stateComponentForExtension.isNil:
      if data.sessions.len == 0:
        return
      stateComponentForExtension = makeStateComponent(data, 0, inExtension = true)
    if stateComponentForExtension.extensionRendererId.len == 0:
      stateComponentForExtension.extensionRendererId = id
      stateComponentForExtension.bindStateExtensionHost()
    result = stateComponentForExtension

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# Placed before registerLocals / onCompleteMove so they are visible at
# the call sites without forward declarations.
# ---------------------------------------------------------------------------

proc observePlaceholderBadges(container: dom_api.Element; vm: StateVM) =
  ## Value Origin Tracking (spec §3.2.3): hand each placeholder badge the pane
  ## shows to the lazy-fill observer (`origin_chain_runtime`), again whenever
  ## a new batch of locals — and so of placeholder tokens — arrives. Runs in
  ## the mount's reactive root.
  let panelContainer = container
  createEffect proc() =
    discard vm.originSummaries.val
    # After the rows for the new summaries are drawn.
    setTimeoutWithArg(proc(containerEl: dom_api.Element) {.cdecl.} =
      let nodeList = containerEl.toJs.querySelectorAll(
        cstring"button.ct-origin-badge.ct-origin-badge-placeholder")
      let count = nodeList.length.to(int)
      for i in 0 ..< count:
        observePlaceholderBadgeJs(nodeList[i])
    , 0, panelContainer)

when defined(ctInExtension):
  proc mountStatePanelForExtension() =
    ## Mount the State pane into the element the extension's webview names
    ## (`extensionRendererId`) — the webview is not the panel host.
    if stateVMInstance.isNil or stateComponentForExtension.isNil:
      return
    let container = dom_api.getElementById(
      dom_api.document, stateComponentForExtension.extensionRendererId)
    if dom_api.isNodeNil(dom_api.Node(container)):
      return
    if mountedStateVM == stateVMInstance and mountedStateHost == container:
      return
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)
    mountedStateVM = stateVMInstance
    mountedStateHost = container
    mountIsoNimStatePanel(container, stateVMInstance)
    observePlaceholderBadges(container, stateVMInstance)
else:
  setPanelDecorator(Content.State,
    proc(host: dom_api.Element; session: SessionViewModel) =
      observePlaceholderBadges(host, session.stateVM))

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

proc releaseOriginSidePanelEffect*() =
  ## Forget the installed render effect so the next
  ## ``tryMountOriginSidePanel`` installs a fresh one.
  ##
  ## Needed because the effect captures its reactive dependencies from
  ## whichever ``OriginChainVM`` existed when it first ran. Startup
  ## creates a stub-backed VM during ``register()`` and then *replaces*
  ## it with the shared-store VM in ``initStateVMFromSession``; without
  ## this reset the effect stays subscribed to the discarded stub's
  ## ``sidePanelOpen`` / ``activeChain`` signals, so the real VM's
  ## chain arrives and the panel never re-renders — the side panel is
  ## drawn exactly once, empty, and stays that way for the whole
  ## session.
  when defined(js):
    originSidePanelEffectInstalled = false

var scratchpadForPins: proc(): ScratchpadVM
  ## Where "Pin to scratchpad" puts a chain: the Scratchpad pane's
  ## ViewModel, resolved when the pin happens. `ui/scratchpad.nim` imports
  ## this module, so this module cannot import it back; it installs the
  ## resolver instead (`installScratchpadForPins`). Resolving at pin time
  ## rather than at wiring time is what lets the OriginChainVM be built
  ## before the Scratchpad pane's VM is, and follow that VM when it is
  ## replaced by the session's.

proc installScratchpadForPins*(resolve: proc(): ScratchpadVM) =
  scratchpadForPins = resolve

proc wireOriginChainBridges(stateVM: StateVM; originVM: OriginChainVM) =
  ## The production wiring of the origin badge, the side panel and the
  ## Scratchpad. It lives in the ViewModel layer
  ## (`origin_chain_bridges.wireOriginChainBridges`) so the headless
  ## suites drive the same bridges this renderer installs.
  origin_chain_bridges.wireOriginChainBridges(stateVM, originVM,
    proc(): ScratchpadVM =
      if scratchpadForPins.isNil: nil else: scratchpadForPins())

proc activeStateVM*(): StateVM =
  ## M42 §14.8 — expose the module-local `StateVM` so the bootstrap
  ## code path (`ui_js.nim`) can install the multi-process bridges the
  ## "Switch process" context-menu entry needs. Returns ``nil`` until
  ## the VM has been created.
  stateVMInstance

proc activeOriginChainVM*(): OriginChainVM =
  ## M29 §14.8 — expose the module-local `OriginChainVM` so the
  ## bootstrap code path (`ui_js.nim`) can attach it to the active
  ## `SessionViewModel` after `initStateVMFromSession` finishes.
  ## Returns ``nil`` until the VM has been created.
  originChainVMInstance

proc installSourceLanguage*(store: ReplayDataStore) =
  ## THE LANGUAGE the store's `ct/load-locals` names: the stopped-in file's,
  ## resolved exactly as the legacy `StateComponent.loadLocals` resolved it.
  ## The host installs it before the session's ViewModels exist, because the
  ## stop loader may ask at once.
  store.sourceLanguageOf = proc(file: string): string =
    langWireName(toLangFromFilename(cstring(file)))

proc initStateVMFromSession*(vm: StateVM) =
  ## Hand the pane the session's `StateVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ##
  ## If a stub-backed instance already exists (created before the session
  ## was available), it is replaced so the panel uses the real backend.
  let store = vm.store
  stateVMStore = store
  stateVMInstance = vm
  # From here on the session's stop loader is the ONE sender of
  # `ct/load-locals` — see `storeSendsLocals` and `loadLocals`.
  storeSendsLocals = true
  # A row's value history is asked for and applied by the ViewModel
  # (`ct/load-history` at the current stop), as on every front-end.
  let theVm = vm
  stateVMInstance.onToggleHistory = proc(expression: string) =
    theVm.loadValueHistory(expression)
  # The watch list needs no bridge here: the stop loader re-asks
  # `ct/load-locals` when it changes.
  # Create the companion OriginChainVM and wire the bridges so the
  # State Pane row renderer can dispatch ``ct/originChain`` requests
  # through the same VM the side-panel uses (M4 deliverable §3.2.1 +
  # §3.2.3).
  originChainVMInstance = createOriginChainVM(store)
  wireOriginChainBridges(stateVMInstance, originChainVMInstance)
  # The VM this replaces may already own the side panel's render
  # effect; drop it so the panel re-binds to the new VM's signals.
  releaseOriginSidePanelEffect()
  # Publish the VM through the shared runtime so other surfaces
  # (history popover in ``ui/value.nim``, omniscience-flow overlay in
  # ``ui/flow.nim``, scratchpad chain cards) can enqueue placeholder
  # tokens into the same lazy-fill batch (spec §3.2.3).
  setOriginChainVM(originChainVMInstance)
  tryMountOriginSidePanel()
  cdebug "[PIPELINE] initStateVMFromSession: storeId=" & $store.storeId
  clog "StateVM: the session's instance installed"

when defined(ctInExtension):
  proc initStateVM() =
    ## The VS Code extension's webview: a StateVM over a stub BackendService,
    ## fed by the component's events (it has no session store).
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
    # The origin side panel mounts into a floating aside appended to
    # document.body and expects the full desktop DOM; the webview has a
    # minimal, panel-only DOM, so it is not mounted here.
    clog "StateVM: parallel ViewModel instance created (stub backend)"
    mountStatePanelForExtension()

proc valueDisplayText*(v: Value): string =
  ## What the State pane's value cell says a recorded value IS.
  ##
  ## PLAT-2: ONE CALL, TO THE ONE PRESENTER, AT THIS SURFACE'S DECLARED BUDGET.
  ##
  ## What it replaced was a three-way choice this pane made for itself, and the
  ## history is worth keeping because each arm was a real defect:
  ##
  ##   * it was `$v` — `text_representation.text`, a multi-line diagnostic DUMP.
  ##     A recorded sequence arrived intact and was displayed as the prose
  ##     `"Sequence(Seq [Field; 4]):\n  100\n  2000\n…"` inside the single
  ##     `span.value-expanded-text` the IsoNim view gives the value cell — while
  ##     the caret beside it already offered the real children.
  ##   * `$v` also LOST REFUSALS: `text()` has no `of Error` branch, so a watch
  ##     refusal — whose `msg` IS the explanation — reached the user as the four
  ##     characters `Error`.
  ##   * the fix was `textRepr` with a `$v` FALLBACK, because `textReprDefault`'s
  ##     `case` ends in `else: ""` and `Enum16`, `Enum32`, `Literal`, `Slice` and
  ##     `Any` fell through it into an EMPTY CELL. So the pane carried a
  ##     two-formatter ladder to work around a hole in one of them.
  ##
  ## The presenter is total — every `PValue` kind renders to something, and
  ## `value_presentation_test` asserts exactly that over the whole enum — so
  ## there is no hole to work around and no ladder. `Error` renders
  ## `<error: msg>` here and on all five other surfaces.
  if v.isNil:
    return ""
  statePanelValue(v).root.text

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

proc localsToStoreRows*(legacyLocals: seq[Variable]): seq[store_types.Variable] =
  ## Map one ``ct/load-locals`` response body onto the store's rows.
  ##
  ## SEPARATED FROM ``syncStoreLocals`` SO A TEST CAN CALL IT. The sync
  ## proc needs the module-level ``stateVMStore``, which only exists once
  ## the app has booted, so every probe that wanted to know what the State
  ## pane *displays* had to re-implement this mapping by hand — and a
  ## hand-written copy cannot notice when the real one is wrong. It did not
  ## notice: `ci/test/watch_expressions_browser_probe.nim` read the refusal
  ## straight out of the wire's ``msg`` field and painted it, while the
  ## product's own mapping turned that same row into the bare word
  ## "Error" (``text_representation.text`` has no ``of Error`` branch, so
  ## ``$value`` fell through to ``$value.kind``). Twenty-four green checks
  ## over a pane that shipped the wrong string.
  ##
  ## So: one mapping, exported, and the probes call it.
  result = newVariableSeq()
  for v in legacyLocals:
    let hasChild = (if v.value.isNil: false else: v.value.elements.len > 0 or v.value.kind in {TypeKind.Pointer, TypeKind.Ref} or v.value.kind in {TypeKind.Instance, TypeKind.Union, TypeKind.Tuple, TypeKind.TableKind, TypeKind.Variant})
    result.add(makeVariable(
      name = $v.expression,
      value = valueDisplayText(v.value),
      typeName = valueDisplayType(v.value),
      hasChildren = hasChild,
      children = toVariableChildren(v.value),
      isWatch = (not v.value.isNil and v.value.isWatch),
    ))

proc syncStoreLocals*(response: CtLoadLocalsResponseBody) =
  ## Mirror one `ct/load-locals` answer into the ViewModel store so the
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
  if stateVMStore.isNil or response.isNil:
    return
  # THE SESSION'S STOP LOADER APPLIES THE ANSWER IT ASKED FOR, through the
  # shared decoder (`store/locals_answer`), on the request's own future. This
  # fan-out delivers the same answer a second time; applying it here as well
  # would write the locals twice per stop.
  if stateVMStore.localsLoadedByHost:
    return
  # WATCH ANSWERS TRAVEL IN THE SAME LIST. Each row carries `value.isWatch`
  # (set by the backend — see `db-backend/src/watch_expression.rs`); the
  # split itself belongs to `applyLocalsResponse`, which is the one place
  # every host performs it.
  let vmRows = localsToStoreRows(response.locals)
  # PLAT-29: THE ANSWER IS RECONCILED AGAINST THE STOP ITS OWN REQUEST WAS
  # SENT AT. `wireLocalsAnswers` recorded that stop under the request's
  # identity as the request was written — whichever of the web's two senders
  # wrote it — and `dap.deliverDapResponse` stamped the same identity into
  # this body. Matching by identity, not by order, is what keeps a second
  # sender or a second subscriber from pairing an answer with the wrong
  # request. One the debugger has moved past is dropped rather than drawn
  # beside the new stop.
  if not stateVMStore.applyLocalsAnswer(vmRows,
                                        $ctRequestIdOf(response.toJs)):
    cdebug "[PIPELINE] syncStoreLocals: dropped an answer for a stop the " &
      "debugger has left"
    return
  cdebug fmt"[PIPELINE] syncStoreLocals: synced {vmRows.len} row(s) into store"

var localsAnswersWired = false

proc wireLocalsAnswers*(viewsApi: MediatorWithSubscribers) =
  ## Connect the web renderer's `ct/load-locals` traffic to the store's
  ## request ledger — both ends, and the one direct subscription.
  ##
  ## THE WEB SENDS `ct/load-locals` FROM ONE PLACE PER STOP: the session's
  ## stop loader (`sdk/stop_loader` -> the real backend's `sendCommand` ->
  ## `DapApi.asyncSendCtRequest`), which also applies the answer, so
  ## `syncStoreLocals` stands down on such a store. `StateComponent.loadLocals`
  ## (through the mediator and `middleware` to `DapApi.sendCtRequest`) stands
  ## down once `initStateVMFromSession` has run, and sent a second request per
  ## move until it did. Every sender reaches `dap.dispatchCtRequest`, and that
  ## is where the tracker records each request's stop under its identity —
  ## so the matching holds however many senders there are. The answer reaches
  ## the store through
  ## `StateComponent.registerLocals` and, where the mediator delivers it,
  ## through the direct subscription below; the ledger answers any second
  ## delivery with the first verdict, and the entry is retired once
  ## `dap.deliverDapResponse`'s fan-out is over. (Measured under the real
  ## mediator constructors — `locals_answer_identity_test.nim` — the direct
  ## subscription is NOT reached: `viewsApi.emit` fans out to subscribed
  ## component mediators, and the root's own handlers run only for events a
  ## component sends up. It is kept, as it was in `ui_js.nim`, and the
  ## matching does not depend on how many deliveries there are.)
  ##
  ## Idempotent: `configureMiddleware` can run again for a new trace.
  if localsAnswersWired:
    return
  localsAnswersWired = true
  trackCtRequests(CtLoadLocals,
    onSent = proc(requestId: cstring) =
      if not stateVMStore.isNil:
        stateVMStore.noteLocalsRequestSent($requestId),
    onAnswered = proc(requestId: cstring) =
      if not stateVMStore.isNil:
        stateVMStore.forgetLocalsRequest($requestId))
  # A DIRECT viewsApi subscription, bypassing the component mediator routing,
  # so the store receives the answer even when the State component's own
  # subscription is not wired up yet.
  viewsApi.subscribe(CtLoadLocalsResponse,
    proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
      cdebug ("[PIPELINE] viewsApi.CtLoadLocalsResponse: received " &
        $(if response.isNil: 0 else: response.locals.len) & " variables")
      syncStoreLocals(response))

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

type
  SourceLineRetryData = ref object
    path: cstring
    line: int
    attempts: int

proc retrySourceLine(data: SourceLineRetryData) {.cdecl.} =
  if stateVMStore.isNil:
    return
  data.attempts += 1
  let cur = lookupSourceLine(data.path, data.line)
  if cur.len > 0:
    stateVMStore.updateCodeStateLine(data.line, cur)
    return
  if data.attempts < 30:
    setTimeoutWithArg(retrySourceLine, 100, data)

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
  let retryData = SourceLineRetryData(
    path: path,
    line: line,
    attempts: 0
  )
  setTimeoutWithArg(retrySourceLine, 100, retryData)

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
  cdebug fmt"[PIPELINE] syncStoreDebuggerPosition(state): synced debugger rrTicks={ticks}"

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
  syncStoreLocals(response)
  syncOriginSummaries(response)
  for localVariable in response.locals:
    let expression = localVariable.expression

    if self.values.hasKey(expression):
      let value = self.values[expression]

      for _, chart in value.charts:
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

proc activeWatchExpressions(self: StateComponent): seq[cstring] =
  ## The watch expressions to ask the backend for.
  ##
  ## THE VIEWMODEL IS THE SOURCE OF TRUTH, because it is what the watch
  ## input form writes: `wireWatchInputForm` (`isonim_state_view.nim`)
  ## calls `StateVM.addWatch`, and the collaboration layer edits the same
  ## signal. `StateComponent.watchExpressions` is only written by
  ## `submitWatchExpression`, which has no call sites anywhere in the
  ## repo — so reading it alone meant this request never carried anything
  ## a user typed.
  ##
  ## The component's own list is still honoured as a fallback so the
  ## legacy path keeps working on hosts that never build a StateVM.
  if not stateVMInstance.isNil:
    result = @[]
    for expression in stateVMInstance.watchExpressions.val:
      result.add(cstring(expression))
  else:
    result = self.watchExpressions

proc loadLocals*(self: StateComponent) =
  ## The legacy State component's `ct/load-locals` — the only sender on a
  ## host whose StateVM runs over a stub store (the VS Code extension, where
  ## `configureMiddleware` never builds the session's store).
  ##
  ## ONE REQUEST PER STOP. Once `initStateVMFromSession` has put the StateVM on
  ## the session's real store, the session's stop loader (`sdk/stop_loader`)
  ## asks on every stop and every watch-list change, through the same
  ## transport, and its answer reaches this component through the same
  ## fan-out. This component
  ## asking as well made two requests per move — one naming the file's
  ## language, the store's naming `c` — so it stands down; the store's
  ## request names the file's language (`ReplayDataStore.sourceLanguageOf`,
  ## installed there), the stop's own tick (this component's `rrTicks` is
  ## never assigned, so it sent 0), the same depth, budget and watches.
  if storeSendsLocals:
    return
  let countBudget = 3000
  let minCountLimit = 50
  let arguments = CtLoadLocalsArguments(
    rrTicks: self.rrTicks,
    countBudget: countBudget,
    minCountLimit: minCountLimit,
    depthLimit: LOCALS_RR_DEPTH_LIMIT,
    watchExpressions: self.activeWatchExpressions(),
    # The wire name, not the enum: this object goes through `toJs`, where a
    # `Lang` would serialise as its ordinal (LRS-1).
    lang: cstring(langWireName(toLangFromFilename(self.location.path))),
  )
  # PLAT-29: the stop this is sent at is recorded by `wireLocalsAnswers`'s
  # tracker as the request is WRITTEN, under the request's own identity.
  self.api.emit(CtLoadLocals, arguments)

method onMove(self: StateComponent) {.async.} =
  self.loadLocals()

proc toValueHistoryRows(results: seq[HistoryResult]): seq[ValueHistoryRow] =
  ## Normalise the ``ct/updated-history`` wire rows into the
  ## backend-neutral shape ``StateVM`` stores.
  ##
  ## This is the single boundary at which the renderer-side
  ## ``HistoryResult`` (from the ``frontend/types.nim`` instantiation of
  ## the included ``common_types``, where ``langstring = cstring``) is
  ## converted. Keeping the conversion here — rather than letting the
  ## ViewModel name a type that exists in two incompatible copies — is
  ## what lets ``StateVM``/``state_view`` compile natively for the
  ## headless tests and removes the previous ``cast[seq[HistoryResult]]``.
  result = newSeq[ValueHistoryRow](results.len)
  for i, r in results:
    result[i] = ValueHistoryRow(
      locationTicks: BiggestInt(r.location.rrTicks),
      valueText: if r.value.isNil: "" else: statePanelValue(r.value).root.text)

method register*(self: StateComponent, api: MediatorWithSubscribers) =
  ## On the desktop and the web page the pane subscribes to nothing: the panel
  ## host mounts the session's StateVM (`ui/panel_host`, from GoldenLayout's
  ## factory), the session's stop loader loads its locals, `ui_js` moves the
  ## store's debugger position, and the ViewModel asks for value histories.
  ##
  ## The VS Code extension's webview has no session store, so there the
  ## component still feeds a stub-backed StateVM from the events below; its
  ## methods (`onCompleteMove`, `loadLocals`, `registerLocals`) are that path.
  self.api = api

  when defined(ctInExtension):
    initStateVM()

    let stateComponent = self
    stateHistoryBridge = proc(expression: string) =
      if not stateComponent.api.isNil:
        stateComponent.api.emit(
          CtLoadHistory,
          LoadHistoryArg(expression: cstring(expression),
                         location: stateComponent.location))
    stateVMInstance.onToggleHistory = stateHistoryBridge

    api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
      discard self.onCompleteMove(response)
    )
    api.subscribe(CtLoadLocalsResponse, proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
      self.registerLocals(response)
    )
    api.subscribe(CtUpdatedHistory, proc(kind: CtEventKind, response: HistoryUpdate, sub: Subscriber) =
      if not stateVMInstance.isNil:
        stateVMInstance.updateHistory($response.expression,
                                      toValueHistoryRows(response.results))
    )
    api.emit(InternalLastCompleteMove, EmptyArg())

# think if it's possible to directly exportc in this way the method
proc registerStateComponent*(component: StateComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

when defined(ctInExtension):
  method redrawForExtension*(self: StateComponent) =
    self.bindStateExtensionHost()

method onCompleteMove*(self: StateComponent, response: MoveState) {.async.} =
  self.location = response.location
  for _, value in self.values:
    value.location = response.location

  syncStoreDebuggerPosition(
    response.location.rrTicks, response.location.path, response.location.line,
    response.location.sourceGeneration, response.location.sourceDigest)
  await self.onMove()
