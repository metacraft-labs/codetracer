## php_request_panel_vm_test.nim
##
## RS-M7 — ``vm_php_request_panel_rows_and_seek``.
##
## The codetracer-side half of the PHP milestone: the Request Panel's
## ViewModel, driven from a container **recorded by the PHP recorder** while a
## real ``php -S`` process served real HTTP requests.  Per
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M7 it asserts that the rows render and that activating a row seeks to
## that span's step range within the worker's recording.
##
## ## What is real here
##
## The fixture in ``fixtures/php_builtin/app.ct`` is a genuine recording, not a
## hand-built container: ``codetracer-php-recorder``'s C extension wrote its
## ``spans.dat`` records itself while that repo's
## ``tests/programs/web/session_driver.php`` drove eight HTTP requests at the
## demo app in ``tests/programs/web/app.php``.  Regenerate it with
##
##   direnv exec ../codetracer-php-recorder just \
##     record-request-panel-fixture <this dir>/fixtures/php_builtin
##
## (the same session ``just demo-request-panel php`` records), and see
## ``fixtures/README.md``, which lives one level up because that recipe
## replaces the whole ``php_builtin/`` directory.
##
## Everything downstream is production code: the container's ``meta.dat`` bit 13
## is read by the shipped reader, the spans are decoded by the canonical Nim
## span reader (``initSpanStreamReader`` / ``settledSpans`` — the same API
## ``src/ct/cli/print_trace.nim`` uses), the step bindings are resolved through
## the production trace reader (``openNewTrace``), and the rows come out of the
## real ``RequestPanelVM`` and the real IsoNim view.
##
## The ground truth for every row is the recorder repo's request schedule
## (``CT_DEMO_REQUESTS`` in ``tests/programs/web/session_driver.php``) plus the
## demo app's routes, written out below as ``ExpectedRow``.  It is deliberately
## NOT derived from the container, so a recorder bug cannot make the
## expectations agree with themselves.  Only the timing-dependent values
## (durations, byte counts, step indices) are asserted as properties.
##
## ## What is specific to the PHP row
##
## * **One container for eight requests.**  This is the whole point of RS-M7.
##   Before it, the extension opened a writer in ``PHP_RINIT`` and closed it in
##   ``PHP_RSHUTDOWN``, so this session would have been eight separate
##   recordings in eight directories, tied together only by a
##   ``session_manifest.jsonl`` sidecar.  Now the worker holds one continuous
##   recording and the requests are eight intervals of its timeline — which is
##   why the seek assertions below can require every row's ``start_step`` to be
##   a distinct step of THIS file.
## * **The demo app is a plain router, not a framework.**  ``framework`` is
##   therefore ``plain`` and the route patterns use PHP-style ``{user_id}``
##   placeholders.  The Laravel integration ships as a middleware and an
##   ``auto_prepend_file`` in the recorder repo; it needs a Composer install,
##   which the recorder's dev shell does not provide, so the checked-in fixture
##   is the plain-server session.
## * **Column-unaware, like the Ruby recording.**  See ``lineOnlyGli``.
##
## Mocking justification (per the workspace policy on mock objects): the only
## mock is ``MockBackendService``, used purely as the transport that carries an
## already-decoded delta into the store — exactly as in
## ``demo_recipe_vm_test.nim``, ``python_request_panel_vm_test.nim`` and
## ``ruby_request_panel_vm_test.nim``.  There is no fake container, no fake
## reader and no fake span data: the bytes are a real recording and are decoded
## by the real readers.
##
## Native-only: it reads real container bytes through a zstd FFI, which does not
## exist on the ``nim js`` backend, so ``just test-vm-js`` excludes this file and
## ``src/ct_test/release_gate.nim`` registers it in ``CoreViewModelGateTests``.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/php_request_panel_vm_test.nim

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
import codetracer_trace_writer/global_line_index
from codetracer_trace_writer/multi_stream_writer import DefaultLinesPerFile

# ---------------------------------------------------------------------------
# The fixture and what it is expected to contain
# ---------------------------------------------------------------------------

