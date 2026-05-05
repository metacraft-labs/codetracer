## test_debug_controls_vm.nim
##
## Unit tests for DebugControlsVM — the ViewModel for the debug control
## toolbar.
##
## Verifies:
## - canStepForward is true only when debugger is idle
## - canStepBackward is true only when idle and past minRRTicks
## - canContinue is true only when debugger is idle
## - isRunning is true when debugger is stepping or running
## - statusText shows the correct human-readable text for each state
## - stepForward sends a forward step command
## - stepBackward sends a backward step command
## - stepIn sends a step-in command
## - stepOut sends a step-out command
## - continueExecution sends a continue command
## - reverseContinue sends a reverse-continue command
## - Action procs are no-ops when the debugger is not in a valid state
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_debug_controls_vm.nim

import std/[json, unittest, sets]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/debug_controls_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


const DAP_STEP_COMMANDS = ["next", "stepBack", "stepIn", "stepOut",
                            "continue", "reverseContinue",
                            "ct/reverseStepIn", "ct/reverseStepOut"].toHashSet

proc isStepCommand(command: string): bool =
  ## Return true if the command is any of the DAP step/continue commands.
  command in DAP_STEP_COMMANDS

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc setDebuggerStatus(store: ReplayDataStore; status: DebuggerStatus) =
  ## Helper to update just the debugger status in the store.
  var dbg = store.debugger.val
  dbg.status = status
  store.debugger.val = dbg

proc setDebuggerPosition(store: ReplayDataStore; rrTicks: uint64) =
  ## Helper to update just the debugger rrTicks in the store.
  var dbg = store.debugger.val
  dbg.rrTicks = rrTicks
  store.debugger.val = dbg

proc setTimelineRange(store: ReplayDataStore; minTicks, maxTicks: uint64) =
  ## Helper to set the timeline range in the store.
  var tl = store.timeline.val
  tl.minRRTicks = minTicks
  tl.maxRRTicks = maxTicks
  store.timeline.val = tl

# ---------------------------------------------------------------------------
# canStepForward
# ---------------------------------------------------------------------------

suite "DebugControlsVM canStepForward":

  test "canStepForward is true when debugger is idle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsIdle)
      check vm.canStepForward.val == true

      dispose()

  test "canStepForward is false when debugger is stepping":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsStepping)
      check vm.canStepForward.val == false

      dispose()

  test "canStepForward is false when debugger is running":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsRunning)
      check vm.canStepForward.val == false

      dispose()

  test "canStepForward is false when debugger is finished":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsFinished)
      check vm.canStepForward.val == false

      dispose()

  test "canStepForward is false when debugger has error":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsError)
      check vm.canStepForward.val == false

      dispose()

# ---------------------------------------------------------------------------
# canStepBackward
# ---------------------------------------------------------------------------

suite "DebugControlsVM canStepBackward":

  test "canStepBackward is true when idle and past minRRTicks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setTimelineRange(0'u64, 1000'u64)
      store.setDebuggerStatus(dsIdle)
      store.setDebuggerPosition(500'u64)

      check vm.canStepBackward.val == true

      dispose()

  test "canStepBackward is false when at minRRTicks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setTimelineRange(0'u64, 1000'u64)
      store.setDebuggerStatus(dsIdle)
      store.setDebuggerPosition(0'u64)

      check vm.canStepBackward.val == false

      dispose()

  test "canStepBackward is false when debugger is not idle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setTimelineRange(0'u64, 1000'u64)
      store.setDebuggerPosition(500'u64)
      store.setDebuggerStatus(dsStepping)

      check vm.canStepBackward.val == false

      dispose()

# ---------------------------------------------------------------------------
# canContinue
# ---------------------------------------------------------------------------

suite "DebugControlsVM canContinue":

  test "canContinue is true when debugger is idle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsIdle)
      check vm.canContinue.val == true

      dispose()

  test "canContinue is false when debugger is stepping":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsStepping)
      check vm.canContinue.val == false

      dispose()

  test "canContinue is false when debugger is finished":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsFinished)
      check vm.canContinue.val == false

      dispose()

# ---------------------------------------------------------------------------
# isRunning
# ---------------------------------------------------------------------------

suite "DebugControlsVM isRunning":

  test "isRunning is false when idle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsIdle)
      check vm.isRunning.val == false

      dispose()

  test "isRunning is true when stepping":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsStepping)
      check vm.isRunning.val == true

      dispose()

  test "isRunning is true when running":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsRunning)
      check vm.isRunning.val == true

      dispose()

  test "isRunning is false when finished":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsFinished)
      check vm.isRunning.val == false

      dispose()

  test "isRunning is false when error":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsError)
      check vm.isRunning.val == false

      dispose()

