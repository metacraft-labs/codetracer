import
  ui_imports, value, ../utils,
  ../communication, ../../common/ct_event

from std / dom import nil # imports dom, without directly its items: you need to use `dom.Node`

# ---------------------------------------------------------------------------
# ViewModel layer — IsoNim is now the primary renderer for the calltrace.
# The CalltraceVM drives the IsoNim reactive DOM tree; the legacy Karax
# render() returns an empty stub once the IsoNim view is mounted.
# ---------------------------------------------------------------------------
import std/[json, tables, options]
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
from ../viewmodel/store/types as vm_types import nil
from ../viewmodel/store/replay_data_store import
  ReplayDataStore, createReplayDataStore, updateCalltraceSection,
  updateDebuggerPosition, makeCallLine, makeCallArg, requestCalltraceSection
from ../viewmodel/store/request_tracker import markComplete
from ../viewmodel/viewmodels/calltrace_vm import
  CalltraceVM, createCalltraceVM,
  scroll, setViewportHeight, setViewportDepth, setRawIgnorePatterns,
  setBackendSearchResults, selectEntry
from isonim/web/dom_api import nil
from isonim/core/batch as isoBatch import batch
from isonim/core/signals import val
from ../viewmodel/views/isonim_calltrace_view import
  mountIsoNimCalltrace

# Module-level CalltraceVM instance. Created once in `register()` and
# fed data whenever the legacy event-bus handlers fire.  The IsoNim
# view is the primary renderer once mounted.
var calltraceVMInstance: CalltraceVM
var calltraceVMStore: ReplayDataStore
var isoNimCalltraceMounted: bool = false

let returnValueName: cstring = "<return value>"

const
  CALL_OFFSET_WIDTH_PX  = 20
  CALL_HEIGHT_PX        = 24
  CALL_BUFFER           = 20
  START_BUFFER          = 10
  CALLTRACE_MARKER_SELECTOR = cstring".collapse-call-img, .expand-call-img, .dot-call-img, .end-of-program-img, .active-call-location"
  CALLTRACE_TOGGLE_SELECTOR = cstring".toggle-call"
  EXPAND_CALLS_KIND     = CtExpandCalls
  COLLAPSE_CALLS_KIND   = CtCollapseCalls

proc getCurrentMonacoTheme(editor: MonacoEditor): cstring {.importjs:"#._themeService._theme.themeName".}
proc getBoundingClientRect(node: js): HTMLBoundingRect {.importjs:"#.getBoundingClientRect()".}
proc replaceChildren(node: js) {.importjs:"#.replaceChildren()".}
proc redrawCallLines(self: CalltraceComponent)
proc loadLines(self: CalltraceComponent, fromScroll: bool)
proc calltraceValueDomHostId(prefix: cstring, parts: varargs[cstring]): cstring
proc mountCalltraceValueDom(hostId: cstring, value: ValueComponent)
proc renderCallExpandedValuesDom*(self: CallExpandedValuesComponent): Node

