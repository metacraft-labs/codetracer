## request_panel_live_vm_test.nim
##
## RS-M3 — headless ViewModel tests for the HTTP Request panel's live span
## tail.
##
## These are the two ViewModel tests named in
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M3:
##
## - ``vm_receives_live_span_deltas``       — rows append in order, filters
##   keep working, and an overlapping delta updates rows in place instead of
##   duplicating ids.
## - ``vm_open_span_settles_on_completion`` — an open (in-flight) record
##   followed by its completion yields ONE row that transitions from
##   in-flight to its final status.
##
## The third test the milestone names, ``live_tail_from_growing_container``,
## is an integration test owned by the backend and lives in
## ``src/db-backend/tests/request_span_tail_test.rs``
## (``tail_decompresses_each_chunk_once_across_a_growing_recording`` and its
## siblings tail a container that is still being written).  It is not
## duplicated here.
##
## Mocking justification (per the workspace policy on mock objects): these
## tests use ``MockBackendService`` and nothing else.  The component under
## test is the client-side merge algorithm, whose entire input is the delta
## body defined by the wire contract — there is no filesystem or compiler
## boundary in it to exercise for real.  Standing up a real backend here
## would test the backend's decoder a second time (it already has
## ``request_span_tail_test.rs``) while making the merge rules, which are the
## actual subject, harder to drive: an overlapping delta and an open record
## that never completes are states a real recording produces only by timing
## accident.  Every byte the mock emits is copied from the shapes the backend
## serialises in ``src/db-backend/src/request_spans.rs``.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/request_panel_live_vm_test.nim

import std/[json, options, strutils, tables, unittest]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/request_panel_vm
import views/isonim_request_panel_view

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc findByClass(node: MockNode; cls: string): MockNode =
  ## Find the first descendant (or self) whose "class" attribute contains
  ## ``cls`` as a whole word.  Same helper as in ``isonim_views_test.nim``;
  ## duplicated because that file keeps it file-local.
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  return nil

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc spanJson(id: int; httpMethod = "GET"; url = "/"; statusCode = 200;
              durationMs = 10; responseSize = 100; startGeid = 0;
              isOpen = false; status = "ok";
              externalTracePath: JsonNode = newJNull()): JsonNode =
  ## One wire ``RequestRecord``.  Field names and types mirror the
  ## camelCase serde output of the backend's ``RequestRecord``
  ## (``src/db-backend/src/request_spans.rs``) exactly, including the
  ## nullable ``externalTracePath``.
  %*{
    "id": id,
    "httpMethod": httpMethod,
    "url": url,
    "statusCode": statusCode,
    "durationMs": durationMs,
    "responseSize": responseSize,
    "startGeid": startGeid,
    "isOpen": isOpen,
    "status": status,
    "externalTracePath": externalTracePath,
  }

proc deltaEvent(spans: seq[JsonNode]; cursor: int; reset = false;
                source = "span-stream"): JsonNode =
  ## The ``ct/updated-http-requests`` envelope as the RealBackendService
  ## shapes it: the ``CtEventKind`` name in ``kind`` and the DAP body under
  ## ``data`` (see ``viewmodel/backend/real_backend.nim``).
  %*{
    "kind": "CtUpdatedHttpRequests",
    "data": {
      "spans": spans,
      "cursor": cursor,
      "reset": reset,
      "source": source,
    },
  }

proc ids(records: seq[RequestRecord]): seq[int] =
  result = newSeqOfCap[int](records.len)
  for r in records:
    result.add(r.id)

# ---------------------------------------------------------------------------
# vm_receives_live_span_deltas
# ---------------------------------------------------------------------------

