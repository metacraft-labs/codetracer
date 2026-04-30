## test_views.nim
##
## Unit tests for the view-state extraction layer — the bridge between
## ViewModels and renderers.
##
## Verifies:
## - DebugControlsViewState correctly reflects each ViewModel memo
## - StateViewState correctly reflects active tab, variables, loading
## - Variable flattening respects expanded paths
## - Watch input visibility tracks the active tab
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_views.nim

import std/[json, unittest, sets]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/debug_controls_vm
import viewmodels/state_vm
import views/debug_controls_view
import views/state_view

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


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
# DebugControlsViewState
# ---------------------------------------------------------------------------

suite "DebugControlsViewState":

  test "reflects idle state with all controls enabled":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsIdle)
      store.setTimelineRange(0'u64, 1000'u64)
      store.setDebuggerPosition(500'u64)

      let vs = getViewState(vm)
      check vs.stepForwardEnabled == true
      check vs.stepBackwardEnabled == true
      check vs.continueEnabled == true
      check vs.reverseContinueEnabled == true
      check vs.stepInEnabled == true
      check vs.stepOutEnabled == true
      check vs.statusText == "Idle"
      check vs.isRunning == false

      dispose()

  test "reflects stepping state with controls disabled":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsStepping)

      let vs = getViewState(vm)
      check vs.stepForwardEnabled == false
      check vs.continueEnabled == false
      check vs.stepInEnabled == false
      check vs.stepOutEnabled == false
      check vs.statusText == "Stepping..."
      check vs.isRunning == true

      dispose()

  test "reflects running state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsRunning)

      let vs = getViewState(vm)
      check vs.stepForwardEnabled == false
      check vs.continueEnabled == false
      check vs.statusText == "Running..."
      check vs.isRunning == true

      dispose()

  test "reflects finished state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsFinished)

      let vs = getViewState(vm)
      check vs.stepForwardEnabled == false
      check vs.continueEnabled == false
      check vs.statusText == "Finished"
      check vs.isRunning == false

      dispose()

  test "reflects error state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsError)

      let vs = getViewState(vm)
      check vs.stepForwardEnabled == false
      check vs.continueEnabled == false
      check vs.statusText == "Error"
      check vs.isRunning == false

      dispose()

  test "stepBackward disabled when at minRRTicks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setTimelineRange(0'u64, 1000'u64)
      store.setDebuggerPosition(0'u64)
      store.setDebuggerStatus(dsIdle)

      let vs = getViewState(vm)
      check vs.stepForwardEnabled == true
      check vs.stepBackwardEnabled == false

      dispose()

  test "view state updates when store changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)

      store.setDebuggerStatus(dsIdle)
      let vs1 = getViewState(vm)
      check vs1.statusText == "Idle"
      check vs1.isRunning == false

      store.setDebuggerStatus(dsStepping)
      let vs2 = getViewState(vm)
      check vs2.statusText == "Stepping..."
      check vs2.isRunning == true

      dispose()

# ---------------------------------------------------------------------------
# StateViewState — basic tab and loading
# ---------------------------------------------------------------------------

suite "StateViewState basic":

  test "shows locals tab by default":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      # Flush the auto-load response so isLoading settles back to
      # false on JS, where mock-future callbacks defer until drain().
      drain()

      let vs = getStateViewState(vm)
      check vs.activeTab == "Locals"
      check vs.watchInputVisible == false
      check vs.isLoading == false
      check vs.variables.len == 0

      dispose()

  test "shows globals tab when selected":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.selectTab(stGlobals)

      let vs = getStateViewState(vm)
      check vs.activeTab == "Globals"
      check vs.watchInputVisible == false

      dispose()

  test "shows watches tab with watch input visible":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.selectTab(stWatches)

      let vs = getStateViewState(vm)
      check vs.activeTab == "Watches"
      check vs.watchInputVisible == true

      dispose()

  test "isLoading reflects store loading state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      check getStateViewState(vm).isLoading == false

      store.locals.loadingState.val = lsLoading
      check getStateViewState(vm).isLoading == true

      store.locals.loadingState.val = lsIdle
      check getStateViewState(vm).isLoading == false

      dispose()

# ---------------------------------------------------------------------------
# StateViewState — variable flattening
# ---------------------------------------------------------------------------

suite "StateViewState variables":

  test "shows locals after store update":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.updateLocals(@[
        makeVariable("x", "42", "int"),
        makeVariable("y", "hello", "string"),
      ])

      let vs = getStateViewState(vm)
      check vs.variables.len == 2
      check vs.variables[0].name == "x"
      check vs.variables[0].value == "42"
      check vs.variables[0].typeName == "int"
      check vs.variables[0].depth == 0
      check vs.variables[1].name == "y"
      check vs.variables[1].value == "hello"

      dispose()

  test "globals show on globals tab":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.locals.globals.val = @[
        Variable(name: "gCounter", value: "7", typeName: "int",
                 hasChildren: false, children: @[]),
      ]
      vm.selectTab(stGlobals)

      let vs = getStateViewState(vm)
      check vs.variables.len == 1
      check vs.variables[0].name == "gCounter"

      dispose()

  test "collapsed variable with children does not show children":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.updateLocals(@[
        makeVariable("obj", "{...}", "MyObj",
          hasChildren = true,
          children = @[
            makeVariable("field1", "10", "int"),
            makeVariable("field2", "20", "int"),
          ]),
      ])

      # By default, nothing is expanded.
      let vs = getStateViewState(vm)
      check vs.variables.len == 1
      check vs.variables[0].name == "obj"
      check vs.variables[0].hasChildren == true
      check vs.variables[0].isExpanded == false

      dispose()

  test "expanded variable shows children at increased depth":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.updateLocals(@[
        makeVariable("obj", "{...}", "MyObj",
          hasChildren = true,
          children = @[
            makeVariable("field1", "10", "int"),
            makeVariable("field2", "20", "int"),
          ]),
      ])

      # Expand "obj".
      vm.toggleExpand("obj")

      let vs = getStateViewState(vm)
      check vs.variables.len == 3
      check vs.variables[0].name == "obj"
      check vs.variables[0].isExpanded == true
      check vs.variables[0].depth == 0
      check vs.variables[1].name == "field1"
      check vs.variables[1].depth == 1
      check vs.variables[1].value == "10"
      check vs.variables[2].name == "field2"
      check vs.variables[2].depth == 1
      check vs.variables[2].value == "20"

      dispose()

  test "nested expansion works at multiple levels":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.updateLocals(@[
        makeVariable("root", "{...}", "Root",
          hasChildren = true,
          children = @[
            makeVariable("child", "{...}", "Child",
              hasChildren = true,
              children = @[
                makeVariable("leaf", "42", "int"),
              ]),
          ]),
      ])

      # Expand both levels.
      vm.toggleExpand("root")
      vm.toggleExpand("root.child")

      let vs = getStateViewState(vm)
      check vs.variables.len == 3
      check vs.variables[0].name == "root"
      check vs.variables[0].depth == 0
      check vs.variables[1].name == "child"
      check vs.variables[1].depth == 1
      check vs.variables[1].isExpanded == true
      check vs.variables[2].name == "leaf"
      check vs.variables[2].depth == 2
      check vs.variables[2].value == "42"

      dispose()

  test "collapsing a parent hides all descendants":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.updateLocals(@[
        makeVariable("root", "{...}", "Root",
          hasChildren = true,
          children = @[
            makeVariable("child", "{...}", "Child",
              hasChildren = true,
              children = @[
                makeVariable("leaf", "42", "int"),
              ]),
          ]),
      ])

      # Expand both, then collapse the root.
      vm.toggleExpand("root")
      vm.toggleExpand("root.child")
      vm.toggleExpand("root")  # collapse

      let vs = getStateViewState(vm)
      # Only the root should be visible (collapsed).
      check vs.variables.len == 1
      check vs.variables[0].name == "root"
      check vs.variables[0].isExpanded == false

      dispose()

  test "multiple top-level variables with mixed expansion":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.updateLocals(@[
        makeVariable("simple", "1", "int"),
        makeVariable("compound", "{...}", "Obj",
          hasChildren = true,
          children = @[
            makeVariable("inner", "2", "int"),
          ]),
        makeVariable("another", "3", "int"),
      ])

      # Expand only the compound variable.
      vm.toggleExpand("compound")

      let vs = getStateViewState(vm)
      check vs.variables.len == 4
      check vs.variables[0].name == "simple"
      check vs.variables[0].depth == 0
      check vs.variables[1].name == "compound"
      check vs.variables[1].depth == 0
      check vs.variables[1].isExpanded == true
      check vs.variables[2].name == "inner"
      check vs.variables[2].depth == 1
      check vs.variables[3].name == "another"
      check vs.variables[3].depth == 0

      dispose()
