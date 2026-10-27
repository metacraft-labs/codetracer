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
from ../dap import trackCtRequests, ctRequestIdOf, ctRequestSessionId
import ./session_viewmodels
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
import ./panel_host
from ../viewmodel/session_vm import SessionViewModel
# Horizontal-Overflow.md §5: the State pane's values are table cells.
from ../viewmodel/views/isonim_state_view import attachStateTableOverflow
from std/jsffi import JsObject
import isonim_origin_chain
import origin_chain_runtime

# The pane's StateVM: the SHOWN tab's session's (`initStateVMFromSession`,
# called again on every tab switch). The panel host renders each tab's State
# pane over its own tab's session (`ui/panel_host`), so these two name only
# what the window-level bridges (the watch input, the origin side panel) act
# on; what a session's moves and answers write goes to that session's own
# store (`syncStoreDebuggerPositionInto`, `wireLocalsAnswers`).
var stateVMInstance: StateVM
var stateVMStore: ReplayDataStore

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

  # Sync the new watch expression to the StateVM, whose stop loader re-asks
  # with it.
  # The watch belongs to this component's own tab (`ownPaneVM`).
  let ownVM = ownPaneVM(self, stateVMInstance, stateVM)
  if ownVM != nil:
    ownVM.addWatch($expression)

  input.toJs.value = cstring""


method restart*(self: StateComponent) =
  discard


# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# Placed before onCompleteMove so they are visible at
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

setPanelDecorator(Content.State,
  proc(host: dom_api.Element; session: SessionViewModel) =
    observePlaceholderBadges(host, session.stateVM)
    attachStateTableOverflow(cast[JsObject](host), session.stateVM))

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
  ## whichever ``OriginChainVM`` existed when it first ran. A new session
  ## *replaces* it in ``initStateVMFromSession``; without this reset the
  ## effect stays subscribed to the discarded VM's
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
  ## resolved from the file's name (`toLangFromFilename`).
  ## The host installs it before the session's ViewModels exist, because the
  ## stop loader may ask at once.
  store.sourceLanguageOf = proc(file: string): string =
    langWireName(toLangFromFilename(cstring(file)))

proc createSessionOriginChainVM*(vm: StateVM;
                                 scratchpad: ScratchpadVM = nil): OriginChainVM =
  ## The OriginChainVM of the session whose `StateVM` is `vm`, built once
  ## when that session's ViewModels are (`ui_js.configureSessionMiddleware`),
  ## with the bridges that let the State pane's row renderer dispatch
  ## ``ct/originChain`` requests through the same VM the side panel uses (M4
  ## deliverable §3.2.1 + §3.2.3). Each tab's session has its own, so a chain
  ## asked for in one tab is never shown in another.
  ##
  ## `scratchpad` is THAT session's Scratchpad ViewModel: a chain pinned from
  ## this session's side panel lands in this session's Scratchpad. Nil pins
  ## into the pane's (`installScratchpadForPins`), for a host with one
  ## session.
  result = createOriginChainVM(vm.store)
  if scratchpad.isNil:
    wireOriginChainBridges(vm, result)
  else:
    let target = scratchpad
    origin_chain_bridges.wireOriginChainBridges(vm, result,
      proc(): ScratchpadVM = target)

proc initStateVMFromSession*(vm: StateVM; originChain: OriginChainVM = nil) =
  ## Hand the pane the session's `StateVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ## Called for the shown tab's session on every tab switch.
  ##
  ## `originChain` is that session's OriginChainVM
  ## (`createSessionOriginChainVM`); nil builds one here, for a host that keeps
  ## a single session.
  let store = vm.store
  stateVMStore = store
  stateVMInstance = vm
  # The session's stop loader is the ONE sender of `ct/load-locals`.
  # A row's value history is asked for and applied by the ViewModel
  # (`ct/load-history` at the current stop), as on every front-end.
  let theVm = vm
  stateVMInstance.onToggleHistory = proc(expression: string) =
    theVm.loadValueHistory(expression)
  # The watch list needs no bridge here: the stop loader re-asks
  # `ct/load-locals` when it changes.
  # The companion OriginChainVM, its bridges wired so the State Pane row
  # renderer can dispatch ``ct/originChain`` requests through the same VM the
  # side-panel uses (M4 deliverable §3.2.1 + §3.2.3).
  originChainVMInstance =
    if originChain.isNil: createSessionOriginChainVM(vm)
    else: originChain
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
  ## SEPARATED FROM ``syncStoreLocalsInto`` SO A TEST CAN CALL IT. The sync
  ## proc needs a session's store, which only exists once the app has
  ## booted, so every probe that wanted to know what the State
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

