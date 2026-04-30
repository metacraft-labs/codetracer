## test_flow_vm.nim
##
## Unit tests for FlowVM — the ViewModel for the Flow panel.
##
## Verifies:
## - Initial state defaults (flowMode, selectedIteration, hoveredStep, etc.)
## - setMode changes flowMode
## - selectIteration updates with clamping
## - hoverStep sets/clears hovered step
## - clickStep sends navigation command
## - toggleRawValues toggles the boolean
## - isLoading memo reflects loading state
## - totalIterations memo reflects iteration count
## - Auto-load effect fires when debugger position or flowMode changes
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_flow_vm.nim

import std/[json, unittest, options]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/flow_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "FlowVM initial state":

  test "flowMode defaults to fmCall":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.flowMode.val == fmCall
      dispose()

  test "selectedIteration defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.selectedIteration.val == 0
      dispose()

  test "hoveredStep defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.hoveredStep.val.isNone
      dispose()

  test "showRawValues defaults to false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.showRawValues.val == false
      dispose()

  test "isLoading starts false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.isLoading.val == false
      dispose()

  test "totalIterations starts at 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.totalIterations.val == 0
      dispose()

# ---------------------------------------------------------------------------
# Flow mode
# ---------------------------------------------------------------------------

suite "FlowVM flow mode":

  test "setMode changes flowMode signal":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.setMode(fmLine)
      check vm.flowMode.val == fmLine

      vm.setMode(fmFunction)
      check vm.flowMode.val == fmFunction

      vm.setMode(fmCall)
      check vm.flowMode.val == fmCall

      dispose()

# ---------------------------------------------------------------------------
# Iteration selection
# ---------------------------------------------------------------------------

suite "FlowVM iteration selection":

  test "selectIteration sets the selected iteration":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 10
      vm.selectIteration(5)
      check vm.selectedIteration.val == 5

      dispose()

  test "selectIteration clamps negative values to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 10
      vm.selectIteration(-3)
      check vm.selectedIteration.val == 0

      dispose()

  test "selectIteration clamps to max iteration":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 5
      vm.selectIteration(99)
      check vm.selectedIteration.val == 4  # totalIterations - 1

      dispose()

  test "selectIteration allows 0 when no iterations":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      # iterationCount is 0, so totalIterations is 0.
      # maxIter = -1, so the else branch sets directly.
      vm.selectIteration(0)
      check vm.selectedIteration.val == 0

      dispose()

# ---------------------------------------------------------------------------
# Hover step
# ---------------------------------------------------------------------------

suite "FlowVM hover step":

  test "hoverStep sets the hovered step":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.hoverStep(some(3))
      check vm.hoveredStep.val == some(3)

      dispose()

  test "hoverStep with none clears the hovered step":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.hoverStep(some(7))
      check vm.hoveredStep.val.isSome

      vm.hoverStep(none(int))
      check vm.hoveredStep.val.isNone

      dispose()

# ---------------------------------------------------------------------------
# Click step (navigation)
# ---------------------------------------------------------------------------

suite "FlowVM clickStep":

  test "clickStep sends flow-jump command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      let cmdCountBefore = mock.receivedCommands.len

      vm.clickStep(42)
      drain()

      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      var found = false
      for cmd in jumpCmds:
        if cmd.command == "ct/flow-jump":
          check cmd.args["step"].getInt == 42
          check cmd.args["flowMode"].getStr == "fmCall"
          check cmd.args["iteration"].getInt == 0
          found = true
          break
      check found

      dispose()

  test "clickStep includes current mode and iteration":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      vm.setMode(fmLine)
      vm.iterationCount.val = 10
      vm.selectIteration(3)

      let cmdCountBefore = mock.receivedCommands.len

      vm.clickStep(7)
      drain()

      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      var found = false
      for cmd in jumpCmds:
        if cmd.command == "ct/flow-jump":
          check cmd.args["flowMode"].getStr == "fmLine"
          check cmd.args["iteration"].getInt == 3
          found = true
          break
      check found

      dispose()

# ---------------------------------------------------------------------------
# Raw values toggle
# ---------------------------------------------------------------------------

suite "FlowVM toggleRawValues":

  test "toggleRawValues flips the boolean":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      check vm.showRawValues.val == false

      vm.toggleRawValues()
      check vm.showRawValues.val == true

      vm.toggleRawValues()
      check vm.showRawValues.val == false

      dispose()

# ---------------------------------------------------------------------------
# isLoading memo
# ---------------------------------------------------------------------------

suite "FlowVM isLoading":

  test "isLoading reflects loading state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      check vm.isLoading.val == false

      vm.loadingState.val = lsLoading
      check vm.isLoading.val == true

      vm.loadingState.val = lsIdle
      check vm.isLoading.val == false

      dispose()

  test "isLoading is false when loading state is lsError":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.loadingState.val = lsError
      check vm.isLoading.val == false

      dispose()

# ---------------------------------------------------------------------------
# totalIterations memo
# ---------------------------------------------------------------------------

suite "FlowVM totalIterations":

  test "totalIterations reflects iterationCount":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 15
      check vm.totalIterations.val == 15

      vm.iterationCount.val = 0
      check vm.totalIterations.val == 0

      dispose()

# ---------------------------------------------------------------------------
# Auto-load effect
# ---------------------------------------------------------------------------

suite "FlowVM auto-load effect":

  test "changing rrTicks triggers flow data request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      # Initially rrTicks is 0 — no request should fire.
      let initialCount = mock.receivedCommands.len
      check initialCount == 0

      # Simulate debugger moving.
      var dbg = store.debugger.val
      dbg.rrTicks = 200'u64
      store.debugger.val = dbg
      drain()

      var found = false
      for cmd in mock.receivedCommands:
        if cmd.command == "ct/load-flow":
          check cmd.args["rrTicks"].getBiggestInt == 200
          check cmd.args["flowMode"].getStr == "fmCall"
          found = true
          break
      check found

      dispose()

  test "changing flowMode triggers flow data request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      # First, set rrTicks > 0 so the effect guard passes.
      var dbg = store.debugger.val
      dbg.rrTicks = 50'u64
      store.debugger.val = dbg
      drain()

      let countBefore = mock.receivedCommands.len

      vm.setMode(fmFunction)
      drain()

      # A new request should have been sent with the updated mode.
      var found = false
      for i in countBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "ct/load-flow":
          check cmd.args["flowMode"].getStr == "fmFunction"
          found = true
          break
      check found

      dispose()

  test "auto-load does not fire for rrTicks == 0":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      var dbg = store.debugger.val
      dbg.rrTicks = 0'u64
      store.debugger.val = dbg
      drain()

      for cmd in mock.receivedCommands:
        check cmd.command != "ct/load-flow"

      dispose()