when defined(ctInExtension):
  var calltraceComponentForExtension* {.exportc.}: CalltraceComponent = makeCalltraceComponent(data, 0, inExtension = true)

  proc bindCalltraceExtensionHost(component: CalltraceComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    # The extension calltrace surface has no panel markup of its own; keep the
    # exported component usable without retaining an empty Karax renderer.
    host.innerHTML = cstring""

  proc makeCalltraceComponentForExtension*(id: cstring): CalltraceComponent {.exportc.} =
    if calltraceComponentForExtension.extensionRendererId.len == 0:
      calltraceComponentForExtension.extensionRendererId = id
      calltraceComponentForExtension.bindCalltraceExtensionHost()
    result = calltraceComponentForExtension

proc calltraceJump(self: CalltraceComponent, location: types.Location) =
  self.api.emit(CtCalltraceJump, location)
  self.api.emit(InternalNewOperation, NewOperation(stableBusy: true, name: "calltrace-jump"))

proc isAtStart(self: CalltraceComponent): bool =
  self.startCallLineIndex < START_BUFFER

proc getStartBufferLen(self: CalltraceComponent): int =
  if self.isAtStart():
    self.startCallLineIndex
  else:
    START_BUFFER

proc toggleCalls*(
  self: CalltraceComponent,
  kind: CtEventKind,
  callKey: cstring,
  nonExpandedKind: CalltraceNonExpandedKind,
  count: int
) =
  let target = CollapseCallsArgs(callKey: callKey, nonExpandedKind: nonExpandedKind, count: count)
  self.api.emit(kind, target)

proc `$`*(c: CallCount): string =
  case c.kind:
  of Equal:
    $c.i
  of GreaterOrEqual:
    &">= {c.i}"
  of LessOrEqual:
    &"<= {c.i}"
  of Greater:
    &"> {c.i}"
  of Less:
    &"< {c.i}"

proc panelDepth*(self: CalltraceComponent): int =
  cast[int](jq("#calltraceComponent-" & $self.id).offsetWidth) div CALL_OFFSET_WIDTH_PX

proc panelHeight*(self: CalltraceComponent): int =
  cast[int](jq("#calltraceComponent-" & $self.id).offsetHeight) div CALL_HEIGHT_PX

proc scrollRawPosition*(self: CalltraceComponent): int =
  cast[int](jq("#calltraceScroll-" & $self.id).toJs.scrollTop)

proc scrollLineIndex*(self: CalltraceComponent): int =
  (self.scrollRawPosition() / CALL_HEIGHT_PX).floor

proc domIdToken(raw: cstring): string =
  for ch in $raw:
    if ch in {'a'..'z'} or ch in {'A'..'Z'} or ch in {'0'..'9'} or ch in {'-', '_'}:
      result.add(ch)
    else:
      result.add("_")
      result.add(toHex(ord(ch), 2))

proc calltraceValueDomHostId(prefix: cstring, parts: varargs[cstring]): cstring =
  var id = $prefix
  for part in parts:
    id.add("-")
    id.add(domIdToken(part))
  result = cstring(id)

proc mountCalltraceValueDom(hostId: cstring, value: ValueComponent) =
  let host = document.getElementById(hostId)
  if host.isNil:
    return

  host.innerHTML = cstring""
  host.appendChild(value.renderValueDom())

proc getLastKey(assoc: JsAssoc[cstring, ValueComponent]): cstring =
  var keys: seq[cstring] = @[]

  for key in assoc.keys:
    keys.add(key)

  result = keys[keys.len - 1]

proc calltraceText(value: cstring): Node =
  document.createTextNode(value)

proc calltraceNewElement(tag: cstring, className: cstring = cstring""): Node =
  result = document.createElement(tag)
  if className.len > 0:
    result.setAttribute(cstring"class", className)

proc setExpandedValueOffsetDom(
  depth: int,
  isLastValue: bool = false,
  backIndentCount: int = 0,
  callHasChildren: bool = false,
  callIsLastChild: bool = false,
  callIsCollapsed: bool = false,
  callIsLastElement: bool = false
): Node =
  var emptyOffsetCount = depth - 1

  if isLastValue and backIndentCount > 0:
    emptyOffsetCount -= (backIndentCount - 1)

  result = calltraceNewElement(cstring"div", cstring"call-offsets")

  if callIsLastElement:
    for i in 0..<depth:
      result.appendChild(calltraceNewElement(cstring"div", cstring"empty-offset"))
  else:
    for i in 0..<emptyOffsetCount:
      result.appendChild(calltraceNewElement(cstring"div", cstring"empty-offset"))
    if isLastValue:
      for i in 0..<backIndentCount - 1:
        result.appendChild(calltraceNewElement(
          cstring"div",
          cstring"empty-offset empty-offset-bottom-border"))
    if isLastValue and (not callHasChildren or callIsCollapsed):
      if callIsLastChild:
        result.appendChild(calltraceNewElement(
          cstring"div",
          cstring"empty-offset empty-offset-right-border empty-offset-bottom-border"))
      else:
        result.appendChild(calltraceNewElement(
          cstring"div",
          cstring"empty-offset empty-offset-right-border"))
    else:
      result.appendChild(calltraceNewElement(
        cstring"div",
        cstring"empty-offset empty-offset-right-border"))

proc updateTooltipOrigin(self: CalltraceComponent, callLine: kdom.Node) =
  if self.startPositionX != -1:
    return

  let rowRect = getBoundingClientRect(callLine.toJs)
  self.startPositionX = rowRect.left + self.scrollLeftOffset

proc syncSvgContainerBounds(svgContainer: Element, width, height: float) =
  let safeWidth = max(width, 1.0)
  let safeHeight = max(height, 1.0)

  svgContainer.setAttribute(cstring"width", cstring($safeWidth))
  svgContainer.setAttribute(cstring"height", cstring($safeHeight))
  svgContainer.setAttribute(cstring"viewBox", cstring(fmt"0 0 {safeWidth} {safeHeight}"))

proc registerSearchRes(self: CalltraceComponent, searchResults: seq[Call]) =
  let current = if self.searchText.isNil: cstring"" else: self.searchText

  self.lastSearch = now()

  if current.len > 0:
    self.searchResults = searchResults
    self.isSearching = true
    self.lastChange = self.lastSearch
  else:
    self.searchResults = @[]
    self.isSearching = false

  # Sync search results into the CalltraceVM so the IsoNim view
  # can render them in the `.call-search-results` container.
  if calltraceVMInstance != nil:
    var vmResults: seq[tuple[name: string, rrTicks: int, key: string]] = @[]
    for call in searchResults:
      vmResults.add((
        name: $call.location.highLevelFunctionName,
        rrTicks: call.location.rrTicks,
        key: $call.key,
      ))
    calltraceVMInstance.setBackendSearchResults(vmResults)

  self.redraw()

func findCall(call: Call, key: cstring): Call =
  if call.key == key:
    return call
  for child in call.children:
    let res = child.findCall(key)
    if not res.isNil:
      return res
  return nil

proc calltraceScroll(self: CalltraceComponent, height: int) =
  let calltraceElement = jqFind(cstring"#" & "calltraceScroll-" & $self.id)
  if not calltraceElement.isNil and not calltraceElement.toJs[0].isNil:
    calltraceElement.toJs[0].scrollTop = height

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# Placed before onUpdatedCalltrace / onCompleteMove so they are visible at
# the call sites without forward declarations.
# ---------------------------------------------------------------------------

proc tryMountIsoNimCalltrace() =
  ## Mount the IsoNim calltrace view into the GoldenLayout-managed
  ## calltrace component container. The container is created by
  ## GoldenLayout with the id `calltraceComponent-0`. The IsoNim view
  ## is the primary renderer — no Karax renderer is involved.
  ##
  ## After mounting:
  ## - `isoNimCalltraceMounted` is set to true
  ## - onUpdatedCalltrace / onCompleteMove still feed data into the
  ##   store, and IsoNim's reactive effects update the DOM automatically
  ##
  ## Safe to call multiple times — mounts only once.
  cerror "[PIPELINE] tryMountIsoNimCalltrace: called, isoNimCalltraceMounted=" & $isoNimCalltraceMounted & " vmIsNil=" & $calltraceVMInstance.isNil
  if isoNimCalltraceMounted or calltraceVMInstance.isNil:
    cerror "[PIPELINE] tryMountIsoNimCalltrace: skipping (already mounted or VM nil)"
    return

  # Wait for the DOM container to exist. GoldenLayout creates it when
  # the component is registered. IsoNim mounts directly into it.
  let key = cstring"calltraceComponent-0"
  var calltraceRetryCount = 0
  proc doMount() =
    if isoNimCalltraceMounted:
      return
    calltraceRetryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if calltraceRetryCount mod 10 == 0:
        cerror "[PIPELINE] tryMountIsoNimCalltrace: retry #" & $calltraceRetryCount &
          ", container=nil"
      if calltraceRetryCount > 200:
        cerror "[PIPELINE] tryMountIsoNimCalltrace: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    cerror "[PIPELINE] tryMountIsoNimCalltrace: container found, mounting now"
    isoNimCalltraceMounted = true
    mountIsoNimCalltrace(container, calltraceVMInstance)
    cerror "[PIPELINE] tryMountIsoNimCalltrace: mount COMPLETE in #calltraceComponent-0"

  doMount()

proc initCalltraceVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel CalltraceVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel
  ## which is backed by a real DapApi).
  ##
  ## If a stub-backed instance already exists (created by initCalltraceVM
  ## before the real backend was available), it is replaced so that the
  ## panel uses the real DapApi instead of the no-op stub.
  if calltraceVMInstance != nil:
    clog "CalltraceVM: replacing existing instance with shared-store version"
    # Reset the IsoNim mount flag so tryMountIsoNimCalltrace() will
    # remount the view with the new, real-backend VM instance.
    isoNimCalltraceMounted = false
  calltraceVMStore = store
  # Clear any pending calltrace request in the shared store's tracker
  # so the new VM's auto-load effect isn't deduplicated against a
  # request that was sent through the old stub backend.
  store.requestTracker.markComplete("load-calltrace")
  calltraceVMInstance = createCalltraceVM(store)
  cerror "[PIPELINE] initCalltraceVMWithStore: storeId=" & $store.storeId
  clog "CalltraceVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimCalltrace()

proc initCalltraceVM() =
  ## Lazily create the parallel CalltraceVM instance backed by a stub
  ## BackendService.  This fallback is used when no shared store has
  ## been provided via `initCalltraceVMWithStore` (e.g. in the VS Code
  ## extension where the SessionViewModel is not yet wired).
  if calltraceVMInstance != nil:
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

  calltraceVMStore = createReplayDataStore(stubBackend)
  calltraceVMInstance = createCalltraceVM(calltraceVMStore)
  cerror "[PIPELINE] initCalltraceVM (stub): storeId=" & $calltraceVMStore.storeId
  clog "CalltraceVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimCalltrace()

proc syncCalltraceData*(results: CtUpdatedCalltraceResponseBody) =
  ## Mirror the legacy calltrace section data into the ViewModel store
  ## so the CalltraceVM's visibleLines memo sees the same data.
  let diagSyncStoreId = if calltraceVMStore.isNil: -1 else: calltraceVMStore.storeId
  cerror "[PIPELINE] syncCalltraceData: CALLED storeId=" &
    $diagSyncStoreId & " lines=" & $results.callLines.len &
    " totalCalls=" & $results.totalCallsCount
  cerror fmt"[PIPELINE] syncCalltraceData: storeId={diagSyncStoreId} received {results.callLines.len} lines, totalCalls={results.totalCallsCount}, storeIsNil={calltraceVMStore.isNil}, vmIsNil={calltraceVMInstance.isNil}, isoNimMounted={isoNimCalltraceMounted}"
  if calltraceVMStore.isNil:
    cerror "[PIPELINE] syncCalltraceData: store is nil, returning early"
    return

  proc hasRenderableCall(callLine: CallLine): bool =
    not callLine.isNil and
      not callLine.content.isNil and
      not callLine.content.call.isNil

  let backendStartIndex = cast[int64](results.startCallLineIndex)
  var vmLines: seq[vm_types.CallLine] = @[]
  for i, callLine in results.callLines:
    if not hasRenderableCall(callLine):
      continue
    let call = callLine.content.call
    let loc = call.location
    # Determine children count and expand state matching the legacy call-line
    # semantics now mirrored by the IsoNim calltrace view.
    let childrenCount = callLine.content.count
    let hiddenChildren = callLine.content.hiddenChildren
    let count = if childrenCount > 0: childrenCount else: call.children.len
    let lineHasChildren = count > 0
    # A call is shown as expanded (collapse toggle visible) when it has
    # children that are not hidden, or when the call itself has loaded
    # children (call.children.len > 0).
    let lineIsExpanded = lineHasChildren and (not hiddenChildren or call.children.len > 0)
    var cl = makeCallLine(
      name = $loc.highLevelFunctionName,
      depth = callLine.depth,
      rrTicks = cast[uint64](loc.rrTicks),
      file = $loc.highLevelPath,
      line = loc.highLevelLine,
      sourceGeneration = loc.sourceGeneration,
      sourceDigest = $loc.sourceDigest,
      codeGeneration = loc.sourceGeneration,
      callstackDepth = loc.callstackDepth,
      hasChildren = lineHasChildren,
      isExpanded = lineIsExpanded,
      callKey = $call.key,
    )
    cl.index = backendStartIndex + i.int64
    vmLines.add(cl)
  # Mirror the backend's startCallLineIndex into the store so that the
  # visibleLines memo can correctly slice based on the global index.
  # Without this, after a calltrace-jump (search-result click) the
  # backend returns a section centered around the jumped-to position,
  # but the store stored startIndex=0 so the visible window kept showing
  # rows [0..24] of the section, not rows around the jumped-to function.
  # Mirror the per-call argument values into the store so the IsoNim
  # calltrace view can render one ``.call-arg`` element per arg per row
  # (matching the legacy call-argument markup that Playwright's
  # ``CallTraceEntry.arguments()`` reads). Without this, the args column
  # collapses to a static ``()`` and the ``variable inspection board via
  # call trace argument`` test fails to find the named arg.
  #
  # The args data has TWO independent sources, mirroring the lookup
  # the old Karax call-line renderer used:
  #
  #   1. ``results.args`` — a TableLike keyed by callKey, populated by
  #      the backend for callstack-loaded calls.
  #   2. ``call.args`` — embedded directly on each Call object when the
  #      call was loaded via the materialized-trace pipeline (the case
  #      for Python / Ruby DB traces, where ``results.args`` is empty
  #      but each ``CallLine.content.call.args`` carries the argument
  #      seq).
  #
  # We collect both and feed the merged table into the store; rows
  # without args entries simply render no ``.call-arg`` children.
  proc safeCallArgText(arg: CallArg): string =
    if arg.isNil:
      return ""
    if ($arg.text).len > 0:
      return $arg.text
    if arg.value.isNil:
      return ""
    case arg.value.kind:
    of Int:
      $arg.value.i
    of Float:
      $arg.value.f
    of String:
      "\"" & $arg.value.text & "\""
    of CString:
      "\"" & $arg.value.cText & "\""
    of Char:
      "'" & $arg.value.c & "'"
    of Bool:
      $arg.value.b
    of Raw:
      $arg.value.r
    of Error:
      $arg.value.msg
    of FunctionKind:
      if ($arg.value.functionLabel).len > 0:
        "function<" & $arg.value.functionLabel & ">"
      else:
        "function"
    of TypeKind.None:
      "nil"
    else:
      ""

  proc convertCallArgs(args: seq[CallArg]): seq[vm_types.CallArg] =
    result = @[]
    for arg in args:
      # Pre-rendering the text here keeps the view layer pure and avoids
      # re-evaluating recursive ``Value`` trees on every reactive update.
      let rendered = safeCallArgText(arg)
      result.add(makeCallArg($arg.name, rendered))

  var vmArgs = initTable[string, seq[vm_types.CallArg]]()
  for key, callArgs in results.args:
    vmArgs[$key] = convertCallArgs(callArgs)
  for callLine in results.callLines:
    if callLine.isNil or callLine.content.isNil:
      continue
    let call = callLine.content.call
    if call.isNil:
      continue
    let key = $call.key
    if key in vmArgs:
      continue  # response-table entry takes precedence (matches legacy lookup)
    if call.args.len == 0:
      continue
    vmArgs[key] = convertCallArgs(call.args)
  calltraceVMStore.updateCalltraceSection(
    vmLines,
    startIndex = backendStartIndex,
    totalCount = cast[uint64](results.totalCallsCount),
    args = vmArgs,
  )
  cerror fmt"[PIPELINE] syncCalltraceData: synced {vmLines.len} calltrace lines into store ({vmArgs.len} arg entries), startIndex={backendStartIndex}, scrollPosition={results.scrollPosition}"

proc syncCalltraceDebuggerPosition*(rrTicks: int, path: cstring, line: int;
                                    sourceGeneration: int = 0;
                                    sourceDigest: cstring = cstring"") =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the CalltraceVM's reactive pipeline sees the same rrTicks value.
  ##
  ## Updating `store.debugger` invalidates the CalltraceVM's auto-load
  ## effect, which then issues a `requestCalltraceSection` with the
  ## up-to-date totalCallsCount-aware window.  If the initial auto-load
  ## was dropped before DAP launch completed, seed a first section from
  ## this real complete-move position while the store is still empty.
  if calltraceVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  let diagStoreId = calltraceVMStore.storeId
  calltraceVMStore.updateDebuggerPosition(
    ticks, $path, line,
    sourceGeneration = sourceGeneration,
    sourceDigest = $sourceDigest)
  if calltraceVMStore.calltrace.lines.val.len == 0:
    # The VM can issue its first auto-load before DAP launch completes;
    # replay-server drops that request, so seed the initial section once
    # the complete-move location proves the handler is ready.
    calltraceVMStore.requestCalltraceSection(
      startIndex = 0'i64,
      height = 90,
      depth = 20,
      rrTicks = ticks,
      file = $path,
      line = line,
    )
  cerror fmt"[PIPELINE] syncCalltraceDebuggerPosition: storeId={diagStoreId} synced debugger rrTicks={ticks}"

method onUpdatedCalltrace*(self: CalltraceComponent, results: CtUpdatedCalltraceResponseBody) {.async.} =
  self.totalCallsCount = results.totalCallsCount

  # Feed the same data into the parallel ViewModel store.
  syncCalltraceData(results)

  for key, res in results.args:
    self.args[key] = res

  for key, ret in results.returnValues:
    self.returnValues[key] = ret

  for i, call in results.callLines:
    self.loadedCallKeys[call.content.call.key] = i

  self.callLines = results.callLines
  self.originalCallLines = results.callLines

  let element = document.getElementById(fmt"calltrace-toggle-loading-{self.id}")

  if element != nil:
    element.style.display = "none"

  if self.loadedCallKeys.hasKey(self.lastSelectedCallKey):
    self.activeCallIndex = results.startCallLineIndex + self.loadedCallKeys[self.lastSelectedCallKey]
    if calltraceVMInstance != nil:
      calltraceVMInstance.selectEntry(some(self.activeCallIndex.int64))

  if self.forceCollapse:
    let scrollTo = max(results.scrollPosition - 2, 0)

    if results.scrollPosition > 0:
      self.calltraceScroll(scrollTo * CALL_HEIGHT_PX)
    self.forceCollapse = false
  else:
    self.redrawCallLines()

  self.redraw()

# proc processStackFrame*(self: CalltraceComponent, index: int, frame: DapStackFrame) =
#   # TODO
#   discard

# method onUpdatedStackTrace(self: CalltraceComponent, frames: seq[DapStackFrame]) =
#   self.callLines = @[]
#   self.args = JsAssoc[cstring, seq[CallKey]]()
#   self.returnValues = JsAssoc[cstring, Value]()
#   for i, frame in self.stackFrameToCallLine:
#     self.processStackFrame(i, frame)
#   self.redrawCallLines()
#   self.redraw()

method register*(self: CalltraceComponent, api: MediatorWithSubscribers) =
  self.api = api

  # The replay session store owns the production CalltraceVM.  Creating the
  # stub-backed fallback during component registration can run reactive memos
  # before the session store has been installed, aborting startup before the
  # caption bar and Golden Layout panels finish hydrating.  The real VM is
  # installed by configureMiddleware through initCalltraceVMWithStore.
  if calltraceVMInstance != nil:
    tryMountIsoNimCalltrace()

  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtUpdatedCalltrace, proc(kind: CtEventKind, response: CtUpdatedCalltraceResponseBody, sub: Subscriber) =
    discard self.onUpdatedCalltrace(response)
  )
  api.subscribe(CtCalltraceSearchResponse, proc(kind: CtEventKind, response: seq[Call], sub: Subscriber) =
    self.registerSearchRes(response)
  )
  api.emit(InternalLastCompleteMove, EmptyArg())

