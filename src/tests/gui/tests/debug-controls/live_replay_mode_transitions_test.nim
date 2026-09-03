## Headless AppViewModel tests for live/replay mode transitions.

import std/[json, options, unittest]

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

  test "calltrace navigation from live mode enters historical replay":
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      app.configureMode(liveMcr)
      app.session.store.updateCalltraceSection(@[
        CallLine(
          index: 0,
          name: "reprobuild_hcr_patchable_value",
          depth: 0,
          rrTicks: 120'u64,
          location: Location(
            file: "patchable.c",
            line: 41,
            column: 1,
            sourceGeneration: 0,
            sourceDigest: "generation-0",
          ),
          codeGeneration: 0,
          hasChildren: false,
          isExpanded: false,
          callKey: "patchable:generation-0",
        )
      ], startIndex = 0'i64, totalCount = 1'u64)

      app.session.calltraceVM.doubleClickEntry(0)
      drain()

      let jumps = mock.commandsNamed("ct/calltrace-jump")
      check app.session.store.session.val.debugSessionMode == historicalFromLive
      check app.session.editorVM.executionCursorKind.val == "historical"
      check jumps.len == 1
      if jumps.len == 1:
        check jumps[0].args["rrTicks"].getBiggestInt == 120
        check jumps[0].args["path"].getStr == "patchable.c"
        check jumps[0].args["line"].getInt == 41
        check jumps[0].args["sourceGeneration"].getInt == 0
        check jumps[0].args["sourceDigest"].getStr == "generation-0"
        check jumps[0].args["codeGeneration"].getInt == 0
      app.dispose()
      teardown()

  test "timeline navigation from live MCR enters historical replay":
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      app.configureMode(liveMcr)

      app.session.timelineVM.seek(120'u64)
      drain()

      let restores = mock.commandsNamed(LiveMcrRestoreAtCommand)
      check app.session.store.session.val.debugSessionMode == historicalFromLive
      check app.session.editorVM.executionCursorKind.val == "historical"
      check app.session.debugControlsVM.showJumpToLive.val
      check restores.len == 1
      if restores.len == 1:
        check restores[0].args["rrTicks"].getBiggestInt == 120
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

  test "a replay selected into a tab that held a live session is a replay again":
    # THE DEFECT THIS PINS. `ui_js.handleDapLiveSessionSelected` announces
    # `liveMcr` to the store; `handleDapReplaySelected` announced nothing and
    # relied on `completedReplay` being the enum's zero value. That holds for a
    # fresh store and fails for a REUSED TAB — and *Stop* makes reusing a tab
    # the specified flow: it ends the debugging session and leaves the tab open
    # so a new one can be started in it.
    #
    # Left at `liveMcr`, an ordinary replay loses its whole reverse half, and
    # for two independent reasons. Both are asserted below, because fixing one
    # would leave the controls grey-but-live or live-but-enabled.
    createRoot proc(teardown: proc()) =
      let (app, mock) = makeAppWithMock()
      app.configureMode(liveMcr)

      # The premise: while the tab holds a live MCR session, backward
      # navigation is genuinely unavailable and the toolbar routes to the live
      # command. If this stopped being true the recovery below would prove
      # nothing.
      echo "live: canStepBackward=", app.session.debugControlsVM.canStepBackward.val,
        " canReverseContinue=", app.session.debugControlsVM.canReverseContinue.val
      check not app.session.debugControlsVM.canStepBackward.val
      check not app.session.debugControlsVM.canReverseContinue.val

      mock.clearReceivedCommands()
      app.session.debugControlsVM.invokeToolbarStep("next")
      drain()
      let liveSteps = mock.commandsNamed(LiveMcrStepCommand).len
      echo "live: ct/mcr-live-step commands=", liveSteps
      check liveSteps == 1

      # The transition the replay-selected path must announce.
      app.session.store.enterCompletedReplayMode()
      drain()

      echo "after: debugSessionMode=", app.session.store.session.val.debugSessionMode,
        " lastLive=", app.session.store.session.val.lastLiveDebugSessionMode,
        " canStepBackward=", app.session.debugControlsVM.canStepBackward.val,
        " canReverseContinue=", app.session.debugControlsVM.canReverseContinue.val
      check app.session.store.session.val.debugSessionMode == completedReplay
      # The reverse controls come back. This is the user-visible half: without
      # it, reverse step over / in / out and reverse continue are all greyed
      # out on a replay that fully supports them.
      check app.session.debugControlsVM.canStepBackward.val
      check app.session.debugControlsVM.canReverseContinue.val

      # And the toolbar stops routing to the live command. Enablement alone is
      # not enough: `liveToolbarActionAllowed` admits only the four forward
      # actions, so a mode left live makes the reverse buttons dead as well as
      # grey.
      mock.clearReceivedCommands()
      app.session.debugControlsVM.invokeToolbarStep("next")
      drain()
      let stillLive = mock.commandsNamed(LiveMcrStepCommand).len
      echo "after: ct/mcr-live-step commands=", stillLive
      check stillLive == 0

      # No live head is remembered, so nothing offers a jump back to a
      # recording head belonging to a program that is no longer running.
      check app.session.store.session.val.lastLiveDebugSessionMode ==
        completedReplay
      check not app.session.debugControlsVM.showJumpToLive.val
      check not app.session.debugControlsVM.showRecordingHead.val
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
