{.push raises: [].}

## The DAEMON LOOP — the M4c deliverable of the Incremental-Test-Runner
## campaign: hold the `CtfsStore` in memory, filter an incoming "run all"
## request via the M4b suite-level invalidation, run only the survivors, and
## update ONLY the executed tests' entries.
##
## # One store, two modes (the point of the in-memory approach)
##
## M3's corrected benchmark put the in-memory CoW overlay back in scope so that
## the file-based and daemon modes share ONE code path. This module realises
## that: a `Daemon` ALWAYS operates on a single `CtfsStore` value through the
## SAME store API (`invalidation.invalidateShallow/Deep`, `ctfs_store.updateTests`).
## The only difference between the two modes is what happens at the cycle
## boundary:
##
##   * `dmDaemon` (`keepInMemory = true`): the `CtfsStore` is held in memory
##     across requests and NEVER flushed. The maps live only in RAM.
##   * `dmFile` (`keepInMemory = false`): the store is FLUSHED to its backing
##     file (`serialize`) at the end of each cycle and RELOADED from it
##     (`loadStore`) at the start of the next — exactly the on-disk artifact the
##     M4a/M2 codec persists. The decision logic in between is byte-for-byte the
##     same code as the daemon path.
##
## Because both modes run the IDENTICAL invalidation query over the IDENTICAL
## `CtfsStore` contents and apply the IDENTICAL `updateTests`, they produce
## IDENTICAL run/skip decisions AND identical resulting store contents for the
## same sequence of requests (`test_daemon_and_file_modes_agree`). File mode
## merely round-trips the store through `serialize`/`loadStore` between cycles,
## which is lossless.
##
## # A "run all" request
##
## `runAll` takes the full known test set (the "run all" universe) and:
##
##   1. FILTER — calls the M4b invalidation query (deep or shallow path,
##      selected by the test backend) over the in-memory store. The query
##      returns the test ids to RE-RUN; every other store test is SKIPPED. The
##      fail-safe contract is inherited verbatim from M4b: any ambiguity (a
##      collision, an unreadable current state, a corrupt store image) RE-RUNS,
##      never skips.
##   2. RUN — re-executes ("records") only the survivors via the injected
##      `RecordProc` seam (in production the engine's `record` path on the test's
##      fixture; in tests a deterministic recompute). The seam returns each
##      re-run test's NEW `StoreTest` (its new root hash + executed-function set
##      with current shallow hashes + read files).
##   3. UPDATE — applies `ctfs_store.updateTests` for EXACTLY the survivors. That
##      upserts each re-run test's deep hash and incrementally fixes the shallow
##      reverse map + file index (remove the test's OLD function/file
##      contributions, add its NEW ones). SKIPPED tests' entries are not touched.
##
## # FAIL-SAFE (carried over from M4b)
##
## The daemon never weakens M4b's never-false-skip guarantee. The filter step IS
## the M4b query, so every conservative re-run it produces (collision,
## unreadable state, corrupt store) flows straight through to the run set. A
## record failure for a survivor is surfaced as an `Err` for that test (the
## caller re-runs it next cycle) and never recorded as a skip-eligible entry.

import std/[os, tables, sets, algorithm]
import results

import engine        # CachedDep, TraceBackend, tbSourceInterpreted ...
import root_hash      # rootHashOfDeps
import ctfs_store     # CtfsStore, StoreTest, key64, serialize/loadStore, updateTests
import invalidation  # the M4b suite-level query

export results
export ctfs_store
export invalidation

