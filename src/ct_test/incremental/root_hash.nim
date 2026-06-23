## Per-test ROOT HASH + re-decide artifact — the M2 deliverable of the
## Incremental-Test-Runner campaign.
##
## This module reduces a single recorded test execution to ONE per-test *root
## hash* and persists the *re-decide artifact* a later run needs to re-evaluate
## skip-vs-rerun after a source edit. It sits ON TOP of the canonical engine
## (`engine.nim`): the executed-function set and the per-function shallow hashes
## are produced by the engine's `record`/`backendStrategies` path — this module
## REUSES that extraction + hashing and never reimplements it.
##
## # 1. The root hash (combination rule, spec §16.7.3)
##
## A test's *root hash* is the engine's per-test DEEP HASH, computed by
## `engine.deepHash` exactly as `Nim-Parallel-Test-Framework.md` §16.7.3
## prescribes:
##
##   1. Take the SET of executed functions discovered from the trace (§16.7.2),
##      each paired with its shallow hash (§16.7.1: source-text hash for
##      interpreted recorders, instruction-byte hash for native).
##   2. SORT the pairs by function identity (name) for determinism — making the
##      combination ORDER-INDEPENDENT over the executed set: two runs that
##      execute the same functions with the same bodies, in any call order,
##      produce the same root hash.
##   3. Accumulate `H( name_0 \0 shallow_0 \x1f  name_1 \0 shallow_1 \x1f ... )`
##      — the function IDENTITY is folded into the digest material alongside its
##      shallow hash, so two distinct functions that happen to share a shallow
##      hash (identical one-line bodies) still contribute distinct material, and
##      a function being ADDED to or REMOVED FROM the executed set necessarily
##      changes the digest (the accumulator is over the SET, so its membership
##      is load-bearing).
##
## This is a sorted-then-hashed accumulator (a flat one-level Merkle/fold over
## the `(identity, shallow-hash)` pairs). Its invariants, which the M2 tests
## assert directly:
##
##   * STABLE — identical reruns of the same trace over the same source produce
##     the same root hash (sorting removes call-order dependence).
##   * SENSITIVE to body — it changes iff some executed function's shallow hash
##     changes (a body edit flows through that function's shallow hash into the
##     fold).
##   * SENSITIVE to set — it changes iff the executed SET changes (a function
##     added or removed changes the pairs folded in).
##   * INSENSITIVE to non-executed code — a function the test never executed is
##     not in the set, so editing it does not change the root hash.
##
## `engine.deepHash` already implements this rule and is shared with the
## skip/re-run `decide` path, so the artifact's root hash and the engine's
## live decision can NEVER diverge. `rootHashOfDeps` is the thin adapter from
## the engine's recorded dependency set to that rule.
##
## # 2. The re-decide artifact schema
##
## The artifact persists EVERYTHING a later run needs to re-decide WITHOUT the
## original trace — re-hash exactly the recorded functions against the current
## source, recompute the root hash, compare, AND name which function changed:
##
##   * `testId`     — the test this artifact belongs to.
##   * `rootHash`   — the combined root hash above (the fast unchanged/changed
##     gate).
##   * `executedFunctions` — the executed-function SET, each entry carrying the
##     function IDENTITY needed to re-hash it (`name` / `file` / `defLine`) AND
##     its `shallow` hash recorded at this run. Persisting the per-function
##     shallow hash is what lets a re-decide pinpoint the CHANGED function (not
##     merely that *some* changed) — exactly the engine's `CachedDep` shape.
##   * `deterministic` — whether the test may be skipped when unchanged (a
##     non-deterministic test always re-runs, §16.7.5). Carried so the artifact
##     is a complete re-decide input.
##   * `readFiles`  — RESERVED M6 SLOT for read-file dependencies (the files the
##     test read at runtime, each with its hash). Empty until M6 folds read
##     files into the root hash / invalidation. The slot is part of the schema
##     NOW so adding it in M6 is a value change, not a format change.
##
## The artifact is intentionally ISOMORPHIC to the engine's `CachedTest` (root
## hash = `deepHash`, executed functions = `deps`), so `fromCachedTest` /
## `toCachedTest` round-trip losslessly and a later run can decide via the
## engine's existing `decide` over the reconstructed cache entry. The artifact
## is the per-test, on-disk PROJECTION of that cache entry.
##
## # 3. The format-abstraction boundary (M3/M4 swappable)
##
## The CTFS-container-vs-custom-flat-file format DECISION is M3 and the concrete
## chosen format lands in M4. So this module does NOT hard-commit to a wire
## format: all persistence goes through the small `RootHashArtifactCodec`
## writer/reader boundary (`writeArtifact` / `readArtifact`). The provisional
## backing is a self-describing JSON document (`ProvisionalJsonCodec`) that
## REUSES the engine's `CachedTest` JSON shape so the format is already proven
## and a future merge into the recording `.ct` stays natural. M3/M4 swap the
## codec WITHOUT touching the root-hash rule, the schema, or the CLI: only the
## bytes on disk change.