suite "RequestPanelVM live span deltas":

  test "vm_receives_live_span_deltas":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      check vm.requests.val.len == 0
      check store.requestSpans.cursor.val == 0'i64

      # --- 1. Snapshot (reset = true) ------------------------------------
      # The first delta of a session is by definition the whole settled set,
      # so the client replaces rather than merges.
      mock.emitEvent(deltaEvent(@[
        spanJson(1, "GET", "/api/users", 200, 12, 2100, startGeid = 10),
        spanJson(2, "POST", "/api/users", 201, 45, 340, startGeid = 20),
      ], cursor = 3, reset = true))

      check vm.requests.val.ids == @[1, 2]
      check vm.requests.val[0].url == "/api/users"
      check vm.requests.val[0].startGeid == 10'i64
      check store.requestSpans.cursor.val == 3'i64
      check store.requestSpans.source.val == "span-stream"

      # --- 2. Append-only delta ------------------------------------------
      mock.emitEvent(deltaEvent(@[
        spanJson(3, "GET", "/api/users/42", 200, 8, 1200, startGeid = 30),
        spanJson(4, "DELETE", "/api/users/42", 500, 23, 89,
                 startGeid = 40, status = "error"),
      ], cursor = 5))

      # Rows append in capture order — oldest first, which is the order the
      # pane spec's Layout section requires ("a live session grows downward
      # like a log").
      check vm.requests.val.ids == @[1, 2, 3, 4]
      check store.requestSpans.cursor.val == 5'i64

      # --- 3. Overlapping delta ------------------------------------------
      # Deltas may re-deliver a range: the backend re-sends a record whose
      # completion superseded an earlier one.  Ids 3 and 4 are already
      # present and must be UPDATED IN PLACE; only id 5 is new.
      mock.emitEvent(deltaEvent(@[
        spanJson(3, "GET", "/api/users/42", 304, 8, 0, startGeid = 30),
        spanJson(4, "DELETE", "/api/users/42", 500, 23, 89,
                 startGeid = 40, status = "error"),
        spanJson(5, "POST", "/api/login", 200, 77, 15, startGeid = 50),
      ], cursor = 6))

      check vm.requests.val.ids == @[1, 2, 3, 4, 5]  # no duplicate ids
      check vm.requests.val.len == 5
      # The superseding record won: id 3's status moved 200 -> 304.
      check vm.requests.val[2].statusCode == 304
      check store.requestSpans.cursor.val == 6'i64

      # --- 4. Filters keep working over the live list --------------------
      vm.setFilterMethod("POST")
      check vm.filteredRequests.val.ids == @[2, 5]

      vm.setFilterMethod("")
      vm.setFilterStatus("5xx")
      check vm.filteredRequests.val.ids == @[4]

      vm.setFilterStatus("")
      vm.setSearchText("/api/users/42")
      check vm.filteredRequests.val.ids == @[3, 4]

      # A delta arriving while a filter is active updates the unfiltered
      # list and the filtered view follows it reactively.
      mock.emitEvent(deltaEvent(@[
        spanJson(6, "GET", "/api/users/42/roles", 200, 5, 30, startGeid = 60),
      ], cursor = 7))
      check vm.requests.val.ids == @[1, 2, 3, 4, 5, 6]
      check vm.filteredRequests.val.ids == @[3, 4, 6]

      vm.setSearchText("")
      check vm.filteredRequests.val.len == 6

      dispose()

  test "the cursor is opaque — echoed back verbatim on the next poll":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      check not vm.isNil

      mock.emitEvent(deltaEvent(@[spanJson(1)], cursor = 42, reset = true))
      check store.requestSpans.cursor.val == 42'i64

      mock.clearReceivedCommands()
      store.requestRequestSpansSince()
      drain()

      let sent = mock.findCommand("ct/load-request-spans-since")
      check sent.isSome
      # Echoed, not incremented, not derived from the row count: the cursor
      # is a chunk count for a span stream and a record count for a legacy
      # sidecar, and the client is not allowed to know which.
      check sent.get.args["cursor"].getInt == 42

      dispose()

  test "a reset delta replaces the list rather than merging into it":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      mock.emitEvent(deltaEvent(@[spanJson(1), spanJson(2), spanJson(3)],
                                cursor = 4, reset = true))
      check vm.requests.val.ids == @[1, 2, 3]

      # An invalidation (the container was rewritten) re-snapshots with a
      # SHORTER set; merging would strand ids 2 and 3 forever.
      mock.emitEvent(deltaEvent(@[spanJson(1)], cursor = 1, reset = true))
      check vm.requests.val.ids == @[1]

      dispose()

  test "a malformed delta body leaves the rows alone":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      mock.emitEvent(deltaEvent(@[spanJson(1), spanJson(2)],
                                cursor = 2, reset = true))
      check vm.requests.val.ids == @[1, 2]

      # A truncated or unexpected payload must never wipe the table the
      # user is reading.
      mock.emitEvent(%*{"kind": "CtUpdatedHttpRequests", "data": "garbage"})
      mock.emitEvent(%*{"kind": "CtUpdatedHttpRequests"})
      mock.emitEvent(%*{"kind": "CtUpdatedHttpRequests", "data": {}})
      check vm.requests.val.ids == @[1, 2]
      check store.requestSpans.cursor.val == 2'i64

      dispose()

