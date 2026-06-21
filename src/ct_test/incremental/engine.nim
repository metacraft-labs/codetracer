## VENDORED from reprobuild's proven incremental-testing engine.
## Provenance: /Users/zahary/m/dev/reprobuild/libs/repro_ct_incremental/src/repro_ct_incremental/engine.nim
## (Trace-Based-Incremental-Testing campaign, milestone M18 productionisation.)
##
## CLEAN VENDOR with ONE deliberate trim (documented below) — keep in sync with
## the reprobuild source above. The decision/record/cache/hash algorithm is
## byte-for-byte the prototype's; only the BACKEND WIRING is reduced.
##
## # The M18 trim: source/CTFS backends only (native gated, never a false skip)
##
## The full reprobuild engine additionally wires the NATIVE (DWARF / compiled-
## instruction-byte) backend, which pulls in `native_trace`/`native_hash`/
## `native_instrument` (objdump/DWARF/compile-time-instrumentation tooling). M18
## productionises trace-based incremental selection for INTERPRETED languages
## that record live in `ct test` (Python/Ruby via the modern CTFS `.ct` bundle),
## so this vendor wires ONLY:
##   * `tbSourceInterpreted` — legacy JSON trace + source-text hashing, and
##   * `tbSourceCtfs`        — modern CTFS `.ct` bundle (via `ct-print`) + the
##                            SAME source-text hashing.
## The NATIVE and reserved Nim-instrumented backends are LEFT WITH NIL STRATEGIES
## (`strategiesImplemented == false`), so `record`/`decide` fail safe to a re-run
## with a clear "backend not yet supported" reason for a native trace — NEVER a
## false skip. Bringing native into `ct test` is a follow-up that vendors the
## native modules too; until then native is honestly gated here.
##
## Everything below this banner is the prototype engine, with the native imports,
## the native shallow hasher, the native trace-dir readability probe, and the
## native dep-location rebind removed (they are unreachable once the native
## strategies are nil). The original module documentation follows.
##
## ---------------------------------------------------------------------------
##
## Deep-hash invalidation engine — the M1 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign.
##
## Given a test's executed functions (discovered from a CodeTracer trace by
## `trace_reader`) and the *current* source tree, this module decides whether
## the test can be skipped ("skipped (unchanged)") or must be re-run. The
## algorithm follows `codetracer-specs/Planned-Features/`
## `Nim-Parallel-Test-Framework.md`:
##
## * §16.7.1 — *shallow hash*: a per-function hash of the function's body text.
## * §16.7.3 — *deep hash*: hash of the sorted-by-name concatenation of the
##   shallow hashes of the test's executed functions.
## * §16.7.4 — *workflow*: between runs we compare the *cached* dependency set
##   against the *current* source. We only re-trace and `record` when the test
##   is actually re-run.
##
## # Source extraction (language-agnostic; M3)
##
## Per-function source extraction is delegated to a `FunctionBodyExtractor`
## selected purely by file extension (see `extractors.nim`). The engine itself
## contains NO per-language logic: it asks `extractors.extractFunctionBody` for
## the body given the source file path, the source lines, and the 1-based
## `defLine`. Ruby (`.rb`) and Python (`.py`) use an indentation heuristic;
## JavaScript (`.js`) uses brace matching. An unknown extension yields an
## `Err`, which the engine maps to the reserved `"missing"` shallow hash so the
## test fail-safes to a re-run (never a silent wrong hash). The exact boundary
## rule matters only for stability, not correctness of the skip/re-run
## decision: as long as the same physical lines are captured for an unchanged
## function and different lines/text for a changed one, the engine is correct.
##
## # Normalization (documented)
##
## Before hashing, `shallowHash` normalizes the body text by:
##   * splitting into lines on `\n` (a trailing `\r` per line is stripped, so
##     CRLF and LF sources hash identically),
##   * stripping *trailing* whitespace from each line (trailing spaces/tabs are
##     not significant), and
##   * re-joining with `\n` and stripping a trailing newline.
##
## Leading whitespace (indentation) IS significant — it is part of the body in
## indentation-structured languages. Comments and blank lines inside the body
## ARE significant (this is the conservative choice: a comment edit triggers a
## re-run rather than risking a false skip). A whitespace/comment-insensitive
## AST mode is deferred to the tree-sitter milestone (M3+).
##
## # Missing functions
##
## If a function named in the cached dependency set no longer exists at its
## recorded `defLine` (the file is shorter than `defLine`, or the extractor
## cannot read a body there), or its source file's extension has no registered
## extractor, the body extraction returns an `Err`. The engine maps that to the
## reserved `"missing"` shallow hash. The deep hash therefore changes versus the
## recorded one, so `decide` returns `idRerunChanged` with the missing function
## listed — a removed/unreadable dependency is treated as changed and is never
## silently skipped (see `removed_executed_function_reruns`).

import std/[json, os, algorithm, hashes, strutils, tables, options]
import results

import trace_reader
import extractors
import backends
import ctfs_trace
import catalog

export trace_reader
export extractors
export backends
export ctfs_trace
export catalog

