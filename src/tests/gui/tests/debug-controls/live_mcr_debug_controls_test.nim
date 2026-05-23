## Focused M3 tests for live MCR debug controls and session-mode state.

import std/[json, unittest]

import vm_test_helpers
import isonim/core/[computation, owner, signals]
import backend/mock_backend
import app/app_vm
import store/types
import store/replay_data_store
import viewmodels/debug_controls_vm

proc makeAppWithMock(autoRespond: bool = true):
    tuple[app: AppViewModel, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let app = createAppViewModel(mock.toBackendService())
  drain()
  mock.clearReceivedCommands()
  (app, mock)

proc configureSession(app: AppViewModel; mode: DebugSessionMode;
                      rrTicks: uint64 = 180'u64;
                      head: uint64 = 400'u64) =
  let store = app.session.store
  store.session.val = SessionState(
    connectionStatus: csConnected,
    debugSessionMode: mode,
    lastLiveDebugSessionMode:
      (if mode in {liveMcr, liveMaterialized}: mode else: completedReplay),
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
  drain()

proc commandsNamed(mock: MockBackendService; command: string):
    seq[ReceivedCommand] =
  for received in mock.receivedCommands:
    if received.command == command:
      result.add(received)

suite "M3 Live MCR debug controls":

  test "completed replay uses existing replay step command route":
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      let vm = app.session.debugControlsVM
      app.configureSession(completedReplay)
      mock.clearReceivedCommands()

      vm.invokeToolbarStep("next")
      drain()

      let nextCommands = mock.commandsNamed("next")
      check nextCommands.len == 1
      if nextCommands.len == 1:
        check nextCommands[0].args["direction"].getStr == "sdForward"
      check mock.commandsNamed(LiveMcrStepCommand).len == 0
      check vm.toolbarModeText.val == ""
      app.dispose()
      teardown()

  test "live MCR mode uses live backend routing for toolbar actions":
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      let vm = app.session.debugControlsVM
      var bridgeAction = ""
      vm.onDapStep = proc(action: cstring) =
        bridgeAction = $action
      app.configureSession(liveMcr)
      mock.clearReceivedCommands()

      vm.invokeToolbarStep("next")
      drain()

      check bridgeAction == ""
      let liveSteps = mock.commandsNamed(LiveMcrStepCommand)
      check liveSteps.len == 1
      if liveSteps.len == 1:
        check liveSteps[0].args["action"].getStr == "next"
        check liveSteps[0].args["threadId"].getInt == 1
      check mock.commandsNamed("next").len == 0
      check vm.toolbarModeText.val == "Live MCR"
      check vm.showRecordingHead.val
      check not vm.showJumpToLive.val
      check not vm.canStepBackward.val
      check not vm.canReverseContinue.val

      mock.clearReceivedCommands()
      vm.invokeToolbarStep("reverse-continue")
      drain()
      check mock.commandsNamed(LiveMcrStepCommand).len == 0
      check mock.commandsNamed("reverseContinue").len == 0
      app.dispose()
      teardown()

  test "restore to history then jump to live keeps mode and head indicator consistent":
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      let store = app.session.store
      let vm = app.session.debugControlsVM
      var bridgedAction = ""
      vm.onDapStep = proc(action: cstring) =
        bridgedAction = $action
      app.configureSession(liveMcr, rrTicks = 400'u64, head = 400'u64)
      mock.clearReceivedCommands()

      vm.restoreAt(160'u64)
      drain()

      let restoreCommands = mock.commandsNamed(LiveMcrRestoreAtCommand)
      check restoreCommands.len == 1
      if restoreCommands.len == 1:
        check restoreCommands[0].args["rrTicks"].getBiggestInt == 160
      check store.session.val.debugSessionMode == historicalFromLive
      check store.session.val.recordingHeadRRTicks == 400'u64
      check store.debugger.val.rrTicks == 160'u64
      check store.debugger.val.status == dsIdle
      check vm.toolbarModeText.val == "Historical replay"
      check vm.recordingHeadText.val == "Head: 400"
      check vm.showRecordingHead.val
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

      let jumpCommands = mock.commandsNamed(LiveMcrRestoreAtCommand)
      check jumpCommands.len == 1
      if jumpCommands.len == 1:
        check jumpCommands[0].args["rrTicks"].getBiggestInt == 400
        check jumpCommands[0].args["jumpToLive"].getBool
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
      let liveStepCommands = mock.commandsNamed(LiveMcrStepCommand)
      check liveStepCommands.len == 1
      app.dispose()
      teardown()

  test "recording head is requested and updated through backend path":
    createRoot proc(teardown: proc()) =
      let mock = newMockBackendService()
      mock.expect(LiveMcrGetRecordingHeadCommand, %*{"rrTicks": 512})
      let app = createAppViewModel(mock.toBackendService())
      let store = app.session.store
      app.configureSession(liveMcr, rrTicks = 400'u64, head = 400'u64)
      mock.clearReceivedCommands()

      store.requestRecordingHead()
      drain()

      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == LiveMcrGetRecordingHeadCommand
      check store.session.val.recordingHeadRRTicks == 512'u64
      check store.session.val.recordingHeadLoadingState == lsIdle
      check store.timeline.val.maxRRTicks == 512'u64
      app.dispose()
      teardown()
