## test_calltrace_navigation.nim
##
## Moving through the call trace from the keyboard is the ViewModel's
## (`calltrace_navigation`): Up / Down / Page / Home / End move the selection
## over the trace and keep it in view, Left goes to the caller, Right into the
## call (expanding a collapsed one first), Enter goes to the selected call.
## Driven through a store holding a section, over a `MockBackendService`; what
## is asserted is the selection, the viewport and the requests sent.

import std/[json, options, unittest]

import isonim/core/[signals, computation]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewport
import viewmodels/[calltrace_vm, calltrace_navigation]

proc line(index: int; name: string; depth = 0; children = false;
          expanded = false): CallLine =
  CallLine(index: index.int64, name: name, depth: depth,
           hasChildren: children, isExpanded: expanded,
           callKey: "k" & $index,
           location: Location(file: "/src/main.py", line: index + 1),
           rrTicks: uint64(index + 1))

proc setup(total = 6): (ReplayDataStore, CalltraceVM, MockBackendService) =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  let vm = createCalltraceVM(store)
  store.updateCalltraceSection(@[
    line(0, "main", 0, children = true, expanded = true),
    line(1, "parse", 1),
    line(2, "eval", 1, children = true, expanded = false),
    line(3, "print", 1)], 0'i64, uint64(total))
  vm.setViewport(Viewport(rows: 3, firstRow: 0))
  (store, vm, mock)

suite "the call trace from the keyboard":

  test "Down and Up move the selection, clamped to the trace":
    let (_, vm, _) = setup()
    vm.moveSelection(1)
    check vm.selectedEntry.val == some(0'i64)   # nothing selected: the first row
    vm.moveSelection(1)
    vm.moveSelection(1)
    check vm.selectedEntry.val == some(2'i64)
    vm.moveSelection(-5)
    check vm.selectedEntry.val == some(0'i64)

  test "a selection past the visible rows scrolls the viewport to it":
    let (_, vm, _) = setup(total = 40)
    vm.selectIndex(10)
    check vm.selectedEntry.val == some(10'i64)
    check vm.viewport.val.firstRow == 8          # the last of three rows
    vm.selectIndex(2)
    check vm.viewport.val.firstRow == 2

  test "Page moves by the pane, Home and End by the trace":
    let (_, vm, _) = setup(total = 40)
    vm.selectFirst()
    vm.pageSelection(1)
    check vm.selectedEntry.val == some(2'i64)    # rows - 1
    vm.selectLast()
    check vm.selectedEntry.val == some(39'i64)

  test "Left goes to the caller":
    let (_, vm, _) = setup()
    vm.selectIndex(3)
    vm.selectParent()
    check vm.selectedEntry.val == some(0'i64)

  test "Right expands a collapsed call, then enters an expanded one":
    let (_, vm, mock) = setup()
    vm.selectIndex(2)
    mock.clearReceivedCommands()
    vm.selectFirstChild()
    check mock.findCommand("ct/expand-calls").isSome
    check vm.selectedEntry.val == some(2'i64)
    vm.selectIndex(0)
    vm.selectFirstChild()
    check vm.selectedEntry.val == some(1'i64)

  test "Enter goes to the selected call":
    let (_, vm, mock) = setup()
    vm.selectIndex(1)
    mock.clearReceivedCommands()
    vm.activateSelected()
    let jump = mock.findCommand("ct/calltrace-jump")
    check jump.isSome
    check jump.isSome and jump.get.args["rrTicks"].getInt == 2
