## elixir_request_panel_vm_test.nim
##
## RS-M8 — ``vm_elixir_request_panel_rows``.
##
## The codetracer-side half of the Elixir/Erlang milestone: the Request Panel's
## ViewModel, driven from a container **recorded by the BEAM recorder** while a
## real Cowboy listener served real HTTP requests to a real ``Plug.Router``.
## Per
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M8 it asserts the rendered rows over the recorded BEAM fixture.
##
## ## What is real here
##
## The fixture in ``fixtures/elixir_plug/app.ct`` is a genuine recording, not a
## hand-built container: ``codetracer-beam-recorder``'s
## ``CodetracerBeamRecorder.Plug`` middleware opened and settled every span
## itself, through ``:codetracer_erlang_runtime.web_request_start/1`` and
## ``web_request_stop/2``, while that repo's
## ``test-programs/elixir/plug_web`` served twelve requests over TCP.
## Regenerate it with
##
##   direnv exec ../codetracer-beam-recorder just \
##     record-request-panel-fixture <this dir>/fixtures/elixir_plug plug
##
## (the same session ``just demo-request-panel elixir`` records), and see
## ``fixtures/README.md``, which lives one level up because that recipe
## replaces the whole ``elixir_plug/`` directory.
##
## Everything downstream is production code: the container's ``meta.dat`` bit 13
## is read by the shipped reader, the spans are decoded by the canonical Nim
## span reader (``initSpanStreamReader`` / ``settledSpans`` — the same API
## ``src/ct/cli/print_trace.nim`` uses), and the rows come out of the real
## ``RequestPanelVM`` and the real IsoNim view.
##
## The ground truth is the demo's own request schedule (``PlugWeb.main/0`` in
## the recorder repo) plus ``PlugWeb.Router``'s routes, written out below.  It
## is deliberately NOT derived from the container, so a recorder bug cannot
## make the expectations agree with themselves.  Only the timing-dependent
## values (durations, byte counts, step indices) are asserted as properties.
##
## ## What is specific to the BEAM row
##
## * **A request is a THREAD, not a process.**  RS-M1b fixes a span's
##   coordinate as *(process_ord, thread_id, step range)*.  The BEAM recorder
##   records one OS process — the ``beam.smp`` it launched — and maps each
##   *BEAM* process onto a container **thread**
##   (``codetracer_session:ensure_pid_thread/3`` mints a thread id per pid).
##   So every row here carries ``process_ord == 0`` and a distinct
##   ``thread_id``, and the BEAM pid itself rides along as ``beam.pid``
##   metadata.  This is the only language row so far where twelve requests
##   occupy twelve different threads of one recording.
## * **Concurrency is visible in the data.**  Cowboy spawns a process per
##   connection and they genuinely run at once.  The first four requests of the
##   fixture block in a rendezvous until all four have arrived, so their step
##   ranges provably interleave and their spans carry
##   ``concurrent_with_siblings``; the remaining eight were issued one at a
##   time and do not.  The recorder-side proof that this follows the schedule
##   rather than being a constant is ``plug_requests_test.exs``, which records
##   the same program a second time under a strictly sequential driver.
## * **No seek-to-source assertion.**  Unlike the PHP row, this test does not
##   resolve a row's ``startGeid`` back to a source line, because the recorder
##   emits no per-line step events for Elixir sources under ``mix run``: step
##   instrumentation is applied to ``.erl`` sources, and the app's own activity
##   reaches the container as call/return records in ``calls.dat``.  A request's
##   step range is therefore made of the thread events that bracket it — a
##   real, distinct, ordered coordinate in this container's exec stream, which
##   is what the panel seeks to, but not something that resolves to a line of
##   ``router.ex``.  Asserting otherwise here would be asserting a fiction.
##
## Mocking justification (per the workspace policy on mock objects): the only
## mock is ``MockBackendService``, used purely as the transport that carries an
## already-decoded delta into the store — exactly as in
## ``demo_recipe_vm_test.nim`` and the Python, Ruby and PHP request-panel
## tests.  There is no fake container, no fake reader and no fake span data:
## the bytes are a real recording and are decoded by the real readers.
##
## Native-only: it reads real container bytes through a zstd FFI, which does not
## exist on the ``nim js`` backend, so ``just test-vm-js`` excludes this file and
## ``src/ct_test/release_gate.nim`` registers it in ``CoreViewModelGateTests``.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/elixir_request_panel_vm_test.nim

