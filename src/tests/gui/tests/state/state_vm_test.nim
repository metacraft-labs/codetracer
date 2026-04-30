## test_state_vm.nim
##
## Unit tests for StateVM — the ViewModel for the state (locals/globals/watches)
## panel.
##
## Verifies:
## - Initial state defaults (activeTab, expandedPaths, selectedPath, etc.)
## - Tab switching via selectTab updates activeTab and currentVariables
## - toggleExpand adds/removes paths from expandedPaths
## - selectPath sets the selected variable path
## - addWatch / removeWatch manage the watch expressions list
## - currentVariables memo returns locals when on stLocals tab
## - currentVariables memo returns globals when on stGlobals tab
## - isLoading memo reflects store loading state
## - Auto-load effect fires requestLocals when debugger rrTicks changes
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_state_vm.nim

import std/[json, unittest, sets]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/state_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  ## Returns both so tests can inspect the mock's receivedCommands.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "StateVM initial state":

  test "activeTab defaults to stLocals":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.activeTab.val == stLocals
      dispose()

  test "expandedPaths starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.expandedPaths.val.len == 0
      dispose()

  test "selectedPath starts as empty string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.selectedPath.val == ""
      dispose()

  test "watchExpressions starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.watchExpressions.val.len == 0
      dispose()

  test "isLoading starts false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.isLoading.val == false
      dispose()

  test "currentVariables starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      check vm.currentVariables.val.len == 0
      dispose()

# ---------------------------------------------------------------------------
# Tab switching
# ---------------------------------------------------------------------------

suite "StateVM tab switching":

  test "selectTab changes activeTab signal":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.selectTab(stGlobals)
      check vm.activeTab.val == stGlobals

      vm.selectTab(stWatches)
      check vm.activeTab.val == stWatches

      vm.selectTab(stLocals)
      check vm.activeTab.val == stLocals

      dispose()

  test "currentVariables returns locals when on stLocals tab":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      # Populate the store's locals signal directly.
      let testLocals = @[
        Variable(name: "x", value: "42", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "y", value: "hello", typeName: "string",
                 hasChildren: false, children: @[]),
      ]
      store.locals.locals.val = testLocals

      vm.selectTab(stLocals)
      check vm.currentVariables.val.len == 2
      check vm.currentVariables.val[0].name == "x"
      check vm.currentVariables.val[1].name == "y"

      dispose()

  test "currentVariables returns globals when on stGlobals tab":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      # Populate globals.
      let testGlobals = @[
        Variable(name: "gCounter", value: "7", typeName: "int",
                 hasChildren: false, children: @[]),
      ]
      store.locals.globals.val = testGlobals

      vm.selectTab(stGlobals)
      check vm.currentVariables.val.len == 1
      check vm.currentVariables.val[0].name == "gCounter"

      dispose()

  test "currentVariables returns empty seq when on stWatches tab":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      # Even if locals and globals have data, watches tab returns empty
      # (watch results are not yet wired through the store).
      store.locals.locals.val = @[
        Variable(name: "x", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
      ]
      store.locals.globals.val = @[
        Variable(name: "g", value: "2", typeName: "int",
                 hasChildren: false, children: @[]),
      ]

      vm.selectTab(stWatches)
      check vm.currentVariables.val.len == 0

      dispose()

  test "currentVariables updates reactively when tab changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.locals.locals.val = @[
        Variable(name: "local1", value: "a", typeName: "string",
                 hasChildren: false, children: @[]),
      ]
      store.locals.globals.val = @[
        Variable(name: "global1", value: "b", typeName: "string",
                 hasChildren: false, children: @[]),
      ]

      # Track via an effect.
      var observed: seq[Variable] = @[]
      createEffect proc() =
        observed = vm.currentVariables.val

      # Initially on locals tab.
      check observed.len == 1
      check observed[0].name == "local1"

      # Switch to globals.
      vm.selectTab(stGlobals)
      check observed.len == 1
      check observed[0].name == "global1"

      dispose()

# ---------------------------------------------------------------------------
# Expand / collapse
# ---------------------------------------------------------------------------

