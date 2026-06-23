## Backend abstraction + detection — the M6 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign (Phase 2).
##
## CodeTracer has TWO independent incremental-testing mechanisms (spec
## `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md` §16.7),
## differing on BOTH axes — dependency discovery AND shallow hashing:
##
## | path                | dependency discovery                | shallow hash                |
## |---------------------|-------------------------------------|-----------------------------|
## | source/interpreted  | canonical `Function`/`Call` records | source text (Phase 1)       |
## | native / MCR        | executed set from the native trace  | compiled instruction bytes  |
##
## Phase 1 implemented exactly the source/interpreted path. M6 introduces the
## *seam* so Phase 2 can plug the native path (M7-M9) and the full
## language→strategy matrix (M10) in WITHOUT changing the source path's
## behaviour. This module owns:
##
##   1. `TraceBackend` — which mechanism a given trace requires.
##   2. `detectBackend` — infer the backend from a trace directory's shape and
##      metadata (with an explicit-metadata override).
##   3. The two pluggable seams — `DependencyDiscovery` and `ShallowHasher` —
##      and a `backendStrategies` selector that maps a `TraceBackend` to its
##      `(DependencyDiscovery, ShallowHasher)` pair. The source/interpreted
##      implementations are injected by `engine.nim` (which owns the canonical
##      JSON reader and the source-text extractor/hasher) so this module stays
##      free of a circular import; the native implementations are wired in by
##      M7-M9.
##
## # The fail-safe invariant (carried over from Phase 1 / M5)
##
## Any ambiguity is conservative: an unknown/empty/ambiguous trace shape yields
## an `Err` from `detectBackend` (the engine turns that into a re-run), and a
## backend whose strategies are not yet implemented (`tbNativeDwarf`,
## `tbNimInstrumented` until M7-M9) routes to a strategy whose discovery returns
## an `Err` — so the engine re-runs with a clear "backend not yet supported"
## reason. NEVER a silent skip.

import std/[json, os, strutils]
import results

import trace_reader

export results

type
  TraceBackend* = enum
    ## The incremental-testing mechanism a trace requires.
    tbSourceInterpreted
      ## Source / interpreted path. The trace carries canonical
      ## `Function`/`Call` records (a `trace.json` events array) and a function's
      ## identity is its *source text*. This is the Phase 1 path: Python, Ruby,
      ## JavaScript, Lua, WASM, and Nim's materialized-source recording.
    tbNativeDwarf
      ## Native / Multi-Core-Recorder (MCR) + RR/DWARF path. The trace does NOT
      ## emit `Function`/`Call` records; the executed-function set comes from the
      ## native trace's calltrace and a function's identity is its *compiled
      ## instruction bytes*. C, C++, Rust, Go, Pascal, D, Fortran, Ada, Crystal,
      ## Odin, V, and Nim's compiled-via-C recording. Implemented in M7-M9.
    tbNimInstrumented
      ## Reserved for Nim's future *instrumented / materialized* recording path
      ## distinct from the two above (Nim can be recorded either way; this slot
      ## holds the dedicated instrumented variant when it lands). Not yet
      ## implemented — routes to a fail-safe re-run.
    tbSourceCtfs
      ## Modern CTFS `.ct` bundle from an INTERPRETED-language recorder (M12). The
      ## bundle carries `function`/`call` records (read via the CTFS reader /
      ## `ct-print`), so the executed-function set comes from CTFS — but a
      ## function's identity is still its *source text* (it is an interpreted
      ## language), so this backend pairs CTFS dependency discovery with the
      ## SAME source-text shallow hasher the `tbSourceInterpreted` path uses.
      ##
      ## # Why a distinct backend (and why it does not break `tbNativeDwarf`)
      ##
      ## A `.ct` container's mere PRESENCE is, by `structuralBackend`, a NATIVE
      ## signal (the native recorders emit CTFS), so a bare `.ct` dir still
      ## detects as `tbNativeDwarf` (instruction-byte hashing) — unchanged from
      ## M6/M8. An INTERPRETED CTFS bundle is distinguished by an EXPLICIT
      ## `recorder_backend: "ctfs-interpreted"` metadata signal, which selects
      ## this backend (CTFS discovery + source hashing). So the existing native
      ## `.ct` path is untouched; the interpreted-CTFS path is opt-in via explicit
      ## metadata.

  # The two seams. Each is a small object of procs so a backend can be added by
  # supplying a new pair without touching the engine's decide/record logic. A
  # nil proc field denotes "not yet implemented for this backend" — the engine
  # MUST treat that as a fail-safe re-run, never a skip (see
  # `strategiesImplemented`).

  DependencyDiscoveryProc* = proc (traceDir: string):
    Result[seq[ExecutedFunction], string] {.nimcall, gcsafe.}
    ## Discover the executed-function set for a trace. The source/interpreted
    ## impl is `trace_reader.readExecutedFunctions`; the native impl (M8) reads
    ## the native calltrace.

  ShallowHashProc* = proc (fn: ExecutedFunction; sourceRoot: string): string
    {.nimcall, gcsafe.}
    ## Compute the CURRENT shallow hash of one executed function against
    ## `sourceRoot` (for native backends `sourceRoot` is the directory the
    ## compiled binary is resolved under). MUST return a value distinct from any
    ## real body hash (e.g. the reserved ``"missing"`` sentinel) when the
    ## function cannot be hashed, so a removed/unreadable dependency is treated
    ## as changed — never silently skipped.

  DependencyDiscovery* = object
    ## The dependency-discovery seam for one backend.
    discover*: DependencyDiscoveryProc

  ShallowHasher* = object
    ## The shallow-hashing seam for one backend.
    hashOf*: ShallowHashProc

  BackendStrategies* = object
    ## The full strategy pair selected by a `TraceBackend`. `backend` is echoed
    ## for diagnostics. When either seam's proc is nil the backend is not yet
    ## implemented (see `strategiesImplemented`).
    backend*: TraceBackend
    discovery*: DependencyDiscovery
    hasher*: ShallowHasher

