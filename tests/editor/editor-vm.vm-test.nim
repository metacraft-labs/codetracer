## test_editor_vm.nim
##
## Unit tests for EditorVM — the ViewModel for the Editor panel.
##
## Verifies:
## - Initial state defaults (activeTabIndex, cursorLine, cursorColumn, etc.)
## - switchTab changes activeTabIndex, clamps negative values
## - closeTab adjusts activeTabIndex when needed
## - setCursor updates line and column, clamps below 1
## - toggleFlowOverlay flips the boolean
## - toggleBreakpointGutter flips the boolean
## - activeFileName memo reflects the store's debugger location
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_editor_vm.nim

import std/[json, unittest, asyncdispatch, options]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/editor_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.
  try:
    poll(0)
  except ValueError:
    discard

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "EditorVM initial state":

  test "activeTabIndex defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      check vm.activeTabIndex.val == 0
      dispose()

  test "cursorLine defaults to 1":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      check vm.cursorLine.val == 1
      dispose()

  test "cursorColumn defaults to 1":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      check vm.cursorColumn.val == 1
      dispose()

  test "scrollTop defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      check vm.scrollTop.val == 0
      dispose()

  test "showFlowOverlay defaults to false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      check vm.showFlowOverlay.val == false
      dispose()

  test "showBreakpointGutter defaults to true":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      check vm.showBreakpointGutter.val == true
      dispose()

  test "activeFileName starts as empty string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      check vm.activeFileName.val == ""
      dispose()

# ---------------------------------------------------------------------------
# switchTab
# ---------------------------------------------------------------------------

suite "EditorVM switchTab":

  test "switchTab changes activeTabIndex":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      vm.switchTab(3)
      check vm.activeTabIndex.val == 3

      vm.switchTab(0)
      check vm.activeTabIndex.val == 0

      dispose()

  test "switchTab clamps negative values to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      vm.switchTab(-5)
      check vm.activeTabIndex.val == 0

      dispose()

# ---------------------------------------------------------------------------
# closeTab
# ---------------------------------------------------------------------------

suite "EditorVM closeTab":

  test "closeTab resets to 0 when closing active tab":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      vm.switchTab(2)
      vm.closeTab(2)
      check vm.activeTabIndex.val == 0

      dispose()

  test "closeTab shifts index left when closing tab to the left":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      vm.switchTab(3)
      vm.closeTab(1)
      check vm.activeTabIndex.val == 2

      dispose()

  test "closeTab does not change index when closing tab to the right":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      vm.switchTab(1)
      vm.closeTab(3)
      check vm.activeTabIndex.val == 1

      dispose()

# ---------------------------------------------------------------------------
# setCursor
# ---------------------------------------------------------------------------

suite "EditorVM setCursor":

  test "setCursor updates line and column":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      vm.setCursor(10, 5)
      check vm.cursorLine.val == 10
      check vm.cursorColumn.val == 5

      dispose()

  test "setCursor clamps line below 1":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      vm.setCursor(0, 5)
      check vm.cursorLine.val == 1

      vm.setCursor(-3, 5)
      check vm.cursorLine.val == 1

      dispose()

  test "setCursor clamps column below 1":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      vm.setCursor(10, 0)
      check vm.cursorColumn.val == 1

      vm.setCursor(10, -2)
      check vm.cursorColumn.val == 1

      dispose()

# ---------------------------------------------------------------------------
# Toggles
# ---------------------------------------------------------------------------

suite "EditorVM toggles":

  test "toggleFlowOverlay flips the boolean":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      check vm.showFlowOverlay.val == false
      vm.toggleFlowOverlay()
      check vm.showFlowOverlay.val == true
      vm.toggleFlowOverlay()
      check vm.showFlowOverlay.val == false

      dispose()

  test "toggleBreakpointGutter flips the boolean":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      check vm.showBreakpointGutter.val == true
      vm.toggleBreakpointGutter()
      check vm.showBreakpointGutter.val == false
      vm.toggleBreakpointGutter()
      check vm.showBreakpointGutter.val == true

      dispose()

# ---------------------------------------------------------------------------
# activeFileName memo
# ---------------------------------------------------------------------------

suite "EditorVM activeFileName":

  test "activeFileName reflects store debugger location":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      var dbg = store.debugger.val
      dbg.location = Location(file: "main.nim", line: 42, column: 1)
      store.debugger.val = dbg

      check vm.activeFileName.val == "main.nim"

      dispose()

  test "activeFileName updates reactively when debugger location changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)

      var dbg = store.debugger.val
      dbg.location = Location(file: "a.nim", line: 1, column: 1)
      store.debugger.val = dbg
      check vm.activeFileName.val == "a.nim"

      dbg.location = Location(file: "b.nim", line: 10, column: 1)
      store.debugger.val = dbg
      check vm.activeFileName.val == "b.nim"

      dispose()
