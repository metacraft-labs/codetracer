## demo_recipe_vm_test.nim
##
## RS-M4 — ``demo_recipe_produces_populated_session``.
##
## The one required test of the milestone.  It runs the container-production
## step of ``just demo-request-panel`` headlessly and asserts, per
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M4:
##
## a) the produced container has a span stream and declares ``meta.dat`` bit 13
##    (``FlagHasSpanStream``); and
## b) a ViewModel built over it renders the expected rows.
##
## Its purpose is to guard the recipe against rot.  It calls
## ``writeDemoRequestSession`` — the SAME proc the recipe's CLI entry point
## calls, not a copy of it — so a change that breaks the demo breaks this test.
##
## Two further cases guard the claims ``just demo-request-panel-live``'s header
## makes about the GROWING session, both of which are properties of the producer
## that no amount of looking at the final container would reveal:
##
## c) *a truncated demo session is a chunk prefix of the full one* — each stage
##    re-seals its earlier chunks to byte-identical bytes, asserted on the raw
##    ``spans.dat`` / ``spans.idx`` bytes, on every previously sealed record, and
##    on the chunk geometry.  Monotonic counts are deliberately NOT accepted as
##    evidence: a producer that re-seals chunk 0 differently every stage still
##    counts up, and that was the actual bug this case was written to catch.
## d) *the live session is seen with a request in flight, which then settles* —
##    tailing the growing container the way the backend does yields a delta with
##    an ``isOpen`` row, which the next stage settles in place.  It is a claim
##    about what the panel OBSERVES, so the check goes through the real store,
##    ViewModel and row rendering.
##
## ## What is real and what is not
##
## Real: the container.  It is written by the canonical Nim writer
## (``codetracer-trace-format-nim``'s ``multi_stream_writer`` +
## ``span_stream``), onto a real filesystem, and read back through the
## production Nim reader (``initSpanStreamReader`` / ``settledSpans`` — the same
## API ``src/ct/cli/print_trace.nim`` ships).  Bit 13 is asserted from the
## container's own ``meta.dat``, and the ground truth for every row is the
## producer's INPUT table (``DemoRequests``), never a re-read of the container,
## so a writer bug cannot make the expectations agree with themselves.
##
## Not exercised here: the db-backend's Rust reader and its DAP handler. Those
## have their own tests over committed fixtures produced by the same writer
## (``src/db-backend/tests/request_span_tail_test.rs`` and
## ``src/db-backend/src/request_spans.rs``); duplicating them from Nim would
## test a second decoder, not the recipe. What this test asserts about the wire
## shape is that the projection ``request_spans.rs::to_request_record`` performs
## — ``http.*`` metadata to ``RequestRecord`` fields, ``start_step`` to
## ``startGeid`` — lands rows the panel renders correctly. The projection is
## mirrored here in ``toWireRecord``, and the mirror is pinned by the same
## ``DemoRequests`` table the producer writes from, so the two cannot drift
## into describing different sessions.
##
## Mocking justification (per the workspace policy on mock objects): the only
## mock is ``MockBackendService``, used solely as the transport that carries an
## already-decoded delta into the store. There is no fake container, no fake
## reader and no fake span data anywhere in this file — the bytes come from the
## real writer and are decoded by the real reader. A real backend process was
## deliberately not used: the tests that need one
## (``integration/real_backend_test.nim``) are excluded from
## ``just test-vm-native`` because they are heavy, and a test excluded from the
## runner guards nothing.
##
## Native-only: the container is real filesystem bytes written through a zstd
## FFI, which does not exist on the ``nim js`` backend.  ``just test-vm-js``
## excludes this file for that reason.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/demo_recipe_vm_test.nim

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

import ../../../../tools/demo_request_session

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc findByClass(node: MockNode; cls: string): MockNode =
  ## First descendant (or self) whose class attribute contains ``cls`` as a
  ## whole word.  Same helper as ``request_panel_live_vm_test.nim``; duplicated
  ## because that file keeps it file-local.
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
  ## ``externalTracePath``).  The demo session has no external bindings, so the
  ## resolution branch is not reachable from here — it is covered by
  ## ``request_spans.rs``' own tests.
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

proc demoDir(name: string): string =
  let dir = getTempDir() / ("ct-rs-m4-" & name & "-" & $getCurrentProcessId())
  removeDir(dir)
  dir

