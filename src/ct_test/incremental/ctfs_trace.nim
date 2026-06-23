## CTFS `.ct` dependency discovery — the M12 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign (Phase 3).
##
## Phase 1/2 read the *legacy* CodeTracer trace forms: the 3-file JSON
## (`trace.json` + `trace_paths.json`, `trace_reader.nim`) and a hand-crafted
## native calltrace projection (`native_trace.nim`). M12 makes the engine read
## the **modern CTFS `.ct` bundle** — the binary container the native recorders
## (and the native Ruby recorder) actually emit.
##
## # The modern CTFS event-dump format (CONFIRMED against a real `.ct`)
##
## CTFS is a binary container; `codetracer-trace-format-nim` ships a reader and a
## `ct-print` tool that dumps a bundle's events. `ct-print --json-events <.ct>`
## emits a JSON **array** of `type`-tagged objects (NOT the legacy
## externally-tagged `{"Function": {...}}` form). The records this reader needs:
##
##   * `{"type":"path","path_id":N,"name":"<file>"}` — interns a source path.
##   * `{"type":"function","function_id":N,"name":"<fnname>"}` — the function
##     table, keyed by `function_id`. NOTE: on an interpreted (Ruby) bundle the
##     `function` record carries ONLY `function_id` + `name` — there is no source
##     line on it, so the definition line must come from elsewhere (see below).
##   * `{"type":"call","function_id":N,"function":"<name>","entry_step":S,...}` —
##     a call to function `function_id`. The executed-function SET is exactly the
##     set of functions referenced by `call` records.
##   * `{"type":"step","step_index":S,"path_id":P,"line":L,"path":"<file>",
##     "function_id":N,...}` — an executed step. Used (best-effort) to resolve a
##     called function's source FILE and definition LINE: the step at a call's
##     `entry_step` carries the function's entry `path`/`line`, which for these
##     recorders is the function's definition site.
##   * `{"type":"value"/"type"/"varname",...}` — skipped (not needed for the
##     executed-function set).
##
## Executed functions = the distinct functions named by `call` records, mapped
## `function_id → function.name`. We additionally resolve, best-effort, each
## executed function's source FILE and definition LINE from the step at the
## call's `entry_step` (its `path`/`line`). When that resolution is unavailable
## the file is "" and the defLine is 0 (the documented best-effort fallback) —
## the executed NAME is always present, which is the only field strictly needed
## for the dependency SET.
##
## # TOLERANT parsing of non-UTF-8 value bytes (IMPORTANT)
##
## `--json-events` embeds recorded `value` payloads as a `data` string that can
## contain RAW NON-UTF-8 bytes (e.g. CBOR-encoded values). The blob as a whole is
## therefore NOT guaranteed to be valid UTF-8, and a strict JSON parser will
## reject it. This reader reads the subprocess output as RAW BYTES and sanitizes
## it to valid UTF-8 (every byte that is not part of a well-formed UTF-8 sequence
## is replaced with the U+FFFD replacement character) BEFORE handing it to
## `std/json`. The replacement only ever touches bytes inside `value`/`data`
## strings (the structural `path`/`function`/`call`/`step` records are pure
## ASCII), so the records this reader cares about are never corrupted. This is
## the documented tolerant-parsing strategy: never assume the dump is clean
## UTF-8.
##
## # `ct-print` resolution (DOCUMENTED)
##
## This prototype reads CTFS via the `ct-print --json-events` SUBPROCESS. The
## PRODUCTION path is to link `codetracer-trace-format-nim`'s reader
## (`codetracer_trace_reader` / `codetracer_ct_print_lib`) directly and read the
## CTFS in-process — no subprocess, no JSON round-trip. The subprocess is the
## documented prototype stand-in (it avoids pulling the trace-format-nim build —
## libzstd flags, its module tree — into the engine's build for the
## prototype). `ct-print` is resolved in this order:
##
##   1. the `CT_PRINT` environment variable, if it points at an executable file;
##   2. a `ct-print` on `PATH`;
##   3. a known build path: `/tmp/ctprint_build/ct-print` (the location the M12
##      test setup builds it into).
##
## If `ct-print` cannot be resolved, or the bundle cannot be read, the reader
## returns an `Err` — so the engine RE-RUNS (never silently skips). A CTFS read
## error can therefore NEVER yield a skip.

