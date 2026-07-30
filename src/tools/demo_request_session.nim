## demo_request_session.nim
##
## RS-M4 — the container-production step behind ``just demo-request-panel``.
##
## ## What is real here and what is synthesised
##
## **The panel path is real.**  What this tool produces is a genuine ``.ct``
## container written by the CANONICAL Nim writer
## (``codetracer-trace-format-nim``'s ``multi_stream_writer`` driving
## ``span_stream``) — the same writer the recorders link, and the same writer
## that produced the committed fixtures in
## ``src/db-backend/tests/fixtures/span_stream/``.  ``meta.dat`` bit 13
## (``FlagHasSpanStream``) is set by the writer because spans were registered,
## not by hand.  Everything downstream of the container is production code:
## ``ct replay`` opens it, the db-backend's Rust span reader decodes
## ``spans.dat`` / ``spans.idx``, ``ct/load-request-spans-since`` tails it, and
## the Request Panel's ViewModel merges the deltas.
##
## **The spans themselves are synthesised.**  No language recorder emits
## ``span_type: "web-request"`` records yet — per-language emission is
## RS-M5…RS-M9 (Python, Ruby, PHP, Elixir, JS), every one of which depends on
## RS-M4.  So there is no real server run to record.  RS-M5+ replaces this
## producer with a live server under its language's recorder; the recipe, the
## GUI path and the guard test below stay exactly as they are, because the only
## thing that changes is who writes the span records.
##
## ## Output layout
##
## ``writeDemoRequestSession(dir, throughRequest)`` produces a trace folder
## ``ct replay -t <dir>`` can open:
##
## | File            | Role                                                    |
## | --------------- | ------------------------------------------------------- |
## | ``demo_server.py`` | The recorded source.  Written to disk so the editor  |
## |                 | pane can show the handler the panel seeks into.         |
## | ``trace.ct``    | The container: exec/value/call streams over that source |
## |                 | plus ``spans.dat`` / ``spans.idx`` and meta.dat bit 13.  |
##
## The step timeline is not decorative: each request's span carries the step
## range of *its* handler invocation, so double-clicking a row seeks to that
## request's entry into ``handle_request`` and not to a shared line.
##
## ## Growing the container (the live-session mode)
##
## ``--through=<n>`` writes the same session truncated to its first ``n``
## requests.  Both the seal points AND every record's content are derived from
## the request index alone — never from ``n`` — so stage ``n``'s span stream is
## a strict CHUNK PREFIX of stage ``n + 1``'s: the sealed chunks come out byte
## identical, which is exactly the immutability the tail's chunk-count cursor
## assumes (``src/db-backend/src/request_spans.rs``: "chunk k means the same
## records in every later observation of the same container").  That is what
## lets ``just demo-request-panel-live`` grow a container under an already open
## GUI.  ``demo_recipe_vm_test.nim`` asserts the property directly, so it cannot
## regress unnoticed.
##
## The one record that legitimately depends on the total — the process
## descriptor's ``endStep`` — is therefore published in two parts, the way a
## real recorder does it: an OPEN descriptor in chunk 0, and the settled one
## appended at the very end of a complete session.
##
## ``--open-only`` adds the one stage a rewrite-per-stage producer cannot reach
## by counting requests: it stops INSIDE request 6, after its open span record
## and before its completion, with the recorded timeline stopping at the handler
## entry.  A GUI tailing the container then sees a genuinely IN-FLIGHT row that
## settles on the following stage, which is what the panel's ``isOpen``
## rendering exists for.  Without it every stage would publish a request's open
## record and its completion in the same atomic rename, and the backend's
## within-delta ``resolve_spans`` would collapse the pair before the panel ever
## saw it.
##
## Note the honest limitation: ``MultiStreamTraceWriter`` builds its container
## **in memory** and serialises at close (``flushSpans``' own docs say so), so
## the demo grows the session by rewriting the whole image and renaming it over
## the old one, not by appending to a live file.  A recorder that wants true
## in-place growth needs the writer built on ``createCtfsStreaming(path)``.
## What is exercised either way is the whole reader half — held reader, chunk
## cursor, per-poll delta, client-side last-record-wins merge.
##
## Usage:
##   demo_request_session <out-dir> [--through=<n>] [--open-only]

