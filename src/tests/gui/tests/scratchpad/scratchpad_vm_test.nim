## test_scratchpad_vm.nim
##
## Unit tests for ScratchpadVM — the ViewModel for the Scratchpad panel.
##
## Verifies:
## - Initial-state defaults (entries, locals lookup, isEmpty/rowCount)
## - addValue / removeValue (per-row close button flow)
## - clearValues (session switch / reset)
## - setLocals (mirrors CtLoadLocalsResponse)
## - addFromExpression (mirrors InternalAddToScratchpadFromExpression)
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_scratchpad_vm.nim

import std/[json, tables, unittest]
import vm_test_helpers
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

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeEntry(expression: string = "i";
               valueText: string = "42";
               isError: bool = false;
               isLiteral: bool = false): ScratchpadValueEntry =
  ScratchpadValueEntry(
    expression: expression,
    valueText: valueText,
    isError: isError,
    isLiteral: isLiteral,
  )

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "ScratchpadVM initial state":

  test "entries default to an empty seq":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      check vm.entries.val.len == 0
      check vm.isEmpty.val
      check vm.rowCount.val == 0
      dispose()

  test "localsByExpression defaults to an empty table":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      check vm.localsByExpression.val.len == 0
      dispose()

# ---------------------------------------------------------------------------
# addValue / removeValue
# ---------------------------------------------------------------------------

suite "ScratchpadVM addValue / removeValue":

  test "addValue appends entries in insertion order":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("a", "1"))
      vm.addValue(makeEntry("b", "2"))
      vm.addValue(makeEntry("c", "3"))

      check vm.entries.val.len == 3
      check vm.entries.val[0].expression == "a"
      check vm.entries.val[1].expression == "b"
      check vm.entries.val[2].expression == "c"
      check vm.rowCount.val == 3
      check not vm.isEmpty.val

      dispose()

  test "removeValue drops the row at index":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("a", "1"))
      vm.addValue(makeEntry("b", "2"))
      vm.addValue(makeEntry("c", "3"))

      vm.removeValue(1)
      check vm.entries.val.len == 2
      check vm.entries.val[0].expression == "a"
      check vm.entries.val[1].expression == "c"

      dispose()

  test "removeValue with out-of-range index is a no-op":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("a"))
      vm.removeValue(99)
      vm.removeValue(-5)

      check vm.entries.val.len == 1

      dispose()

# ---------------------------------------------------------------------------
# clearValues
# ---------------------------------------------------------------------------

suite "ScratchpadVM clearValues":

  test "clearValues drops every entry":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("a"))
      vm.addValue(makeEntry("b"))
      check vm.rowCount.val == 2

      vm.clearValues()
      check vm.entries.val.len == 0
      check vm.isEmpty.val
      check vm.rowCount.val == 0

      dispose()

# ---------------------------------------------------------------------------
# setLocals / addFromExpression
# ---------------------------------------------------------------------------

suite "ScratchpadVM setLocals / addFromExpression":

  test "setLocals stores entries keyed by expression":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.setLocals(@[makeEntry("x", "1"), makeEntry("y", "2")])
      check vm.localsByExpression.val.len == 2
      check vm.localsByExpression.val["y"].valueText == "2"

      dispose()

  test "addFromExpression copies a known local into entries":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.setLocals(@[makeEntry("x", "1"), makeEntry("y", "2")])
      vm.addFromExpression("x")

      check vm.entries.val.len == 1
      check vm.entries.val[0].expression == "x"
      check vm.entries.val[0].valueText == "1"

      dispose()

  test "addFromExpression with unknown name is a no-op":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.setLocals(@[makeEntry("x", "1")])
      vm.addFromExpression("not-here")

      check vm.entries.val.len == 0

      dispose()
