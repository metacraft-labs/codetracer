## test_event_log_vm.nim
##
## Unit tests for EventLogVM — the ViewModel for the Event Log panel.
##
## Verifies:
## - Initial state defaults (selectedRow, currentPage, pageSize, etc.)
## - selectRow updates selection
## - doubleClickRow sends navigation command
## - nextPage / prevPage update currentPage with clamping
## - sort toggles direction or sets new column
## - setSearchQuery updates query and resets page to 0
## - setPageSize updates size and resets page to 0
## - totalPages memo computes from totalEventCount and pageSize
## - isLoading memo reflects loading state
## - Auto-load effect fires when page/sort/search/rrTicks changes
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_event_log_vm.nim

import std/[json, unittest, options]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/event_log_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "EventLogVM initial state":

  test "selectedRow defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.selectedRow.val.isNone
      dispose()

  test "currentPage defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.currentPage.val == 0
      dispose()

  test "pageSize defaults to DEFAULT_PAGE_SIZE":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.pageSize.val == DEFAULT_PAGE_SIZE
      dispose()

  test "searchQuery starts as empty string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.searchQuery.val == ""
      dispose()

  test "sortColumn defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.sortColumn.val == 0
      dispose()

  test "sortAscending defaults to true":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.sortAscending.val == true
      dispose()

  test "isLoading starts false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.isLoading.val == false
      dispose()

  test "totalPages starts at 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.totalPages.val == 0
      dispose()

  test "eventRows starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      check vm.eventRows.val.len == 0
      dispose()

# ---------------------------------------------------------------------------
# Row selection
# ---------------------------------------------------------------------------

suite "EventLogVM row selection":

  test "selectRow sets the selected row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.selectRow(some(5))
      check vm.selectedRow.val == some(5)

      dispose()

  test "selectRow with none clears selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.selectRow(some(3))
      check vm.selectedRow.val.isSome

      vm.selectRow(none(int))
      check vm.selectedRow.val.isNone

      dispose()

# ---------------------------------------------------------------------------
# Double-click navigation
# ---------------------------------------------------------------------------