suite "StateVM expand/collapse":

  test "toggleExpand adds a path":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.toggleExpand("x")
      check "x" in vm.expandedPaths.val

      dispose()

  test "toggleExpand removes an already expanded path":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.toggleExpand("x")
      check "x" in vm.expandedPaths.val

      vm.toggleExpand("x")
      check "x" notin vm.expandedPaths.val

      dispose()

  test "toggleExpand handles multiple paths independently":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.toggleExpand("a")
      vm.toggleExpand("b")
      vm.toggleExpand("c")

      check "a" in vm.expandedPaths.val
      check "b" in vm.expandedPaths.val
      check "c" in vm.expandedPaths.val

      # Collapse only "b"
      vm.toggleExpand("b")
      check "a" in vm.expandedPaths.val
      check "b" notin vm.expandedPaths.val
      check "c" in vm.expandedPaths.val

      dispose()

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

suite "StateVM selection":

  test "selectPath sets the selected path":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.selectPath("myVar.field")
      check vm.selectedPath.val == "myVar.field"

      dispose()

  test "selectPath with empty string clears selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.selectPath("x")
      check vm.selectedPath.val == "x"

      vm.selectPath("")
      check vm.selectedPath.val == ""

      dispose()

# ---------------------------------------------------------------------------
# Watch expressions
# ---------------------------------------------------------------------------

suite "StateVM watch expressions":

  test "addWatch appends a new expression":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("counter")
      check vm.watchExpressions.val == @["counter"]

      vm.addWatch("total")
      check vm.watchExpressions.val == @["counter", "total"]

      dispose()

  test "addWatch ignores empty strings":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("")
      check vm.watchExpressions.val.len == 0

      dispose()

  test "addWatch ignores duplicate expressions":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("x")
      vm.addWatch("x")
      check vm.watchExpressions.val == @["x"]

      dispose()

  test "removeWatch removes an existing expression":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("a")
      vm.addWatch("b")
      vm.addWatch("c")

      vm.removeWatch("b")
      check vm.watchExpressions.val == @["a", "c"]

      dispose()

  test "removeWatch is a no-op for non-existent expressions":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      vm.addWatch("x")
      vm.removeWatch("y")
      check vm.watchExpressions.val == @["x"]

      dispose()

# ---------------------------------------------------------------------------
# isLoading memo
# ---------------------------------------------------------------------------

suite "StateVM isLoading":

  test "isLoading reflects store loading state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      check vm.isLoading.val == false

      store.locals.loadingState.val = lsLoading
      check vm.isLoading.val == true

      store.locals.loadingState.val = lsIdle
      check vm.isLoading.val == false

      dispose()

  test "isLoading is false when loading state is lsError":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)

      store.locals.loadingState.val = lsError
      check vm.isLoading.val == false

      dispose()

# ---------------------------------------------------------------------------
# Auto-load effect
# ---------------------------------------------------------------------------

suite "StateVM auto-load effect":

  test "changing rrTicks triggers requestLocals on the backend":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      # The auto-load effect fires on creation (no rrTicks guard),
      # so clear initial commands to isolate the position change.
      mock.clearReceivedCommands()

      # Simulate the debugger moving to a new position.
      var dbg = store.debugger.val
      dbg.rrTicks = 100'u64
      store.debugger.val = dbg
      drain()

      # The effect should have triggered requestLocals.
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == "ct/load-locals"
      check mock.receivedCommands[0].args["rrTicks"].getBiggestInt == 100

      dispose()

  test "auto-load effect fires again when rrTicks changes a second time":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      # The auto-load effect no longer guards on rrTicks > 0, so
      # the initial effect run at rrTicks=0 also fires a request.
      let initialCount = mock.receivedCommands.len

      # First move.
      var dbg = store.debugger.val
      dbg.rrTicks = 50'u64
      store.debugger.val = dbg
      drain()
      check mock.receivedCommands.len == initialCount + 1

      # Second move — different rrTicks, so a new request should fire.
      dbg = store.debugger.val
      dbg.rrTicks = 75'u64
      store.debugger.val = dbg
      drain()
      check mock.receivedCommands.len == initialCount + 2
      check mock.receivedCommands[^1].args["rrTicks"].getBiggestInt == 75

      dispose()

  test "auto-load effect fires even for rrTicks == 0 (DB-based traces)":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()

      # The auto-load effect no longer guards on rrTicks > 0 because
      # DB-based traces always have rrTicks=0. RequestTracker handles
      # deduplication of redundant requests.
      # The initial effect run at rrTicks=0 fires a request.
      check mock.receivedCommands.len >= 1
      check mock.receivedCommands[0].command == "ct/load-locals"

      dispose()
