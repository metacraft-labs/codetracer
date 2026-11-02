import
  ui_imports, session_viewmodels, colors, typetraits, strutils, base64,
  ../[ types, communication ],
  ../../common/ct_event

# ---------------------------------------------------------------------------
# The pane is the generic view (`viewmodel/views/isonim_terminal_output_view`)
# over the session's `TerminalOutputVM`. The panel host (`ui/panel_host`)
# mounts it and reports the lines it shows; the ViewModel loads those lines by
# window and follows the store's position, so the component subscribes to
# nothing.
# ---------------------------------------------------------------------------

import std/json
from std/options import isSome, get
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  TerminalLine, TerminalEventFragment, TerminalOutputEvent
from ../viewmodel/viewmodels/terminal_output_vm import
  TerminalOutputVM, createTerminalOutputVM, setEvents, clearLines,
  setCurrentRRTicks, setRecordingKey, recordingKeyOf, viewMemoryFromJson,
  viewMemoryToJson, windowed, heldLine, jumpToEvent,
  TerminalView
import std/tables
import isonim/core/signals
from isonim/web/dom_api import nil

# PLAT-52: no `ansi_up` here any more. A program's output reaches the DOM as
# text nodes (`textContent`) inside spans whose style comes from the decoded
# SGR attributes, so there is no markup to escape — see
# `viewmodel/views/isonim_terminal_output_view`.

# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls. Mirrors
# the pattern used by the event-log and calltrace migrations.
var terminalOutputVMInstance: TerminalOutputVM
  ## The SHOWN tab's TerminalOutputVM; a component's handlers act on their
  ## own tab's (`paneVM`).
var terminalOutputVMStore: ReplayDataStore

proc paneVM(self: TerminalOutputComponent): TerminalOutputVM =
  ## The TerminalOutputVM of the tab that holds `self` (`ownPaneVM`).
  ownPaneVM(self, terminalOutputVMInstance, terminalOutputVM)

proc rememberTerminalViews(vm: TerminalOutputVM; data: Data)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initTerminalOutputVMFromSession*(vm: TerminalOutputVM) =
  ## Hand the pane the session's `TerminalOutputVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ##
  ## If a stub-backed instance already exists (created before the session
  ## was available), it is replaced so the panel uses the real backend.
  terminalOutputVMStore = vm.store
  terminalOutputVMInstance = vm
  rememberTerminalViews(vm, data)


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

proc rememberTerminalViews(vm: TerminalOutputVM; data: Data) =
  ## Key the view choice (lines / screen) by the recording, seeded from what
  ## this browser remembered, and remember every later choice. Before the
  ## pane's first lines arrive, which pick the view.
  if vm.isNil or vm.recordingKey.len > 0:
    return
  let recordingKey =
    if data.isNil or data.trace.isNil: ""
    else: recordingKeyOf(data.trace.outputFolder)
  # A recording without an output folder (one made in a browser tab) has no
  # key to remember a view choice under; the choice still applies, unfiled.
  if recordingKey.len == 0:
    return
  vm.setRecordingKey(
    recordingKey,
    viewMemoryFromJson($readTerminalViews(cstring(TerminalViewsStorageKey))))
  vm.onViewChosen =
    proc(memory: Table[string, TerminalView]) =
      writeTerminalViews(cstring(TerminalViewsStorageKey),
                         cstring(viewMemoryToJson(memory)))

proc syncTerminalOutputVM(self: TerminalOutputComponent) =
  ## Hand the recorded writes to the ``TerminalOutputVM``, the recording's
  ## remembered view choice first — where the ViewModel does not load its
  ## own lines. A ViewModel the engine serves by line window loads its writes
  ## itself, when its screen view is shown.
  let vm = self.paneVM()
  if vm.isNil or vm.windowed:
    return
  rememberTerminalViews(vm, self.data)
  vm.setEvents(terminalOutputEventsOf(self.cachedEvents))

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
  let vm = self.paneVM()
  if vm.isNil:
    return
  let line = vm.heldLine(response)
  if line.isSome and line.get.fragments.len > 0:
    vm.jumpToEvent(line.get.fragments[0].eventIndex)

method restart*(self: TerminalOutputComponent) =
  self.cachedLines = JsAssoc[int, seq[TerminalEvent]]{}
  self.cachedEvents = @[]
  self.lineEventIndices = JsAssoc[int, int]{}
  self.currentLine = 0
  self.initialUpdate = true
  self.renderedEventIndex = 0
  self.location = types.Location()
  # This tab's own lines only: a trace loaded into one tab restarts that
  # tab's components, and must not clear what another tab shows.
  let vm = self.paneVM()
  if not vm.isNil:
    vm.clearLines()

# TerminalOutputComponent.render() removed: IsoNim is the primary
# renderer.  Generic callers are expected to use direct IsoNim mount
# paths; all real DOM construction happens in
# ``viewmodel/views/isonim_terminal_output_view.nim``.


method register*(self: TerminalOutputComponent, api: MediatorWithSubscribers) =
  ## The pane subscribes to nothing (see the module header).
  self.api = api
