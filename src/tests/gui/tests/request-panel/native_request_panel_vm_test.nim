## native_request_panel_vm_test.nim
##
## RS-M10 — ``vm_native_request_panel_rows``.
##
## The codetracer-side half of the native/MCR milestone: the Request Panel's
## ViewModel, driven from a container **recorded by ct-mcr** while a real
## nginx served real HTTP requests over loopback.  Per
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M10 it asserts the rendered rows over the recorded native fixture.
##
## ## What is real here
##
## The fixture in ``fixtures/native_nginx/nginx.ct`` is a genuine recording,
## not a hand-built container: ``ct-mcr record`` recorded a real
## ``nginx -c …`` process under LD_PRELOAD interposition while ``curl`` drove
## five requests at it, and ``codetracer-native-recorder``'s request
## discoverer then read that container's own OS events back and wrote the
## spans it found into the container's ``spans.dat`` / ``spans.idx`` /
## ``spantype.ns``.  Regenerate it with
##
##   direnv exec ../codetracer-native-recorder just \
##     record-request-panel-fixture <this dir>/fixtures/native_nginx
##
## (the same session ``just demo-request-panel native`` records), and see
## ``fixtures/README.md``, which lives one level up because that recipe
## replaces the whole ``native_nginx/`` directory.
##
## Everything downstream is production code: the container's ``meta.dat`` bit
## 13 is read by the shipped reader, the spans are decoded by the canonical
## Nim span reader (``initSpanStreamReader`` / ``settledSpans`` — the same API
## ``src/ct/cli/print_trace.nim`` uses), and the rows come out of the real
## ``RequestPanelVM`` and the real IsoNim view.
##
## The ground truth is the recorder repo's fixture recipe — the five requests
## ``just record-request-panel-fixture`` issues and the routes its generated
## ``nginx.conf`` declares — written out below as ``ExpectedRows``.  It is
## deliberately NOT derived from the container, so a discovery bug cannot make
## the expectations agree with themselves.
##
## ## What is specific to the native row
##
## * **Nothing in the recorded program knows what a request is.**  Every other
##   language row is produced by a middleware inside the recorded process that
##   calls the span writer.  nginx has no such seam and ``ct-mcr`` records
##   syscalls, so these spans are DISCOVERED after the fact by matching the
##   recorded ``recv``/``writev`` payloads into request/response pairs.  The
##   ``discovery.mode`` metadata key says so on every row, and it is the one
##   key no managed recorder emits.
## * **One settled record per span, not an open/settled pair.**  A middleware
##   publishes an open record when the request arrives and a settled one when
##   it finishes, which is why the Elixir and JS tests assert
##   ``readAllSpanRecords().len == rows * 2``.  A post-pass has no "in flight"
##   moment to publish — by the time discovery runs, every request already
##   ended — so it appends exactly one record per row and this test asserts
##   ``== rows``.  Both are valid streams under the last-record-wins rule; the
##   difference is real and is asserted rather than papered over.
## * **No seek-to-source assertion**, for the same reason as the Elixir row
##   and more strongly: a ``ct-mcr`` container carries no ``steps.dat`` at
##   all.  A span's ``start_step`` / ``end_step`` are GEIDs — positions in the
##   recording's own event ordering — so what the panel seeks to is a real,
##   distinct, ordered coordinate in this container, but not a line of C.
##   Asserting otherwise here would be asserting a fiction.
## * **The wall clock is the SERVER's, at the server's resolution.**  There is
##   no per-event timestamp in a native container (``meta.dat`` reports
##   ``tickSource: none``, so the tick is an event counter), so the discoverer
##   anchors each span on the nearest clock reading nginx itself took.  Those
##   readings come from the vDSO ``time(2)`` fast path and have one-second
##   resolution, so ``http.duration_ms`` is 0 for requests served in under a
##   second — which is the true value at the resolution the recording holds.
##   The test asserts the epoch is real (post-2017) and that durations are
##   well formed, and deliberately does NOT assert a positive duration, which
##   would be asserting a number the recording does not contain.
##
## Mocking justification (per the workspace policy on mock objects): the only
## mock is ``MockBackendService``, used purely as the transport that carries an
## already-decoded delta into the store — exactly as in
## ``demo_recipe_vm_test.nim`` and the Python / Ruby / PHP / Elixir / JS
## request-panel tests.  There is no fake container, no fake reader and no
## fake span data: the bytes are a real recording and are decoded by the real
## readers.
##
## Native-only: it reads real container bytes through a zstd FFI, which does
## not exist on the ``nim js`` backend, so ``just test-vm-js`` excludes this
## file and ``src/ct_test/release_gate.nim`` registers it in
## ``CoreViewModelGateTests``.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/native_request_panel_vm_test.nim

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

# ---------------------------------------------------------------------------
# The fixture and what it is expected to contain
# ---------------------------------------------------------------------------

