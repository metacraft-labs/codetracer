## Headless AppViewModel tests for live/replay mode transitions.

import std/[options, unittest]

import vm_test_helpers
import isonim/core/[computation, owner, signals]
import backend/mock_backend
import app/app_vm
import store/types
import store/replay_data_store
import viewmodels/[calltrace_vm, debug_controls_vm, editor_vm, event_log_vm,
                  timeline_vm]

proc makeAppWithMock(autoRespond: bool = true):
    tuple[app: AppViewModel, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let app = createAppViewModel(mock.toBackendService())
  drain()
  mock.clearReceivedCommands()
  (app, mock)

proc configureMode(app: AppViewModel; mode: DebugSessionMode) =
  app.session.store.session.val = SessionState(
    connectionStatus: csConnected,
    debugSessionMode: mode,
    lastLiveDebugSessionMode:
      (if mode in {liveMcr, liveMaterialized}: mode else: liveMcr),
    recordingHeadRRTicks: 900'u64,
    recordingHeadLoadingState: lsIdle,
  )
  app.session.store.timeline.val = TimelineState(
    minRRTicks: 0'u64,
    maxRRTicks: 900'u64,
    currentRRTicks: 900'u64,
  )
  app.session.store.debugger.val = DebuggerState(
    location: Location(file: "main.c", line: 10, column: 1),
    rrTicks: 900'u64,
    status: dsIdle,
    threadId: 1'u32,
  )
  drain()

proc commandsNamed(mock: MockBackendService; command: string):
    seq[ReceivedCommand] =
  for received in mock.receivedCommands:
    if received.command == command:
      result.add(received)

suite "AppViewModel live/replay mode transitions":

  test "event-log navigation from live mode enters historical replay":
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      app.configureMode(liveMcr)
      app.session.eventLogVM.eventRows.val = @[
        EventLogRow(eventId: 17'u64, kind: "call", line: 42, value: "hit"),
      ]

      app.session.eventLogVM.doubleClickRow(0)
      drain()

      check app.session.store.session.val.debugSessionMode == historicalFromLive
      check app.session.store.session.val.lastLiveDebugSessionMode == liveMcr
      check mock.commandsNamed("ct/event-jump").len == 1
      check app.session.editorVM.executionCursorKind.val == "historical"
      app.dispose()
      teardown()

  test "calltrace and timeline navigation preserve completed replay mode":
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      app.configureMode(completedReplay)
      app.session.store.updateCalltraceSection(@[
        CallLine(
          index: 0,
          name: "main",
          depth: 0,
          rrTicks: 120'u64,
          location: Location(file: "main.c", line: 12, column: 1),
          hasChildren: false,
          isExpanded: false,
          callKey: "main",
        )
      ], startIndex = 0'i64, totalCount = 1'u64)

      app.session.calltraceVM.doubleClickEntry(0)
      app.session.timelineVM.seek(120'u64)
      drain()

      check app.session.store.session.val.debugSessionMode == completedReplay
      check mock.commandsNamed("ct/calltrace-jump").len == 1
      check mock.commandsNamed("ct/timeline-seek").len == 1
      app.dispose()
      teardown()

  test "jump-to-live restores the original live materialized mode":
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      app.configureMode(liveMaterialized)
      app.session.timelineVM.seek(300'u64)
      drain()

      check app.session.store.session.val.debugSessionMode == historicalFromLive
      check app.session.store.session.val.lastLiveDebugSessionMode ==
        liveMaterialized
      check app.session.debugControlsVM.showJumpToLive.val

      mock.clearReceivedCommands()
      app.session.debugControlsVM.jumpToLive()
      drain()

      let restores = mock.commandsNamed(LiveRecordingRestoreAtCommand)
      check restores.len == 1
      check app.session.store.session.val.debugSessionMode == liveMaterialized
      check app.session.editorVM.executionCursorKind.val == "live-recording"
      app.dispose()
      teardown()