# ---------------------------------------------------------------------------
# statusText
# ---------------------------------------------------------------------------

suite "DebugControlsVM statusText":

  test "statusText shows Idle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsIdle)
      check vm.statusText.val == "Idle"

      dispose()

  test "statusText shows Stepping...":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsStepping)
      check vm.statusText.val == "Stepping..."

      dispose()

  test "statusText shows Running...":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsRunning)
      check vm.statusText.val == "Running..."

      dispose()

  test "statusText shows Finished":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsFinished)
      check vm.statusText.val == "Finished"

      dispose()

  test "statusText shows Error":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsError)
      check vm.statusText.val == "Error"

      dispose()

# ---------------------------------------------------------------------------
# Action procs — step commands
# ---------------------------------------------------------------------------

suite "DebugControlsVM step actions":

  test "stepForward sends forward step command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.stepForward()
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "next":
          check cmd.args["direction"].getStr == "sdForward"
          found = true
          break
      check found

      dispose()

  test "stepBackward sends backward step command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setTimelineRange(0'u64, 1000'u64)
      store.setDebuggerPosition(500'u64)
      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.stepBackward()
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "stepBack":
          check cmd.args["direction"].getStr == "sdBackward"
          found = true
          break
      check found

      dispose()

  test "stepIn sends step-in command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.stepIn()
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "stepIn":
          check cmd.args["direction"].getStr == "sdStepIn"
          found = true
          break
      check found

      dispose()

  test "stepOut sends step-out command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.stepOut()
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "stepOut":
          check cmd.args["direction"].getStr == "sdStepOut"
          found = true
          break
      check found

      dispose()

  test "continueExecution sends continue command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.continueExecution()
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "continue":
          check cmd.args["direction"].getStr == "sdContinue"
          found = true
          break
      check found

      dispose()

  test "reverseContinue sends reverse-continue command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.reverseContinue()
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "reverseContinue":
          check cmd.args["direction"].getStr == "sdReverseContinue"
          found = true
          break
      check found

      dispose()

  test "toolbar click prefers DAP bridge callback when installed":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      var clickedAction = ""
      vm.onDapStep = proc(action: cstring) = clickedAction = $action
      drain()

      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.invokeToolbarStep("next")
      drain()

      check clickedAction == "next"
      check mock.receivedCommands.len == cmdCountBefore

      dispose()

  test "toolbar click falls back to store request when bridge is absent":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.invokeToolbarStep("next")
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "next":
          check cmd.args["direction"].getStr == "sdForward"
          check cmd.args["threadId"].getInt == 1
          found = true
          break
      check found

      dispose()

# ---------------------------------------------------------------------------
# Action guards — no-ops when not in valid state
# ---------------------------------------------------------------------------

suite "DebugControlsVM action guards":

  test "stepForward is no-op when debugger is stepping":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsStepping)
      let cmdCountBefore = mock.receivedCommands.len

      vm.stepForward()
      drain()

      # No step command should have been sent.
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        check not mock.receivedCommands[i].command.isStepCommand

      dispose()

  test "stepBackward is no-op when at minRRTicks":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setTimelineRange(0'u64, 1000'u64)
      store.setDebuggerPosition(0'u64)
      store.setDebuggerStatus(dsIdle)
      let cmdCountBefore = mock.receivedCommands.len

      vm.stepBackward()
      drain()

      for i in cmdCountBefore ..< mock.receivedCommands.len:
        check not mock.receivedCommands[i].command.isStepCommand

      dispose()

  test "continueExecution is no-op when debugger is running":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsRunning)
      let cmdCountBefore = mock.receivedCommands.len

      vm.continueExecution()
      drain()

      for i in cmdCountBefore ..< mock.receivedCommands.len:
        check not mock.receivedCommands[i].command.isStepCommand

      dispose()

  test "reverseContinue is no-op when debugger is finished":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      drain()

      store.setDebuggerStatus(dsFinished)
      let cmdCountBefore = mock.receivedCommands.len

      vm.reverseContinue()
      drain()

      for i in cmdCountBefore ..< mock.receivedCommands.len:
        check not mock.receivedCommands[i].command.isStepCommand

      dispose()
