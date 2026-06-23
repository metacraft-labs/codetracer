{.push raises: [].}

## Suite-level INVALIDATION query over a `CtfsStore` — the M4b deliverable of
## the Incremental-Test-Runner campaign.
##
## # What this module is
##
## M4a built the CTFS-namespace storage (`ctfs_store.nim`): the interning tables,
## the deep-hash forward map (`testId -> rootHash`), the shallow REVERSE
## structure (`functionId -> {shallow, [testIds]}`), and the file reverse index
## (`fileId -> {[testIds], mtime}`). The existing engine (`engine.decide`) makes
## a PER-TEST skip/re-run decision by re-hashing one test's recorded functions.
##
## This module implements the OPTIMAL, SUITE-LEVEL invalidation the daemon (M4c)
## will call to filter "run all": given the current codebase and the changed-file
## signal, it returns the exact set of test ids to RE-RUN (plus, for naming,
## which functions/files changed) WITHOUT re-deciding every test one-by-one.
##
## Two query shapes, matching the team-confirmed invalidation model:
##
##   * **DEEP (Nim `symBodyHash`)** — `invalidateDeep`. For each test, recompute
##     its deep (root) hash from the current codebase and compare to the stored
##     `testId -> deepHash`. CHANGED ⇒ re-run. UNCHANGED ⇒ consult the file index
##     (a changed read file still re-runs the test). No reverse map is needed.
##
##   * **SHALLOW (Python/Ruby/JS/native)** — `invalidateShallow`. (1) Hash the
##     functions in the current codebase (at least those in CHANGED files) and
##     compare to the recorded shallow hashes in the shallow reverse map ⇒ the set
##     of CHANGED functions; (2) the REVERSE map turns changed functions into the
##     invalidated test set; (3) UNION the tests invalidated via the file index
##     (changed read files ⇒ their reader tests). Tests reached by neither (2) nor
##     (3) ⇒ SKIP.
##
## File-input invalidation is IDENTICAL in both cases: a read file whose mtime
## (or hash, per config) changed invalidates the tests that read it, via the file
## index. `foldFileInvalidation` implements it once and both query paths call it.
##
## The hashing is the engine's OWN hashing, reused verbatim: the shallow path
## uses `engine.backendStrategies(backend).hasher.hashOf` (the exact seam the
## engine's `record`/`decide` use), and the deep recombination uses
## `root_hash.rootHashOfDeps` (which folds via `engine.deepHash`, §16.7.3). There
## is NO parallel hash implementation here.
##
## # FAIL-SAFE — the runner's core guarantee: NEVER a false skip
##
## Every ambiguity RE-RUNS, never skips. Concretely:
##
##   * A store read error (malformed namespace image), an unresolvable function
##     source, or a missing/unreadable file ⇒ the affected test(s) are RE-RUN.
##   * The DEEP path: if a test's stored deep hash cannot be read, the test
##     re-runs; if its current deep hash cannot be computed, it re-runs.
##   * **The interning-collision hole is CLOSED.** `key64` (FNV-1a) has no
##     collision detection, so two distinct names could collide on one id and
##     SILENTLY MERGE entries — a false skip. Before this module trusts ANY id it
##     resolves, it verifies the id's STORED name/identity (the interning
##     namespace records id->name) matches the name it was QUERIED with. On a
##     mismatch — the collision signature — the affected tests are conservatively
##     RE-RUN (the entry is treated as changed). A collision can therefore never
##     cause a false skip. See `verifyTestIdName` / `verifyFunctionIdentity`.

import std/[algorithm, sets, tables, options]
import results

import trace_reader   # ExecutedFunction
import engine         # CachedDep, backendStrategies, TraceBackend, ShallowHasher ...
import root_hash      # rootHashOfDeps (the §16.7.3 deep-hash recombination)
import ctfs_store     # CtfsStore, key64, functionKey, ShallowEntry, FileEntry ...

export results
export options

# ---------------------------------------------------------------------------
# Inputs + result
# ---------------------------------------------------------------------------

