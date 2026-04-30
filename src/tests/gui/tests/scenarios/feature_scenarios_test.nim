## test_feature_scenarios.nim
##
## Comprehensive headless ViewModel tests covering core debugging features
## that GUI tests exercise but the existing headless tests do not fully cover.
##
## This file focuses on realistic debugging scenarios, testing features
## end-to-end through the SessionViewModel + MockBackendService stack.
## Each test simulates what a developer actually does when debugging:
## navigating event logs, using flow visualization, managing tracepoints,
## tracking values in the scratchpad, running multiple sessions, issuing
## step/continue commands, and navigating across files.
##
## Feature areas covered:
## 1. Event Log Navigation — row selection, pagination, sorting, search,
##    double-click navigation, and debugger-driven reloading
## 2. Flow Visualization & Loop Iterations — mode switching, iteration
##    control, data loading, and step navigation
## 3. Tracepoint & Point List Management — selection, editing lifecycle,
##    and multi-point workflows
## 4. Scratchpad Value Tracking — item management, comparison mode,
##    and selection in various modes
## 5. Multi-Session Management — independent stores, isolated state,
##    and session switching
## 6. Continue & Breakpoint Commands — continue, reverse-continue,
##    step-in, step-out, and command sequencing
## 7. Editor Multi-File State — file tracking, cursor positioning,
##    tab management, and overlay toggles
## 8. Full Debugging Workflow — complete end-to-end session exercising
##    all panels together
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_feature_scenarios.nim

import std/[json, unittest, options, sets]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import store/request_tracker
import session_vm
import viewmodels/[
  state_vm,
  calltrace_vm,
  debug_controls_vm,
  editor_vm,
  timeline_vm,
  event_log_vm,
  flow_vm,
  point_list_vm,
  scratchpad_vm,
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeCallLine(index: int64; name: string; depth: int = 0;
                  rrTicks: uint64 = 0; file: string = "";
                  line: int = 0): CallLine =
  ## Convenience constructor for CallLine test data.
  CallLine(
    index: index,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: file, line: line, column: 0),
  )

proc countCommands(mock: MockBackendService; command: string): int =
  ## Count how many times a specific command was sent to the mock.
  result = 0
  for rc in mock.receivedCommands:
    if rc.command == command:
      inc result

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

# ===========================================================================
# 1. Event Log Navigation
# ===========================================================================

suite "Event Log: row selection and navigation":

  test "selecting a row updates the selection signal":
    ## Simulates a developer clicking a row in the event log.
    ## The selected row should update to the clicked index.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      # Initially no row is selected.
      check vm.selectedRow.val.isNone

      # Click row 5.
      vm.selectRow(some(5))
      check vm.selectedRow.val == some(5)

      # Click a different row.
      vm.selectRow(some(12))
      check vm.selectedRow.val == some(12)

      # Click the same row again -- selection should remain.
      vm.selectRow(some(12))
      check vm.selectedRow.val == some(12)

      dispose()

  test "selecting a row then clearing restores no-selection state":
    ## Developer clicks a row, then clicks elsewhere to deselect.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.selectRow(some(3))
      check vm.selectedRow.val == some(3)

      # Deselect by passing none.
      vm.selectRow(none(int))
      check vm.selectedRow.val.isNone

      dispose()

  test "double-click row navigates to event location via backend":
    ## Simulates a developer double-clicking an event log row to jump
    ## to the corresponding source location. The backend should receive
    ## a ct/event-jump command with the event's ID and line number.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      # Populate realistic event rows.
      vm.eventRows.val = @[
        EventLogRow(eventId: 100'u64, kind: "call", line: 15,
                    value: "fibonacci(10)"),
        EventLogRow(eventId: 101'u64, kind: "assignment", line: 18,
                    value: "result = 55"),
        EventLogRow(eventId: 102'u64, kind: "return", line: 22,
                    value: "55"),
      ]

      mock.clearReceivedCommands()

      # Double-click the assignment event (row 1).
      vm.doubleClickRow(1)
      drain()

      let jumpCmd = mock.findCommand("ct/event-jump")
      check jumpCmd.isSome
      check jumpCmd.get.args["eventId"].getBiggestInt == 101
      check jumpCmd.get.args["line"].getInt == 18

      dispose()

  test "double-click on first and last rows works correctly":
    ## Boundary check: the first and last rows should both be navigable.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      vm.eventRows.val = @[
        EventLogRow(eventId: 50'u64, kind: "call", line: 1,
                    value: "main()"),
        EventLogRow(eventId: 51'u64, kind: "assignment", line: 5,
                    value: "x = 0"),
        EventLogRow(eventId: 52'u64, kind: "return", line: 99,
                    value: "exit(0)"),
      ]

      # Double-click first row.
      mock.clearReceivedCommands()
      vm.doubleClickRow(0)
      drain()

      var cmd = mock.findCommand("ct/event-jump")
      check cmd.isSome
      check cmd.get.args["eventId"].getBiggestInt == 50
      check cmd.get.args["line"].getInt == 1

      # Double-click last row.
      mock.clearReceivedCommands()
      vm.doubleClickRow(2)
      drain()

      cmd = mock.findCommand("ct/event-jump")
      check cmd.isSome
      check cmd.get.args["eventId"].getBiggestInt == 52
      check cmd.get.args["line"].getInt == 99

      dispose()

  test "event log loads when debugger moves to a new position":
    ## When the debugger steps to a new execution point, the event log
    ## should automatically request fresh data for that position.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      # Move debugger to trigger the auto-load effect.
      var dbg = store.debugger.val
      dbg.rrTicks = 500'u64
      store.debugger.val = dbg
      drain()

      let cmd = mock.findCommand("ct/event-load")
      check cmd.isSome
      check cmd.get.args["rrTicks"].getBiggestInt == 500

      dispose()

  test "event log request includes current page and sort parameters":
    ## The auto-load effect should pass along pagination and sort state
    ## so the backend returns the correct slice of events.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      # Configure page 2 with custom page size and sort.
      vm.totalEventCount.val = 300
      vm.currentPage.val = 2
      vm.setPageSize(25)
      # setPageSize resets page to 0, so set it again.
      vm.currentPage.val = 2
      vm.sort(3)  # Sort by column 3, ascending.
      mock.clearReceivedCommands()

      # Trigger the auto-load via debugger move.
      var dbg = store.debugger.val
      dbg.rrTicks = 700'u64
      store.debugger.val = dbg
      drain()

      let cmd = mock.findCommand("ct/event-load")
      check cmd.isSome
      check cmd.get.args["page"].getInt == 2
      check cmd.get.args["pageSize"].getInt == 25
      check cmd.get.args["sortColumn"].getInt == 3
      check cmd.get.args["sortAscending"].getBool == true

      dispose()

  test "pagination next/prev changes displayed page":
    ## Simulates paging through a large event log.
    ## With 200 events and page size 50, there are 4 pages (0..3).
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.totalEventCount.val = 200

      # Start at page 0.
      check vm.currentPage.val == 0
      check vm.totalPages.val == 4

      # Next page -> page 1.
      vm.nextPage()
      check vm.currentPage.val == 1

      # Next page -> page 2.
      vm.nextPage()
      check vm.currentPage.val == 2

      # Prev page -> page 1.
      vm.prevPage()
      check vm.currentPage.val == 1

      # Prev page -> page 0.
      vm.prevPage()
      check vm.currentPage.val == 0

      # Prev page at page 0 -> stays at 0.
      vm.prevPage()
      check vm.currentPage.val == 0

      dispose()

  test "pagination clamped at last page":
    ## Cannot go past the last page.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.totalEventCount.val = 120
      # 120 / 50 = 3 pages (0, 1, 2).
      check vm.totalPages.val == 3

      vm.currentPage.val = 2  # Last page.
      vm.nextPage()
      check vm.currentPage.val == 2  # Clamped.

      dispose()

  test "search filters events and resets page":
    ## Setting a search query resets pagination to page 0 so the user
    ## sees results from the beginning.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      vm.totalEventCount.val = 200
      vm.currentPage.val = 3

      vm.setSearchQuery("TypeError")
      check vm.searchQuery.val == "TypeError"
      check vm.currentPage.val == 0  # Reset to first page.

      # Trigger auto-load to verify search is included.
      mock.clearReceivedCommands()
      var dbg = store.debugger.val
      dbg.rrTicks = 100'u64
      store.debugger.val = dbg
      drain()

      let cmd = mock.findCommand("ct/event-load")
      check cmd.isSome
      check cmd.get.args["searchQuery"].getStr == "TypeError"

      dispose()

  test "sort by column sends new request with toggled direction":
    ## Clicking a column header to sort, then clicking again to reverse.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      # Sort by column 2 (ascending by default).
      vm.sort(2)
      check vm.sortColumn.val == 2
      check vm.sortAscending.val == true

      # Click column 2 again -> descending.
      vm.sort(2)
      check vm.sortColumn.val == 2
      check vm.sortAscending.val == false

      # Click a different column -> resets to ascending.
      vm.sort(0)
      check vm.sortColumn.val == 0
      check vm.sortAscending.val == true

      dispose()

  test "empty event log has zero total pages":
    ## Edge case: no events loaded.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      check vm.totalEventCount.val == 0
      check vm.totalPages.val == 0

      # nextPage on empty is a no-op.
      vm.nextPage()
      check vm.currentPage.val == 0

      dispose()