proc registerCalltraceComponent*(component: CalltraceComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

proc loadLines(self: CalltraceComponent, fromScroll: bool) =
  if not self.usesMaterializedTracesTrace or not (not self.usesMaterializedTracesTrace and fromScroll) or not self.loadedCallKeys.hasKey(self.lastSelectedCallKey):
    let depth = self.panelDepth()
    let height = self.panelHeight()
    let startBuffer = self.getStartBufferLen()
    let calltraceLoadArgs = CalltraceLoadArgs(
      location: self.location,
      startCallLineIndex: self.startCallLineIndex - startBuffer,
      depth: depth,
      height: height + CALL_BUFFER + startBuffer,
      rawIgnorePatterns: self.rawIgnorePatterns,
      optimizeCollapse: true,
      autoCollapsing: not self.loadedCallKeys.hasKey(self.lastSelectedCallKey) and self.forceCollapse,
      renderCallLineIndex: 0,
    )

    echo "LOAD CALLTRACE SECTION"
    self.api.emit(CtLoadCalltraceSection, calltraceLoadArgs)

    # Also send the request via the ViewModel store's backend as a
    # fallback. The mediator path (self.api.emit) may fail if the
    # middleware subscription hasn't been set up yet (early registration).
    # The store backend uses DapApi directly, bypassing the mediator.
    if calltraceVMStore != nil:
      calltraceVMStore.requestCalltraceSection(
        startIndex = int64(self.startCallLineIndex - startBuffer),
        height = height + CALL_BUFFER + startBuffer,
        depth = depth,
        rrTicks = cast[uint64](self.location.rrTicks),
        file = $self.location.path,
        line = self.location.line,
        rawIgnorePatterns = $self.rawIgnorePatterns,
        optimizeCollapse = true,
        autoCollapsing = not self.loadedCallKeys.hasKey(self.lastSelectedCallKey) and self.forceCollapse,
      )

    self.loadedCallKeys = JsAssoc[cstring, int]{}
  else:
    cwarn "ignore"

proc scroll(self: CalltraceComponent) =
  let index = self.scrollLineIndex()
  self.startCallLineIndex = index

  # Feed the scroll position into the CalltraceVM so its auto-load
  # effect triggers a fresh requestCalltraceSection.  This replaces
  # the direct self.loadLines(fromScroll=true) call.
  if calltraceVMInstance != nil:
    calltraceVMInstance.scroll(index.int64)
  else:
    self.loadLines(fromScroll=true)

# debouncing algorithm based on
# multiple answers to https://stackoverflow.com/questions/25991367/difference-between-throttling-and-debouncing-a-function
# and made after first throttling based on
# https://johnkavanagh.co.uk/articles/throttling-scroll-events-in-javascript/
const DELAY: int64 = 100 # milliseconds

proc afterScroll(self: CalltraceComponent) =
  let currentTime: int64 = now()
  let lastTimePlusDelay = (self.lastScrollFireTime.toJs + DELAY.toJs).to(int64)

  if lastTimePlusDelay <= currentTime:
    self.scroll()

proc eventuallyScroll(self: CalltraceComponent) =
  let currentTime: int64 = now()

  self.lastScrollFireTime = currentTime

  let element = document.getElementById(fmt"calltrace-toggle-loading-{self.id}")
  if element != nil:
    element.style.display = "block"

  discard windowSetTimeout(
    proc =
      self.afterScroll(),
      cast[int](DELAY)
  )

proc setCalltraceMutationObserver(self: CalltraceComponent) =
  let calltrace = "\"" & fmt"calltrace-data-label-{self.id}" & "\""
  let activeCalltrace = jq(fmt"[data-label={calltrace}]")
  if not activeCalltrace.isNil:
    self.resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
      for entry in entries:
        let timeout = setTimeout((proc =
          let scrollPosition = jq(fmt"#calltraceScroll-{self.id}")
          self.startPositionX = -1
          self.scrollLeftOffset =
            if not scrollPosition.isNil:
              cast[float](scrollPosition.toJs.scrollLeft)
            else:
              0
          try:
            let index = self.scrollLineIndex()
            self.startCallLineIndex = index
            # Update the VM's scroll position and viewport dimensions
            # so the auto-load effect re-requests data for the new size.
            # Wrap the three writes in `batch(...)` so the autoLoad effect
            # invalidates and re-runs at most once for this resize event
            # (see the matching comment in onCompleteMove).
            if calltraceVMInstance != nil:
              let vm = calltraceVMInstance
              let viewportHeight = self.panelHeight()
              let viewportDepth = self.panelDepth()
              let scrollIndex = index.int64
              isoBatch.batch proc() =
                vm.setViewportHeight(viewportHeight)
                vm.setViewportDepth(viewportDepth)
                vm.scroll(scrollIndex)
            else:
              self.loadLines(fromScroll=false)
          except:
            cwarn "scroll or load lines exception in mutation observer: ok if in editor mode"),
          100
        )
      )
    self.resizeObserver.observe(cast[Node](activeCalltrace))

