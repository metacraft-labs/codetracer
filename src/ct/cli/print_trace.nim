## ct print -- Print trace events in human-readable format.
##
## Auto-detects the trace type:
## - `.ct` containers: materialized DB traces and MCR replay traces alike are
##   stored in CTFS containers; `ct print` shows summary info, prints the
##   request list when the container carries a span stream, and delegates
##   detailed event analysis to `ct-mcr` / `ct-print` companion tools.
## - JSONL span manifests: parses and pretty-prints HTTP requests
## - Trace directories: scans for trace files within
##
## Legacy sidecar bundles are no longer accepted (M-REC-1.5): all
## metadata lives in the CTFS container's ``meta.dat``.
##
## # Request spans: the container wins over the sidecar (RS-M2)
##
## A recording's HTTP requests used to live only in a sidecar
## (`session_manifest.jsonl` from the PHP recorder, `codetracer_spans.jsonl`
## from the Ruby/Python middlewares).  They now live inside the `.ct` container
## itself, as the `spans.dat` / `spans.idx` span stream gated by `meta.dat`
## bit 13 — see
## `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`.
##
## `ct print` therefore **prefers the stream** and only falls back to a sidecar
## when the container has none.  The sidecar path stays for exactly as long as
## the read-only compatibility shim does: pre-cutover sessions must keep
## printing.  Both paths render the same table through `printRequestRows`, so
## the two can never drift into showing different columns.

import
  std/[algorithm, os, json, strutils, strformat, options]

import codetracer_trace_writer/span_stream

type
  TraceType* = enum
    ttUnknown
    ttMcrTrace       ## MCR .ct file
    ttMaterialized   ## Legacy materialized trace (no longer supported by readers)
    ttSpanManifest   ## JSONL span manifest (session_manifest.jsonl, codetracer_spans.jsonl)
    ttTraceDirectory ## Directory containing trace files

  RequestRow* = object
    ## One printable HTTP request, produced by EITHER the container's span
    ## stream or a legacy sidecar line.  Deliberately stringly-typed: the
    ## metadata values are strings on the wire (the spec says so — "Values are
    ## strings, matching the current JSONL contract"), and `ct print` only
    ## renders them.
    httpMethod*: string
    url*: string
    statusCode*: string
    durationMs*: string
    status*: string       ## "ok" / "error" / "unknown"
    raw*: string          ## the original JSON line, for `--format json`

  PrintOptions* = object
    path*: string
    filter*: string        ## "calls", "steps", "http", "errors", ""
    function*: string      ## filter by function name
    limit*: int            ## max events to print (0 = unlimited)
    format*: string        ## "text", "json", "csv"
    verify*: bool          ## verify mode for CI smoke tests
    follow*: bool          ## follow mode (future: watch for new events)

proc detectTraceType*(path: string): TraceType =
  ## Determine the trace type from a file or directory path.
  ## Returns ttUnknown if the path does not exist or cannot be classified.
  if not fileExists(path) and not dirExists(path):
    return ttUnknown

  if fileExists(path):
    if path.endsWith(".ct"):
      return ttMcrTrace
    if path.endsWith(".jsonl"):
      return ttSpanManifest
    if path.endsWith(".bin") or path.endsWith(".json"):
      # Legacy materialized trace fragments — no longer accepted, but
      # report them so callers can produce a clear migration message.
      return ttMaterialized
    # Peek at the first bytes to detect JSON lines
    try:
      let content = readFile(path)
      if content.len > 0 and content[0] == '{':
        return ttSpanManifest
    except CatchableError:
      discard
    return ttUnknown

  # Directory -- look for `.ct` containers (materialized DB or MCR).
  for kind, file in walkDir(path):
    if kind == pcFile and file.endsWith(".ct"):
      return ttMcrTrace

  if fileExists(path / "session_manifest.jsonl") or
      fileExists(path / "codetracer_spans.jsonl"):
    return ttSpanManifest

  # Legacy 3-file bundle detection (kept only for the migration message).
  if fileExists(path / "trace.bin") or fileExists(path / "trace.json"):
    return ttMaterialized

  return ttTraceDirectory

