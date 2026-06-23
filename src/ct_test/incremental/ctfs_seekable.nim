## In-process, seekable executed-function reader for modern CTFS `.ct` bundles
## — the M1 deliverable of the Incremental-Test-Runner campaign.
##
## # What this replaces
##
## M12 (`ctfs_trace.nim`) read a test's executed-function set by shelling out to
## `ct-print --json-events <.ct>`, which dumps the ENTIRE trace — paths,
## functions, calls, steps AND value payloads — as one JSON array, then parsed
## all of it just to collect the functions named by `call` records.  That paid
## for the whole step+value stream (the far larger part of a trace) and a
## subprocess + JSON round-trip on every read.
##
## This module does the production read the M12 header always documented as the
## target: it links `codetracer-trace-format-nim`'s seekable `NewTraceReader`
## directly and reads ONLY:
##
##   * the **function interning table** (`funcs.dat`/`funcs.off`, loaded eagerly
##     at open) — `function_id → name`; and
##   * the **dedicated call stream** (`calls.dat` + `calls.idx`, M17a) — the
##     `function_id` of every call record, read seekably one chunk at a time.
##
## The executed-function SET is exactly the distinct functions named by `call`
## records, mapped through the function table — IDENTICAL to what
## `ct-print --json-events` yields, but WITHOUT dumping or parsing the step or
## value streams and WITHOUT a subprocess.
##
## This matches the db-backend's Rust `SeekableCallStream`
## (`db-backend/src/ctfs_trace_reader/call_stream_source.rs`): the `calls.dat`
## stream (M17a) exists precisely so the call tree "load[s] independently … no
## step scanning needed".  The Nim `CallStreamReader`
## (`codetracer_trace_writer/call_stream.nim`) reads the SAME chunked
## `calls.dat`/`calls.idx` wire format the Rust reader does.
##
## # Best-effort def-file / def-line (the source hasher's inputs)
##
## The `tbSourceCtfs` engine backend hashes a function's identity from its
## SOURCE TEXT (`engine.shallowHashOfDepSource`), located by `dep.file` +
## `dep.defLine`.  The function interning table carries only the name, so the
## definition site must — exactly as the M12 `ct-print` path did — come from the
## STEP at the function's first call's `entry_step` (its entry/definition site
## for these interpreted recorders).
##
## Resolving that line requires reading the step at `entry_step`.  We do NOT
## scan the whole step stream for it: `stepAbsoluteGlobalLineIndex(entryStep)`
## SEEKS to the single `steps.dat` chunk that holds that one step (bounded
## decompression — see `NewTraceReader.execChunkDecompressions`), and we resolve
## its `(path_id, line)` with the same `buildGliFromMeta` / `resolveGli` global
## line index `ct-print --json-events` uses, so the resolved file/line are
## byte-for-byte what the subprocess produced.  The **value stream is never
## touched** on any path here (`valueStreamLoaded` stays false).
##
## When def-line resolution is disabled (`resolveDefLines = false`) — or when a
## step read fails — `file` is `""` and `defLine` is `0`, the SAME documented
## best-effort fallback M12 used.  The executed NAME is always present (the only
## field strictly needed for the dependency SET); def-file/line is best-effort.
##
## # Errors ⇒ re-run, never skip
##
## Any problem (bundle unreadable, no call stream, malformed records) is an
## `Err`.  The engine turns that into a RE-RUN; a CTFS read error can never
## produce a skip.  `hasCallStream` distinguishes a modern split-stream bundle
## (handled here) from a legacy one the caller must route to the `ct-print`
## fallback.

import std/[algorithm, tables]
import results

import codetracer_trace_writer/new_trace_reader
import codetracer_ct_print_lib  # buildGliFromMeta, resolveGli (shared GLI helpers)

import trace_reader  # ExecutedFunction

export results