import std/[algorithm, json, options, os, strutils, tables, unittest]
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
    "fixtures" / "elixir_plug" / "app.ct"

  CohortSize = 4
    ## ``PlugWeb.main/0`` issues this many requests at once against
    ## ``/concurrent/:slot``; each blocks in ``PlugWeb.Barrier`` until the whole
    ## cohort has arrived, so all four are inside their handlers at the same
    ## instant.

type
  ExpectedRow = object
    ## One row of the recorded session, transcribed from ``PlugWeb.main/0``'s
    ## schedule and ``PlugWeb.Router``'s routes.
    httpMethod*: string
    url*: string
    statusCode*: int
    route*: string
    bucket*: string          ## the panel's status-colour bucket

const
  ExpectedSequentialRows: array[8, ExpectedRow] = [
    ExpectedRow(httpMethod: "GET", url: "/api/users", statusCode: 200,
      route: "/api/users", bucket: "success"),
    ExpectedRow(httpMethod: "POST", url: "/api/users", statusCode: 201,
      route: "/api/users", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/api/users/2", statusCode: 200,
      route: "/api/users/:user_id", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/static/app.css", statusCode: 304,
      route: "/static/app.css", bucket: "redirect"),
    ExpectedRow(httpMethod: "GET", url: "/api/users/999", statusCode: 404,
      route: "/api/users/:user_id", bucket: "client-error"),
    ExpectedRow(httpMethod: "GET", url: "/slow", statusCode: 200,
      route: "/slow", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/boom", statusCode: 500,
      route: "/boom", bucket: "server-error"),
    ExpectedRow(httpMethod: "GET", url: "/healthz", statusCode: 200,
      route: "/healthz", bucket: "success"),
  ]
    ## The eight requests the driver issues one at a time, in order.  They
    ## cover every status bucket the panel colours (2xx, 3xx, 4xx, 5xx), two
    ## methods, a parameterised route and a handler that raises.

  SlowRowIndex = 5
    ## ``/slow`` sleeps 400 ms inside its handler, so its duration is the one
    ## row whose ``http.duration_ms`` can be asserted to be substantial rather
    ## than merely well formed.

  TotalRows = CohortSize + ExpectedSequentialRows.len

# ---------------------------------------------------------------------------
# Helpers (shared shape with the python_/ruby_/php_ request-panel tests)
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
  ## ``externalTracePath``).  The BEAM recorder emits inline spans only — the
  ## container's own exec stream carries the coordinate — so the
  ## external-binding branch is unreachable from here.
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
# vm_elixir_request_panel_rows
# ---------------------------------------------------------------------------