proc findContainer*(path: string): string =
  ## The `.ct` container for `path`, which may be the container itself or the
  ## directory holding it.  Empty string when there is none.  Mirrors the probes
  ## the db-backend's trace-open path performs (`trace.ct`, then any single
  ## `.ct`), and sorts the fallback candidates so the choice is deterministic —
  ## `walkDir` order is filesystem-dependent.
  if fileExists(path):
    return if path.endsWith(".ct"): path else: ""
  if not dirExists(path):
    return ""
  let canonical = path / "trace.ct"
  if fileExists(canonical):
    return canonical
  var candidates: seq[string] = @[]
  for kind, entry in walkDir(path):
    if kind == pcFile and entry.endsWith(".ct"):
      candidates.add(entry)
  if candidates.len == 0:
    return ""
  candidates.sort()
  candidates[0]

proc metaValue(span: SpanRecord, key: string): string =
  ## First value recorded under `key`.  Linear because span metadata is a
  ## handful of pairs, and because "first wins" is a defined answer where a map
  ## rebuild would pick arbitrarily.
  for (k, v) in span.metadata:
    if k == key:
      return v
  ""

proc statusText(status: SpanStatus): string =
  case status
  of spanStatusUnknown: "unknown"
  of spanStatusOk: "ok"
  of spanStatusError: "error"

proc containerRequestRows*(ctPath: string): Option[seq[RequestRow]] =
  ## The request rows carried by a container's span stream, or `none` when the
  ## container has no stream at all.
  ##
  ## The presence gate is `spans.dat` rather than `meta.dat` bit 13.  `ct` has
  ## no meta.dat flag reader of its own (`ct/trace/ctfs_sources.nim` parses the
  ## payload and discards the flags), and the two agree by construction: the
  ## writer only creates `spans.dat` when it sets the bit.  A container that
  ## HAS the file but whose stream cannot be read is reported as an error rather
  ## than silently degrading to the sidecar — a damaged stream is a real
  ## problem, and quietly printing stale sidecar rows instead would hide it.
  var raw: string
  try:
    raw = readFile(ctPath)
  except CatchableError:
    return none(seq[RequestRow])
  var data = newSeq[byte](raw.len)
  for i in 0 ..< raw.len:
    data[i] = byte(raw[i])

  if not hasSpanStreamFiles(data):
    return none(seq[RequestRow])

  let readerRes = initSpanStreamReader(data)
  if readerRes.isErr:
    echo "Error: cannot read the span stream in " & ctPath & ": " & readerRes.error
    return some(newSeq[RequestRow]())
  let reader = readerRes.get()
  let settledRes = reader.settledSpans()
  if settledRes.isErr:
    echo "Error: cannot decode the span stream in " & ctPath & ": " & settledRes.error
    return some(newSeq[RequestRow]())

  var rows: seq[RequestRow] = @[]
  for span in settledRes.get():
    # Only web requests are printable rows; `process` / `test` spans share the
    # stream but belong to other views.
    if span.spanType != "web-request":
      continue
    let httpMethod = metaValue(span, "http.method")
    let url = metaValue(span, "http.url")
    var line = ""
    try:
      line = $(%*{
        "span_type": span.spanType,
        "status": statusText(span.status),
        "start_step": span.startStep,
        "end_step": span.endStep,
        "metadata": {
          "http.method": httpMethod,
          "http.url": url,
          "http.status_code": metaValue(span, "http.status_code"),
          "http.duration_ms": metaValue(span, "http.duration_ms"),
        },
      })
    except CatchableError:
      line = ""
    rows.add(RequestRow(
      httpMethod: if httpMethod.len > 0: httpMethod else: "-",
      url: if url.len > 0: url else: "-",
      statusCode: metaValue(span, "http.status_code"),
      durationMs: metaValue(span, "http.duration_ms"),
      status: statusText(span.status),
      raw: line))
  some(rows)

proc sidecarPath(path: string): string =
  ## The legacy sidecar for `path`, or empty when there is none.
  if fileExists(path):
    return path
  if fileExists(path / "session_manifest.jsonl"):
    return path / "session_manifest.jsonl"
  if fileExists(path / "codetracer_spans.jsonl"):
    return path / "codetracer_spans.jsonl"
  ""

proc sidecarRequestRows*(manifestPath: string): seq[RequestRow] =
  ## Rows from a legacy `session_manifest.jsonl` / `codetracer_spans.jsonl`.
  ##
  ## Malformed lines are skipped, matching the reference loader at
  ## `codetracer-native-recorder/.../span_manifest.nim`: the sidecar is
  ## append-only text written from a shutdown hook, so a truncated final line is
  ## an expected state of a real session and must not make the file unprintable.
  for line in lines(manifestPath):
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    try:
      let j = parseJson(trimmed)
      let meta = j{"metadata"}
      if meta == nil:
        continue
      result.add(RequestRow(
        httpMethod: meta{"http.method"}.getStr("-"),
        url: meta{"http.url"}.getStr("-"),
        statusCode: meta{"http.status_code"}.getStr("-"),
        durationMs: meta{"http.duration_ms"}.getStr("-"),
        status: j{"status"}.getStr("-"),
        raw: trimmed))
    except JsonParsingError:
      continue