type
  IncrementalDecisionKind* = enum
    idRunFresh                ## No cache entry for this test — run it and record.
    idSkipUnchanged           ## Deep hash unchanged — the test may be skipped.
    idRerunChanged            ## At least one executed function changed/was removed.
    idRerunNonDeterministic   ## Test marked non-deterministic — always re-run.
    idRerunFailSafe           ## A guard (missing trace, unreadable source/cache,
                              ## hashing/extraction error) forced a conservative
                              ## re-run rather than risk a silent skip (M5).

  IncrementalDecision* = object
    ## The skip/re-run verdict for a single test.
    case kind*: IncrementalDecisionKind
    of idRunFresh, idSkipUnchanged, idRerunNonDeterministic:
      discard
    of idRerunChanged:
      changedFuncs*: seq[string]
        ## Names of executed functions whose shallow hash changed (or which are
        ## now missing from the source) since the cache was recorded.
    of idRerunFailSafe:
      reason*: string
        ## A human-readable diagnostic for *why* the fail-safe re-run was forced
        ## (e.g. ``missing trace dir: …``). The decision is ALWAYS re-run; the
        ## reason exists so the watch report can distinguish fail-safe re-runs
        ## from ordinary changed-function re-runs (M5 §16.7).

  CachedDep* = object
    ## A single recorded dependency: the executed function plus the shallow
    ## hash it had at record time. Persisting the per-dep shallow hash lets
    ## `decide` pinpoint exactly which functions changed (not just that *some*
    ## did), giving function-level precision in the changed-set report.
    fn*: ExecutedFunction
    shallow*: string

  CachedTest* = object
    ## A cache entry for one test: its recorded deep hash and the executed
    ## functions (dependency set) it was computed from, each with its recorded
    ## shallow hash.
    deepHash*: string
    deps*: seq[CachedDep]
    deterministic*: bool
      ## Whether this test is deterministic. Defaults to ``true``. A test marked
      ## non-deterministic (``false``) is ALWAYS re-run by `decide`, regardless of
      ## whether any executed function's hash changed (spec §16.7: non-deterministic
      ## tests are always re-run). Persisted in the cache JSON so the marking
      ## survives a process restart.
    bodyHash*: string
      ## The catalog-reported compile-time DEEP hash (`symBodyHash`, §16.2/§16.3)
      ## for this test, when the CodeTracer unit-testing library reported one at
      ## `record` time. Empty (``""``) means NO deep hash was recorded — the test
      ## is then decided purely by the runtime shallow path (M1/M9). When
      ## non-empty, `decideByCatalog`/`decideTiered` compare the CURRENT catalog
      ## `bodyHash` directly against this value: equal ⇒ skip, differ ⇒ re-run,
      ## with NO trace and NO shallow hashing. The two paths update and compare
      ## INDEPENDENTLY — a `record` with a catalog stores this field AND the
      ## shallow deps; a `record` without one stores the deps and leaves this
      ## empty (M11).

  IncrementalCache* = object
    ## In-memory map of `testId -> CachedTest`, with JSON persistence.
    path*: string                       ## Backing JSON file path.
    entries*: Table[string, CachedTest] ## testId -> cache entry.

const
  DefaultCacheDir* = ".ct-incremental"
  DefaultCacheFile* = "cache.json"
  CacheVersion* = 3
    ## Current on-disk cache schema version (M5/M11). A cache file written with a
    ## DIFFERENT version (older or newer) is IGNORED by `loadCache` — treated as
    ## an empty/fresh cache so every test re-runs — rather than mis-parsed or
    ## partially trusted. Bumped from 1 to 2 in M5 when the per-test
    ## ``deterministic`` field was introduced; bumped from 2 to 3 in M11 when the
    ## per-test catalog ``bodyHash`` (the compile-time deep hash, §16.2/§16.3) was
    ## added. A v2 file lacks `bodyHash`, so a v2 entry that was recorded under
    ## the deep path would look like a shallow-only entry; per M5 the version
    ## mismatch makes the whole file re-run, which is the safe outcome.

# ---------------------------------------------------------------------------
# Decision constructors
# ---------------------------------------------------------------------------

func runFresh*(): IncrementalDecision =
  IncrementalDecision(kind: idRunFresh)

func skipUnchanged*(): IncrementalDecision =
  IncrementalDecision(kind: idSkipUnchanged)

func rerunChanged*(changedFuncs: seq[string]): IncrementalDecision =
  IncrementalDecision(kind: idRerunChanged, changedFuncs: changedFuncs)

func rerunNonDeterministic*(): IncrementalDecision =
  IncrementalDecision(kind: idRerunNonDeterministic)

func rerunFailSafe*(reason: string): IncrementalDecision =
  IncrementalDecision(kind: idRerunFailSafe, reason: reason)

func isRerun*(d: IncrementalDecision): bool =
  ## True for every decision kind that means "the test must run". Only
  ## `idSkipUnchanged` is a skip; ALL other kinds (fresh, changed,
  ## non-deterministic, fail-safe) re-run. Centralising this keeps callers from
  ## accidentally treating a new fail-safe kind as a skip.
  d.kind != idSkipUnchanged

# ---------------------------------------------------------------------------
# Source extraction + shallow hash (§16.7.1)
# ---------------------------------------------------------------------------

func hexOfHash(h: Hash): string =
  ## Render a `std/hashes.Hash` as a fixed-width lowercase hex string. We cast
  ## through `uint` to take the raw bit pattern (the sign bit must not trigger a
  ## range error), then `toHex` on the unsigned value.
  toHex(cast[uint](h)).toLowerAscii()

func normalizeBody(funcSource: string): string =
  ## Apply the documented normalization: strip trailing whitespace per line
  ## (including a stray `\r` from CRLF sources), keep leading indentation,
  ## re-join with `\n`, and drop a trailing newline.
  var outLines: seq[string]
  for rawLine in funcSource.split('\n'):
    outLines.add rawLine.strip(leading = false, trailing = true)
  outLines.join("\n").strip(leading = false, trailing = true)

proc shallowHash*(funcSource: string): string =
  ## Stable per-function hash (§16.7.1) of a function's body text, after the
  ## documented normalization. The empty body (missing function) hashes to a
  ## distinct, reserved value so a removed function is representable and never
  ## collides with a real body.
  ##
  ## The returned value is a lowercase hex string of `std/hashes.hash`. It is
  ## deterministic for a given Nim build/process and — because `hash(string)`
  ## in `std/hashes` is a fixed Farm-hash-derived algorithm seeded only by the
  ## input bytes — stable across processes of the same binary. (Cryptographic
  ## strength is not required, per §16.7 / the spec's hash-algorithm note: this
  ## is change detection on trusted local data.)
  let normalized = normalizeBody(funcSource)
  if normalized.len == 0:
    # Reserved sentinel for a missing/empty function body. Distinct from any
    # hash of real content so the deep hash necessarily changes.
    return "missing"
  hexOfHash(hash(normalized))