type
  DaemonMode* = enum
    ## Which cycle-boundary policy the daemon runs under. Both modes share the
    ## SAME store API and decision logic; they differ ONLY in whether the store
    ## is held in memory or round-tripped through the backing file each cycle.
    dmDaemon   ## hold the `CtfsStore` in memory, never flush (`keepInMemory`)
    dmFile     ## flush to + reload from the backing file each cycle

  RecordProc* = proc(test: StoreTest): Result[StoreTest, string]
    {.closure, gcsafe, raises: [].}
    ## Re-run ("record") one survivor and return its NEW `StoreTest` — its new
    ## root hash + executed-function set (each with its CURRENT shallow hash) +
    ## read files. In production this wraps the engine's `record` on the test's
    ## fixture (re-extract the executed set, re-hash against current source); the
    ## tests inject a deterministic recompute. An `Err` means the re-run could not
    ## produce a usable record (e.g. the trace is unreadable) — the daemon does
    ## NOT update that test's entry, so it stays in its prior state and re-runs
    ## again next cycle (never silently skipped).

  Daemon* = object
    ## The daemon's held state. `store` is the in-memory `CtfsStore`; `mode`
    ## picks the cycle-boundary policy; `backingPath` is the file `dmFile` uses
    ## (and `dmDaemon` deliberately never writes). `signal` is the file-change
    ## probe the M4b file fold uses; `backend` selects the shallow vs deep query
    ## path and the hasher seam.
    store*: CtfsStore
    mode*: DaemonMode
    backingPath*: string
    backend*: TraceBackend
    signal*: FileSignal

  RunAllOutcome* = object
    ## The result of one "run all" request. `rerun`/`skipped` are the filter's
    ## verdict (test ids); `recordErrors` names any survivor whose re-run failed
    ## (its entry was left unchanged and it will re-run again). `result` is the
    ## raw M4b verdict (reasons, changed functions/files) for the daemon report.
    rerun*: seq[uint64]
    skipped*: seq[uint64]
    recordErrors*: Table[uint64, string]
    invalidation*: InvalidationResult

# ---------------------------------------------------------------------------
# Cycle boundary — the ONE place daemon vs file mode differ
# ---------------------------------------------------------------------------

proc flushToBacking*(d: Daemon): Result[void, string] =
  ## Flush the in-memory store to its backing file. A no-op (and a deliberate
  ## one) in `dmDaemon`: the daemon NEVER writes its backing file — the maps live
  ## only in memory. In `dmFile` this is the persistence that makes the next
  ## cycle reload from disk. Requires `backingPath` to be set in file mode.
  if d.mode == dmDaemon:
    return ok()  # daemon mode never flushes (the overlay-never-flushes contract)
  if d.backingPath.len == 0:
    return err("file mode requires a backingPath to flush")
  try:
    let dir = d.backingPath.parentDir
    if dir.len > 0: createDir(dir)
    writeFile(d.backingPath, cast[string](d.store.serialize()))
  except CatchableError as e:
    return err("failed to flush store to " & d.backingPath & ": " & e.msg)
  ok()

proc reloadFromBacking(d: var Daemon): Result[void, string] =
  ## Reload the store from the backing file (file mode only). In daemon mode the
  ## in-memory store IS the source of truth, so there is nothing to reload — the
  ## same `CtfsStore` value carries across the cycle untouched.
  if d.mode == dmDaemon:
    return ok()
  if d.backingPath.len == 0:
    return err("file mode requires a backingPath to reload")
  if not fileExists(d.backingPath):
    return err("backing store file missing: " & d.backingPath)
  var raw: string
  try:
    raw = readFile(d.backingPath)
  except CatchableError as e:
    return err("failed to read backing store " & d.backingPath & ": " & e.msg)
  let loaded = loadStore(cast[seq[byte]](raw))
  if loaded.isErr: return err(loaded.error)
  d.store = loaded.value
  ok()

# ---------------------------------------------------------------------------
# Construction + seeding
# ---------------------------------------------------------------------------

proc initDaemon*(mode: DaemonMode; backend = tbSourceInterpreted;
                 backingPath = ""; signal = FileSignal()): Daemon =
  ## A fresh daemon with an EMPTY store (no tests recorded yet). `keepInMemory`
  ## on the store mirrors the mode so the store's own intent flag is consistent.
  var s = buildStore(@[]).value  # an empty store always builds
  s.keepInMemory = mode == dmDaemon
  Daemon(store: s, mode: mode, backingPath: backingPath,
         backend: backend, signal: signal)

proc seed*(d: var Daemon; tests: seq[StoreTest]): Result[void, string] =
  ## Seed the daemon from an initial run of the whole suite (every test's first
  ## record). Builds the full store by inverting the per-test executed sets, then
  ## — in file mode — flushes it to the backing file so the next cycle reloads
  ## from disk (the daemon mode keeps it in memory).
  let built = buildStore(tests)
  if built.isErr: return err(built.error)
  d.store = built.value
  d.store.keepInMemory = d.mode == dmDaemon
  if d.mode == dmFile:
    return d.flushToBacking()
  ok()

# ---------------------------------------------------------------------------
# The "run all" request
# ---------------------------------------------------------------------------