proc syncStoreLocalsInto*(store: ReplayDataStore;
                          response: CtLoadLocalsResponseBody) =
  ## Mirror one `ct/load-locals` answer into `store` — the store of the
  ## session whose request it answers — so its StateVM's currentVariables
  ## memo sees the same data.
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
  if store.isNil or response.isNil:
    return
  # THE SESSION'S STOP LOADER APPLIES THE ANSWER IT ASKED FOR, through the
  # shared decoder (`store/locals_answer`), on the request's own future. This
  # fan-out delivers the same answer a second time; applying it here as well
  # would write the locals twice per stop.
  if store.localsLoadedByHost:
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
  if not store.applyLocalsAnswer(vmRows,
                                 $ctRequestIdOf(response.toJs)):
    cdebug "[PIPELINE] syncStoreLocals: dropped an answer for a stop the " &
      "debugger has left"
    return
  cdebug fmt"[PIPELINE] syncStoreLocals: synced {vmRows.len} row(s) into store"

var localsRequestsTracked = false

proc localsStoreForRequest(requestId: cstring): ReplayDataStore =
  ## The store of the tab whose `DapApi` sent `requestId` (`dap.ctRequestId`
  ## names each request by its session), or the shown tab's when no open tab
  ## sent it.
  let vm = sessionVMOf(
    data.sessionWithDapSessionId(ctRequestSessionId(requestId)))
  if not vm.isNil: vm.store else: stateVMStore

proc wireLocalsAnswers*(viewsApi: MediatorWithSubscribers;
                        store: ReplayDataStore) =
  ## Connect the web renderer's `ct/load-locals` traffic to the store's
  ## request ledger — both ends, and the one direct subscription.
  ##
  ## THE WEB SENDS `ct/load-locals` FROM ONE PLACE PER STOP: the session's
  ## stop loader (`sdk/stop_loader` -> the real backend's `sendCommand` ->
  ## `DapApi.asyncSendCtRequest`), which also applies the answer, so
  ## `syncStoreLocalsInto` stands down on such a store. Every sender reaches `dap.dispatchCtRequest`, and that
  ## is where the tracker records each request's stop under its identity —
  ## so the matching holds however many senders there are. The answer reaches
  ## the store through the direct subscription below, where the mediator
  ## delivers it; the ledger answers any second
  ## delivery with the first verdict, and the entry is retired once
  ## `dap.deliverDapResponse`'s fan-out is over. (Measured under the real
  ## mediator constructors — `locals_answer_identity_test.nim` — the direct
  ## subscription is NOT reached: `viewsApi.emit` fans out to subscribed
  ## component mediators, and the root's own handlers run only for events a
  ## component sends up. It is kept, as it was in `ui_js.nim`, and the
  ## matching does not depend on how many deliveries there are.)
  ##
  ##
  ## PER SESSION: each tab's session calls this once with its own views
  ## mediator and store (`ui_js.configureSessionMiddleware`), so an answer
  ## reaches the store of the tab that asked, shown or not. The request
  ## tracking is the transport's, one for every tab, and finds each
  ## request's store by the session its identity names.
  if not localsRequestsTracked:
    localsRequestsTracked = true
    trackCtRequests(CtLoadLocals,
      onSent = proc(requestId: cstring) =
        let target = localsStoreForRequest(requestId)
        if not target.isNil:
          target.noteLocalsRequestSent($requestId),
      onAnswered = proc(requestId: cstring) =
        let target = localsStoreForRequest(requestId)
        if not target.isNil:
          target.forgetLocalsRequest($requestId))
  # A DIRECT viewsApi subscription, bypassing the component mediator routing,
  # so the store receives the answer even when the State component's own
  # subscription is not wired up yet.
  let sessionStore = store
  viewsApi.subscribe(CtLoadLocalsResponse,
    proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
      cdebug ("[PIPELINE] viewsApi.CtLoadLocalsResponse: received " &
        $(if response.isNil: 0 else: response.locals.len) & " variables")
      syncStoreLocalsInto(sessionStore, response))

