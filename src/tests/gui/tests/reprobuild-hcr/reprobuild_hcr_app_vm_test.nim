## Headless app-ViewModel coverage for the Reprobuild HCR debugging flow.
##
## The db-backend gate owns the process-level proof: editor-like file edits,
## `repro watch`, live debugserver/LLDB, recording, and replay. This test pins
## how the CodeTracer app ViewModel represents the same transcript once the
## backend reports the live/replay positions.

import std/[json, sequtils, strutils, unittest]

import vm_test_helpers
import isonim/core/[computation, owner, signals]
import backend/mock_backend
import app/app_vm
import store/[replay_data_store, types]
import viewmodels/[calltrace_vm, debug_controls_vm]

const
  PatchableFunction = "reprobuild_hcr_patchable_value"
  PatchableSource = "src/patchable.c"
  Gen0Breakpoint = "REPROBUILD_HCR_GEN0_BREAKPOINT"
  Gen0StepStart = "REPROBUILD_HCR_GEN0_STEP_START"
  Gen0StepNext = "REPROBUILD_HCR_GEN0_STEP_NEXT"
  Gen1Breakpoint = "REPROBUILD_HCR_GEN1_BREAKPOINT"
  Gen1StepStart = "REPROBUILD_HCR_GEN1_STEP_START"
  Gen1StepNext = "REPROBUILD_HCR_GEN1_STEP_NEXT"

proc commandsNamed(mock: MockBackendService; command: string):
    seq[ReceivedCommand] =
  for received in mock.receivedCommands:
    if received.command == command:
      result.add(received)

proc makeCallLine(index: int64; marker: string; generation: int;
                  line: int; rrTicks: uint64): CallLine =
  CallLine(
    index: index,
    name: PatchableFunction,
    depth: 0,
    rrTicks: rrTicks,
    location: Location(file: PatchableSource, line: line, column: 0),
    hasChildren: false,
    isExpanded: false,
    callKey: marker & ":" & $generation,
  )

proc makeVariable(name, value: string): Variable =
  Variable(
    name: name,
    value: value,
    typeName: "int",
    hasChildren: false,
    children: @[],
  )

proc configureLiveSession(app: AppViewModel; rrTicks: uint64) =
  let store = app.session.store
  store.session.val = SessionState(
    connectionStatus: csConnected,
    debugSessionMode: liveMcr,
    lastLiveDebugSessionMode: liveMcr,
    recordingHeadRRTicks: rrTicks,
    recordingHeadLoadingState: lsIdle,
  )
  store.timeline.val = TimelineState(
    minRRTicks: 0'u64,
    maxRRTicks: rrTicks,
    currentRRTicks: rrTicks,
  )
  store.debugger.val = DebuggerState(
    location: Location(file: PatchableSource, line: 1, column: 0),
    rrTicks: rrTicks,
    status: dsIdle,
    threadId: 1'u32,
  )
  app.session.calltraceVM.setViewportHeight(20)
  drain()

proc publishStop(app: AppViewModel; marker: string; generation: int;
                 line: int; rrTicks: uint64) =
  let store = app.session.store
  store.updateDebuggerPosition(rrTicks, PatchableSource, line)
  var timeline = store.timeline.val
  timeline.currentRRTicks = rrTicks
  if rrTicks > timeline.maxRRTicks:
    timeline.maxRRTicks = rrTicks
  store.timeline.val = timeline
  store.updateCodeStateLine(line, "int marker = 0; /* " & marker & " */")
  store.updateLocals(@[
    makeVariable("iteration", $rrTicks),
    makeVariable("source_generation", $generation),
  ])
  store.updateCalltraceSection(@[
    makeCallLine(0'i64, marker, generation, line, rrTicks),
  ], 0'i64, 1'u64)
  drain()

proc assertGenerationVisible(app: AppViewModel; marker: string;
                             generation: int; rrTicks: uint64) =
  let session = app.session
  check session.debugControlsVM.toolbarModeText.val == "Live MCR"
  check session.editorVM.activeFileName.val.endsWith("patchable.c")
  check session.timelineVM.currentPosition.val == rrTicks
  check session.stateVM.codeStateLine.val.contains(marker)
  check session.stateVM.currentVariables.val.anyIt(
    it.name == "source_generation" and it.value == $generation)
  check session.calltraceVM.visibleLines.val.len == 1
  check session.calltraceVM.visibleLines.val[0].name == PatchableFunction
  check session.calltraceVM.visibleLines.val[0].location.line ==
    session.store.debugger.val.location.line

suite "Reprobuild HCR AppViewModel":

  test "live debugging, old/new code stepping, history restore and jump-to-live":
    createRoot proc(teardown: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let vm = app.session.debugControlsVM
      var bridgedAction = ""
      vm.onDapStep = proc(action: cstring) =
        bridgedAction = $action

      app.configureLiveSession(100'u64)
      app.publishStop(Gen0Breakpoint, 0, 41, 100'u64)
      mock.clearReceivedCommands()

      app.assertGenerationVisible(Gen0Breakpoint, 0, 100'u64)
      check vm.recordingHeadText.val == "Head: 100"

      vm.invokeToolbarStep("next")
      drain()
      let oldLiveSteps = mock.commandsNamed(LiveMcrStepCommand)
      check oldLiveSteps.len == 1
      if oldLiveSteps.len == 1:
        check oldLiveSteps[0].args["action"].getStr == "next"
      app.publishStop(Gen0StepNext, 0, 43, 110'u64)
      app.assertGenerationVisible(Gen0StepNext, 0, 110'u64)

      mock.clearReceivedCommands()
      app.session.store.updateRecordingHead(300'u64)
      app.publishStop(Gen1Breakpoint, 1, 61, 300'u64)
      app.assertGenerationVisible(Gen1Breakpoint, 1, 300'u64)
      check vm.recordingHeadText.val == "Head: 300"

      vm.invokeToolbarStep("next")
      drain()
      let newLiveSteps = mock.commandsNamed(LiveMcrStepCommand)
      check newLiveSteps.len == 1
      if newLiveSteps.len == 1:
        check newLiveSteps[0].args["threadId"].getInt == 1
      app.publishStop(Gen1StepNext, 1, 63, 310'u64)
      app.assertGenerationVisible(Gen1StepNext, 1, 310'u64)

      mock.clearReceivedCommands()
      vm.restoreAt(100'u64)
      drain()
      let restores = mock.commandsNamed(LiveMcrRestoreAtCommand)
      check restores.len == 1
      if restores.len == 1:
        check restores[0].args["rrTicks"].getBiggestInt == 100
      check app.session.store.session.val.debugSessionMode == historicalFromLive
      check vm.toolbarModeText.val == "Historical replay"
      app.publishStop(Gen0Breakpoint, 0, 41, 100'u64)

      mock.clearReceivedCommands()
      bridgedAction = ""
      vm.invokeToolbarStep("next")
      drain()
      check bridgedAction == "next"
      check mock.commandsNamed(LiveMcrStepCommand).len == 0

      vm.jumpToLive()
      drain()
      let jumps = mock.commandsNamed(LiveMcrRestoreAtCommand)
      check jumps.len == 1
      if jumps.len == 1:
        check jumps[0].args["rrTicks"].getBiggestInt == 300
        check jumps[0].args["jumpToLive"].getBool
      check app.session.store.session.val.debugSessionMode == liveMcr
      check vm.toolbarModeText.val == "Live MCR"

      app.dispose()
      teardown()
