## python_request_panel_vm_test.nim
##
## RS-M5 — ``vm_python_request_panel_rows``.
##
## The codetracer-side half of the Python milestone: the Request Panel's
## ViewModel, driven from a container **recorded by the Python recorder** while a
## real Flask app served real HTTP requests.  Per
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M5 it asserts the rendered row count, the columns, the status colouring,
## and that a row's double-click emits a seek into that request's handler.
##
## ## What is real here
##
## The fixture in ``fixtures/python_flask/`` is a genuine recording, not a
## hand-built container: ``codetracer-python-recorder``'s WSGI middleware wrote
## its ``spans.dat`` records itself while ``wsgiref`` served eight requests to
## the demo app in that repo's ``test-programs/web/flask/app.py``.  Regenerate it
## with
##
##   direnv exec ../codetracer-python-recorder just \
##     record-request-panel-fixture <this dir>/fixtures/python_flask flask
##
## (also what ``just demo-request-panel python`` records), and see
## ``fixtures/README.md`` — which lives one level up because that recipe replaces
## the whole ``python_flask/`` directory.
##
## Everything downstream is production code: the container's ``meta.dat`` bit 13
## is read by the shipped reader, the spans are decoded by the canonical Nim span
## reader (``initSpanStreamReader`` / ``settledSpans`` — the same API
## ``src/ct/cli/print_trace.nim`` uses), the step bindings are resolved through
## the production trace reader (``openNewTrace``), and the rows come out of the
## real ``RequestPanelVM`` and the real IsoNim view.
##
## The ground truth for every row is the demo app's **request schedule**
## (``DEMO_REQUESTS`` in the recorder repo's
## ``test-programs/web/session_driver.py``) plus its routes, written out below as
## ``ExpectedRow``.  It is deliberately NOT derived from the container, so a
## recorder bug cannot make the expectations agree with themselves.  Only the
## timing-dependent values (durations, byte counts, step indices) are asserted as
## properties rather than constants.
##
## Mocking justification (per the workspace policy on mock objects): the only
## mock is ``MockBackendService``, used purely as the transport that carries an
## already-decoded delta into the store — exactly as in
## ``demo_recipe_vm_test.nim``.  There is no fake container, no fake reader and
## no fake span data: the bytes are a real recording and are decoded by the real
## readers.  A live backend process was deliberately not used because the tests
## that need one are excluded from ``just test-vm-native`` for runtime, and a
## test that does not run guards nothing.
##
## Native-only: it reads real container bytes through a zstd FFI, which does not
## exist on the ``nim js`` backend, so ``just test-vm-js`` excludes this file and
## ``src/ct_test/release_gate.nim`` registers it in ``CoreViewModelGateTests``.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/python_request_panel_vm_test.nim

import std/[json, options, os, strutils, tables, unittest]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/request_panel_vm
import views/isonim_request_panel_view

import results
import codetracer_ctfs/container
import codetracer_trace_writer/meta_dat
import codetracer_trace_writer/span_stream
import codetracer_trace_writer/new_trace_reader

# ---------------------------------------------------------------------------
# The fixture and what it is expected to contain
# ---------------------------------------------------------------------------

const
  FixtureContainer = currentSourcePath.parentDir /
    "fixtures" / "python_flask" / "serve.ct"

  DemoAppSuffix = "web/flask/app.py"
    ## The recorded demo app.  A row's seek must land in THIS file: an earlier
    ## version of the recorder's trace filter also traced Flask's own
    ## ``site-packages/flask/app.py``, and then every row's double-click landed
    ## in the framework's ``wsgi_app`` instead of in the app being debugged.

type
  ExpectedRow = object
    ## One row of the recorded session, transcribed from the recorder repo's
    ## ``DEMO_REQUESTS`` schedule and its Flask routes.
    httpMethod*: string
    url*: string
    statusCode*: int
    route*: string
    bucket*: string          ## the panel's status-colour bucket
    hasErrorMessage*: bool   ## a handler that raised must say so

const
  ExpectedRows: array[8, ExpectedRow] = [
    ExpectedRow(httpMethod: "GET", url: "/api/users", statusCode: 200,
      route: "/api/users", bucket: "success"),
    ExpectedRow(httpMethod: "POST", url: "/api/users", statusCode: 201,
      route: "/api/users", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/api/users/2", statusCode: 200,
      route: "/api/users/<int:user_id>", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/static/app.css", statusCode: 304,
      route: "/static/app.css", bucket: "redirect"),
    ExpectedRow(httpMethod: "GET", url: "/api/users/999", statusCode: 404,
      route: "/api/users/<int:user_id>", bucket: "client-error"),
    ExpectedRow(httpMethod: "GET", url: "/api/reports/slow", statusCode: 200,
      route: "/api/reports/slow", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/api/boom", statusCode: 500,
      route: "/api/boom", bucket: "server-error", hasErrorMessage: true),
    ExpectedRow(httpMethod: "GET", url: "/api/users", statusCode: 200,
      route: "/api/users", bucket: "success"),
  ]
    ## Eight requests covering every status bucket the panel colours (2xx, 3xx,
    ## 4xx, 5xx), two methods, a parameterised route, and a handler that raises.

  SlowRowIndex = 5
    ## ``/api/reports/slow`` sleeps 50 ms inside its handler, so its duration is
    ## the one row whose ``http.duration_ms`` can be asserted to be non-trivial
    ## rather than merely well formed.

