## viewmodel/session_vm.nim
##
## SessionViewModel — top-level container that owns the shared
## ReplayDataStore and all panel ViewModels for a single replay session.
##
## The factory `createSessionVM` takes a BackendService (which may be
## backed by a real DapApi or a mock) and constructs:
##   1. A ReplayDataStore wired to that backend
##   2. One ViewModel per panel, all sharing the same store
##
## This ensures that every panel sees the same reactive data and that
## commands sent through the store reach the real backend.
##
## The session_vm does NOT own or replace the legacy event-bus code.
## The existing UI still reads from legacy data structures.  The
## session_vm runs in parallel so that the ViewModel reactive pipeline
## is exercised with real data from the backend.

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
  ## Create the full ViewModel layer for a replay session.
  ##
  ## The BackendService is typically created via `newRealBackendService`
  ## (from real_backend.nim) with adapter procs that bridge to DapApi.
  ## In tests, a MockBackendService can be passed instead.
  ##
  ## All panel VMs share the same ReplayDataStore, so a debugger
  ## position change propagates to every panel's reactive pipeline.
  let store = createReplayDataStore(backend)

  SessionViewModel(
    store: store,
    backend: backend,
    stateVM: createStateVM(store),
    calltraceVM: createCalltraceVM(store),
    eventLogVM: createEventLogVM(store),
    flowVM: createFlowVM(store),
    editorVM: createEditorVM(store),
    timelineVM: createTimelineVM(store),
    debugControlsVM: createDebugControlsVM(store),
    searchVM: createSearchVM(store),
    pointListVM: createPointListVM(store),
    scratchpadVM: createScratchpadVM(store),
    shellVM: createShellVM(store),
  )

proc dispose*(session: SessionViewModel) =
  ## Tear down all reactive roots.  Call this when the replay session
  ## ends to free signal graph resources.
  ##
  ## Each ViewModel's dispose proc cleans up its own reactive root.
  ## The store's dispose is called last since VMs hold references to it.
  session.stateVM.dispose()
  session.calltraceVM.dispose()
  session.eventLogVM.dispose()
  session.flowVM.dispose()
  session.editorVM.dispose()
  session.timelineVM.dispose()
  session.debugControlsVM.dispose()
  session.searchVM.dispose()
  session.pointListVM.dispose()
  session.scratchpadVM.dispose()
  session.shellVM.dispose()
  session.store.dispose()
  session.backend.disconnect()
