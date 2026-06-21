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
## `trace_reader`/`ctfs_trace`) and the *current* source tree, this module
## decides whether the test can be skipped ("skipped (unchanged)") or must be
## re-run, following `Nim-Parallel-Test-Framework.md` §16.7:
##
## * §16.7.1 — *shallow hash*: a per-function hash of the function's body text.
## * §16.7.3 — *deep hash*: hash of the sorted-by-name concatenation of the
##   shallow hashes of the test's executed functions.
## * §16.7.4 — *workflow*: between runs we compare the *cached* dependency set
##   against the *current* source; we only re-trace and `record` when the test
##   is actually re-run.

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
                              ## hashing/extraction error, or an unsupported
                              ## backend) forced a conservative re-run rather
                              ## than risk a silent skip (M5).

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
        ## A human-readable diagnostic for *why* the fail-safe re-run was forced.

  CachedDep* = object
    ## A single recorded dependency: the executed function plus the shallow
    ## hash it had at record time.
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
      ## non-deterministic (``false``) is ALWAYS re-run by `decide`.
    bodyHash*: string
      ## The catalog-reported compile-time DEEP hash (`symBodyHash`, §16.2/§16.3)
      ## for this test, when reported at `record` time. Empty (``""``) means NO
      ## deep hash was recorded — the test is decided purely by the runtime
      ## shallow path.

  IncrementalCache* = object
    ## In-memory map of `testId -> CachedTest`, with JSON persistence.
    path*: string                       ## Backing JSON file path.
    entries*: Table[string, CachedTest] ## testId -> cache entry.

const
  DefaultCacheDir* = ".ct-incremental"
  DefaultCacheFile* = "cache.json"
  CacheVersion* = 3
    ## Current on-disk cache schema version. A cache file written with a
    ## DIFFERENT version is IGNORED by `loadCache` (treated as an empty/fresh
    ## cache so every test re-runs) — never mis-parsed or partially trusted.

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
  ## `idSkipUnchanged` is a skip; ALL other kinds re-run.
  d.kind != idSkipUnchanged

# ---------------------------------------------------------------------------
# Source extraction + shallow hash (§16.7.1)
# ---------------------------------------------------------------------------

func hexOfHash(h: Hash): string =
  ## Render a `std/hashes.Hash` as a fixed-width lowercase hex string.
  toHex(cast[uint](h)).toLowerAscii()

func normalizeBody(funcSource: string): string =
  ## Strip trailing whitespace per line (incl. a stray `\r` from CRLF sources),
  ## keep leading indentation, re-join with `\n`, drop a trailing newline.
  var outLines: seq[string]
  for rawLine in funcSource.split('\n'):
    outLines.add rawLine.strip(leading = false, trailing = true)
  outLines.join("\n").strip(leading = false, trailing = true)

proc shallowHash*(funcSource: string): string =
  ## Stable per-function hash (§16.7.1) of a function's body text, after the
  ## documented normalization. The empty body (missing function) hashes to a
  ## distinct, reserved value.
  let normalized = normalizeBody(funcSource)
  if normalized.len == 0:
    return "missing"
  hexOfHash(hash(normalized))

# ---------------------------------------------------------------------------
# Per-dependency shallow hashing against current source
# ---------------------------------------------------------------------------

proc resolveSourcePath(sourceRoot, file: string): string =
  ## Resolve a trace-recorded `file` against `sourceRoot`. Trace paths are
  ## typically absolute-looking; we join them under `sourceRoot` after stripping
  ## a leading path separator.
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
  ## The source/interpreted `ShallowHasher` implementation. Compute the current
  ## shallow hash of a single executed function against the source under
  ## `sourceRoot`. A missing file, a missing function, OR an unsupported source
  ## extension yields the reserved `"missing"` shallow hash — so a removed/
  ## unreadable dependency is treated as changed, never silently skipped.
  let path = resolveSourcePath(sourceRoot, dep.file)
  let linesRes = readSourceLines(path)
  if linesRes.isErr:
    return shallowHash("")  # missing file => missing function => "missing"
  let bodyRes = extractFunctionBody(dep.file, linesRes.value, dep.defLine)
  if bodyRes.isErr:
    return shallowHash("")  # unknown ext / out-of-range / unmatched => "missing"
  shallowHash(bodyRes.value)