type
  SeekableReadStats* = object
    ## Observable instrumentation for the M1 "skips steps and values" proof.
    ## Captured by `readExecutedFunctionsSeekableInstrumented` from the live
    ## `NewTraceReader` after the read completes.
    valueStreamLoaded*: bool
      ## Whether the value stream reader was ever initialized.  MUST stay
      ## false: this read never needs recorded variable values.
    execStreamLoaded*: bool
      ## Whether the exec (steps) stream reader was initialized.  False on the
      ## name-only path; true (but BOUNDED) when def-line resolution sought the
      ## call-entry steps.
    execChunkDecompressions*: uint64
      ## Distinct `steps.dat` chunks inflated.  Bounded by the number of
      ## distinct call-entry chunks, NEVER the whole step stream.
    callCount*: uint64
      ## Total call records read from `calls.dat`.

proc hasCallStream*(reader: NewTraceReader): bool =
  ## True iff this bundle carries the dedicated M17a `calls.dat` call stream
  ## (its `meta.dat` `has_call_stream` flag is set).  When false the bundle is
  ## a legacy unified-stream `.ct` whose call tree is interleaved in the step
  ## stream; the caller routes those to the `ct-print` fallback rather than
  ## scanning steps here.
  reader.meta.hasCallStream

proc buildExecutedFunctions(reader: var NewTraceReader; resolveDefLines: bool):
    Result[seq[ExecutedFunction], string] =
  ## Core read: build the de-duplicated, name-sorted executed-function set from
  ## the call stream + function table.  When `resolveDefLines` is set, resolve
  ## each distinct function's source file + definition line (best-effort) from
  ## the step at its FIRST call's `entryStep`, via a targeted seekable step read.
  let ccRes = reader.callCount()
  if ccRes.isErr:
    return err("failed to read call count: " & ccRes.error)
  let callCount = ccRes.value

  # Build the GLI only if we will resolve def-lines (it depends solely on
  # meta.dat paths, so it is cheap and reads no streams).
  let gli =
    if resolveDefLines: buildGliFromMeta(reader.meta)
    else: default(typeof(buildGliFromMeta(reader.meta)))

  # First call per distinct function id determines its definition site (the
  # earliest entry, mirroring ct-print emitting the entry step at call order).
  var firstEntryStep = initTable[uint64, uint64]()
  var orderedIds: seq[uint64] = @[]

  for i in 0'u64 ..< callCount:
    let cRes = reader.call(i)
    if cRes.isErr:
      return err("failed to read call record " & $i & ": " & cRes.error)
    let fid = cRes.value.functionId
    if not firstEntryStep.hasKey(fid):
      firstEntryStep[fid] = cRes.value.entryStep
      orderedIds.add fid

  var resultSeq: seq[ExecutedFunction] = @[]
  for fid in orderedIds:
    let nameRes = reader.function(fid)
    if nameRes.isErr:
      # A call we cannot name contributes no trackable dependency (no name to
      # hash); skip it rather than fail the whole read — the safe analogue of
      # the M12 reader's "drop the unnameable call" handling.
      continue
    let name = nameRes.value
    if name.len == 0:
      continue

    var file = ""
    var defLine = 0
    if resolveDefLines:
      # Targeted seekable step read: resolve ONLY the step at this function's
      # first-call entry. `stepAbsoluteGlobalLineIndex` inflates only the one
      # `steps.dat` chunk that holds it (bounded decompression), never the
      # whole stream; the value stream is never touched.
      let es = firstEntryStep[fid]
      let gliRes = reader.stepAbsoluteGlobalLineIndex(es)
      if gliRes.isOk:
        # Resolve the step's absolute global_position_index to (file, line).
        # COLUMN-AWARE traces (e.g. the production Python recorder's bundles)
        # encode the GLI as a byte offset (cumulative line_lengths), so the
        # line-count-based `resolveGli` returns garbage on them — they MUST go
        # through the spec-canonical `decodeGlobalPositionIndex`.  Line-only
        # traces use `resolveGli`.  This mirrors ct-print's `resolveStepLocation`
        # exactly, so the resolved file/line match `ct-print --json-events`.
        var fileId = 0
        var line = 0'u64
        var resolved = false
        if reader.meta.hasColumnAwareSteps:
          let posRes = reader.decodeGlobalPositionIndex(gliRes.value)
          if posRes.isOk:
            fileId = int(posRes.value.file)
            line = uint64(posRes.value.line)
            resolved = true
        if not resolved:
          (fileId, line) = resolveGli(gli, gliRes.value)
        let pRes = reader.path(uint64(fileId))
        if pRes.isOk:
          file = pRes.value
          defLine = int(line)
      # On any failure leave file=""/defLine=0 — the documented best-effort gap.

    resultSeq.add ExecutedFunction(name: name, file: file, defLine: defLine)

  if resultSeq.len == 0:
    return err("CTFS bundle has no executed (called) functions")

  # Name-sorted, matching the M12 reader's deterministic output order.
  resultSeq.sort(proc (a, b: ExecutedFunction): int = cmp(a.name, b.name))
  ok(resultSeq)

