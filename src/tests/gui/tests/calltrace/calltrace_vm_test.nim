## test_calltrace_vm.nim
##
## Unit tests for CalltraceVM — the ViewModel for the Calltrace panel.
##
## Verifies:
## - Initial state (scrollPosition=0, no selection, empty expandedNodes, etc.)
## - scroll updates scrollPosition signal
## - scroll triggers data load via effect (verify mock backend receives command)
## - selectEntry updates selection
## - toggleExpand adds/removes from set
## - doubleClickEntry sends navigation command
## - visibleLines memo computes correct slice from store data
## - hasMoreAbove/hasMoreBelow derive correctly from scroll position and total count
## - searchQuery updates and highlightedMatches recomputes
## - isLoading reflects store loading state
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_calltrace_vm.nim

import std/[json, unittest, sets, options]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/calltrace_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeCallLine(index: int64; name: string; depth: int = 0;
                  rrTicks: uint64 = 0; file: string = "";
                  line: int = 0; callstackDepth: int = 0): CallLine =
  ## Convenience constructor for CallLine test data.
  CallLine(
    index: index,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(
      file: file,
      line: line,
      column: 0,
      callstackDepth: callstackDepth,
    ),
  )

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "CalltraceVM initial state":

  test "scrollPosition defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.scrollPosition.val == 0'i64
      dispose()

  test "viewportHeight defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.viewportHeight.val == 0
      dispose()

  test "selectedEntry defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.selectedEntry.val.isNone
      dispose()

  test "expandedNodes starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.expandedNodes.val.len == 0
      dispose()

  test "searchQuery starts as empty string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.searchQuery.val == ""
      dispose()

  test "isLoading starts false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      # `createCalltraceVM` installs an auto-load effect that fires
      # immediately and sets `loadingState = lsLoading`. The mock
      # backend resolves the request synchronously, but the response
      # callback is queued onto the async dispatcher / pendingCallbacks
      # queue and only fires after `drain()`. Without drain(), the
      # observed `isLoading` value here is *true* on the JS backend.
      drain()
      check vm.isLoading.val == false
      dispose()

  test "visibleLines starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.visibleLines.val.len == 0
      dispose()

  test "hasMoreAbove starts false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.hasMoreAbove.val == false
      dispose()

  test "hasMoreBelow starts false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.hasMoreBelow.val == false
      dispose()

  test "highlightedMatches starts empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      check vm.highlightedMatches.val.len == 0
      dispose()

# ---------------------------------------------------------------------------
# Scroll
# ---------------------------------------------------------------------------

