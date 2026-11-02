## test_event_log_kind_selection.nim
##
## HSF-D6: the Event Log's kind filter lives in `EventLogVM.selectedKinds`
## and travels as `ct/event-load`'s `selectedKinds`; the engine's `total` is
## then the selected kinds' count and its `unfilteredTotal` the log's, and the
## pager counts the filtered list.
##
## The backend is a `MockBackendService` — the transport is the only stand-in;
## what is asserted is the request the real ViewModel sends and the store it
## fills.

import std/[json, unittest]

import isonim/core/[signals, computation, owner, async_compat]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewport
import viewmodels/event_log_vm

proc answer(total, unfilteredTotal: int): JsonNode =
  %*{"type": "response", "command": "ct/event-load", "success": true,
     "body": {"events": [], "total": total,
              "unfilteredTotal": unfilteredTotal, "indexAtTick": -1}}

proc eventLoads(mock: MockBackendService): seq[JsonNode] =
  for c in mock.receivedCommands:
    if c.command == "ct/event-load":
      result.add c.args

proc onlyKind(ordinal, count: int): seq[bool] =
  result = newSeq[bool](count)
  result[ordinal] = true

suite "the Event Log's kind selection":

  test "an unfiltered pane sends no selection":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      let sent = mock.eventLoads
      check sent.len == 1
      check sent.len == 1 and not sent[0].hasKey("selectedKinds")
      check not vm.isFiltered
      dispose()

  test "a selection is the request's, and the pane restarts from the top":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 5, firstRow: 40))
      drainPlatformCallbacks()
      vm.setSelectedKinds(onlyKind(3, 24))
      drainPlatformCallbacks()
      let sent = mock.eventLoads
      check sent.len == 2
      check sent.len == 2 and sent[1]["selectedKinds"] == %onlyKind(3, 24)
      check vm.viewport.val.firstRow == 0
      check vm.isFiltered
      dispose()

  test "selecting every kind is no filter":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      vm.setSelectedKinds(onlyKind(3, 24))
      drainPlatformCallbacks()
      var all = newSeq[bool](24)
      for flag in all.mitems: flag = true
      vm.setSelectedKinds(all)
      drainPlatformCallbacks()
      let sent = mock.eventLoads
      check vm.selectedKinds.val.len == 0
      check sent.len == 3 and not sent[2].hasKey("selectedKinds")
      dispose()

  test "the counts are the filtered list's and the log's":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      mock.expect("ct/event-load", answer(30, 30))
      vm.setViewport(Viewport(rows: 5, firstRow: 0))
      drainPlatformCallbacks()
      check store.eventLog.recordsTotal.val == 30
      mock.expect("ct/event-load", answer(10, 30))
      vm.setSelectedKinds(onlyKind(3, 24))
      drainPlatformCallbacks()
      check store.eventLog.recordsFiltered.val == 10
      check store.eventLog.recordsTotal.val == 30
      check vm.totalPages.val == 2
      dispose()
