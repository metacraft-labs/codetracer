## VENDORED from reprobuild's proven incremental-testing engine.
## Provenance: /Users/zahary/m/dev/reprobuild/libs/repro_ct_incremental/src/repro_ct_incremental/trace_reader.nim
## (Trace-Based-Incremental-Testing campaign, milestone M18 productionisation.)
##
## This is a CLEAN VENDOR (not a fork): the algorithm is byte-for-byte the
## reprobuild prototype's. Keep the two copies in sync — if you change the
## decision/hash logic here, mirror it in the reprobuild source above and vice
## versa. See codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md
## §16.7 for the authoritative specification.
##
## Reader for CodeTracer JSON traces — the M0 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign.
##
## It reads the *executed functions* of a recorded run: the set of
## `Function` records that are referenced by at least one `Call` record in
## the trace. That set is exactly the "runtime dependency" set §16.7.2 of
## `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md`
## describes — the functions a test actually executed.
##
## # Trace schema (confirmed, not invented)
##
## The reader targets the JSON trace form
## (`trace.json` + `trace_paths.json` + `trace_metadata.json`) produced by
## `serde_json::to_string(&Vec<TraceLowLevelEvent>)` in
## `codetracer-trace-format` (`codetracer_trace_writer`,
## `non_streaming_trace_writer.rs`). The `TraceLowLevelEvent` enum carries no
## serde container attribute, so serde's default *externally-tagged*
## representation applies.
##
## `trace.json` is a JSON **array** of events; each event is a single-key
## object `{"<VariantName>": <payload>}`. The variants this reader needs:
##
## * `{"Path": "<string>"}` — interns a source path. Paths appear in the same
##   order as the entries in `trace_paths.json`; the 0-based ordinal of a
##   `Path` event is its `path_id`.
## * `{"Function": {"path_id": <int>, "line": <int>, "name": "<str>"}}` —
##   a function-table entry. The 0-based ordinal of a `Function` event is its
##   `function_id`. `path_id` indexes `trace_paths.json` (and equivalently the
##   `Path` stream). `line` is the definition line (1-based, as CodeTracer
##   records it). The newtype wrappers `PathId(usize)`, `Line(i64)` and
##   `FunctionId(usize)` all serialize as bare integers (serde transparent /
##   newtype-struct default).
## * `{"Call": {"function_id": <int>, "args": [...]}}` — a call to the
##   function-table entry at index `function_id`.
##
## `trace_paths.json` is a JSON array of strings (the interned paths, index =
## `path_id`).
##
## This module deliberately depends only on `std/json` — no CTFS binary
## parsing and no `codetracer-trace-format-nim` dependency (that is a later
## milestone). All malformed input is reported as `Err`, never a crash.

import std/[json, os, algorithm, tables]
import results

export results

type
  ExecutedFunction* = object
    ## A function that was executed (called) at least once in the trace.
    name*: string   ## Function name as recorded by the recorder.
    file*: string   ## Source file path resolved via `path_id`.
    defLine*: int   ## 1-based definition line of the function.

const
  TraceEventsFile* = "trace.json"
  TracePathsFile* = "trace_paths.json"

func cmpExecutedFunction(a, b: ExecutedFunction): int =
  ## Total order used to produce the deterministic, name-sorted output.
  ## Primary key is the name; `file` and `defLine` break ties so that two
  ## distinct functions that happen to share a name (e.g. methods in
  ## different files) keep a stable, reproducible order.
  result = cmp(a.name, b.name)
  if result == 0:
    result = cmp(a.file, b.file)
  if result == 0:
    result = cmp(a.defLine, b.defLine)

proc readPaths(tracePathsPath: string): Result[seq[string], string] =
  ## Parse `trace_paths.json` into the `path_id`-indexed path table.
  if not fileExists(tracePathsPath):
    return err("trace paths file not found: " & tracePathsPath)
  var raw: string
  try:
    raw = readFile(tracePathsPath)
  except CatchableError as e:
    return err("failed to read " & tracePathsPath & ": " & e.msg)
  var node: JsonNode
  try:
    node = parseJson(raw)
  except CatchableError as e:
    return err("malformed JSON in " & tracePathsPath & ": " & e.msg)
  if node.kind != JArray:
    return err(TracePathsFile & " must be a JSON array of strings")
  var paths = newSeq[string](node.len)
  for i, entry in node.elems:
    if entry.kind != JString:
      return err(TracePathsFile & " entry " & $i & " is not a string")
    paths[i] = entry.getStr()
  ok(paths)