import std/os
import results
import codetracer_trace_writer/multi_stream_writer
import codetracer_trace_writer/span_stream

const
  DemoProgramName* = "demo_server.py"
    ## The recorded source file, written next to the container.

  DemoRecordingId* = "01984f00-0000-7000-8000-0000000000d4"
    ## Pinned so every stage of a growing session is recognised by the
    ## backend's tail as the SAME recording.  ``RequestSpanTail`` keys its
    ## cursor on (container path, ``meta.dat`` recording id), and a fresh
    ## UUIDv7 per stage would make each rewrite look like a new recording and
    ## force a full ``reset`` instead of a delta.

  DemoSource* = """# CodeTracer RS-M4 demo server.
# Synthetic web-request spans over a real trace container.
ROUTES = {}


def route(path):
    def register(handler):
        ROUTES[path] = handler
        return handler
    return register


def handle_request(method, path, body):
    handler = ROUTES.get(path)
    if handler is None:
        return 404, b"not found"
    status, payload = handler(method, body)
    return status, payload


def serve_forever(sock):
    while True:
        method, path, body = read_request(sock)
        status, payload = handle_request(method, path, body)
        write_response(sock, status, payload)


serve_forever(listen(8080))
"""

type
  DemoRequest* = object
    ## One request the demo session serves.
    httpMethod*: string
    url*: string
    statusCode*: int
    durationMs*: int
    responseSize*: int
    publishedOpenFirst*: bool
      ## When true the request is published as an OPEN record before its
      ## completion, so the container carries the in-flight-then-settled pair
      ## the panel's ``isOpen`` rendering exists for.  It is also the only
      ## request ``--open-only`` can stop inside: a growing session may only
      ## pause where the full session has a record anyway, or the truncated
      ## stage would not be a chunk prefix of the next one.

