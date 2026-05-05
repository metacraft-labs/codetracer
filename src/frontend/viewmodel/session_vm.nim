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
## Panel ViewModels are created by their panel modules once the legacy
## startup sequence has created the expected components. This keeps
## SessionViewModel passive during startup: constructing it must not
## emit backend requests or mount any panel DOM.

import isonim/viewmodel  # for ViewModel.dispose
import backend/backend_service
import store/[replay_data_store, types]
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
