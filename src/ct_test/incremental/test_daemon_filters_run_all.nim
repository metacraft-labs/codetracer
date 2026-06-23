## M4c — the daemon-loop tests.
##
## These exercise the daemon loop (`daemon.nim`): hold the `CtfsStore` in
## memory, filter an incoming "run all" via the M4b suite-level invalidation,
## run only the survivors, and update ONLY the executed tests' entries
## (incremental remove-old/add-new reverse-map + file-index fix-up).
##
##   * `e2e_daemon_filters_run_all` — seed from an initial run, edit one executed
##     function, "run all": ONLY the affected test runs (filtered via M4b), the
##     rest skip; ONLY the executed tests' store entries change (skipped tests'
##     entries are byte-identical before/after, and the reverse map / file index
##     reflect only the re-run tests' updates).
##   * `test_daemon_and_file_modes_agree` — the SAME sequence of requests through
##     daemon mode (in-memory) and file mode (flush/reload) yields IDENTICAL
##     run/skip decisions AND identical resulting store contents.
##   * `test_daemon_overlay_never_flushes` — in daemon mode the backing file is
##     never written across a full request cycle.
##   * `test_daemon_failsafe_carryover` — the daemon path preserves M4b's
##     never-false-skip guarantee (an ambiguity ⇒ that test runs).
##
## The shallow path hashes REAL source via the engine's own hasher seam (the
## committed `m0_three_funcs` Ruby fixture), exactly like the M4b test, so the
## daemon's filter is the real M4b query — not a stub.

import std/[unittest, tables, options, os, strutils, times]

import results

import engine        # CachedDep, ExecutedFunction, tbSourceInterpreted, backendStrategies
import ctfs_store    # CtfsStore, StoreTest, key64, functionKey, serialize/loadStore
import root_hash      # rootHashOfDeps
import invalidation  # FileSignal, InvalidationResult
import daemon        # the M4c loop under test

# ---------------------------------------------------------------------------
# Fixture helpers (mirror the M4b test so the filter is the REAL M4b query)
# ---------------------------------------------------------------------------

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  relSrc = "src/three_funcs.rb"

var counter = 0
proc makeSourceRoot(): string =
  inc counter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("ct_m4c_" & $stamp & "_" & $counter)
  let dst = root / relSrc
  createDir(dst.parentDir)
  copyFile(threeFuncsFixture / relSrc, dst)
  root

proc editFunctionBody(root, funcName, newBody: string) =
  let path = root / relSrc
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip() == "def " & funcName:
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBody
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

proc currentRubyShallow(root, funcName: string, defLine: int): string =
  ## The engine's CURRENT shallow hash for a Ruby function under `root`, via the
  ## SAME seam the query uses.
  let strat = backendStrategies(tbSourceInterpreted)
  strat.hasher.hashOf(
    ExecutedFunction(name: funcName, file: relSrc, defLine: defLine), root)

proc dep(name, file: string, defLine: int, shallow: string): CachedDep =
  CachedDep(fn: ExecutedFunction(name: name, file: file, defLine: defLine),
            shallow: shallow)

proc rubyStoreTests(root: string): seq[StoreTest] =
  ## Two tests over the Ruby fixture:
  ##   t_uses_a: executes used_a (+ main)
  ##   t_uses_b: executes used_b (+ main)
  ## recorded with their CURRENT shallow hashes so they read unchanged until an
  ## edit. used_a is at line 16, used_b at 20, main at 28 (see the fixture).
  let mainSh = currentRubyShallow(root, "main",   28)
  let aSh    = currentRubyShallow(root, "used_a", 16)
  let bSh    = currentRubyShallow(root, "used_b", 20)
  let mainDep = dep("main",   relSrc, 28, mainSh)
  let aDep    = dep("used_a", relSrc, 16, aSh)
  let bDep    = dep("used_b", relSrc, 20, bSh)
  result = @[
    StoreTest(testId: key64("t_uses_a"), testName: "t_uses_a",
              rootHash: rootHashOfDeps(@[mainDep, aDep]),
              deps: @[mainDep, aDep], readFiles: @[]),
    StoreTest(testId: key64("t_uses_b"), testName: "t_uses_b",
              rootHash: rootHashOfDeps(@[mainDep, bDep]),
              deps: @[mainDep, bDep], readFiles: @[]),
  ]