suite "EventLogVM doubleClickRow":

  test "doubleClickRow sends navigation command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      # Populate event rows directly.
      vm.eventRows.val = @[
        EventLogRow(eventId: 1'u64, kind: "call", line: 10, value: "foo()"),
        EventLogRow(eventId: 2'u64, kind: "return", line: 20, value: "42"),
      ]

      let cmdCountBefore = mock.receivedCommands.len

      vm.doubleClickRow(1)
      drain()

      # Should have sent an event-log-jump command.
      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      var found = false
      for cmd in jumpCmds:
        if cmd.command == "ct/event-jump":
          check cmd.args["eventId"].getBiggestInt == 2
          check cmd.args["line"].getInt == 20
          found = true
          break
      check found

      dispose()

  test "doubleClickRow is no-op for out-of-range index":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      vm.eventRows.val = @[
        EventLogRow(eventId: 1'u64, kind: "call", line: 10, value: "foo()"),
      ]

      let cmdCountBefore = mock.receivedCommands.len

      vm.doubleClickRow(99)
      drain()

      # No event-log-jump command should have been sent.
      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      for cmd in jumpCmds:
        check cmd.command != "ct/event-jump"

      dispose()

# ---------------------------------------------------------------------------
# Pagination
# ---------------------------------------------------------------------------

suite "EventLogVM pagination":

  test "nextPage increments currentPage":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      # Set total event count so there are multiple pages.
      vm.totalEventCount.val = 200
      vm.nextPage()
      check vm.currentPage.val == 1

      vm.nextPage()
      check vm.currentPage.val == 2

      dispose()

  test "nextPage does not exceed totalPages - 1":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      # 60 events, page size 50 -> 2 pages (indices 0, 1).
      vm.totalEventCount.val = 60
      vm.currentPage.val = 1

      vm.nextPage()
      # Should stay at 1 (max page index).
      check vm.currentPage.val == 1

      dispose()

  test "prevPage decrements currentPage":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.totalEventCount.val = 200
      vm.currentPage.val = 3

      vm.prevPage()
      check vm.currentPage.val == 2

      dispose()

  test "prevPage does not go below 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.prevPage()
      check vm.currentPage.val == 0

      dispose()

  test "setPageSize resets page to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.totalEventCount.val = 200
      vm.currentPage.val = 3

      vm.setPageSize(25)
      check vm.pageSize.val == 25
      check vm.currentPage.val == 0

      dispose()

  test "setPageSize ignores non-positive values":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.setPageSize(0)
      check vm.pageSize.val == DEFAULT_PAGE_SIZE

      vm.setPageSize(-5)
      check vm.pageSize.val == DEFAULT_PAGE_SIZE

      dispose()

# ---------------------------------------------------------------------------
# Sorting
# ---------------------------------------------------------------------------

suite "EventLogVM sorting":

  test "sort sets new column and defaults to ascending":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.sort(2)
      check vm.sortColumn.val == 2
      check vm.sortAscending.val == true

      dispose()

  test "sort toggles direction when same column":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.sort(1)
      check vm.sortAscending.val == true

      vm.sort(1)
      check vm.sortAscending.val == false

      vm.sort(1)
      check vm.sortAscending.val == true

      dispose()

  test "sort resets to ascending when changing column":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.sort(1)       # Set column 1, ascending.
      vm.sort(1)       # Toggle — now descending.
      check vm.sortAscending.val == false

      vm.sort(2)       # New column — should reset to ascending.
      check vm.sortColumn.val == 2
      check vm.sortAscending.val == true

      dispose()

# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

suite "EventLogVM search":

  test "setSearchQuery updates the search query":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.setSearchQuery("error")
      check vm.searchQuery.val == "error"

      dispose()

  test "setSearchQuery resets page to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.totalEventCount.val = 200
      vm.currentPage.val = 3

      vm.setSearchQuery("warning")
      check vm.currentPage.val == 0

      dispose()

# ---------------------------------------------------------------------------
# totalPages memo
# ---------------------------------------------------------------------------

suite "EventLogVM totalPages":

  test "totalPages computes correctly from event count and page size":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.totalEventCount.val = 120
      # pageSize is 50 by default -> ceil(120/50) = 3
      check vm.totalPages.val == 3

      dispose()

  test "totalPages is 0 when no events":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      check vm.totalPages.val == 0

      dispose()

  test "totalPages is 1 when events fit in a single page":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.totalEventCount.val = 30
      check vm.totalPages.val == 1

      dispose()

  test "totalPages updates when pageSize changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.totalEventCount.val = 100
      check vm.totalPages.val == 2  # 100 / 50 = 2

      vm.setPageSize(25)
      check vm.totalPages.val == 4  # 100 / 25 = 4

      dispose()

# ---------------------------------------------------------------------------
# isLoading memo
# ---------------------------------------------------------------------------

suite "EventLogVM isLoading":

  test "isLoading reflects loading state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      check vm.isLoading.val == false

      vm.loadingState.val = lsLoading
      check vm.isLoading.val == true

      vm.loadingState.val = lsIdle
      check vm.isLoading.val == false

      dispose()

  test "isLoading is false when loading state is lsError":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)

      vm.loadingState.val = lsError
      check vm.isLoading.val == false

      dispose()

# ---------------------------------------------------------------------------
# Auto-load effect
# ---------------------------------------------------------------------------

suite "EventLogVM auto-load effect":

  test "changing rrTicks triggers event log request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      # Initially rrTicks is 0 — no request should fire.
      let initialCount = mock.receivedCommands.len
      check initialCount == 0

      # Simulate debugger moving to a new position.
      var dbg = store.debugger.val
      dbg.rrTicks = 100'u64
      store.debugger.val = dbg
      drain()

      # The effect should have triggered a load-event-log request.
      var found = false
      for cmd in mock.receivedCommands:
        if cmd.command == "ct/event-load":
          check cmd.args["rrTicks"].getBiggestInt == 100
          found = true
          break
      check found

      dispose()

  test "auto-load does not fire for rrTicks == 0":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      drain()

      var dbg = store.debugger.val
      dbg.rrTicks = 0'u64
      store.debugger.val = dbg
      drain()

      for cmd in mock.receivedCommands:
        check cmd.command != "ct/event-load"

      dispose()