# ===========================================================================
# 2. Flow Visualization & Loop Iterations
# ===========================================================================

suite "Flow: mode switching and iteration control":

  test "flow mode switching requests new data from backend":
    ## Switching from fmCall to fmLine should trigger a new flow data
    ## request with the updated mode, allowing the developer to see
    ## flow at a different granularity.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      # Position the debugger so the auto-load guard passes.
      var dbg = store.debugger.val
      dbg.rrTicks = 300'u64
      store.debugger.val = dbg
      drain()

      let countBefore = mock.receivedCommands.len

      # Switch to line mode.
      vm.setMode(fmLine)
      drain()

      # A new request with fmLine should have been sent.
      var found = false
      for i in countBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "ct/load-flow":
          check cmd.args["flowMode"].getStr == "fmLine"
          found = true
          break
      check found

      dispose()

  test "switching through all three flow modes":
    ## Exercise all mode transitions: fmCall -> fmLine -> fmFunction -> fmCall.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      check vm.flowMode.val == fmCall

      vm.setMode(fmLine)
      check vm.flowMode.val == fmLine

      vm.setMode(fmFunction)
      check vm.flowMode.val == fmFunction

      vm.setMode(fmCall)
      check vm.flowMode.val == fmCall

      dispose()

  test "iteration selection updates with clamping at boundaries":
    ## A loop with 10 iterations should allow selection 0..9.
    ## Attempts to go out of range are clamped.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 10
      check vm.totalIterations.val == 10

      # Select middle iteration.
      vm.selectIteration(5)
      check vm.selectedIteration.val == 5

      # Select last iteration.
      vm.selectIteration(9)
      check vm.selectedIteration.val == 9

      # Attempt to select past the end -> clamped to 9.
      vm.selectIteration(15)
      check vm.selectedIteration.val == 9

      # Attempt negative -> clamped to 0.
      vm.selectIteration(-1)
      check vm.selectedIteration.val == 0

      # Select first iteration.
      vm.selectIteration(0)
      check vm.selectedIteration.val == 0

      dispose()

  test "iteration selection when iteration count changes":
    ## If the developer navigates to code with fewer iterations,
    ## the selected iteration should be clamped automatically when
    ## the user tries to select beyond the new range.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 20
      vm.selectIteration(15)
      check vm.selectedIteration.val == 15

      # Reduce iterations (e.g. moved to a different loop).
      vm.iterationCount.val = 5
      # The selected iteration remains at 15 until re-selected.
      # Attempting to select an out-of-range value is clamped.
      vm.selectIteration(15)
      check vm.selectedIteration.val == 4  # clamped to max (5-1)

      dispose()

  test "flow data loads when debugger moves":
    ## Moving the debugger to a new position should trigger a flow
    ## data request with the new rrTicks.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      var dbg = store.debugger.val
      dbg.rrTicks = 1000'u64
      store.debugger.val = dbg
      drain()

      let cmd = mock.findCommand("ct/load-flow")
      check cmd.isSome
      check cmd.get.args["rrTicks"].getBiggestInt == 1000

      dispose()

  test "flow step click navigates to step position":
    ## Clicking a step in the flow visualization should send a
    ## ct/flow-jump command to the backend with the step index,
    ## current mode, and iteration.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      # Set up mode and iteration context.
      vm.setMode(fmLine)
      vm.iterationCount.val = 8
      vm.selectIteration(3)

      mock.clearReceivedCommands()

      # Click step 7 in the flow view.
      vm.clickStep(7)
      drain()

      let cmd = mock.findCommand("ct/flow-jump")
      check cmd.isSome
      check cmd.get.args["step"].getInt == 7
      check cmd.get.args["flowMode"].getStr == "fmLine"
      check cmd.get.args["iteration"].getInt == 3

      dispose()

  test "hover step sets and clears correctly":
    ## Moving the mouse over flow steps should update the hover state.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      check vm.hoveredStep.val.isNone

      vm.hoverStep(some(5))
      check vm.hoveredStep.val == some(5)

      vm.hoverStep(some(10))
      check vm.hoveredStep.val == some(10)

      # Mouse leaves the flow area.
      vm.hoverStep(none(int))
      check vm.hoveredStep.val.isNone

      dispose()

  test "toggle raw values switches display mode":
    ## Developers can toggle between formatted and raw value display.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      check vm.showRawValues.val == false
      vm.toggleRawValues()
      check vm.showRawValues.val == true
      vm.toggleRawValues()
      check vm.showRawValues.val == false

      dispose()

  test "flow does not load for rrTicks zero":
    ## If the debugger has not yet moved (rrTicks == 0), no flow
    ## request should be sent.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      # rrTicks is 0 by default -- no request should fire.
      for cmd in mock.receivedCommands:
        check cmd.command != "ct/load-flow"

      dispose()