proc redrawTraceLine(self: CalltraceComponent) =
  let scrollElement = jq(cstring(fmt"#calltraceScroll-{self.id}"))
  let svgContainer = document.getElementById(fmt"svg-content-{self.id}")

  if scrollElement.isNil or svgContainer.isNil:
    return

  let localCalltraceNode = findNodeInElement(cast[kdom.Node](scrollElement), ".local-calltrace")
  if localCalltraceNode.isNil:
    return
  let localCalltraceElement = cast[Element](localCalltraceNode)

  let calltraceLinesNode = findNodeInElement(cast[kdom.Node](localCalltraceElement), ".calltrace-lines")
  if calltraceLinesNode.isNil:
    return
  let calltraceLinesElement = cast[Element](calltraceLinesNode)

  let scrollLeft = cast[float](scrollElement.toJs.scrollLeft)
  self.scrollLeftOffset = scrollLeft
  let calltraceLinesRect = calltraceLinesElement.getBoundingClientRect()
  let svgWidth = max(cast[float](scrollElement.toJs.scrollWidth), calltraceLinesRect.width + scrollLeft)
  let svgHeight = max(cast[float](calltraceLinesElement.scrollHeight), calltraceLinesRect.height)
  var coordinates: seq[tuple[x, top, center, bottom: float]] = @[]

  self.startPositionX = -1
  self.startPositionY = -1
  replaceChildren(svgContainer.toJs)
  svgContainer.syncSvgContainerBounds(svgWidth, svgHeight)

  for callLine in findAllNodesInElement(cast[kdom.Node](calltraceLinesElement), ".calltrace-call-line"):
    self.updateTooltipOrigin(callLine)

    let rowRect = getBoundingClientRect(callLine.toJs)
    var marker = findNodeInElement(callLine, CALLTRACE_MARKER_SELECTOR)
    if marker.isNil:
      marker = findNodeInElement(callLine, CALLTRACE_TOGGLE_SELECTOR)
    if marker.isNil:
      continue

    let markerRect = getBoundingClientRect(marker)
    let rowTop = rowRect.top - calltraceLinesRect.top
    let rowBottom = rowRect.bottom - calltraceLinesRect.top
    let centerY = min(max(markerRect.top + (markerRect.height / 2.0) - calltraceLinesRect.top, rowTop), rowBottom)
    let centerX = markerRect.left + (markerRect.width / 2.0) - calltraceLinesRect.left + scrollLeft

    coordinates.add((centerX, rowTop, centerY, rowBottom))

  if coordinates.len > 1:
    for i in 0..<coordinates.len:
      let (x1, top1, center1, bottom1) = coordinates[i]
      let startY = if i == 0: center1 else: top1
      let endY = if i == coordinates.high: center1 else: bottom1

      if endY > startY:
        cast[Node](svgContainer).appendChild(cast[Node](renderLineElement(x1, startY, x1, endY)))

      if i < coordinates.high:
        let (x2, _, _, _) = coordinates[i + 1]
        cast[Node](svgContainer).appendChild(cast[Node](renderLineElement(x1, bottom1, x2, bottom1)))