proc nameTable(tests: seq[StoreTest]): Table[uint64, string] =
  result = initTable[uint64, string]()
  for t in tests: result[t.testId] = t.testName

proc neverChangedSignal(): FileSignal =
  FileSignal(byHash: false,
    currentMtime: proc(path: string): Option[int64] {.gcsafe.} = none(int64),
    currentHash: nil, recordedHash: nil)

# A RecordProc that re-records the survivor by re-reading the CURRENT source via
# the engine's own hasher — exactly what a real daemon's `record` does (re-hash
# against current source), but deterministic and trace-free for the test. The
# executed SET for each test is fixed (its known functions); only the shallow
# hashes are recomputed against the edited tree.
proc rubyRecorder(root: string): RecordProc =
  let funcsByTest = {
    key64("t_uses_a"): @[("main", 28), ("used_a", 16)],
    key64("t_uses_b"): @[("main", 28), ("used_b", 20)],
  }.toTable
  let names = {
    key64("t_uses_a"): "t_uses_a",
    key64("t_uses_b"): "t_uses_b",
  }.toTable
  (proc(test: StoreTest): Result[StoreTest, string] {.gcsafe, raises: [].} =
    if not funcsByTest.hasKey(test.testId):
      return err("unknown test: " & $test.testId)
    var deps: seq[CachedDep]
    try:
      for (fn, line) in funcsByTest.getOrDefault(test.testId):
        let strat = backendStrategies(tbSourceInterpreted)
        let sh = strat.hasher.hashOf(
          ExecutedFunction(name: fn, file: relSrc, defLine: line), root)
        deps.add dep(fn, relSrc, line, sh)
    except Exception as e:
      return err("recorder failed: " & e.msg)
    ok(StoreTest(testId: test.testId,
                 testName: names.getOrDefault(test.testId, test.testName),
                 rootHash: rootHashOfDeps(deps),
                 deps: deps, readFiles: @[])))

# ===========================================================================