# ---------------------------------------------------------------------------
# vm_open_span_settles_on_completion
# ---------------------------------------------------------------------------

suite "RequestPanelVM in-flight rows":

  test "vm_open_span_settles_on_completion":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)
      let body = findByClass(panel, "request-table-body")

      # --- The recorder publishes the request as it STARTS ---------------
      # An open record carries no status and no duration yet.
      mock.emitEvent(deltaEvent(@[
        spanJson(7, "POST", "/api/checkout", statusCode = 0, durationMs = 0,
                 responseSize = 0, startGeid = 700,
                 isOpen = true, status = "unknown"),
      ], cursor = 8, reset = true))

      check vm.requests.val.len == 1
      check body.children.len == 1
      let openRow = vm.requests.val[0]
      check openRow.id == 7
      check openRow.isOpen
      check openRow.statusCode == 0
      check openRow.status == "unknown"

      # Rendered distinctly, with no status or duration — pane spec
      # §"Live Sessions".
      check body.children[0].attributes["class"] == "request-row request-row-open"
      check statusText(openRow) == InFlightPlaceholder
      check durationText(openRow) == InFlightPlaceholder
      check statusCellClass(openRow) == "request-status-unknown"

      # --- The completion arrives in a later delta ----------------------
      mock.emitEvent(deltaEvent(@[
        spanJson(7, "POST", "/api/checkout", statusCode = 201,
                 durationMs = 128, responseSize = 512, startGeid = 700,
                 isOpen = false, status = "ok"),
      ], cursor = 9))

      # ONE row, transitioned in place — not a second row beneath the
      # first.
      check vm.requests.val.len == 1
      check body.children.len == 1
      let settled = vm.requests.val[0]
      check settled.id == 7
      check not settled.isOpen
      check settled.statusCode == 201
      check settled.status == "ok"
      check settled.durationMs == 128

      check body.children[0].attributes["class"] == "request-row"
      check statusText(settled) == "201"
      # No space before the unit — the legacy Karax column's shape
      # (``fc0dcf95b``: ``$ms & "ms"``), which ``formatDuration`` was
      # restored to and which ``isonim_views_test``'s "match the legacy
      # column shapes" case and the pane spec's Columns table both pin.
      check durationText(settled) == "128ms"
      check statusCellClass(settled) == "request-status-success"

      dispose()

  test "an in-flight row that never completes stays a single in-flight row":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      mock.emitEvent(deltaEvent(@[
        spanJson(1, "GET", "/slow", statusCode = 0, durationMs = 0,
                 isOpen = true, status = "unknown", startGeid = 1),
      ], cursor = 2, reset = true))

      # Unrelated traffic completes around it; the open row must neither
      # settle by accident nor be re-appended.
      mock.emitEvent(deltaEvent(@[spanJson(2, "GET", "/fast")], cursor = 3))
      mock.emitEvent(deltaEvent(@[spanJson(3, "GET", "/fast")], cursor = 4))

      check vm.requests.val.ids == @[1, 2, 3]
      check vm.requests.val[0].isOpen
      check not vm.requests.val[1].isOpen

      dispose()

  test "in-flight rows are selectable and keep the selected modifier":
    createRoot proc(dispose: proc()) =
      # The pane spec makes no exception for in-flight rows in its
      # Interactions table, so selection has to compose with the
      # in-flight modifier rather than replace it.
      check rowClass(selected = false, isOpen = false) == "request-row"
      check rowClass(selected = true, isOpen = false) == "request-row selected"
      check rowClass(selected = false, isOpen = true) ==
        "request-row request-row-open"
      check rowClass(selected = true, isOpen = true) ==
        "request-row selected request-row-open"

# ---------------------------------------------------------------------------
# Seek semantics
# ---------------------------------------------------------------------------

