## js_request_panel_vm_test.nim
##
## RS-M9 — ``vm_js_request_panel_rows``.
##
## The codetracer-side half of the JavaScript milestone: the Request Panel's
## ViewModel, driven from a container **recorded by the JS recorder** while a
## real Express app on a real ``http.Server`` served real HTTP requests over
## loopback.  Per
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M9 it asserts that the rows render and that activating a row seeks into
## that request's own step range.
##
## ## What is real here
##
## The fixture in ``fixtures/js_express/index.ct`` is a genuine recording, not
## a hand-built container: ``codetracer-js-recorder``'s Express middleware
## (``packages/express``) opened and settled the spans, and the recorder's
## native addon wrote them into ``spans.dat`` while that repo's
## ``test-programs/web/express/index.js`` drove seven HTTP requests at the demo
## app in ``test-programs/web/express/app.js``.  Regenerate it with
##
##   direnv exec ../codetracer-js-recorder just \
##     record-request-panel-fixture <this dir>/fixtures/js_express
##
## (the same session ``just demo-request-panel js`` records), and see
## ``fixtures/README.md``, which lives one level up because that recipe
## replaces the whole ``js_express/`` directory.
##
## Everything downstream is production code: the container's ``meta.dat`` bit 13
## is read by the shipped reader, the spans are decoded by the canonical Nim
## span reader (``initSpanStreamReader`` / ``settledSpans`` — the same API
## ``src/ct/cli/print_trace.nim`` uses), the step bindings are resolved through
## the production trace reader (``openNewTrace``), and the rows come out of the
## real ``RequestPanelVM`` and the real IsoNim view.
##
## The ground truth for every row is the recorder repo's request schedule
## (``DEMO_REQUESTS`` in ``test-programs/web/express/index.js``) plus the demo
## app's routes, written out below as ``ExpectedRow``.  It is deliberately NOT
## derived from the container, so a recorder bug cannot make the expectations
## agree with themselves.  Only the timing-dependent values (durations, step
## indices) are asserted as properties.
##
## ## What is specific to the JavaScript row
##
## * **A request is a slice of one event loop, and the slices are not all of
##   one kind.**  The JS recorder maps each Node async context
##   (``async_hooks.executionAsyncId()``) onto a container thread, so a handler
##   that runs to completion without yielding is a contiguous run of the exec
##   stream, while a handler that ``await``s has its continuation land on a
##   different context *inside its own step range*.  This is the first fixture
##   in which ``contiguous_on_one_thread`` takes **both** values in one
##   sequential recording, and the assertions below require exactly that — a
##   recorder that hard-coded the bit either way fails here.
## * **Seeks resolve to the handler's source.**  The instrumenter instruments
##   the app but not ``node_modules``, so a request's step range is made of
##   real per-line steps of ``app.js`` and a double-click lands on a line of
##   the handler — unlike the Elixir row, whose ranges contain no per-line
##   steps at all.
##
##   One honest caveat, asserted below rather than papered over: a span's
##   ``start_step`` is the first EXEC-STREAM event of its interval, and for a
##   request that resumes on a different async context before its handler runs
##   (the POST, whose body parser awaits the request's ``data`` events) that
##   first event is a ``ThreadStart``.  A thread event carries no source
##   position, so the reader resolves it to its fallback rather than to the
##   handler's own line.  The *range* still covers the handler's lines, which
##   is what the assertions below require of every row.
## * **Column-aware, like the Python recording.**  The recorder opts into
##   column-aware step encoding by default and ships ``paths.dat`` Layout A
##   line-length tables, so steps resolve through
##   ``decodeGlobalPositionIndex`` rather than the line-only reconstruction the
##   PHP and Ruby rows need.
##
## Mocking justification (per the workspace policy on mock objects): the only
## mock is ``MockBackendService``, used purely as the transport that carries an
## already-decoded delta into the store — exactly as in
## ``demo_recipe_vm_test.nim`` and the Python / Ruby / PHP / Elixir
## request-panel tests.  There is no fake container, no fake reader and no fake
## span data: the bytes are a real recording and are decoded by the real
## readers.
##
## Native-only: it reads real container bytes through a zstd FFI, which does not
## exist on the ``nim js`` backend, so ``just test-vm-js`` excludes this file and
## ``src/ct_test/release_gate.nim`` registers it in ``CoreViewModelGateTests``.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/js_request_panel_vm_test.nim

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
    "fixtures" / "js_express" / "index.ct"

  DemoAppSuffix = "web/express/app.js"
    ## The recorded demo app.  A row's seek must land in THIS file — not in
    ## the driver (``index.js``) that issued the requests, and not in a
    ## neighbouring request's steps.

  DriverSuffix = "web/express/index.js"
    ## The in-process driver.  It is recorded too (it is part of the program),
    ## which is why "the seek lands in the handler" has to be checked rather
    ## than assumed.

