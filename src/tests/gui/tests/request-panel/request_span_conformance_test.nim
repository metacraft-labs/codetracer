## request_span_conformance_test.nim
##
## RS-M12 — ``request_span_conformance_all_languages``.
##
## (The milestone's other required test,
## ``no_recorder_writes_sidecar_manifests``, lives in the sibling
## ``no_sidecar_manifests_test.nim``: it drives a real recording per language
## and therefore needs the recorder siblings, which this file deliberately
## does not.)
##
## The closing milestone of the Request-Panel campaign, per
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M12.  RS-M5..RS-M10 each added ONE language row of the matrix with its
## own ViewModel test over its own recorded fixture.  Each of those tests knows
## its language's session by heart — the exact URLs, the exact routes, the
## exact handler lines — which is what makes them good regression tests and
## also what makes them blind to the thing this file exists for: a metadata
## key that ONE recorder quietly stopped emitting, or started emitting in a
## different unit, or a span stream that stopped pairing its open and settled
## records.  Nothing forced the six to agree, so nothing failed when they
## drifted.
##
## This file is the agreement.  It runs the SAME assertion set over all six
## recorded fixtures and reports every violation it finds, grouped per
## language and naming the field, so one run tells you which recorder broke
## and which key it broke on.
##
## ## Why it lives here
##
## The suite has to read six containers produced by six different repos.
## ``codetracer`` is the only repo that holds all six — they are checked in
## under ``fixtures/`` precisely so the ViewModel lane needs no Python, Ruby,
## PHP, Erlang, Node or nginx toolchain — and it is the repo whose release
## gate (``src/ct_test/release_gate.nim``'s ``CoreViewModelGateTests``)
## already runs the six per-language tests.  Putting the conformance suite
## anywhere else would mean either vendoring five foreign fixtures into a
## seventh repo or splitting the assertion set across six runners, which is
## the situation this milestone is closing.
##
## ## What is REQUIRED of every recorder, and what may VARY
##
## The recorders do not behave identically, and lowering the assertions to
## their intersection would make this suite worthless.  Instead every
## difference is declared, per language, in ``request_span_languages.nim``'s
## ``LanguageRows``, and the suite asserts *against the declaration*.  So:
##
## * a recorder that stops emitting a key it declares fails;
## * a recorder that starts emitting a key it declares it does not fails;
## * a recorder that changes how many of its rows are contiguous fails;
## * a recorder whose seek fidelity improves ALSO fails, with a diagnostic
##   telling you to raise its declaration — an unannounced improvement is
##   still an unannounced change.
##
## The universal contract (no waiver possible, asserted for every language):
##
## * ``meta.dat`` bit 13 is set and the span-stream files exist;
## * the production reader decodes the stream, and ``spantype.ns`` names
##   ``web-request`` with exactly the settled span ids;
## * every settled record is a ``web-request``, not open, not external, flat
##   (``parent_span_id == 0``) and shares the container's timeline;
## * ``span_id``s are unique, positive and strictly increasing, and the rows
##   are ordered — non-decreasing ``start_wall_ns``;
## * the four keys ``CTFS-Request-Span-Streams.md`` § "Well-known metadata
##   keys" marks REQUIRED are *present* (not merely defaulting to the empty
##   string): ``http.method``, ``http.url``, ``http.status_code``,
##   ``http.duration_ms``;
## * ``http.method`` is a real method token, ``http.url`` is a path,
##   ``http.status_code`` is in 100..599, and the record's ``status`` enum
##   agrees with it (``error`` iff >= 400, never ``unknown`` once settled);
## * ``http.duration_ms`` is a non-negative integer AND is bounded by the
##   span's own wall clock — a recorder that reported microseconds as
##   milliseconds would fail here even though every other check passed;
## * ``start_wall_ns`` is a real UNIX epoch (post-2017) and ``end_wall_ns``
##   is not before it;
## * ``label`` is exactly ``"<METHOD> <url>"``;
## * the step range is a real, ordered, per-row-distinct coordinate of THIS
##   container, and the binding is inline (no external recording named);
## * last-record-wins holds: grouping the raw stream by ``span_id`` and
##   taking the last record per id reproduces ``settledSpans()`` exactly;
## * the rows render through the real store, the real ``RequestPanelVM`` and
##   the real IsoNim view, and double-clicking a row seeks to that row's own
##   ``start_step``.
##
## Declared per language (see ``LanguageRows`` for the value and the reason):
##
## * ``publishesOpenRecords`` — a live middleware publishes an open record on
##   arrival and settles it later, so the raw stream is twice the row count.
##   A post-pass discoverer (native/nginx) has no in-flight moment and emits
##   one settled record per row.  Both are valid streams.
## * ``emitsRoute`` / ``emitsRemoteAddr`` / ``responseSizeAlwaysPresent`` /
##   ``errorMessageRows`` — the spec marks these OPTIONAL, and the six differ.
## * ``requiredExtraKeys`` / ``forbiddenKeys`` — ``discovery.mode`` exists
##   only on discovered spans and must exist on ALL of them; ``beam.pid`` and
##   ``beam.thread_id`` exist only on the BEAM row.
## * ``contiguousRows`` / ``concurrentRows`` — the exact number of rows whose
##   structural bits are set.  These are MEASURED by the recorders that can
##   measure them (BEAM, JS, native), so they are real properties of the
##   session and are pinned as counts rather than waived.
## * ``slowRowFloorMs`` — the floor the slowest row's duration must clear.
##   Zero for native, where ``meta.dat`` reports ``tickSource: none`` and the
##   wall times come from nginx's own one-second-resolution ``time(2)``
##   readings, so a sub-second request truthfully has duration 0.  Fabricating
##   a number the recording does not contain would be worse than reporting 0.
## * ``fidelity`` — how far a row's ``start_step`` resolves.  Four recorders
##   land in the recorded application's source; the BEAM row lands on a real
##   ordered coordinate that is not a line of ``.ex`` (the Erlang
##   instrumenter only instruments ``.erl``, so an Elixir app reaches the
##   container as call/return records and the span's range is made of the
##   thread events bracketing it); the native row has no step stream at all.
##
## ## Mocking justification (workspace policy on mock objects)
##
## The only mock is ``MockBackendService``, used purely as the transport that
## carries an already-decoded delta into the store — exactly as in the six
## per-language tests.  There is no fake container, no fake reader and no fake
## span data anywhere: the bytes are six real recordings and are decoded by
## the production readers.
##
## Native-only: it reads real container bytes through a zstd FFI, which does
## not exist on the ``nim js`` backend, so ``just test-vm-js`` excludes this
## file and ``src/ct_test/release_gate.nim`` registers it in
## ``CoreViewModelGateTests``.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/request_span_conformance_test.nim

