## test_store.nim
##
## Unit tests for ReplayDataStore, RequestTracker, and store types.
##
## Verifies:
## - Store initialises with correct default state (idle, disconnected).
## - requestLocals sends the right command to the backend.
## - requestCalltraceSection sends the right command.
## - requestStep sends a step command and updates debugger status.
## - RequestTracker deduplicates identical pending requests.
## - RequestTracker allows re-request after markComplete.
## - Signal changes propagate through effects.
## - Loading state transitions correctly on success and failure.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_store.nim

import std/[json, unittest, asyncdispatch]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import ../backend/backend_service
import ../backend/mock_backend
import ../store/types
import ../store/request_tracker
import ../store/replay_data_store

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.  Silently ignores the case where
  ## there is nothing pending in the dispatcher (which happens when
  ## mock futures complete synchronously via callSoon).
  try:
    poll(0)
  except ValueError:
    # "No handles or timers registered in dispatcher" — nothing to drain.
    discard

# ---------------------------------------------------------------------------
# RequestTracker tests
# ---------------------------------------------------------------------------

suite "RequestTracker":

  test "new tracker has no pending requests":
    let t = newRequestTracker()
    check not t.hasPending("anything")

  test "isDuplicate returns false when nothing is pending":
    let t = newRequestTracker()
    check not t.isDuplicate("load-locals", "100")

  test "isDuplicate returns true for matching key and args":
    let t = newRequestTracker()
    t.markPending("load-locals", "100")
    check t.isDuplicate("load-locals", "100")

  test "isDuplicate returns false for same key but different args":
    let t = newRequestTracker()
    t.markPending("load-locals", "100")
    check not t.isDuplicate("load-locals", "200")

  test "markComplete allows re-request":
    let t = newRequestTracker()
    t.markPending("load-locals", "100")
    check t.isDuplicate("load-locals", "100")
    t.markComplete("load-locals")
    check not t.isDuplicate("load-locals", "100")
    check not t.hasPending("load-locals")

  test "clear removes all pending entries":
    let t = newRequestTracker()
    t.markPending("a", "1")
    t.markPending("b", "2")
    t.clear()
    check not t.hasPending("a")
    check not t.hasPending("b")

  test "multiple args are distinguished":
    let t = newRequestTracker()
    t.markPending("calltrace", "0", "50", "10")
    check t.isDuplicate("calltrace", "0", "50", "10")
    check not t.isDuplicate("calltrace", "0", "50", "20")

# ---------------------------------------------------------------------------
# ReplayDataStore — initial state
# ---------------------------------------------------------------------------

suite "ReplayDataStore initial state":

  test "session starts disconnected":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      check store.session.val.connectionStatus == csDisconnected
      dispose()

  test "debugger starts idle":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      check store.debugger.val.status == dsIdle
      check store.debugger.val.rrTicks == 0'u64
      dispose()

  test "timeline starts at zero":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      check store.timeline.val.minRRTicks == 0'u64
      check store.timeline.val.maxRRTicks == 0'u64
      check store.timeline.val.currentRRTicks == 0'u64
      dispose()

  test "calltrace loading state starts idle":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      check store.calltrace.loadingState.val == lsIdle
      check store.calltrace.lines.val.len == 0
      dispose()

  test "locals loading state starts idle":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      check store.locals.loadingState.val == lsIdle
      check store.locals.locals.val.len == 0
      dispose()

# ---------------------------------------------------------------------------
# ReplayDataStore — request procs
# ---------------------------------------------------------------------------

suite "ReplayDataStore requests":

  test "requestLocals sends ct/load-locals with rrTicks":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      store.requestLocals(42'u64)
      drain()

      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == "ct/load-locals"
      check mock.receivedCommands[0].args["rrTicks"].getBiggestInt == 42
      dispose()

  test "requestLocals deduplicates identical requests":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      store.requestLocals(42'u64)
      # Second call with same rrTicks should be skipped.
      store.requestLocals(42'u64)

      check mock.receivedCommands.len == 1
      dispose()

  test "requestLocals allows different rrTicks after completion":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      store.requestLocals(42'u64)
      drain()
      # After the first completes, a new rrTicks should be allowed.
      store.requestLocals(99'u64)

      check mock.receivedCommands.len == 2
      check mock.receivedCommands[1].args["rrTicks"].getBiggestInt == 99
      dispose()

  test "requestCalltraceSection sends ct/load-calltrace":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      store.requestCalltraceSection(100'i64, 50, 10)
      drain()

      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == "ct/load-calltrace"
      check mock.receivedCommands[0].args["startIndex"].getBiggestInt == 100
      check mock.receivedCommands[0].args["height"].getInt == 50
      check mock.receivedCommands[0].args["depth"].getInt == 10
      dispose()

  test "requestStep sends ct/step and sets status to stepping":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      store.requestStep(sdForward)

      # Status should be stepping immediately (before async completes).
      check store.debugger.val.status == dsStepping
      check mock.receivedCommands.len == 1
      check mock.receivedCommands[0].command == "ct/step"
      dispose()

  test "requestStep deduplicates identical in-flight steps":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      store.requestStep(sdForward)
      store.requestStep(sdForward)

      check mock.receivedCommands.len == 1
      dispose()

# ---------------------------------------------------------------------------
# Loading state transitions
# ---------------------------------------------------------------------------

suite "Loading state transitions":

  test "requestLocals transitions loading state to lsLoading then lsIdle":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      store.requestLocals(10'u64)
      # Right after the call, loading state should be lsLoading.
      # But since futures complete synchronously in tests with
      # autoRespond, the callback fires immediately in poll(0).
      check store.locals.loadingState.val == lsLoading

      drain()
      check store.locals.loadingState.val == lsIdle
      check store.locals.loadedForRRTicks.val == 10'u64
      dispose()

  test "requestLocals sets lsError on failure":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(strict = true)
      # Expect the command so it does not raise synchronously,
      # but we will make the future fail.
      let svc = mock.toBackendService()

      # Override sendProc to return a failed future.
      let origSend = svc.sendProc
      svc.sendProc = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
        mock.receivedCommands.add((command, args))
        var fut = newFuture[JsonNode]("fail-test")
        fut.fail(newException(CatchableError, "backend down"))
        return fut

      let store = createReplayDataStore(svc)
      store.requestLocals(10'u64)
      drain()

      check store.locals.loadingState.val == lsError
      dispose()

# ---------------------------------------------------------------------------
# Signal propagation
# ---------------------------------------------------------------------------

suite "Signal propagation":

  test "effect runs when signal changes":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      var observed = 0
      createEffect proc() =
        observed = store.debugger.val.status.ord

      # Initial execution: dsIdle == 0
      check observed == dsIdle.ord

      # Trigger a change.
      var dbg = store.debugger.val
      dbg.status = dsStepping
      store.debugger.val = dbg

      check observed == dsStepping.ord
      dispose()

  test "effect tracks calltrace loading state":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      var states: seq[LoadingState] = @[]
      createEffect proc() =
        states.add(store.calltrace.loadingState.val)

      # Initial: lsIdle
      check states == @[lsIdle]

      store.requestCalltraceSection(0, 50, 5)

      # After request: lsLoading was set
      check lsLoading in states

      drain()

      # After completion: back to lsIdle
      check states[^1] == lsIdle
      dispose()