# ---------------------------------------------------------------------------
# Per-dependency shallow hashing against current source
# ---------------------------------------------------------------------------

proc resolveSourcePath(sourceRoot, file: string): string =
  ## Resolve a trace-recorded `file` against `sourceRoot`. Trace paths are
  ## typically absolute-looking (e.g. `/fixtures/.../x.rb`); we join them under
  ## `sourceRoot` after stripping a leading path separator so a fixture trace
  ## recorded with an absolute-looking path resolves under the test's temp dir.
  var rel = file
  while rel.len > 0 and (rel[0] == '/' or rel[0] == '\\'):
    rel = rel[1 .. ^1]
  sourceRoot / rel

proc readSourceLines(path: string): Result[seq[string], string] =
  ## Read a source file and split into lines on `\n`. A missing/unreadable file
  ## is an Err (the caller turns that into a changed/missing dependency).
  if not fileExists(path):
    return err("source file not found: " & path)
  var raw: string
  try:
    raw = readFile(path)
  except CatchableError as e:
    return err("failed to read " & path & ": " & e.msg)
  ok(raw.split('\n'))

proc shallowHashOfDepSource(dep: ExecutedFunction; sourceRoot: string): string
    {.nimcall, gcsafe.} =
  ## The source/interpreted `ShallowHasher` implementation (Phase 1). Compute
  ## the current shallow hash of a single executed function against the source
  ## under `sourceRoot`. A missing file, a missing function, OR an unsupported
  ## source extension yields the reserved `"missing"` shallow hash (via
  ## `shallowHash` of an empty body), so a removed/unreadable dependency is
  ## treated as changed — never silently skipped, never hashed with the wrong
  ## extractor. The extractor is chosen purely by `dep.file`'s extension.
  ##
  ## (M6: this is the `tbSourceInterpreted` shallow-hash seam. Its signature
  ## matches `backends.ShallowHashProc` so it can be injected into a
  ## `ShallowHasher`. The behaviour is BYTE-FOR-BYTE the Phase-1 hasher.)
  let path = resolveSourcePath(sourceRoot, dep.file)
  let linesRes = readSourceLines(path)
  if linesRes.isErr:
    return shallowHash("")  # missing file => missing function => "missing"
  # `dep.file` (the trace-recorded path) carries the extension that selects the
  # extractor; `path` is only where the bytes live under the temp sourceRoot.
  let bodyRes = extractFunctionBody(dep.file, linesRes.value, dep.defLine)
  if bodyRes.isErr:
    return shallowHash("")  # unknown ext / out-of-range / unmatched => "missing"
  shallowHash(bodyRes.value)


# ---------------------------------------------------------------------------
# Backend strategy selection (M6 seam)
# ---------------------------------------------------------------------------
#
# The engine routes dependency discovery and shallow hashing through the
# `backends` seams, selected by the detected `TraceBackend`. The
# source/interpreted strategy is wired here from the Phase-1 implementations
# (`trace_reader.readExecutedFunctions` + `shallowHashOfDepSource`), giving the
# byte-for-byte identical behaviour Phase 1 had. Native (`tbNativeDwarf`) and
# the reserved `tbNimInstrumented` are intentionally LEFT with nil seam procs
# until M7-M9: `strategiesImplemented` reports them unimplemented and the
# engine fails safe to a re-run (never a skip).

let
  sourceInterpretedStrategies = BackendStrategies(
    backend: tbSourceInterpreted,
    discovery: newDependencyDiscovery(readExecutedFunctions),
    hasher: newShallowHasher(shallowHashOfDepSource))


  sourceCtfsStrategies = BackendStrategies(
    backend: tbSourceCtfs,
    # M12: dependency discovery reads the executed-function set from a MODERN
    # CTFS `.ct` bundle (via `ct-print --json-events`, tolerant of non-UTF-8
    # value bytes); shallow hashing reuses the SAME source-text hasher the
    # `tbSourceInterpreted` path uses (the bundle is from an INTERPRETED
    # recorder, so a function's identity is its source text). The CTFS reader
    # populates each dep's `file`/`defLine` from the call's entry step, so the
    # existing source extractor + `{deepHash, deps}` cache shape work unchanged.
    discovery: newDependencyDiscovery(readExecutedFunctionsCtfs),
    hasher: newShallowHasher(shallowHashOfDepSource))

proc backendStrategies*(backend: TraceBackend): BackendStrategies =
  ## Select the `(DependencyDiscovery, ShallowHasher)` pair for a backend.
  ## `tbSourceInterpreted` (Phase 1) and `tbNativeDwarf` (M8) are both wired; the
  ## reserved `tbNimInstrumented` backend returns a pair with nil seam procs
  ## (`strategiesImplemented == false`) so the engine re-runs with
  ## `notImplementedReason`. M9 wires Nim's dual path.
  case backend
  of tbSourceInterpreted:
    sourceInterpretedStrategies
  of tbSourceCtfs:
    sourceCtfsStrategies
  of tbNativeDwarf, tbNimInstrumented:
    # Vendored trim: native + reserved Nim backends have nil seam procs, so the
    # engine fails safe to a re-run (`strategiesImplemented == false`).
    BackendStrategies(backend: backend)

# ---------------------------------------------------------------------------
# Deep hash (§16.7.3)
# ---------------------------------------------------------------------------

proc deepHash*(funcs: seq[(string, string)]): string =
  ## Combine per-function `(name, shallowHash)` pairs into a test's deep hash
  ## (§16.7.3): sort by name for determinism, then hash the concatenation of
  ## the shallow hashes. Order-independent and stable: two inputs with the same
  ## set of pairs in any order produce the same deep hash.
  var sorted = funcs
  sorted.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  var buf = ""
  for (name, sh) in sorted:
    # Include the name in the digest input so that two different functions that
    # happen to share a shallow hash (e.g. identical one-line bodies) still
    # produce distinct deep-hash material when their identities differ.
    buf.add name
    buf.add '\x00'
    buf.add sh
    buf.add '\x1f'
  hexOfHash(hash(buf))