import std/[json, options, os, sequtils, strutils, tables, unittest]
import request_span_languages
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
# Local constants
#
# The capability declaration itself lives in `request_span_languages.nim`, so
# `no_sidecar_manifests_test.nim` reads the SAME matrix.  Only the thresholds
# this suite applies live here.
# ---------------------------------------------------------------------------

const
  KnownMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

  RealEpochFloorNs = 1_500_000_000_000_000_000'u64
    ## 2017-07-14 in UNIX epoch nanoseconds.  A tick counter dressed up as a
    ## timestamp does not clear this.

  DurationSlackMs = 2
    ## ``http.duration_ms`` may exceed the span's own integer-millisecond wall
    ## delta only by rounding: a recorder that rounds 3356.6 ms to 3357
    ## overshoots the floor by 1.  Two milliseconds absorbs that on both
    ## sides; a unit error (microseconds reported as milliseconds) is three
    ## orders of magnitude out and still fails.

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

type
  Diagnostics = ref object
    ## Per-language failure collector.  The suite never stops at the first
    ## problem: it runs every check over every fixture and reports the whole
    ## set, because "the Ruby recorder dropped http.route" and "the JS
    ## recorder changed its duration unit" are two different bugs and finding
    ## them one release apart is the failure mode this milestone closes.
    lang: string
    items: seq[string]

proc note(d: Diagnostics; ctx, msg: string) =
  d.items.add("[" & d.lang & "] " & ctx & ": " & msg)

proc want(d: Diagnostics; ctx: string; ok: bool; msg: string) =
  if not ok: d.note(ctx, msg)

proc wantEq[T](d: Diagnostics; ctx, field: string; got, expected: T) =
  if got != expected:
    d.note(ctx, field & " is " & $got & ", expected " & $expected)

# ---------------------------------------------------------------------------
# Container helpers (same shapes the six per-language tests use)
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

proc hasMeta(span: SpanRecord; key: string): bool =
  for (k, _) in span.metadata:
    if k == key:
      return true
  false