const
  TraceMetadataFile* = "trace_metadata.json"
    ## Optional sidecar the source/interpreted recorder writes; may carry an
    ## explicit `recorder_backend` field that overrides structure detection.
  TraceDbMetadataFile* = "trace_db_metadata.json"
    ## Sidecar emitted by the native/CTFS trace-db path. Its mere presence is a
    ## native-shape signal; it may also carry an explicit `recorder_backend`.
  RrSubdir* = "rr"
    ## An `rr/` subdirectory inside a trace dir indicates an RR (native) replay
    ## capture.
  CtfsExtension* = ".ct"
    ## A CTFS binary container file (`*.ct`) inside the trace dir indicates a
    ## native CTFS capture.

# ---------------------------------------------------------------------------
# Explicit metadata override
# ---------------------------------------------------------------------------

func backendOfRecorderField(value: string): Result[TraceBackend, string] =
  ## Map an explicit `recorder_backend` metadata value to a `TraceBackend`.
  ## Recognised values (case-insensitive) mirror the recorder identifiers used
  ## across the CodeTracer recorders:
  ##   * ``rr`` / ``mcr`` / ``ttd``      ⇒ native (instruction-byte) path.
  ##   * ``native-instrumented``         ⇒ native (instruction-byte) path via the
  ##                                       M14/M15 compile-time-instrumentation
  ##                                       capture (the LIVE native path on hosts
  ##                                       without Intel PT / RR / MCR).
  ##   * ``interpreter``                 ⇒ source/interpreted path (legacy JSON).
  ##   * ``ctfs-interpreted``            ⇒ modern CTFS bundle from an interpreted
  ##                                       recorder (M12): CTFS discovery + source
  ##                                       text hashing.
  ##   * ``nim-instrumented``            ⇒ the reserved Nim instrumented path.
  ## An unrecognised value is an `Err` so a typo/forward-incompatible recorder
  ## name fails safe (the engine re-runs) rather than guessing a path.
  case value.strip().toLowerAscii()
  of "rr", "mcr", "ttd", "native", "native-dwarf", "dwarf",
     "native-instrumented", "native_instrumented", "instrumented-native":
    ok(tbNativeDwarf)
  of "interpreter", "interpreted", "source", "source-interpreted":
    ok(tbSourceInterpreted)
  of "ctfs-interpreted", "ctfs_interpreted", "ctfs-source", "interpreted-ctfs":
    ok(tbSourceCtfs)
  of "nim-instrumented", "nim_instrumented", "instrumented":
    ok(tbNimInstrumented)
  else:
    err("unknown recorder_backend value: '" & value & "'")

proc explicitBackendFromMetadata(traceDir: string):
    Result[TraceBackend, string] =
  ## Look for an explicit `recorder_backend` field in either metadata sidecar.
  ## Returns:
  ##   * `ok(backend)`          — a recognised explicit field was found.
  ##   * `err(<diagnostic>)`    — the field was PRESENT but unrecognised/malformed
  ##                              (a hard signal: honour the intent to be explicit
  ##                              and fail safe rather than fall through to
  ##                              structure detection).
  ##   * `ok-less sentinel`     — see below: absence of the field is signalled by
  ##                              returning `err("")` with an EMPTY message, which
  ##                              the caller treats as "no explicit field, fall
  ##                              back to structure".
  ##
  ## The empty-message sentinel keeps the precedence explicit and total without a
  ## third Option type: `detectBackend` only falls back to structure detection
  ## when the message is empty.
  for metaFile in [TraceMetadataFile, TraceDbMetadataFile]:
    let p = traceDir / metaFile
    if not fileExists(p):
      continue
    var raw: string
    try:
      raw = readFile(p)
    except CatchableError as e:
      # An unreadable metadata file is not itself a backend signal; skip it and
      # let structure detection (or the other sidecar) decide. We do NOT hard
      # error here because the file may be irrelevant to backend selection.
      discard e
      continue
    var node: JsonNode
    try:
      node = parseJson(raw)
    except CatchableError:
      # Malformed metadata JSON: ignore for override purposes (structure
      # detection still applies). The trace readers report their own errors.
      continue
    if node.kind == JObject and node.hasKey("recorder_backend"):
      let field = node["recorder_backend"]
      if field.kind != JString:
        return err("recorder_backend in " & metaFile & " must be a string")
      return backendOfRecorderField(field.getStr())
  # No explicit field anywhere ⇒ empty-message sentinel ⇒ fall back to structure.
  err("")

