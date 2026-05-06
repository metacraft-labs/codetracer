## Focused M3 tests for live MCR debug controls and session-mode state.

import std/[json, unittest]

import vm_test_helpers
import isonim/core/[computation, owner, signals]
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/debug_controls_vm

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc configureSession(store: ReplayDataStore; mode: DebugSessionMode;
                      rrTicks: uint64 = 180'u64;
                      head: uint64 = 400'u64) =
  store.session.val = SessionState(
    connectionStatus: csConnected,
    debugSessionMode: mode,
    recordingHeadRRTicks: head,
    recordingHeadLoadingState: lsIdle,
  )
  store.timeline.val = TimelineState(
    minRRTicks: 0'u64,
    maxRRTicks: head,
    currentRRTicks: rrTicks,
  )
  store.debugger.val = DebuggerState(
    location: Location(file: "main.nim", line: 1, column: 1),
    rrTicks: rrTicks,
    status: dsIdle,
    threadId: 1'u32,
  )

suite "M3 Live MCR debug controls":

  test "completed replay uses existing replay step command route":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      store.configureSession(completedReplay)

      vm.invokeToolbarStep("next")
      drain()

      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == "next"
      check mock.receivedCommands[0].args["direction"].getStr == "sdForward"
      check vm.toolbarModeText.val == ""
      dispose()

  test "live MCR mode uses live backend routing for toolbar actions":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      var bridgeAction = ""
      vm.onDapStep = proc(action: cstring) =
        bridgeAction = $action
      store.configureSession(liveMcr)

      vm.invokeToolbarStep("next")
      drain()

      check bridgeAction == ""
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == LiveMcrStepCommand
      check mock.receivedCommands[0].args["action"].getStr == "next"
      check mock.receivedCommands[0].args["threadId"].getInt == 1
      check vm.toolbarModeText.val == "Live MCR"
      check not vm.canStepBackward.val
      check not vm.canReverseContinue.val

      mock.clearReceivedCommands()
      vm.invokeToolbarStep("reverse-continue")
      drain()
      check mock.receivedCommands.len == 0
      dispose()

  test "restore to history then jump to live keeps mode and head indicator consistent":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      var bridgedAction = ""
      vm.onDapStep = proc(action: cstring) =
        bridgedAction = $action
      store.configureSession(liveMcr, rrTicks = 400'u64, head = 400'u64)

      vm.restoreAt(160'u64)
      drain()

      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == LiveMcrRestoreAtCommand
      check mock.receivedCommands[0].args["rrTicks"].getBiggestInt == 160
      check store.session.val.debugSessionMode == historicalFromLive
      check store.session.val.recordingHeadRRTicks == 400'u64
      check store.debugger.val.rrTicks == 160'u64
      check store.debugger.val.status == dsIdle
      check vm.toolbarModeText.val == "Historical replay"
      check vm.recordingHeadText.val == "Head: 400"
      check vm.showJumpToLive.val
      check vm.canJumpToLive.val

      mock.clearReceivedCommands()
      vm.invokeToolbarStep("next")
      drain()

      check bridgedAction == "next"
      check mock.receivedCommands.len == 0

      mock.clearReceivedCommands()
      vm.jumpToLive()
      drain()

      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == LiveMcrRestoreAtCommand
      check mock.receivedCommands[0].args["rrTicks"].getBiggestInt == 400
      check mock.receivedCommands[0].args["jumpToLive"].getBool
      check store.session.val.debugSessionMode == liveMcr
      check store.debugger.val.rrTicks == 400'u64
      check store.debugger.val.status == dsIdle
      check vm.toolbarModeText.val == "Live MCR"
      check vm.recordingHeadText.val == "Head: 400"

      bridgedAction = ""
      mock.clearReceivedCommands()
      vm.invokeToolbarStep("next")
      drain()

      check bridgedAction == ""
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == LiveMcrStepCommand
      dispose()

  test "recording head is requested and updated through backend path":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      mock.expect(LiveMcrGetRecordingHeadCommand, %*{"rrTicks": 512})
      let store = createReplayDataStore(mock.toBackendService())
      store.configureSession(liveMcr, rrTicks = 400'u64, head = 400'u64)

      store.requestRecordingHead()
      drain()

      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == LiveMcrGetRecordingHeadCommand
      check store.session.val.recordingHeadRRTicks == 512'u64
      check store.session.val.recordingHeadLoadingState == lsIdle
      check store.timeline.val.maxRRTicks == 512'u64
      dispose()