proc metaValue(span: SpanRecord; key: string): string =
  for (k, v) in span.metadata:
    if k == key:
      return v
  ""

proc numericMeta(span: SpanRecord; key: string): int =
  ## The db-backend's ``parse_numeric_metadata``: an absent or unparseable
  ## value is 0, never an error.  Presence and shape are checked separately,
  ## which is the point — a key that vanished must not be indistinguishable
  ## from a key whose value is "0".
  try:
    parseInt(metaValue(span, key))
  except ValueError:
    0

proc isDecimal(s: string): bool =
  s.len > 0 and s.allIt(it in {'0' .. '9'})

proc statusName(s: SpanStatus): string =
  case s
  of spanStatusUnknown: "unknown"
  of spanStatusOk: "ok"
  of spanStatusError: "error"

proc toWireRecord(span: SpanRecord): JsonNode =
  ## Project a decoded span to the wire ``RequestRecord``, mirroring
  ## ``src/db-backend/src/request_spans.rs::to_request_record`` field for
  ## field (camelCase keys, ``start_step`` -> ``startGeid``, nullable
  ## ``externalTracePath``).  All six recorders bind inline, so the
  ## external-binding branch is unreachable from here — which the suite
  ## asserts rather than assumes.
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
  ## The global-line index a COLUMN-UNAWARE trace was written against: the
  ## writer allocates ``DefaultLinesPerFile`` lines per file, so the index is
  ## ``file_base + line``.  This is what ``ct print`` reconstructs
  ## (``buildGliFromMeta`` in ``codetracer_ct_print_lib``) from the writer's
  ## own constant, so the suite resolves such steps the way the shipped CLI
  ## does.
  var counts = newSeq[uint64](max(pathCount, 1))
  for i in 0 ..< counts.len:
    counts[i] = DefaultLinesPerFile
  buildGlobalLineIndex(counts)

# ---------------------------------------------------------------------------
# The shared assertion set
# ---------------------------------------------------------------------------