import std/[json, os, algorithm, tables]
import results

import trace_reader   # ExecutedFunction
import engine         # deepHash, CachedTest, CachedDep, record, IncrementalCache, decide ...

export results

type
  ReadFileDep* = object
    ## RESERVED M6 slot: a file the test READ at runtime plus the hash it had at
    ## record time. Folded into the root hash / invalidation in M6 so a changed
    ## read-file re-runs the test. Empty (`@[]`) until then. Defined now so the
    ## schema is forward-stable.
    path*: string     ## The read file's path (as the recording reports it).
    hash*: string     ## The file's content hash at record time.

  RootHashArtifact* = object
    ## The per-test re-decide artifact (see the module schema docs). This is the
    ## standalone, on-disk PROJECTION of the engine's `CachedTest` for one test.
    testId*: string
    rootHash*: string
      ## The combined per-test root hash (§16.7.3; `engine.deepHash` over the
      ## executed-function set's `(name, shallow)` pairs).
    executedFunctions*: seq[CachedDep]
      ## The executed-function SET, each with its identity (`fn.name/file/defLine`)
      ## and the `shallow` hash recorded at this run. Reuses the engine's
      ## `CachedDep` so the re-decide goes through the engine unchanged.
    deterministic*: bool
      ## Whether the test may be skipped when unchanged (§16.7.5). Defaults true.
    readFiles*: seq[ReadFileDep]
      ## RESERVED M6 read-file dependency slot. Empty until M6.

  RootHashArtifactCodec* = object
    ## The swappable serialization boundary (M3/M4). A codec turns a
    ## `RootHashArtifact` into bytes and back. The root-hash rule, the schema,
    ## and the CLI are all codec-agnostic — only this object's two procs decide
    ## the on-disk bytes, so M3's format decision swaps a codec, nothing else.
    name*: string
      ## A human-readable codec id (appears in diagnostics; e.g. "json").
    encode*: proc(a: RootHashArtifact): Result[string, string] {.nimcall, gcsafe.}
    decode*: proc(bytes: string): Result[RootHashArtifact, string] {.nimcall, gcsafe.}

const
  ArtifactSchemaVersion* = 1
    ## On-disk schema version for the PROVISIONAL JSON codec. A document whose
    ## version differs is rejected by `decode` (the caller re-runs / re-records)
    ## rather than mis-parsed — the same conservative stance `engine.loadCache`
    ## takes. Bumped when the schema (not the codec) changes.
  DefaultArtifactDir* = ".ct-incremental"
    ## Default directory for per-test artifacts, alongside the engine cache.
  ArtifactExt* = ".roothash.json"
    ## Provisional per-test artifact file extension (JSON codec).

# ---------------------------------------------------------------------------
# Root hash (§16.7.3) — the thin adapter over the engine's deepHash
# ---------------------------------------------------------------------------