suite "RequestPanelVM seek from a live row":

  test "double-click seeks to the span's startGeid":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      mock.emitEvent(deltaEvent(@[
        spanJson(1, "GET", "/a", startGeid = 111),
        spanJson(2, "POST", "/b", startGeid = 222),
      ], cursor = 3, reset = true))

      mock.clearReceivedCommands()
      vm.jumpToHandler(1)
      drain()

      let sent = mock.findCommand("ct/seek-to-geid")
      check sent.isSome
      check sent.get.args["geid"].getInt == 222
      check sent.get.args["url"].getStr == "/b"

      dispose()

  test "a row with an external binding opens that container instead":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      var openedPath = ""
      var openedGeid = 0'i64
      vm.openExternalTrace = proc(tracePath: string; startGeid: int64) =
        openedPath = tracePath
        openedGeid = startGeid

      mock.emitEvent(deltaEvent(@[
        spanJson(1, "GET", "/inline", startGeid = 5),
        spanJson(2, "GET", "/external", startGeid = 9,
                 externalTracePath = %"/traces/worker.ct"),
      ], cursor = 3, reset = true))

      mock.clearReceivedCommands()

      # Inline row: seeks inside the recording already open.
      vm.jumpToHandler(0)
      drain()
      check mock.findCommand("ct/seek-to-geid").isSome
      check openedPath == ""

      # External row: the handler's steps are not in this container, so no
      # seek is dispatched — the container is opened instead.
      mock.clearReceivedCommands()
      vm.jumpToHandler(1)
      drain()
      check not mock.findCommand("ct/seek-to-geid").isSome
      check openedPath == "/traces/worker.ct"
      check openedGeid == 9'i64

      dispose()

# ---------------------------------------------------------------------------
# Store-level plumbing
# ---------------------------------------------------------------------------

suite "ReplayDataStore request-span tail":

  test "the first poll asks for a snapshot with a zero cursor":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()

      store.requestRequestSpansSince()
      drain()

      let sent = mock.findCommand("ct/load-request-spans-since")
      check sent.isSome
      check sent.get.args["cursor"].getInt == 0

      dispose()

  test "the response body is applied when the transport carries one":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      mock.expect("ct/load-request-spans-since", %*{
        "spans": [spanJson(1, "GET", "/from-response")],
        "cursor": 11,
        "reset": true,
        "source": "legacy-jsonl",
      })

      store.requestRequestSpansSince()
      drain()

      check store.requestSpans.requests.val.ids == @[1]
      check store.requestSpans.requests.val[0].url == "/from-response"
      check store.requestSpans.cursor.val == 11'i64
      check store.requestSpans.source.val == "legacy-jsonl"

      dispose()

  test "applying the same delta twice is idempotent":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      check not mock.isNil

      # The panel's own mediator subscription and the store's backend-event
      # handler both land here; the overlap must not double rows.
      let body = %*{
        "spans": [spanJson(1), spanJson(2)],
        "cursor": 4,
        "reset": false,
        "source": "span-stream",
      }
      store.applyRequestSpanDelta(body)
      store.applyRequestSpanDelta(body)

      check store.requestSpans.requests.val.ids == @[1, 2]
      check store.requestSpans.cursor.val == 4'i64

      dispose()

  test "clearRequests drops the tail and forgets the cursor":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      mock.emitEvent(deltaEvent(@[spanJson(1), spanJson(2)],
                                cursor = 9, reset = true))
      check vm.requests.val.len == 2

      vm.clearRequests()

      check vm.requests.val.len == 0
      check store.requestSpans.requests.val.len == 0
      # A stale cursor would suppress the snapshot the next poll must get.
      check store.requestSpans.cursor.val == 0'i64
      check vm.selectedIndex.val == NO_SELECTED_INDEX

      dispose()

  test "records missing optional fields still decode into usable rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()

      store.applyRequestSpanDelta(%*{
        "spans": [{"id": 1, "httpMethod": "GET", "url": "/minimal"}],
        "cursor": 1,
        "reset": true,
        "source": "legacy-jsonl",
      })

      let rows = store.requestSpans.requests.val
      check rows.len == 1
      check rows[0].id == 1
      check rows[0].url == "/minimal"
      check rows[0].responseSize == 0
      check not rows[0].isOpen
      # An absent status byte is "unknown", not an optimistic "ok".
      check rows[0].status == "unknown"
      check rows[0].externalTracePath == ""

      dispose()
