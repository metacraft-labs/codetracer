## RS-M2 span-stream fixture generator.
##
## Writes the `.ct` containers the db-backend's span-stream tests read, using
## the **canonical Nim writer** — `codetracer_trace_writer/multi_stream_writer`
## driving `codetracer_trace_writer/span_stream` — so the committed fixtures are
## real production bytes, not something the Rust side round-tripped through
## itself.  That is the load-bearing property of these fixtures: the Rust reader
## in `src/db-backend/src/ctfs_trace_reader/span_stream.rs` is proved
## byte-compatible with the Nim writer by reading what the Nim writer wrote.
##
## It is the same cross-implementation pattern
## `codetracer-trace-format-nim/tests/gen_io_event_stream_crossread_fixture.nim`
## uses for `events.dat`, and the reason the fixtures are *committed* rather than
## generated at test time is that the db-backend test suite must not depend on a
## Nim toolchain or on a sibling repo checkout.  Run `./regenerate.sh` to rebuild
## them.
##
## ## Why the Nim writer and not a real server run
##
## RS-M2's `load_request_spans_from_recorded_container` asks for "a container
## recorded by a real server run".  No recorder emits `span_type: "web-request"`
## records yet — per-language emission is RS-M5…RS-M9 (Python, Ruby, PHP,
## Elixir, JS), all of which depend on RS-M4, which depends on this milestone.
## RS-M2 is deliberately the readers-first step of a readers-before-writers
## rollout (`CTFS-Request-Span-Streams.md` §"`meta.dat` feature bit"), so the
## most real writer that exists today is the canonical one this generator uses.
##
## ## Outputs
##
## | File                        | Contents                                        |
## | --------------------------- | ----------------------------------------------- |
## | `web_session.ct`            | 1 process span + 8 web-request spans, incl. an   |
## |                             | open/completion pair and an external binding.    |
## | `web_session.expected.jsonl`| Ground truth for each settled span, in span-id   |
## |                             | order, derived from the generator's INPUTS.      |
## | `web_session.manifest.jsonl`| The pre-cutover PHP `session_manifest.jsonl` the |
## |                             | SAME session would have written, for the shim.   |
## | `web_session_200.ct`        | 200 web-request spans, chunks sealed at          |
## |                             | irregular intervals so they are SHORT.           |
## | `web_session_200.expected.jsonl` | Ground truth for the 200-request container. |
## | `no_spans.ct`               | The same writer with no span registered — bit 13 |
## |                             | stays clear and the container is unchanged.      |
##
## The `.expected.jsonl` sidecars are written from the span values the generator
## fed the writer, NOT from re-reading the container, so a writer bug cannot make
## the expectations agree with themselves.
##
## Usage: `gen_span_fixtures <out-dir>`.

import std/[json, os, strutils]
import results
import codetracer_trace_writer/multi_stream_writer
import codetracer_trace_writer/span_stream

proc fail(msg: string) {.raises: [].} =
  try:
    stderr.writeLine("gen_span_fixtures: " & msg)
  except IOError, ValueError:
    discard
  quit(1)

proc statusName(s: SpanStatus): string {.raises: [].} =
  case s
  of spanStatusUnknown: "unknown"
  of spanStatusOk: "ok"
  of spanStatusError: "error"

proc expectedLine(s: SpanRecord): string {.raises: [].} =
  ## One ground-truth line describing a SETTLED span, as the Rust reader must
  ## decode it.  Emitted in the generator's own terms so the Rust assertions are
  ## against the recording's intent, not against a second decoder.
  var meta = newJObject()
  var order = newJArray()
  for (k, v) in s.metadata:
    meta[k] = %v
    order.add(%k)
  let obj = %*{
    "span_id": s.spanId,
    "parent_span_id": s.parentSpanId,
    "is_open": s.isOpen,
    "is_external": s.isExternal,
    "status": statusName(s.status),
    "start_wall_ns": s.startWallNs,
    "end_wall_ns": s.endWallNs,
    "process_ord": s.processOrd,
    "thread_id": s.threadId,
    "start_step": s.startStep,
    "end_step": s.endStep,
    "external_recording": s.externalRecording,
    "external_path": s.externalPath,
    "span_type": s.spanType,
    "label": s.label,
    "contiguous_on_one_thread": s.contiguousOnOneThread,
    "shares_timeline": s.sharesTimeline,
    "concurrent_with_siblings": s.concurrentWithSiblings,
    "metadata": meta,
    "metadata_order": order,
  }
  try:
    result = $obj
  except Exception:
    fail("failed to serialise expected line for span " & $s.spanId)