type
  FileSignal* = object
    ## How a read-file dependency is checked for change (the "changed-file
    ## signal" for the file index). For each file path the caller supplies the
    ## CURRENT mtime (or, when `byHash` is set, a content hash carried as the
    ## mtime is not used — the caller passes the current hash via `currentHash`).
    ## A file that the caller cannot stat / read at all is reported via
    ## `currentMtime`/`currentHash` returning `none`, which the query treats as a
    ## CHANGE (fail-safe: a vanished/unreadable read file re-runs its tests).
    byHash*: bool
      ## When true, compare the file's recorded vs current content HASH; else
      ## compare the recorded vs current MTIME. The recorded value lives in the
      ## store's file index (`FileEntry.mtime`) for the mtime mode; for the hash
      ## mode the recorded hash is supplied by the caller via `recordedHash`
      ## (the store's path-only file namespace does not persist per-file hashes
      ## until M6 — see the M6 slot note in `ctfs_store`).
    currentMtime*: proc(path: string): Option[int64] {.closure, gcsafe, raises: [].}
      ## Current mtime of a read file, or `none` if it cannot be stat'd (treated
      ## as changed). Used in the default (mtime) mode.
    currentHash*: proc(path: string): Option[string] {.closure, gcsafe, raises: [].}
      ## Current content hash of a read file, or `none` if unreadable (treated as
      ## changed). Used only when `byHash` is set.
    recordedHash*: proc(path: string): Option[string] {.closure, gcsafe, raises: [].}
      ## The recorded content hash for a read file (M6: from the artifact sidecar
      ## or the store once it persists hashes). `none` ⇒ no baseline ⇒ changed.
      ## Used only when `byHash` is set.

  InvalidationReason* = enum
    ## Why a particular test ended up in the re-run set (for diagnostics/naming).
    irDeepHashChanged      ## DEEP path: the test's recomputed deep hash differs.
    irShallowFuncChanged   ## SHALLOW path: an executed function it ran changed.
    irReadFileChanged      ## A read file the test depends on changed.
    irFailSafe             ## A guard (store read error, collision, unresolvable
                           ## source/file) forced a conservative re-run.

  InvalidationResult* = object
    ## The suite-level verdict. `rerun` is the set of test ids to RE-RUN; every
    ## test id present in the store but ABSENT from `rerun` is SKIPPED. The
    ## auxiliary sets exist for naming/diagnostics (which functions/files changed)
    ## and for the M4c daemon to report WHY each test re-runs.
    rerun*: HashSet[uint64]
      ## Test ids to re-run. The complement (store tests not here) is skipped.
    changedFunctions*: HashSet[uint64]
      ## Function ids whose current shallow hash differs from the recorded one
      ## (shallow path), or which could not be verified (collision/fail-safe).
    changedFiles*: HashSet[uint64]
      ## File ids whose current mtime/hash differs from the recorded one.
    reasons*: Table[uint64, set[InvalidationReason]]
      ## Per re-run test id, the reason(s) it was invalidated (diagnostics).

proc initInvalidationResult(): InvalidationResult =
  InvalidationResult(
    rerun: initHashSet[uint64](),
    changedFunctions: initHashSet[uint64](),
    changedFiles: initHashSet[uint64](),
    reasons: initTable[uint64, set[InvalidationReason]]())

proc flag(r: var InvalidationResult; testId: uint64; reason: InvalidationReason) =
  ## Add `testId` to the re-run set with `reason`. Idempotent; accumulates
  ## reasons (a test can be invalidated by several signals at once).
  r.rerun.incl testId
  # `mgetOrPut` returns a mutable ref to the (existing or freshly inserted) value
  # without raising a `KeyError`, keeping the `{.push raises: [].}` contract.
  var empty: set[InvalidationReason]
  r.reasons.mgetOrPut(testId, empty).incl reason

# ---------------------------------------------------------------------------
# Collision safety — CLOSE the `key64` interning false-skip hole
# ---------------------------------------------------------------------------
#
# `key64` (FNV-1a) is a pure hash with NO collision detection, so two DISTINCT
# names can map to the SAME id. If we trusted an id blindly, a collision could
# silently associate the wrong stored entry (deep hash / shallow set) with a
# name, and a stale-but-byte-equal hash could yield a FALSE SKIP. To make a
# collision incapable of causing a false skip, BEFORE trusting any id we verify
# the id's STORED name/identity (recorded in the interning namespace) equals the
# name we resolved the id FROM. On a mismatch we treat the lookup as a collision
# and force the affected test(s) to RE-RUN. (The check is also a guard against a
# corrupt/foreign store: a wrong stored name ⇒ re-run, never skip.)