# ---------------------------------------------------------------------------
# Backend strategy selection
# ---------------------------------------------------------------------------
#
# M18 wires the SOURCE/interpreted (`tbSourceInterpreted`) and CTFS-interpreted
# (`tbSourceCtfs`) backends; both use the source-text shallow hasher. The NATIVE
# and reserved Nim-instrumented backends are LEFT WITH NIL seam procs so
# `strategiesImplemented` reports them unimplemented and the engine fails safe to
# a re-run (never a skip). See the module banner for the trim rationale.

let
  sourceInterpretedStrategies = BackendStrategies(
    backend: tbSourceInterpreted,
    discovery: newDependencyDiscovery(readExecutedFunctions),
    hasher: newShallowHasher(shallowHashOfDepSource))

  sourceCtfsStrategies = BackendStrategies(
    backend: tbSourceCtfs,
    discovery: newDependencyDiscovery(readExecutedFunctionsCtfs),
    hasher: newShallowHasher(shallowHashOfDepSource))

proc backendStrategies*(backend: TraceBackend): BackendStrategies =
  ## Select the `(DependencyDiscovery, ShallowHasher)` pair for a backend.
  ## `tbSourceInterpreted` and `tbSourceCtfs` are wired; `tbNativeDwarf` and
  ## `tbNimInstrumented` return a pair with nil seam procs
  ## (`strategiesImplemented == false`) so the engine re-runs with
  ## `notImplementedReason` (honest gate, never a false skip).
  case backend
  of tbSourceInterpreted:
    sourceInterpretedStrategies
  of tbSourceCtfs:
    sourceCtfsStrategies
  of tbNativeDwarf, tbNimInstrumented:
    BackendStrategies(backend: backend)

# ---------------------------------------------------------------------------
# Deep hash (§16.7.3)
# ---------------------------------------------------------------------------

proc deepHash*(funcs: seq[(string, string)]): string =
  ## Combine per-function `(name, shallowHash)` pairs into a test's deep hash
  ## (§16.7.3): sort by name for determinism, then hash the concatenation.
  var sorted = funcs
  sorted.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  var buf = ""
  for (name, sh) in sorted:
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
  ## (first run). Malformed JSON is an Err — never a crash. A foreign/old schema
  ## version is treated as an empty (fresh) cache so EVERY test re-runs.
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
    if entry.hasKey("deterministic"):
      if entry["deterministic"].kind != JBool:
        return err("cache entry '" & testId & "' deterministic must be a bool")
      ct.deterministic = entry["deterministic"].getBool()
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
  ## Remove cache entries for tests no longer in the live set, persist, and
  ## return the sorted list of removed ids. Best-effort persistence.
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
  ## `testId`. The trace's backend is detected and discovery + hashing go through
  ## that backend's seams. A backend whose strategies are not wired (native /
  ## Nim-instrumented in this vendor), or an ambiguous/unknown trace shape,
  ## returns an `Err` — the caller MUST re-run, never record a skip-eligible
  ## entry from an unsupported backend.
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
  cache.entries[testId] = CachedTest(
    deepHash: "",
    deps: @[],
    deterministic: deterministic,
    bodyHash: bodyHash)

proc markNonDeterministic*(cache: var IncrementalCache; testId: string;
                           deterministic = false): Result[void, string] =
  ## (Re)mark an already-recorded test's determinism without re-recording its
  ## dependency set. Err if there is no cache entry for `testId`.
  if not cache.entries.hasKey(testId):
    return err("cannot mark unknown test as non-deterministic: " & testId)
  cache.entries[testId].deterministic = deterministic
  ok()