proc rootHashOfDeps*(deps: seq[CachedDep]): string =
  ## Compute the per-test ROOT HASH from a recorded executed-function set, using
  ## the engine's §16.7.3 deep-hash combination rule (sorted-by-name fold over
  ## the `(name, shallow)` pairs). This is the SAME function the engine's
  ## skip/re-run decision uses, so the artifact's root hash and a live decision
  ## can never disagree.
  var pairs: seq[(string, string)]
  for dep in deps:
    pairs.add (dep.fn.name, dep.shallow)
  deepHash(pairs)

# ---------------------------------------------------------------------------
# Artifact <-> engine CachedTest bridge (isomorphic; lossless round-trip)
# ---------------------------------------------------------------------------

proc fromCachedTest*(testId: string; ct: CachedTest): RootHashArtifact =
  ## Project an engine `CachedTest` (one cache entry) into the standalone
  ## per-test artifact. The artifact's `rootHash` is the entry's recorded
  ## `deepHash` — they are the SAME value (both are §16.7.3 over the same deps),
  ## so this never recomputes; it carries the engine's recorded root hash
  ## verbatim. `readFiles` is the empty M6 slot.
  RootHashArtifact(
    testId: testId,
    rootHash: ct.deepHash,
    executedFunctions: ct.deps,
    deterministic: ct.deterministic,
    readFiles: @[])

proc toCachedTest*(a: RootHashArtifact): CachedTest =
  ## Reconstruct an engine `CachedTest` from the artifact so a later run can
  ## decide via the engine's existing `decide` path. The root hash becomes the
  ## entry's `deepHash`; `bodyHash` is left empty (the artifact is the runtime
  ## shallow path's projection — the compile-time catalog deep hash is a
  ## separate engine concern not part of the M2 artifact).
  CachedTest(
    deepHash: a.rootHash,
    deps: a.executedFunctions,
    deterministic: a.deterministic,
    bodyHash: "")

# ---------------------------------------------------------------------------
# Provisional JSON codec (the M2 backing; swapped wholesale in M4)
# ---------------------------------------------------------------------------

proc encodeJson(a: RootHashArtifact): Result[string, string] {.nimcall, gcsafe.} =
  ## Serialize the artifact to the provisional self-describing JSON document.
  ## Deterministic field order + sorted executed functions for stable, diffable
  ## files. The JSON shape mirrors the engine's `CachedTest` entry (a `deepHash`
  ## + a `deps` array of `{name,file,defLine,shallow}`) so a future merge into
  ## the recording `.ct` or the engine cache is natural.
  var funcs = newJArray()
  var sortedDeps = a.executedFunctions
  sortedDeps.sort(proc (x, y: CachedDep): int =
    result = cmp(x.fn.name, y.fn.name)
    if result == 0: result = cmp(x.fn.file, y.fn.file)
    if result == 0: result = cmp(x.fn.defLine, y.fn.defLine))
  for dep in sortedDeps:
    var d = newJObject()
    d["name"] = newJString(dep.fn.name)
    d["file"] = newJString(dep.fn.file)
    d["defLine"] = newJInt(dep.fn.defLine)
    d["shallow"] = newJString(dep.shallow)
    funcs.add d
  var reads = newJArray()
  for rf in a.readFiles:
    var r = newJObject()
    r["path"] = newJString(rf.path)
    r["hash"] = newJString(rf.hash)
    reads.add r
  var root = newJObject()
  root["version"] = newJInt(ArtifactSchemaVersion)
  root["testId"] = newJString(a.testId)
  root["rootHash"] = newJString(a.rootHash)
  root["deterministic"] = newJBool(a.deterministic)
  root["executedFunctions"] = funcs
  root["readFiles"] = reads  # RESERVED M6 slot (empty until M6)
  ok(root.pretty())