proc verifyTestIdName*(s: CtfsStore; testId: uint64; expectedName: string):
    Result[bool, string] =
  ## True iff the store's interning table maps `testId` back to `expectedName`.
  ## A store READ error is an `Err` (the caller fail-safes to re-run). A `none`
  ## name (id absent from interning) or a DIFFERENT name is `ok(false)` — a
  ## collision/foreign-store signature the caller turns into a re-run.
  let nm = s.testName(testId)
  if nm.isErr: return err(nm.error)
  if nm.value.isNone: return ok(false)
  ok(nm.value.get == expectedName)

proc verifyFunctionIdentity*(s: CtfsStore; functionId: uint64;
                             expectedIdentity: string): Result[bool, string] =
  ## True iff the store's function interning maps `functionId` back to
  ## `expectedIdentity` (`"name\0file\0defLine"`). Read error ⇒ `Err`; absent or
  ## mismatched identity ⇒ `ok(false)` (collision/foreign-store ⇒ re-run).
  let id = s.functionIdentity(functionId)
  if id.isErr: return err(id.error)
  if id.value.isNone: return ok(false)
  ok(id.value.get == expectedIdentity)

proc functionIdentityString(fn: ExecutedFunction): string =
  ## The interned identity string for a function — the SAME concatenation
  ## `ctfs_store.functionKey` hashes, so a verified identity proves the id was
  ## NOT a collision.
  fn.name & "\0" & fn.file & "\0" & $fn.defLine

# ---------------------------------------------------------------------------
# File-index invalidation (identical in the deep + shallow cases)
# ---------------------------------------------------------------------------

proc fileChanged(entry: FileEntry; signal: FileSignal): bool =
  ## Decide whether one recorded read-file entry has CHANGED under `signal`.
  ## Fail-safe: any inability to read the current state (a `none` from the
  ## caller's probe) is treated as CHANGED. In hash mode a missing recorded hash
  ## (no baseline) is also CHANGED.
  if signal.byHash:
    let cur = if signal.currentHash != nil: signal.currentHash(entry.path)
              else: none(string)
    if cur.isNone: return true  # unreadable now ⇒ changed
    let rec = if signal.recordedHash != nil: signal.recordedHash(entry.path)
              else: none(string)
    if rec.isNone: return true  # no baseline ⇒ changed
    return cur.get != rec.get
  else:
    let cur = if signal.currentMtime != nil: signal.currentMtime(entry.path)
              else: none(int64)
    if cur.isNone: return true  # un-stat'able now ⇒ changed
    return cur.get != entry.mtime

proc foldFileInvalidation*(s: CtfsStore; signal: FileSignal;
                           r: var InvalidationResult): Result[void, string] =
  ## Fold the file reverse index into the result: for every recorded read file
  ## whose mtime/hash changed, mark its reader tests for re-run (reason
  ## `irReadFileChanged`). This is the file-input invalidation shared by BOTH the
  ## deep and shallow paths. A store read error fail-safes by re-running EVERY
  ## reader test of EVERY file (we cannot tell which changed) — never a skip.
  let fidsRes = s.fileIds()
  if fidsRes.isErr:
    return err(fidsRes.error)
  for fid in fidsRes.value:
    let eRes = s.fileEntryOf(fid)
    if eRes.isErr:
      # Cannot read this file entry: conservatively re-run nothing specific here
      # (we have no test ids), but surface the error so the caller re-runs the
      # whole suite. Returning the error is the safe outcome.
      return err(eRes.error)
    if eRes.value.isNone: continue
    let entry = eRes.value.get
    # Collision safety on the file id: verify the stored path interns back to
    # this id. A mismatch ⇒ treat as changed (re-run the readers).
    let pathOk = block:
      let p = s.filePath(fid)
      if p.isErr: return err(p.error)
      p.value.isSome and p.value.get == entry.path and key64(entry.path) == fid
    if (not pathOk) or fileChanged(entry, signal):
      r.changedFiles.incl fid
      for tid in entry.testIds:
        r.flag(tid, irReadFileChanged)
  ok()

# ---------------------------------------------------------------------------
# DEEP path — recompute each test's deep hash, compare to the forward map
# ---------------------------------------------------------------------------