proc sourceTraceDirReadable(traceDir: string): Result[void, string] =
  ## Readability probe for a SOURCE/interpreted test's legacy JSON trace dir.
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
  ## The CTFS-backend readability probe. A CTFS trace dir must exist and contain
  ## a resolvable `.ct` bundle, and `ct-print` must be resolvable — otherwise we
  ## cannot read the executed-function set and MUST re-run.
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
  ## Backend-dispatched readability probe. Native/Nim-instrumented are gated by
  ## the `strategiesImplemented` guard before this is reached, so only a trivial
  ## existence probe is kept for them (keeps the case total).
  case backend
  of tbSourceInterpreted:
    sourceTraceDirReadable(traceDir)
  of tbSourceCtfs:
    ctfsTraceDirReadable(traceDir)
  of tbNativeDwarf, tbNimInstrumented:
    if dirExists(traceDir): ok() else: err("missing trace dir: " & traceDir)

proc decide*(testId, traceDir, sourceRoot: string;
             cache: IncrementalCache): IncrementalDecision =
  ## Decide skip vs re-run for `testId` (§16.7.4 step 3).
  ##
  ## * `testId` absent from cache ⇒ `idRunFresh`.
  ## * cache entry marked non-deterministic ⇒ `idRerunNonDeterministic`.
  ## * trace dir missing/unreadable, or its backend unsupported ⇒
  ##   `idRerunFailSafe`.
  ## * otherwise recompute each CACHED dependency's shallow hash from the CURRENT
  ##   source and compare to the recorded per-dep hash. Every dep unchanged ⇒
  ##   `idSkipUnchanged`; otherwise ⇒ `idRerunChanged` listing exactly the
  ##   functions whose hash changed or which are now missing.
  ##
  ## The ONLY decision kind that skips is `idSkipUnchanged`, reached only when
  ## (a) the test is deterministic, (b) its trace dir + backend are readable/
  ## supported, and (c) every recorded dep's CURRENT shallow hash equals its
  ## recorded hash. Any error routes to a re-run — never a false skip.
  if not cache.entries.hasKey(testId):
    return runFresh()
  let cached = cache.entries[testId]
  if not cached.deterministic:
    return rerunNonDeterministic()
  let backendRes = detectBackend(traceDir)
  if backendRes.isErr:
    return rerunFailSafe(backendRes.error)
  let strategies = backendStrategies(backendRes.value)
  if not strategiesImplemented(strategies):
    return rerunFailSafe(notImplementedReason(backendRes.value))
  let traceRes = traceDirReadable(traceDir, backendRes.value)
  if traceRes.isErr:
    return rerunFailSafe(traceRes.error)
  # SOURCE/CTFS deps carry a source path + defLine the source hasher resolves
  # under the CURRENT `sourceRoot`, so no rebind is needed.
  var changed: seq[string]
  for dep in cached.deps:
    let current = strategies.hasher.hashOf(dep.fn, sourceRoot)
    if current != dep.shallow:
      changed.add dep.fn.name
  if changed.len == 0:
    return skipUnchanged()
  changed.sort()
  rerunChanged(changed)

# ---------------------------------------------------------------------------
# The catalog DEEP path (compile-time symBodyHash) + tiered selector (M11)
# ---------------------------------------------------------------------------

proc decideByCatalog*(testId: string; catalog: BodyHashCatalog;
                      cache: IncrementalCache): IncrementalDecision =
  ## The DEEP path: decide skip vs re-run for `testId` PURELY from the catalog's
  ## compile-time `bodyHash` (§16.2/§16.3) — NO trace, NO shallow hashing.
  let current = catalog.bodyHashFor(testId)
  if current.isNone:
    return runFresh()
  if not cache.entries.hasKey(testId):
    return runFresh()
  let cached = cache.entries[testId]
  if not cached.deterministic:
    return rerunNonDeterministic()
  if cached.bodyHash.len == 0:
    return rerunChanged(@[testId])
  if cached.bodyHash == current.get():
    return skipUnchanged()
  rerunChanged(@[testId])

proc decideTiered*(testId: string; catalog: BodyHashCatalog;
                   traceDir, sourceRoot: string;
                   cache: IncrementalCache): IncrementalDecision =
  ## The TIERED selector: use the compile-time DEEP path when the catalog reports
  ## a `bodyHash` for `testId`, otherwise fall back to the runtime backend
  ## SHALLOW path (`decide`).
  if catalog.hasBodyHash(testId):
    decideByCatalog(testId, catalog, cache)
  else:
    decide(testId, traceDir, sourceRoot, cache)