proc refreshTraceOverlay*(self: CalltraceComponent) =
  if self.usesMaterializedTracesTrace:
    self.redrawTraceLine()

proc redrawCallLines(self: CalltraceComponent) =
  ## Historical selection/scroll paths still call this proc, but the
  ## calltrace panel no longer has a live Karax renderer to redraw.
  ## `layout.nim` classifies `Content.Calltrace` as IsoNim-owned, and the
  ## extension build registers only an empty stub.  The real DOM is updated by
  ## `mountIsoNimCalltrace` reactive effects fed through `syncCalltraceData`.
  discard

proc changeLastCallSelection(self: CalltraceComponent) =
  self.lastSelectedCallKey = self.callsByLine[self.selectedCallNumber].call.key

proc changeCallSelection(self: CalltraceComponent, key: cstring) =
  self.selectedCallNumber = self.lineIndex[key]
  self.changeLastCallSelection()
  self.redraw()

proc getSelectedCall(self: CalltraceComponent): Call =
  self.callsByLine[self.selectedCallNumber].call

method onLeft*(self: CalltraceComponent) {.async.} =
  let call = self.getSelectedCall()

  if not call.parent.isNil:
    self.changeCallSelection(call.parent.key)

method onRight*(self: CalltraceComponent) {.async.} =
  var call: Call = self.getSelectedCall()

  if call.children.len() > 0:
    self.changeCallSelection(call.children[0].key)