proc phpManifestLine(s: SpanRecord): string {.raises: [].} =
  ## The `session_manifest.jsonl` line the PHP recorder
  ## (`codetracer-php-recorder/src/web_bootstrap.php`) writes for this request,
  ## byte-shape for byte-shape: a `trace_dir`, a `span_type`, a `status` and a
  ## `metadata` object whose `http.*` values are all STRINGS.
  ##
  ## Generating it from the same span the container carries is what makes
  ## `legacy_jsonl_session_still_opens` meaningful: the two fixtures cannot
  ## drift into describing different sessions.
  let obj = %*{
    "trace_dir": (if s.externalPath.len > 0: s.externalPath
                  else: "requests/req-" & align($s.spanId, 4, '0')),
    "span_type": s.spanType,
    "timestamp": "2026-07-29T12:00:00Z",
    "status": statusName(s.status),
    "metadata": {
      "http.method": s.metadata[0][1],
      "http.url": s.metadata[1][1],
      "http.status_code": s.metadata[2][1],
      "http.duration_ms": s.metadata[3][1],
    },
  }
  try:
    result = $obj
  except Exception:
    fail("failed to serialise manifest line for span " & $s.spanId)

proc webRequestSpan(spanId: uint64, httpMethod, url: string,
    status, durationMs, responseSize: int, startStep, endStep: uint64): SpanRecord {.raises: [].} =
  ## A completed, inline-bound web-request span carrying the spec's well-known
  ## metadata keys.  The first four pairs are deliberately the four keys the
  ## legacy PHP sidecar carried, in that order, so `phpManifestLine` can project
  ## them positionally.  The order is otherwise NON-alphabetical on purpose:
  ## metadata order is part of the wire contract and a reader that rebuilt it
  ## from a map would be caught.
  SpanRecord(
    spanId: spanId,
    parentSpanId: 0,
    isOpen: false,
    isExternal: false,
    # The HTTP status code IS the span status: >= 400 is an error, per the
    # `status` mapping the PHP recorder already writes into its sidecar.
    status: if status >= 400: spanStatusError else: spanStatusOk,
    startWallNs: 1_764_000_000_000_000_000'u64 + spanId * 5_000_000'u64,
    endWallNs: 1_764_000_000_000_000_000'u64 + spanId * 5_000_000'u64 +
      uint64(durationMs) * 1_000_000'u64,
    processOrd: 0,
    threadId: 1,
    startStep: startStep,
    endStep: endStep,
    spanType: "web-request",
    label: httpMethod & " " & url,
    contiguousOnOneThread: true,
    sharesTimeline: true,
    concurrentWithSiblings: false,
    metadata: @[
      ("http.method", httpMethod),
      ("http.url", url),
      ("http.status_code", $status),
      ("http.duration_ms", $durationMs),
      ("http.response_size", $responseSize),
      ("http.remote_addr", "127.0.0.1"),
      ("framework", "php-fpm"),
    ])

proc writeLines(path: string, lines: seq[string]) {.raises: [].} =
  var blob = ""
  for line in lines:
    blob.add(line)
    blob.add("\n")
  try:
    writeFile(path, blob)
  except IOError:
    fail("failed to write " & path)

# ---------------------------------------------------------------------------
# Fixture A — a small, richly-shaped server session.
# ---------------------------------------------------------------------------