const
  FixtureContainer = currentSourcePath.parentDir /
    "fixtures" / "native_nginx" / "nginx.ct"

type
  ExpectedRow = object
    ## One row of the recorded session, transcribed from the recorder repo's
    ## ``record-request-panel-fixture`` recipe: its curl schedule and the
    ## ``location`` blocks of the ``nginx.conf`` it generates.
    httpMethod*: string
    url*: string
    statusCode*: int
    bucket*: string          ## the panel's status-colour bucket

const
  ExpectedRows: array[5, ExpectedRow] = [
    # A static file, served through `ngx_writev_chain` because the recipe sets
    # `sendfile off` — so it takes the same write path a generated body does.
    ExpectedRow(httpMethod: "GET", url: "/index.html", statusCode: 200,
      bucket: "success"),
    # A `return 200` body generated by nginx itself.
    ExpectedRow(httpMethod: "GET", url: "/ping", statusCode: 200,
      bucket: "success"),
    # A file that is not there.
    ExpectedRow(httpMethod: "GET", url: "/missing.html", statusCode: 404,
      bucket: "client-error"),
    # An explicit non-standard status, so "the discoverer reads the status
    # line" cannot be satisfied by recognising a handful of common codes.
    ExpectedRow(httpMethod: "GET", url: "/teapot", statusCode: 418,
      bucket: "client-error"),
    # A method the location forbids: same URL as row 1, different method and
    # different status, so a row cannot be identified by its URL alone.
    ExpectedRow(httpMethod: "POST", url: "/ping", statusCode: 403,
      bucket: "client-error"),
  ]

  PingRowIndex = 1
    ## ``GET /ping``.
  PostPingRowIndex = 4
    ## ``POST /ping`` — the same URL, and the reason the rows are compared
    ## pairwise on (method, url, status) rather than on url alone.

# ---------------------------------------------------------------------------
# Helpers (shared shape with the sibling request-panel tests)
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
  ## ``src/db-backend/src/request_spans.rs::to_request_record`` field for
  ## field (camelCase keys, ``start_step`` -> ``startGeid``, nullable
  ## ``externalTracePath``).  Discovered spans are inline — the coordinate is
  ## in THIS container — so the external-binding branch is unreachable here.
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

# ---------------------------------------------------------------------------
# vm_native_request_panel_rows
# ---------------------------------------------------------------------------