const
  FixtureContainer = currentSourcePath.parentDir /
    "fixtures" / "php_builtin" / "app.ct"

  DemoAppSuffix = "web/app.php"
    ## The recorded demo app.  A row's seek must land in THIS file, which for
    ## the PHP recorder also means it must not land on the synthetic
    ## ``<toplevel>`` frame of a *neighbouring* request — the failure mode a
    ## continuous worker timeline introduces and a per-request recording could
    ## not have.

type
  ExpectedRow = object
    ## One row of the recorded session, transcribed from the recorder repo's
    ## ``CT_DEMO_REQUESTS`` schedule and the demo app's routes.
    httpMethod*: string
    url*: string
    statusCode*: int
    route*: string
    bucket*: string          ## the panel's status-colour bucket
    hasErrorMessage*: bool   ## a handler that failed must say so

const
  ExpectedRows: array[8, ExpectedRow] = [
    ExpectedRow(httpMethod: "GET", url: "/api/users", statusCode: 200,
      route: "/api/users", bucket: "success"),
    ExpectedRow(httpMethod: "POST", url: "/api/users", statusCode: 201,
      route: "/api/users", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/api/users/2", statusCode: 200,
      route: "/api/users/{user_id}", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/static/app.css", statusCode: 304,
      route: "/static/app.css", bucket: "redirect"),
    ExpectedRow(httpMethod: "GET", url: "/api/users/999", statusCode: 404,
      route: "/api/users/{user_id}", bucket: "client-error"),
    ExpectedRow(httpMethod: "GET", url: "/api/reports/slow", statusCode: 200,
      route: "/api/reports/slow", bucket: "success"),
    ExpectedRow(httpMethod: "GET", url: "/api/boom", statusCode: 500,
      route: "/api/boom", bucket: "server-error", hasErrorMessage: true),
    ExpectedRow(httpMethod: "GET", url: "/api/users", statusCode: 200,
      route: "/api/users", bucket: "success"),
  ]
    ## Eight requests covering every status bucket the panel colours (2xx, 3xx,
    ## 4xx, 5xx), two methods, a parameterised route, and a handler that fails.

  SlowRowIndex = 5
    ## ``/api/reports/slow`` sleeps ~50 ms inside its handler, so its duration
    ## is the one row whose ``http.duration_ms`` can be asserted to be
    ## non-trivial rather than merely well formed.

# ---------------------------------------------------------------------------
# Helpers (shared shape with python_/ruby_request_panel_vm_test.nim)
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
  ## ``externalTracePath``).  The PHP recorder emits inline spans only — the
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

proc lineOnlyGli(pathCount: int): GlobalLineIndex =
  ## The global-line index a COLUMN-UNAWARE trace was written against.
  ##
  ## The PHP extension registers plain ``(path, line)`` steps and does not opt
  ## into column-aware tracing, so ``decodeGlobalPositionIndex`` (which needs
  ## the per-line byte-length tables) refuses the container and a step's
  ## ``global_position_index`` is instead the writer's line-only encoding:
  ## ``DefaultLinesPerFile`` lines allocated per file, so the index is
  ## ``file_base + line``.  This is precisely what ``ct print`` reconstructs
  ## (``buildGliFromMeta`` in ``codetracer_ct_print_lib``), from the writer's
  ## own constant, so this test resolves steps the same way the shipped CLI
  ## does.
  var counts = newSeq[uint64](pathCount)
  for i in 0 ..< pathCount:
    counts[i] = DefaultLinesPerFile
  buildGlobalLineIndex(counts)

proc sourceOfStep(reader: var NewTraceReader; gliIndex: GlobalLineIndex;
                  step: uint64): tuple[file: string, line: uint32] =
  ## Resolve a step id to its ``(source file, line)`` through the production
  ## trace reader, so "the seek lands in the handler" is checked against the
  ## recording rather than assumed.
  let gli = reader.stepAbsoluteGlobalLineIndex(step)
  doAssert gli.isOk, "stepAbsoluteGlobalLineIndex(" & $step & "): " & gli.error
  let (fileId, line) = gliIndex.resolve(gli.get())
  let file = reader.path(uint64(fileId))
  doAssert file.isOk, "path(" & $fileId & "): " & file.error
  (file: file.get().replace('\\', '/'), line: uint32(line))