type
  CurrentDepsProc* = proc(testId: uint64): Result[Option[seq[CachedDep]], string]
    {.closure, gcsafe, raises: [].}
    ## Supplies the CURRENT executed-function set (with each function's CURRENT
    ## shallow hash) for a test, from which the deep path recomputes the root
    ## hash. `none` ⇒ the current set is unavailable (e.g. the test's trace can no
    ## longer be read) ⇒ the deep path RE-RUNS the test (fail-safe). `Err` ⇒ a
    ## hard read error ⇒ re-run. In the daemon this is backed by re-extracting the
    ## test's executed set and hashing each function against the current source;
    ## the tests inject a deterministic recompute.

proc invalidateDeep*(s: CtfsStore; testNames: Table[uint64, string];
                     currentDeps: CurrentDepsProc;
                     signal: FileSignal): Result[InvalidationResult, string] =
  ## DEEP invalidation (Nim `symBodyHash` case). For every test in the store's
  ## deep-forward map:
  ##
  ##   1. Resolve the test's STORED deep hash. Read error / absent ⇒ re-run.
  ##   2. COLLISION SAFETY: verify the test id interns back to the supplied name
  ##      (`testNames[testId]`). Mismatch/absent ⇒ re-run (never trust a possibly
  ##      collided id for a SKIP).
  ##   3. Recompute the test's CURRENT deep hash via `currentDeps` +
  ##      `rootHashOfDeps` (the engine's §16.7.3 rule). Unavailable/error ⇒ re-run.
  ##   4. CHANGED ⇒ re-run (`irDeepHashChanged`). UNCHANGED ⇒ leave for the file
  ##      check.
  ##
  ## Then fold the file index (a changed read file still re-runs an otherwise
  ## unchanged test). Tests reached by neither ⇒ SKIP.
  var r = initInvalidationResult()

  let tidsRes = s.testIds()
  if tidsRes.isErr: return err(tidsRes.error)

  for tid in tidsRes.value:
    # (1) stored deep hash
    let storedRes = s.deepHashOf(tid)
    if storedRes.isErr:
      r.flag(tid, irFailSafe); continue
    if storedRes.value.isNone:
      # No stored baseline ⇒ cannot prove unchanged ⇒ re-run.
      r.flag(tid, irFailSafe); continue
    let stored = storedRes.value.get

    # (2) collision safety: the id must intern back to the queried name.
    let expectedName = testNames.getOrDefault(tid, "")
    if expectedName.len == 0:
      # We do not know the name to verify against ⇒ cannot safely skip ⇒ re-run.
      r.flag(tid, irFailSafe); continue
    let verified = verifyTestIdName(s, tid, expectedName)
    if verified.isErr:
      r.flag(tid, irFailSafe); continue
    if not verified.value:
      # Collision / foreign-store signature ⇒ conservatively re-run.
      r.flag(tid, irFailSafe); continue

    # (3) recompute current deep hash
    let curRes = currentDeps(tid)
    if curRes.isErr:
      r.flag(tid, irFailSafe); continue
    if curRes.value.isNone:
      r.flag(tid, irFailSafe); continue
    let currentHash = rootHashOfDeps(curRes.value.get)

    # (4) compare
    if currentHash != stored:
      r.flag(tid, irDeepHashChanged)
    # else: unchanged so far — the file check below may still invalidate it.

  let fileRes = foldFileInvalidation(s, signal, r)
  if fileRes.isErr: return err(fileRes.error)
  ok(r)

# ---------------------------------------------------------------------------
# SHALLOW path — changed functions via the reverse map + the file index
# ---------------------------------------------------------------------------

proc rerunReaders(r: var InvalidationResult; fid: uint64; entry: ShallowEntry;
                  reason: InvalidationReason) =
  ## Mark every reader test of `fid` (its reverse set) for re-run with `reason`,
  ## and record the function id as changed (for naming). A module-level helper
  ## (not a nested closure) so it does not capture the loop's `lent` iterator
  ## variable.
  r.changedFunctions.incl fid
  for tid in entry.testIds:
    r.flag(tid, reason)