method onUp*(self: CalltraceComponent) {.async.} =
  if self.activeCallIndex > 0:
    self.activeCallIndex -= 1

    if self.activeCallIndex < self.startCallLineIndex:
      self.calltraceScroll(max((self.activeCallIndex - self.panelHeight() + 1), 0) * CALL_HEIGHT_PX)
    else:
      self.redrawCallLines()

method onDown*(self: CalltraceComponent) {.async.} =
  if self.activeCallIndex < self.totalCallsCount - 1:
    self.activeCallIndex += 1

    if self.activeCallIndex >= self.startCallLineIndex + self.panelHeight() - 1:
      self.calltraceScroll(self.activeCallIndex * CALL_HEIGHT_PX)
    else:
      self.redrawCallLines()

method onEnter*(self: CalltraceComponent) {.async.} =
  let buffer = self.getStartBufferLen()

  if self.activeCallIndex - self.startCallLineIndex + buffer < self.callLines.len():
    let callIndex = self.callLines[self.activeCallIndex - self.startCallLineIndex + buffer].content.call.key

    if self.loadedCallKeys.hasKey($callIndex):
      let callLinesIndex = self.loadedCallKeys[$callIndex]

      case self.callLines[callLinesIndex].content.kind:
      of CallLineContentKind.Call:
        let call = self.callLines[callLinesIndex].content.call

        self.lastSelectedCallKey = call.key
        self.calltraceJump(call.location)

      of CallLineContentKind.CallstackInternalCount:
        let content = self.callLines[callLinesIndex].content

        self.toggleCalls(EXPAND_CALLS_KIND, content.call.key, CalltraceNonExpandedKind.CallstackInternal, content.count)
        self.loadLines(fromScroll=false)

      of CallLineContentKind.StartCallstackCount:
        let content = self.callLines[callLinesIndex].content

        self.depthStart = content.call.depth
        self.toggleCalls(EXPAND_CALLS_KIND, "0", CalltraceNonExpandedKind.Callstack, content.count)
        self.loadLines(fromScroll=false)

      of CallLineContentKind.NonExpanded:
        discard

      of CallLineContentKind.WithHiddenChildren:
        discard

      of CallLineContentKind.EndOfProgramCall:
        discard