const
  DemoRequests*: array[8, DemoRequest] = [
    DemoRequest(httpMethod: "GET", url: "/api/users",
      statusCode: 200, durationMs: 12, responseSize: 2148),
    DemoRequest(httpMethod: "POST", url: "/api/users",
      statusCode: 201, durationMs: 31, responseSize: 96),
    DemoRequest(httpMethod: "GET", url: "/api/users/42",
      statusCode: 200, durationMs: 8, responseSize: 512),
    DemoRequest(httpMethod: "GET", url: "/static/app.css",
      statusCode: 304, durationMs: 1, responseSize: 0),
    DemoRequest(httpMethod: "DELETE", url: "/api/users/42",
      statusCode: 404, durationMs: 5, responseSize: 48),
    DemoRequest(httpMethod: "GET", url: "/api/reports/slow",
      statusCode: 200, durationMs: 940, responseSize: 8192,
      publishedOpenFirst: true),
    DemoRequest(httpMethod: "PUT", url: "/api/orders/7",
      statusCode: 500, durationMs: 220, responseSize: 76),
    DemoRequest(httpMethod: "GET", url: "/health",
      statusCode: 200, durationMs: 1, responseSize: 2),
  ]
    ## Eight requests covering every status bucket the panel colours (2xx, 3xx,
    ## 4xx, 5xx), four methods, a duration on each side of the 1-second
    ## formatting boundary, a zero-byte body, and one open/completion pair.
    ## The URLs share the ``/api/users`` prefix so the panel's search filter has
    ## something to narrow.

  StartupLines = [3'u64, 5'u64, 26'u64, 20'u64, 21'u64]
    ## Module-level execution before the first request: the ROUTES literal, the
    ## decorator definition, the bottom-of-file call, then ``serve_forever``'s
    ## loop head.

  RequestLines = [22'u64, 13'u64, 14'u64, 16'u64, 17'u64, 23'u64, 21'u64]
    ## One request's steps: read it, enter ``handle_request`` (line 13 — the
    ## handler entry a row's double-click seeks to), look the route up, dispatch,
    ## return, write the response, loop.

  HandlerEntryStepOffset = 1
    ## Index within ``RequestLines`` of the ``handle_request`` entry step.  A
    ## span's ``start_step`` points here so activating a row lands on the
    ## handler rather than on the shared socket-read line.

  DemoWallStartNs = 1_764_500_000_000_000_000'u64

proc processSpan(lastStep: uint64, open: bool): SpanRecord =
  ## The RS-M1b ``span_type: "process"`` descriptor.  Present so the demo
  ## container is shaped like a real recording — and so the panel is seen
  ## NOT to render it as a request row.
  ##
  ## ``open`` is what keeps the growing session's chunk 0 immutable, and it is
  ## also what a real recorder does: a process that is still running has no end
  ## step and no end wall clock to write, so it publishes an OPEN descriptor
  ## first and a settled one when it exits.  A demo stage that wrote the
  ## settled descriptor up front would have to derive its ``endStep`` from the
  ## request TOTAL, and since that record shares chunk 0 with request 1 the
  ## whole chunk would re-seal with different bytes at every stage — breaking
  ## the chunk-prefix property the tail's cursor depends on.
  SpanRecord(
    spanId: 1,
    isOpen: open,
    status: if open: spanStatusUnknown else: spanStatusOk,
    startWallNs: DemoWallStartNs,
    endWallNs:
      if open: 0'u64
      else: DemoWallStartNs + 30_000_000_000'u64,
    processOrd: 0,
    threadId: 1,
    startStep: 0,
    endStep: if open: 0'u64 else: lastStep,
    spanType: "process",
    label: "python3 " & DemoProgramName,
    sharesTimeline: true,
    metadata: @[
      ("process.pid", "31415"),
      ("process.parent_pid", "1"),
      ("process.exe", "/usr/bin/python3"),
      ("process.args", "python3 " & DemoProgramName),
      ("process.has_execed", "false"),
    ])

proc requestSpan(spanId: uint64, req: DemoRequest,
    startStep, endStep: uint64, open: bool): SpanRecord =
  ## One inline-bound ``web-request`` span.  The metadata keys are the
  ## well-known ``http.*`` set from ``CTFS-Request-Span-Streams.md``, in the
  ## order the PHP recorder's sidecar already used — metadata order is part of
  ## the wire contract, so it is written deliberately rather than alphabetically.
  let startNs = DemoWallStartNs + 1_000_000_000'u64 + spanId * 250_000_000'u64
  var meta = @[
    ("http.method", req.httpMethod),
    ("http.url", req.url),
    ("http.status_code", if open: "0" else: $req.statusCode),
    ("http.duration_ms", if open: "0" else: $req.durationMs),
    ("http.response_size", if open: "0" else: $req.responseSize),
    ("http.remote_addr", "127.0.0.1"),
    ("framework", "synthetic-demo"),
  ]
  if not open and req.statusCode >= 500:
    meta.add(("error.message", "handler raised RuntimeError"))
  SpanRecord(
    spanId: spanId,
    isOpen: open,
    # The HTTP status class IS the span status, matching the mapping the
    # recorders' sidecars already used: >= 400 is an error.
    status:
      if open: spanStatusUnknown
      elif req.statusCode >= 400: spanStatusError
      else: spanStatusOk,
    startWallNs: startNs,
    endWallNs:
      if open: 0'u64
      else: startNs + uint64(req.durationMs) * 1_000_000'u64,
    processOrd: 0,
    threadId: 1,
    startStep: startStep,
    endStep: if open: 0'u64 else: endStep,
    spanType: "web-request",
    label: req.httpMethod & " " & req.url,
    contiguousOnOneThread: true,
    sharesTimeline: true,
    metadata: meta)

proc demoOpenOnlyStage*(throughRequest: int): bool =
  ## Whether ``--open-only`` is meaningful for this stage: it means "stop right
  ## after request ``throughRequest``'s OPEN record", so that request must be
  ## one the session publishes open first.
  ##
  ## The restriction is what keeps the chunk-prefix property intact.  Emitting
  ## an open record for a request the full session publishes settled-only would
  ## put a record in the truncated stage that the next stage does not have at
  ## the same append position — the exact re-sealing this producer avoids.
  let count = max(0, min(throughRequest, DemoRequests.len))
  count > 0 and DemoRequests[count - 1].publishedOpenFirst

proc demoSpansThrough*(throughRequest: int; openOnly: bool = false):
    tuple[records: seq[SpanRecord], sealAfter: seq[int]] =
  ## The append-order span RECORDS of a session truncated to its first
  ## ``throughRequest`` requests, plus the 1-based record ordinals after which
  ## a chunk is sealed.  ``openOnly`` truncates one record earlier still: the
  ## last request stops at its OPEN record, so the stage is a session with one
  ## request genuinely IN FLIGHT.  It is honoured only for a stage
  ## ``demoOpenOnlyStage`` accepts; callers reject the rest.
  ##
  ## ## Why every stage is a chunk prefix of the next
  ##
  ## Seal points are derived per request (one chunk per request, and an extra
  ## seal after an open record so the in-flight row is visible before its
  ## completion exists), never from the total.  Every record's CONTENT is
  ## likewise derived from its own request index only — which is why the
  ## process descriptor is published OPEN here and settled only once the
  ## session is complete: a settled descriptor's ``endStep`` is the end of the
  ## whole timeline, and that record sits in chunk 0 next to request 1, so
  ## writing it early would re-seal chunk 0 with different bytes at every
  ## stage.  With both halves index-derived, stage ``n``'s sealed chunks are
  ## byte-identical to stage ``n + 1``'s first chunks — the immutability the
  ## tail's chunk-count cursor needs
  ## (``request_spans.rs``: "chunk k means the same records in every later
  ## observation of the same container").
  ##
  ## ``demo_recipe_vm_test.nim``'s "a truncated demo session is a chunk prefix
  ## of the full one" asserts exactly that, byte for byte and record for
  ## record, over every consecutive stage pair the live recipe walks.
  let count = max(0, min(throughRequest, DemoRequests.len))
  let stopAtOpen = openOnly and demoOpenOnlyStage(count)
  var records: seq[SpanRecord] = @[]
  var sealAfter: seq[int] = @[]

  # Chunk 0 opens with the still-running process: content independent of how
  # many requests this stage serves.
  records.add(processSpan(0, open = true))

  for i in 0 ..< count:
    let req = DemoRequests[i]
    let base = uint64(StartupLines.len + i * RequestLines.len)
    let startStep = base + uint64(HandlerEntryStepOffset)
    let endStep = base + uint64(RequestLines.len) - 1
    let spanId = uint64(i + 2)          # span 1 is the process descriptor
    if req.publishedOpenFirst:
      records.add(requestSpan(spanId, req, startStep, endStep, open = true))
      sealAfter.add(records.len)
      if stopAtOpen and i == count - 1:
        # The session stops here: the request is in flight, its completion
        # record belongs to the NEXT stage.
        return (records, sealAfter)
      records.add(requestSpan(spanId, req, startStep, endStep, open = false))
    else:
      records.add(requestSpan(spanId, req, startStep, endStep, open = false))
    sealAfter.add(records.len)

  # The process exits only when the last request has been served, so its
  # settled descriptor — the one record that legitimately depends on the total
  # — is appended last, in a chunk no later stage can invalidate.
  if count == DemoRequests.len:
    let lastStep = uint64(StartupLines.len + count * RequestLines.len)
    records.add(processSpan(lastStep - 1, open = false))
    sealAfter.add(records.len)

  (records, sealAfter)

proc writeDemoRequestSession*(dir: string;
    throughRequest: int = DemoRequests.len;
    openOnly: bool = false): Result[string, string] =
  ## Materialise the demo trace folder in ``dir`` and return the container path.
  ##
  ## Writing the container is atomic: the image is serialised to a sibling
  ## temp file and renamed into place, so a GUI already tailing ``trace.ct``
  ## never observes a half-written container (a torn read would make the
  ## backend's tail drop its reader and rebuild, costing a poll interval).
  ##
  ## ``openOnly`` stops the session INSIDE request ``throughRequest``: its open
  ## span record is published, its completion is not, and the recorded timeline
  ## stops at the handler entry — the stage a tailing panel must see to render
  ## an in-flight row.  Only stages ``demoOpenOnlyStage`` accepts can do this;
  ## asking for any other is an error rather than a silently ignored flag.
  if openOnly and not demoOpenOnlyStage(throughRequest):
    return err("--open-only needs a request the session publishes open " &
      "first; request " & $throughRequest & " is not one of those " &
      "(the demo publishes request 6 open first)")
  try:
    createDir(dir)
  except OSError as e:
    return err("cannot create " & dir & ": " & e.msg)

  let sourcePath = dir / DemoProgramName
  try:
    writeFile(sourcePath, DemoSource)
  except IOError as e:
    return err("cannot write " & sourcePath & ": " & e.msg)

  let containerPath = dir / "trace.ct"
  var wRes = initMultiStreamWriter(containerPath, sourcePath,
    recordingId = DemoRecordingId)
  if wRes.isErr:
    return err("init writer: " & wRes.error)
  var w = wRes.get()
  w.metadata.workdir = dir
  w.metadata.args = @[DemoProgramName]

  let pathRes = w.registerPath(sourcePath)
  if pathRes.isErr:
    w.closeCtfs()
    return err("registerPath: " & pathRes.error)
  let pathId = pathRes.get()

  let fnRes = w.registerFunction("handle_request")
  if fnRes.isErr:
    w.closeCtfs()
    return err("registerFunction: " & fnRes.error)
  let handlerFn = fnRes.get()

  # The recorded timeline.  Step indices are implicit in registration order and
  # are exactly what the spans' step ranges refer to.
  for line in StartupLines:
    let r = w.registerStep(pathId, line, [])
    if r.isErr:
      w.closeCtfs()
      return err("registerStep: " & r.error)

  let count = max(0, min(throughRequest, DemoRequests.len))
  for i in 0 ..< count:
    # An in-flight request has only executed as far as its handler entry, so
    # that is where the recorded timeline stops for it.  The unreturned call is
    # deliberate and supported: ``MultiStreamTraceWriter.close`` drains unclosed
    # frames exactly so an exit-without-return recording stays well formed.
    let inFlight = openOnly and i == count - 1
    let lastStepIndex =
      if inFlight: HandlerEntryStepOffset
      else: RequestLines.len - 1
    for j in 0 .. lastStepIndex:
      let line = RequestLines[j]
      if j == HandlerEntryStepOffset:
        let c = w.registerCall(handlerFn, [])
        if c.isErr:
          w.closeCtfs()
          return err("registerCall: " & c.error)
      let r = w.registerStep(pathId, line, [])
      if r.isErr:
        w.closeCtfs()
        return err("registerStep: " & r.error)
      if j == RequestLines.len - 2:
        let ret = w.registerReturn()
        if ret.isErr:
          w.closeCtfs()
          return err("registerReturn: " & ret.error)

  let (records, sealAfter) = demoSpansThrough(throughRequest, openOnly)
  for i, rec in records:
    let r = w.registerSpan(rec)
    if r.isErr:
      w.closeCtfs()
      return err("registerSpan " & $rec.spanId & ": " & r.error)
    if (i + 1) in sealAfter:
      let f = w.flushSpans()
      if f.isErr:
        w.closeCtfs()
        return err("flushSpans: " & f.error)

  let closeRes = w.close()
  if closeRes.isErr:
    w.closeCtfs()
    return err("close: " & closeRes.error)
  let bytes = w.toBytes()
  w.closeCtfs()

  let tmpPath = containerPath & ".tmp"
  try:
    writeFile(tmpPath, bytes)
    moveFile(tmpPath, containerPath)
  except IOError as e:
    return err("cannot write " & containerPath & ": " & e.msg)
  except OSError as e:
    return err("cannot rename into " & containerPath & ": " & e.msg)

  ok(containerPath)

when isMainModule:
  # Only the CLI needs string parsing; importing it unconditionally would make
  # every importer of this module carry an unused-import warning.
  import std/strutils

  proc usage() =
    stderr.writeLine(
      "usage: demo_request_session <out-dir> [--through=<n>] [--open-only]")
    quit(2)

  var outDir = ""
  var through = DemoRequests.len
  var openOnly = false
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    if arg.startsWith("--through="):
      try:
        through = parseInt(arg["--through=".len .. ^1])
      except ValueError:
        usage()
    elif arg == "--open-only":
      openOnly = true
    elif arg.startsWith("-"):
      usage()
    elif outDir.len == 0:
      outDir = arg
    else:
      usage()
  if outDir.len == 0:
    usage()

  let res = writeDemoRequestSession(outDir, through, openOnly)
  if res.isErr:
    stderr.writeLine("demo_request_session: " & res.error)
    quit(1)
  echo res.get()
