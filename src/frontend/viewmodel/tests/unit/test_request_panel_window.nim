## test_request_panel_window.nim — Tier 1 for the Request panel's window
## (Viewport-Driven-Loading V2; codetracer-pm issue 2026-10-20 "the request
## panel loads a whole snapshot and filters it on the client").
##
## A COMPLETED recording's requests are read by window, filtered by the
## engine (`ct/load-request-spans {start, limit, filters}`); its first poll
## asks only how many there are. A LIVE session keeps its tail
## (`ct/load-request-spans-since`) and filters it here.
##
## WHY A SCRIPTED BACKEND: the property under test is what the ViewModel
## sends and how it applies an answer of the engine's shape; the engine's
## filtering and windowing are tested where they live (`request_spans.rs`).
##
## Runs on the C and JS backends.

import std/[json, strutils, unittest]

import isonim/core/[signals, computation, async_compat]

import backend/backend_service
import store/[replay_data_store, types]
import viewport
import viewmodels/request_panel_vm

proc drain() = drainPlatformCallbacks()

type
  Engine = ref object
    sent: seq[(string, JsonNode)]

proc record(id: int; httpMethod: string): JsonNode =
  %*{"id": id, "httpMethod": httpMethod, "url": "/r/" & $id,
     "statusCode": 200, "durationMs": 1, "startGeid": id * 10,
     "status": "ok"}

proc answer(command: string; args: JsonNode): JsonNode =
  ## 200 requests, ids 1..200, every third a POST.
  var matching: seq[JsonNode]
  let wantMethod = args{"filters", "method"}.getStr("")
  for id in 1 .. 200:
    let m = if id mod 3 == 0: "POST" else: "GET"
    if wantMethod.len == 0 or wantMethod == m:
      matching.add record(id, m)
  case command
  of "ct/load-request-spans":
    let start = args{"start"}.getInt(0)
    let limit = args{"limit"}.getInt(0)
    var page = newJArray()
    for i in start ..< min(matching.len, start + limit):
      page.add matching[i]
    %*{"requests": page, "total": matching.len, "source": "span-stream"}
  else:
    newJObject()

proc setup(live = false): (Engine, ReplayDataStore, RequestPanelVM) =
  let e = Engine()
  let backend = BackendService(
    sendProc: proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
      e.sent.add((command, args))
      newCompletedFuture[JsonNode](%*{"type": "response", "success": true,
                                      "body": answer(command, args)}),
    onEventProc: proc(handler: EventHandler) = discard)
  let store = createReplayDataStore(backend)
  if live:
    var session = store.session.val
    session.debugSessionMode = liveMcr
    store.session.val = session
  (e, store, createRequestPanelVM(store))

proc sentOf(e: Engine; command: string): seq[JsonNode] =
  for (c, a) in e.sent:
    if c == command: result.add a

suite "the request panel reads the window it shows":

  test "a completed recording's first poll asks only how many there are":
    let (e, store, vm) = setup()
    store.requestRequestSpansSince()
    drain()
    check e.sentOf("ct/load-request-spans-since").len == 0
    let asked = e.sentOf("ct/load-request-spans")
    check asked.len == 1
    check asked[0]["limit"].getInt == 1
    check store.requestSpans.recordedTotal.val == 200
    check vm.requests.val.len == 0

  test "an unmeasured view asks nothing":
    let (e, _, _) = setup()
    drain()
    check e.sentOf("ct/load-request-spans").len == 0

  test "R rows at row F ask for the 20/10 window, filtered by the engine":
    let (e, store, vm) = setup()
    store.requestRequestSpansSince()
    vm.setViewport(Viewport(rows: 20, firstRow: 100))
    drain()
    let windows = e.sentOf("ct/load-request-spans")
    check windows.len == 2
    let w = windows[^1]
    check w["start"].getInt == 90
    check w["limit"].getInt == 20 + LeadRows + TrailRows
    check vm.windowed
    check vm.windowStart.val == 90
    check vm.matchingCount == 200
    check vm.recordedCount == 200
    check vm.filteredRequests.val.len == 50
    check vm.filteredRequests.val[0].id == 91

  test "a filter asks the engine, and the count follows it":
    let (e, store, vm) = setup()
    store.requestRequestSpansSince()
    vm.setViewport(Viewport(rows: 20, firstRow: 0))
    drain()
    vm.setFilterMethod("POST")
    drain()
    let w = e.sentOf("ct/load-request-spans")[^1]
    check w{"filters", "method"}.getStr == "POST"
    check vm.matchingCount == 66
    check vm.recordedCount == 200
    for r in vm.filteredRequests.val:
      check r.httpMethod == "POST"

  test "the selection follows its request as the window moves":
    let (_, _, vm) = setup()
    vm.setViewport(Viewport(rows: 20, firstRow: 100))
    drain()
    vm.selectRequest(15)               # row 105: request 106
    check vm.filteredRequests.val[15].id == 106
    vm.setViewport(Viewport(rows: 20, firstRow: 101))
    drain()
    check vm.windowStart.val == 91
    check vm.selectedIndex.val == 14
    check vm.filteredRequests.val[vm.selectedIndex.val].id == 106

  test "a live session keeps its tail and asks for no window":
    let (e, store, vm) = setup(live = true)
    vm.setViewport(Viewport(rows: 20, firstRow: 0))
    store.requestRequestSpansSince()
    drain()
    check e.sentOf("ct/load-request-spans").len == 0
    check e.sentOf("ct/load-request-spans-since").len == 1
    check not vm.windowed