method onPageUp*(self: CalltraceComponent) {.async.} =
  let index = max((self.startCallLineIndex - self.panelHeight()), 0)

  self.calltraceScroll(index * CALL_HEIGHT_PX)
  self.activeCallIndex = index
  self.redrawCallLines()

method onPageDown*(self: CalltraceComponent) {.async.} =
  let index = self.startCallLineIndex + self.panelHeight() - 1

  self.calltraceScroll(index * CALL_HEIGHT_PX)
  self.activeCallIndex = index
  self.redrawCallLines()

method onFocus*(self: CalltraceComponent) {.async.} =
  if self.activeCallIndex == NO_INDEX:
    self.activeCallIndex = self.startCallLineIndex
  elif self.activeCallIndex < self.startCallLineIndex or self.activeCallIndex > self.startCallLineIndex + self.panelHeight():
    self.calltraceScroll(self.activeCallIndex * CALL_HEIGHT_PX)

  self.redrawCallLines()

method onGotoStart*(self: CalltraceComponent) {.async.} =
  self.activeCallIndex = 0
  self.startCallLineIndex = self.activeCallIndex

  self.calltraceScroll(0)

method onGotoEnd*(self: CalltraceComponent) {.async.} =
  self.activeCallIndex = self.totalCallsCount - 1
  self.startCallLineIndex = self.totalCallsCount - self.panelHeight()

  self.calltraceScroll(self.activeCallIndex * CALL_HEIGHT_PX)

method onFindOrFilter*(self: CalltraceComponent) {.async.} =
  let forms = document.getElementsByClass(fmt"calltrace-search-form-{self.id}")

  if forms.len() > 0:
    let form = forms[0].Element
    let inputElement = form.getElementsByTagName("input".cstring)
    if inputElement.len() > 0:
      inputElement[0].focus()

method onCompleteMove*(self: CalltraceComponent, response: MoveState) {.async.} =
  self.location = response.location

  # Wrap every signal write that feeds the CalltraceVM's autoLoad effect
  # in a single `batch(...)`.  The autoLoad effect depends on
  # viewportHeight, viewportDepth, scrollPosition (via store), the
  # debugger position (rrTicks/file/line), and rawIgnorePatterns — without
  # batching, each individual write schedules its own autoLoad re-run,
  # producing several backend round-trips per CtCompleteMove that
  # overwrite the calltrace store mid-render and leave Playwright holding
  # stale `.calltrace-call-line` locators (the python/ruby sudoku
  # navigation regression).
  let location = response.location
  let hasVM = calltraceVMInstance != nil
  let vm = calltraceVMInstance
  let viewportHeight = self.panelHeight()
  let viewportDepth = self.panelDepth()
  let hasIgnorePatterns = hasVM and not self.rawIgnorePatterns.isNil
  let ignorePatterns = if hasIgnorePatterns: $self.rawIgnorePatterns else: ""
  isoBatch.batch proc() =
    # Mirror the debugger position into the parallel ViewModel store.
    # Triggers the CalltraceVM's auto-load effect which calls
    # store.requestCalltraceSection.  The backend will respond with
    # CtUpdatedCalltrace handled by the existing onUpdatedCalltrace
    # subscription.
    syncCalltraceDebuggerPosition(
      location.rrTicks, location.path, location.line,
      location.sourceGeneration, location.sourceDigest)
    # Sync the viewport dimensions and filter patterns to the VM so the
    # auto-load effect can include them in its request.
    if hasVM:
      vm.setViewportHeight(viewportHeight)
      vm.setViewportDepth(viewportDepth)
      if hasIgnorePatterns:
        vm.setRawIgnorePatterns(ignorePatterns)

  #TODO: pass explicitly in trace as trace kind/in init/other way?
  let lang = toLangFromFilename(self.location.path)
  if not self.usesMaterializedTracesTraceSet:
    self.usesMaterializedTracesTrace = lang != LangUnknown and lang.usesMaterializedTraces
    self.usesMaterializedTracesTraceSet = true

  # For materialized traces: if the call key is already loaded, just
  # update the active index and scroll position without re-requesting.
  echo "ON COMPLETE MOVE; is db?: ", self.usesMaterializedTracesTrace
  if self.usesMaterializedTracesTrace and self.loadedCallKeys.hasKey(response.location.key):
    self.lastSelectedCallKey = response.location.key
    let buffer = self.getStartBufferLen()

    self.activeCallIndex = self.startCallLineIndex + self.loadedCallKeys[response.location.key]

    if calltraceVMInstance != nil:
      calltraceVMInstance.selectEntry(some(self.activeCallIndex.int64))

    if self.loadedCallKeys[response.location.key] >= self.panelHeight() - 1 + buffer:
      self.calltraceScroll(((self.activeCallIndex - buffer) - (self.panelHeight() / 2).floor) * CALL_HEIGHT_PX)
  elif not self.usesMaterializedTracesTrace or not self.loadedCallKeys.hasKey(response.location.key):
    self.lastSelectedCallKey = response.location.key
    self.forceCollapse = true
    # When the IsoNim view is the active renderer, the CalltraceVM's
    # auto-load effect (in `createCalltraceVM`) is the single source of
    # truth for calltrace section requests.  It depends on
    # `store.debugger.val` so the position write above already
    # invalidates it, scheduling exactly one request with the correct
    # totalCallsCount-aware window.  The legacy `loadLines` was kept as
    # a parallel safety net but its smaller response (panelHeight +
    # CALL_BUFFER ≈ 45 lines vs the auto-load's totalCalls-aware ~100)
    # arrived after the auto-load response and clobbered the store with
    # truncated data, so Playwright's `findEntry` raced an oscillating
    # DOM during navigation tests (python/ruby sudoku — TODO 5.1(a)).
    # Skip the legacy call when the VM is wired; the legacy path is
    # only needed for the (unused) Karax-only fallback.
    if calltraceVMInstance.isNil:
      self.loadLines(fromScroll=false)
  self.redraw()

