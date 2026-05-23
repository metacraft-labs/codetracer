## viewmodel/session_vm.nim
##
## SessionViewModel — top-level container that owns the shared
## ReplayDataStore and all panel ViewModels for a single replay session.
##
## The factory `createSessionVM` takes a BackendService (which may be
## backed by a real DapApi or a mock) and constructs the shared
## ReplayDataStore wired to that backend.
##
## This ensures that every panel sees the same reactive data and that
## commands sent through the store reach the real backend.
##
## The session_vm does NOT own or replace the legacy event-bus code.
## The existing UI still reads from legacy data structures.  The
## default `createSessionVM` constructor stays passive during startup:
## constructing it must not emit backend requests or mount any panel DOM.
##
## App-level owners that need a complete ViewModel graph call
## `initializePanelViewModels` explicitly after their backend and
## lifecycle wiring is ready.

import isonim/viewmodel  # for ViewModel.dispose
import backend/backend_service
import store/replay_data_store
import viewmodels/[
  state_vm,
  calltrace_vm,
  event_log_vm,
  flow_vm,
  editor_vm,
  timeline_vm,
  debug_controls_vm,
  search_vm,
  point_list_vm,
  scratchpad_vm,
  shell_vm,
]

type
  SessionViewModel* = ref object
    ## Holds all ViewModel layer objects for a single replay session.
    ## Created once per session and shared across all panels.
    store*: ReplayDataStore
    backend*: BackendService
    stateVM*: StateVM
    calltraceVM*: CalltraceVM
    eventLogVM*: EventLogVM
    flowVM*: FlowVM
    editorVM*: EditorVM
    timelineVM*: TimelineVM
    debugControlsVM*: DebugControlsVM
    searchVM*: SearchVM
    pointListVM*: PointListVM
    scratchpadVM*: ScratchpadVM
    shellVM*: ShellVM

proc createSessionVM*(backend: BackendService): SessionViewModel =
  ## Create the shared ViewModel store for a replay session.
  ##
  ## The BackendService is typically created via `newRealBackendService`
  ## (from real_backend.nim) with adapter procs that bridge to DapApi.
  ## In tests, a MockBackendService can be passed instead.
  ##
  ## All panel VMs created later share the same ReplayDataStore, so a
  ## debugger position change propagates to every panel's reactive
  ## pipeline without running panel effects before middleware wiring is
  ## complete.
  let store = createReplayDataStore(backend)

  SessionViewModel(
    store: store,
    backend: backend,
  )

proc initializePanelViewModels*(session: SessionViewModel) =
  ## Create the standard panel ViewModels for a SessionViewModel.
  ##
  ## This is intentionally separate from `createSessionVM`: several panel
  ## VMs own reactive effects that may issue backend requests, so the
  ## production startup sequence must opt in only after middleware and bridge
  ## callbacks are ready. Headless app tests use this proc to instantiate the
  ## same app-level ViewModel graph without involving DOM or legacy modules.
  if session.isNil or session.store.isNil:
    return

  if session.stateVM.isNil:
    session.stateVM = createStateVM(session.store)
  if session.calltraceVM.isNil:
    session.calltraceVM = createCalltraceVM(session.store)
  if session.eventLogVM.isNil:
    session.eventLogVM = createEventLogVM(session.store)
  if session.flowVM.isNil:
    session.flowVM = createFlowVM(session.store)
  if session.editorVM.isNil:
    session.editorVM = createEditorVM(session.store)
  if session.timelineVM.isNil:
    session.timelineVM = createTimelineVM(session.store)
  if session.debugControlsVM.isNil:
    session.debugControlsVM = createDebugControlsVM(session.store)
  if session.searchVM.isNil:
    session.searchVM = createSearchVM(session.store)
  if session.pointListVM.isNil:
    session.pointListVM = createPointListVM(session.store)
  if session.scratchpadVM.isNil:
    session.scratchpadVM = createScratchpadVM(session.store)
  if session.shellVM.isNil:
    session.shellVM = createShellVM(session.store)

proc dispose*(session: SessionViewModel) =
  ## Tear down all reactive roots.  Call this when the replay session
  ## ends to free signal graph resources.
  ##
  ## Each ViewModel's dispose proc cleans up its own reactive root.
  ## The store's dispose is called last since VMs hold references to it.
  if not session.stateVM.isNil:
    session.stateVM.dispose()
  if not session.calltraceVM.isNil:
    session.calltraceVM.dispose()
  if not session.eventLogVM.isNil:
    session.eventLogVM.dispose()
  if not session.flowVM.isNil:
    session.flowVM.dispose()
  if not session.editorVM.isNil:
    session.editorVM.dispose()
  if not session.timelineVM.isNil:
    session.timelineVM.dispose()
  if not session.debugControlsVM.isNil:
    session.debugControlsVM.dispose()
  if not session.searchVM.isNil:
    session.searchVM.dispose()
  if not session.pointListVM.isNil:
    session.pointListVM.dispose()
  if not session.scratchpadVM.isNil:
    session.scratchpadVM.dispose()
  if not session.shellVM.isNil:
    session.shellVM.dispose()
  if not session.store.isNil:
    session.store.dispose()
  if not session.backend.isNil:
    session.backend.disconnect()