suite "CalltraceVM scroll":

  test "scroll updates scrollPosition signal":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.setViewport(vm.viewport.val.scrolledTo(50))
      check vm.scrollPosition.val == 50'i64

      vm.setViewport(vm.viewport.val.scrolledTo(200))
      check vm.scrollPosition.val == 200'i64

      dispose()

  test "scroll clamps negative values to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.setViewport(vm.viewport.val.scrolledTo(-10))
      check vm.scrollPosition.val == 0'i64

      dispose()

  test "scroll triggers data load via effect":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # The auto-load effect fires on creation (no rrTicks guard).
      # Clear initial commands so we can track new ones.
      mock.clearReceivedCommands()

      # Set a debugger position so the auto-load effect re-fires.
      store.updateDebuggerPosition(100'u64, "main.nim", 1)

      # Set viewport height so the effect will request data.
      vm.setViewport(vm.viewport.val.withRows(25))
      drain()

      # The effect should have fired calltrace section requests.
      let countAfterSetup = mock.receivedCommands.len
      check countAfterSetup >= 1
      check mock.receivedCommands[^1].command == "ct/load-calltrace-section"

      # Now scroll — this should trigger another request.
      vm.setViewport(vm.viewport.val.scrolledTo(100))
      drain()

      check mock.receivedCommands.len == countAfterSetup + 1
      check mock.receivedCommands[^1].command == "ct/load-calltrace-section"
      # The window starts `TrailRows` above the first visible row (the
      # Electron GUI's `START_BUFFER`).
      let startIdx = mock.receivedCommands[^1].args["startCallLineIndex"].getBiggestInt
      check startIdx == 100 - TrailRows

      dispose()

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

suite "CalltraceVM selection":

  test "selectEntry updates selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.selectEntry(some(42'i64))
      check vm.selectedEntry.val == some(42'i64)

      dispose()

  test "selectEntry with none clears selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.selectEntry(some(10'i64))
      check vm.selectedEntry.val.isSome

      vm.selectEntry(none(int64))
      check vm.selectedEntry.val.isNone

      dispose()

  # The current-call mark is a claim about which CALL the debugger is in,
  # so it follows the call's key, never the row position the call happened
  # to have (#811; Click-Navigation.md §3.3: "A row that is no longer
  # present retires the mark rather than leaving the previous one
  # standing"). The sections below are the ones the reporter's program
  # produces: `<toplevel>` -> `main` -> `assert_in_range`, then
  # `<end of program>`, before and after `main` is collapsed.

  proc keyedLine(index: int64; name, key: string; depth: int;
                 hasChildren = false; isExpanded = false): CallLine =
    result = makeCallLine(index, name, depth = depth)
    result.callKey = key
    result.hasChildren = hasChildren
    result.isExpanded = isExpanded

  proc expandedSection(): seq[CallLine] =
    @[
      keyedLine(0, "<toplevel>", "0", 0, hasChildren = true, isExpanded = true),
      keyedLine(1, "main", "1", 1, hasChildren = true, isExpanded = true),
      keyedLine(2, "assert_in_range", "2", 2),
      keyedLine(3, "<end of program>", "3", 1),
    ]

  proc collapsedSection(): seq[CallLine] =
    # `main` collapsed: its child is hidden and every row after it moves
    # up, so `<end of program>` takes `assert_in_range`'s old index 2.
    @[
      keyedLine(0, "<toplevel>", "0", 0, hasChildren = true, isExpanded = true),
      keyedLine(1, "main", "1", 1, hasChildren = true, isExpanded = false),
      keyedLine(2, "<end of program>", "3", 1),
    ]

  proc markedRows(vm: CalltraceVM): seq[string] =
    ## The names of the visible rows the View draws the mark on: it marks
    ## the row whose `index` equals `selectedEntry` (`rowClassWeb`,
    ## `selectedToggleIconClass`, `selectedChildBoxClass`).
    let sel = vm.selectedEntry.val
    for line in vm.visibleLines.val:
      if sel.isSome and sel.get == line.index:
        result.add line.name

  test "collapsing an ancestor of the selected call retires the mark (#811)":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 10))
      drain()
      store.updateCalltraceSection(expandedSection(), 0, 4)

      # The `assert_in_range` row is selected (a click, `rowHandlers
      # .onSelect`, or the debugger stopping in it) and carries the mark.
      vm.selectEntry(some(2'i64))
      check vm.markedRows() == @["assert_in_range"]

      # Collapse `main` through the toggle the View wires to its icon. The
      # VM asks the backend to collapse and re-asks for the section ...
      mock.clearReceivedCommands()
      vm.toggleExpandCallChildren(1)
      check mock.receivedCommands.len >= 2
      check mock.receivedCommands[0].command == "ct/collapse-calls"
      check mock.receivedCommands[^1].command == "ct/load-calltrace-section"
      # ... and the reloaded section no longer holds the call.
      store.updateCalltraceSection(collapsedSection(), 0, 3)

      # No visible row may carry the mark, and `<end of program>` (the row
      # that took index 2) least of all.
      check vm.markedRows().len == 0
      check vm.selectedEntry.val.isNone

      dispose()

  test "re-expanding restores the mark on the call at its new index (#811)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 10))
      drain()
      store.updateCalltraceSection(expandedSection(), 0, 4)
      vm.selectEntry(some(2'i64))

      vm.toggleExpandCallChildren(1)
      store.updateCalltraceSection(collapsedSection(), 0, 3)
      check vm.selectedEntry.val.isNone

      vm.toggleExpandCallChildren(1)

      # Expanded again, with a sibling call loaded before it this time, so
      # the call is back but one row further down than it was.
      store.updateCalltraceSection(@[
        keyedLine(0, "<toplevel>", "0", 0, hasChildren = true, isExpanded = true),
        keyedLine(1, "main", "1", 1, hasChildren = true, isExpanded = true),
        keyedLine(2, "check_input", "4", 2),
        keyedLine(3, "assert_in_range", "2", 2),
        keyedLine(4, "<end of program>", "3", 1),
      ], 0, 5)
      check vm.selectedEntry.val == some(3'i64)
      check vm.markedRows() == @["assert_in_range"]

      dispose()

  test "selectCall marks the call once a section holding it is loaded":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      store.updateCalltraceSection(collapsedSection(), 0, 3)

      # A move into a call the loaded section does not show: nothing is
      # marked, not the row that happens to sit where the call once was.
      vm.selectCall("2")
      check vm.selectedEntry.val.isNone
      check vm.selectedCallKey.val == "2"

      store.updateCalltraceSection(expandedSection(), 0, 4)
      check vm.selectedEntry.val == some(2'i64)
      check vm.markedRows() == @["assert_in_range"]

      dispose()

  test "clearing the selection forgets the call":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      store.updateCalltraceSection(expandedSection(), 0, 4)
      vm.selectCall("2")
      check vm.selectedEntry.val == some(2'i64)

      vm.selectEntry(none(int64))
      check vm.selectedCallKey.val == ""
      # A later section that holds the call does not bring the mark back.
      store.updateCalltraceSection(expandedSection(), 0, 4)
      check vm.selectedEntry.val.isNone

      dispose()

  test "a collapse keeps a row selected by index on its call, not its index":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 10))
      drain()
      store.updateCalltraceSection(expandedSection(), 0, 4)

      # `<end of program>` is selected by index; collapsing `main` moves
      # it up one row, and the mark moves with it (Scrollbar-Scrubbers.md
      # §3 item 6: expansion changes keep the row's identity, not its
      # index).
      vm.selectEntry(some(3'i64))
      vm.toggleExpandCallChildren(1)
      check vm.selectedCallKey.val == "3"
      store.updateCalltraceSection(collapsedSection(), 0, 3)
      check vm.selectedEntry.val == some(2'i64)
      check vm.markedRows() == @["<end of program>"]

      dispose()

  test "selectEntry alone writes the index and follows no call":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      store.updateCalltraceSection(expandedSection(), 0, 4)
      vm.selectCall("2")

      # The terminal keeps its call-stack FRAME cursor in this signal
      # (`call_stack_binding.publishInspectionCursor`), so an index write
      # drops the held call and a section reload leaves the index alone.
      vm.selectEntry(some(3'i64))
      check vm.selectedCallKey.val == ""
      store.updateCalltraceSection(collapsedSection(), 0, 3)
      check vm.selectedEntry.val == some(3'i64)

      dispose()

# ---------------------------------------------------------------------------
# Expand / collapse
# ---------------------------------------------------------------------------

suite "CalltraceVM expand/collapse":

  test "toggleExpand adds a node":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.toggleExpand(5'i64)
      check 5'i64 in vm.expandedNodes.val

      dispose()

  test "toggleExpand removes an already expanded node":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.toggleExpand(5'i64)
      check 5'i64 in vm.expandedNodes.val

      vm.toggleExpand(5'i64)
      check 5'i64 notin vm.expandedNodes.val

      dispose()

  test "toggleExpand handles multiple nodes independently":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.toggleExpand(1'i64)
      vm.toggleExpand(2'i64)
      vm.toggleExpand(3'i64)

      check 1'i64 in vm.expandedNodes.val
      check 2'i64 in vm.expandedNodes.val
      check 3'i64 in vm.expandedNodes.val

      # Collapse only node 2.
      vm.toggleExpand(2'i64)
      check 1'i64 in vm.expandedNodes.val
      check 2'i64 notin vm.expandedNodes.val
      check 3'i64 in vm.expandedNodes.val

      dispose()

# ---------------------------------------------------------------------------
# Double-click navigation
# ---------------------------------------------------------------------------

suite "CalltraceVM doubleClickEntry":

  test "doubleClickEntry sends navigation command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # Populate calltrace data in the store.
      let testLines = @[
        makeCallLine(0, "main", file = "main.nim", line = 10, rrTicks = 50),
        makeCallLine(1, "foo", depth = 1, file = "foo.nim", line = 20,
                     rrTicks = 100, callstackDepth = 3),
        makeCallLine(2, "bar", depth = 2, file = "bar.nim", line = 30, rrTicks = 150),
      ]
      store.calltrace.lines.val = testLines
      store.calltrace.startLineIndex.val = 0'i64

      let cmdCountBefore = mock.receivedCommands.len

      vm.doubleClickEntry(1)
      drain()

      # Should have sent a calltrace-jump command. The backend expects
      # a Location struct with camelCase field names — `path` (not
      # `file`), plus `highLevelPath` / `highLevelLine` mirrors of the
      # primary path/line — so the assertions match those keys.
      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      var found = false
      for cmd in jumpCmds:
        if cmd.command == "ct/calltrace-jump":
          check cmd.args["path"].getStr == "foo.nim"
          check cmd.args["line"].getInt == 20
          check cmd.args["rrTicks"].getBiggestInt == 100
          check cmd.args["callstackDepth"].getInt == 3
          found = true
          break
      check found

      dispose()

  test "doubleClickEntry is no-op for out-of-range index":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      store.calltrace.lines.val = @[
        makeCallLine(0, "main"),
      ]
      store.calltrace.startLineIndex.val = 0'i64

      let cmdCountBefore = mock.receivedCommands.len

      # Index 99 is out of range — should be silently ignored.
      vm.doubleClickEntry(99)
      drain()

      # No calltrace-jump command should have been sent.
      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      for cmd in jumpCmds:
        check cmd.command != "ct/calltrace-jump"

      dispose()

# ---------------------------------------------------------------------------
# visibleLines memo
# ---------------------------------------------------------------------------

suite "CalltraceVM visibleLines":

  test "visibleLines computes correct slice from store data":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      # Set up store with 10 lines starting at index 5.
      var lines: seq[CallLine] = @[]
      for i in 0 ..< 10:
        lines.add(makeCallLine((5 + i).int64, "func_" & $i))
      store.calltrace.lines.val = lines
      store.calltrace.startLineIndex.val = 5'i64
      store.calltrace.totalCallsCount.val = 100'u64

      # Set viewport: scroll to index 7, show 4 rows.
      vm.scrollPosition.val = 7'i64
      vm.viewportHeight.val = 4

      let visible = vm.visibleLines.val
      check visible.len == 4
      check visible[0].index == 7
      check visible[1].index == 8
      check visible[2].index == 9
      check visible[3].index == 10

      dispose()

  test "visibleLines returns empty when no data":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.scrollPosition.val = 0'i64
      vm.viewportHeight.val = 10
      check vm.visibleLines.val.len == 0

      dispose()

  test "visibleLines clamps to available data":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      # Store has lines [0..2], viewport wants [0..9].
      store.calltrace.lines.val = @[
        makeCallLine(0, "a"),
        makeCallLine(1, "b"),
        makeCallLine(2, "c"),
      ]
      store.calltrace.startLineIndex.val = 0'i64

      vm.scrollPosition.val = 0'i64
      vm.viewportHeight.val = 10

      let visible = vm.visibleLines.val
      check visible.len == 3
      check visible[0].name == "a"
      check visible[2].name == "c"

      dispose()

# ---------------------------------------------------------------------------
# hasMoreAbove / hasMoreBelow
# ---------------------------------------------------------------------------

suite "CalltraceVM hasMoreAbove/hasMoreBelow":

  test "hasMoreAbove is false at position 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.scrollPosition.val = 0'i64
      check vm.hasMoreAbove.val == false

      dispose()

  test "hasMoreAbove is true when scrolled down":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.setViewport(vm.viewport.val.scrolledTo(10))
      check vm.hasMoreAbove.val == true

      dispose()

  test "hasMoreBelow is false when total is 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      store.calltrace.totalCallsCount.val = 0'u64
      vm.viewportHeight.val = 10
      check vm.hasMoreBelow.val == false

      dispose()

  test "hasMoreBelow is true when more entries exist below viewport":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      store.calltrace.totalCallsCount.val = 100'u64
      vm.scrollPosition.val = 0'i64
      vm.viewportHeight.val = 25

      check vm.hasMoreBelow.val == true

      dispose()

  test "hasMoreBelow is false when viewport covers all remaining entries":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      store.calltrace.totalCallsCount.val = 50'u64
      vm.scrollPosition.val = 25'i64
      vm.viewportHeight.val = 25

      check vm.hasMoreBelow.val == false

      dispose()

# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

suite "CalltraceVM search":

  test "setSearchQuery updates searchQuery signal":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.setSearchQuery("main")
      check vm.searchQuery.val == "main"

      dispose()

  test "highlightedMatches returns matching indices":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      store.calltrace.lines.val = @[
        makeCallLine(0, "main"),
        makeCallLine(1, "processData"),
        makeCallLine(2, "mainLoop"),
        makeCallLine(3, "cleanup"),
      ]
      store.calltrace.startLineIndex.val = 0'i64

      vm.setSearchQuery("main")
      let matches = vm.highlightedMatches.val
      check matches.len == 2
      check matches[0] == 0'i64
      check matches[1] == 2'i64

      dispose()

  test "highlightedMatches is case-insensitive":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      store.calltrace.lines.val = @[
        makeCallLine(0, "Main"),
        makeCallLine(1, "MAIN_LOOP"),
        makeCallLine(2, "other"),
      ]
      store.calltrace.startLineIndex.val = 0'i64

      vm.setSearchQuery("main")
      let matches = vm.highlightedMatches.val
      check matches.len == 2
      check matches[0] == 0'i64
      check matches[1] == 1'i64

      dispose()

  test "highlightedMatches is empty for empty query":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      store.calltrace.lines.val = @[
        makeCallLine(0, "main"),
      ]
      store.calltrace.startLineIndex.val = 0'i64

      vm.setSearchQuery("")
      check vm.highlightedMatches.val.len == 0

      dispose()

  test "highlightedMatches accounts for startLineIndex offset":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      store.calltrace.lines.val = @[
        makeCallLine(50, "alpha"),
        makeCallLine(51, "beta"),
        makeCallLine(52, "alpha_two"),
      ]
      store.calltrace.startLineIndex.val = 50'i64

      vm.setSearchQuery("alpha")
      let matches = vm.highlightedMatches.val
      check matches.len == 2
      check matches[0] == 50'i64
      check matches[1] == 52'i64

      dispose()

# ---------------------------------------------------------------------------
# isLoading memo
# ---------------------------------------------------------------------------

suite "CalltraceVM isLoading":

  test "isLoading reflects store calltrace loading state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()  # flush the auto-load effect's loading→idle transition

      check vm.isLoading.val == false

      store.calltrace.loadingState.val = lsLoading
      check vm.isLoading.val == true

      store.calltrace.loadingState.val = lsIdle
      check vm.isLoading.val == false

      dispose()

  test "isLoading is false when loading state is lsError":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      store.calltrace.loadingState.val = lsError
      check vm.isLoading.val == false

      dispose()

# ---------------------------------------------------------------------------
# Auto-load effect
# ---------------------------------------------------------------------------

suite "CalltraceVM auto-load effect":

  test "setting viewportHeight triggers calltrace section request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # The auto-load effect fires on creation (no rrTicks guard).
      # Clear initial commands so we can track the viewport-triggered one.
      mock.clearReceivedCommands()

      # Set a debugger position so the auto-load effect re-fires.
      store.updateDebuggerPosition(100'u64, "main.nim", 1)

      vm.setViewport(vm.viewport.val.withRows(30))
      drain()

      # The effect should have fired with the explicit viewport height.
      let cmd = mock.receivedCommands[^1]
      check cmd.command == "ct/load-calltrace-section"
      # The GUI's window: the visible rows, `LeadRows` after them, and the
      # rows above the first visible one that `TrailRows` reached (none at
      # the top of the trace).
      check cmd.args["height"].getInt == 30 + LeadRows

      dispose()

  test "an unmeasured pane asks for nothing":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()
      # No view has reported a size: the rows of a pane nobody sized are not
      # the ViewModel's to guess (Viewport-Driven-Loading V2).
      store.updateDebuggerPosition(100'u64, "main.nim", 1)
      drain()
      check mock.receivedCommands.len == 0
      check vm.viewport.val.rows == 0

      dispose()

  test "effect fires even when rrTicks is 0 (DB-based traces)":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # The auto-load effect does not guard on rrTicks > 0 because DB-based
      # traces always have rrTicks=0: a measured pane at tick 0 asks.
      vm.setViewport(Viewport(rows: 10))
      drain()
      check mock.receivedCommands.len >= 1
      check mock.receivedCommands[0].command == "ct/load-calltrace-section"

      dispose()

  test "debugger position change triggers calltrace section request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # Set up viewport and initial debugger position.
      store.updateDebuggerPosition(100'u64, "main.nim", 1)
      vm.setViewport(vm.viewport.val.withRows(20))
      drain()
      let countAfterInit = mock.receivedCommands.len

      # Move the debugger — auto-load effect should fire again.
      store.updateDebuggerPosition(200'u64, "main.nim", 5)
      drain()

      check mock.receivedCommands.len == countAfterInit + 1
      let lastCmd = mock.receivedCommands[^1]
      check lastCmd.command == "ct/load-calltrace-section"

      dispose()

  test "scroll triggers a new calltrace section request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # Set a debugger position so the auto-load effect's guard passes.
      store.updateDebuggerPosition(100'u64, "main.nim", 1)

      vm.setViewport(vm.viewport.val.withRows(20))
      drain()
      let countAfterInit = mock.receivedCommands.len

      vm.setViewport(vm.viewport.val.scrolledTo(50))
      drain()

      check mock.receivedCommands.len == countAfterInit + 1
      let lastCmd = mock.receivedCommands[^1]
      check lastCmd.command == "ct/load-calltrace-section"
      # Window start: 50 - TrailRows = 40; height: rows + LeadRows + TrailRows.
      check lastCmd.args["startCallLineIndex"].getBiggestInt == 50 - TrailRows
      check lastCmd.args["height"].getInt == 20 + LeadRows + TrailRows

      dispose()
