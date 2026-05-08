## ct print -- Print trace events in human-readable format.
##
## Auto-detects the trace type:
## - `.ct` containers: materialized DB traces and MCR replay traces alike are
##   stored in CTFS containers; `ct print` shows summary info and delegates
##   detailed event analysis to `ct-mcr` / `ct-print` companion tools.
## - JSONL span manifests: parses and pretty-prints HTTP requests
## - Trace directories: scans for trace files within
##
## Legacy 3-file materialized traces (trace.bin / trace.json +
## trace_metadata.json + trace_paths.json) are no longer accepted — those
## bundles must be regenerated as `.ct` containers per the CTFS migration.

import
  std/[os, json, strutils, strformat, options]

type
  TraceType* = enum
    ttUnknown
    ttMcrTrace       ## MCR .ct file
    ttMaterialized   ## Legacy materialized trace (no longer supported by readers)
    ttSpanManifest   ## JSONL span manifest (session_manifest.jsonl, codetracer_spans.jsonl)
    ttTraceDirectory ## Directory containing trace files

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
  if fileExists(path / "trace.bin") or fileExists(path / "trace.json") or
      fileExists(path / "trace_metadata.json"):
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

proc printMaterializedTrace(path: string, opts: PrintOptions) =
  ## Stub: legacy 3-file materialized traces (trace.bin / trace.json +
  ## trace_metadata.json + trace_paths.json) are no longer supported.
  ## Materialized traces now live in `.ct` CTFS containers and are printed
  ## via `printMcrTrace`. This stub stays around so detection of legacy
  ## artefacts produces a helpful migration message rather than silently
  ## walking nonexistent files.
  discard opts
  echo fmt"Legacy materialized trace detected at: {path}"
  echo "  Legacy 3-file bundles (trace.bin / trace.json + trace_metadata.json"
  echo "  + trace_paths.json) are no longer accepted; the trace must be"
  echo "  regenerated as a CTFS `.ct` container (see"
  echo "  codetracer-specs/Trace-Files/CTFS-Migration-Guide.md)."

proc printMcrTrace(path: string, opts: PrintOptions) =
  ## Print info about an MCR .ct trace file.
  echo fmt"MCR trace: {path}"
  let size = getFileSize(path)
  echo fmt"  Size: {size} bytes ({size div 1024} KB)"
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
