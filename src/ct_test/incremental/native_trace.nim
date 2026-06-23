## Native dependency discovery — the M8 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign (Phase 2).
##
## CodeTracer's *native / Multi-Core-Recorder (MCR)* path does NOT emit the
## canonical `Function`/`Call` records the source/interpreted path uses (those
## are read by `trace_reader.readExecutedFunctions`). Instead the executed
## functions come from the native trace's **calltrace**: the MCR/RR emulator
## records flat `CallRecord`s (`tickEnter`, `tickExit`, `callerPc`, `calleePc`)
## while emulating the program, then resolves each `calleePc` to a function name
## via the binary's DWARF (addr2line) when building the hierarchical call tree.
## See the native recorder:
##
##   * `codetracer-native-recorder/ct_emulator/src/ct_emulator/write_log.nim`
##     — `CallRecord {tickEnter, tickExit, callerPc, calleePc}`, the flat
##     call/return stream the emulator appends.
##   * `.../ct_emulator/calltrace_collector.nim` — collects those records during
##     emulation (works for both MCR direct emulation and RR replay).
##   * `.../ct_emulator/calltrace.nim` — `buildCallTree` turns the flat records
##     into a `CallTree` of `CallNode {functionName, sourceFile, sourceLine,
##     calleePc, ...}`, resolving each `calleePc` to a `functionName` with
##     `source_index.resolvePCs` (addr2line over the ELF).
##
## # The native-trace fixture shape (a documented prototype stand-in)
##
## A live MCR/RR run is NOT available in this dev shell (it needs the emulator +
## a recorded process), so — exactly as Phase 1 hand-crafts canonical JSON
## traces in the real `codetracer-trace-format` shape — M8 hand-crafts the
## native calltrace in a JSON shape modeled on the real `CallNode`/`CallRecord`
## structures above. The reader consumes a single file:
##
##   `<traceDir>/native_calltrace.json`
##
## whose shape is a thin, EXPLICITLY-DOCUMENTED JSON projection of the native
## calltrace the recorder produces in memory (there is no canonical on-disk JSON
## form for it upstream yet — the recorder keeps the call tree in memory and the
## persistent write-log is a binary stream — so this JSON is a clearly-labelled
## minimal prototype form, not an invented competing wire format):
##
## ```json
## {
##   "binary": "/abs/or/relative/path/to/the/recorded/executable",
##   "calls": [
##     { "functionName": "used_a", "calleePc": 4096 },
##     { "functionName": "used_b", "calleePc": 4112 },
##     { "functionName": "main",   "calleePc": 4160 }
##   ]
## }
## ```
##
## Mapping to the real native calltrace:
##   * `binary`             ⇐ the ELF/Mach-O the MCR/RR recorder replayed (the
##                            `elfPath` `buildCallTree` resolves PCs against). It
##                            is the OWNING BINARY of every function in `calls`.
##   * `calls[].functionName` ⇐ `CallNode.functionName` (resolved from
##                            `calleePc` via addr2line). This is the
##                            executed-function NAME — the only field the
##                            dependency set needs.
##   * `calls[].calleePc`   ⇐ `CallNode.calleePc` / `CallRecord.calleePc`. Carried
##                            for fidelity/debuggability; the dependency set keys
##                            on the resolved NAME (a real run can have several
##                            PCs resolve to one inlined/duplicated name), so the
##                            reader DE-DUPLICATES by name. `calleePc` is optional.
##
## A real reader would walk the whole `CallTree` (roots + children) collecting
## every node's `functionName`; the executed SET is exactly those names. The flat
## `calls` array here is that same set already flattened — a calltrace's executed
## function set is independent of the tree nesting, so flattening loses nothing
## relevant to dependency discovery.
##
## # The native `ExecutedFunction` convention (DOCUMENTED)
##
## Native dependencies key on (function NAME + owning BINARY), not on a source
## file + definition line (a native function's identity is its compiled
## instruction bytes — spec §16.7.1 — located in the binary by symbol name). So
## the `ExecutedFunction` this reader returns carries:
##
##   * `name`    = the executed function's name (the symbol/DWARF name).
##   * `file`    = the BINARY path (NOT a source path). The native
##                 `ShallowHasher` reads `dep.file` as the binary and calls
##                 `shallowHashNative(dep.file, dep.name)`. Keeping the binary in
##                 `.file` lets the existing cache schema (`{name, file, defLine,
##                 shallow}`) persist native deps with NO schema change — the
##                 binary travels in the same slot a source path would.
##   * `defLine` = 0 (UNUSED for native — there is no source definition line in
##                 instruction-byte identity). Always 0 so the cache is stable.
##
## # Fail-safe invariant (carried over from Phase 1 / M5)
##
## Any structural problem — missing/unreadable `native_calltrace.json`, malformed
## JSON, a non-object root, a missing/empty `binary`, a missing/empty
## `functionName` — yields an `Err`. The engine turns that into a re-run, NEVER a
## silent skip. The reader never raises.