proc buildSessionSpans(): seq[SpanRecord] {.raises: [].} =
  ## The RAW record sequence, in append order — including the open record that a
  ## later completion supersedes.  `settled` below is what a reader must return.
  var spans: seq[SpanRecord] = @[]

  # (1) The process descriptor, as an RS-M1b `span_type: "process"` record.
  #     This replaced the dead `meta.json` process table; a reader must see it
  #     alongside the requests and NOT mistake it for one.
  spans.add(SpanRecord(
    spanId: 1,
    parentSpanId: 0,
    isOpen: false,
    isExternal: false,
    status: spanStatusOk,
    startWallNs: 1_764_000_000_000_000_000'u64,
    endWallNs: 1_764_000_000_900_000_000'u64,
    processOrd: 0,
    threadId: 1,
    startStep: 0,
    endStep: 100_000,
    spanType: "process",
    label: "/usr/bin/php-fpm",
    contiguousOnOneThread: false,
    sharesTimeline: true,
    concurrentWithSiblings: false,
    metadata: @[
      ("process.pid", "4242"),
      ("process.parent_pid", "1"),
      ("process.exe", "/usr/bin/php-fpm"),
      ("process.args", "php-fpm --nodaemonize"),
      ("process.has_execed", "false"),
    ]))

  # (2..8) Seven completed requests spanning every status class the panel
  #        buckets, several methods, and URLs with a shared substring so the
  #        URL filter has something to narrow.
  spans.add(webRequestSpan(2, "GET", "/api/users", 200, 12, 2148, 120, 480))
  spans.add(webRequestSpan(3, "POST", "/api/users", 201, 31, 96, 481, 1_040))
  spans.add(webRequestSpan(4, "GET", "/api/users/42", 200, 8, 512, 1_041, 1_260))
  spans.add(webRequestSpan(5, "GET", "/static/app.css", 304, 1, 0, 1_261, 1_290))
  spans.add(webRequestSpan(6, "DELETE", "/api/users/42", 404, 5, 48, 1_291, 1_400))
  spans.add(webRequestSpan(7, "PUT", "/api/orders/7", 500, 220, 76, 1_401, 2_600))
  spans.add(webRequestSpan(8, "GET", "/health", 200, 1, 2, 2_601, 2_620))

  # (9) An OPEN record followed by its completion — the append-only
  #     in-flight-then-settled pattern.  A reader that does not apply
  #     last-record-wins will show nine rows instead of eight, or show the
  #     request as still running.
  var open9 = webRequestSpan(9, "GET", "/api/reports/slow", 0, 0, 0, 2_621, 0)
  open9.isOpen = true
  open9.status = spanStatusUnknown
  open9.endWallNs = 0
  open9.endStep = 0
  spans.add(open9)

  # (10) An EXTERNAL binding — the span's execution lives in a different
  #      container.  This is what `session_manifest.jsonl`'s `trace_dir` did,
  #      and RS-M2 must resolve it to an openable container path.  An external
  #      span carries no step range in THIS container, so start/end step are 0.
  var external = webRequestSpan(10, "POST", "/api/orders", 502, 1200, 64, 0, 0)
  external.isExternal = true
  external.externalRecording = "01949fcc-7d92-7e9c-cccc-dddddddddddd"
  external.externalPath = "requests/req-0010.ct"
  external.metadata.add(("error.message", "upstream timeout"))
  spans.add(external)

  # (9, again) The completion of the open record.  Appended AFTER other spans
  #            so the pair is not adjacent — a reader may not rely on adjacency.
  spans.add(webRequestSpan(9, "GET", "/api/reports/slow", 200, 940, 8192,
    2_621, 5_400))

  spans

proc settledOf(raw: seq[SpanRecord]): seq[SpanRecord] {.raises: [].} =
  ## Last-record-wins per span id, ascending by span id — the generator's own
  ## statement of what a reader must produce.
  var maxId = 0'u64
  for s in raw:
    if s.spanId > maxId: maxId = s.spanId
  for id in 1'u64 .. maxId:
    var found = false
    var latest: SpanRecord
    for s in raw:
      if s.spanId == id:
        latest = s
        found = true
    if found:
      result.add(latest)

proc writeContainer(outPath, program, recordingId: string,
    spans: seq[SpanRecord], flushAfter: seq[int]) {.raises: [].} =
  ## Write `spans` (append order) into a fresh container, calling `flushSpans`
  ## after each 1-based record ordinal in `flushAfter`.
  ##
  ## The explicit flush points are the point of the fixture: they seal SHORT
  ## chunks in the middle of the stream, which is exactly the case CTFS §7's
  ## "chunk = N div chunk_size" addressing cannot describe and the `spans.idx`
  ## v2 cumulative column exists to handle.  A Rust reader that divided by
  ## `chunk_size` would return the wrong record for everything after the first
  ## short chunk.
  var wRes = initMultiStreamWriter(outPath, program, recordingId = recordingId)
  if wRes.isErr: fail("init writer: " & wRes.error)
  var w = wRes.get()

  # One recorded path + a couple of steps so the container is a plausible
  # recording rather than a bag of spans.
  let pRes = w.registerPath("/srv/app/index.php")
  if pRes.isErr: fail("registerPath: " & pRes.error)
  let pathId = pRes.get()
  for line in 1'u64 .. 8'u64:
    let r = w.registerStep(pathId, line, [])
    if r.isErr: fail("registerStep: " & r.error)

  for i, span in spans:
    let r = w.registerSpan(span)
    if r.isErr: fail("registerSpan " & $span.spanId & ": " & r.error)
    if (i + 1) in flushAfter:
      let f = w.flushSpans()
      if f.isErr: fail("flushSpans: " & f.error)

  let closeRes = w.close()
  if closeRes.isErr: fail("close: " & closeRes.error)
  let bytes = w.toBytes()
  w.closeCtfs()
  try:
    writeFile(outPath, bytes)
  except IOError:
    fail("failed to write " & outPath)

