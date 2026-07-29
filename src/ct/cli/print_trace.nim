## ct print -- Inspect a recording.
##
## Auto-detects the trace shape and reads it:
## - `.ct` CTFS containers (server-side recorders, MCR): full decode via the
##   shared `codetracer_ct_print_lib` reader.
## - Three-file JSON trace directories (the browser recorder's output).
## - JSONL span manifests: parses and pretty-prints HTTP requests.
## - Directories containing any of the above.
##
## One command covering every shape is deliberate. A cross-process session
## routinely mixes a browser recording with a server recording, and the
## question that matters — do their correlation markers actually pair? —
## can only be answered by looking at both in the same terms.
##
## Useful invocations:
##   ct print <trace>                     summary
##   ct print --filter markers <trace>    boundary crossings this trace declares
##   ct print --format json <trace>       complete decoded document

import
  std/[os, json, strutils, strformat, options, tables]
import results
import codetracer_trace_writer/new_trace_reader
import codetracer_ct_print_lib

type
  TraceType* = enum
    ttUnknown
    ttMcrTrace       ## MCR .ct file
    ttMaterialized   ## Legacy materialized trace (no longer supported by readers)
    ttSpanManifest   ## JSONL span manifest (session_manifest.jsonl, codetracer_spans.jsonl)
    ttTraceDirectory ## Directory containing trace files

  PrintOptions* = object
    path*: string
    filter*: string        ## "calls", "steps", "http", "errors", "markers", ""
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

proc printSpanManifest(path: string, opts: PrintOptions) =
  ## Pretty-print a JSONL span manifest (HTTP requests).
  let manifestPath =
    if fileExists(path):
      path
    elif fileExists(path / "session_manifest.jsonl"):
      path / "session_manifest.jsonl"
    elif fileExists(path / "codetracer_spans.jsonl"):
      path / "codetracer_spans.jsonl"
    else:
      echo "No span manifest found in: " & path
      return

  echo fmt"Span manifest: {manifestPath}"
  echo ""

  if opts.format == "csv":
    echo "method,url,status_code,duration_ms,status"
  elif opts.format != "json":
    # Text table header
    echo "   #  Method   URL                            Status  Duration    Status"
    echo "-".repeat(75)

  var count = 0
  for line in lines(manifestPath):
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue

    try:
      let j = parseJson(trimmed)
      let meta = j{"metadata"}
      if meta == nil:
        continue

      let httpMethod = meta{"http.method"}.getStr("-")
      let url = meta{"http.url"}.getStr("-")
      let statusCode = meta{"http.status_code"}.getStr("-")
      let durationMs = meta{"http.duration_ms"}.getStr("-")
      let status = j{"status"}.getStr("-")

      # Apply filters
      if opts.filter == "errors" and status != "error":
        continue
      if opts.filter == "http" and httpMethod == "-":
        continue
      if opts.function.len > 0 and opts.function notin url:
        continue

      inc count
      if opts.limit > 0 and count > opts.limit:
        break

      if opts.format == "json":
        echo trimmed
      elif opts.format == "csv":
        echo fmt"{httpMethod},{url},{statusCode},{durationMs},{status}"
      else:
        echo fmt"{count:>4}  {httpMethod:<8} {url:<30} {statusCode:<7} {durationMs:>6}ms  {status:<6}"
    except JsonParsingError:
      continue

  if opts.format != "json" and opts.format != "csv":
    echo ""
    echo fmt"Total: {count} requests"

proc printMaterializedTraceStub(path: string, opts: PrintOptions) =
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

proc collectMarkerEvents(events: JsonNode): seq[JsonNode] =
  ## Pick the correlation markers out of a `buildFullDocument` event list.
  if events == nil or events.kind != JArray:
    return @[]
  for ev in events.elems:
    if isCorrelationMarker(ev):
      result.add(ev)

proc renderMarkerTable(program: string, markers: seq[JsonNode]) =
  ## Human-readable rendering shared by the CTFS and JSON trace shapes.
  ##
  ## Correlation markers are what let a value's history cross a process
  ## boundary: each records that a value left or entered this recording,
  ## tagged with a key that pairs it with the matching marker elsewhere.
  ## When a cross-process origin chain stops early, the reason is nearly
  ## always visible here — a missing marker, a key that does not match its
  ## counterpart, or a direction recorded the wrong way round.
  if program.len > 0:
    echo fmt"program: {program}"
  echo fmt"correlation markers: {markers.len}"
  if markers.len == 0:
    echo ""
    echo "  (none — this recording declares no boundary crossings, so a"
    echo "   cross-process origin chain cannot enter or leave it)"
    return
  echo ""
  echo "  #  direction  boundary                  key                  step  shown"
  echo "-".repeat(88)
  for i, m in markers:
    let payload = m{"correlation_marker"}
    let direction = payload{"direction"}.getStr("?")
    let boundary = payload{"boundary_id"}.getStr("?")
    let key = payload{"key_value"}.getStr("?")
    let stepId = m{"step_id"}.getInt(-1)
    let shown =
      if payload{"show_value"} != nil and payload{"show_value"}.kind == JString:
        payload{"show_value"}.getStr()
      else:
        ""
    echo align($(i + 1), 3) & "  " & alignLeft(direction, 9) & "  " &
      alignLeft(boundary, 24) & "  " & alignLeft(key, 19) & "  " &
      align($stepId, 4) & "  " & shown