proc currentDeps(deps: seq[ExecutedFunction]; sourceRoot: string;
                 hasher: ShallowHasher): seq[CachedDep] =
  ## Compute the current per-dependency shallow hashes against `sourceRoot`
  ## using the backend-selected `hasher` seam.
  for dep in deps:
    result.add CachedDep(fn: dep, shallow: hasher.hashOf(dep, sourceRoot))

func deepHashOfCachedDeps(deps: seq[CachedDep]): string =
  ## Deep hash of a recorded dependency set (uses the stored shallow hashes).
  var pairs: seq[(string, string)]
  for dep in deps:
    pairs.add (dep.fn.name, dep.shallow)
  deepHash(pairs)

# ---------------------------------------------------------------------------
# Cache type + JSON persistence
# ---------------------------------------------------------------------------

func defaultCachePath*(root = "."): string =
  ## The default cache path: `<root>/.ct-incremental/cache.json`.
  root / DefaultCacheDir / DefaultCacheFile

func initCache*(path = defaultCachePath()): IncrementalCache =
  ## A fresh, empty cache bound to `path`.
  IncrementalCache(path: path, entries: initTable[string, CachedTest]())

proc loadCache*(path = defaultCachePath()): Result[IncrementalCache, string] =
  ## Load a cache from JSON at `path`. A missing file yields an empty cache
  ## (first run). Malformed JSON is an Err — never a crash.
  ##
  ## # Schema versioning (M5)
  ##
  ## A cache file whose top-level ``version`` is absent or does NOT equal the
  ## current `CacheVersion` is treated as if it were empty: the returned cache is
  ## fresh (no entries) and bound to `path`, so EVERY test decides `idRunFresh`
  ## and re-runs. We never partially trust a foreign-schema file — an older
  ## schema may be missing fields a present-day `decide` relies on (e.g. the
  ## ``deterministic`` flag), and silently trusting it could skip a test that
  ## should run. This is an Ok (fresh cache), NOT an Err: a stale schema is a
  ## normal, expected condition (a tool upgrade), not a corruption.
  var cache = initCache(path)
  if not fileExists(path):
    return ok(cache)
  var raw: string
  try:
    raw = readFile(path)
  except CatchableError as e:
    return err("failed to read cache " & path & ": " & e.msg)
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed cache JSON in " & path & ": " & e.msg)
  if root.kind != JObject:
    return err("cache JSON root must be an object")
  # Reject a foreign/old schema version up front: return a FRESH (empty) cache so
  # everything re-runs, instead of mis-parsing a file written by another schema.
  if not root.hasKey("version") or root["version"].kind != JInt or
      int(root["version"].getBiggestInt()) != CacheVersion:
    return ok(cache)
  if not root.hasKey("tests"):
    return err("cache JSON missing 'tests' object")
  let tests = root["tests"]
  if tests.kind != JObject:
    return err("cache 'tests' must be a JSON object")
  for testId, entry in tests.fields:
    if entry.kind != JObject or not entry.hasKey("deepHash") or
        not entry.hasKey("deps"):
      return err("cache entry '" & testId & "' is malformed")
    var ct = CachedTest(deepHash: entry["deepHash"].getStr(), deterministic: true)
    # `deterministic` defaults to true when absent (a v2 file is always written
    # WITH the field by `toJson`; tolerating its absence keeps us robust to a
    # hand-edited cache without ever defaulting to the unsafe direction —
    # "deterministic: true" only ENABLES skipping, and the per-dep hashes still
    # gate that skip, so the conservative invariant holds).
    if entry.hasKey("deterministic"):
      if entry["deterministic"].kind != JBool:
        return err("cache entry '" & testId & "' deterministic must be a bool")
      ct.deterministic = entry["deterministic"].getBool()
    # The M11 catalog deep hash is OPTIONAL in the JSON: a shallow-only entry has
    # no `bodyHash`, which decodes to the empty string ⇒ "no deep hash recorded"
    # ⇒ the shallow path decides this test. A non-empty value is the recorded
    # compile-time `symBodyHash` the deep path compares the current catalog
    # against. Tolerating its absence keeps the reader robust to a hand-edited
    # cache without ever defaulting to the unsafe direction.
    if entry.hasKey("bodyHash"):
      if entry["bodyHash"].kind != JString:
        return err("cache entry '" & testId & "' bodyHash must be a string")
      ct.bodyHash = entry["bodyHash"].getStr()
    if entry["deps"].kind != JArray:
      return err("cache entry '" & testId & "' deps must be an array")
    for dep in entry["deps"].elems:
      if dep.kind != JObject or not dep.hasKey("name") or
          not dep.hasKey("file") or not dep.hasKey("defLine") or
          not dep.hasKey("shallow"):
        return err("cache entry '" & testId & "' has a malformed dep")
      ct.deps.add CachedDep(
        fn: ExecutedFunction(
          name: dep["name"].getStr(),
          file: dep["file"].getStr(),
          defLine: int(dep["defLine"].getBiggestInt())),
        shallow: dep["shallow"].getStr())
    cache.entries[testId] = ct
  ok(cache)