import std/[json, os, osproc, algorithm, tables, strutils]
import results

import trace_reader  # ExecutedFunction

export results

const
  CtPrintEnvVar* = "CT_PRINT"
    ## Environment variable that, if set to an executable path, overrides
    ## `ct-print` resolution (highest precedence).
  CtPrintExeName* = "ct-print"
    ## The `ct-print` executable name searched on `PATH`.
  CtPrintKnownBuildPath* = "/tmp/ctprint_build/ct-print"
    ## The known build path the M12 test setup builds `ct-print` into; used as a
    ## last-resort fallback so the tests can run without `CT_PRINT`/`PATH` set.
  CtfsExtension* = ".ct"
    ## A CTFS bundle file extension.

proc resolveCtPrint*(): Result[string, string] =
  ## Resolve the `ct-print` executable, in the documented precedence order:
  ## `CT_PRINT` env var → `PATH` → the known build path. Returns the resolved
  ## absolute-or-relative path, or an `Err` listing where it was looked for.
  let envPath = getEnv(CtPrintEnvVar)
  if envPath.len > 0:
    if fileExists(envPath):
      return ok(envPath)
    return err("CT_PRINT points at a non-existent file: " & envPath)
  let onPath = findExe(CtPrintExeName)
  if onPath.len > 0:
    return ok(onPath)
  if fileExists(CtPrintKnownBuildPath):
    return ok(CtPrintKnownBuildPath)
  err("ct-print not found: set $" & CtPrintEnvVar &
    ", put '" & CtPrintExeName & "' on PATH, or build it into " &
    CtPrintKnownBuildPath)

proc resolveCtBundle*(traceDirOrCtFile: string): Result[string, string] =
  ## Resolve the `.ct` bundle to read. Accepts EITHER:
  ##   * a path to a `.ct` file directly (used as-is), OR
  ##   * a trace DIRECTORY that contains exactly one `*.ct` bundle.
  ## A directory with no `.ct`, or more than one, is an `Err` (ambiguous ⇒
  ## re-run, never a guess). A non-existent path is an `Err`.
  if fileExists(traceDirOrCtFile) and
      traceDirOrCtFile.toLowerAscii().endsWith(CtfsExtension):
    return ok(traceDirOrCtFile)
  if dirExists(traceDirOrCtFile):
    var found: seq[string]
    for kind, path in walkDir(traceDirOrCtFile):
      if kind in {pcFile, pcLinkToFile} and
          path.toLowerAscii().endsWith(CtfsExtension):
        found.add path
    if found.len == 0:
      return err("no " & CtfsExtension & " bundle found in: " & traceDirOrCtFile)
    if found.len > 1:
      found.sort()
      return err("multiple " & CtfsExtension & " bundles in " &
        traceDirOrCtFile & " (ambiguous): " & found.join(", "))
    return ok(found[0])
  err("CTFS path not found (no such file or directory): " & traceDirOrCtFile)