# ===========================================================================
# 3. Tracepoint & Point List Management
# ===========================================================================

suite "PointList: breakpoint and tracepoint management":

  test "selecting a point updates the selection signal":
    ## Developer clicks a breakpoint in the point list.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      check vm.selectedPoint.val.isNone

      vm.selectPoint(some(3))
      check vm.selectedPoint.val == some(3)

      vm.selectPoint(some(7))
      check vm.selectedPoint.val == some(7)

      dispose()

  test "editing mode tracks which point is being edited":
    ## Developer starts inline editing on a point, then stops.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      # Start editing point 2.
      vm.startEditing(2)
      check vm.editingPoint.val == some(2)
      # Editing also selects the point.
      check vm.selectedPoint.val == some(2)

      # Stop editing.
      vm.stopEditing()
      check vm.editingPoint.val.isNone
      # Selection should remain.
      check vm.selectedPoint.val == some(2)

      dispose()

  test "editing one point then switching to edit another":
    ## Developer edits a point, then immediately starts editing a
    ## different one without explicitly stopping.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(1)
      check vm.editingPoint.val == some(1)
      check vm.selectedPoint.val == some(1)

      # Switch directly to editing point 4.
      vm.startEditing(4)
      check vm.editingPoint.val == some(4)
      check vm.selectedPoint.val == some(4)

      dispose()

  test "selection and editing are independent":
    ## Selecting a different point while editing does not stop editing,
    ## and stopping editing does not change selection.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      # Start editing point 3.
      vm.startEditing(3)
      check vm.editingPoint.val == some(3)

      # Select a different point manually (e.g. via keyboard).
      vm.selectPoint(some(6))
      check vm.selectedPoint.val == some(6)
      # Editing still active on point 3.
      check vm.editingPoint.val == some(3)

      # Stop editing.
      vm.stopEditing()
      check vm.editingPoint.val.isNone
      # Selection remains on 6.
      check vm.selectedPoint.val == some(6)

      dispose()

  test "clearing selection when nothing is selected is a no-op":
    ## Edge case: clearing already-cleared selection.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      check vm.selectedPoint.val.isNone
      vm.selectPoint(none(int))
      check vm.selectedPoint.val.isNone

      dispose()

  test "stop editing when not editing is a no-op":
    ## Edge case: calling stopEditing without startEditing.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      check vm.editingPoint.val.isNone
      vm.stopEditing()
      check vm.editingPoint.val.isNone

      dispose()

  test "rapid edit-select-edit cycle":
    ## Simulates a developer rapidly interacting with the point list:
    ## edit -> select different -> edit new -> stop.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(0)
      check vm.editingPoint.val == some(0)
      check vm.selectedPoint.val == some(0)

      vm.selectPoint(some(2))
      check vm.selectedPoint.val == some(2)

      vm.startEditing(2)
      check vm.editingPoint.val == some(2)
      check vm.selectedPoint.val == some(2)

      vm.stopEditing()
      check vm.editingPoint.val.isNone
      check vm.selectedPoint.val == some(2)

      vm.selectPoint(none(int))
      check vm.selectedPoint.val.isNone

      dispose()

# ===========================================================================
# 4. Scratchpad Value Tracking
# ===========================================================================

