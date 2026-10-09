import
  ui_imports, colors, typetraits, strutils, base64,
  ../[ types, communication ],
  ../../common/ct_event

# ---------------------------------------------------------------------------
# ViewModel layer — IsoNim is the primary renderer.
#
# The legacy Karax `method render` was dropped in favour of an IsoNim
# view (`viewmodel/views/isonim_terminal_output_view.nim`) that mounts
# directly into the GoldenLayout container. The legacy
# `TerminalOutputComponent` retains its event-bus subscriptions so the
# frontend's existing wiring (CtLoadedTerminal, CtUpdatedEvents,
# CtCompleteMove) keeps feeding data; the component now mirrors every
# update into a `TerminalOutputVM` whose signals drive the IsoNim view.
# ---------------------------------------------------------------------------

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  TerminalLine, TerminalEventFragment, TerminalOutputEvent
from ../viewmodel/viewmodels/terminal_output_vm import
  TerminalOutputVM, createTerminalOutputVM, setEvents, clearLines,
  setCurrentRRTicks, setRecordingKey, recordingKeyOf, viewMemoryFromJson,
  viewMemoryToJson,
  TerminalView
import std/tables
import isonim/core/signals
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_terminal_output_view import
  mountIsoNimTerminalOutput

# PLAT-52: no `ansi_up` here any more. A program's output reaches the DOM as
# text nodes (`textContent`) inside spans whose style comes from the decoded
# SGR attributes, so there is no markup to escape — see
# `viewmodel/views/isonim_terminal_output_view`.

# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls. Mirrors
# the pattern used by the event-log and calltrace migrations.
var terminalOutputVMInstance: TerminalOutputVM
var terminalOutputVMStore: ReplayDataStore
var terminalOutputComponentRef: TerminalOutputComponent
var isoNimTerminalOutputMounted*: bool = false

proc tryMountIsoNimTerminalOutputPanel*()

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initTerminalOutputVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel ``TerminalOutputVM`` using an externally
  ## provided ``ReplayDataStore`` (typically the shared store from
  ## ``SessionViewModel``). If a stub-backed instance already exists
  ## (created by ``initTerminalOutputVM`` before the real backend was
  ## available) it is replaced so the panel uses the real backend.
  if terminalOutputVMInstance != nil:
    clog "TerminalOutputVM: replacing existing instance with shared-store version"
    isoNimTerminalOutputMounted = false
  terminalOutputVMStore = store
  terminalOutputVMInstance = createTerminalOutputVM(store)
  clog "TerminalOutputVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimTerminalOutputPanel()

proc initTerminalOutputVM() =
  ## Lazily create the parallel ``TerminalOutputVM`` backed by a stub
  ## ``BackendService``. Fallback when no shared store has been
  ## provided via ``initTerminalOutputVMWithStore``.
  if terminalOutputVMInstance != nil:
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

  terminalOutputVMStore = createReplayDataStore(stubBackend)
  terminalOutputVMInstance = createTerminalOutputVM(terminalOutputVMStore)
  clog "TerminalOutputVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimTerminalOutputPanel()

