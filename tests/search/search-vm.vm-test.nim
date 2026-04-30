## test_search_vm.nim
##
## Unit tests for SearchVM — the ViewModel for the Search / Command palette.
##
## Verifies:
## - Initial state defaults (mode, query, selectedResult, resultsVisible)
## - setMode changes mode and resets query and selection
## - setQuery updates query, shows/hides results, resets selection
## - selectResult sets/clears the selected result
## - toggleResults flips the visibility boolean
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_search_vm.nim

import std/[json, unittest, asyncdispatch, options]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import ../backend/backend_service
import ../backend/mock_backend
import ../store/types
import ../store/replay_data_store
import ../viewmodels/search_vm

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

suite "SearchVM initial state":

  test "mode defaults to smCommand":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      check vm.mode.val == smCommand
      dispose()

  test "query defaults to empty string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      check vm.query.val == ""
      dispose()

  test "selectedResult defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      check vm.selectedResult.val.isNone
      dispose()

  test "resultsVisible defaults to false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      check vm.resultsVisible.val == false
      dispose()

# ---------------------------------------------------------------------------
# setMode
# ---------------------------------------------------------------------------

suite "SearchVM setMode":

  test "setMode changes the mode":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      vm.setMode(smFile)
      check vm.mode.val == smFile

      vm.setMode(smFindInFiles)
      check vm.mode.val == smFindInFiles

      vm.setMode(smFindSymbol)
      check vm.mode.val == smFindSymbol

      vm.setMode(smCommand)
      check vm.mode.val == smCommand

      dispose()

  test "setMode clears query and selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      vm.setQuery("test")
      vm.selectResult(some(2))

      vm.setMode(smFile)
      check vm.query.val == ""
      check vm.selectedResult.val.isNone

      dispose()

# ---------------------------------------------------------------------------
# setQuery
# ---------------------------------------------------------------------------

suite "SearchVM setQuery":

  test "setQuery updates the query":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      vm.setQuery("hello")
      check vm.query.val == "hello"

      dispose()

  test "setQuery shows results when query is non-empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      vm.setQuery("test")
      check vm.resultsVisible.val == true

      dispose()

  test "setQuery hides results when query is empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      vm.setQuery("test")
      check vm.resultsVisible.val == true

      vm.setQuery("")
      check vm.resultsVisible.val == false

      dispose()

  test "setQuery resets selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      vm.setQuery("a")
      vm.selectResult(some(1))
      check vm.selectedResult.val == some(1)

      vm.setQuery("ab")
      check vm.selectedResult.val.isNone

      dispose()

# ---------------------------------------------------------------------------
# selectResult
# ---------------------------------------------------------------------------

suite "SearchVM selectResult":

  test "selectResult sets the selected result":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      vm.selectResult(some(5))
      check vm.selectedResult.val == some(5)

      dispose()

  test "selectResult with none clears the selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      vm.selectResult(some(3))
      vm.selectResult(none(int))
      check vm.selectedResult.val.isNone

      dispose()

# ---------------------------------------------------------------------------
# toggleResults
# ---------------------------------------------------------------------------

suite "SearchVM toggleResults":

  test "toggleResults flips the boolean":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)

      check vm.resultsVisible.val == false
      vm.toggleResults()
      check vm.resultsVisible.val == true
      vm.toggleResults()
      check vm.resultsVisible.val == false

      dispose()