proc sanitizeToUtf8*(raw: string): string =
  ## Replace every byte that is not part of a well-formed UTF-8 sequence with the
  ## U+FFFD replacement character (encoded as the 3 bytes 0xEF 0xBF 0xBD), so the
  ## result is valid UTF-8 that `std/json` accepts. Well-formed multi-byte
  ## sequences (including the structural ASCII records) pass through unchanged;
  ## only the raw non-UTF-8 bytes inside recorded `value`/`data` strings are
  ## rewritten. This is the documented tolerant-parsing step (the dump is NOT
  ## guaranteed to be clean UTF-8).
  ##
  ## The decoder follows the Unicode well-formed-UTF-8 byte-sequence table
  ## (RFC 3629 / Unicode §3.9, Table 3-7): it validates lead-byte ranges,
  ## continuation-byte ranges, and the tighter bounds that exclude overlong
  ## encodings, surrogate code points (U+D800..U+DFFF), and code points above
  ## U+10FFFF. Any byte that does not start or continue a valid sequence is
  ## replaced; on a malformed sequence we advance exactly one byte (so the next
  ## byte gets a fresh chance) — the standard "replace and resync by one byte"
  ## recovery.
  const Repl = "\xEF\xBF\xBD"  # U+FFFD encoded in UTF-8
  result = newStringOfCap(raw.len)
  var i = 0
  let n = raw.len
  template b(k: int): int = raw[k].ord
  while i < n:
    let c0 = b(i)
    if c0 < 0x80:
      # ASCII fast path.
      result.add raw[i]
      inc i
    elif c0 in 0xC2 .. 0xDF:
      # 2-byte sequence: C2..DF 80..BF (C0/C1 would be overlong).
      if i + 1 < n and b(i+1) in 0x80 .. 0xBF:
        result.add raw[i]; result.add raw[i+1]
        i += 2
      else:
        result.add Repl; inc i
    elif c0 in 0xE0 .. 0xEF:
      # 3-byte sequence with the per-lead-byte continuation bounds that exclude
      # overlong encodings (E0 A0..BF) and surrogates (ED 80..9F).
      let lo1 =
        if c0 == 0xE0: 0xA0
        elif c0 == 0xED: 0x80
        else: 0x80
      let hi1 =
        if c0 == 0xED: 0x9F
        else: 0xBF
      if i + 2 < n and b(i+1) in lo1 .. hi1 and b(i+2) in 0x80 .. 0xBF:
        result.add raw[i]; result.add raw[i+1]; result.add raw[i+2]
        i += 3
      else:
        result.add Repl; inc i
    elif c0 in 0xF0 .. 0xF4:
      # 4-byte sequence with the bounds that exclude overlong (F0 90..BF) and
      # > U+10FFFF (F4 80..8F).
      let lo1 =
        if c0 == 0xF0: 0x90
        elif c0 == 0xF4: 0x80
        else: 0x80
      let hi1 =
        if c0 == 0xF4: 0x8F
        else: 0xBF
      if i + 3 < n and b(i+1) in lo1 .. hi1 and
          b(i+2) in 0x80 .. 0xBF and b(i+3) in 0x80 .. 0xBF:
        result.add raw[i]; result.add raw[i+1]
        result.add raw[i+2]; result.add raw[i+3]
        i += 4
      else:
        result.add Repl; inc i
    else:
      # Invalid lead byte (0x80..0xC1, 0xF5..0xFF): replace and advance one byte.
      result.add Repl; inc i

proc runCtPrintJsonEvents(ctPrint, bundle: string): Result[string, string] =
  ## Run `ct-print --json-events <bundle>` and return the RAW stdout bytes. A
  ## non-zero exit (or a failure to launch) is an `Err` (⇒ re-run upstream).
  var output: string
  var code: int
  try:
    (output, code) = execCmdEx(
      quoteShell(ctPrint) & " --json-events " & quoteShell(bundle))
  except CatchableError as e:
    return err("failed to run ct-print: " & e.msg)
  except Exception as e:
    # osproc can raise OSError/IOError variants on a broken launch; never crash.
    return err("failed to run ct-print: " & e.msg)
  if code != 0:
    return err("ct-print exited with code " & $code &
      " on " & bundle & ":\n" & output)
  ok(output)