proc printRequestRows(rows: seq[RequestRow], opts: PrintOptions) =
  ## Render request rows.  Shared by the span-stream and sidecar paths so the
  ## two can never present different columns for the same recording.
  if opts.format == "csv":
    echo "method,url,status_code,duration_ms,status"
  elif opts.format != "json":
    echo "   #  Method   URL                            Status  Duration    Status"
    echo "-".repeat(75)

  var count = 0
  for row in rows:
    # Apply filters
    if opts.filter == "errors" and row.status != "error":
      continue
    if opts.filter == "http" and row.httpMethod == "-":
      continue
    if opts.function.len > 0 and opts.function notin row.url:
      continue

    inc count
    if opts.limit > 0 and count > opts.limit:
      break

    if opts.format == "json":
      echo row.raw
    elif opts.format == "csv":
      echo fmt"{row.httpMethod},{row.url},{row.statusCode},{row.durationMs},{row.status}"
    else:
      echo fmt"{count:>4}  {row.httpMethod:<8} {row.url:<30} {row.statusCode:<7} {row.durationMs:>6}ms  {row.status:<6}"

  if opts.format != "json" and opts.format != "csv":
    echo ""
    echo fmt"Total: {count} requests"

proc printSpanManifest(path: string, opts: PrintOptions) =
  ## Print a recording's HTTP requests, preferring the container's span stream
  ## over any legacy sidecar (RS-M2).
  let container = findContainer(path)
  if container.len > 0:
    let streamRows = containerRequestRows(container)
    if streamRows.isSome:
      echo fmt"Request spans: {container} (span stream)"
      echo ""
      printRequestRows(streamRows.get(), opts)
      return

  let manifestPath = sidecarPath(path)
  if manifestPath.len == 0:
    echo "No span manifest found in: " & path
    return

  echo fmt"Span manifest: {manifestPath}"
  echo ""
  printRequestRows(sidecarRequestRows(manifestPath), opts)

proc printMaterializedTrace(path: string, opts: PrintOptions) =
  ## Stub: legacy materialized traces are no longer supported (M-REC-1.5).
  ## Materialized traces now live in `.ct` CTFS containers and are printed
  ## via `printMcrTrace`. This stub stays around so detection of legacy
  ## artefacts produces a helpful migration message rather than silently
  ## walking nonexistent files.
  discard opts
  echo fmt"Legacy materialized trace detected at: {path}"
  echo "  Legacy sidecar bundles are no longer accepted; the trace must be"
  echo "  regenerated as a CTFS `.ct` container (see"
  echo "  codetracer-specs/Trace-Files/CTFS-Migration-Guide.md)."

proc printMcrTrace(inputPath: string, opts: PrintOptions) =
  ## Print info about an MCR .ct trace.
  ##
  ## `inputPath` may be the container itself OR the directory holding it —
  ## `detectTraceType` classifies a directory that contains any `.ct` as
  ## `ttMcrTrace`, so this proc must resolve the container rather than assume
  ## it was handed a file (it previously called `getFileSize` straight on the
  ## argument, which raises on a directory).
  ##
  ## When the container carries a span stream (RS-M2) the request list is
  ## printed from it — that is the whole point of moving spans into the
  ## container: a recording is ONE artifact, so `ct print <container>` no longer
  ## needs a second file to show what was served.  A container without a stream
  ## still falls back to a sidecar sitting next to it, so pre-cutover sessions
  ## print exactly as they did.
  let path = findContainer(inputPath)
  if path.len == 0:
    echo "Error: no .ct container found at: " & inputPath
    return

  echo fmt"MCR trace: {path}"
  let size = getFileSize(path)
  echo fmt"  Size: {size} bytes ({size div 1024} KB)"
  echo ""

  let streamRows = containerRequestRows(path)
  if streamRows.isSome:
    printRequestRows(streamRows.get(), opts)
    echo ""
  else:
    let manifestPath = sidecarPath(parentDir(path))
    if manifestPath.len > 0:
      echo fmt"Span manifest: {manifestPath}"
      echo ""
      printRequestRows(sidecarRequestRows(manifestPath), opts)
      echo ""

  echo "(Use 'ct-mcr trace info " & path & "' for detailed event analysis)"
  echo "(Use 'ct-mcr trace events " & path & "' to dump individual events)"

