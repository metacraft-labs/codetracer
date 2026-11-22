## test_event_log_follows_stop.nim
##
## HSF-D6 deliverable 3: the terminal's and GPUI's Event Logs page through
## `EventLogVM` (`followStop` + `setViewport`). A ViewModel that follows the
## stop names it in each window request (`atRRTicks`), records the "now" row
## its answer reports (`store.eventLog.currentIndex`), and asks again after a
## move; one that does not (the desktop's) asks nothing on a move.
##
## The backend is a `MockBackendService` — the transport is the only stand-in;
## what is asserted is the request the real ViewModel sends and the store it
## fills.

import std/[json, options, unittest]

import isonim/core/[signals, owner, async_compat]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewport
import viewmodels/event_log_vm

proc answer(indexAtTick: int): JsonNode =
  %*{"type": "response", "command": "ct/event-load", "success": true,
     "body": {"events": [], "recordsTotal": 0, "indexAtTick": indexAtTick}}

proc eventLoads(mock: MockBackendService): seq[JsonNode] =
  for c in mock.receivedCommands:
    if c.command == "ct/event-load":
      result.add c.args

suite "an Event Log that follows the stop":

  test "the request names the stop, and the answer's now-row is kept":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      store.updateDebuggerPosition(120'u64, "/src/main.py", 3)
      mock.expect("ct/event-load", answer(7))
      vm.followStop()
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      let sent = mock.eventLoads
      check sent.len == 1
      check sent.len == 1 and sent[0]["atRRTicks"].getInt == 120
      check store.eventLog.currentIndex.val == 7
      dispose()

  test "a move asks again, naming the new stop":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      store.updateDebuggerPosition(120'u64, "/src/main.py", 3)
      vm.followStop()
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      store.updateDebuggerPosition(300'u64, "/src/main.py", 9)
      drainPlatformCallbacks()
      let sent = mock.eventLoads
      check sent.len == 2
      check sent.len == 2 and sent[1]["atRRTicks"].getInt == 300
      dispose()

  test "a pane that does not follow the stop asks nothing on a move":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      store.updateDebuggerPosition(120'u64, "/src/main.py", 3)
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      store.updateDebuggerPosition(300'u64, "/src/main.py", 9)
      drainPlatformCallbacks()
      let sent = mock.eventLoads
      check sent.len == 1
      check sent.len == 1 and not sent[0].hasKey("atRRTicks")
      dispose()

  test "the pane's order is the request's":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      store.updateDebuggerPosition(120'u64, "/src/main.py", 3)
      vm.followStop()
      vm.sortBy(EventLogOrder(column: elcTick, ascending: false))
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      let sent = mock.eventLoads
      check sent.len >= 1
      check sent.len >= 1 and sent[^1]["sortAscending"].getBool == false
      dispose()

proc windowOf(events: int; indexAtTick: int): JsonNode =
  var rows = newJArray()
  for i in 0 ..< events:
    rows.add %*{"kind": "Write", "content": "event " & $i, "eventIndex": i,
                "directLocationRRTicks": 100 + i}
  %*{"type": "response", "command": "ct/event-load", "success": true,
     "body": {"events": rows, "total": events, "indexAtTick": indexAtTick}}

suite "answers that arrive out of order":

  test "an answer to a superseded request does not replace the newer one's":
    # A pane measured before the entry stop asks twice: before the stop and
    # at it. The engine answers the second first; the first answer, which
    # carries no events, lands last and must not empty the log.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      mock.deferResponses = true
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      vm.followStop()
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      store.updateDebuggerPosition(120'u64, "/src/main.py", 3)
      drainPlatformCallbacks()
      check mock.eventLoads.len == 2
      check mock.pendingDeferredCount == 2
      mock.settleDeferredAt(1, windowOf(6, 2))
      check store.eventLog.rows.val.len == 6
      mock.settleDeferredAt(0, windowOf(0, -1))
      check store.eventLog.rows.val.len == 6
      check store.eventLog.currentIndex.val == 2
      dispose()

  test "answers in order are both applied, the newest last":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      mock.deferResponses = true
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      vm.followStop()
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      store.updateDebuggerPosition(120'u64, "/src/main.py", 3)
      drainPlatformCallbacks()
      mock.settleDeferredAt(0, windowOf(0, -1))
      mock.settleDeferredAt(0, windowOf(6, 2))
      check store.eventLog.rows.val.len == 6
      check store.eventLog.currentIndex.val == 2
      dispose()