proc ctfsHasCallStream*(traceDirOrCtFile: string): Result[bool, string] =
  ## M17a: report whether the bundle carries a DEDICATED `calls.dat` call
  ## stream — i.e. whether its `meta.dat` has the `has_call_stream` capability
  ## flag (bit 8) set.  Probes `ct-print --meta-json` (the metadata-only fast
  ## path; it does NOT decode the event streams) and reads
  ## `metadata.flags.has_call_stream`.
  ##
  ## When true, the engine PREFERS the dedicated call stream for executed-
  ## function discovery: the call tree is split out of the unified step/value
  ## stream, so reading it does not require scanning the (far larger) step
  ## stream.  When false (a legacy bundle), discovery falls back to the unified
  ## stream.  EITHER WAY the executed SET is identical — the split is purely a
  ## storage/locality optimisation (the call records are derived from the same
  ## Call/Return events).  A missing/old `ct-print`, or a flag field absent from
  ## the JSON, yields `ok(false)` (treat as legacy), never a crash; a failed
  ## subprocess launch is an `Err` (⇒ re-run upstream, never a silent skip).
  let bundleRes = resolveCtBundle(traceDirOrCtFile)
  if bundleRes.isErr:
    return err(bundleRes.error)
  let bundle = bundleRes.value
  let ctPrintRes = resolveCtPrint()
  if ctPrintRes.isErr:
    return err(ctPrintRes.error)
  var output: string
  var code: int
  try:
    (output, code) = execCmdEx(
      quoteShell(ctPrintRes.value) & " --meta-json " & quoteShell(bundle))
  except CatchableError as e:
    return err("failed to run ct-print --meta-json: " & e.msg)
  except Exception as e:
    return err("failed to run ct-print --meta-json: " & e.msg)
  if code != 0:
    return err("ct-print --meta-json exited with code " & $code &
      " on " & bundle & ":\n" & output)
  # --meta-json output is pure ASCII (metadata only, no value bytes), so a
  # straight std/json parse is safe here.
  var root: JsonNode
  try:
    root = parseJson(output)
  except CatchableError as e:
    return err("malformed ct-print --meta-json for " & bundle & ": " & e.msg)
  if root.kind == JObject and root.hasKey("metadata") and
      root["metadata"].kind == JObject and root["metadata"].hasKey("flags") and
      root["metadata"]["flags"].kind == JObject and
      root["metadata"]["flags"].hasKey("has_call_stream") and
      root["metadata"]["flags"]["has_call_stream"].kind == JBool:
    return ok(root["metadata"]["flags"]["has_call_stream"].getBool())
  # Older ct-print that does not surface the flag ⇒ treat as legacy (no split).
  ok(false)

