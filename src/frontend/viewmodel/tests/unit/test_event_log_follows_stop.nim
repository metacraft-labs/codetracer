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