import std/[json, os, algorithm, tables]
import results

import trace_reader      # ExecutedFunction
import native_instrument # instrumentation-flavour native discovery (M14/M15)

export results

const
  NativeCalltraceFile* = "native_calltrace.json"
    ## The hand-crafted native calltrace projection a native trace dir carries
    ## in this prototype (see the module doc for the shape + real-recorder
    ## mapping). A native trace dir is additionally marked by `detectBackend`'s
    ## structural signals (an `rr/` subdir, a `*.ct` container, or a
    ## `trace_db_metadata.json`); this file carries the executed-function payload.

proc nativeTraceBinary*(traceDir: string): Result[string, string] =
  ## Read just the `binary` path the native calltrace references (the owning
  ## executable of every function in the trace). Used by the engine at `decide`
  ## time to rebind cached native deps onto the CURRENT binary (the analogue of
  ## the source path resolving deps under the current `sourceRoot`). Any
  ## structural problem ⇒ `Err` (the engine fail-safes to a re-run).
  if not dirExists(traceDir):
    return err("native trace dir not found: " & traceDir)
  let p = traceDir / NativeCalltraceFile
  if not fileExists(p):
    return err("native calltrace file not found: " & p)
  var raw: string
  try:
    raw = readFile(p)
  except CatchableError as e:
    return err("failed to read " & p & ": " & e.msg)
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed JSON in " & p & ": " & e.msg)
  if root.kind != JObject or not root.hasKey("binary") or
      root["binary"].kind != JString:
    return err(NativeCalltraceFile & " must have a string 'binary' field")
  let binary = root["binary"].getStr()
  if binary.len == 0:
    return err(NativeCalltraceFile & " 'binary' must be non-empty")
  ok(binary)

proc readExecutedFunctionsNative*(traceDir: string):
    Result[seq[ExecutedFunction], string] =
  ## The native `DependencyDiscovery` implementation: read the executed-function
  ## SET from a native trace's calltrace (`<traceDir>/native_calltrace.json`).
  ##
  ## Returns the de-duplicated, name-sorted set of `ExecutedFunction`s, each
  ## carrying the executed function NAME (`name`) and the owning BINARY path
  ## (`file`); `defLine` is always 0 (native deps key on name+binary, not a
  ## source line — see the module doc).
  ##
  ## Any structural problem yields an `Err` (⇒ re-run upstream, never a skip).
  if not dirExists(traceDir):
    return err("native trace dir not found: " & traceDir)
  let p = traceDir / NativeCalltraceFile
  if not fileExists(p):
    return err("native calltrace file not found: " & p)
  var raw: string
  try:
    raw = readFile(p)
  except CatchableError as e:
    return err("failed to read " & p & ": " & e.msg)
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed JSON in " & p & ": " & e.msg)
  if root.kind != JObject:
    return err(NativeCalltraceFile & " root must be a JSON object")
  if not root.hasKey("binary") or root["binary"].kind != JString:
    return err(NativeCalltraceFile & " must have a string 'binary' field")
  let binary = root["binary"].getStr()
  if binary.len == 0:
    return err(NativeCalltraceFile & " 'binary' must be non-empty")
  if not root.hasKey("calls") or root["calls"].kind != JArray:
    return err(NativeCalltraceFile & " must have an array 'calls' field")

  # Collect the executed-function NAME set (de-duplicated). A real call tree may
  # resolve several PCs to one name (recursion, multiple call sites); the
  # dependency set is the SET of names, so we de-dup by name and keep the binary
  # as the owning file for every entry.
  var seen = initTable[string, bool]()
  var resultSeq: seq[ExecutedFunction] = @[]
  for i, call in root["calls"].elems:
    if call.kind != JObject:
      return err(NativeCalltraceFile & " calls[" & $i & "] is not an object")
    if not call.hasKey("functionName") or
        call["functionName"].kind != JString:
      return err(NativeCalltraceFile & " calls[" & $i &
        "] missing string 'functionName'")
    let name = call["functionName"].getStr()
    if name.len == 0:
      return err(NativeCalltraceFile & " calls[" & $i &
        "] has an empty 'functionName'")
    # Skip the addr2line "unknown" sentinel a real recorder emits for an
    # unresolved PC ("??"): an unresolved function cannot be hashed by name, so
    # including it would force a perpetual re-run. We DROP it from the set
    # rather than fail the whole read; if the set ends up empty that is handled
    # below. (A real unresolved PC is rare and not a dependency we can track.)
    if name == "??":
      continue
    if not seen.hasKeyOrPut(name, true):
      resultSeq.add ExecutedFunction(name: name, file: binary, defLine: 0)

  if resultSeq.len == 0:
    return err(NativeCalltraceFile & " contains no resolvable executed functions")

  resultSeq.sort(proc (a, b: ExecutedFunction): int = cmp(a.name, b.name))
  ok(resultSeq)