proc main() {.raises: [].} =
  let args = commandLineParams()
  if args.len < 1:
    fail("usage: gen_span_fixtures <out-dir>")
  let outDir = args[0]
  try:
    createDir(outDir)
  except OSError, IOError:
    fail("cannot create " & outDir)

  # --- Fixture A: web_session.ct -----------------------------------------
  let sessionSpans = buildSessionSpans()
  # Seal after records 3, 4 and 9 — three SHORT chunks (3, 1, 5 and 2 records)
  # against a `chunk_size` header of 64.
  writeContainer(outDir / "web_session.ct", "/srv/app/index.php",
    "01949fcc-7d92-7e9c-a001-000000000001", sessionSpans, @[3, 4, 9])

  let settled = settledOf(sessionSpans)
  var expectedLines: seq[string] = @[]
  var manifestLines: seq[string] = @[]
  for s in settled:
    expectedLines.add(expectedLine(s))
    # The PHP sidecar only ever described web requests, never processes.
    if s.spanType == "web-request":
      manifestLines.add(phpManifestLine(s))
  writeLines(outDir / "web_session.expected.jsonl", expectedLines)
  writeLines(outDir / "web_session.manifest.jsonl", manifestLines)

  # --- Fixture B: web_session_200.ct -------------------------------------
  const
    methods = ["GET", "POST", "PUT", "DELETE"]
    statuses = [200, 201, 204, 301, 404, 418, 500, 503]
    urls = ["/api/users", "/api/users/42", "/api/orders", "/api/orders/7",
            "/static/app.css", "/health", "/api/reports/monthly",
            "/admin/api/users"]
  var bigSpans: seq[SpanRecord] = @[]
  var flushPoints: seq[int] = @[]
  for i in 0 ..< 200:
    let id = uint64(i + 1)
    let httpMethod = methods[i mod methods.len]
    let url = urls[(i * 3) mod urls.len]
    let status = statuses[(i * 5) mod statuses.len]
    bigSpans.add(webRequestSpan(id, httpMethod, url, status,
      1 + (i * 7) mod 400, (i * 131) mod 65_536,
      uint64(i) * 50'u64 + 10'u64, uint64(i) * 50'u64 + 49'u64))
    # Irregular seal points (7, 11, 13-record runs) so almost no chunk holds
    # `chunk_size` records and no arithmetic relation between record index and
    # chunk index survives.
    if (i + 1) mod 7 == 0 or (i + 1) mod 11 == 0 or (i + 1) mod 13 == 0:
      flushPoints.add(i + 1)
  writeContainer(outDir / "web_session_200.ct", "/srv/app/index.php",
    "01949fcc-7d92-7e9c-a002-000000000002", bigSpans, flushPoints)

  var bigExpected: seq[string] = @[]
  for s in settledOf(bigSpans):
    bigExpected.add(expectedLine(s))
  writeLines(outDir / "web_session_200.expected.jsonl", bigExpected)

  # --- Fixture C: no_spans.ct --------------------------------------------
  # The SAME writer with no span registered.  `meta.dat` bit 13 stays clear and
  # the container carries no spans.dat / spans.idx / spantype.ns, which is the
  # "a span-free container is byte-identical to pre-RS-M1 output" guarantee the
  # spec's Design Goal 6 makes.
  writeContainer(outDir / "no_spans.ct", "/srv/app/index.php",
    "01949fcc-7d92-7e9c-a003-000000000003", @[], @[])

  echo "wrote span-stream fixtures to " & outDir

main()