type
  ExpectedRow = object
    ## One row of the recorded session, transcribed from the recorder repo's
    ## ``DEMO_REQUESTS`` schedule and the demo app's routes.
    httpMethod*: string
    url*: string
    statusCode*: int
    route*: string
    bucket*: string          ## the panel's status-colour bucket
    hasErrorMessage*: bool   ## a handler that failed must say so
    contiguous*: bool        ## did the handler run without yielding?

const
  ExpectedRows: array[7, ExpectedRow] = [
    ExpectedRow(httpMethod: "GET", url: "/api/users", statusCode: 200,
      route: "/api/users", bucket: "success", contiguous: true),
    # The body parser awaits the request's `data` events, so the handler runs
    # on a different async context than the one the span opened on.  This row
    # is non-contiguous for the same reason the awaiting handler below is, and
    # it is the reason a POST cannot be assumed to behave like a GET.
    ExpectedRow(httpMethod: "POST", url: "/api/users", statusCode: 201,
      route: "/api/users", bucket: "success", contiguous: false),
    ExpectedRow(httpMethod: "GET", url: "/api/users/2", statusCode: 200,
      route: "/api/users/:userId", bucket: "success", contiguous: true),
    ExpectedRow(httpMethod: "GET", url: "/api/users/999", statusCode: 404,
      route: "/api/users/:userId", bucket: "client-error", contiguous: true),
    ExpectedRow(httpMethod: "GET", url: "/static/app.css", statusCode: 304,
      route: "/static/app.css", bucket: "redirect", contiguous: true),
    # THE async handler: it awaits ~50 ms inside its own span.
    ExpectedRow(httpMethod: "GET", url: "/api/reports/slow", statusCode: 200,
      route: "/api/reports/slow", bucket: "success", contiguous: false),
    ExpectedRow(httpMethod: "GET", url: "/api/boom", statusCode: 500,
      route: "/api/boom", bucket: "server-error", hasErrorMessage: true,
      contiguous: true),
  ]
    ## Seven requests covering every status bucket the panel colours (2xx, 3xx,
    ## 4xx, 5xx), two methods, a parameterised route, a handler that awaits and
    ## a handler that throws.

  SlowRowIndex = 5
    ## ``/api/reports/slow`` awaits ~50 ms inside its handler, so its duration
    ## is the one row whose ``http.duration_ms`` can be asserted to be
    ## non-trivial rather than merely well formed.

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
  ## ``src/db-backend/src/request_spans.rs::to_request_record`` field for field
  ## (camelCase keys, ``start_step`` -> ``startGeid``, nullable
  ## ``externalTracePath``).  The JS recorder emits inline spans only — the
  ## whole milestone is about the steps living in the same container — so the
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

proc sourceOfStep(reader: var NewTraceReader;
                  step: uint64): tuple[file: string, line: uint32] =
  ## Resolve a step id to its ``(source file, line)`` through the production
  ## trace reader, so "the seek lands in the handler" is checked against the
  ## recording rather than assumed.
  ##
  ## The JS recorder is column-aware and ships ``paths.dat`` Layout A
  ## line-length tables, so the container carries a real global-position index
  ## and this goes through ``decodeGlobalPositionIndex`` — the same path the
  ## Python row takes, and not the line-only reconstruction the PHP and Ruby
  ## rows need.
  let gli = reader.stepAbsoluteGlobalLineIndex(step)
  doAssert gli.isOk, "stepAbsoluteGlobalLineIndex(" & $step & "): " & gli.error
  let loc = reader.decodeGlobalPositionIndex(gli.get())
  doAssert loc.isOk, "decodeGlobalPositionIndex: " & loc.error
  let file = reader.path(loc.get().file)
  doAssert file.isOk, "path(" & $loc.get().file & "): " & file.error
  (file: file.get().replace('\\', '/'), line: loc.get().line)

# ---------------------------------------------------------------------------
# vm_js_request_panel_rows
# ---------------------------------------------------------------------------