# ---------------------------------------------------------------------------
# Native flavour dispatch — calltrace.json (legacy) vs instrumentation (M15)
# ---------------------------------------------------------------------------
#
# The native backend (`tbNativeDwarf`) now has TWO concrete trace flavours, both
# producing the SAME `ExecutedFunction{name, file=binary, defLine=0}` shape and
# both hashed by the M7 instruction-byte `shallowHashNative`:
#
#   * LEGACY:        a hand-crafted `native_calltrace.json` projection (M8). Kept
#                    as an explicitly-labelled legacy fixture path so the M8 tests
#                    keep working. The owning binary is the calltrace's `binary`
#                    field.
#   * INSTRUMENTED:  a GENUINE compile-time-instrumentation capture (M14/M15): a
#                    `native_instrument_calls.log` names file plus the recorded
#                    `instrumented_prog` binary, both in the trace dir. This is the
#                    LIVE native path on arm64-macOS (no Intel PT / RR / MCR).
#
# The dispatch below selects the flavour by which artifact the trace dir carries.
# The instrumentation flavour is preferred when BOTH are present (the live
# artifact is the real capture; the legacy JSON is only a stand-in). Any
# structural problem in the selected flavour ⇒ `Err` (the engine re-runs, never a
# false skip).

func instrumentLogPath(traceDir: string): string =
  ## The instrumentation names-file path inside a trace dir.
  traceDir / native_instrument.InstrumentOutFile

func instrumentBinaryPath(traceDir: string): string =
  ## The instrumented binary `instrumentAndRun` builds + runs to CAPTURE the
  ## executed-function set (`<traceDir>/instrumented_prog`).
  traceDir / "instrumented_prog"

const RecordedBinaryName* = "recorded_prog"
  ## The CLEAN (non-instrumented) binary the harness records alongside the
  ## instrumented one, for SHALLOW HASHING. See `instrumentHashBinaryPath`.

proc instrumentHashBinaryPath(traceDir: string): string =
  ## The binary the native shallow hash reads each executed function's compiled
  ## instruction bytes from, for an instrumentation trace.
  ##
  ## # Why a SEPARATE clean binary (not `instrumented_prog`)
  ##
  ## `-finstrument-functions` injects `__cyg_profile_func_enter/exit` calls into
  ## EVERY instrumented function; those calls are pc-relative to the linked-in
  ## recorder runtime. So ANY source edit that changes the total code size (e.g.
  ## growing the UNEXECUTED `unused_c`) relocates the runtime relative to the
  ## executed functions and changes their instrument-call operands — i.e. the
  ## instrumented binary's per-function bytes are NOT relocation-stable for
  ## unrelated edits (the M7 call-distance limitation, amplified to every
  ## function). Hashing the instrumented binary would therefore re-hash the
  ## executed functions on an unrelated edit ⇒ a conservative (but useless)
  ## re-run, defeating function-level precision.
  ##
  ## The hash must reflect the REAL (production) program a user ships — a clean,
  ## NON-instrumented build of the SAME source. The harness records that clean
  ## binary as `<traceDir>/recorded_prog`; instrumentation is a DISCOVERY tool
  ## only. When the clean binary is present it is the hashing input; otherwise we
  ## fall back to the instrumented binary (still correct — a changed hash is a
  ## safe re-run, never a false skip; only precision is reduced).
  let clean = traceDir / RecordedBinaryName
  if fileExists(clean): clean else: instrumentBinaryPath(traceDir)

