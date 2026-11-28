## The value origin works in a session of several recordings after the
## process tree switches to another recording.
##
## A session made of several recordings (a `session.toml`: frontend-js,
## frontend-wasm, backend) keeps one StateVM per recording, and a switch
## (`SessionViewModel.onSwitchProcess`) makes the switched-to recording's
## VM `session.stateVM`. The hosts reach the value origin through that VM:
## the WebAssembly core's "Show in side panel" arrives at the page as
## `session.stateVM.onShowOriginProc` (`ui/panel_host`). The per-recording
## VMs were built without the origin bridges, so after switching to the
## backend recording the press did nothing and the side panel never opened
## (`cross-process/origin-spans-three-recordings`, step 20).
##
## Real: `createSessionVM` and `initializePanelViewModels`,
## `applyListProcessesResponse`,
## `onSwitchProcess`, `attachOriginChainVM` and the bridges
## (`origin_chain_bridges.wireOriginChainBridges`), wired as the hosts wire
## them. The one stand-in is the engine: `MockBackendService`, which
## records the `ct/originChain` request instead of answering it from a
## replay. What is asserted is what happens before any answer: the press
## reaches the session's OriginChainVM, the side panel opens and the
## request goes out.
##
## Compile + run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_switched_recording_origin.nim

import std/[json, options, unittest]

import isonim/core/[async_compat, owner, signals]

import ../../backend/mock_backend
import ../../session_vm
import ../../store/types
import ../../viewmodels/[origin_chain_bridges, origin_chain_vm,
                         scratchpad_vm, state_vm]

const ThreeRecordings = """
{"processes": [
  {"recordingId": "fe-js", "role": "frontend-js", "displayName": "frontend",
   "defaultThreadPrefix": "fe", "threadCount": 1, "threadIds": [1]},
  {"recordingId": "fe-wasm", "role": "frontend-wasm",
   "displayName": "frontend-wasm", "defaultThreadPrefix": "wasm",
   "threadCount": 1, "threadIds": [2]},
  {"recordingId": "be", "role": "backend", "displayName": "backend",
   "defaultThreadPrefix": "be", "threadCount": 1, "threadIds": [3]}
]}
"""

proc attachOrigin(session: SessionViewModel) =
  ## As `ui/state.createSessionOriginChainVM` and the VS Code host do: the
  ## session's StateVM gets the bridges, then the OriginChainVM is attached.
  let origin = createOriginChainVM(session.store)
  let s = session
  wireOriginChainBridges(session.stateVM, origin,
    proc(): ScratchpadVM = s.scratchpadVM)
  session.attachOriginChainVM(origin)

proc showOriginReachesTheSidePanel(session: SessionViewModel;
                                   mock: MockBackendService) =
  let vm = session.stateVM
  check not vm.isNil
  check not vm.onShowOriginProc.isNil
  if vm.isNil or vm.onShowOriginProc.isNil:
    return
  mock.clearReceivedCommands()
  vm.onShowOriginProc("balance", Location(file: "backend/server.js", line: 72))
  drainPlatformCallbacks()
  check session.originChainVM.sidePanelOpen.val
  check session.originChainVM.breadcrumbStack.val.len == 1
  check mock.findCommand("ct/originChain").isSome

suite "the value origin after a process switch":
  test "Show in side panel on the switched-to recording opens the side panel":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      session.initializePanelViewModels()
      session.attachOrigin()
      session.applyListProcessesResponse(parseJson(ThreeRecordings))
      check session.activeProcessRecordingId.val == "fe-js"
      session.onSwitchProcess("be")
      check session.activeProcessRecordingId.val == "be"
      showOriginReachesTheSidePanel(session, mock)
      dispose()

  test "a recording the tree lists after the origin is attached is wired too":
    # The other order: the process tree's reply arrives first, the
    # OriginChainVM is attached after it.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      session.initializePanelViewModels()
      session.applyListProcessesResponse(parseJson(ThreeRecordings))
      session.attachOrigin()
      session.onSwitchProcess("fe-wasm")
      showOriginReachesTheSidePanel(session, mock)
      dispose()