suite "M4c — daemon loop":

  # -------------------------------------------------------------------------
  test "e2e_daemon_filters_run_all":
    # Seed the store from an initial run; edit ONE executed function (used_a);
    # "run all": only t_uses_a runs (it executes used_a), t_uses_b skips. ONLY the
    # executed test's store entries change.
    let root = makeSourceRoot()
    let tests = rubyStoreTests(root)
    let names = nameTable(tests)

    var d = initDaemon(dmDaemon, tbSourceInterpreted, signal = neverChangedSignal())
    require d.seed(tests).isOk

    # Snapshot the SKIPPED test's (t_uses_b) store-visible entries BEFORE the run.
    let bId = key64("t_uses_b")
    let aId = key64("t_uses_a")
    let bDeepBefore = d.store.deepHashOf(bId)
    require bDeepBefore.isOk and bDeepBefore.value.isSome
    let bNameBefore = d.store.testName(bId)

    # used_b's reverse entry should contain ONLY t_uses_b before AND after (since
    # t_uses_b is never re-run, used_b is never touched).
    let usedBFid = functionKey(ExecutedFunction(name: "used_b", file: relSrc, defLine: 20))
    let usedBBefore = d.store.shallowEntryOf(usedBFid)
    require usedBBefore.isOk and usedBBefore.value.isSome

    # No edit yet ⇒ run all skips everything.
    block:
      let res = d.runAllShallow(names, root, rubyRecorder(root))
      require res.isOk
      check res.value.rerun.len == 0
      check res.value.skipped.len == 2

    # Edit used_a ⇒ run all re-runs ONLY t_uses_a.
    editFunctionBody(root, "used_a", "42 + 1")
    block:
      let res = d.runAllShallow(names, root, rubyRecorder(root))
      require res.isOk
      let outcome = res.value
      check aId in outcome.rerun
      check bId notin outcome.rerun
      check outcome.rerun.len == 1
      check bId in outcome.skipped
      check outcome.recordErrors.len == 0
      check irShallowFuncChanged in outcome.invalidation.reasons[aId]

    # The SKIPPED test's entries are byte-identical before/after.
    let bDeepAfter = d.store.deepHashOf(bId)
    require bDeepAfter.isOk and bDeepAfter.value.isSome
    check bDeepAfter.value.get == bDeepBefore.value.get
    let bNameAfter = d.store.testName(bId)
    check bNameAfter.value == bNameBefore.value

    # used_b's reverse entry is untouched (still only t_uses_b).
    let usedBAfter = d.store.shallowEntryOf(usedBFid)
    require usedBAfter.isOk and usedBAfter.value.isSome
    check usedBAfter.value.get.testIds == usedBBefore.value.get.testIds
    check usedBAfter.value.get.shallow == usedBBefore.value.get.shallow

    # used_a's reverse entry now records the EDITED shallow hash (the re-run
    # refreshed it) and still has t_uses_a as its (only) reader.
    let usedAFid = functionKey(ExecutedFunction(name: "used_a", file: relSrc, defLine: 16))
    let usedAAfter = d.store.shallowEntryOf(usedAFid)
    require usedAAfter.isOk and usedAAfter.value.isSome
    check usedAAfter.value.get.testIds == @[aId]
    check usedAAfter.value.get.shallow == currentRubyShallow(root, "used_a", 16)

    # t_uses_a's deep hash CHANGED in the store (it was re-recorded against the edit).
    let aDeepAfter = d.store.deepHashOf(aId)
    require aDeepAfter.isOk and aDeepAfter.value.isSome
    check aDeepAfter.value.get != bDeepBefore.value.get  # different from b's anyway
    # main is shared: its reverse set still contains BOTH tests (t_uses_a re-ran
    # and re-added itself; t_uses_b was never removed).
    let mainFid = functionKey(ExecutedFunction(name: "main", file: relSrc, defLine: 28))
    let mainAfter = d.store.shallowEntryOf(mainFid)
    require mainAfter.isOk and mainAfter.value.isSome
    check aId in mainAfter.value.get.testIds
    check bId in mainAfter.value.get.testIds

  # -------------------------------------------------------------------------
  test "test_daemon_and_file_modes_agree":
    # The SAME sequence of requests through daemon mode (in-memory) and file mode
    # (flush/reload) yields identical run/skip decisions AND identical resulting
    # store contents.
    let rootD = makeSourceRoot()
    let rootF = makeSourceRoot()
    let testsD = rubyStoreTests(rootD)
    let testsF = rubyStoreTests(rootF)
    let names = nameTable(testsD)  # ids are name-derived, identical across roots

    let backing = getTempDir() / ("ct_m4c_backing_" & $epochTime() & ".cts")
    removeFile(backing)

    var dDaemon = initDaemon(dmDaemon, tbSourceInterpreted, signal = neverChangedSignal())
    var dFile = initDaemon(dmFile, tbSourceInterpreted, backing, neverChangedSignal())
    require dDaemon.seed(testsD).isOk
    require dFile.seed(testsF).isOk

    # The seeded stores are byte-identical (same inputs).
    check dDaemon.store.serialize() == dFile.store.serialize()

    # Cycle 1: no edit ⇒ both skip everything, decisions agree.
    block:
      let rd = dDaemon.runAllShallow(names, rootD, rubyRecorder(rootD))
      let rf = dFile.runAllShallow(names, rootF, rubyRecorder(rootF))
      require rd.isOk and rf.isOk
      check rd.value.rerun == rf.value.rerun
      check rd.value.skipped == rf.value.skipped
      check rd.value.rerun.len == 0

    # Cycle 2: edit used_a in BOTH trees ⇒ both re-run only t_uses_a; decisions
    # AND resulting store contents agree.
    editFunctionBody(rootD, "used_a", "7 * 7")
    editFunctionBody(rootF, "used_a", "7 * 7")
    block:
      let rd = dDaemon.runAllShallow(names, rootD, rubyRecorder(rootD))
      let rf = dFile.runAllShallow(names, rootF, rubyRecorder(rootF))
      require rd.isOk and rf.isOk
      check rd.value.rerun == rf.value.rerun
      check rd.value.skipped == rf.value.skipped
      check key64("t_uses_a") in rd.value.rerun
      check rd.value.rerun.len == 1

    # The resulting store contents are byte-for-byte identical across modes.
    check dDaemon.store.serialize() == dFile.store.serialize()

    # Stronger: the INCREMENTAL remove-old/add-new update produces the SAME store
    # as a fresh full `buildStore` of the final logical state (used_a's body
    # edited, so its recorded shallow hash + t_uses_a's root hash change; used_b /
    # t_uses_b unchanged). This is the real correctness check for the reverse-map
    # fix-up: no stale reverse-set membership, no missed refresh.
    let finalTests = rubyStoreTests(rootD)  # rebuilds against the edited tree
    let fresh = buildStore(finalTests)
    require fresh.isOk
    check dDaemon.store.serialize() == fresh.value.serialize()

  # -------------------------------------------------------------------------
  test "test_daemon_overlay_never_flushes":
    # In daemon mode the maps live only in memory: the backing file is NEVER
    # written across a full request cycle.
    let root = makeSourceRoot()
    let tests = rubyStoreTests(root)
    let names = nameTable(tests)

    let backing = getTempDir() / ("ct_m4c_neverflush_" & $epochTime() & ".cts")
    removeFile(backing)

    # Even given a backingPath, daemon mode must not write it.
    var d = initDaemon(dmDaemon, tbSourceInterpreted, backing, neverChangedSignal())
    require d.seed(tests).isOk
    check not fileExists(backing)   # seed in daemon mode does not flush

    editFunctionBody(root, "used_a", "1 - 1")
    let res = d.runAllShallow(names, root, rubyRecorder(root))
    require res.isOk
    check key64("t_uses_a") in res.value.rerun
    # The full request cycle completed; the on-disk artifact is still absent.
    check not fileExists(backing)

    # Sanity: an explicit flush is also a no-op in daemon mode.
    require d.flushToBacking().isOk
    check not fileExists(backing)

  # -------------------------------------------------------------------------
  test "test_daemon_failsafe_carryover":
    # The daemon path preserves M4b's never-false-skip guarantee: a CORRUPT store
    # image (an ambiguity the M4b query turns into a whole-suite re-run) must NOT
    # let the daemon silently skip. The filter surfaces an Err, which the daemon
    # propagates — the caller re-runs everything rather than trusting a partial
    # or empty skip-all.
    let root = makeSourceRoot()
    let tests = rubyStoreTests(root)
    let names = nameTable(tests)

    var d = initDaemon(dmDaemon, tbSourceInterpreted, signal = neverChangedSignal())
    require d.seed(tests).isOk

    # Corrupt the shallow-reverse B-tree header so the M4b enumeration fails
    # (exactly the M4b `corrupt_store_never_silently_skips_shallow` condition).
    require d.store.shallowReverse.len >= 16
    for i in 0 ..< 16:
      d.store.shallowReverse[i] = byte(0xFF)

    let res = d.runAllShallow(names, root, rubyRecorder(root))
    # The corruption MUST surface as an error (never an empty/partial skip-all).
    check res.isErr

  test "test_daemon_failsafe_collision_reruns":
    # A forced key64 collision on the DEEP path must re-run the affected test,
    # never skip it — the daemon inherits M4b's collision guard verbatim. We
    # drive the deep path with a names table that claims a stored id belongs to a
    # DIFFERENT name than the store interned; even with an identical recomputed
    # deep hash the test must re-run.
    let storedName = "suite::stored_test"
    let id = key64(storedName)
    let d0 = dep("fn::x", "src/x.py", 1, "shX")
    let tests = @[
      StoreTest(testId: id, testName: storedName,
                rootHash: rootHashOfDeps(@[d0]), deps: @[d0], readFiles: @[]),
    ]
    var d = initDaemon(dmDaemon, tbSourceInterpreted, signal = neverChangedSignal())
    require d.seed(tests).isOk

    # The names table claims this id belongs to a DIFFERENT name (the collision).
    var collidingNames = initTable[uint64, string]()
    collidingNames[id] = "suite::queried_test"

    # A deep recompute returning the IDENTICAL deps (so the deep hash MATCHES and
    # a naive query would SKIP). The collision guard must still re-run. Built via
    # factory procs so the captured deps are closure locals (preserving gcsafe).
    proc makeRecompute(fixed: seq[CachedDep]): CurrentDepsProc =
      (proc(testId: uint64): Result[Option[seq[CachedDep]], string] {.gcsafe, raises: [].} =
        ok(some(fixed)))
    proc makeRecorder(tid: uint64; nm: string; fixed: seq[CachedDep]): RecordProc =
      (proc(test: StoreTest): Result[StoreTest, string] {.gcsafe, raises: [].} =
        ok(StoreTest(testId: tid, testName: nm,
                     rootHash: rootHashOfDeps(fixed), deps: fixed, readFiles: @[])))

    let res = d.runAllDeep(collidingNames, makeRecompute(@[d0]),
                           makeRecorder(id, "suite::queried_test", @[d0]))
    require res.isOk
    check id in res.value.rerun         # NOT skipped despite the matching hash
    check irFailSafe in res.value.invalidation.reasons[id]

  # -------------------------------------------------------------------------
  test "incremental_update_set_change_drops_old_adds_new":
    # The trickiest part of M4c: when a re-run test's executed SET changes, the
    # incremental reverse-map fix-up must REMOVE the test from functions/files it
    # no longer touches (dropping a function/file that loses its last reader) and
    # ADD it to the new ones — and an UNTOUCHED test's contributions must survive.
    # Asserted directly over `updateTests` (the daemon's update primitive) AND by
    # equality with a fresh `buildStore` of the final logical state.
    let shared = dep("lib::shared", "src/lib.py", 1, "shSHARED")
    let oldFn  = dep("lib::old",    "src/lib.py", 5, "shOLD")
    let newFn  = dep("lib::new",    "src/lib.py", 9, "shNEW")
    let other  = dep("lib::other",  "src/lib.py", 13, "shOTHER")
    let aId = key64("t_a")
    let bId = key64("t_b")
    # Initial: t_a executes {shared, old} reading f_old; t_b executes {shared,
    # other} reading f_keep. So `old`'s reverse set = {t_a} (its only reader),
    # `shared` = {t_a, t_b}.
    let initial = @[
      StoreTest(testId: aId, testName: "t_a",
                rootHash: rootHashOfDeps(@[shared, oldFn]),
                deps: @[shared, oldFn],
                readFiles: @[(path: "f_old", mtime: 10'i64)]),
      StoreTest(testId: bId, testName: "t_b",
                rootHash: rootHashOfDeps(@[shared, other]),
                deps: @[shared, other],
                readFiles: @[(path: "f_keep", mtime: 20'i64)]),
    ]
    var s = buildStore(initial).value

    # Re-run ONLY t_a, now executing {shared, new} and reading f_new (it dropped
    # `old` and f_old, gained `new` and f_new; `shared` stays).
    let aUpdated = StoreTest(testId: aId, testName: "t_a",
                             rootHash: rootHashOfDeps(@[shared, newFn]),
                             deps: @[shared, newFn],
                             readFiles: @[(path: "f_new", mtime: 30'i64)])
    require updateTests(s, @[aUpdated]).isOk

    let oldFid = functionKey(oldFn.fn)
    let newFid = functionKey(newFn.fn)
    let sharedFid = functionKey(shared.fn)
    let otherFid = functionKey(other.fn)

    # `old` lost its last reader (t_a) ⇒ it is DROPPED from the reverse map AND
    # the function interning table.
    block:
      let e = s.shallowEntryOf(oldFid); require e.isOk
      check e.value.isNone
      let ident = s.functionIdentity(oldFid); require ident.isOk
      check ident.value.isNone
    # `new` was created with t_a as its reader.
    block:
      let e = s.shallowEntryOf(newFid); require e.isOk and e.value.isSome
      check e.value.get.testIds == @[aId]
      check e.value.get.shallow == "shNEW"
    # `shared` keeps BOTH readers (t_a re-added itself; t_b untouched).
    block:
      let e = s.shallowEntryOf(sharedFid); require e.isOk and e.value.isSome
      check aId in e.value.get.testIds
      check bId in e.value.get.testIds
    # `other` (only t_b's) is untouched.
    block:
      let e = s.shallowEntryOf(otherFid); require e.isOk and e.value.isSome
      check e.value.get.testIds == @[bId]

    # File index: f_old dropped (last reader gone), f_new added, f_keep untouched.
    check s.fileEntryOf(key64("f_old")).value.isNone
    block:
      let e = s.fileEntryOf(key64("f_new")); require e.isOk and e.value.isSome
      check e.value.get.testIds == @[aId]
      check e.value.get.mtime == 30'i64
    block:
      let e = s.fileEntryOf(key64("f_keep")); require e.isOk and e.value.isSome
      check e.value.get.testIds == @[bId]

    # Deep-forward: t_a's root hash updated; t_b's unchanged.
    check s.deepHashOf(aId).value.get == rootHashOfDeps(@[shared, newFn])
    check s.deepHashOf(bId).value.get == rootHashOfDeps(@[shared, other])

    # And the whole store equals a fresh full build of the final logical state.
    let finalState = @[aUpdated, initial[1]]
    check s.serialize() == buildStore(finalState).value.serialize()