# ---------------------------------------------------------------------------
# Helpers (shared shape with demo_recipe_vm_test.nim)
# ---------------------------------------------------------------------------

proc findByClass(node: MockNode; cls: string): MockNode =
  ## First descendant (or self) whose class attribute contains ``cls`` as a
  ## whole word.  Kept file-local, as the sibling request-panel tests do.
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  return nil

proc containerBytes(path: string): seq[byte] =
  let raw = readFile(path)
  result = newSeq[byte](raw.len)
  for i in 0 ..< raw.len:
    result[i] = byte(raw[i])

proc metaValue(span: SpanRecord; key: string): string =
  for (k, v) in span.metadata:
    if k == key:
      return v
  ""

proc numericMeta(span: SpanRecord; key: string): int =
  ## The db-backend's ``parse_numeric_metadata``: an absent or unparseable
  ## value is 0, never an error.
  try:
    parseInt(metaValue(span, key))
  except ValueError:
    0

proc statusName(s: SpanStatus): string =
  case s
  of spanStatusUnknown: "unknown"
  of spanStatusOk: "ok"
  of spanStatusError: "error"

proc toWireRecord(span: SpanRecord): JsonNode =
  ## Project a decoded span to the wire ``RequestRecord``, mirroring
  ## ``src/db-backend/src/request_spans.rs::to_request_record`` field for field
  ## (camelCase keys, ``start_step`` -> ``startGeid``, nullable
  ## ``externalTracePath``).  The Python recorder emits inline spans only, so the
  ## external-binding branch is unreachable from here; it has its own coverage in
  ## ``request_spans.rs``.
  %*{
    "id": int(span.spanId),
    "httpMethod": metaValue(span, "http.method"),
    "url": metaValue(span, "http.url"),
    "statusCode": numericMeta(span, "http.status_code"),
    "durationMs": numericMeta(span, "http.duration_ms"),
    "responseSize": numericMeta(span, "http.response_size"),
    "startGeid": int(span.startStep),
    "isOpen": span.isOpen,
    "status": statusName(span.status),
    "externalTracePath": newJNull(),
  }

proc deltaBody(spans: seq[JsonNode]; cursor: int; reset: bool): JsonNode =
  %*{"spans": spans, "cursor": cursor, "reset": reset,
     "source": "span-stream"}

proc webRequests(spans: seq[SpanRecord]): seq[SpanRecord] =
  for s in spans:
    if s.spanType == "web-request":
      result.add(s)

proc sourceOfStep(path: string; step: uint64): tuple[file: string, line: uint32] =
  ## Resolve a step id to its ``(source file, line)`` through the production
  ## trace reader, so "the seek lands in the handler" is checked against the
  ## recording rather than assumed.
  var readerRes = openNewTrace(path)
  doAssert readerRes.isOk, "openNewTrace: " & readerRes.error
  var reader = readerRes.get()
  let gli = reader.stepAbsoluteGlobalLineIndex(step)
  doAssert gli.isOk, "stepAbsoluteGlobalLineIndex(" & $step & "): " & gli.error
  let loc = reader.decodeGlobalPositionIndex(gli.get())
  doAssert loc.isOk, "decodeGlobalPositionIndex: " & loc.error
  let file = reader.path(loc.get().file)
  doAssert file.isOk, "path(" & $loc.get().file & "): " & file.error
  (file: file.get().replace('\\', '/'), line: loc.get().line)

# ---------------------------------------------------------------------------
# vm_python_request_panel_rows
# ---------------------------------------------------------------------------

