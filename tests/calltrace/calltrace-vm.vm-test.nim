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

import std/[json, unittest, asyncdispatch, sets, options]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import ../backend/backend_service
import ../backend/mock_backend
import ../store/types
import ../store/replay_data_store
import ../viewmodels/calltrace_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.
  try:
    poll(0)
  except ValueError:
    # "No handles or timers registered in dispatcher" — nothing to drain.
    discard

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

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

      vm.scroll(50)
      check vm.scrollPosition.val == 50'i64

      vm.scroll(200)
      check vm.scrollPosition.val == 200'i64

      dispose()

  test "scroll clamps negative values to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)

      vm.scroll(-10)
      check vm.scrollPosition.val == 0'i64

      dispose()

  test "scroll triggers data load via effect":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # Initially viewportHeight is 0, so no request should fire.
      let initialCount = mock.receivedCommands.len
      check initialCount == 0

      # Set a debugger position so the auto-load effect's guard passes.
      store.updateDebuggerPosition(100'u64, "main.nim", 1)

      # Set viewport height so the effect will request data.
      vm.setViewportHeight(25)
      drain()

      # The effect should have fired a calltrace section request.
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == "ct/load-calltrace-section"

      # Now scroll — this should trigger another request.
      vm.scroll(100)
      drain()

      check mock.receivedCommands.len == 2
      check mock.receivedCommands[1].command == "ct/load-calltrace-section"
      # The start index should account for the buffer.
      let startIdx = mock.receivedCommands[1].args["startCallLineIndex"].getBiggestInt
      check startIdx == 100 - CALLTRACE_BUFFER

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
        makeCallLine(1, "foo", depth = 1, file = "foo.nim", line = 20, rrTicks = 100),
        makeCallLine(2, "bar", depth = 2, file = "bar.nim", line = 30, rrTicks = 150),
      ]
      store.calltrace.lines.val = testLines
      store.calltrace.startLineIndex.val = 0'i64

      let cmdCountBefore = mock.receivedCommands.len

      vm.doubleClickEntry(1)
      drain()

      # Should have sent a calltrace-jump command.
      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      var found = false
      for cmd in jumpCmds:
        if cmd.command == "ct/calltrace-jump":
          check cmd.args["file"].getStr == "foo.nim"
          check cmd.args["line"].getInt == 20
          check cmd.args["rrTicks"].getBiggestInt == 100
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

      vm.scroll(10)
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

      # No request yet — viewport height is 0.
      check mock.receivedCommands.len == 0

      # Set a debugger position so the auto-load effect's guard passes.
      store.updateDebuggerPosition(100'u64, "main.nim", 1)

      vm.setViewportHeight(30)
      drain()

      # Now the effect should have fired.
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == "ct/load-calltrace-section"
      check mock.receivedCommands[0].args["height"].getInt ==
            30 + CALLTRACE_BUFFER * 2

      dispose()

  test "effect does not fire when viewport height is 0":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # Set a debugger position; the guard should still skip because
      # viewport height is 0.
      store.updateDebuggerPosition(100'u64, "main.nim", 1)

      # Scroll without setting viewport height — effect should skip.
      vm.scroll(50)
      drain()

      check mock.receivedCommands.len == 0

      dispose()

  test "effect does not fire when rrTicks is 0":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # Set viewport height but leave debugger at rrTicks=0.
      vm.setViewportHeight(20)
      drain()

      check mock.receivedCommands.len == 0

      dispose()

  test "debugger position change triggers calltrace section request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()

      # Set up viewport and initial debugger position.
      store.updateDebuggerPosition(100'u64, "main.nim", 1)
      vm.setViewportHeight(20)
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

      vm.setViewportHeight(20)
      drain()
      let countAfterInit = mock.receivedCommands.len

      vm.scroll(50)
      drain()

      check mock.receivedCommands.len == countAfterInit + 1
      let lastCmd = mock.receivedCommands[^1]
      check lastCmd.command == "ct/load-calltrace-section"
      # Buffer start: max(0, 50 - 20) = 30
      check lastCmd.args["startCallLineIndex"].getBiggestInt == 50 - CALLTRACE_BUFFER

      dispose()