proc internalBytes(bytes: seq[byte]; name: string): seq[byte] =
  ## One internal CTFS file, raw.  Used to compare the SEALED BYTES of the span
  ## stream across stages, which is the strongest available statement of chunk
  ## immutability: it does not go through the decoder at all.
  let r = readInternalFile(bytes, name)
  doAssert r.isOk, name & ": " & r.error
  r.get()

proc prefixMismatch(prefix, whole: seq[byte]): int =
  ## ``-1`` when ``prefix`` is a byte prefix of ``whole``; otherwise the first
  ## index at which they differ (or ``whole.len`` when ``whole`` is the shorter
  ## of the two, i.e. the stream shrank).
  if whole.len < prefix.len:
    return whole.len
  for i in 0 ..< prefix.len:
    if prefix[i] != whole[i]:
      return i
  -1

type LiveStage = tuple[through: int, openOnly: bool]

const LiveStages: array[9, LiveStage] = [
  (through: 1, openOnly: false),
  (through: 2, openOnly: false),
  (through: 3, openOnly: false),
  (through: 4, openOnly: false),
  (through: 5, openOnly: false),
  (through: 6, openOnly: true),   # request 6 published open, still in flight
  (through: 6, openOnly: false),  # ... and settled one stage later
  (through: 7, openOnly: false),
  (through: 8, openOnly: false),
]
  ## The stage sequence ``just demo-request-panel-live`` walks, in order.  Kept
  ## in step with the ``stages`` array in that recipe: these tests are only
  ## evidence about the demo if they grow the container the way the demo does.

proc stageLabel(s: LiveStage): string =
  "stage --through=" & $s.through & (if s.openOnly: " --open-only" else: "")

proc webRequests(spans: seq[SpanRecord]): seq[SpanRecord] =
  for s in spans:
    if s.spanType == "web-request":
      result.add(s)

# ---------------------------------------------------------------------------
# demo_recipe_produces_populated_session
# ---------------------------------------------------------------------------