proc decodeJson(bytes: string): Result[RootHashArtifact, string] {.nimcall, gcsafe.} =
  ## Parse a provisional JSON artifact document. A version mismatch, malformed
  ## JSON, or a missing/ill-typed field is an `Err` — the caller re-runs /
  ## re-records rather than trust a half-parsed artifact (the engine's
  ## conservative stance). Never raises.
  var root: JsonNode
  try:
    root = parseJson(bytes)
  except CatchableError as e:
    return err("malformed artifact JSON: " & e.msg)
  if root.kind != JObject:
    return err("artifact JSON root must be an object")
  if not root.hasKey("version") or root["version"].kind != JInt or
      int(root["version"].getBiggestInt()) != ArtifactSchemaVersion:
    return err("artifact schema version mismatch (need " &
      $ArtifactSchemaVersion & ")")
  for required in ["testId", "rootHash", "executedFunctions"]:
    if not root.hasKey(required):
      return err("artifact JSON missing '" & required & "'")
  if root["executedFunctions"].kind != JArray:
    return err("artifact 'executedFunctions' must be an array")
  var a = RootHashArtifact(
    testId: root["testId"].getStr(),
    rootHash: root["rootHash"].getStr(),
    deterministic: true)
  if root.hasKey("deterministic"):
    if root["deterministic"].kind != JBool:
      return err("artifact 'deterministic' must be a bool")
    a.deterministic = root["deterministic"].getBool()
  for dep in root["executedFunctions"].elems:
    if dep.kind != JObject or not dep.hasKey("name") or not dep.hasKey("file") or
        not dep.hasKey("defLine") or not dep.hasKey("shallow"):
      return err("artifact has a malformed executedFunctions entry")
    a.executedFunctions.add CachedDep(
      fn: ExecutedFunction(
        name: dep["name"].getStr(),
        file: dep["file"].getStr(),
        defLine: int(dep["defLine"].getBiggestInt())),
      shallow: dep["shallow"].getStr())
  # RESERVED M6 slot: tolerated absent (older/empty artifact) — decodes to @[].
  if root.hasKey("readFiles"):
    if root["readFiles"].kind != JArray:
      return err("artifact 'readFiles' must be an array")
    for rf in root["readFiles"].elems:
      if rf.kind != JObject or not rf.hasKey("path") or not rf.hasKey("hash"):
        return err("artifact has a malformed readFiles entry")
      a.readFiles.add ReadFileDep(
        path: rf["path"].getStr(), hash: rf["hash"].getStr())
  ok(a)

proc provisionalJsonCodec*(): RootHashArtifactCodec =
  ## The M2 provisional codec: self-describing JSON over the engine's cache
  ## shape. Retained as a fallback / interop format; the DEFAULT codec is now the
  ## M4a CTFS-namespace codec (installed by `ctfs_codec` via `setDefaultCodec`).
  RootHashArtifactCodec(name: "json", encode: encodeJson, decode: decodeJson)

# ---------------------------------------------------------------------------
# The default codec (M2/M3/M4 swap point)
# ---------------------------------------------------------------------------
#
# M2 hard-defaulted persistence to the JSON codec. M3 (corrected) chose the
# CTFS B-tree NAMESPACE format and M4a implements it (`ctfs_codec.nim`). To swap
# the format WHOLESALE behind this boundary WITHOUT a circular import
# (`ctfs_codec` imports `root_hash` for the schema + boundary types), the default
# codec is an INSTALLABLE hook: `ctfs_codec` registers the CTFS codec at its
# module init via `setDefaultCodec`, so any module that imports `ctfs_codec`
# (the CLI, the M4a tests) persists through the namespace format. Until a codec
# is installed, the default is the provisional JSON (so `root_hash` stays usable
# stand-alone and the M2 behaviour is preserved when CTFS is not linked).

var defaultCodecHook: RootHashArtifactCodec = provisionalJsonCodec()

proc setDefaultCodec*(codec: RootHashArtifactCodec) =
  ## Install the process-wide default `RootHashArtifactCodec` used by
  ## `writeArtifact`/`readArtifact` when no explicit codec is passed. `ctfs_codec`
  ## calls this at init to make the CTFS-namespace format the default (the M4a
  ## swap). Idempotent; the last installer wins.
  defaultCodecHook = codec

