## test_scratchpad_vm.nim
##
## Unit tests for ScratchpadVM — the ViewModel for the Scratchpad panel.
##
## Verifies:
## - Initial state defaults (selectedItem, comparisonMode)
## - selectItem sets/clears the selected item
## - toggleComparisonMode flips the boolean
## - Interaction between selection and comparison mode
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_scratchpad_vm.nim

import std/[json, unittest, asyncdispatch, options]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/scratchpad_vm

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

suite "ScratchpadVM initial state":

  test "selectedItem defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      check vm.selectedItem.val.isNone
      dispose()

  test "comparisonMode defaults to false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      check vm.comparisonMode.val == false
      dispose()

# ---------------------------------------------------------------------------
# selectItem
# ---------------------------------------------------------------------------

suite "ScratchpadVM selectItem":

  test "selectItem sets the selected item":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.selectItem(some(2))
      check vm.selectedItem.val == some(2)

      dispose()

  test "selectItem with none clears the selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.selectItem(some(3))
      vm.selectItem(none(int))
      check vm.selectedItem.val.isNone

      dispose()

  test "selectItem can change to a different item":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.selectItem(some(0))
      check vm.selectedItem.val == some(0)

      vm.selectItem(some(5))
      check vm.selectedItem.val == some(5)

      dispose()

# ---------------------------------------------------------------------------
# toggleComparisonMode
# ---------------------------------------------------------------------------

suite "ScratchpadVM toggleComparisonMode":

  test "toggleComparisonMode flips the boolean":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      check vm.comparisonMode.val == false
      vm.toggleComparisonMode()
      check vm.comparisonMode.val == true
      vm.toggleComparisonMode()
      check vm.comparisonMode.val == false

      dispose()

  test "toggleComparisonMode does not affect selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.selectItem(some(1))
      vm.toggleComparisonMode()
      check vm.selectedItem.val == some(1)
      check vm.comparisonMode.val == true

      dispose()

  test "selection works in comparison mode":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.toggleComparisonMode()
      check vm.comparisonMode.val == true

      vm.selectItem(some(4))
      check vm.selectedItem.val == some(4)

      vm.selectItem(none(int))
      check vm.selectedItem.val.isNone

      dispose()