suite "RS-M5 Python request panel":

  test "vm_python_request_panel_rows":
    check fileExists(FixtureContainer)
    let bytes = containerBytes(FixtureContainer)

    # --- the recording declares a span stream ---------------------------
    # The db-backend's span reader returns "no spans" for a container whose bit
    # 13 is clear, so a recorder that failed to register spans would show an
    # empty panel and no error anywhere.
    let metaRaw = readInternalFile(bytes, "meta.dat")
    check metaRaw.isOk
    let meta = readMetaDat(metaRaw.get())
    check meta.isOk
    check meta.get().hasSpanStream
    check hasSpanStreamFiles(bytes)
    # It is a Python recording of the demo server, not some other fixture that
    # happened to be copied in.
    check meta.get().program.replace('\\', '/').endsWith("web/serve.py")

    # --- decode with the production reader ------------------------------
    let readerRes = initSpanStreamReader(bytes)
    check readerRes.isOk
    let settledRes = readerRes.get().settledSpans()
    check settledRes.isOk
    let settled = settledRes.get()

    # Every request was published open first and then settled, so a reader
    # without last-record-wins would report sixteen spans here.
    let webSpans = webRequests(settled)
    check webSpans.len == ExpectedRows.len
    check settled.len == webSpans.len  # the session has no other span types yet

    for i, span in webSpans:
      checkpoint("span " & $i & " " & span.label)
      let want = ExpectedRows[i]
      check metaValue(span, "http.method") == want.httpMethod
      check metaValue(span, "http.url") == want.url
      check numericMeta(span, "http.status_code") == want.statusCode
      check metaValue(span, "http.route") == want.route
      check metaValue(span, "framework") == "flask"
      check span.label == want.httpMethod & " " & want.url
      check not span.isOpen
      check not span.isExternal   # inline binding: the steps are in THIS file
      check statusName(span.status) ==
        (if want.statusCode >= 400: "error" else: "ok")
      check (metaValue(span, "error.message").len > 0) == want.hasErrorMessage
      # Each request owns its own step range, ascending and disjoint — the
      # server handled one request at a time.
      check span.startStep > 0'u64
      check span.endStep > span.startStep
      if i > 0:
        check span.startStep > webSpans[i - 1].endStep

    # The 50 ms handler is the row whose duration must be more than "not zero".
    check numericMeta(webSpans[SlowRowIndex], "http.duration_ms") >= 40

    # --- the rows the ViewModel renders ---------------------------------
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)
      let tableBody = findByClass(panel, "request-table-body")
      check tableBody != nil
      check tableBody.children.len == 0

      var wire: seq[JsonNode] = @[]
      for span in webSpans:
        wire.add(toWireRecord(span))
      store.applyRequestSpanDelta(
        deltaBody(wire, cursor = webSpans.len, reset = true))

      check vm.requests.val.len == ExpectedRows.len
      check tableBody.children.len == ExpectedRows.len
      check store.requestSpans.source.val == "span-stream"

      for i in 0 ..< ExpectedRows.len:
        checkpoint("row " & $i & " " & ExpectedRows[i].url)
        let want = ExpectedRows[i]
        let row = vm.requests.val[i]
        # --- columns ---
        check row.id == int64(webSpans[i].spanId)
        check row.httpMethod == want.httpMethod
        check row.url == want.url
        check row.statusCode == want.statusCode
        check row.startGeid == int64(webSpans[i].startStep)
        check not row.isOpen
        # Durations and byte counts are timing / content dependent, so they are
        # asserted as properties: recorded, non-negative, and rendered.
        check row.durationMs >= 0
        check row.responseSize >= 0
        check durationText(row).len > 0
        check formatSize(row.responseSize).len > 0
        # --- status colouring ---
        check statusText(row) == $want.statusCode
        check statusBucket(row.statusCode) == want.bucket
        check statusCellClass(row) == "request-status-" & want.bucket
        # --- the rendered row ---
        let rowNode = tableBody.children[i]
        check rowNode.attributes["class"] == "request-row"
        let statusCell = findByClass(rowNode, "request-col-status")
        check statusCell != nil
        check findByClass(statusCell, "request-status-" & want.bucket) != nil
        check textContent(findByClass(rowNode, "request-col-url")) == want.url

      # Every bucket the pane spec colours is present, so the fixture actually
      # exercises the colouring instead of showing eight green rows.
      var buckets: seq[string] = @[]
      for row in vm.requests.val:
        let bucket = statusBucket(row.statusCode)
        if bucket notin buckets:
          buckets.add(bucket)
      check "success" in buckets
      check "redirect" in buckets
      check "client-error" in buckets
      check "server-error" in buckets

      # --- double-click seeks into the request's handler ------------------
      #
      # Driven through the rendered row's own ``ondblclick`` handler, not by
      # calling the ViewModel action directly, so the wiring is covered too.
      for i in 0 ..< ExpectedRows.len:
        checkpoint("dblclick row " & $i & " " & ExpectedRows[i].url)
        mock.clearReceivedCommands()
        fireEvent(tableBody.children[i], "dblclick")
        drain()
        let sent = mock.findCommand("ct/seek-to-geid")
        check sent.isSome
        check sent.get.args["geid"].getInt == int(webSpans[i].startStep)
        check sent.get.args["url"].getStr == ExpectedRows[i].url

      # The seek target is a step of THIS request — not a shared line, which is
      # the whole point of an inline-bound span — and it resolves into the
      # recorded demo app rather than into Flask's internals.
      var seekTargets: seq[uint64] = @[]
      for i, span in webSpans:
        checkpoint("seek target of row " & $i)
        check span.startStep notin seekTargets
        seekTargets.add(span.startStep)
        let loc = sourceOfStep(FixtureContainer, span.startStep)
        check loc.file.endsWith(DemoAppSuffix)
        check loc.line > 0'u32

      dispose()