suite "Scratchpad: value tracking and comparison":

  test "selected item tracking":
    ## Developer selects different items in the scratchpad to inspect
    ## their values at the current execution point.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      check vm.selectedItem.val.isNone

      # Select item 0.
      vm.selectItem(some(0))
      check vm.selectedItem.val == some(0)

      # Select item 2.
      vm.selectItem(some(2))
      check vm.selectedItem.val == some(2)

      # Clear selection.
      vm.selectItem(none(int))
      check vm.selectedItem.val.isNone

      dispose()

  test "comparison mode toggle":
    ## Developer enables comparison mode to see two values side by side
    ## at different execution points (e.g. before and after a mutation).
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      check vm.comparisonMode.val == false

      vm.toggleComparisonMode()
      check vm.comparisonMode.val == true

      vm.toggleComparisonMode()
      check vm.comparisonMode.val == false

      dispose()

  test "selection persists across comparison mode toggles":
    ## Toggling comparison mode should not affect which item is selected.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.selectItem(some(1))
      check vm.selectedItem.val == some(1)

      vm.toggleComparisonMode()
      check vm.comparisonMode.val == true
      check vm.selectedItem.val == some(1)  # Still selected.

      vm.toggleComparisonMode()
      check vm.comparisonMode.val == false
      check vm.selectedItem.val == some(1)  # Still selected.

      dispose()

  test "selection works independently in comparison mode":
    ## Developer can change selection while comparison mode is on.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.toggleComparisonMode()
      check vm.comparisonMode.val == true

      vm.selectItem(some(0))
      check vm.selectedItem.val == some(0)

      vm.selectItem(some(3))
      check vm.selectedItem.val == some(3)

      vm.selectItem(none(int))
      check vm.selectedItem.val.isNone

      dispose()

  test "rapid selection changes in comparison mode":
    ## Stress test: rapidly changing selection should not corrupt state.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.toggleComparisonMode()

      for i in 0 ..< 20:
        vm.selectItem(some(i))
        check vm.selectedItem.val == some(i)

      vm.selectItem(none(int))
      check vm.selectedItem.val.isNone
      check vm.comparisonMode.val == true

      dispose()

# ===========================================================================
# 5. Multi-Session Management
# ===========================================================================