proc printTraceDirectory(path: string, opts: PrintOptions) =
  ## Scan a directory for traces and print a summary.
  echo fmt"Trace directory: {path}"
  echo ""

  var traceCount = 0
  for kind, entry in walkDir(path):
    if kind == pcDir:
      let detected = detectTraceType(entry)
      if detected != ttUnknown and detected != ttTraceDirectory:
        inc traceCount
        let name = extractFilename(entry)
        echo fmt"  [{traceCount}] {name} ({detected})"
    elif kind == pcFile and entry.endsWith(".ct"):
      inc traceCount
      let name = extractFilename(entry)
      echo fmt"  [{traceCount}] {name} (ttMcrTrace)"

  if traceCount == 0:
    echo "  No traces found."
  else:
    echo ""
    echo fmt"Total: {traceCount} traces"
    echo "Use 'ct print <trace-path>' to inspect a specific trace."

type
  VerifyResult* = object
    ## Result of trace verification, used by ``--verify`` for CI smoke tests.
    valid*: bool
    traceType*: TraceType
    eventCount*: int
    callCount*: int
    stepCount*: int
    httpRequestCount*: int
    sourceFileCount*: int
    errors*: seq[string]

proc countContainerRequests(path: string): Option[int] =
  ## Number of web-request spans in the container for `path`, or `none` when
  ## there is no container with a span stream.  The RS-M2 preference rule in one
  ## place, so `--verify` and the printers agree on which source is canonical.
  let container = findContainer(path)
  if container.len == 0:
    return none(int)
  let rows = containerRequestRows(container)
  if rows.isNone:
    return none(int)
  some(rows.get().len)

proc verifySpanManifest(path: string): VerifyResult =
  ## Verify a recording's HTTP requests, preferring the container's span stream
  ## over a legacy sidecar (RS-M2).
  result.traceType = ttSpanManifest

  let fromStream = countContainerRequests(path)
  if fromStream.isSome:
    result.httpRequestCount = fromStream.get()
    result.eventCount = result.httpRequestCount
    result.valid = result.httpRequestCount > 0
    if result.httpRequestCount == 0:
      result.errors.add("Span stream carries no HTTP requests")
    return

  let manifestPath = sidecarPath(path)
  if manifestPath.len == 0:
    result.errors.add("No span manifest found")
    return

  for line in lines(manifestPath):
    let trimmed = line.strip()
    if trimmed.len == 0: continue
    try:
      let j = parseJson(trimmed)
      let meta = j{"metadata"}
      if meta != nil and meta.hasKey("http.method"):
        result.httpRequestCount += 1
      else:
        result.errors.add("Span missing http.method metadata")
    except CatchableError:
      result.errors.add("Malformed JSON line")

  result.eventCount = result.httpRequestCount
  result.valid = result.httpRequestCount > 0 and result.errors.len == 0

proc verifyMaterializedTrace(path: string): VerifyResult =
  ## Legacy materialized traces are no longer supported; verification just
  ## reports a clear migration error so CI smoke tests fail loudly instead
  ## of silently passing on a stale 3-file bundle.
  result.traceType = ttMaterialized
  result.valid = false
  let msg = "Legacy materialized trace at " & path &
            " is no longer supported (CTFS-only). Regenerate as a `.ct` " &
            "container per codetracer-specs/Trace-Files/CTFS-Migration-Guide.md."
  result.errors.add(msg)

proc verifyMcrTrace(inputPath: string): VerifyResult =
  ## Verify an MCR .ct trace exists and has reasonable size.
  ##
  ## As in `printMcrTrace`, `inputPath` may be the container or the directory
  ## holding it, because that is what `detectTraceType` can hand us.
  result.traceType = ttMcrTrace
  let path = findContainer(inputPath)
  if path.len == 0:
    result.errors.add("File not found: " & inputPath)
    return
  let size = getFileSize(path)
  if size < 100:
    result.errors.add(
      "Trace file suspiciously small (" &
      $size & " bytes)")
  else:
    result.eventCount = 1  # We know events exist based on file size
    result.valid = true
  # RS-M2: a container that carries a span stream reports its request count
  # directly, so `ct print --verify <container>` is a complete smoke test of a
  # recorded server session without a second file.
  let requests = containerRequestRows(path)
  if requests.isSome:
    result.httpRequestCount = requests.get().len