func extractFromEvents(root: JsonNode): Result[seq[ExecutedFunction], string] =
  ## Parse the modern `type`-tagged event array into the executed-function set.
  ##
  ## Strategy:
  ##   1. Build the function table `function_id → name` from `function` records.
  ##   2. Build a `step_index → (path, line)` map from `step` records (best-effort
  ##      file/defLine resolution).
  ##   3. For each `call` record, mark `function_id` executed and resolve its
  ##      source file/defLine from the step at the call's `entry_step` (the
  ##      function's entry/definition site for these recorders).
  ##   4. Return the de-duplicated, name-sorted executed set.
  ##
  ## The reader is TOLERANT of records it does not recognise and of optional
  ## fields being absent: only `function`/`call` records are required for the
  ## SET; `step`/`entry_step` enrich file+defLine best-effort. A `call` may carry
  ## the resolved name inline (`"function"`), which we prefer; otherwise the name
  ## comes from the function table via `function_id`.
  if root.kind != JArray:
    return err("ct-print --json-events output must be a JSON array")

  var functionTable = initTable[int, string]()
  var stepInfo = initTable[int, (string, int)]()  # step_index -> (path, line)

  # First pass: function table + step info.
  for ev in root.elems:
    if ev.kind != JObject or not ev.hasKey("type") or
        ev["type"].kind != JString:
      continue  # tolerate malformed/foreign records
    case ev["type"].getStr()
    of "function":
      if ev.hasKey("function_id") and ev["function_id"].kind == JInt and
          ev.hasKey("name") and ev["name"].kind == JString:
        functionTable[int(ev["function_id"].getBiggestInt())] =
          ev["name"].getStr()
    of "step":
      if ev.hasKey("step_index") and ev["step_index"].kind == JInt:
        let si = int(ev["step_index"].getBiggestInt())
        var p = ""
        var ln = 0
        if ev.hasKey("path") and ev["path"].kind == JString:
          p = ev["path"].getStr()
        if ev.hasKey("line") and ev["line"].kind == JInt:
          ln = int(ev["line"].getBiggestInt())
        stepInfo[si] = (p, ln)
    else:
      discard

  # Second pass: the executed set from `call` records, enriched best-effort.
  var seen = initTable[string, bool]()
  var resultSeq: seq[ExecutedFunction] = @[]
  for ev in root.elems:
    if ev.kind != JObject or not ev.hasKey("type") or
        ev["type"].kind != JString or ev["type"].getStr() != "call":
      continue
    # Resolve the executed function NAME: prefer the inline `function` name, else
    # the function table via `function_id`.
    var name = ""
    if ev.hasKey("function") and ev["function"].kind == JString:
      name = ev["function"].getStr()
    elif ev.hasKey("function_id") and ev["function_id"].kind == JInt:
      let fid = int(ev["function_id"].getBiggestInt())
      if functionTable.hasKey(fid):
        name = functionTable[fid]
    if name.len == 0:
      # A call we cannot name: skip it rather than fail the whole read. It cannot
      # contribute a trackable dependency (no name to hash), so dropping it is
      # the safe analogue of native_trace's "??" handling.
      continue
    # Best-effort file + defLine from the entry step.
    var file = ""
    var defLine = 0
    if ev.hasKey("entry_step") and ev["entry_step"].kind == JInt:
      let es = int(ev["entry_step"].getBiggestInt())
      if stepInfo.hasKey(es):
        (file, defLine) = stepInfo[es]
    if not seen.hasKeyOrPut(name, true):
      resultSeq.add ExecutedFunction(name: name, file: file, defLine: defLine)

  if resultSeq.len == 0:
    return err("CTFS bundle has no executed (called) functions")

  resultSeq.sort(proc (a, b: ExecutedFunction): int = cmp(a.name, b.name))
  ok(resultSeq)

proc readExecutedFunctionsCtfs*(traceDirOrCtFile: string):
    Result[seq[ExecutedFunction], string] =
  ## The CTFS `DependencyDiscovery` implementation: read the executed-function
  ## SET from a modern CTFS `.ct` bundle, via the `ct-print --json-events`
  ## subprocess (the documented prototype stand-in for linking
  ## `codetracer-trace-format-nim`'s reader directly).
  ##
  ## `traceDirOrCtFile` may be a `.ct` file or a directory containing one.
  ##
  ## Returns the de-duplicated, name-sorted executed set; each `ExecutedFunction`
  ## carries the function `name`, and (best-effort) its source `file` and
  ## definition `defLine` resolved from the call's entry step. Names are always
  ## present; file/defLine may be ""/0 when the bundle does not carry them.
  ##
  ## Any problem — `ct-print` unavailable, bundle unresolvable/unreadable, the
  ## subprocess failing, or malformed output — yields an `Err`. The engine turns
  ## that into a re-run; a CTFS read error can NEVER produce a skip.
  let bundleRes = resolveCtBundle(traceDirOrCtFile)
  if bundleRes.isErr:
    return err(bundleRes.error)
  let bundle = bundleRes.value
  let ctPrintRes = resolveCtPrint()
  if ctPrintRes.isErr:
    return err(ctPrintRes.error)
  let runRes = runCtPrintJsonEvents(ctPrintRes.value, bundle)
  if runRes.isErr:
    return err(runRes.error)
  # Tolerant parse: sanitize non-UTF-8 value bytes, then parse with std/json.
  let cleaned = sanitizeToUtf8(runRes.value)
  var root: JsonNode
  try:
    root = parseJson(cleaned)
  except CatchableError as e:
    return err("malformed ct-print JSON for " & bundle & ": " & e.msg)
  extractFromEvents(root)