proc readExecutedFunctionsSeekable*(ctFile: string;
    resolveDefLines: bool = true): Result[seq[ExecutedFunction], string] =
  ## Read the executed-function set from a modern split-stream CTFS `.ct` file
  ## IN-PROCESS over the seekable call stream + function table.
  ##
  ## `ctFile` MUST be a `.ct` file path (the caller resolves a trace dir to its
  ## single bundle).  Returns an `Err` when the bundle is unreadable, when it
  ## carries no dedicated call stream (a legacy bundle — the caller falls back
  ## to `ct-print`), or when a call/func record is malformed.
  ##
  ## With `resolveDefLines` (the default), each executed function's source file
  ## and definition line are resolved best-effort from its first call's entry
  ## step via a TARGETED seekable step read; the value stream is never read.
  ## With `resolveDefLines = false` only the NAME set is produced (file=""/
  ## defLine=0) and the step stream is never opened at all.
  let openRes = openNewTrace(ctFile)
  if openRes.isErr:
    return err("failed to open CTFS bundle " & ctFile & ": " & openRes.error)
  var reader = openRes.value
  if not reader.hasCallStream():
    return err("CTFS bundle " & ctFile &
      " carries no dedicated call stream (legacy unified-stream bundle); " &
      "route to the ct-print fallback")
  buildExecutedFunctions(reader, resolveDefLines)

proc readExecutedFunctionsSeekableInstrumented*(ctFile: string;
    resolveDefLines: bool = true):
    Result[tuple[functions: seq[ExecutedFunction], stats: SeekableReadStats],
      string] =
  ## Test-facing variant of `readExecutedFunctionsSeekable` that ALSO returns
  ## the live reader's stream-load instrumentation, so a test can PROVE the read
  ## never touched the value stream and only sought a bounded slice of the step
  ## stream.  Behaviourally identical to `readExecutedFunctionsSeekable` for the
  ## function set it returns.
  let openRes = openNewTrace(ctFile)
  if openRes.isErr:
    return err("failed to open CTFS bundle " & ctFile & ": " & openRes.error)
  var reader = openRes.value
  if not reader.hasCallStream():
    return err("CTFS bundle " & ctFile &
      " carries no dedicated call stream (legacy unified-stream bundle); " &
      "route to the ct-print fallback")
  let funcsRes = buildExecutedFunctions(reader, resolveDefLines)
  if funcsRes.isErr:
    return err(funcsRes.error)
  let cc = reader.callCount()
  let stats = SeekableReadStats(
    valueStreamLoaded: reader.valueStreamLoaded(),
    execStreamLoaded: reader.execStreamLoaded(),
    execChunkDecompressions: reader.execChunkDecompressions(),
    callCount: if cc.isOk: cc.value else: 0'u64)
  ok((functions: funcsRes.value, stats: stats))