proc runAllShallow*(d: var Daemon; testNames: Table[uint64, string];
                    sourceRoot: string; record: RecordProc):
    Result[RunAllOutcome, string] =
  ## Handle a "run all" request on the SHALLOW path (Python/Ruby/JS/native).
  ##
  ##   1. (file mode) reload the store from the backing file.
  ##   2. FILTER via `invalidateShallow` over the in-memory store.
  ##   3. RUN only the survivors via `record`.
  ##   4. UPDATE only the executed tests' entries via `updateTests`.
  ##   5. (file mode) flush the store back to the backing file.
  ##
  ## Daemon mode does steps 2-4 entirely in memory and never touches the backing
  ## file (steps 1 and 5 are no-ops). The two modes therefore share one code
  ## path and produce identical decisions + identical store contents.
  let rl = d.reloadFromBacking()
  if rl.isErr: return err(rl.error)

  let invRes = invalidateShallow(d.store, d.backend, sourceRoot, d.signal)
  if invRes.isErr: return err(invRes.error)
  let inv = invRes.value

  let skippedRes = skippedTests(d.store, inv)
  if skippedRes.isErr: return err(skippedRes.error)

  # RUN the survivors. We re-run exactly the filtered set, in ascending id order
  # for determinism. The caller supplies the universe via `testNames` (every
  # known test); we only re-run those the filter selected (a re-run id must be a
  # known test — an unknown re-run id is surfaced as an error, never skipped).
  var rerunIds: seq[uint64]
  for tid in inv.rerun: rerunIds.add tid
  rerunIds.sort()

  var updated: seq[StoreTest]
  var recordErrors = initTable[uint64, string]()
  for tid in rerunIds:
    if tid notin testNames:
      recordErrors[tid] = "re-run id not in the known test set"
      continue
    # The record seam needs at least the test id + name to locate its fixture.
    let stub = StoreTest(testId: tid, testName: testNames.getOrDefault(tid, ""),
                         rootHash: "", deps: @[], readFiles: @[])
    let rec = record(stub)
    if rec.isErr:
      recordErrors[tid] = rec.error
      continue
    updated.add rec.value

  # UPDATE only the executed tests' entries (incremental reverse-map fix-up).
  if updated.len > 0:
    let upd = updateTests(d.store, updated)
    if upd.isErr: return err(upd.error)

  let fl = d.flushToBacking()
  if fl.isErr: return err(fl.error)

  ok(RunAllOutcome(
    rerun: rerunIds, skipped: skippedRes.value,
    recordErrors: recordErrors, invalidation: inv))

proc runAllDeep*(d: var Daemon; testNames: Table[uint64, string];
                 currentDeps: CurrentDepsProc; record: RecordProc):
    Result[RunAllOutcome, string] =
  ## Handle a "run all" request on the DEEP path (Nim `symBodyHash` case). Same
  ## five steps as `runAllShallow` but the filter is `invalidateDeep` (recompute
  ## each test's deep hash via `currentDeps` and compare to the forward map). The
  ## update step is identical (`updateTests` for the survivors).
  let rl = d.reloadFromBacking()
  if rl.isErr: return err(rl.error)

  let invRes = invalidateDeep(d.store, testNames, currentDeps, d.signal)
  if invRes.isErr: return err(invRes.error)
  let inv = invRes.value

  let skippedRes = skippedTests(d.store, inv)
  if skippedRes.isErr: return err(skippedRes.error)

  var rerunIds: seq[uint64]
  for tid in inv.rerun: rerunIds.add tid
  rerunIds.sort()

  var updated: seq[StoreTest]
  var recordErrors = initTable[uint64, string]()
  for tid in rerunIds:
    if tid notin testNames:
      recordErrors[tid] = "re-run id not in the known test set"
      continue
    let stub = StoreTest(testId: tid, testName: testNames.getOrDefault(tid, ""),
                         rootHash: "", deps: @[], readFiles: @[])
    let rec = record(stub)
    if rec.isErr:
      recordErrors[tid] = rec.error
      continue
    updated.add rec.value

  if updated.len > 0:
    let upd = updateTests(d.store, updated)
    if upd.isErr: return err(upd.error)

  let fl = d.flushToBacking()
  if fl.isErr: return err(fl.error)

  ok(RunAllOutcome(
    rerun: rerunIds, skipped: skippedRes.value,
    recordErrors: recordErrors, invalidation: inv))