proc defaultCodec*(): RootHashArtifactCodec =
  ## The currently-installed default codec (CTFS-namespace once `ctfs_codec` is
  ## linked, else provisional JSON).
  defaultCodecHook

# ---------------------------------------------------------------------------
# File I/O over the codec boundary
# ---------------------------------------------------------------------------

func defaultArtifactPath*(testId: string; root = "."): string =
  ## The default per-test artifact path:
  ## `<root>/.ct-incremental/<testId>.roothash.json`. The test id is sanitized
  ## (path separators / spaces → `_`) so it is a safe single filename.
  var safe = ""
  for ch in testId:
    if ch in {'/', '\\', ' ', ':'}: safe.add '_'
    else: safe.add ch
  root / DefaultArtifactDir / (safe & ArtifactExt)

proc writeArtifact*(a: RootHashArtifact; path: string;
                    codec = defaultCodec()): Result[void, string] =
  ## Encode `a` with `codec` and write it to `path`, creating parent dirs. All
  ## persistence flows through the codec, so the on-disk format is swappable
  ## (M3/M4). A codec or write failure is an `Err`, never a raise.
  let enc = codec.encode(a)
  if enc.isErr:
    return err("artifact encode failed (" & codec.name & "): " & enc.error)
  try:
    let dir = path.parentDir
    if dir.len > 0: createDir(dir)
    writeFile(path, enc.value)
  except CatchableError as e:
    return err("failed to write artifact " & path & ": " & e.msg)
  ok()

proc readArtifact*(path: string;
                   codec = defaultCodec()): Result[RootHashArtifact, string] =
  ## Read + decode the artifact at `path` via `codec`. A missing file or decode
  ## failure is an `Err` (the caller treats that as "no usable baseline" and
  ## re-runs). Never raises.
  if not fileExists(path):
    return err("artifact not found: " & path)
  var bytes: string
  try:
    bytes = readFile(path)
  except CatchableError as e:
    return err("failed to read artifact " & path & ": " & e.msg)
  codec.decode(bytes)

# ---------------------------------------------------------------------------
# Build the artifact from a recorded trace (REUSES the engine extraction)
# ---------------------------------------------------------------------------

proc buildArtifact*(testId, traceDir, sourceRoot: string;
                    deterministic = true): Result[RootHashArtifact, string] =
  ## Reduce a recorded test trace to its per-test artifact by REUSING the
  ## engine's `record` (which detects the backend, discovers the executed set,
  ## and shallow-hashes each function against the CURRENT source under
  ## `sourceRoot`) and projecting the resulting `CachedTest`. The root hash is
  ## the engine's recorded deep hash — no separate hashing path exists, so the
  ## artifact and the engine's live decision are guaranteed consistent.
  ##
  ## An unreadable/unsupported trace is an `Err` (propagated from `record`) — the
  ## caller MUST re-run, never persist a bogus artifact (fail-safe contract).
  var cache = initCache()
  let rec = record(cache, testId, traceDir, sourceRoot, deterministic = deterministic)
  if rec.isErr:
    return err(rec.error)
  ok(fromCachedTest(testId, cache.entries[testId]))

# ---------------------------------------------------------------------------
# Re-decide from a persisted artifact (REUSES the engine decide)
# ---------------------------------------------------------------------------

proc redecideFromArtifact*(a: RootHashArtifact; traceDir, sourceRoot: string):
    IncrementalDecision =
  ## Re-decide skip-vs-rerun for the test from its PERSISTED artifact, against
  ## the CURRENT source under `sourceRoot`. Reconstructs a one-entry engine cache
  ## from the artifact and dispatches to the engine's `decide` — so the artifact
  ## path inherits the engine's full fail-safe contract verbatim (the only skip
  ## is `idSkipUnchanged`; a changed executed function is named; a removed/
  ## unreadable dependency or an unreadable trace re-runs). `traceDir` supplies
  ## the executed-SET backend probe exactly as the engine's `decide` expects.
  var cache = initCache()
  cache.entries[a.testId] = toCachedTest(a)
  decide(a.testId, traceDir, sourceRoot, cache)