suite "RS-M9 JavaScript request panel":

  test "vm_js_request_panel_rows":
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

    # ONE container for the whole session: one Node process served all seven
    # requests, and both recorded sources (the app and the in-process driver)
    # are interned once for the process rather than once per request.
    check meta.get().paths.len == 2
    var recordedPaths: seq[string] = @[]
    for p in meta.get().paths:
      recordedPaths.add(p.replace('\\', '/'))
    var sawApp = false
    var sawDriver = false
    for p in recordedPaths:
      if p.endsWith(DemoAppSuffix): sawApp = true
      if p.endsWith(DriverSuffix): sawDriver = true
    check sawApp
    check sawDriver

    # --- decode with the production reader ------------------------------
    let readerRes = initSpanStreamReader(bytes)
    check readerRes.isOk
    let reader0 = readerRes.get()
    let settledRes = reader0.settledSpans()
    check settledRes.isOk
    let settled = settledRes.get()

    # Every request was published open first and then settled, so a reader
    # without last-record-wins would report fourteen rows here.
    let allRes = reader0.readAllSpanRecords()
    check allRes.isOk
    check allRes.get().len == ExpectedRows.len * 2

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
      check metaValue(span, "framework") == "express"
      check span.label == want.httpMethod & " " & want.url
      check not span.isOpen
      check not span.isExternal   # inline binding: the steps are in THIS file
      check span.parentSpanId == 0'u64
      # One Node process per recording, so every span names the primary one.
      check span.processOrd == 0'u64
      check statusName(span.status) ==
        (if want.statusCode >= 400: "error" else: "ok")
      # Status and message are independent: the 404 is an error status with no
      # message, so a span that carried one whenever it carried the other
      # would pass a weaker test than this.
      check (metaValue(span, "error.message").len > 0) == want.hasErrorMessage
      # Each request owns its own step range, ascending and disjoint — one
      # event loop handled them one at a time over a single timeline.
      check span.startStep > 0'u64
      check span.endStep > span.startStep
      if i > 0:
        check span.startStep > webSpans[i - 1].endStep

      # --- the structural bits, which are what makes this row different ---
      #
      # Every span is a slice of the recording's one exec-stream ordering...
      check span.sharesTimeline
      # ...none of them overlap, because the driver issued the requests one at
      # a time and Node ran them on one event loop...
      check not span.concurrentWithSiblings
      # ...and contiguity is per-request: a handler that never yielded is an
      # uninterrupted run of that stream, while one that awaited has its own
      # continuation land on a different async context inside its range.
      check span.contiguousOnOneThread == want.contiguous
      # Each request entered on its own async context, which the recorder maps
      # to its own container thread.
      check span.threadId > 0'u64

    # The bit is not a constant in either direction — the property that makes
    # asserting it worth anything.  (`ExpectedRows` above pins WHICH rows.)
    var contiguousCount = 0
    var splitCount = 0
    var threadIds: seq[uint64] = @[]
    for span in webSpans:
      if span.contiguousOnOneThread: contiguousCount += 1 else: splitCount += 1
      check span.threadId notin threadIds
      threadIds.add(span.threadId)
    check contiguousCount > 0
    check splitCount > 0

    # The 304 sends no body; the rows that do must report bytes.
    check numericMeta(webSpans[4], "http.response_size") == 0
    check numericMeta(webSpans[0], "http.response_size") > 0

    # The ~50 ms awaiting handler is the row whose duration must be more than
    # "not zero".
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
      # exercises the colouring instead of showing seven green rows.
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
      for i in 0 ..< ExpectedRows.len:
        checkpoint("dblclick row " & $i & " " & ExpectedRows[i].url)
        mock.clearReceivedCommands()
        fireEvent(tableBody.children[i], "dblclick")
        drain()
        let sent = mock.findCommand("ct/seek-to-geid")
        check sent.isSome
        check sent.get.args["geid"].getInt == int(webSpans[i].startStep)
        check sent.get.args["url"].getStr == ExpectedRows[i].url

      # The seek target is a step of THIS request and of no other, and — the
      # claim specific to this row — it resolves to a line of the HANDLER's
      # source rather than merely to some distinct ordered coordinate.  The
      # driver that issued the requests is recorded in the same container, so
      # landing in `app.js` rather than `index.js` is a real discrimination.
      var traceRes = openNewTrace(FixtureContainer)
      check traceRes.isOk
      var trace = traceRes.get()
      var seekTargets: seq[uint64] = @[]
      var coveredLines: seq[seq[uint32]] = @[]
      for i, span in webSpans:
        checkpoint("seek target of row " & $i)
        check span.startStep notin seekTargets
        seekTargets.add(span.startStep)
        check span.startStep <= span.endStep
        let loc = sourceOfStep(trace, span.startStep)
        check loc.file.endsWith(DemoAppSuffix)
        check loc.line > 0'u32
        # And the LAST step of the span is inside the app too, so the range a
        # row resolves to is a real interval of this recording and not a
        # single reachable point at the front of it.
        let endLoc = sourceOfStep(trace, span.endStep)
        check endLoc.file.endsWith(DemoAppSuffix)

        # The range covers this request's OWN handler.  This is the assertion
        # that would fail if a row's steps were really its neighbour's, and it
        # is deliberately not a hard-coded line number: it walks the whole
        # range and records the distinct source lines it reaches.
        var lines: seq[uint32] = @[]
        var step = span.startStep
        while step <= span.endStep:
          let at = sourceOfStep(trace, step)
          check at.file.endsWith(DemoAppSuffix)
          if at.line notin lines:
            lines.add(at.line)
          step += 1
        # More than one line, so the range is a stretch of the handler's body
        # and not a single position repeated.
        check lines.len >= 2
        coveredLines.add(lines)

      # No two requests cover the same set of source lines.  The two
      # ``/api/users/:userId`` rows share a handler and are told apart by the
      # branch they took (the 404 return vs. the success path), which is
      # exactly the resolution the panel promises: a row seeks into ITS OWN
      # execution, not into "the handler" generically.
      for i in 0 ..< coveredLines.len:
        for j in (i + 1) ..< coveredLines.len:
          checkpoint("line coverage of rows " & $i & " and " & $j)
          check coveredLines[i] != coveredLines[j]

      dispose()