proc verifyTraceDirectory(path: string): VerifyResult =
  ## Verify a directory containing traces or span manifests.
  result.traceType = ttTraceDirectory
  var traceCount = 0

  # Request spans: the container's stream wins over any sidecar (RS-M2).  Only
  # when the directory holds no span-bearing container do the legacy sidecars
  # get counted, so a session that has been re-recorded into a container is
  # never double-counted against a stale sidecar left beside it.
  let fromStream = countContainerRequests(path)
  if fromStream.isSome:
    result.httpRequestCount += fromStream.get()
  else:
    for candidate in [
      path / "session_manifest.jsonl",
      path / "codetracer_spans.jsonl",
    ]:
      if fileExists(candidate):
        let subResult = verifySpanManifest(candidate)
        result.httpRequestCount += subResult.httpRequestCount

  # Check for individual trace directories
  for kind, entry in walkDir(path):
    if kind == pcDir:
      let subType = detectTraceType(entry)
      if subType == ttMaterialized:
        let subResult = verifyMaterializedTrace(entry)
        result.eventCount += subResult.eventCount
        result.callCount += subResult.callCount
        result.stepCount += subResult.stepCount
        traceCount += 1

  # Check for .ct files
  for kind, entry in walkDir(path):
    if kind == pcFile and entry.endsWith(".ct"):
      traceCount += 1
      result.eventCount += 1

  if traceCount == 0 and result.httpRequestCount == 0:
    result.errors.add(
      "No traces or requests found in directory")

  result.valid = result.errors.len == 0 and
    (result.eventCount > 0 or result.httpRequestCount > 0)

proc runVerify*(opts: PrintOptions): int =
  ## Verify a trace and return exit code (0=pass, 1=fail).
  ## Designed for CI smoke tests:
  ##   ct print --verify trace-out/ || exit 1
  let traceType = detectTraceType(opts.path)

  let verifyResult = case traceType
    of ttSpanManifest:
      verifySpanManifest(opts.path)
    of ttMaterialized:
      verifyMaterializedTrace(opts.path)
    of ttMcrTrace:
      verifyMcrTrace(opts.path)
    of ttTraceDirectory:
      verifyTraceDirectory(opts.path)
    of ttUnknown:
      VerifyResult(
        valid: false,
        errors: @[
          "Cannot detect trace type: " & opts.path])

  # Print concise summary -- one line per metric, PASS/FAIL at end
  echo "Trace verification: " & opts.path
  echo "  Type:           " & $verifyResult.traceType
  echo "  Events:         " & $verifyResult.eventCount
  if verifyResult.callCount > 0:
    echo "  Function calls: " & $verifyResult.callCount
  if verifyResult.stepCount > 0:
    echo "  Steps:          " & $verifyResult.stepCount
  if verifyResult.httpRequestCount > 0:
    echo "  HTTP requests:  " & $verifyResult.httpRequestCount
  if verifyResult.sourceFileCount > 0:
    echo "  Source files:   " & $verifyResult.sourceFileCount

  if verifyResult.errors.len > 0:
    echo "  Errors:"
    for err in verifyResult.errors:
      echo "    - " & err

  if verifyResult.valid:
    echo "  Status:         PASS"
    return 0
  else:
    echo "  Status:         FAIL"
    return 1

proc runPrint*(opts: PrintOptions) =
  ## Main entry point for the print command.
  if opts.verify:
    let exitCode = runVerify(opts)
    quit(exitCode)

  let traceType = detectTraceType(opts.path)

  case traceType
  of ttSpanManifest:
    printSpanManifest(opts.path, opts)
  of ttMaterialized:
    printMaterializedTrace(opts.path, opts)
  of ttMcrTrace:
    printMcrTrace(opts.path, opts)
  of ttTraceDirectory:
    printTraceDirectory(opts.path, opts)
  of ttUnknown:
    echo "Error: Cannot detect trace type for: " & opts.path
    echo ""
    echo "Expected one of:"
    echo "  - A .ct file (MCR trace)"
    echo "  - A directory with trace.bin/trace.json (materialized trace)"
    echo "  - A .jsonl file (span manifest)"
    echo "  - A directory containing traces"
    quit(1)