suite "RS-M8 Elixir request panel":

  test "vm_elixir_request_panel_rows":
    check fileExists(FixtureContainer)
    let bytes = containerBytes(FixtureContainer)

    # --- the recording declares a span stream ----------------------------
    # The db-backend's span reader returns "no spans" for a container whose bit
    # 13 is clear, so a recorder that failed to register spans would show an
    # empty panel and no error anywhere.
    let metaRaw = readInternalFile(bytes, "meta.dat")
    check metaRaw.isOk
    let meta = readMetaDat(metaRaw.get())
    check meta.isOk
    check meta.get().hasSpanStream
    check hasSpanStreamFiles(bytes)

    # --- decode with the production reader -------------------------------
    let readerRes = initSpanStreamReader(bytes)
    check readerRes.isOk
    let reader0 = readerRes.get()
    let settledRes = reader0.settledSpans()
    check settledRes.isOk
    let settled = settledRes.get()

    # Every request was published open first and then settled, so a reader
    # without last-record-wins would report twenty-four rows here.
    let allRes = reader0.readAllSpanRecords()
    check allRes.isOk
    check allRes.get().len == TotalRows * 2

    let webSpans = webRequests(settled)
    check webSpans.len == TotalRows
    check settled.len == webSpans.len  # the session has no other span types yet

    # --- the BEAM coordinate ---------------------------------------------
    # One OS process, one thread per BEAM process.  Twelve requests served by
    # twelve Cowboy connection processes must therefore be twelve threads of
    # ONE recording — not twelve recordings, and not one thread reused.
    var seenThreads: seq[uint64] = @[]
    var seenPids: seq[string] = @[]
    for i, span in webSpans:
      checkpoint("span " & $i & " " & span.label)
      check span.processOrd == 0'u64
      check span.threadId notin seenThreads
      seenThreads.add(span.threadId)
      let pid = metaValue(span, "beam.pid")
      check pid.startsWith("<")
      check pid.endsWith(">")
      check pid notin seenPids
      seenPids.add(pid)
      # The metadata pair and the span's own coordinate must agree: the
      # metadata is for a human reading the panel, the coordinate is what the
      # reader binds to, and they name the same process.
      check metaValue(span, "beam.thread_id") == $span.threadId
      check not span.isOpen
      check not span.isExternal   # inline binding: the steps are in THIS file
      check span.sharesTimeline
      check metaValue(span, "framework") == "plug"
      check span.label ==
        metaValue(span, "http.method") & " " & metaValue(span, "http.url")
      check span.endStep >= span.startStep
      check statusName(span.status) ==
        (if numericMeta(span, "http.status_code") >= 400: "error" else: "ok")

    # --- the rendezvous cohort -------------------------------------------
    # These four requests were provably inside their handlers at the same
    # instant, so their ranges interleave and the format says so.  Their
    # arrival order is a property of the scheduler, so the URLs are compared as
    # a set while everything else is compared exactly.
    var cohortUrls: seq[string] = @[]
    for i in 0 ..< CohortSize:
      let span = webSpans[i]
      checkpoint("cohort row " & $i & " " & span.label)
      cohortUrls.add(metaValue(span, "http.url"))
      check metaValue(span, "http.route") == "/concurrent/:slot"
      check numericMeta(span, "http.status_code") == 200
      check span.concurrentWithSiblings
      # Other requests' events are interleaved into the shared exec stream, so
      # the interval is not an uninterrupted run on one thread.
      check not span.contiguousOnOneThread
    cohortUrls.sort()
    check cohortUrls == @["/concurrent/1", "/concurrent/2", "/concurrent/3",
                          "/concurrent/4"]

    for i in 0 ..< CohortSize:
      for j in (i + 1) ..< CohortSize:
        checkpoint("cohort overlap " & $i & "/" & $j)
        # Genuinely overlapping and genuinely distinct.
        check webSpans[i].startStep <= webSpans[j].endStep
        check webSpans[j].startStep <= webSpans[i].endStep
        check webSpans[i].startStep != webSpans[j].startStep

    # --- the sequential tail ---------------------------------------------
    for k, want in ExpectedSequentialRows:
      let span = webSpans[CohortSize + k]
      checkpoint("sequential row " & $k & " " & span.label)
      check metaValue(span, "http.method") == want.httpMethod
      check metaValue(span, "http.url") == want.url
      check numericMeta(span, "http.status_code") == want.statusCode
      # The routed pattern, not the path the client typed.
      check metaValue(span, "http.route") == want.route
      check not span.concurrentWithSiblings
      if k > 0:
        # Issued one at a time, so each owns a later, disjoint interval.
        check span.startStep > webSpans[CohortSize + k - 1].endStep

    # The 304 sends no body; the rows that do must report bytes.
    let cssRow = webSpans[CohortSize + 3]
    check metaValue(cssRow, "http.url") == "/static/app.css"
    check numericMeta(cssRow, "http.response_size") == 0
    check numericMeta(webSpans[CohortSize + 0], "http.response_size") > 0

    # The 400 ms handler is the row whose duration must be more than "not
    # zero".
    check numericMeta(webSpans[CohortSize + SlowRowIndex],
                      "http.duration_ms") >= 400

    # --- the rows the ViewModel renders ----------------------------------
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

      check vm.requests.val.len == TotalRows
      check tableBody.children.len == TotalRows
      check store.requestSpans.source.val == "span-stream"

      for i in 0 ..< TotalRows:
        checkpoint("row " & $i & " " & metaValue(webSpans[i], "http.url"))
        let span = webSpans[i]
        let row = vm.requests.val[i]
        # --- columns ---
        check row.id == int64(span.spanId)
        check row.httpMethod == metaValue(span, "http.method")
        check row.url == metaValue(span, "http.url")
        check row.statusCode == numericMeta(span, "http.status_code")
        check row.startGeid == int64(span.startStep)
        check not row.isOpen
        # Durations and byte counts are timing / content dependent, so they are
        # asserted as properties: recorded, non-negative, and rendered.
        check row.durationMs >= 0
        check row.responseSize >= 0
        check durationText(row).len > 0
        check formatSize(row.responseSize).len > 0
        # --- status colouring ---
        check statusText(row) == $row.statusCode
        check statusCellClass(row) == "request-status-" & statusBucket(row.statusCode)
        # --- the rendered row ---
        let rowNode = tableBody.children[i]
        check rowNode.attributes["class"] == "request-row"
        let statusCell = findByClass(rowNode, "request-col-status")
        check statusCell != nil
        check textContent(findByClass(rowNode, "request-col-url")) == row.url

      # The sequential tail's buckets are the schedule's, exactly.
      for k, want in ExpectedSequentialRows:
        checkpoint("sequential bucket " & $k & " " & want.url)
        let row = vm.requests.val[CohortSize + k]
        check statusBucket(row.statusCode) == want.bucket
        let rowNode = tableBody.children[CohortSize + k]
        check findByClass(rowNode, "request-status-" & want.bucket) != nil

      # Every bucket the pane spec colours is present, so the fixture actually
      # exercises the colouring instead of showing twelve green rows.
      var buckets: seq[string] = @[]
      for row in vm.requests.val:
        let bucket = statusBucket(row.statusCode)
        if bucket notin buckets:
          buckets.add(bucket)
      check "success" in buckets
      check "redirect" in buckets
      check "client-error" in buckets
      check "server-error" in buckets

      # --- activating a row seeks to that span's step range ---------------
      #
      # Driven through the rendered row's own ``ondblclick`` handler, not by
      # calling the ViewModel action directly, so the wiring is covered too.
      # Twelve requests are twelve intervals of ONE recording, so the twelve
      # seek targets must be twelve distinct steps of it — the property that
      # makes the panel usable at all on a server recording.
      var seekTargets: seq[int] = @[]
      for i in 0 ..< TotalRows:
        checkpoint("dblclick row " & $i)
        mock.clearReceivedCommands()
        fireEvent(tableBody.children[i], "dblclick")
        drain()
        let sent = mock.findCommand("ct/seek-to-geid")
        check sent.isSome
        let target = sent.get.args["geid"].getInt
        check target == int(webSpans[i].startStep)
        check target notin seekTargets
        seekTargets.add(target)
        check sent.get.args["url"].getStr == metaValue(webSpans[i], "http.url")
        # The target is inside the row's own interval, and no other row's
        # interval starts there.
        check uint64(target) >= webSpans[i].startStep
        check uint64(target) <= webSpans[i].endStep

      dispose()