# ---------------------------------------------------------------------------
# Structure detection
# ---------------------------------------------------------------------------

proc hasCtfsContainer(traceDir: string): bool =
  ## True if the trace dir contains a `*.ct` CTFS container file.
  for kind, path in walkDir(traceDir):
    if kind in {pcFile, pcLinkToFile} and path.toLowerAscii().endsWith(CtfsExtension):
      return true
  false

proc structuralBackend(traceDir: string): Result[TraceBackend, string] =
  ## Detect the backend purely from the trace directory's shape:
  ##   * a canonical `trace.json` events array  ⇒ source/interpreted.
  ##   * an `rr/` subdir OR a `*.ct` container OR a `trace_db_metadata.json`
  ##                                             ⇒ native.
  ## Ambiguity (both shapes present) and emptiness (neither) are `Err` so the
  ## engine re-runs rather than guess.
  let hasCanonical = fileExists(traceDir / TraceEventsFile)
  let hasRr = dirExists(traceDir / RrSubdir)
  let hasDbMeta = fileExists(traceDir / TraceDbMetadataFile)
  let hasCtfs = hasCtfsContainer(traceDir)
  let nativeSignal = hasRr or hasDbMeta or hasCtfs

  if hasCanonical and nativeSignal:
    return err("ambiguous trace shape in " & traceDir &
      ": both canonical " & TraceEventsFile & " and native signal(s) present")
  if hasCanonical:
    return ok(tbSourceInterpreted)
  if nativeSignal:
    return ok(tbNativeDwarf)
  err("unrecognised/empty trace shape in " & traceDir &
    ": no " & TraceEventsFile & ", no " & RrSubdir & "/, no " &
    CtfsExtension & " container, no " & TraceDbMetadataFile)

# ---------------------------------------------------------------------------
# Public detection
# ---------------------------------------------------------------------------

proc detectBackend*(traceDir: string): Result[TraceBackend, string] =
  ## Detect the `TraceBackend` for a trace directory.
  ##
  ## # Precedence (documented)
  ##
  ##   1. EXPLICIT metadata wins: if either `trace_metadata.json` or
  ##      `trace_db_metadata.json` carries a `recorder_backend` string field, that
  ##      value selects the backend (recognised values: `rr`/`mcr`/`ttd` ⇒ native,
  ##      `interpreter` ⇒ source (legacy JSON), `ctfs-interpreted` ⇒ modern CTFS
  ##      from an interpreted recorder, `nim-instrumented` ⇒ the reserved Nim
  ##      path). An explicit-but-unrecognised value is an `Err` (fail safe).
  ##   2. STRUCTURE otherwise: a canonical `trace.json` ⇒ source/interpreted; an
  ##      `rr/` subdir, a `*.ct` CTFS container, or a `trace_db_metadata.json`
  ##      sidecar ⇒ native.
  ##
  ## Ambiguous (both source and native structural signals), unknown, or empty
  ## directories yield an `Err` — never a guess — so upstream re-runs.
  if not dirExists(traceDir):
    return err("trace dir not found: " & traceDir)
  let explicit = explicitBackendFromMetadata(traceDir)
  if explicit.isOk:
    return explicit
  # A NON-empty error message means an explicit field was present but
  # malformed/unrecognised — honour the intent to be explicit and fail safe.
  if explicit.error.len > 0:
    return err(explicit.error)
  # Empty message ⇒ no explicit field ⇒ structure detection.
  structuralBackend(traceDir)

# ---------------------------------------------------------------------------
# Strategy selection
# ---------------------------------------------------------------------------

func newDependencyDiscovery*(discover: DependencyDiscoveryProc): DependencyDiscovery =
  DependencyDiscovery(discover: discover)

func newShallowHasher*(hashOf: ShallowHashProc): ShallowHasher =
  ShallowHasher(hashOf: hashOf)

func strategiesImplemented*(s: BackendStrategies): bool =
  ## True iff both seams are wired for this backend. The engine MUST re-run
  ## (never skip) when this is false — see `engine.decide`/`engine.record`.
  s.discovery.discover != nil and s.hasher.hashOf != nil

func notImplementedReason*(backend: TraceBackend): string =
  ## A clear, stable diagnostic for a backend whose strategies are not yet
  ## wired. Surfaced verbatim by the engine's fail-safe re-run so the watch
  ## output explains WHY a native/Nim-instrumented trace re-runs instead of
  ## participating in incremental skipping.
  "backend not yet supported: " & $backend