proc lookupSourceLine(editors: JsAssoc[cstring, EditorViewComponent];
                      path: cstring; line: int): string =
  ## Look up the source code at `<path>:<line>` from the editor cache.
  ## Mirrors the legacy ``StateComponent.excerpt`` lookup which read
  ## ``data.ui.editors[path].tabInfo.sourceLines[line - 1]``. Returns
  ## an empty string when:
  ##   * the editor for this file has not been opened / its source
  ##     lines have not yet been populated, or
  ##   * the requested line is outside the source-lines bounds (1-based
  ##     line numbers, so ``line < 1`` or ``line > sourceLines.len``).
  ## In either case the caller (``syncStoreCodeStateLineInto``) routes the
  ## empty string into the IsoNim view's ``no-code`` fallback so the
  ## ``#code-state-line-{id}`` element is still emitted.
  ##
  ## `editors` are one tab's: the tab whose session stopped there.
  if line < 1 or editors.isNil:
    return ""
  if not editors.hasKey(path):
    return ""
  let editor = editors[path]
  if editor.isNil or editor.tabInfo.isNil:
    return ""
  let lines = editor.tabInfo.sourceLines
  if line > lines.len:
    return ""
  $lines[line - 1]

type
  SourceLineRetryData = ref object
    store: ReplayDataStore
    editors: JsAssoc[cstring, EditorViewComponent]
    path: cstring
    line: int
    attempts: int

proc retrySourceLine(data: SourceLineRetryData) {.cdecl.} =
  if data.store.isNil:
    return
  data.attempts += 1
  let cur = lookupSourceLine(data.editors, data.path, data.line)
  if cur.len > 0:
    data.store.updateCodeStateLine(data.line, cur)
    return
  if data.attempts < 30:
    setTimeoutWithArg(retrySourceLine, 100, data)

proc syncStoreCodeStateLineInto*(store: ReplayDataStore;
                                 editors: JsAssoc[cstring, EditorViewComponent];
                                 path: cstring; line: int) =
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
  ##
  ## `store` and `editors` are ONE session's — the session the move belongs
  ## to, shown or not: its source line is looked up in its own tab's editors.
  if store.isNil:
    return
  let initial = lookupSourceLine(editors, path, line)
  store.updateCodeStateLine(line, initial)
  if initial.len > 0:
    return

  # Re-poll every 100 ms for up to ~3 s. The editor's source-lines
  # field is populated synchronously when the file content arrives
  # (see frontend/utils.nim ~line 1160 and renderer.nim
  # ``onTabReloaded``); the IsoNim view stays on the ``no-code``
  # fallback until then. The captured ``path`` / ``line`` are stable
  # for the duration of this scheduled re-check; any subsequent move
  # cancels the relevance of older retries because the next call to
  # ``syncStoreCodeStateLineInto`` overwrites the signal anyway.
  let retryData = SourceLineRetryData(
    store: store,
    editors: editors,
    path: path,
    line: line,
    attempts: 0
  )
  setTimeoutWithArg(retrySourceLine, 100, retryData)

proc syncStoreDebuggerPositionInto*(store: ReplayDataStore;
                                    editors: JsAssoc[cstring, EditorViewComponent];
                                    rrTicks: int, path: cstring, line: int;
                                    sourceGeneration: int = 0;
                                    sourceDigest: cstring = cstring"") =
  ## Mirror one session's debugger position into that session's store
  ## (`store`, with `editors` its tab's editors) so its StateVM's reactive
  ## pipeline sees the same rrTicks value — the session the move belongs to,
  ## whichever tab is on screen.
  if store.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  store.updateDebuggerPosition(
    ticks, $path, line,
    sourceGeneration = sourceGeneration,
    sourceDigest = $sourceDigest)
  syncStoreCodeStateLineInto(store, editors, path, line)
  cdebug fmt"[PIPELINE] syncStoreDebuggerPosition(state): synced debugger rrTicks={ticks}"

proc redrawDynamically*(self: StateComponent) =
  # IsoNim is the primary renderer. All DOM updates are handled by
  # IsoNim reactive effects when the store signals change (via
  # syncStoreLocalsInto). No Karax DOM manipulation needed.
  discard

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
  ## The pane subscribes to nothing: the panel host mounts the session's
  ## StateVM (`ui/panel_host`, from GoldenLayout's factory), the session's
  ## stop loader loads its locals, `ui_js` moves the store's debugger
  ## position, and the ViewModel asks for value histories.
  self.api = api

method onCompleteMove*(self: StateComponent, response: MoveState) {.async.} =
  self.location = response.location
  for _, value in self.values:
    value.location = response.location

  # Into the store of the tab that holds this component — the tab whose move
  # it is, shown or not — from that tab's editors. A component no tab holds
  # uses the pane's.
  let session = self.data.sessionOfComponent(self)
  let vm = sessionVMOf(session)
  let store = if vm.isNil: stateVMStore else: vm.store
  let editors =
    if session.isNil or session.ui.isNil: data.ui.editors
    else: session.ui.editors
  syncStoreDebuggerPositionInto(store, editors,
    response.location.rrTicks, response.location.path, response.location.line,
    response.location.sourceGeneration, response.location.sourceDigest)