proc checkStream(d: Diagnostics; lang: LanguageRow; bytes: seq[byte];
                 settled: var seq[SpanRecord]) =
  ## Everything that can be read off the container: the meta flags, the raw
  ## record stream, the last-record-wins pairing and the span-type namespace.
  let metaRaw = readInternalFile(bytes, "meta.dat")
  if metaRaw.isErr:
    d.note("meta.dat", "unreadable: " & metaRaw.error)
    return
  let metaRes = readMetaDat(metaRaw.get())
  if metaRes.isErr:
    d.note("meta.dat", "undecodable: " & metaRes.error)
    return
  let meta = metaRes.get()

  # A container whose bit 13 is clear makes the db-backend's span reader
  # answer "no spans", so a recorder that forgot to register would show an
  # empty panel and no error anywhere.
  d.want("meta.dat", meta.hasSpanStream,
    "FlagHasSpanStream (bit 13) is not set")
  d.want("meta.dat", hasSpanStreamFiles(bytes),
    "spans.dat / spans.idx are missing from the container")

  # The step stream is the difference between "the seek lands in source" and
  # "the seek lands at a coordinate", so it is declared, not discovered.
  d.wantEq("meta.dat", "hasStepStream", meta.hasStepStream,
    lang.fidelity != sfNoStepStream)

  let readerRes = initSpanStreamReader(bytes)
  if readerRes.isErr:
    d.note("spans.dat", "initSpanStreamReader failed: " & readerRes.error)
    return
  let reader = readerRes.get()

  let allRes = reader.readAllSpanRecords()
  if allRes.isErr:
    d.note("spans.dat", "readAllSpanRecords failed: " & allRes.error)
    return
  let allRecords = allRes.get()

  let settledRes = reader.settledSpans()
  if settledRes.isErr:
    d.note("spans.dat", "settledSpans failed: " & settledRes.error)
    return
  settled = webRequests(settledRes.get())

  d.wantEq("spans.dat", "settled web-request count", settled.len, lang.rows)
  d.wantEq("spans.dat", "settled span count (no other span types expected)",
    settledRes.get().len, settled.len)

  # --- open / settled pairing under last-record-wins --------------------
  #
  # A live middleware publishes an open record on arrival and settles it
  # later, so the raw stream is twice the row count; a post-pass emits one
  # settled record per row.  Whichever it is, the LAST record per span_id
  # must be the settled one and must be what `settledSpans()` returns —
  # that is the whole reader contract, and it is the one property a
  # recorder can break without any single record looking wrong.
  let expectedRaw = lang.rows * (if lang.publishesOpenRecords: 2 else: 1)
  d.wantEq("spans.dat", "raw record count", allRecords.len, expectedRaw)

  var order: seq[uint64] = @[]
  var byId = initTable[uint64, seq[SpanRecord]]()
  for rec in allRecords:
    if rec.spanId notin byId:
      byId[rec.spanId] = @[]
      order.add(rec.spanId)
    byId[rec.spanId].add(rec)

  d.wantEq("spans.dat", "distinct span_ids in the raw stream",
    order.len, lang.rows)
  for id in order:
    let group = byId[id]
    let ctx = "span_id " & $id
    d.wantEq(ctx, "records per span_id", group.len,
      if lang.publishesOpenRecords: 2 else: 1)
    if group.len == 0: continue
    d.want(ctx, not group[^1].isOpen,
      "the LAST record is still open, so last-record-wins yields an " &
      "in-flight row for a finished request")
    if lang.publishesOpenRecords and group.len >= 2:
      for k in 0 ..< group.len - 1:
        d.want(ctx, group[k].isOpen,
          "record " & $k & " of " & $group.len &
          " is settled but is not the last one")
  # The resolved view must be exactly the per-id last records, in order.
  let resolved = resolveSpans(allRecords)
  d.wantEq("spans.dat", "resolveSpans() row count", resolved.len, order.len)
  if resolved.len == settledRes.get().len:
    for i in 0 ..< resolved.len:
      d.wantEq("resolved row " & $i, "span_id",
        resolved[i].spanId, settledRes.get()[i].spanId)
      d.wantEq("resolved row " & $i, "label",
        resolved[i].label, settledRes.get()[i].label)
      d.wantEq("resolved row " & $i, "metadata",
        resolved[i].metadata, settledRes.get()[i].metadata)

  # --- spantype.ns ------------------------------------------------------
  # It lets a reader list the requests without decompressing a single span
  # record, so it has to name the type and hold exactly the settled ids.
  let nsRes = readSpanTypeNamespace(bytes)
  if nsRes.isErr:
    d.note("spantype.ns", "unreadable: " & nsRes.error)
  else:
    var seen = false
    for entry in nsRes.get():
      if entry.name == "web-request":
        seen = true
        var distinctIds: seq[uint64] = @[]
        for id in entry.spanIds:
          if id notin distinctIds: distinctIds.add(id)
        d.wantEq("spantype.ns", "distinct web-request ids",
          distinctIds.len, lang.rows)
        for s in settled:
          d.want("spantype.ns", s.spanId in distinctIds,
            "settled span_id " & $s.spanId & " is not listed")
    d.want("spantype.ns", seen, "no 'web-request' entry")

