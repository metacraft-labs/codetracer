## test_point_list_vm.nim
##
## Unit tests for PointListVM — the ViewModel for the Point List
## (tracepoints / breakpoints) panel.
##
## Verifies:
## - Initial state defaults (selectedPoint, editingPoint)
## - selectPoint sets/clears the selected point
## - startEditing sets editingPoint and also selects the point
## - stopEditing clears editingPoint
## - Editing and selection interact correctly
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_point_list_vm.nim

import std/[json, unittest, asyncdispatch, options]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/point_list_vm

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

suite "PointListVM initial state":

  test "selectedPoint defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      check vm.selectedPoint.val.isNone
      dispose()

  test "editingPoint defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      check vm.editingPoint.val.isNone
      dispose()

# ---------------------------------------------------------------------------
# selectPoint
# ---------------------------------------------------------------------------

suite "PointListVM selectPoint":

  test "selectPoint sets the selected point":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.selectPoint(some(3))
      check vm.selectedPoint.val == some(3)

      dispose()

  test "selectPoint with none clears the selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.selectPoint(some(5))
      vm.selectPoint(none(int))
      check vm.selectedPoint.val.isNone

      dispose()

  test "selectPoint can change to a different point":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.selectPoint(some(1))
      check vm.selectedPoint.val == some(1)

      vm.selectPoint(some(7))
      check vm.selectedPoint.val == some(7)

      dispose()

# ---------------------------------------------------------------------------
# startEditing
# ---------------------------------------------------------------------------

suite "PointListVM startEditing":

  test "startEditing sets editingPoint":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(2)
      check vm.editingPoint.val == some(2)

      dispose()

  test "startEditing also selects the point":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(4)
      check vm.selectedPoint.val == some(4)

      dispose()

  test "startEditing overrides previous editing point":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(1)
      check vm.editingPoint.val == some(1)

      vm.startEditing(3)
      check vm.editingPoint.val == some(3)
      check vm.selectedPoint.val == some(3)

      dispose()

# ---------------------------------------------------------------------------
# stopEditing
# ---------------------------------------------------------------------------

suite "PointListVM stopEditing":

  test "stopEditing clears editingPoint":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(2)
      check vm.editingPoint.val == some(2)

      vm.stopEditing()
      check vm.editingPoint.val.isNone

      dispose()

  test "stopEditing does not change selectedPoint":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(5)
      check vm.selectedPoint.val == some(5)

      vm.stopEditing()
      check vm.editingPoint.val.isNone
      # Selection remains.
      check vm.selectedPoint.val == some(5)

      dispose()

  test "stopEditing is a no-op when not editing":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.stopEditing()
      check vm.editingPoint.val.isNone

      dispose()
