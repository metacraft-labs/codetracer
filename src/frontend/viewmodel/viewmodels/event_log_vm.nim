## viewmodels/event_log_vm.nim
##
## EventLogVM — ViewModel for the Event Log panel.
##
## Holds reactive state for:
## - Which row is selected
## - Pagination (current page, page size)
## - Search query for filtering events
## - Sort column and direction
##
## Derives:
## - `totalPages`: computed from the store's event log data and page size
## - `isLoading`: whether a data-fetch is currently in flight
##
## Also creates an auto-load effect that calls the backend to request
## event log data whenever the page, sort, or search parameters change.
##
## Usage:
##   let vm = createEventLogVM(store)
##   echo vm.currentPage.val      # 0
##   vm.nextPage()
##   echo vm.totalPages.val       # derived from store data

import std/[json, options]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

const
  ## Default number of rows per page in the event log panel.
  DEFAULT_PAGE_SIZE* = 50

type
  EventLogVM* = ref object of ViewModel
    ## Reactive state for the Event Log panel.
    ##
    ## Mutable signals:
    ##   selectedRow      — index of the selected row, or none
    ##   currentPage      — zero-based page index
    ##   pageSize         — number of rows per page
    ##   searchQuery      — current search/filter text
    ##   sortColumn       — column index to sort by
    ##   sortAscending    — whether sort is ascending
    ##
    ## Derived memos:
    ##   totalPages       — total pages based on event count and page size
    ##   isLoading        — whether a request is in flight
    ##
    ## The store reference is kept for the auto-load effect and
    ## for navigation actions (double-click jump).
    store*: ReplayDataStore

    # -- Mutable state --
    selectedRow*: Signal[Option[int]]
    currentPage*: Signal[int]
    pageSize*: Signal[int]
    searchQuery*: Signal[string]
    sortColumn*: Signal[int]
    sortAscending*: Signal[bool]

    # -- Internal state for event log data --
    # These are owned by the VM since ReplayDataStore does not yet
    # have a dedicated event-log sub-store.
    eventRows*: Signal[seq[EventLogRow]]
    totalEventCount*: Signal[int]
    loadingState*: Signal[LoadingState]

    # -- Derived state --
    totalPages*: Memo[int]
    isLoading*: Memo[bool]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc selectRow*(vm: EventLogVM; row: Option[int]) =
  ## Set the currently selected row. Pass `none(int)` to clear.
  vm.selectedRow.val = row

proc doubleClickRow*(vm: EventLogVM; row: int) =
  ## Navigate to the source location of the event at `row`.
  ## Looks up the event in the VM's event rows and sends a
  ## navigation command via the backend.
  let rows = vm.eventRows.val
  if row >= 0 and row < rows.len:
    let event = rows[row]
    let args = %*{
      "eventId": event.eventId,
      "line": event.line,
    }
    vm.store.requestHistoricalNavigation("ct/event-jump", args)

proc nextPage*(vm: EventLogVM) =
  ## Advance to the next page, clamped to totalPages - 1.
  let maxPage = vm.totalPages.val - 1
  let next = vm.currentPage.val + 1
  if maxPage >= 0 and next <= maxPage:
    vm.currentPage.val = next

proc prevPage*(vm: EventLogVM) =
  ## Go back one page, clamped to 0.
  let prev = vm.currentPage.val - 1
  if prev >= 0:
    vm.currentPage.val = prev

proc sort*(vm: EventLogVM; column: int) =
  ## Sort by the given column. If already sorting by this column,
  ## toggle the direction. Otherwise, set the column and default
  ## to ascending.
  if vm.sortColumn.val == column:
    vm.sortAscending.val = not vm.sortAscending.val
  else:
    vm.sortColumn.val = column
    vm.sortAscending.val = true

proc setSearchQuery*(vm: EventLogVM; query: string) =
  ## Update the search query. Resets to page 0 since the result
  ## set changes.
  vm.searchQuery.val = query
  vm.currentPage.val = 0

proc setPageSize*(vm: EventLogVM; size: int) =
  ## Update the page size. Resets to page 0 to avoid stale offsets.
  if size > 0:
    vm.pageSize.val = size
    vm.currentPage.val = 0

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createEventLogVM*(store: ReplayDataStore): EventLogVM =
  ## Create an EventLogVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for `totalPages` and `isLoading`
  ## 3. An auto-load effect that requests event log data when
  ##    page, sort, search, or debugger position changes
  withViewModel proc(dispose: proc()): EventLogVM =
    let selectedRow = createSignal(none(int))
    let currentPage = createSignal(0)
    let pageSize = createSignal(DEFAULT_PAGE_SIZE)
    let searchQuery = createSignal("")
    let sortColumn = createSignal(0)
    let sortAscending = createSignal(true)

    # Internal event log state (not yet in ReplayDataStore).
    let eventRows = createSignal(newSeq[EventLogRow]())
    let totalEventCount = createSignal(0)
    let loadingState = createSignal(lsIdle)

    # Derived: total pages from event count and page size.
    let totalPages = createMemo[int] proc(): int =
      let total = totalEventCount.val
      let ps = pageSize.val
      if ps <= 0:
        return 0
      (total + ps - 1) div ps

    # Derived: loading indicator.
    let isLoading = createMemo[bool] proc(): bool =
      loadingState.val == lsLoading

    let vm = EventLogVM(
      store: store,
      selectedRow: selectedRow,
      currentPage: currentPage,
      pageSize: pageSize,
      searchQuery: searchQuery,
      sortColumn: sortColumn,
      sortAscending: sortAscending,
      eventRows: eventRows,
      totalEventCount: totalEventCount,
      loadingState: loadingState,
      totalPages: totalPages,
      isLoading: isLoading,
      disposeProc: dispose,
    )

    # Auto-load effect: whenever page, sort, search, or debugger position
    # changes, request fresh event log data from the backend.
    createEffect proc() =
      let page = currentPage.val
      let ps = pageSize.val
      let query = searchQuery.val
      let col = sortColumn.val
      let asc = sortAscending.val
      let ticks = store.debugger.val.rrTicks
      if ticks > 0'u64:
        let args = %*{
          "page": page,
          "pageSize": ps,
          "searchQuery": query,
          "sortColumn": col,
          "sortAscending": asc,
          "rrTicks": ticks,
        }
        discard store.backend.send("ct/event-load", args)

    vm