proc tryMountIsoNimTerminalOutputPanel*() =
  ## Mount the IsoNim terminal-output view into the GoldenLayout-managed
  ## container. The container is created by GoldenLayout under the id
  ## ``terminalComponent-{id}`` (note the truncation — the default
  ## layout JSON in ``src/config/default_layout.json`` and the
  ## Playwright page object ``terminal-output-pane.ts`` both use the
  ## ``terminalComponent`` prefix rather than the
  ## ``convertComponentLabel`` ``terminalOutputComponent`` form).
  ## The terminal panel is a singleton (id always 0) but we still
  ## resolve through the registered component's id field for symmetry
  ## with the other IsoNim mounts.
  ##
  ## Safe to call multiple times — mounts only once. The retry loop
  ## handles GoldenLayout's asynchronous container creation: the
  ## container appears slightly after the layout state changes so we
  ## back off and retry until it lands (capped at 200 attempts, ~2 s).
  if isoNimTerminalOutputMounted or terminalOutputVMInstance.isNil:
    return
  if terminalOutputComponentRef.isNil:
    return

  let key = cstring("terminalComponent-" & $terminalOutputComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimTerminalOutputMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimTerminalOutputPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    # Replace any prior content (Karax may have planted a stub element
    # before the IsoNim mount fires).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimTerminalOutputMounted = true
    try:
      mountIsoNimTerminalOutput(container, terminalOutputVMInstance)
    except:
      cerror "tryMountIsoNimTerminalOutputPanel: mount EXCEPTION: " & getCurrentExceptionMsg()

  doMount()

# ---------------------------------------------------------------------------
# The recorded writes, handed to the shared model.
#
# PLAT-52: the line cache this module built with `ansi_up` (HTML `<span>`
# runs, split on newlines with a regular expression) is gone. The writes go
# to `TerminalOutputVM.setEvents`, and the shared model
# (`viewmodel/viewmodels/terminal_output_model`) splits them into lines of
# fragments carrying their text and decoded SGR attributes — the same lines
# the terminal and GPUI front-ends draw. The desktop's view builds its spans
# from those attributes (`isonim_terminal_output_view`).
# ---------------------------------------------------------------------------

when defined(ctInExtension):
  var terminalOutputComponentForExtension* {.exportc.}: TerminalOutputComponent

  proc bindTerminalOutputExtensionHost(component: TerminalOutputComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    # Mount the IsoNim terminal-output panel into the container the extension
    # webview provides.  tryMountIsoNimTerminalOutputPanel is idempotent.
    tryMountIsoNimTerminalOutputPanel()

  proc makeTerminalOutputComponentForExtension*(id: cstring): TerminalOutputComponent {.exportc.} =
    if terminalOutputComponentForExtension.isNil:
      if data.sessions.len == 0:
        return
      terminalOutputComponentForExtension = makeTerminalOutputComponent(data, 0, inExtension = true)
    if terminalOutputComponentForExtension.extensionRendererId.len == 0:
      terminalOutputComponentForExtension.extensionRendererId = id
      terminalOutputComponentForExtension.bindTerminalOutputExtensionHost()
    result = terminalOutputComponentForExtension

proc getLines(self: TerminalOutputComponent) =
  self.api.emit(CtLoadTerminal, EmptyArg())

proc terminalOutputEventsOf*(eventList: seq[ProgramEvent]):
    seq[TerminalOutputEvent] =
  ## The recorded writes as the shared model takes them.
  for i, event in eventList:
    let content =
      if event.base64Encoded:
        decode($event.content)
      else:
        $event.content
    result.add TerminalOutputEvent(
      content: content,
      rrTicks: cast[uint64](event.directLocationRRTicks),
      eventIndex: i,
      logIndex: event.eventIndex,
      path: $event.highLevelPath,
      line: event.highLevelLine,
      stdout: event.stdout)

const TerminalViewsStorageKey = "codetracer.terminalViews"
  ## Where the view the user chose for each recording (lines / screen) is
  ## remembered (Terminal-Output-Pane.md §3), as the native front-ends keep it
  ## in their state directory (`native_state.terminalViewsPath`).

proc readTerminalViews(key: cstring): cstring {.importjs: """
  (function(k) {
    try {
      if (typeof localStorage === 'undefined' || localStorage === null) return '';
      var v = localStorage.getItem(k);
      return (v === null || v === undefined) ? '' : v;
    } catch (e) { return ''; }
  })(#)""".}

proc writeTerminalViews(key, value: cstring) {.importjs: """
  (function(k, v) {
    try {
      if (typeof localStorage === 'undefined' || localStorage === null) return;
      localStorage.setItem(k, v);
    } catch (e) { }
  })(#, #)""".}

proc syncTerminalOutputVM(self: TerminalOutputComponent) =
  ## Hand the recorded writes to the ``TerminalOutputVM``, the recording's
  ## remembered view choice first.
  if terminalOutputVMInstance.isNil:
    return
  let recordingKey =
    if self.data.isNil or self.data.trace.isNil: ""
    else: recordingKeyOf(self.data.trace.outputFolder)
  # A recording without an output folder (one made in a browser tab) has no
  # key to remember a view choice under; the choice still applies, unfiled.
  if terminalOutputVMInstance.recordingKey.len == 0 and recordingKey.len > 0:
    terminalOutputVMInstance.setRecordingKey(
      recordingKey,
      viewMemoryFromJson($readTerminalViews(cstring(TerminalViewsStorageKey))))
    terminalOutputVMInstance.onViewChosen =
      proc(memory: Table[string, TerminalView]) =
        writeTerminalViews(cstring(TerminalViewsStorageKey),
                           cstring(viewMemoryToJson(memory)))
  terminalOutputVMInstance.setEvents(terminalOutputEventsOf(self.cachedEvents))

proc syncTerminalOutputDebuggerPosition(rrTicks: int) =
  ## Mirror the debugger's rrTicks into the VM's ``currentRRTicks``
  ## signal. Triggers the IsoNim view's per-fragment colour effect so
  ## past/active/future classes track the user's position.
  ##
  ## NOTE: We do NOT call terminalOutputVMStore.updateDebuggerPosition here.
  ## When the shared store is active, terminalOutputVMStore IS the same object
  ## as calltraceVMStore / stateVMStore. Calling updateDebuggerPosition with
  ## file="" would overwrite the real file/line written by syncCalltraceDebuggerPosition
  ## and syncStoreDebuggerPosition, firing the calltrace/state reactive effects
  ## with an empty position and causing repeated spurious loads (CPU spin).
  ## The createEffect in terminal_output_vm.nim already mirrors rrTicks from
  ## store.debugger.val automatically; setCurrentRRTicks is a direct update as
  ## a belt-and-suspenders path for the stub-backed case.
  if terminalOutputVMInstance.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  terminalOutputVMInstance.setCurrentRRTicks(ticks)

# ---------------------------------------------------------------------------
# Component event handlers
# ---------------------------------------------------------------------------

method onLoadedTerminal*(self: TerminalOutputComponent, eventList: seq[ProgramEvent]) {.async.} =
  self.initialUpdate = false
  self.cachedEvents = eventList
  self.syncTerminalOutputVM()


proc onTerminalEventClick(self: TerminalOutputComponent, eventElement: ProgramEvent) =
  self.api.emit(CtEventJump, eventElement)
  self.api.emit(InternalNewOperation, NewOperation(name: "event jump", stableBusy: true))

method onOutputJumpFromShellUi*(self: TerminalOutputComponent, response: int) {.async.} =
  ## The shell asks for line `response`: go to the write that started it.
  if terminalOutputVMInstance.isNil:
    return
  let lines = terminalOutputVMInstance.lines.val
  if response >= 0 and response < lines.len and
     lines[response].fragments.len > 0:
    let index = lines[response].fragments[0].eventIndex
    if index >= 0 and index < self.cachedEvents.len:
      self.onTerminalEventClick(self.cachedEvents[index])

method restart*(self: TerminalOutputComponent) =
  self.cachedLines = JsAssoc[int, seq[TerminalEvent]]{}
  self.cachedEvents = @[]
  self.lineEventIndices = JsAssoc[int, int]{}
  self.currentLine = 0
  self.initialUpdate = true
  self.renderedEventIndex = 0
  self.location = types.Location()
  if not terminalOutputVMInstance.isNil:
    terminalOutputVMInstance.clearLines()

# TerminalOutputComponent.render() removed: IsoNim is the primary
# renderer.  Generic callers are expected to use direct IsoNim mount
# paths; all real DOM construction happens in
# ``viewmodel/views/isonim_terminal_output_view.nim``.

when defined(ctInExtension):
  method redrawForExtension*(self: TerminalOutputComponent) =
    self.bindTerminalOutputExtensionHost()

method register*(self: TerminalOutputComponent, api: MediatorWithSubscribers) =
  self.api = api

  # Lazily create the VM and remember the component so the IsoNim
  # mount procedure can find both. ``initTerminalOutputVM`` is a no-op
  # if a shared-store instance was already installed by
  # ``configureMiddleware``.
  initTerminalOutputVM()
  if terminalOutputComponentRef.isNil:
    terminalOutputComponentRef = self
    tryMountIsoNimTerminalOutputPanel()

  api.subscribe(CtLoadedTerminal, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    discard self.onLoadedTerminal(response)
  )
  api.subscribe(CtUpdatedEvents, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    if self.initialUpdate:
      self.getLines()
      self.initialUpdate = false
  )
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    self.location = response.location
    syncTerminalOutputDebuggerPosition(response.location.rrTicks)
  )
  api.emit(InternalLastCompleteMove, EmptyArg())

# think if it's possible to directly exportc in this way the method
proc registerTerminalOutputComponent*(component: TerminalOutputComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