suite "Multi-session: independent debugger state":

  test "two sessions have independent stores":
    ## Two debugging sessions open simultaneously should not share
    ## state. Moving the debugger in session 1 should not affect
    ## session 2.
    createRoot proc(dispose: proc()) =
      let mock1 = newMockBackendService(autoRespond = true)
      let session1 = createSessionVM(mock1.toBackendService())
      drain()

      let mock2 = newMockBackendService(autoRespond = true)
      let session2 = createSessionVM(mock2.toBackendService())
      drain()

      # Move debugger in session 1 to main.py:42.
      session1.store.updateDebuggerPosition(500'u64, "main.py", 42)
      drain()

      # Session 1 should be at main.py.
      check session1.editorVM.activeFileName.val == "main.py"
      check session1.timelineVM.currentPosition.val == 500'u64

      # Session 2 should be untouched -- still at default.
      check session2.editorVM.activeFileName.val == ""
      check session2.timelineVM.currentPosition.val == 0'u64

      dispose()

  test "variables are isolated between sessions":
    ## Setting locals in session 1 should not appear in session 2.
    createRoot proc(dispose: proc()) =
      let mock1 = newMockBackendService(autoRespond = true)
      let session1 = createSessionVM(mock1.toBackendService())

      let mock2 = newMockBackendService(autoRespond = true)
      let session2 = createSessionVM(mock2.toBackendService())

      # Set locals in session 1.
      session1.store.updateLocals(@[
        Variable(name: "x", value: "42", typeName: "int",
                 hasChildren: false, children: @[]),
      ])

      # Set different locals in session 2.
      session2.store.updateLocals(@[
        Variable(name: "y", value: "99", typeName: "float",
                 hasChildren: false, children: @[]),
      ])

      # Session 1 shows x=42.
      check session1.stateVM.currentVariables.val.len == 1
      check session1.stateVM.currentVariables.val[0].name == "x"
      check session1.stateVM.currentVariables.val[0].value == "42"

      # Session 2 shows y=99.
      check session2.stateVM.currentVariables.val.len == 1
      check session2.stateVM.currentVariables.val[0].name == "y"
      check session2.stateVM.currentVariables.val[0].value == "99"

      dispose()

  test "stepping in one session does not affect other":
    ## Step commands sent in session 1 should not produce any commands
    ## in session 2's backend.
    createRoot proc(dispose: proc()) =
      let mock1 = newMockBackendService(autoRespond = true)
      let session1 = createSessionVM(mock1.toBackendService())
      drain()

      let mock2 = newMockBackendService(autoRespond = true)
      let session2 = createSessionVM(mock2.toBackendService())
      drain()

      mock2.clearReceivedCommands()

      # Step forward in session 1.
      session1.debugControlsVM.stepForward()
      drain()

      # Session 1 should have sent the step command.
      check mock1.countCommands("next") >= 1

      # Session 2 should have received no commands at all.
      check mock2.receivedCommands.len == 0

      dispose()

  test "watch expressions are isolated between sessions":
    ## Adding a watch in session 1 should not appear in session 2.
    createRoot proc(dispose: proc()) =
      let mock1 = newMockBackendService(autoRespond = true)
      let session1 = createSessionVM(mock1.toBackendService())

      let mock2 = newMockBackendService(autoRespond = true)
      let session2 = createSessionVM(mock2.toBackendService())

      session1.stateVM.addWatch("counter * 2")
      session2.stateVM.addWatch("total + tax")

      check session1.stateVM.watchExpressions.val.len == 1
      check session1.stateVM.watchExpressions.val[0] == "counter * 2"

      check session2.stateVM.watchExpressions.val.len == 1
      check session2.stateVM.watchExpressions.val[0] == "total + tax"

      dispose()

  test "debug controls state is independent across sessions":
    ## One session in stepping state, another idle.
    createRoot proc(dispose: proc()) =
      let mock1 = newMockBackendService(autoRespond = true)
      let session1 = createSessionVM(mock1.toBackendService())
      drain()

      let mock2 = newMockBackendService(autoRespond = true)
      let session2 = createSessionVM(mock2.toBackendService())
      drain()

      # Session 1: step forward (enters dsStepping).
      session1.debugControlsVM.stepForward()
      check session1.debugControlsVM.isRunning.val == true
      check session1.debugControlsVM.statusText.val == "Stepping..."

      # Session 2 should still be idle.
      check session2.debugControlsVM.isRunning.val == false
      check session2.debugControlsVM.statusText.val == "Idle"

      dispose()

# ===========================================================================
# 6. Continue & Breakpoint Commands
# ===========================================================================

suite "Debugger: continue and breakpoint operations":

  test "continue sends continue command to backend":
    ## Developer presses Continue (F5) to run until the next breakpoint.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      mock.clearReceivedCommands()
      session.debugControlsVM.continueExecution()
      drain()

      let cmd = mock.findCommand("continue")
      check cmd.isSome
      check cmd.get.args["direction"].getStr == "sdContinue"

      dispose()

  test "reverse continue sends reverse-continue command":
    ## Developer presses Reverse Continue to go back to the previous
    ## breakpoint hit.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Set timeline range and debugger past the start.
      var tl = session.store.timeline.val
      tl.minRRTicks = 0'u64
      tl.maxRRTicks = 10000'u64
      session.store.timeline.val = tl

      session.store.updateDebuggerPosition(5000'u64, "app.py", 50)
      drain()

      mock.clearReceivedCommands()
      session.debugControlsVM.reverseContinue()
      drain()

      let cmd = mock.findCommand("reverseContinue")
      check cmd.isSome
      check cmd.get.args["direction"].getStr == "sdReverseContinue"

      dispose()

  test "step in sends stepIn command":
    ## Developer presses Step In (F11) to enter a function call.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      mock.clearReceivedCommands()
      session.debugControlsVM.stepIn()
      drain()

      let cmd = mock.findCommand("stepIn")
      check cmd.isSome
      check cmd.get.args["direction"].getStr == "sdStepIn"

      dispose()

  test "step out sends stepOut command":
    ## Developer presses Step Out (Shift+F11) to return to caller.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      mock.clearReceivedCommands()
      session.debugControlsVM.stepOut()
      drain()

      let cmd = mock.findCommand("stepOut")
      check cmd.isSome
      check cmd.get.args["direction"].getStr == "sdStepOut"

      dispose()

  test "step backward sends backward step command":
    ## Developer presses Reverse Step to go back one execution step.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Set timeline so backward step is allowed.
      var tl = session.store.timeline.val
      tl.minRRTicks = 0'u64
      tl.maxRRTicks = 5000'u64
      session.store.timeline.val = tl

      session.store.updateDebuggerPosition(1000'u64, "main.py", 10)
      drain()

      mock.clearReceivedCommands()
      session.debugControlsVM.stepBackward()
      drain()

      let cmd = mock.findCommand("stepBack")
      check cmd.isSome
      check cmd.get.args["direction"].getStr == "sdBackward"

      dispose()

  test "continue after reverse step sends correct command sequence":
    ## Developer steps backward, then continues forward. Both
    ## commands should be sent in the correct order.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Set up timeline range.
      var tl = session.store.timeline.val
      tl.minRRTicks = 0'u64
      tl.maxRRTicks = 10000'u64
      session.store.timeline.val = tl

      # Position at rrTicks 3000.
      session.store.updateDebuggerPosition(3000'u64, "algorithm.py", 30)
      drain()

      mock.clearReceivedCommands()

      # Step backward.
      session.debugControlsVM.stepBackward()
      drain()

      let stepBackCmd = mock.findCommand("stepBack")
      check stepBackCmd.isSome
      check stepBackCmd.get.args["direction"].getStr == "sdBackward"

      # Simulate the debugger arriving at a new position (rrTicks 2900).
      session.store.updateDebuggerPosition(2900'u64, "algorithm.py", 28)
      # Reset to idle so we can continue.
      var dbg = session.store.debugger.val
      dbg.status = dsIdle
      session.store.debugger.val = dbg
      drain()

      mock.clearReceivedCommands()

      # Continue forward.
      session.debugControlsVM.continueExecution()
      drain()

      let contCmd = mock.findCommand("continue")
      check contCmd.isSome
      check contCmd.get.args["direction"].getStr == "sdContinue"

      dispose()

  test "commands are blocked when debugger is finished":
    ## Once the debugger reaches the end of the recording, no step or
    ## continue commands should be sent.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Mark debugger as finished.
      var dbg = session.store.debugger.val
      dbg.status = dsFinished
      session.store.debugger.val = dbg

      mock.clearReceivedCommands()

      session.debugControlsVM.stepForward()
      session.debugControlsVM.stepBackward()
      session.debugControlsVM.continueExecution()
      session.debugControlsVM.reverseContinue()
      session.debugControlsVM.stepIn()
      session.debugControlsVM.stepOut()
      drain()

      # No commands should have been sent.
      check mock.receivedCommands.len == 0

      dispose()

  test "commands are blocked when debugger is in error state":
    ## Same as above but for the error state.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      var dbg = session.store.debugger.val
      dbg.status = dsError
      session.store.debugger.val = dbg

      mock.clearReceivedCommands()

      session.debugControlsVM.stepForward()
      session.debugControlsVM.continueExecution()
      drain()

      check mock.receivedCommands.len == 0

      dispose()

  test "commands are blocked while a step is in progress":
    ## While the debugger is stepping, additional step commands
    ## should be rejected (double-click protection).
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Initiate a step.
      session.debugControlsVM.stepForward()
      check session.debugControlsVM.isRunning.val == true

      mock.clearReceivedCommands()

      # Try to issue more commands while stepping.
      session.debugControlsVM.stepForward()
      session.debugControlsVM.continueExecution()
      session.debugControlsVM.stepIn()
      drain()

      # No additional step commands should have been sent because
      # canStepForward and canContinue are false while dsStepping.
      check mock.countCommands("next") + mock.countCommands("stepBack") +
            mock.countCommands("stepIn") + mock.countCommands("stepOut") +
            mock.countCommands("continue") + mock.countCommands("reverseContinue") == 0

      dispose()

# ===========================================================================
# 7. Editor Multi-File State
# ===========================================================================

suite "Editor: multi-file navigation and state":

  test "debugger move to new file updates active file":
    ## Stepping from main.py to solver.py should update the editor's
    ## active file name.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Start at main.py:10.
      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()
      check session.editorVM.activeFileName.val == "main.py"

      # Step into solver.py:20.
      session.store.updateDebuggerPosition(200'u64, "solver.py", 20)
      drain()
      check session.editorVM.activeFileName.val == "solver.py"

      # Step into utils.py:5.
      session.store.updateDebuggerPosition(300'u64, "utils.py", 5)
      drain()
      check session.editorVM.activeFileName.val == "utils.py"

      dispose()

  test "calltrace navigation to different file":
    ## Double-clicking a calltrace entry in a different file should
    ## send a navigation command with that file's location.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Populate calltrace with entries in different files.
      session.store.calltrace.lines.val = @[
        makeCallLine(0, "main", depth = 0, rrTicks = 100,
                     file = "main.py", line = 1),
        makeCallLine(1, "calculate", depth = 1, rrTicks = 200,
                     file = "math_utils.py", line = 42),
        makeCallLine(2, "format_result", depth = 1, rrTicks = 300,
                     file = "formatters.py", line = 15),
      ]
      session.store.calltrace.startLineIndex.val = 0'i64
      session.store.calltrace.totalCallsCount.val = 100'u64

      session.calltraceVM.setViewportHeight(10)

      mock.clearReceivedCommands()

      # Double-click the "calculate" entry in math_utils.py.
      session.calltraceVM.doubleClickEntry(1)
      drain()

      let cmd = mock.findCommand("ct/calltrace-jump")
      check cmd.isSome
      check cmd.get.args["file"].getStr == "math_utils.py"
      check cmd.get.args["line"].getInt == 42
      check cmd.get.args["rrTicks"].getBiggestInt == 200

      dispose()

  test "cursor position can be set and read":
    ## Developer clicks in the editor at a specific position.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      # Default cursor position.
      check session.editorVM.cursorLine.val == 1
      check session.editorVM.cursorColumn.val == 1

      # Set cursor to line 15, column 8.
      session.editorVM.setCursor(15, 8)
      check session.editorVM.cursorLine.val == 15
      check session.editorVM.cursorColumn.val == 8

      # Move cursor to a different position.
      session.editorVM.setCursor(42, 20)
      check session.editorVM.cursorLine.val == 42
      check session.editorVM.cursorColumn.val == 20

      dispose()

  test "cursor position clamps negative values":
    ## Edge case: attempting to set cursor below line/column 1.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      session.editorVM.setCursor(-5, 0)
      check session.editorVM.cursorLine.val == 1   # Clamped to 1.
      check session.editorVM.cursorColumn.val == 1  # Clamped to 1.

      dispose()

  test "tab switching and closing":
    ## Developer opens multiple files and switches between them.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      check session.editorVM.activeTabIndex.val == 0

      # Switch to tab 2.
      session.editorVM.switchTab(2)
      check session.editorVM.activeTabIndex.val == 2

      # Switch to tab 1.
      session.editorVM.switchTab(1)
      check session.editorVM.activeTabIndex.val == 1

      # Close tab 1 (the active tab) -> resets to 0.
      session.editorVM.closeTab(1)
      check session.editorVM.activeTabIndex.val == 0

      dispose()

  test "closing tab to the left adjusts active index":
    ## Closing a tab to the left of the active tab should shift
    ## the active tab index left by one.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      session.editorVM.switchTab(3)
      check session.editorVM.activeTabIndex.val == 3

      # Close tab 1 (to the left of active tab 3).
      session.editorVM.closeTab(1)
      check session.editorVM.activeTabIndex.val == 2  # Shifted left.

      dispose()

  test "switchTab clamps negative index":
    ## Edge case: switching to a negative tab index.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      session.editorVM.switchTab(-1)
      check session.editorVM.activeTabIndex.val == 0

      dispose()

  test "flow overlay toggle":
    ## Developer toggles the flow overlay on the editor.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      check session.editorVM.showFlowOverlay.val == false

      session.editorVM.toggleFlowOverlay()
      check session.editorVM.showFlowOverlay.val == true

      session.editorVM.toggleFlowOverlay()
      check session.editorVM.showFlowOverlay.val == false

      dispose()

  test "breakpoint gutter toggle":
    ## Developer toggles the breakpoint gutter visibility.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      # Gutter is visible by default.
      check session.editorVM.showBreakpointGutter.val == true

      session.editorVM.toggleBreakpointGutter()
      check session.editorVM.showBreakpointGutter.val == false

      session.editorVM.toggleBreakpointGutter()
      check session.editorVM.showBreakpointGutter.val == true

      dispose()

  test "active file name tracks debugger across many files":
    ## Simulate navigating through a realistic call stack across
    ## multiple source files in a web application.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      let files = [
        ("app.py", 10, 100'u64),
        ("routes.py", 45, 200'u64),
        ("views.py", 112, 300'u64),
        ("models.py", 78, 400'u64),
        ("db.py", 33, 500'u64),
        ("models.py", 80, 600'u64),  # Return to models.py.
        ("views.py", 115, 700'u64),  # Return to views.py.
        ("routes.py", 48, 800'u64),  # Return to routes.py.
      ]

      for (file, line, ticks) in files:
        session.store.updateDebuggerPosition(ticks, file, line)
        drain()
        check session.editorVM.activeFileName.val == file

      dispose()

# ===========================================================================
# 8. Full Debugging Workflow
# ===========================================================================

suite "Full workflow: record -> replay -> debug":

  test "complete debugging session":
    ## Simulates a realistic debugging session from start to finish:
    ## 1. Initial state: connected, idle
    ## 2. Load trace -> debugger at entry (line 1)
    ## 3. Verify all panels have initial data requests
    ## 4. Step forward 3 times with variable changes
    ## 5. Navigate via calltrace to a specific function
    ## 6. Add watch expression
    ## 7. Step backward
    ## 8. Verify locals show previous state
    ## 9. Check event log has been requested
    ## 10. Check flow data loaded
    ## 11. Verify timeline position matches throughout
    ## 12. Cleanup
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Set up calltrace viewport.
      session.calltraceVM.setViewportHeight(30)
      drain()

      # Set up timeline range (simulating a recording).
      var tl = session.store.timeline.val
      tl.minRRTicks = 100'u64
      tl.maxRRTicks = 50000'u64
      session.store.timeline.val = tl

      # ---- Step 1: Initial state checks ----
      check session.debugControlsVM.statusText.val == "Idle"
      check session.debugControlsVM.canStepForward.val == true
      check session.stateVM.currentVariables.val.len == 0
      check session.editorVM.activeFileName.val == ""
      check session.timelineVM.currentPosition.val == 0'u64

      # ---- Step 2: Load trace -> debugger at entry ----
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(100'u64, "fibonacci.py", 1)
      drain()

      # Verify all panels requested initial data.
      check mock.findCommand("ct/load-locals").isSome
      check mock.findCommand("ct/load-calltrace-section").isSome
      check mock.findCommand("ct/event-load").isSome
      check mock.findCommand("ct/load-flow").isSome

      # Verify editor shows the right file.
      check session.editorVM.activeFileName.val == "fibonacci.py"
      check session.timelineVM.currentPosition.val == 100'u64

      # ---- Step 3: Initial locals arrive ----
      session.store.updateLocals(@[
        Variable(name: "n", value: "10", typeName: "int",
                 hasChildren: false, children: @[]),
      ])
      check session.stateVM.currentVariables.val.len == 1
      check session.stateVM.currentVariables.val[0].name == "n"
      check session.stateVM.currentVariables.val[0].value == "10"

      # ---- Step 4: Step forward 3 times ----
      # Step 1: line 3, x = 0
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(200'u64, "fibonacci.py", 3)
      drain()
      session.store.updateLocals(@[
        Variable(name: "n", value: "10", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "a", value: "0", typeName: "int",
                 hasChildren: false, children: @[]),
      ])
      check session.stateVM.currentVariables.val.len == 2
      check session.timelineVM.currentPosition.val == 200'u64

      # Step 2: line 4, y = 1
      session.store.updateDebuggerPosition(300'u64, "fibonacci.py", 4)
      drain()
      session.store.updateLocals(@[
        Variable(name: "n", value: "10", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "a", value: "0", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "b", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
      ])
      check session.stateVM.currentVariables.val.len == 3
      check session.timelineVM.currentPosition.val == 300'u64

      # Step 3: line 6 (inside loop), a = 1, b = 1
      session.store.updateDebuggerPosition(400'u64, "fibonacci.py", 6)
      drain()
      session.store.updateLocals(@[
        Variable(name: "n", value: "10", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "a", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "b", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "i", value: "0", typeName: "int",
                 hasChildren: false, children: @[]),
      ])
      check session.stateVM.currentVariables.val.len == 4
      check session.stateVM.currentVariables.val[1].value == "1"  # a
      check session.stateVM.currentVariables.val[3].name == "i"

      # ---- Step 5: Navigate via calltrace ----
      # Populate calltrace with a deep stack.
      session.store.calltrace.lines.val = @[
        makeCallLine(0, "main", depth = 0, rrTicks = 50,
                     file = "main.py", line = 1),
        makeCallLine(1, "fibonacci", depth = 1, rrTicks = 100,
                     file = "fibonacci.py", line = 1),
        makeCallLine(2, "fibonacci_helper", depth = 2, rrTicks = 350,
                     file = "fibonacci.py", line = 20),
      ]
      session.store.calltrace.startLineIndex.val = 0'i64
      session.store.calltrace.totalCallsCount.val = 50'u64

      mock.clearReceivedCommands()

      # Double-click "fibonacci_helper" entry.
      session.calltraceVM.doubleClickEntry(2)
      drain()

      let navCmd = mock.findCommand("ct/calltrace-jump")
      check navCmd.isSome
      check navCmd.get.args["file"].getStr == "fibonacci.py"
      check navCmd.get.args["line"].getInt == 20

      # ---- Step 6: Add watch expression ----
      mock.clearReceivedCommands()
      session.stateVM.addWatch("a + b")
      drain()

      # Verify a new locals request includes the watch.
      let watchCmd = mock.findCommand("ct/load-locals")
      check watchCmd.isSome
      let watches = watchCmd.get.args["watchExpressions"]
      check watches.len == 1
      check watches[0].getStr == "a + b"

      # ---- Step 7: Step backward ----
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(300'u64, "fibonacci.py", 4)
      drain()

      # Verify new data was requested.
      check mock.findCommand("ct/load-locals").isSome
      check mock.findCommand("ct/load-flow").isSome

      # ---- Step 8: Verify locals show previous state ----
      session.store.updateLocals(@[
        Variable(name: "n", value: "10", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "a", value: "0", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "b", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
      ])
      # Back at step 2 -- a is 0 again (time-travel).
      check session.stateVM.currentVariables.val[1].value == "0"
      check session.stateVM.currentVariables.val.len == 3

      # ---- Step 9: Verify event log was requested ----
      check mock.findCommand("ct/event-load").isSome

      # ---- Step 10: Verify flow data was requested ----
      check mock.findCommand("ct/load-flow").isSome

      # ---- Step 11: Timeline position matches ----
      check session.timelineVM.currentPosition.val == 300'u64

      # ---- Step 12: Verify timeline markers ----
      let markers = session.timelineVM.markers.val
      check markers.len == 2
      check markers[0] == 100'u64   # minRRTicks
      check markers[1] == 50000'u64 # maxRRTicks

      dispose()

  test "multi-panel consistency during rapid navigation":
    ## Simulates rapid navigation through a program, verifying that
    ## all panels stay consistent at each position.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      session.calltraceVM.setViewportHeight(20)
      drain()

      # Navigate through 5 positions rapidly.
      let positions = [
        (100'u64, "server.py", 10),
        (250'u64, "handler.py", 25),
        (400'u64, "database.py", 42),
        (550'u64, "handler.py", 30),
        (700'u64, "server.py", 15),
      ]

      for (ticks, file, line) in positions:
        mock.clearReceivedCommands()
        session.store.updateDebuggerPosition(ticks, file, line)
        drain()

        # Verify consistency across all panels at each position.
        check session.editorVM.activeFileName.val == file
        check session.timelineVM.currentPosition.val == ticks

        # Verify all data panels sent requests.
        check mock.findCommand("ct/load-locals").isSome
        check mock.findCommand("ct/load-calltrace-section").isSome
        check mock.findCommand("ct/event-load").isSome
        check mock.findCommand("ct/load-flow").isSome

      dispose()

  test "tab switching mid-session shows correct variable source":
    ## During a debugging session, switching between locals, globals,
    ## and watches should show the right data source for each.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      # Populate both locals and globals.
      session.store.locals.locals.val = @[
        Variable(name: "request", value: "<Request GET /api>", typeName: "Request",
                 hasChildren: true, children: @[]),
        Variable(name: "user_id", value: "42", typeName: "int",
                 hasChildren: false, children: @[]),
      ]
      session.store.locals.globals.val = @[
        Variable(name: "app", value: "<Flask>", typeName: "Flask",
                 hasChildren: true, children: @[]),
        Variable(name: "config", value: "{...}", typeName: "dict",
                 hasChildren: true, children: @[]),
        Variable(name: "VERSION", value: "2.1.0", typeName: "str",
                 hasChildren: false, children: @[]),
      ]

      # Locals tab: 2 variables.
      check session.stateVM.activeTab.val == stLocals
      check session.stateVM.currentVariables.val.len == 2
      check session.stateVM.currentVariables.val[0].name == "request"

      # Globals tab: 3 variables.
      session.stateVM.selectTab(stGlobals)
      check session.stateVM.currentVariables.val.len == 3
      check session.stateVM.currentVariables.val[2].name == "VERSION"
      check session.stateVM.currentVariables.val[2].value == "2.1.0"

      # Watches tab: empty (not wired to backend results yet).
      session.stateVM.selectTab(stWatches)
      check session.stateVM.currentVariables.val.len == 0

      # Back to locals.
      session.stateVM.selectTab(stLocals)
      check session.stateVM.currentVariables.val.len == 2
      check session.stateVM.currentVariables.val[1].name == "user_id"

      dispose()

  test "timeline seek sends command to backend":
    ## Developer clicks on the timeline at a specific tick to jump there.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      mock.clearReceivedCommands()

      # Seek to tick 5000.
      session.timelineVM.seek(5000'u64)
      drain()

      let cmd = mock.findCommand("ct/timeline-seek")
      check cmd.isSome
      check cmd.get.args["rrTicks"].getBiggestInt == 5000

      dispose()

  test "timeline zoom and pan":
    ## Developer zooms in and pans the timeline.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      check session.timelineVM.zoomLevel.val == 1.0

      session.timelineVM.zoom(2.5)
      check session.timelineVM.zoomLevel.val == 2.5

      # Zoom clamps below 0.1.
      session.timelineVM.zoom(0.05)
      check session.timelineVM.zoomLevel.val == 0.1

      # Pan to a specific range.
      session.timelineVM.pan(1000'u64, 5000'u64)
      check session.timelineVM.viewStart.val == 1000'u64
      check session.timelineVM.viewEnd.val == 5000'u64

      dispose()

  test "timeline hover tracking":
    ## Developer hovers over the timeline at various positions.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      check session.timelineVM.hoveredTick.val.isNone

      session.timelineVM.hover(some(3000'u64))
      check session.timelineVM.hoveredTick.val == some(3000'u64)

      session.timelineVM.hover(some(7500'u64))
      check session.timelineVM.hoveredTick.val == some(7500'u64)

      # Mouse leaves timeline.
      session.timelineVM.hover(none(uint64))
      check session.timelineVM.hoveredTick.val.isNone

      dispose()

  test "calltrace search highlights matching entries":
    ## Developer searches for a function name in the calltrace.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      # Populate calltrace with various function names.
      session.store.calltrace.lines.val = @[
        makeCallLine(0, "main", depth = 0, rrTicks = 100,
                     file = "main.py", line = 1),
        makeCallLine(1, "process_request", depth = 1, rrTicks = 200,
                     file = "server.py", line = 10),
        makeCallLine(2, "validate_input", depth = 2, rrTicks = 300,
                     file = "validators.py", line = 5),
        makeCallLine(3, "process_response", depth = 1, rrTicks = 400,
                     file = "server.py", line = 50),
        makeCallLine(4, "format_output", depth = 2, rrTicks = 500,
                     file = "formatters.py", line = 20),
      ]
      session.store.calltrace.startLineIndex.val = 0'i64

      # Search for "process" -> should match indices 1 and 3.
      session.calltraceVM.setSearchQuery("process")
      let matches = session.calltraceVM.highlightedMatches.val
      check matches.len == 2
      check matches[0] == 1'i64  # process_request
      check matches[1] == 3'i64  # process_response

      # Case-insensitive search for "PROCESS".
      session.calltraceVM.setSearchQuery("PROCESS")
      let upperMatches = session.calltraceVM.highlightedMatches.val
      check upperMatches.len == 2

      # Clear search.
      session.calltraceVM.setSearchQuery("")
      check session.calltraceVM.highlightedMatches.val.len == 0

      dispose()

  test "variable tree expand/collapse tracking":
    ## Developer expands and collapses compound variables in the
    ## state panel's tree view.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      check session.stateVM.expandedPaths.val.len == 0

      # Expand "request".
      session.stateVM.toggleExpand("request")
      check "request" in session.stateVM.expandedPaths.val

      # Expand "request.headers".
      session.stateVM.toggleExpand("request.headers")
      check "request.headers" in session.stateVM.expandedPaths.val
      check session.stateVM.expandedPaths.val.len == 2

      # Collapse "request" (toggle off).
      session.stateVM.toggleExpand("request")
      check "request" notin session.stateVM.expandedPaths.val
      # "request.headers" is still expanded.
      check "request.headers" in session.stateVM.expandedPaths.val
      check session.stateVM.expandedPaths.val.len == 1

      dispose()

  test "variable path selection for keyboard navigation":
    ## Developer uses keyboard to navigate the variable tree.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      check session.stateVM.selectedPath.val == ""

      session.stateVM.selectPath("response")
      check session.stateVM.selectedPath.val == "response"

      session.stateVM.selectPath("response.body")
      check session.stateVM.selectedPath.val == "response.body"

      # Clear selection.
      session.stateVM.selectPath("")
      check session.stateVM.selectedPath.val == ""

      dispose()