proc toJson(cache: IncrementalCache): JsonNode =
  ## Serialize the cache deterministically (test ids sorted) for stable files.
  var tests = newJObject()
  var ids: seq[string]
  for id in cache.entries.keys: ids.add id
  ids.sort()
  for id in ids:
    let ct = cache.entries[id]
    var deps = newJArray()
    for dep in ct.deps:
      var d = newJObject()
      d["name"] = newJString(dep.fn.name)
      d["file"] = newJString(dep.fn.file)
      d["defLine"] = newJInt(dep.fn.defLine)
      d["shallow"] = newJString(dep.shallow)
      deps.add d
    var entry = newJObject()
    entry["deepHash"] = newJString(ct.deepHash)
    entry["deterministic"] = newJBool(ct.deterministic)
    # The M11 catalog deep hash (`symBodyHash`). Written unconditionally (empty
    # for a shallow-only entry) so a round-trip is loss-free and the field is
    # self-documenting on disk.
    entry["bodyHash"] = newJString(ct.bodyHash)
    entry["deps"] = deps
    tests[id] = entry
  result = newJObject()
  result["version"] = newJInt(CacheVersion)
  result["tests"] = tests

proc saveCache*(cache: IncrementalCache): Result[void, string] =
  ## Persist the cache to its `path`, creating parent directories.
  try:
    let dir = cache.path.parentDir
    if dir.len > 0:
      createDir(dir)
    writeFile(cache.path, cache.toJson().pretty())
  except CatchableError as e:
    return err("failed to write cache " & cache.path & ": " & e.msg)
  ok()

# ---------------------------------------------------------------------------
# Cache pruning (M4)
# ---------------------------------------------------------------------------

proc pruneCache*(cache: var IncrementalCache;
                 liveTestIds: openArray[string]): seq[string] =
  ## Remove cache entries for tests that are no longer part of the live test
  ## set, then PERSIST the pruned cache to disk. Returns the sorted list of
  ## test ids that were removed (empty if nothing was pruned).
  ##
  ## # Semantics
  ##
  ## `liveTestIds` is the authoritative set of tests that currently exist (e.g.
  ## the tests discovered in this run). Any cache entry whose test id is NOT in
  ## that set is deleted: the test was renamed, removed, or is otherwise gone,
  ## so keeping its `{deepHash, deps}` would only waste space and could mislead
  ## a future run that re-introduces the same id with different behaviour.
  ##
  ## This handles the *removed-test* case specifically. The complementary
  ## *removed-function within a still-present test* case needs no pruning: M1
  ## already treats a dependency that no longer exists in source as the
  ## reserved `"missing"` shallow hash, so such a test re-runs (never a silent
  ## skip) and is re-recorded with the current dependency set on that run.
  ##
  ## Pruning is idempotent: a test absent from BOTH the cache and `liveTestIds`
  ## is simply ignored, and an entry already pruned stays pruned. After this
  ## returns, a subsequent `decide` for a pruned test id yields `idRunFresh`
  ## (no entry ⇒ run-and-record), exactly as for a never-seen test.
  ##
  ## The on-disk cache is rewritten via `saveCache`. A persistence failure does
  ## NOT raise: the in-memory cache is still pruned, and the failure surfaces on
  ## the next explicit `saveCache` the caller performs. (Callers that need the
  ## persisted state guaranteed should call `saveCache` and check its Result.)
  var live = initTable[string, bool]()
  for id in liveTestIds:
    live[id] = true
  var removed: seq[string]
  for id in cache.entries.keys:
    if not live.hasKey(id):
      removed.add id
  for id in removed:
    cache.entries.del id
  removed.sort()
  # Persist the pruned cache. Best-effort: see the doc comment above.
  discard saveCache(cache)
  removed

# ---------------------------------------------------------------------------
# record / decide (§16.7.4)
# ---------------------------------------------------------------------------

proc record*(cache: var IncrementalCache; testId, traceDir, sourceRoot: string;
             deterministic = true; bodyHash = ""): Result[void, string] =
  ## Record a fresh run: read the trace's executed functions, compute each
  ## one's shallow hash from the CURRENT source under `sourceRoot`, combine into
  ## the deep hash, and store `{deepHash, deps, deterministic, bodyHash}` for
  ## `testId`. Called after a test is actually executed and re-traced (§16.7.4
  ## step 4).
  ##
  ## `deterministic` marks whether the test is reproducible. Pass `false` for a
  ## test known to be non-deterministic: it is persisted in the cache and makes
  ## every future `decide` re-run the test regardless of hashes (§16.7).
  ##
  ## `bodyHash` (M11) is the catalog-reported compile-time DEEP hash
  ## (`symBodyHash`, §16.2/§16.3) for this test, when the CodeTracer unit-testing
  ## library reported one. Pass it through (or use `recordWithCatalog`) so the
  ## deep path can compare against it later. The empty default means "no deep
  ## hash reported" — the entry is then a shallow-only entry decided by the
  ## runtime path. The two paths are stored side by side and compared
  ## INDEPENDENTLY (M11): this proc ALWAYS records the shallow deps, and
  ## ADDITIONALLY records `bodyHash` when one is supplied.
  ##
  ## # Backend routing (M6)
  ##
  ## The trace's backend is detected (`detectBackend`) and dependency discovery +
  ## shallow hashing go through that backend's seams. The source/interpreted
  ## backend uses `readExecutedFunctions` + the source-text hasher exactly as
  ## Phase 1 did (byte-for-byte identical results). A backend whose strategies
  ## are not yet wired (native / Nim-instrumented, until M7-M9), or an
  ## ambiguous/unknown trace shape, returns an `Err` — the caller MUST re-run,
  ## never record a skip-eligible entry from an unsupported backend.
  let backendRes = detectBackend(traceDir)
  if backendRes.isErr:
    return err("cannot record: " & backendRes.error)
  let strategies = backendStrategies(backendRes.value)
  if not strategiesImplemented(strategies):
    return err("cannot record: " & notImplementedReason(backendRes.value))
  let execRes = strategies.discovery.discover(traceDir)
  if execRes.isErr:
    return err(execRes.error)
  let deps = currentDeps(execRes.value, sourceRoot, strategies.hasher)
  cache.entries[testId] = CachedTest(
    deepHash: deepHashOfCachedDeps(deps),
    deps: deps,
    deterministic: deterministic,
    bodyHash: bodyHash)
  ok()

