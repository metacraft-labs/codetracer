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
               isLiteral: bool = false;
               hasChildren: bool = false): ScratchpadValueEntry =
  ScratchpadValueEntry(
    expression: expression,
    valueText: valueText,
    isError: isError,
    isLiteral: isLiteral,
    hasChildren: hasChildren,
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
# Multi-iteration merging
#
# `GUI/Core-Panes/Scratchpad-Pane.md` §"Adding Values" / §"Multi-iteration
# Values": one row per expression, its value column a comma-separated list of
# the samples captured for it.  Adding a value that is already pinned must
# extend that list, never create a second row for the same expression.
#
# The idempotence case is also the last line of defence for #612: several
# entry points funnel into the same `InternalAddToScratchpad` sink, so a
# single user gesture must not be able to grow the list twice.
# ---------------------------------------------------------------------------

suite "ScratchpadVM multi-iteration merging":

  test "re-adding the same expression appends a comma-separated sample":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("remaining_shield", "10000"))
      vm.addValue(makeEntry("remaining_shield", "9150"))
      vm.addValue(makeEntry("remaining_shield", "8300"))

      check vm.entries.val.len == 1
      check vm.entries.val[0].expression == "remaining_shield"
      check vm.entries.val[0].valueText == "10000, 9150, 8300"
      check vm.rowCount.val == 1

      dispose()

  test "samples of a merged row can be recovered":
    check scratchpadSamples("10000, 9150, 8300") == @["10000", "9150", "8300"]
    check scratchpadSamples("42") == @["42"]
    check scratchpadSamples("") == newSeq[string]()

  test "re-adding an identical value leaves exactly one row and one sample":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      for _ in 0 ..< 4:
        vm.addValue(makeEntry("i", "5"))

      check vm.entries.val.len == 1
      check vm.entries.val[0].valueText == "5"

      dispose()

  test "a value equal to the last sample is dropped, an earlier one is kept":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("i", "1"))
      vm.addValue(makeEntry("i", "2"))
      vm.addValue(makeEntry("i", "2"))   # unchanged since the last capture
      vm.addValue(makeEntry("i", "1"))   # a genuine return to an old value

      check vm.entries.val.len == 1
      check vm.entries.val[0].valueText == "1, 2, 1"

      dispose()

  test "different expressions keep their own rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("remaining_shield", "10000"))
      vm.addValue(makeEntry("damage", "850"))
      vm.addValue(makeEntry("remaining_shield", "9150"))
      vm.addValue(makeEntry("damage", "650"))

      check vm.entries.val.len == 2
      check vm.entries.val[0].expression == "remaining_shield"
      check vm.entries.val[0].valueText == "10000, 9150"
      check vm.entries.val[1].expression == "damage"
      check vm.entries.val[1].valueText == "850, 650"

      dispose()

  test "composite values are not merged":
    # A row with children renders an expandable tree belonging to one capture;
    # concatenating the text of two captures would leave the tree describing
    # only the first.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("point", "(x: 1, y: 2)", hasChildren = true))
      vm.addValue(makeEntry("point", "(x: 3, y: 4)", hasChildren = true))

      check vm.entries.val.len == 2

      dispose()

  test "errors are not merged into a value row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("i", "5"))
      vm.addValue(makeEntry("i", "not available", isError = true))

      check vm.entries.val.len == 2
      check vm.entries.val[0].valueText == "5"
      check vm.entries.val[1].isError

      dispose()

  test "addFromExpression merges into the row it already has":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.setLocals(@[makeEntry("x", "1")])
      vm.addFromExpression("x")
      vm.setLocals(@[makeEntry("x", "2")])
      vm.addFromExpression("x")

      check vm.entries.val.len == 1
      check vm.entries.val[0].valueText == "1, 2"

      dispose()

  test "removeValue drops the whole merged row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeEntry("a", "1"))
      vm.addValue(makeEntry("a", "2"))
      vm.addValue(makeEntry("b", "9"))

      vm.removeValue(0)

      check vm.entries.val.len == 1
      check vm.entries.val[0].expression == "b"

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