proc hasInstrumentTrace*(traceDir: string): bool =
  ## True iff `traceDir` carries an instrumentation capture (the names log). The
  ## binary is checked by the discovery/hash path; the log's presence is the
  ## flavour signal (it is the artifact the legacy JSON path never produces).
  fileExists(instrumentLogPath(traceDir))

proc hasCalltraceTrace*(traceDir: string): bool =
  ## True iff `traceDir` carries the legacy `native_calltrace.json` projection.
  fileExists(traceDir / NativeCalltraceFile)

proc readExecutedFunctionsNativeAny*(traceDir: string):
    Result[seq[ExecutedFunction], string] =
  ## Flavour-aware native `DependencyDiscovery`: read the executed-function set
  ## from whichever native trace flavour `traceDir` carries — the genuine
  ## instrumentation capture (M14/M15) preferred, else the legacy
  ## `native_calltrace.json` projection (M8). Any structural problem ⇒ `Err`.
  if not dirExists(traceDir):
    return err("native trace dir not found: " & traceDir)
  if hasInstrumentTrace(traceDir):
    # M14 discovers the executed NAME set (and keys each dep's `.file` on the
    # instrumented binary). For HASHING we must read the CLEAN recorded binary
    # (see `instrumentHashBinaryPath`), so re-point every dep's `.file` onto it —
    # the NAME (the dependency identity) is unchanged.
    let discovered = readExecutedFunctionsInstrumented(traceDir)
    if discovered.isErr:
      return discovered
    let hashBinary = instrumentHashBinaryPath(traceDir)
    var rebound: seq[ExecutedFunction]
    for fn in discovered.get():
      rebound.add ExecutedFunction(
        name: fn.name, file: hashBinary, defLine: fn.defLine)
    return ok(rebound)
  # Neither an instrumentation capture nor a legacy calltrace is present. Delegate
  # to the legacy reader so its specific, backward-compatible diagnostic
  # ("native calltrace file not found: …") surfaces — a native-shaped trace dir
  # that carries no executed-set payload of EITHER flavour ⇒ Err (re-run).
  readExecutedFunctionsNative(traceDir)

proc nativeTraceBinaryAny*(traceDir: string): Result[string, string] =
  ## Flavour-aware owning-binary resolution. The native shallow hasher reads each
  ## function's instruction bytes from the trace's recorded binary; `decide`
  ## rebinds cached native deps onto it (the analogue of the source path's
  ## `sourceRoot` rebind). For the instrumentation flavour the binary is the
  ## recorded `instrumented_prog`; for the legacy flavour it is the calltrace's
  ## `binary` field. A missing/unresolvable binary ⇒ `Err` (the engine fail-safes
  ## the dep hashes to "missing" ⇒ re-run, never a skip).
  if not dirExists(traceDir):
    return err("native trace dir not found: " & traceDir)
  if hasInstrumentTrace(traceDir):
    # The HASHING binary (clean `recorded_prog` if present, else the instrumented
    # one) — `decide` rebinds cached native deps onto it, exactly as discovery
    # keys fresh deps on it.
    let binary = instrumentHashBinaryPath(traceDir)
    if not fileExists(binary):
      return err("native hash binary not found in instrumentation trace dir: " &
        binary)
    return ok(binary)
  if hasCalltraceTrace(traceDir):
    return nativeTraceBinary(traceDir)
  err("native trace dir " & traceDir & " carries no native trace flavour")

proc nativeTraceDirReadableAny*(traceDir: string): Result[void, string] =
  ## Flavour-aware native readability probe (the M5/M8 fail-safe, extended for the
  ## instrumentation flavour). A native trace dir must exist AND carry a readable
  ## artifact of a recognised flavour. The recorded binary is probed later by the
  ## shallow hasher (which fail-safes to a re-run if it is missing/unreadable), so
  ## a missing binary is ALWAYS a re-run, never a skip.
  if not dirExists(traceDir):
    return err("missing trace dir: " & traceDir)
  if hasInstrumentTrace(traceDir):
    let p = instrumentLogPath(traceDir)
    try:
      discard readFile(p)
    except CatchableError as e:
      return err("unreadable native instrument log " & p & ": " & e.msg)
    return ok()
  # No instrumentation capture ⇒ require the legacy calltrace (its absence yields
  # the backward-compatible "missing native trace file" diagnostic the engine's
  # M8 fail-safe assertions pin).
  let p = traceDir / NativeCalltraceFile
  if not fileExists(p):
    return err("missing native trace file: " & p)
  try:
    discard readFile(p)
  except CatchableError as e:
    return err("unreadable native trace file " & p & ": " & e.msg)
  ok()