proc recordBodyHash*(cache: var IncrementalCache; testId, bodyHash: string;
                     deterministic = true) =
  ## Record a test PURELY by its catalog deep hash — NO trace, NO shallow deps.
  ##
  ## This is the deep-path counterpart of `record`: when the CodeTracer
  ## unit-testing library reports a per-test `bodyHash` (§16.3), the runner can
  ## record the test's deep hash WITHOUT ever producing or reading a trace
  ## (§16.5 — the catalog comparison needs no runtime observation). A subsequent
  ## `decideByCatalog`/`decideTiered` compares the CURRENT catalog `bodyHash`
  ## against the value stored here.
  ##
  ## The stored entry has an EMPTY shallow dependency set, so if a future build
  ## stops reporting a `bodyHash` for this test (the library was dropped), the
  ## tiered selector falls back to the shallow path and `decide` sees an empty
  ## recorded dep set ⇒ `idSkipUnchanged` only if nothing was recorded. To avoid
  ## a stale shallow skip in that mixed case, callers that may toggle the library
  ## should re-`record` with a trace. In the steady deep-path state (library
  ## always present) only `bodyHash` is consulted, so the empty dep set is never
  ## reached. This is documented and asserted in the M11 tests.
  cache.entries[testId] = CachedTest(
    deepHash: "",
    deps: @[],
    deterministic: deterministic,
    bodyHash: bodyHash)

proc markNonDeterministic*(cache: var IncrementalCache; testId: string;
                           deterministic = false): Result[void, string] =
  ## Separate API to (re)mark an already-recorded test's determinism without
  ## re-recording its dependency set. Returns an Err if there is no cache entry
  ## for `testId` (you cannot mark a test that has never been recorded). Pass
  ## ``deterministic = true`` to clear a prior non-deterministic marking.
  ##
  ## A test marked non-deterministic (the default) is ALWAYS re-run by `decide`
  ## regardless of source hashes — spec §16.7: non-deterministic tests are
  ## always re-run.
  if not cache.entries.hasKey(testId):
    return err("cannot mark unknown test as non-deterministic: " & testId)
  cache.entries[testId].deterministic = deterministic
  ok()

proc sourceTraceDirReadable(traceDir: string): Result[void, string] =
  ## A conservative readability probe for a SOURCE/interpreted test's trace
  ## directory (M5 fail-safe). The directory must exist AND its two required JSON
  ## files (`trace.json`, `trace_paths.json`) must be present and readable. We do
  ## NOT fully parse them here — `record` does that — but a missing dir or file,
  ## or a file we cannot open, is reported so `decide` re-runs rather than risk a
  ## skip against a trace it cannot even see.
  if not dirExists(traceDir):
    return err("missing trace dir: " & traceDir)
  for required in [TraceEventsFile, TracePathsFile]:
    let p = traceDir / required
    if not fileExists(p):
      return err("missing trace file: " & p)
    try:
      discard readFile(p)
    except CatchableError as e:
      return err("unreadable trace file " & p & ": " & e.msg)
  ok()


proc ctfsTraceDirReadable(traceDir: string): Result[void, string] =
  ## The CTFS-backend readability probe (M12 fail-safe). A CTFS trace dir must
  ## exist and contain a resolvable `.ct` bundle, and `ct-print` must be
  ## resolvable — otherwise we cannot read the executed-function set and MUST
  ## re-run rather than risk a skip against a bundle we cannot see. (Whether the
  ## bundle's CONTENTS parse is checked later, by the discovery seam, which also
  ## Errs ⇒ re-run.)
  if not dirExists(traceDir) and
      not (fileExists(traceDir) and traceDir.toLowerAscii().endsWith(".ct")):
    return err("missing CTFS trace dir/bundle: " & traceDir)
  let bundleRes = resolveCtBundle(traceDir)
  if bundleRes.isErr:
    return err(bundleRes.error)
  let ctPrintRes = resolveCtPrint()
  if ctPrintRes.isErr:
    return err(ctPrintRes.error)
  ok()

proc traceDirReadable(traceDir: string; backend: TraceBackend):
    Result[void, string] =
  ## Backend-dispatched readability probe. Each backend has its own required
  ## trace files (source: `trace.json`+`trace_paths.json`; native:
  ## `native_calltrace.json`; CTFS: a resolvable `.ct` bundle + `ct-print`), so
  ## the probe must run AFTER backend detection.
  case backend
  of tbSourceInterpreted:
    sourceTraceDirReadable(traceDir)
  of tbSourceCtfs:
    ctfsTraceDirReadable(traceDir)
  of tbNativeDwarf, tbNimInstrumented:
    # Vendored trim: native + reserved Nim backends have no wired strategies; the
    # caller's `strategiesImplemented` guard fail-safes before this is reached.
    # A trivial existence probe keeps this total.
    if dirExists(traceDir): ok() else: err("missing trace dir: " & traceDir)

proc currentDepLocations(deps: seq[CachedDep]; traceDir: string;
                         backend: TraceBackend): Result[seq[CachedDep], string] =
  ## Rebind each cached dependency to the location it must be hashed against
  ## GIVEN THE CURRENT TRACE DIR, per backend. The shallow hash recorded at
  ## `record` time is preserved (it is what the current hash is compared against);
  ## only the `fn.file` the hasher reads is updated where the backend needs it.
  ##
  ##   * SOURCE: identity — `fn.file` is a (relative) source path the hasher
  ##     resolves under the CURRENT `sourceRoot`, so the cached deps already point
  ##     at the current tree. (Byte-for-byte the Phase-1 behaviour.)
  ##   * NATIVE: `fn.file` is the binary baked at record time; rebind it to the
  ##     binary the CURRENT trace references so the hash is computed against the
  ##     freshly-rebuilt binary (a real watch cycle rebuilds into a new path). If
  ##     the current binary cannot be resolved, rebind to a guaranteed-absent
  ##     path so the current hash becomes the `"missing"` sentinel ⇒ a re-run,
  ##     never a skip.
  case backend
  of tbSourceInterpreted, tbSourceCtfs, tbNativeDwarf, tbNimInstrumented:
    # Vendored trim: only the source/CTFS-interpreted deps reach here (native is
    # gated to a fail-safe re-run before decide() rebinds), and they carry a
    # source path + defLine the source hasher resolves under the CURRENT
    # `sourceRoot` — so no rebind is needed.
    ok(deps)