proc printCtfsTrace(path: string, opts: PrintOptions) =
  ## Decode a CTFS `.ct` container and print it.
  ##
  ## This used to stop at "here is the file size, go run ct-mcr". Reading
  ## the container here means one command answers questions about every
  ## trace shape CodeTracer produces, which matters most when comparing
  ## recordings that are *supposed* to correlate with each other: having
  ## to switch tools between a browser recording and a server recording is
  ## exactly when a mismatch goes unnoticed.
  let readerRes = openNewTrace(path)
  if readerRes.isErr:
    echo fmt"Error: cannot read CTFS container {path}: {readerRes.error}"
    quit(1)
  var reader = readerRes.get()
  let doc = buildFullDocument(reader, FullOpts())

  if opts.filter == "markers":
    let markers = collectMarkerEvents(doc{"events"})
    if opts.format == "json":
      var arr = newJArray()
      for m in markers:
        arr.add(m)
      echo pretty(arr, indent = 2)
    else:
      renderMarkerTable(doc{"metadata"}{"program"}.getStr(""), markers)
    return

  if opts.format == "json":
    echo pretty(doc, indent = 2)
    return

  echo fmt"CTFS trace: {path}"
  let meta = doc{"metadata"}
  if meta != nil:
    echo "  Program:  " & meta{"program"}.getStr("-")
    echo "  Workdir:  " & meta{"workdir"}.getStr("-")
    echo "  Recorder: " & meta{"recorder"}.getStr("-")
  let counts = doc{"counts"}
  if counts != nil:
    for k, v in counts.pairs:
      echo fmt"  {k}: {v}"
  let markers = collectMarkerEvents(doc{"events"})
  echo fmt"  Correlation markers: {markers.len}"
  echo ""
  echo "  Use --markers for the boundary-crossing detail,"
  echo "      --format json for the complete decoded document."

proc printJsonTrace(path: string, opts: PrintOptions) =
  ## Print a legacy three-file JSON trace directory.
  ##
  ## This is the shape the browser recorder writes (`record-web`), so it
  ## has to be first-class here rather than a migration message: a
  ## cross-process session routinely mixes one of these with a CTFS
  ## container from a server recorder.
  let eventsPath = path / "trace.json"
  if not fileExists(eventsPath):
    echo fmt"Error: {eventsPath} not found"
    quit(1)
  let events = parseFile(eventsPath)
  var program = ""
  if fileExists(path / "trace_metadata.json"):
    program = parseFile(path / "trace_metadata.json"){"program"}.getStr("")

  # Re-shape the on-disk events into the same `{kind, ...}` view
  # `buildFullDocument` produces, so the marker rendering below is shared
  # with the CTFS path rather than duplicated per format.
  var markers: seq[JsonNode] = @[]
  var stepIndex = 0
  var counts = initTable[string, int]()
  if events.kind == JArray:
    for raw in events.elems:
      if raw.kind != JObject:
        continue
      for tag, body in raw.pairs:
        counts.mgetOrPut(tag, 0) += 1
        if tag == "Step":
          inc stepIndex
        elif tag == "Event":
          var ev = newJObject()
          ev["kind"] = newJString("io")
          ev["step_id"] = newJInt(stepIndex)
          let metadata = body{"metadata"}.getStr("")
          var bytes: seq[byte] = @[]
          for c in metadata:
            bytes.add(byte(c))
          addEventMetadata(ev, bytes)
          if isCorrelationMarker(ev):
            markers.add(ev)

  if opts.filter == "markers":
    if opts.format == "json":
      var arr = newJArray()
      for m in markers:
        arr.add(m)
      echo pretty(arr, indent = 2)
    else:
      renderMarkerTable(program, markers)
    return

  if opts.format == "json":
    echo pretty(events, indent = 2)
    return

  echo fmt"JSON trace: {path}"
  echo fmt"  Program: {program}"
  for tag, n in counts.pairs:
    echo fmt"  {tag}: {n}"
  echo fmt"  Correlation markers: {markers.len}"

proc printMcrTrace(path: string, opts: PrintOptions) =
  ## Print a `.ct` container (materialized DB traces and MCR traces alike).
  printCtfsTrace(path, opts)

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

proc verifySpanManifest(path: string): VerifyResult =
  ## Verify a JSONL span manifest contains valid HTTP request entries.
  result.traceType = ttSpanManifest
  let manifestPath =
    if fileExists(path): path
    elif fileExists(path / "session_manifest.jsonl"):
      path / "session_manifest.jsonl"
    elif fileExists(path / "codetracer_spans.jsonl"):
      path / "codetracer_spans.jsonl"
    else:
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

proc verifyMcrTrace(path: string): VerifyResult =
  ## Verify an MCR .ct trace file exists and has reasonable size.
  result.traceType = ttMcrTrace
  if not fileExists(path):
    result.errors.add("File not found: " & path)
    return
  let size = getFileSize(path)
  if size < 100:
    result.errors.add(
      "Trace file suspiciously small (" &
      $size & " bytes)")
  else:
    result.eventCount = 1  # We know events exist based on file size
    result.valid = true

proc verifyTraceDirectory(path: string): VerifyResult =
  ## Verify a directory containing traces or span manifests.
  result.traceType = ttTraceDirectory
  var traceCount = 0

  # Check for span manifest with HTTP requests
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
    printJsonTrace(opts.path, opts)
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