suite "RS-M4 demo recipe":

  test "demo_recipe_produces_populated_session":
    let dir = demoDir("full")
    defer: removeDir(dir)

    # --- The recipe's container-production step, run headlessly ----------
    let produced = writeDemoRequestSession(dir)
    check produced.isOk
    let containerPath = produced.get()
    check containerPath == dir / "trace.ct"
    check fileExists(containerPath)
    # The recorded source is written next to the container so the editor pane
    # has the handler the panel seeks into.
    check fileExists(dir / DemoProgramName)

    let bytes = containerBytes(containerPath)

    # --- (a) the container declares a span stream (meta.dat bit 13) ------
    let metaRaw = readInternalFile(bytes, "meta.dat")
    check metaRaw.isOk
    let meta = readMetaDat(metaRaw.get())
    check meta.isOk
    # This is the assertion the whole demo hangs on: the db-backend's span
    # reader returns "no spans" for a container whose bit 13 is clear
    # (``span_stream.rs::open_from_ctfs``), so a producer that forgot to
    # register spans would yield an empty panel and no error anywhere.
    check meta.get().hasSpanStream
    # The writer sets the bit because spans were registered, not by request —
    # so the files must actually be there too.
    check hasSpanStreamFiles(bytes)
    check meta.get().recordingId == DemoRecordingId

    # --- Decode with the production reader ------------------------------
    let readerRes = initSpanStreamReader(bytes)
    check readerRes.isOk
    let settledRes = readerRes.get().settledSpans()
    check settledRes.isOk
    let settled = settledRes.get()

    # One process descriptor (RS-M1b) plus one span per request.  The
    # open/completion pair collapses to ONE settled span, so a reader without
    # last-record-wins would see nine requests here.
    check settled.len == DemoRequests.len + 1
    check settled[0].spanType == "process"

    var webSpans: seq[SpanRecord] = @[]
    for span in settled:
      if span.spanType == "web-request":
        webSpans.add(span)
    check webSpans.len == DemoRequests.len

    # Ground truth is the producer's INPUT table, not a re-read.
    for i, span in webSpans:
      checkpoint("request " & $i & " " & DemoRequests[i].url)
      let want = DemoRequests[i]
      check metaValue(span, "http.method") == want.httpMethod
      check metaValue(span, "http.url") == want.url
      check numericMeta(span, "http.status_code") == want.statusCode
      check numericMeta(span, "http.duration_ms") == want.durationMs
      check numericMeta(span, "http.response_size") == want.responseSize
      # Every request settled: the one published open was superseded.
      check not span.isOpen
      check statusName(span.status) ==
        (if want.statusCode >= 400: "error" else: "ok")
      # Each request owns its own step range, so double-clicking row N seeks
      # into request N's handler and not into a shared line.
      check span.startStep > 0'u64
      check span.endStep > span.startStep

    # Step ranges are disjoint and ascending — the property that makes the
    # seek meaningful.
    for i in 1 ..< webSpans.len:
      check webSpans[i].startStep > webSpans[i - 1].endStep

    # --- (b) a ViewModel over the container renders the expected rows ----
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
      store.applyRequestSpanDelta(deltaBody(wire, cursor = 9, reset = true))

      check vm.requests.val.len == DemoRequests.len
      check tableBody.children.len == DemoRequests.len
      check store.requestSpans.source.val == "span-stream"

      for i in 0 ..< DemoRequests.len:
        checkpoint("row " & $i & " " & DemoRequests[i].url)
        let want = DemoRequests[i]
        let row = vm.requests.val[i]
        check row.httpMethod == want.httpMethod
        check row.url == want.url
        check row.statusCode == want.statusCode
        check row.durationMs == want.durationMs
        check row.responseSize == want.responseSize
        check row.startGeid == int64(webSpans[i].startStep)
        check not row.isOpen
        # Rendered as a settled row, never as in-flight.
        check tableBody.children[i].attributes["class"] == "request-row"
        check statusText(row) == $want.statusCode
        check statusCellClass(row) ==
          "request-status-" & statusBucket(want.statusCode)

      # Every status bucket the pane spec colours is present, so the demo
      # actually shows the colouring off rather than eight green rows.
      var buckets: seq[string] = @[]
      for row in vm.requests.val:
        let bucket = statusBucket(row.statusCode)
        if bucket notin buckets:
          buckets.add(bucket)
      check "success" in buckets
      check "redirect" in buckets
      check "client-error" in buckets
      check "server-error" in buckets

      # The 940 ms request straddles the pane spec's duration boundary in the
      # other direction from the 1 ms ones; both shapes must render.
      check durationText(vm.requests.val[0]) == "12ms"
      check durationText(vm.requests.val[5]) == "940ms"

      # The panel's filters work over the rows the demo produces — the demo is
      # only useful if the URLs it serves are worth filtering.
      # Two ``/api/users`` and two ``/api/users/42`` — the shared prefix is
      # what gives the demo's search box something to narrow.
      vm.setSearchText("/api/users")
      check vm.filteredRequests.val.len == 4
      vm.setSearchText("/api/users/42")
      check vm.filteredRequests.val.len == 2
      vm.setSearchText("")
      vm.setFilterStatus("5xx")
      check vm.filteredRequests.val.len == 1
      check vm.filteredRequests.val[0].url == "/api/orders/7"
      vm.setFilterStatus("")

      # Activating a row seeks to that request's handler entry.
      mock.clearReceivedCommands()
      vm.jumpToHandler(2)
      drain()
      let sent = mock.findCommand("ct/seek-to-geid")
      check sent.isSome
      check sent.get.args["geid"].getInt == int(webSpans[2].startStep)

      dispose()

  test "a truncated demo session is a chunk prefix of the full one":
    # This is what makes ``just demo-request-panel-live`` a real live session
    # rather than a slideshow: stage ``n``'s span stream must be a strict CHUNK
    # PREFIX of stage ``n+1``'s, because the backend's tail cursor counts
    # chunks and treats a sealed chunk as immutable
    # (``request_spans.rs`` — "chunk k means the same records in every later
    # observation of the same container").  If a stage resealed earlier chunks
    # differently the panel would either miss rows or re-reset on every poll.
    #
    # Monotonic record and chunk counts do NOT establish that: a producer that
    # re-seals chunk 0 with different bytes at every stage still counts up.  So
    # the property is asserted the only way that settles it —
    #
    #   * ``spans.dat`` and ``spans.idx`` of each stage must contain the
    #     previous stage's bytes UNCHANGED, at the same offsets; and
    #   * every record the previous stage had already sealed must decode to an
    #     identical ``SpanRecord``, in the same append position; and
    #   * every chunk the previous stage had sealed must still start at the same
    #     record and hold the same number of records.
    #
    # (The regression this guards against is real: deriving the process
    # descriptor's ``endStep`` from the request TOTAL put a count-dependent
    # record in chunk 0, and chunk 0 then re-sealed with different bytes at
    # every single stage.)
    let dir = demoDir("prefix")
    defer: removeDir(dir)

    var prevDat: seq[byte] = @[]
    var prevIdx: seq[byte] = @[]
    var prevRecords: seq[SpanRecord] = @[]
    var prevGeometry: seq[tuple[first: uint64, count: int]] = @[]
    var prevChunks = 0
    var isFirstStage = true

    for stage in LiveStages:
      checkpoint(stageLabel(stage))
      let produced = writeDemoRequestSession(dir,
        throughRequest = stage.through, openOnly = stage.openOnly)
      check produced.isOk
      let bytes = containerBytes(produced.get())

      # Same recording id at every stage, so the tail recognises the rewritten
      # container as the SAME recording and serves a delta instead of a reset.
      let metaRaw = readInternalFile(bytes, "meta.dat")
      check metaRaw.isOk
      check readMetaDat(metaRaw.get()).get().recordingId == DemoRecordingId

      let readerRes = initSpanStreamReader(bytes)
      check readerRes.isOk
      let reader = readerRes.get()
      let recordsRes = reader.readAllSpanRecords()
      check recordsRes.isOk
      let records = recordsRes.get()

      # Every stage adds at least one sealed chunk, so a tailing panel always
      # has something new to show.
      check records.len > prevRecords.len
      check reader.chunkCount() > prevChunks

      let dat = internalBytes(bytes, SpansDataFileName)
      let idx = internalBytes(bytes, SpansIndexFileName)

      if not isFirstStage:
        # (1) The sealed BYTES are untouched — no re-compression, no shifted
        # chunk offsets.
        checkpoint("spans.dat prefix mismatch at byte " &
          $prefixMismatch(prevDat, dat))
        check prefixMismatch(prevDat, dat) == -1
        checkpoint("spans.idx prefix mismatch at byte " &
          $prefixMismatch(prevIdx, idx))
        check prefixMismatch(prevIdx, idx) == -1

        # (2) Record for record, the previously sealed records are identical.
        for i in 0 ..< prevRecords.len:
          checkpoint("record " & $i & " (span " & $prevRecords[i].spanId &
            ", " & prevRecords[i].spanType & ")")
          check records[i] == prevRecords[i]

        # (3) Chunk k still means the same records — the sentence the
        # backend's cursor is built on, asserted literally.
        for c in 0 ..< prevGeometry.len:
          checkpoint("chunk " & $c)
          check reader.firstRecordOfChunk(c) == prevGeometry[c].first
          check reader.recordsInChunk(c) == prevGeometry[c].count

      prevDat = dat
      prevIdx = idx
      prevRecords = records
      prevChunks = reader.chunkCount()
      prevGeometry = @[]
      for c in 0 ..< reader.chunkCount():
        prevGeometry.add((first: reader.firstRecordOfChunk(c),
          count: reader.recordsInChunk(c)))
      isFirstStage = false

      let settled = reader.settledSpans()
      check settled.isOk
      # One process span plus one span per request served so far — the request
      # published open first collapses to a single settled span in every stage
      # that carries its completion, and is the in-flight row in the stage that
      # does not.
      check settled.get().len == stage.through + 1
      check webRequests(settled.get()).len == stage.through

    # The final stage is the same session the default recipe produces: the two
    # process-descriptor records (open, then settled) plus one record per
    # request plus request 6's open record.
    check prevRecords.len == 2 + DemoRequests.len + 1

  test "the live session is seen with a request in flight, which then settles":
    # ``demo-request-panel-live``'s header promises that "one request is seen in
    # flight before it settles".  That is a claim about what a TAILING PANEL
    # observes, and it does not follow from the container merely containing an
    # open record: the backend applies ``resolve_spans`` WITHIN a delta, so a
    # stage that publishes an open record and its completion together (one
    # atomic rename, one poll) yields a single settled row and the in-flight
    # rendering is never reached.  The ``--open-only`` stage exists to break the
    # pair across two stages; this test is what says it works.
    #
    # It walks the recipe's stage list exactly as the recipe does, tails the
    # container the way the backend does (``readSpansSince`` from the chunk
    # count last seen, ``resolveSpans`` within the delta), and feeds the result
    # through the real store and ViewModel.
    let dir = demoDir("inflight")
    defer: removeDir(dir)

    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)
      let tableBody = findByClass(panel, "request-table-body")
      check tableBody != nil

      var cursor = 0
      var inFlightStages = 0
      var inFlightSpanId = 0'u64
      var settledAfterInFlight = 0
      # Per stage: the rows the panel holds after that poll, and whether the
      # DELTA (not the accumulated list) carried an in-flight row.
      for stage in LiveStages:
        checkpoint(stageLabel(stage))
        let produced = writeDemoRequestSession(dir,
          throughRequest = stage.through, openOnly = stage.openOnly)
        check produced.isOk
        let bytes = containerBytes(produced.get())
        let readerRes = initSpanStreamReader(bytes)
        check readerRes.isOk
        let reader = readerRes.get()

        # The tail: only the chunks sealed since the last poll.
        let deltaRes = reader.readSpansSince(cursor)
        check deltaRes.isOk
        let deltaSpans = webRequests(resolveSpans(deltaRes.get()))
        var wire: seq[JsonNode] = @[]
        for span in deltaSpans:
          wire.add(toWireRecord(span))
        store.applyRequestSpanDelta(deltaBody(wire,
          cursor = reader.chunkCount(), reset = cursor == 0))
        cursor = reader.chunkCount()

        # Each stage carries exactly one request record for the panel.
        check deltaSpans.len == 1
        check vm.requests.val.len == stage.through
        check tableBody.children.len == stage.through

        let row = vm.requests.val[^1]
        if row.isOpen:
          inc inFlightStages
          inFlightSpanId = uint64(row.id)
          # The in-flight row the pane spec describes: no status, no duration,
          # and the ``request-row-open`` modifier CSS greys.
          check stage.openOnly
          check deltaSpans[0].isOpen
          check statusName(deltaSpans[0].status) == "unknown"
          check row.statusCode == 0
          check row.durationMs == 0
          check statusText(row) == InFlightPlaceholder
          check durationText(row) == InFlightPlaceholder
          check statusCellClass(row) == "request-status-unknown"
          check tableBody.children[^1].attributes["class"] ==
            "request-row request-row-open"
        else:
          check not stage.openOnly
          if inFlightSpanId != 0'u64 and uint64(row.id) == inFlightSpanId:
            # The very next stage settles the SAME span: the client-side
            # last-record-wins merge replaced the in-flight row in place rather
            # than adding a ninth.
            inc settledAfterInFlight
            let want = DemoRequests[stage.through - 1]
            check row.statusCode == want.statusCode
            check row.durationMs == want.durationMs
            check statusName(deltaSpans[0].status) ==
              (if want.statusCode >= 400: "error" else: "ok")
            check statusText(row) == $want.statusCode
            check durationText(row) != InFlightPlaceholder
            check tableBody.children[^1].attributes["class"] == "request-row"
            inFlightSpanId = 0'u64

      # Exactly one stage is in flight, and it is followed by the stage that
      # settles it.  Both halves matter: without the first the promise in the
      # recipe header is false, and without the second the demo would leave a
      # permanently grey row.
      check inFlightStages == 1
      check settledAfterInFlight == 1
      check vm.requests.val.len == DemoRequests.len
      for row in vm.requests.val:
        check not row.isOpen

      dispose()

  test "the live recipe grows the container through exactly these stages":
    # Anti-drift.  The two cases above are evidence about
    # ``just demo-request-panel-live`` only if the recipe walks the sequence in
    # ``LiveStages`` — in particular the ``--open-only`` step, which is what
    # makes the in-flight row observable at all and which is easy to drop while
    # editing the shell loop.  So the recipe's own stage list is parsed out of
    # the justfile and compared.  If this fails, the fix is to bring the two
    # back into step, not to relax the check.
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
      .parentDir.parentDir.parentDir
    let justfilePath = repoRoot / "justfile"
    check fileExists(justfilePath)
    let justfileText = readFile(justfilePath)

    # The seed stage is produced before the loop.
    check LiveStages[0] == (through: 1, openOnly: false)
    check "\"$work/demo_request_session\" \"$demo_dir\" --through=1" in
      justfileText

    # ... and the rest come out of the recipe's `stages=( ... )` array.
    let arrayStart = justfileText.find("stages=(")
    check arrayStart >= 0
    let arrayEnd = justfileText.find(")", arrayStart)
    check arrayEnd > arrayStart
    var recipeStages: seq[string] = @[]
    for line in justfileText[arrayStart ..< arrayEnd].splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("\"") and trimmed.endsWith("\""):
        recipeStages.add(trimmed[1 ..< trimmed.high])

    var expectedStages: seq[string] = @[]
    for i in 1 ..< LiveStages.len:
      expectedStages.add("--through=" & $LiveStages[i].through &
        (if LiveStages[i].openOnly: " --open-only" else: ""))
    check recipeStages == expectedStages