proc decide*(testId, traceDir, sourceRoot: string;
             cache: IncrementalCache): IncrementalDecision =
  ## Decide skip vs re-run for `testId` (§16.7.4 step 3).
  ##
  ## * If `testId` is absent from the cache ⇒ `idRunFresh`.
  ## * If the cache entry is marked non-deterministic ⇒ `idRerunNonDeterministic`
  ##   (spec §16.7: a non-deterministic test is ALWAYS re-run, regardless of
  ##   hashes — checked before any source/trace inspection so it can never be
  ##   shadowed by an `idSkipUnchanged`).
  ## * If the trace dir referenced for the test is missing/unreadable ⇒
  ##   `idRerunFailSafe` (we re-run rather than trust a stale decision against a
  ##   trace we cannot see). This guard intentionally fires only for a cached
  ##   test: a never-recorded test already runs fresh.
  ## * Otherwise recompute each CACHED dependency's shallow hash from the
  ##   CURRENT source (NOT a fresh trace) and compare it to the per-dep shallow
  ##   hash recorded at `record` time. If every dep is unchanged ⇒
  ##   `idSkipUnchanged` (equivalently, the deep hash is unchanged). Otherwise ⇒
  ##   `idRerunChanged` listing exactly the executed functions whose shallow
  ##   hash changed or which are now missing (function-level precision).
  ##
  ## # The conservative invariant (M5)
  ##
  ## The ONLY decision kind that skips is `idSkipUnchanged`, and it is reached
  ## only when (a) the test is deterministic, (b) its trace dir is readable, and
  ## (c) every recorded dependency's CURRENT shallow hash equals its recorded
  ## hash. An unreadable source file or an extraction/hashing failure yields the
  ## reserved `"missing"` shallow hash (see `shallowHashOfDepSource`), which differs
  ## from any real recorded hash and therefore routes to `idRerunChanged` — so a
  ## hashing/extraction error is itself a re-run, never a skip. No error or
  ## non-deterministic condition can reach the skip branch.
  if not cache.entries.hasKey(testId):
    return runFresh()
  let cached = cache.entries[testId]
  # Guard 1: a non-deterministic test is always re-run, before any hashing.
  if not cached.deterministic:
    return rerunNonDeterministic()
  # Guard 2 (M6/M8 backend routing): detect the trace's backend and select its
  # strategies FIRST, because the readability probe (guard 3) is backend-specific
  # — a source trace requires `trace.json`/`trace_paths.json`, a native trace
  # requires `native_calltrace.json`. An ambiguous/unknown shape, or a backend
  # whose strategies are not yet wired (Nim-instrumented until M9), fails safe to
  # a re-run with a clear reason — NEVER a skip.
  let backendRes = detectBackend(traceDir)
  if backendRes.isErr:
    return rerunFailSafe(backendRes.error)
  let strategies = backendStrategies(backendRes.value)
  if not strategiesImplemented(strategies):
    return rerunFailSafe(notImplementedReason(backendRes.value))
  # Guard 3: the trace dir referenced for this test must carry the backend's
  # required, readable trace files. If they are gone or unreadable, fail safe to
  # a re-run with a diagnostic — we re-run rather than trust a stale decision
  # against a trace we cannot see. (Source backend keeps the Phase-1 fail-safe
  # reasons ``missing trace dir`` / ``missing trace file`` byte-for-byte.) This
  # guard intentionally fires only for a cached test: a never-recorded test
  # already runs fresh.
  let traceRes = traceDirReadable(traceDir, backendRes.value)
  if traceRes.isErr:
    return rerunFailSafe(traceRes.error)
  # Resolve the CURRENT location each cached dependency must be hashed against,
  # given the CURRENT trace dir. This is the native counterpart of the source
  # path's "re-hash the cached deps against the CURRENT source under sourceRoot":
  #   * SOURCE: a cached dep's `.file` is a (relative) source path; the hasher
  #     resolves it under `sourceRoot`, which is already the CURRENT source tree.
  #     No rebind is needed — `currentDeps` returns the cached deps unchanged.
  #   * NATIVE: a cached dep's `.file` is the BINARY path baked at record time
  #     (an old build in an old temp dir). The CURRENT binary is the one the
  #     CURRENT trace references, so we rebind each cached dep's `.file` to the
  #     current trace's binary before hashing. If the current binary cannot be
  #     resolved (a malformed/empty current calltrace), every dep is rebound to a
  #     guaranteed-absent path so its current hash becomes the `"missing"`
  #     sentinel ⇒ a re-run, never a skip.
  let currentDepsRes = currentDepLocations(cached.deps, traceDir, backendRes.value)
  if currentDepsRes.isErr:
    return rerunFailSafe(currentDepsRes.error)
  let currentCachedDeps = currentDepsRes.value
  # Recompute each dependency's CURRENT shallow hash against the current source
  # via the backend's hasher seam and compare to the per-dep shallow hash
  # recorded at `record` time. A dep is "changed" if its current shallow hash
  # differs from the recorded one — this includes the case where the function
  # was removed OR its source is unreadable (current hash == the `"missing"`
  # sentinel), which is therefore reported as changed and never silently skipped.
  var changed: seq[string]
  for dep in currentCachedDeps:
    let current = strategies.hasher.hashOf(dep.fn, sourceRoot)
    if current != dep.shallow:
      changed.add dep.fn.name
  if changed.len == 0:
    # No executed function's body changed since record() — the deep hash is
    # unchanged, so the test may be skipped.
    return skipUnchanged()
  changed.sort()
  rerunChanged(changed)