proc setContinuationLinks*(self: CalltraceComponent, links: seq[ContinuationLinkInfo]) =
  ## Called by the backend when continuation links are discovered.
  ## Builds the lookup table mapping registration GEIDs to their links
  ## so the call view can show jump icons next to await expressions.
  self.continuationLinks = links
  self.continuationsByCallKey = JsAssoc[cstring, ContinuationLinkInfo]{}
  for link in links:
    # Map the registration GEID to the link.
    # The call key format depends on the trace type;
    # for now, use the GEID as the key string.
    let key = cstring($link.registrationGEID)
    self.continuationsByCallKey[key] = link

proc setAsyncThreads*(self: CalltraceComponent, threads: seq[AsyncThreadInfo]) =
  ## Called by the backend when async thread groupings are discovered.
  self.asyncThreads = threads

# CalltraceComponent.render() removed: IsoNim is the primary renderer.
# Generic callers are expected to use direct IsoNim mount paths. All
# real rendering is handled by tryMountIsoNimCalltrace().

when defined(ctInExtension):
  method redrawForExtension*(self: CalltraceComponent) =
    self.bindCalltraceExtensionHost()

proc renderRemoveButtonDom(
  self: CallExpandedValuesComponent,
  key: cstring,
  row: Node
): Node =
  proc removeFromParent(node: Node) {.importjs: "(function(node) { if (node.parentNode) node.parentNode.removeChild(node); })(#)".}
  result = calltraceNewElement(cstring"div", cstring"remove-expanded-value")
  result.setAttribute(cstring"id", cstring(fmt"expanded-value-remove-button-{key}"))
  result.addEventListener(cstring"click", proc(ev: Event) =
    discard jsDelete(self.values[key])
    row.removeFromParent())
  result.appendChild(calltraceText(cstring"x"))

proc renderExpandedValueDom(
  self: CallExpandedValuesComponent,
  key: cstring,
  value: ValueComponent,
  isLastValue: bool = false,
  isReturnValue: bool
): Node =
  result = calltraceNewElement(cstring"div", cstring"value-expanded")
  result.appendChild(setExpandedValueOffsetDom(
    self.depth,
    isLastValue,
    self.backIndentCount,
    self.callHasChildren,
    self.callIsLastChild,
    self.callIsCollapsed,
    self.callIsLastElement))

  let valueClass =
    if isReturnValue:
      cstring"call-expanded-value return-value"
    else:
      cstring"call-expanded-value"
  let valueContainer = calltraceNewElement(cstring"div", valueClass)
  let hostId = calltraceValueDomHostId(
    cstring"call-expanded-value-dom",
    key,
    value.baseExpression)
  let host = calltraceNewElement(cstring"div", cstring"calltrace-direct-value-host")
  host.setAttribute(cstring"id", hostId)
  host.setAttribute(cstring"style", cstring"width: 100%;")
  host.appendChild(value.renderValueDom())
  valueContainer.appendChild(host)
  valueContainer.appendChild(renderRemoveButtonDom(self, key, result))
  result.appendChild(valueContainer)

proc renderCallExpandedValuesDom*(self: CallExpandedValuesComponent): Node =
  ## Build the legacy expanded call-value container directly. The rich value
  ## rows are owned by ValueComponent.renderValueDom(); this helper preserves
  ## only the calltrace-specific container, offset, and remove-button shell.
  let hasReturnValue = self.values.hasKey(returnValueName)
  var lastKey = cstring""

  result = calltraceNewElement(cstring"div", cstring"call-expanded-values-container")

  if not hasReturnValue and self.values.len > 0:
    lastKey = getLastKey(self.values)

  for key, value in self.values:
    if key == returnValueName:
      continue
    let isLastValue = key == lastKey
    result.appendChild(renderExpandedValueDom(self, key, value, isLastValue, false))

  if hasReturnValue:
    result.appendChild(renderExpandedValueDom(
      self,
      returnValueName,
      self.values[returnValueName],
      true,
      true))