suite "RS-M10 native request panel":

  test "vm_native_request_panel_rows":
    check fileExists(FixtureContainer)
    let bytes = containerBytes(FixtureContainer)

    # --- the recording declares a span stream ---------------------------
    # The db-backend's span reader returns "no spans" for a container whose
    # bit 13 is clear, so a discovery pass that failed to stamp it would show
    # an empty panel and no error anywhere.  On this path the bit is set by a
    # length-preserving in-place rewrite AFTER the recording closed, which is
    # exactly the step that could silently not happen.
    let metaRaw = readInternalFile(bytes, "meta.dat")
    check metaRaw.isOk
    let meta = readMetaDat(metaRaw.get())
    check meta.isOk
    check meta.get().hasSpanStream
    check hasSpanStreamFiles(bytes)

    # A ct-mcr recording of a C program carries no source-step streams; the
    # panel's coordinate is the container's own event ordering.  Asserted so
    # that a future change which starts emitting them is noticed here rather
    # than silently changing what a row seeks to.
    check not meta.get().hasStepStream

    # --- decode with the production reader ------------------------------
    let readerRes = initSpanStreamReader(bytes)
    check readerRes.isOk
    let reader0 = readerRes.get()
    let settledRes = reader0.settledSpans()
    check settledRes.isOk
    let settled = settledRes.get()

    # ONE record per row: discovery is a post-pass, so no span was ever
    # published open.  (The Elixir and JS rows assert ``* 2`` here because a
    # live middleware publishes an open record first.)
    let allRes = reader0.readAllSpanRecords()
    check allRes.isOk
    check allRes.get().len == ExpectedRows.len
    for rec in allRes.get():
      check not rec.isOpen

    let webSpans = webRequests(settled)
    check webSpans.len == ExpectedRows.len
    # One nginx process with `master_process off`, so the recording holds no
    # `span_type: "process"` records either — the request spans are the whole
    # stream.
    check settled.len == webSpans.len

    for i, span in webSpans:
      checkpoint("span " & $i & " " & span.label)
      let want = ExpectedRows[i]
      check metaValue(span, "http.method") == want.httpMethod
      check metaValue(span, "http.url") == want.url
      check numericMeta(span, "http.status_code") == want.statusCode
      check metaValue(span, "framework") == "nginx"
      # The key that exists only on this row of the language matrix: nothing
      # in nginx called a span writer, so the row has to say where it came
      # from.
      check metaValue(span, "discovery.mode") == "event-scan"
      check span.label == want.httpMethod & " " & want.url
      check not span.isOpen
      check not span.isExternal   # inline binding: the steps are in THIS file
      check span.parentSpanId == 0'u64
      # `master_process off` — one process, so every span names the primary.
      check span.processOrd == 0'u64
      check statusName(span.status) ==
        (if want.statusCode >= 400: "error" else: "ok")
      # Every row reports the bytes nginx actually wrote for it.  Before
      # RS-M10 closed the `writev` capture hole this was not merely wrong but
      # absent: the response never reached the trace at all.
      check numericMeta(span, "http.response_size") > 0
      # A real UNIX epoch taken from a clock reading the SERVER made, not a
      # tick counter dressed up as nanoseconds.  1.5e18 ns is 2017.
      check span.startWallNs > 1_500_000_000_000_000_000'u64
      check span.endWallNs >= span.startWallNs
      # Well formed, but NOT asserted positive: see the header.
      check numericMeta(span, "http.duration_ms") >= 0
      # Each request owns its own step range, ascending and disjoint — one
      # nginx worker served them one at a time over a single timeline.
      check span.startStep > 0'u64
      check span.endStep > span.startStep
      if i > 0:
        check span.startStep > webSpans[i - 1].endStep

      # --- the structural bits --------------------------------------------
      # Every span is a slice of the recording's one GEID ordering...
      check span.sharesTimeline
      # ...the matcher followed one socket conversation on ONE thread from
      # request to response...
      check span.contiguousOnOneThread
      # ...and a single non-threaded worker never had two in flight.  This is
      # derived from the intervals in the recorder's `toSpanRecords`, not
      # hard-coded at the call site: two overlapping intervals set it.
      check not span.concurrentWithSiblings

    # The same URL under two methods is two distinct rows with two distinct
    # statuses — the discriminator that a URL-keyed discoverer would fail.
    check metaValue(webSpans[PingRowIndex], "http.url") ==
      metaValue(webSpans[PostPingRowIndex], "http.url")
    check metaValue(webSpans[PingRowIndex], "http.method") !=
      metaValue(webSpans[PostPingRowIndex], "http.method")
    check numericMeta(webSpans[PingRowIndex], "http.status_code") !=
      numericMeta(webSpans[PostPingRowIndex], "http.status_code")

    # Span ids are distinct, so the panel can key rows on them.
    var ids: seq[uint64] = @[]
    for span in webSpans:
      check span.spanId notin ids
      ids.add(span.spanId)

    # `spantype.ns` lets a reader fetch the request list without decompressing
    # a single span record, and it must name the discovered type.
    let nsRes = readSpanTypeNamespace(bytes)
    check nsRes.isOk
    var sawWebRequest = false
    for entry in nsRes.get():
      if entry.name == "web-request":
        sawWebRequest = true
        check entry.spanIds.len == ExpectedRows.len
    check sawWebRequest

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
        checkpoint("row " & $i & " " & ExpectedRows[i].httpMethod & " " &
          ExpectedRows[i].url)
        let want = ExpectedRows[i]
        let row = vm.requests.val[i]
        # --- columns ---
        check row.id == int64(webSpans[i].spanId)
        check row.httpMethod == want.httpMethod
        check row.url == want.url
        check row.statusCode == want.statusCode
        check row.startGeid == int64(webSpans[i].startStep)
        check not row.isOpen
        check row.durationMs >= 0
        check row.responseSize > 0
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

      # Both buckets this session produces are present, so the colouring is
      # exercised rather than asserted against five identical green rows.
      var buckets: seq[string] = @[]
      for row in vm.requests.val:
        let bucket = statusBucket(row.statusCode)
        if bucket notin buckets:
          buckets.add(bucket)
      check "success" in buckets
      check "client-error" in buckets

      # --- activating a row seeks to that span's step range ---------------
      #
      # Driven through the rendered row's own ``ondblclick`` handler, not by
      # calling the ViewModel action directly, so the wiring is covered too.
      # A native container has no per-line steps, so what is asserted is what
      # this recording actually supports: each row seeks to ITS OWN, distinct,
      # ordered coordinate — and no two rows seek to the same place.
      var seekTargets: seq[int] = @[]
      for i in 0 ..< ExpectedRows.len:
        checkpoint("dblclick row " & $i & " " & ExpectedRows[i].url)
        mock.clearReceivedCommands()
        fireEvent(tableBody.children[i], "dblclick")
        drain()
        let sent = mock.findCommand("ct/seek-to-geid")
        check sent.isSome
        let geid = sent.get.args["geid"].getInt
        check geid == int(webSpans[i].startStep)
        check sent.get.args["url"].getStr == ExpectedRows[i].url
        check geid notin seekTargets
        seekTargets.add(geid)

      dispose()