proc getIntField(obj: JsonNode; field: string): Result[int, string] =
  ## Fetch an integer-valued field from a JSON object, tolerating both the
  ## serde-emitted integer form and (defensively) a numeric float form.
  if obj.kind != JObject or not obj.hasKey(field):
    return err("missing field '" & field & "'")
  let v = obj[field]
  case v.kind
  of JInt: ok(int(v.getBiggestInt()))
  of JFloat: ok(int(v.getFloat()))
  else: err("field '" & field & "' is not an integer")

proc readExecutedFunctions*(traceDir: string): Result[seq[ExecutedFunction], string] =
  ## Read `traceDir` (a CodeTracer JSON trace directory) and return the
  ## de-duplicated, name-sorted set of executed functions.
  ##
  ## Executed functions = the `Function` records referenced by `Call` records.
  ## A function defined but never called (e.g. `unused_c` in the M0 fixture)
  ## is *not* included.
  ##
  ## Any structural problem (missing files, malformed JSON, out-of-range
  ## indices, wrong types) yields an `Err` with a human-readable message —
  ## the reader never raises.
  if not dirExists(traceDir):
    return err("trace dir not found: " & traceDir)

  let pathsRes = readPaths(traceDir / TracePathsFile)
  if pathsRes.isErr:
    return err(pathsRes.error)
  let paths = pathsRes.value

  let eventsPath = traceDir / TraceEventsFile
  if not fileExists(eventsPath):
    return err("trace events file not found: " & eventsPath)
  var raw: string
  try:
    raw = readFile(eventsPath)
  except CatchableError as e:
    return err("failed to read " & eventsPath & ": " & e.msg)
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed JSON in " & eventsPath & ": " & e.msg)
  if root.kind != JArray:
    return err(TraceEventsFile & " must be a JSON array of events")

  # First pass: build the function table (function_id -> FunctionRecord) in
  # the order the `Function` events appear, exactly as the recorder assigns
  # ids. We also collect which function_ids were actually called.
  var functionTable: seq[ExecutedFunction] = @[]
  var called = initTable[int, bool]()

  for idx, event in root.elems:
    if event.kind != JObject:
      return err("event " & $idx & " is not a JSON object")
    if event.len != 1:
      return err("event " & $idx & " must have exactly one variant key")
    # Externally-tagged: the single key is the variant name.
    for variant, payload in event.fields:
      case variant
      of "Function":
        let pathIdRes = getIntField(payload, "path_id")
        if pathIdRes.isErr:
          return err("Function event " & $idx & ": " & pathIdRes.error)
        let lineRes = getIntField(payload, "line")
        if lineRes.isErr:
          return err("Function event " & $idx & ": " & lineRes.error)
        if payload.kind != JObject or not payload.hasKey("name") or
            payload["name"].kind != JString:
          return err("Function event " & $idx & ": missing string 'name'")
        let pathId = pathIdRes.value
        if pathId < 0 or pathId >= paths.len:
          return err("Function event " & $idx & ": path_id " & $pathId &
            " out of range (have " & $paths.len & " paths)")
        functionTable.add ExecutedFunction(
          name: payload["name"].getStr(),
          file: paths[pathId],
          defLine: lineRes.value)
      of "Call":
        let fnIdRes = getIntField(payload, "function_id")
        if fnIdRes.isErr:
          return err("Call event " & $idx & ": " & fnIdRes.error)
        called[fnIdRes.value] = true
      else:
        # Any other event variant (Step, Path, Value, Return, ...) is
        # irrelevant to executed-function discovery and is skipped.
        discard

  # Second pass: resolve called function_ids to their table entries,
  # validating the index, and de-duplicate.
  var seen = initTable[string, bool]()
  var resultSeq: seq[ExecutedFunction] = @[]
  for fnId in called.keys:
    if fnId < 0 or fnId >= functionTable.len:
      return err("Call references function_id " & $fnId &
        " out of range (have " & $functionTable.len & " functions)")
    let fn = functionTable[fnId]
    # De-dup key combines all identity fields so two genuinely different
    # functions are never collapsed.
    let key = fn.name & "\x00" & fn.file & "\x00" & $fn.defLine
    if not seen.hasKeyOrPut(key, true):
      resultSeq.add fn

  resultSeq.sort(cmpExecutedFunction)
  ok(resultSeq)
