## test_calltrace_section_answer.nim
##
## The store decodes the answer to its own `ct/load-calltrace-section` request
## (`ReplayDataStore.requestCalltraceSection`), through the shared section
## decoder, on every transport — the whole envelope (stdio, worker, mock) and
## the bare body (`DapApi` on the desktop). Before, the desktop read the
## section from its legacy call-trace component's event subscription, so a host
## without that component — the panel host — showed an empty pane.
##
## The backend is a `MockBackendService` answering with the engine's section
## shape (`callLines` of `content.call`, `startCallLineIndex`,
## `totalCallsCount`): the property is what the store holds afterwards.

import std/[json, unittest]

import isonim/core/[signals, async_compat]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]

proc section(names: openArray[string]; start = 0): JsonNode =
  var lines = newJArray()
  for i, n in names:
    lines.add %*{"depth": 0, "content": {"kind": 0, "count": 0,
      "call": {"rawName": n, "key": $(start + i),
               "location": {"path": "/src/main.py", "line": i + 1,
                            "rrTicks": i + 1}}}}
  %*{"callLines": lines, "startCallLineIndex": start,
     "totalCallsCount": 40}

suite "a call-trace section is decoded by the store that asked for it":

  test "the whole response is applied":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    mock.expect("ct/load-calltrace-section",
                %*{"success": true, "body": section(["main", "helper"])})
    store.requestCalltraceSection(startIndex = 0, height = 10, depth = 5)
    drainPlatformCallbacks()
    check store.calltrace.lines.val.len == 2
    check store.calltrace.loadingState.val == lsIdle

  test "a bare body (the desktop's transport) is applied the same":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    mock.expect("ct/load-calltrace-section", section(["a", "b", "c"], 5))
    store.requestCalltraceSection(startIndex = 5, height = 10, depth = 5)
    drainPlatformCallbacks()
    check store.calltrace.lines.val.len == 3
    check store.calltrace.startLineIndex.val == 5

  test "a refusal leaves the held section and says so":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    mock.expect("ct/load-calltrace-section",
                %*{"success": true, "body": section(["main"])})
    store.requestCalltraceSection(startIndex = 0, height = 10, depth = 5)
    drainPlatformCallbacks()
    mock.expect("ct/load-calltrace-section",
                %*{"success": false, "message": "busy"})
    store.requestCalltraceSection(startIndex = 0, height = 20, depth = 5)
    drainPlatformCallbacks()
    check store.calltrace.lines.val.len == 1
    check store.calltrace.loadingState.val == lsError