proc checkSpan(d: Diagnostics; lang: LanguageRow; i: int;
               span: SpanRecord; prev: Option[SpanRecord]) =
  ## The universal per-row contract.
  let ctx = "row " & $i & " (" & span.label & ")"

  # --- identity and shape ----------------------------------------------
  d.wantEq(ctx, "span_type", span.spanType, "web-request")
  d.want(ctx, span.spanId > 0'u64, "span_id is 0")
  d.want(ctx, not span.isOpen, "settled view still reports isOpen")
  d.wantEq(ctx, "parent_span_id", span.parentSpanId, 0'u64)
  d.want(ctx, span.sharesTimeline,
    "shares_timeline is clear: the span claims not to be a slice of this " &
    "container's timeline")

  # --- the binding is resolvable ---------------------------------------
  # Every recorder in the matrix binds inline; an external binding names a
  # DIFFERENT container, which nothing here (or in the panel) would follow.
  d.want(ctx, not span.isExternal,
    "is_external is set: the span names another container")
  d.want(ctx, span.externalRecording.len == 0,
    "external_recording is set on an inline span: '" &
      span.externalRecording & "'")
  d.want(ctx, span.externalPath.len == 0,
    "external_path is set on an inline span: '" & span.externalPath & "'")

  # --- required metadata keys ------------------------------------------
  for key in RequiredMetadataKeys:
    d.want(ctx, span.hasMeta(key),
      "required metadata key '" & key & "' is MISSING")

  let httpMethod = span.metaValue("http.method")
  let url = span.metaValue("http.url")
  d.want(ctx, httpMethod in KnownMethods,
    "http.method is '" & httpMethod & "', not an HTTP method token")
  d.want(ctx, url.startsWith("/"),
    "http.url is '" & url & "', which is not a path")
  d.wantEq(ctx, "label", span.label, httpMethod & " " & url)

  # --- status is well formed and agrees with the record ----------------
  let statusRaw = span.metaValue("http.status_code")
  if not isDecimal(statusRaw):
    d.note(ctx, "http.status_code is '" & statusRaw & "', not a decimal")
  else:
    let code = numericMeta(span, "http.status_code")
    d.want(ctx, code >= 100 and code <= 599,
      "http.status_code " & $code & " is outside 100..599")
    let wantStatus = if code >= 400: "error" else: "ok"
    d.wantEq(ctx, "status enum vs http.status_code " & $code,
      statusName(span.status), wantStatus)

  # --- duration is well formed and bounded by the span's own clock -----
  let durationRaw = span.metaValue("http.duration_ms")
  if not isDecimal(durationRaw):
    d.note(ctx, "http.duration_ms is '" & durationRaw & "', not a decimal")
  else:
    let durationMs = numericMeta(span, "http.duration_ms")
    d.want(ctx, durationMs >= 0, "http.duration_ms is negative")
    if span.endWallNs >= span.startWallNs:
      let wallMs = int((span.endWallNs - span.startWallNs) div 1_000_000'u64)
      d.want(ctx, durationMs <= wallMs + DurationSlackMs,
        "http.duration_ms " & $durationMs & " exceeds the span's own wall " &
        "delta of " & $wallMs & " ms (slack " & $DurationSlackMs & ") — a " &
        "unit or clock-source error")

  # --- the wall clock is a real clock ----------------------------------
  d.want(ctx, span.startWallNs > RealEpochFloorNs,
    "start_wall_ns " & $span.startWallNs & " is not a post-2017 UNIX epoch " &
    "— it looks like a tick counter")
  d.want(ctx, span.endWallNs >= span.startWallNs,
    "end_wall_ns " & $span.endWallNs & " precedes start_wall_ns " &
      $span.startWallNs)

  # --- the step range is a real, ordered coordinate --------------------
  d.want(ctx, span.startStep > 0'u64, "start_step is 0")
  d.want(ctx, span.endStep >= span.startStep,
    "end_step " & $span.endStep & " precedes start_step " & $span.startStep)

  # --- ordering across rows --------------------------------------------
  if prev.isSome:
    d.want(ctx, span.spanId > prev.get().spanId,
      "span_id " & $span.spanId & " does not follow the previous row's " &
        $prev.get().spanId)
    d.want(ctx, span.startWallNs >= prev.get().startWallNs,
      "start_wall_ns goes backwards against the previous row")

  # --- the declared, per-recorder differences --------------------------
  d.wantEq(ctx, "framework", span.metaValue("framework"), lang.framework)

  if lang.emitsRoute:
    d.want(ctx, span.hasMeta("http.route"),
      "http.route is MISSING although this recorder declares it (" &
        lang.routeNote & ")")
  else:
    d.want(ctx, not span.hasMeta("http.route"),
      "http.route is present although this recorder declares it emits none " &
      "(" & lang.routeNote & ") — raise the declaration if that is intended")

  if lang.responseSizeAlwaysPresent:
    d.want(ctx, span.hasMeta("http.response_size"),
      "http.response_size is MISSING although this recorder declares it on " &
      "every row (" & lang.responseSizeNote & ")")
  if span.hasMeta("http.response_size"):
    d.want(ctx, isDecimal(span.metaValue("http.response_size")),
      "http.response_size is '" & span.metaValue("http.response_size") &
        "', not a decimal")

  d.wantEq(ctx, "http.remote_addr present",
    span.hasMeta("http.remote_addr"), lang.emitsRemoteAddr)

  for key in lang.requiredExtraKeys:
    d.want(ctx, span.hasMeta(key),
      "recorder-specific key '" & key & "' is MISSING")
  for key in lang.forbiddenKeys:
    d.want(ctx, not span.hasMeta(key),
      "key '" & key & "' must not appear on this recorder's spans")

  # An error message is a claim that the APPLICATION failed, so it may only
  # accompany a 5xx.  A 404 is an error status with no message, which is why
  # the two are checked independently.
  if span.hasMeta("error.message"):
    d.want(ctx, span.metaValue("error.message").len > 0,
      "error.message is present but empty")
    d.want(ctx, numericMeta(span, "http.status_code") >= 500,
      "error.message on a non-5xx row")

proc checkFixtureAggregates(d: Diagnostics; lang: LanguageRow;
                            settled: seq[SpanRecord]) =
  ## Properties of the whole session rather than of one row.
  var ids: seq[uint64] = @[]
  var seeks: seq[uint64] = @[]
  var contiguous = 0
  var concurrent = 0
  var errorMessages = 0
  var maxDuration = 0
  var anyResponseBody = false
  var buckets: seq[string] = @[]

  for span in settled:
    if span.spanId in ids:
      d.note("session", "duplicate span_id " & $span.spanId)
    ids.add(span.spanId)
    if span.startStep in seeks:
      d.note("session",
        "two rows share the seek target " & $span.startStep &
        " — double-clicking them lands in the same place")
    seeks.add(span.startStep)
    if span.contiguousOnOneThread: contiguous += 1
    if span.concurrentWithSiblings: concurrent += 1
    if span.hasMeta("error.message"): errorMessages += 1
    maxDuration = max(maxDuration, numericMeta(span, "http.duration_ms"))
    if numericMeta(span, "http.response_size") > 0: anyResponseBody = true
    let bucket = statusBucket(numericMeta(span, "http.status_code"))
    if bucket notin buckets: buckets.add(bucket)

  d.wantEq("session", "contiguous_on_one_thread rows (" &
    lang.structuralNote & ")", contiguous, lang.contiguousRows)
  d.wantEq("session", "concurrent_with_siblings rows (" &
    lang.structuralNote & ")", concurrent, lang.concurrentRows)
  d.wantEq("session", "rows carrying error.message (" &
    lang.errorMessageNote & ")", errorMessages, lang.errorMessageRows)
  d.want("session", maxDuration >= lang.slowRowFloorMs,
    "the slowest row reports " & $maxDuration & " ms, below the declared " &
    "floor of " & $lang.slowRowFloorMs & " ms (" & lang.durationNote & ")")
  d.want("session", anyResponseBody,
    "no row reports a non-zero http.response_size, so the response capture " &
    "produced nothing at all")
  # A fixture whose rows are all one colour cannot exercise the panel's
  # status colouring, so it would silently stop testing it.
  d.want("session", buckets.len >= 2,
    "every row falls in the same status bucket (" & buckets.join(", ") &
    "), so this fixture no longer exercises the panel's colouring")

proc checkBindingsResolvable(d: Diagnostics; lang: LanguageRow;
                             containerPath: string; pathCount: int;
                             settled: seq[SpanRecord]) =
  ## "Bindings resolvable": what a double-click actually reaches.
  if lang.fidelity == sfNoStepStream:
    # Nothing to resolve — asserted positively by `hasStepStream` in
    # `checkStream`.  The ordered-coordinate property is checked in
    # `checkFixtureAggregates` (distinct seek targets) and `checkSpan`.
    return

  var traceRes = openNewTrace(containerPath)
  if traceRes.isErr:
    d.note("bindings", "openNewTrace failed: " & traceRes.error)
    return
  var trace = traceRes.get()
  let lineGli = lineOnlyGli(pathCount)

  for i, span in settled:
    let ctx = "row " & $i & " (" & span.label & ")"
    for (which, step) in [("start_step", span.startStep),
                          ("end_step", span.endStep)]:
      let gliRes = trace.stepAbsoluteGlobalLineIndex(step)
      if gliRes.isErr:
        d.note(ctx, which & " " & $step &
          " does not resolve to a global line index: " & gliRes.error)
        continue
      let gli = gliRes.get()
      case lang.fidelity
      of sfHandlerColumnAware:
        let loc = trace.decodeGlobalPositionIndex(gli)
        if loc.isErr:
          d.note(ctx, which & ": decodeGlobalPositionIndex failed (" &
            loc.error & ") although this recorder declares a column-aware " &
            "trace — " & lang.fidelityNote)
          continue
        let file = trace.path(loc.get().file)
        if file.isErr:
          d.note(ctx, which & ": path(" & $loc.get().file & ") failed: " &
            file.error)
          continue
        d.want(ctx, file.get().replace('\\', '/')
                        .endsWith(lang.handlerSourceSuffix),
          which & " resolves to " & file.get() & ", not the recorded " &
            "application " & lang.handlerSourceSuffix)
        d.want(ctx, loc.get().line > 0'u32,
          which & " resolves to line 0")
      of sfHandlerLineOnly:
        # `decodeGlobalPositionIndex` must REFUSE a column-unaware container;
        # if it starts succeeding the recorder gained column awareness and
        # the declaration is stale.
        let loc = trace.decodeGlobalPositionIndex(gli)
        d.want(ctx, loc.isErr,
          which & ": the container is now column-aware, but this recorder " &
          "is declared sfHandlerLineOnly — raise its declaration")
        let (fileId, line) = lineGli.resolve(gli)
        let file = trace.path(uint64(fileId))
        if file.isErr:
          d.note(ctx, which & ": path(" & $fileId & ") failed: " & file.error)
          continue
        d.want(ctx, file.get().replace('\\', '/')
                        .endsWith(lang.handlerSourceSuffix),
          which & " resolves to " & file.get() & ", not the recorded " &
            "application " & lang.handlerSourceSuffix)
        d.want(ctx, line > 0,
          which & " resolves to line 0")
      of sfOrderedCoordinateOnly:
        # The step exists and orders, but carries no application position.
        # Asserted as the NEGATIVE it is, so that a recorder which starts
        # instrumenting its own sources fails here and forces the
        # declaration (and this row of the language matrix) to be raised
        # rather than silently improving unnoticed.
        d.want(ctx, gli <= 1'u64,
          which & " now carries a real global position (" & $gli & "). " &
          "This recorder is declared sfOrderedCoordinateOnly because " &
          lang.fidelityNote & " — if source resolution now works, raise " &
          "its declaration to a handler fidelity and add the source " &
          "assertions.")
      of sfNoStepStream:
        discard

proc checkViewModel(d: Diagnostics; lang: LanguageRow;
                    settled: seq[SpanRecord]) =
  ## The same rows through the real store, the real ViewModel and the real
  ## IsoNim view — including the double-click that seeks.
  createRoot proc(dispose: proc()) =
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    let vm = createRequestPanelVM(store)
    let r = MockRenderer()
    let panel = renderRequestPanel(r, vm)
    let tableBody = findByClass(panel, "request-table-body")
    if tableBody == nil:
      d.note("view", "the panel rendered no request-table-body")
      dispose()
      return
    d.wantEq("view", "rows before any delta", tableBody.children.len, 0)

    var wire: seq[JsonNode] = @[]
    for span in settled:
      wire.add(toWireRecord(span))
    store.applyRequestSpanDelta(
      deltaBody(wire, cursor = settled.len, reset = true))

    d.wantEq("view", "ViewModel row count", vm.requests.val.len, settled.len)
    d.wantEq("view", "rendered row count", tableBody.children.len, settled.len)
    d.wantEq("view", "delta source", store.requestSpans.source.val,
      "span-stream")

    if vm.requests.val.len == settled.len and
        tableBody.children.len == settled.len:
      for i in 0 ..< settled.len:
        let span = settled[i]
        let row = vm.requests.val[i]
        let ctx = "view row " & $i & " (" & span.label & ")"
        let code = numericMeta(span, "http.status_code")
        d.wantEq(ctx, "id", row.id, int64(span.spanId))
        d.wantEq(ctx, "httpMethod", row.httpMethod,
          span.metaValue("http.method"))
        d.wantEq(ctx, "url", row.url, span.metaValue("http.url"))
        d.wantEq(ctx, "statusCode", row.statusCode, code)
        d.wantEq(ctx, "startGeid", row.startGeid, int64(span.startStep))
        d.want(ctx, not row.isOpen, "the row renders as in-flight")
        d.want(ctx, row.durationMs >= 0, "durationMs is negative")
        d.want(ctx, row.responseSize >= 0, "responseSize is negative")
        d.want(ctx, durationText(row).len > 0, "durationText is empty")
        d.want(ctx, formatSize(row.responseSize).len > 0,
          "formatSize is empty")
        d.wantEq(ctx, "statusText", statusText(row), $code)
        let bucket = statusBucket(code)
        d.wantEq(ctx, "statusCellClass", statusCellClass(row),
          "request-status-" & bucket)
        let rowNode = tableBody.children[i]
        d.wantEq(ctx, "rendered row class",
          rowNode.attributes.getOrDefault("class", ""), "request-row")
        let statusCell = findByClass(rowNode, "request-col-status")
        if statusCell == nil:
          d.note(ctx, "no request-col-status cell rendered")
        else:
          d.want(ctx,
            findByClass(statusCell, "request-status-" & bucket) != nil,
            "the status cell is not coloured '" & bucket & "'")
        d.wantEq(ctx, "rendered url",
          textContent(findByClass(rowNode, "request-col-url")),
          span.metaValue("http.url"))

      # Activating a row seeks to THAT row's coordinate.  Driven through the
      # rendered row's own `ondblclick`, so the wiring is covered too.
      for i in 0 ..< settled.len:
        let span = settled[i]
        let ctx = "dblclick row " & $i & " (" & span.label & ")"
        mock.clearReceivedCommands()
        fireEvent(tableBody.children[i], "dblclick")
        drain()
        let sent = mock.findCommand("ct/seek-to-geid")
        if sent.isNone:
          d.note(ctx, "no ct/seek-to-geid command was sent")
          continue
        d.wantEq(ctx, "seek geid", sent.get.args["geid"].getInt,
          int(span.startStep))
        d.wantEq(ctx, "seek url", sent.get.args["url"].getStr,
          span.metaValue("http.url"))

    dispose()

# ---------------------------------------------------------------------------
# request_span_conformance_all_languages
# ---------------------------------------------------------------------------

suite "RS-M12 cross-language request-span conformance":

  test "request_span_conformance_all_languages":
    let fixturesRoot = currentSourcePath.parentDir / "fixtures"
    var failures: seq[string] = @[]
    var checkedLanguages = 0

    for lang in LanguageRows:
      checkpoint("conformance: " & lang.id)
      let d = Diagnostics(lang: lang.id, items: @[])
      let containerPath =
        fixturesRoot / lang.fixtureDir / lang.containerFile

      # --- the declaration itself has to be coherent ----------------------
      # A handler fidelity with no `handlerSourceSuffix` would make the
      # "resolves into the recorded application" check vacuous: every path
      # ends with the empty string.  Assert it here so the declaration cannot
      # be weakened by omission.
      case lang.fidelity
      of sfHandlerColumnAware, sfHandlerLineOnly:
        d.want("declaration", lang.handlerSourceSuffix.len > 0,
          "fidelity is " & $lang.fidelity & " but handlerSourceSuffix is " &
          "empty, which would make the source-resolution check vacuous")
      of sfOrderedCoordinateOnly, sfNoStepStream:
        d.want("declaration", lang.handlerSourceSuffix.len == 0,
          "fidelity is " & $lang.fidelity & " but handlerSourceSuffix is '" &
          lang.handlerSourceSuffix & "' — this recorder resolves no source")
      d.want("declaration", lang.fidelityNote.len > 0,
        "every fidelity below sfHandlerColumnAware must carry the reason it " &
        "is legitimate")

      if not fileExists(containerPath):
        d.note("fixture", "missing container " & containerPath &
          " — regenerate it with `direnv exec ../" & lang.recorderRepo &
          " just record-request-panel-fixture`")
        failures.add(d.items)
        continue

      # No recorder may leave a sidecar next to the container it recorded.
      for stray in sidecarsUnder(fixturesRoot / lang.fixtureDir):
        d.note("fixture", "a sidecar manifest sits beside the container: " &
          stray)

      let bytes = containerBytes(containerPath)
      var settled: seq[SpanRecord] = @[]
      checkStream(d, lang, bytes, settled)

      if settled.len > 0:
        var pathCount = 0
        let metaRaw = readInternalFile(bytes, "meta.dat")
        if metaRaw.isOk:
          let metaRes = readMetaDat(metaRaw.get())
          if metaRes.isOk:
            pathCount = metaRes.get().paths.len

        for i, span in settled:
          let prev =
            if i == 0: none(SpanRecord) else: some(settled[i - 1])
          checkSpan(d, lang, i, span, prev)
        checkFixtureAggregates(d, lang, settled)
        checkBindingsResolvable(d, lang, containerPath, pathCount, settled)
        checkViewModel(d, lang, settled)
        checkedLanguages += 1

      failures.add(d.items)

    # Every language must actually have been checked: an empty run that
    # reports no failures would be a green suite that asserts nothing.
    if checkedLanguages != LanguageRows.len:
      failures.add("[suite] only " & $checkedLanguages & " of " &
        $LanguageRows.len & " language fixtures produced any spans to check")

    if failures.len > 0:
      checkpoint("request-span conformance violations (" &
        $failures.len & "):\n  " & failures.join("\n  "))
      fail()