# ---------------------------------------------------------------------------
# M11 — the catalog DEEP path (compile-time symBodyHash) + tiered selector
# ---------------------------------------------------------------------------
#
# When the CodeTracer Nim unit-testing library is linked, it reports a per-test
# compile-time DEEP hash (`symBodyHash`, §16.2) in its `--list-json` catalog
# (§16.3). `symBodyHash` already covers the test's entire transitive call graph,
# so it IS the deep hash — there is nothing to combine and NO trace is needed
# (§16.5/§3.7: the runner compares catalog `bodyHash`es between builds and skips
# the unchanged ones). The engine compares that hash DIRECTLY.
#
# # Why the shallow path is RETAINED (an explicit M11 requirement)
#
# `symBodyHash` exists only when the test binary links the library AND only for
# Nim. When the engine runs WITHOUT that library — every non-Nim language, and
# Nim binaries built without it — there is NO catalog `bodyHash`, so the engine
# MUST fall back to the runtime shallow path (M1/M9): discover the executed
# functions from a trace and compare per-function source/instruction hashes.
# Removing the shallow path would break that no-library case entirely. So
# `decideTiered` is "deep-when-the-library-reports-it, shallow-otherwise": it
# uses `decideByCatalog` iff a catalog `bodyHash` is available for the test, and
# otherwise dispatches to the existing backend shallow `decide`. Both decisions
# are equally fail-safe (the only skip is `idSkipUnchanged`).

proc decideByCatalog*(testId: string; catalog: BodyHashCatalog;
                      cache: IncrementalCache): IncrementalDecision =
  ## The DEEP path: decide skip vs re-run for `testId` PURELY from the catalog's
  ## compile-time `bodyHash` (§16.2/§16.3) — NO trace, NO shallow hashing, NO
  ## source inspection.
  ##
  ## Preconditions: the caller must have established that the catalog reports a
  ## `bodyHash` for `testId` (use `catalog.hasBodyHash` or let `decideTiered`
  ## dispatch). If it does NOT, this returns `idRunFresh` (treating the test as
  ## never-deep-recorded) so a caller that reaches here without a hash never
  ## silently skips.
  ##
  ## Decision (per the M11 spec):
  ##   * `testId` absent from the cache ⇒ `idRunFresh` (run + record the hash).
  ##   * cache entry marked non-deterministic ⇒ `idRerunNonDeterministic`
  ##     (checked first, exactly as the shallow `decide` does — a
  ##     non-deterministic test is ALWAYS re-run, §16.7).
  ##   * the cache has NO recorded `bodyHash` for this test (it was recorded by
  ##     the shallow path only) ⇒ `idRerunChanged` — we cannot prove the deep
  ##     hash is unchanged against an absent baseline, so we conservatively
  ##     re-run (and the caller re-records WITH the hash). Never a silent skip.
  ##   * recorded `bodyHash` EQUALS the current catalog `bodyHash` ⇒
  ##     `idSkipUnchanged`.
  ##   * they DIFFER ⇒ `idRerunChanged`.
  ##
  ## # Safety (static over-estimation is a SAFE re-run)
  ##
  ## `symBodyHash` is a STATIC compile-time deep hash over the transitive call
  ## graph; it may OVER-estimate the dynamic dependency set (e.g. a branch the
  ## test never takes at runtime still contributes to the hash). An over-estimate
  ## only ever causes MORE re-runs (a changed hash ⇒ `idRerunChanged`), which is
  ## always safe. It can NEVER cause a false skip: a skip requires the recorded
  ## and current deep hashes to be byte-equal.
  let current = catalog.bodyHashFor(testId)
  if current.isNone:
    # No deep hash reported for this test — caller should have used the shallow
    # path. Fail safe to a fresh run rather than skip.
    return runFresh()
  if not cache.entries.hasKey(testId):
    return runFresh()
  let cached = cache.entries[testId]
  # Guard: a non-deterministic test is always re-run, before any comparison.
  if not cached.deterministic:
    return rerunNonDeterministic()
  if cached.bodyHash.len == 0:
    # The cache entry has no recorded deep hash (it was recorded by the shallow
    # path). We have no deep baseline to compare against, so we cannot prove the
    # test is unchanged on the deep path — re-run conservatively (the caller
    # re-records with the catalog hash). Reported as a changed deep dependency.
    return rerunChanged(@[testId])
  if cached.bodyHash == current.get():
    return skipUnchanged()
  rerunChanged(@[testId])

proc decideTiered*(testId: string; catalog: BodyHashCatalog;
                   traceDir, sourceRoot: string;
                   cache: IncrementalCache): IncrementalDecision =
  ## The TIERED selector (M11): use the compile-time DEEP path when the catalog
  ## reports a `bodyHash` for `testId`, otherwise fall back to the existing
  ## runtime backend SHALLOW path (`decide`).
  ##
  ## "Deep-when-the-library-reports-it, shallow-otherwise":
  ##   * catalog HAS a `bodyHash` for `testId` ⇒ `decideByCatalog` (no trace, no
  ##     shallow hashing; `traceDir`/`sourceRoot` are NOT consulted at all).
  ##   * catalog does NOT ⇒ `decide(testId, traceDir, sourceRoot, cache)` — the
  ##     unchanged M1/M9 shallow path. This is the no-library case; removing the
  ##     shallow path would break it, which is why the shallow path is retained.
  ##
  ## When BOTH a catalog `bodyHash` AND a trace are available, the DEEP path is
  ## preferred (the catalog hash already covers the whole transitive call graph,
  ## so it is at least as conservative as the shallow runtime set and needs no
  ## trace read). A static over-estimate there is a SAFE re-run, never a false
  ## skip (see `decideByCatalog`).
  if catalog.hasBodyHash(testId):
    decideByCatalog(testId, catalog, cache)
  else:
    decide(testId, traceDir, sourceRoot, cache)