# ---------------------------------------------------------------------------
# vm_php_request_panel_rows_and_seek
# ---------------------------------------------------------------------------

suite "RS-M7 PHP request panel":

  test "vm_php_request_panel_rows_and_seek":
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
    # NOTE: ``meta.get().recorderId`` is deliberately NOT asserted.  The FFI's
    # ``ct_write_meta_dat`` is a documented no-op on the multi-stream backend
    # ("Multi-stream writer writes meta.dat automatically during close()") and
    # drops the recorder id on the floor, so no CTFS V4 container the PHP
    # recorder has ever produced carries one — including the traces recorded
    # before RS-M7.  That is an FFI gap, not a milestone regression.

    # ONE container for the whole session, and its program is the demo app —
    # not one of eight per-request recordings.  The path table is the direct
    # evidence that interning is shared across the eight requests: the app is
    # interned once for the worker, not once per request.
    check meta.get().paths.len == 1
    check meta.get().paths[0].replace('\\', '/').endsWith(DemoAppSuffix)

    # --- decode with the production reader ------------------------------
    let readerRes = initSpanStreamReader(bytes)
    check readerRes.isOk
    let reader0 = readerRes.get()
    let settledRes = reader0.settledSpans()
    check settledRes.isOk
    let settled = settledRes.get()

    # Every request was published open first and then settled, so a reader
    # without last-record-wins would report sixteen rows here.
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
      check metaValue(span, "framework") == "plain"
      check span.label == want.httpMethod & " " & want.url
      check not span.isOpen
      check not span.isExternal   # inline binding: the steps are in THIS file
      check statusName(span.status) ==
        (if want.statusCode >= 400: "error" else: "ok")
      # Status and message are independent: the 404 is an error status with no
      # message, so a span that carried one whenever it carried the other
      # would pass a weaker test than this.
      check (metaValue(span, "error.message").len > 0) == want.hasErrorMessage
      # Each request owns its own step range, ascending and disjoint — one
      # worker handled them one at a time over a single timeline.
      check span.startStep > 0'u64
      check span.endStep > span.startStep
      if i > 0:
        check span.startStep > webSpans[i - 1].endStep

    # The 304 sends no body; the rows that do must report bytes.
    check numericMeta(webSpans[3], "http.response_size") == 0
    check numericMeta(webSpans[0], "http.response_size") > 0

    # The ~50 ms handler is the row whose duration must be more than "not zero".
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

      # The seek target is a step of THIS request and of no other.  On a
      # per-request recording that would be trivially true; on one continuous
      # worker timeline it is the property that makes the panel usable, so it
      # is checked against the recording rather than assumed: every target is
      # distinct, lies inside its own span's range, and resolves into the
      # recorded demo app.
      var traceRes = openNewTrace(FixtureContainer)
      check traceRes.isOk
      var trace = traceRes.get()
      let gliIndex = lineOnlyGli(meta.get().paths.len)
      var seekTargets: seq[uint64] = @[]
      for i, span in webSpans:
        checkpoint("seek target of row " & $i)
        check span.startStep notin seekTargets
        seekTargets.add(span.startStep)
        check span.startStep >= span.startStep
        check span.startStep <= span.endStep
        let loc = sourceOfStep(trace, gliIndex, span.startStep)
        check loc.file.endsWith(DemoAppSuffix)
        check loc.line > 0'u32
        # And the LAST step of the span is inside the app too, so the range a
        # row resolves to is a real interval of this recording and not a
        # single reachable point at the front of it.
        let endLoc = sourceOfStep(trace, gliIndex, span.endStep)
        check endLoc.file.endsWith(DemoAppSuffix)

      dispose()