proc invalidateShallow*(s: CtfsStore; backend: TraceBackend;
                        sourceRoot: string;
                        signal: FileSignal): Result[InvalidationResult, string] =
  ## SHALLOW invalidation (Python/Ruby/JS/native). For every function id in the
  ## shallow reverse structure:
  ##
  ##   1. Read its stored `{shallow, identity, [testIds]}`. Read error ⇒ re-run
  ##      its reader tests (fail-safe).
  ##   2. COLLISION SAFETY: verify the function id interns back to the stored
  ##      identity. Mismatch/absent ⇒ treat as CHANGED ⇒ re-run its readers.
  ##   3. Recompute the function's CURRENT shallow hash from the current codebase
  ##      via the engine's backend hasher seam (the SAME hasher `record`/`decide`
  ##      use). Differs from the stored hash ⇒ the function CHANGED.
  ##   4. A changed function ⇒ via the REVERSE map, re-run exactly the tests whose
  ##      reverse set contains it (`irShallowFuncChanged`).
  ##
  ## Then UNION the tests invalidated via the file index. Every store test
  ## reached by neither ⇒ SKIP.
  ##
  ## The hasher seam is selected per `backend` (source/interpreted, CTFS-source,
  ## or native). A backend whose hasher is not wired ⇒ EVERY function is treated
  ## as changed (re-run everything) — never a skip.
  var r = initInvalidationResult()

  let strategies = backendStrategies(backend)
  let hasherWired = strategies.hasher.hashOf != nil

  let fidsRes = s.functionIds()
  if fidsRes.isErr: return err(fidsRes.error)

  for fid in fidsRes.value:
    let eRes = s.shallowEntryOf(fid)
    if eRes.isErr:
      # Cannot read this function entry: we have no test ids to re-run from it,
      # so surface the error and let the caller re-run the whole suite.
      return err(eRes.error)
    if eRes.value.isNone: continue
    let entry = eRes.value.get

    # (2) collision safety: the id must intern back to the stored identity.
    let identity = functionIdentityString(
      ExecutedFunction(name: entry.name, file: entry.file, defLine: entry.defLine))
    let verified = verifyFunctionIdentity(s, fid, identity)
    if verified.isErr:
      rerunReaders(r, fid, entry, irFailSafe); continue
    if (not verified.value) or key64(identity) != fid:
      # Collision / foreign-store / mis-keyed entry ⇒ treat as changed.
      rerunReaders(r, fid, entry, irFailSafe); continue

    if not hasherWired:
      # No hasher for this backend ⇒ cannot prove unchanged ⇒ re-run readers.
      rerunReaders(r, fid, entry, irFailSafe); continue

    # (3) recompute current shallow hash via the engine's own hasher seam. The
    # `ShallowHashProc` type is not annotated `raises: []`; the wired source and
    # native hashers never raise (they map every error to the `"missing"`
    # sentinel), but we guard defensively so any unexpected exception fail-safes
    # to a re-run of this function's readers rather than escaping the query.
    let fn = ExecutedFunction(name: entry.name, file: entry.file,
                              defLine: entry.defLine)
    var current: string
    var hashOk = true
    try:
      current = strategies.hasher.hashOf(fn, sourceRoot)
    except Exception:
      # The `ShallowHashProc` proc-type carries the inferred `Exception` effect
      # (it is not annotated `raises: []`), so we must catch the base `Exception`
      # to keep this query's `{.push raises: [].}` contract. Any escape ⇒ a
      # conservative re-run of this function's readers, never a skip.
      hashOk = false
    if (not hashOk) or current != entry.shallow:
      # (4) changed (or unhashably so) ⇒ re-run exactly this function's readers.
      rerunReaders(r, fid, entry, if hashOk: irShallowFuncChanged else: irFailSafe)

  let fileRes = foldFileInvalidation(s, signal, r)
  if fileRes.isErr: return err(fileRes.error)
  ok(r)

# ---------------------------------------------------------------------------
# Convenience: the skipped complement
# ---------------------------------------------------------------------------

proc skippedTests*(s: CtfsStore; r: InvalidationResult): Result[seq[uint64], string] =
  ## The test ids the query SKIPPED: every test present in the store's
  ## deep-forward map that is NOT in `r.rerun`, ascending. (The deep-forward map
  ## is the authoritative test set — every recorded test has a deep hash.)
  let tidsRes = s.testIds()
  if tidsRes.isErr: return err(tidsRes.error)
  var skipped: seq[uint64]
  for tid in tidsRes.value:
    if tid notin r.rerun:
      skipped.add tid
  skipped.sort()
  ok(skipped)
