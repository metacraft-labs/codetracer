## M4b — `test_invalidation_via_reverse_map` (+ the deep, file, collision, and
## fail-safe cases).
##
## These tests exercise the SUITE-LEVEL invalidation query (`invalidation.nim`)
## over a `CtfsStore`, covering the team-confirmed model:
##
##   * SHALLOW (reverse map): editing function F's body invalidates EXACTLY the
##     tests whose reverse-map set contains F, and ONLY those.
##   * DEEP (forward map): a test whose recomputed deep hash changed re-runs; one
##     whose deep hash is unchanged is skipped (then file-checked).
##   * FILE input: a changed read file (mtime/hash) re-runs the tests that read
##     it, in BOTH the deep and shallow cases; an unchanged file does not.
##   * COLLISION fail-safe: a forced `key64` collision between two distinct names
##     does NOT cause a false skip — the colliding tests are conservatively
##     re-run.
##   * STORE fail-safe: a missing/unreadable store entry ⇒ re-run, never skip.
##
## The shallow path hashes REAL source via the engine's own hasher seam (the
## committed `m0_three_funcs` Ruby fixture); the deep path drives a deterministic
## injected recompute; the reverse-map / collision cases use synthetic stores so
## the reverse fan-in is exact and a collision can be injected.

import std/[unittest, tables, sets, options, os, strutils, times]

import results

import engine        # CachedDep, ExecutedFunction, shallowHash, tbSourceInterpreted
import ctfs_store    # CtfsStore, StoreTest, buildStore, key64, functionKey
import root_hash      # rootHashOfDeps
import invalidation  # the M4b query under test

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc dep(name, file: string, defLine: int, shallow: string): CachedDep =
  CachedDep(fn: ExecutedFunction(name: name, file: file, defLine: defLine),
            shallow: shallow)

proc neverChangedSignal(): FileSignal =
  ## A file signal under which NO read file ever changes: every recorded mtime
  ## is reported back unchanged. (We capture the store's recorded entries via a
  ## closure over a path->mtime table populated per test.)
  FileSignal(byHash: false,
    currentMtime: proc(path: string): Option[int64] {.gcsafe.} = none(int64),
    currentHash: nil, recordedHash: nil)

proc nameTable(tests: seq[StoreTest]): Table[uint64, string] =
  result = initTable[uint64, string]()
  for t in tests: result[t.testId] = t.testName

# A deep-recompute that returns, for each test, the SAME deps it was recorded
# with (so the deep hash is unchanged) UNLESS the test id is in `changed`, in
# which case one dep's shallow hash is perturbed (so the deep hash changes).
proc deepRecompute(tests: seq[StoreTest];
                   changed: HashSet[uint64]): CurrentDepsProc =
  var byId = initTable[uint64, seq[CachedDep]]()
  for t in tests: byId[t.testId] = t.deps
  let changedSet = changed
  (proc(testId: uint64): Result[Option[seq[CachedDep]], string] {.gcsafe.} =
    if not byId.hasKey(testId):
      return ok(none(seq[CachedDep]))
    var deps = byId.getOrDefault(testId)
    if testId in changedSet and deps.len > 0:
      deps[0].shallow = deps[0].shallow & "_EDITED"
    ok(some(deps)))

# ---------------------------------------------------------------------------
# Synthetic corpus with real reverse fan-in
# ---------------------------------------------------------------------------

proc reverseMapTests(): seq[StoreTest] =
  ## Three tests sharing functions:
  ##   alpha: helper, onlyA
  ##   beta:  helper, onlyB
  ##   gamma: util
  ## So `helper`'s reverse set is {alpha, beta}, `onlyA` is {alpha},
  ## `onlyB` is {beta}, `util` is {gamma}.
  let helper = dep("lib::helper", "src/lib.py", 10, "shHELPER")
  let onlyA  = dep("a::only",     "src/a.py",   3,  "shONLYA")
  let onlyB  = dep("b::only",     "src/b.py",   7,  "shONLYB")
  let util   = dep("lib::util",   "src/lib.py", 40, "shUTIL")
  let names = ["s::test_alpha", "s::test_beta", "s::test_gamma"]
  result = @[
    StoreTest(testId: key64(names[0]), testName: names[0],
              rootHash: rootHashOfDeps(@[helper, onlyA]),
              deps: @[helper, onlyA], readFiles: @[]),
    StoreTest(testId: key64(names[1]), testName: names[1],
              rootHash: rootHashOfDeps(@[helper, onlyB]),
              deps: @[helper, onlyB], readFiles: @[]),
    StoreTest(testId: key64(names[2]), testName: names[2],
              rootHash: rootHashOfDeps(@[util]),
              deps: @[util], readFiles: @[]),
  ]

# ---------------------------------------------------------------------------
# Real-source fixture (the committed m0_three_funcs Ruby program)
# ---------------------------------------------------------------------------

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  relSrc = "src/three_funcs.rb"

var counter = 0
proc makeSourceRoot(): string =
  inc counter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("ct_m4b_" & $stamp & "_" & $counter)
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
  ## SAME seam the query uses — so a recorded store built with these values reads
  ## "unchanged" until the source is edited.
  let strat = backendStrategies(tbSourceInterpreted)
  strat.hasher.hashOf(
    ExecutedFunction(name: funcName, file: relSrc, defLine: defLine), root)

proc rubyStore(root: string): seq[StoreTest] =
  ## Two tests over the Ruby fixture:
  ##   t_uses_a: executes used_a (+ main)
  ##   t_uses_b: executes used_b (+ main)
  ## recorded with their CURRENT shallow hashes so they read unchanged until an
  ## edit. used_a is at line 16, used_b at 20, main at 28 (see the fixture).
  let mainSh  = currentRubyShallow(root, "main",   28)
  let aSh      = currentRubyShallow(root, "used_a", 16)
  let bSh      = currentRubyShallow(root, "used_b", 20)
  let mainDep = dep("main",   relSrc, 28, mainSh)
  let aDep     = dep("used_a", relSrc, 16, aSh)
  let bDep     = dep("used_b", relSrc, 20, bSh)
  result = @[
    StoreTest(testId: key64("t_uses_a"), testName: "t_uses_a",
              rootHash: rootHashOfDeps(@[mainDep, aDep]),
              deps: @[mainDep, aDep], readFiles: @[]),
    StoreTest(testId: key64("t_uses_b"), testName: "t_uses_b",
              rootHash: rootHashOfDeps(@[mainDep, bDep]),
              deps: @[mainDep, bDep], readFiles: @[]),
  ]

# ===========================================================================

suite "M4b — suite-level invalidation":

  # -------------------------------------------------------------------------
  test "invalidation_via_reverse_map":
    # Editing function used_a's body invalidates EXACTLY t_uses_a (whose reverse
    # set contains used_a) and NOT t_uses_b; editing nothing skips both.
    let root = makeSourceRoot()
    let tests = rubyStore(root)
    let s = buildStore(tests).value

    # (a) No edit ⇒ no function changed ⇒ both tests skip.
    block:
      let res = invalidateShallow(s, tbSourceInterpreted, root, neverChangedSignal())
      require res.isOk
      check res.value.rerun.len == 0

    # (b) Edit used_a ⇒ only t_uses_a re-runs; t_uses_b is skipped.
    editFunctionBody(root, "used_a", "42 + 1")
    block:
      let res = invalidateShallow(s, tbSourceInterpreted, root, neverChangedSignal())
      require res.isOk
      let r = res.value
      check key64("t_uses_a") in r.rerun
      check key64("t_uses_b") notin r.rerun
      check r.rerun.len == 1
      # The changed function id is reported for naming.
      check functionKey(ExecutedFunction(name: "used_a", file: relSrc, defLine: 16)) in
        r.changedFunctions
      # Reason is the shallow-function-changed signal.
      check irShallowFuncChanged in r.reasons[key64("t_uses_a")]

  # -------------------------------------------------------------------------
  test "shared_function_edit_reruns_all_its_readers":
    # Editing `main` (executed by BOTH tests) re-runs both — proving the reverse
    # map fan-in is honoured, not just single-reader functions.
    let root = makeSourceRoot()
    let tests = rubyStore(root)
    let s = buildStore(tests).value
    editFunctionBody(root, "main", "used_b\n  used_a")
    let res = invalidateShallow(s, tbSourceInterpreted, root, neverChangedSignal())
    require res.isOk
    check key64("t_uses_a") in res.value.rerun
    check key64("t_uses_b") in res.value.rerun
    check res.value.rerun.len == 2

  # -------------------------------------------------------------------------
  test "deep_hash_invalidation":
    # DEEP case: a test whose recomputed deep hash CHANGED re-runs; one whose deep
    # hash is UNCHANGED is skipped (then file-checked, here no files).
    let tests = reverseMapTests()
    let s = buildStore(tests).value
    let names = nameTable(tests)
    let alpha = tests[0].testId
    # Only alpha's deep hash changes.
    var changed = initHashSet[uint64]()
    changed.incl alpha
    let recompute = deepRecompute(tests, changed)
    let res = invalidateDeep(s, names, recompute, neverChangedSignal())
    require res.isOk
    let r = res.value
    check alpha in r.rerun
    check irDeepHashChanged in r.reasons[alpha]
    check tests[1].testId notin r.rerun   # beta unchanged ⇒ skip
    check tests[2].testId notin r.rerun   # gamma unchanged ⇒ skip
    check r.rerun.len == 1

  test "deep_hash_all_unchanged_skips_every_test":
    let tests = reverseMapTests()
    let s = buildStore(tests).value
    let names = nameTable(tests)
    let recompute = deepRecompute(tests, initHashSet[uint64]())
    let res = invalidateDeep(s, names, recompute, neverChangedSignal())
    require res.isOk
    check res.value.rerun.len == 0
    # The skipped complement is the whole corpus.
    let skipped = skippedTests(s, res.value)
    require skipped.isOk
    check skipped.value.len == tests.len

  # -------------------------------------------------------------------------
  test "file_input_invalidation":
    # A changed read file re-runs the tests that read it, in BOTH the deep and
    # shallow cases; an unchanged file does not.
    let names = ["s::reader_x", "s::reader_y", "s::reader_z"]
    let d = dep("f::run", "src/run.py", 1, "shRUN")
    var tests = @[
      StoreTest(testId: key64(names[0]), testName: names[0],
                rootHash: rootHashOfDeps(@[d]), deps: @[d],
                readFiles: @[(path: "data/shared.json", mtime: 100'i64)]),
      StoreTest(testId: key64(names[1]), testName: names[1],
                rootHash: rootHashOfDeps(@[d]), deps: @[d],
                readFiles: @[(path: "data/shared.json", mtime: 100'i64),
                             (path: "data/only_y.json", mtime: 200'i64)]),
      StoreTest(testId: key64(names[2]), testName: names[2],
                rootHash: rootHashOfDeps(@[d]), deps: @[d],
                readFiles: @[]),
    ]
    let s = buildStore(tests).value

    # Signal: only.json changed (mtime now differs), shared.json unchanged.
    proc curMtime(path: string): Option[int64] {.gcsafe.} =
      if path == "data/shared.json": some(100'i64)   # unchanged
      elif path == "data/only_y.json": some(999'i64) # CHANGED (was 200)
      else: none(int64)
    let signal = FileSignal(byHash: false, currentMtime: curMtime,
                            currentHash: nil, recordedHash: nil)

    # DEEP case: every test's deep hash is unchanged, so only the file signal
    # invalidates — reader_y (read only_y.json) re-runs; x and z do not.
    block:
      let recompute = deepRecompute(tests, initHashSet[uint64]())
      let res = invalidateDeep(s, nameTable(tests), recompute, signal)
      require res.isOk
      let r = res.value
      check key64(names[1]) in r.rerun         # reader_y
      check key64(names[0]) notin r.rerun      # reader_x (only shared, unchanged)
      check key64(names[2]) notin r.rerun      # reader_z (no files)
      check irReadFileChanged in r.reasons[key64(names[1])]
      check key64("data/only_y.json") in r.changedFiles

    # SHALLOW case: no function changed (shRUN matches under a stub backend would
    # not match real source, so use the same file-only signal but assert the file
    # fold runs identically). We can't run the real hasher on the synthetic
    # src/run.py, so assert ONLY the file fold here via foldFileInvalidation.
    block:
      var r = InvalidationResult(
        rerun: initHashSet[uint64](),
        changedFunctions: initHashSet[uint64](),
        changedFiles: initHashSet[uint64](),
        reasons: initTable[uint64, set[InvalidationReason]]())
      let fold = foldFileInvalidation(s, signal, r)
      require fold.isOk
      check key64(names[1]) in r.rerun
      check key64(names[0]) notin r.rerun
      check key64(names[2]) notin r.rerun

    # An unchanged file (everything matches) invalidates nothing.
    block:
      proc allUnchanged(path: string): Option[int64] {.gcsafe.} =
        if path == "data/shared.json": some(100'i64)
        elif path == "data/only_y.json": some(200'i64)
        else: none(int64)
      let calm = FileSignal(byHash: false, currentMtime: allUnchanged,
                            currentHash: nil, recordedHash: nil)
      let recompute = deepRecompute(tests, initHashSet[uint64]())
      let res = invalidateDeep(s, nameTable(tests), recompute, calm)
      require res.isOk
      check res.value.rerun.len == 0

  # -------------------------------------------------------------------------
  test "invalidation_collision_failsafe":
    # Inject a key64 collision between two DISTINCT test names mapping to the SAME
    # id. The store can only hold ONE of them per namespace, so a naive lookup of
    # the OTHER name's id would resolve to the stored (wrong) name's entry and,
    # if its deep hash happened to match, FALSELY SKIP. The collision-safety check
    # (verify the id interns back to the queried name) forces a re-run instead.
    #
    # We synthesize the collision by hand: pick id X for the stored test "stored",
    # and a DIFFERENT queried name "queried" that we PRETEND hashes to X (we drive
    # the deep query with a names table that maps X -> "queried", but the store
    # interns X -> "stored"). The mismatch must force a re-run.
    let storedName = "suite::stored_test"
    let id = key64(storedName)
    let d = dep("fn::x", "src/x.py", 1, "shX")
    let tests = @[
      StoreTest(testId: id, testName: storedName,
                rootHash: rootHashOfDeps(@[d]), deps: @[d], readFiles: @[]),
    ]
    let s = buildStore(tests).value

    # The names table the daemon would pass is keyed by id; simulate the collision
    # by claiming this id belongs to a DIFFERENT name than the store interned.
    var collidingNames = initTable[uint64, string]()
    collidingNames[id] = "suite::queried_test"   # != storedName, same id

    # Even with a deep recompute that returns the IDENTICAL deps (so the deep hash
    # MATCHES and a naive query would SKIP), the collision-safety check must force
    # a re-run because the id does not intern back to the queried name.
    let recompute = deepRecompute(tests, initHashSet[uint64]())  # unchanged hash
    let res = invalidateDeep(s, collidingNames, recompute, neverChangedSignal())
    require res.isOk
    let r = res.value
    check id in r.rerun                       # NOT skipped despite matching hash
    check irFailSafe in r.reasons[id]

    # Control: with the CORRECT name, the same unchanged-hash query SKIPS.
    var correctNames = initTable[uint64, string]()
    correctNames[id] = storedName
    let res2 = invalidateDeep(s, correctNames, recompute, neverChangedSignal())
    require res2.isOk
    check res2.value.rerun.len == 0

  test "shallow_collision_failsafe_function_identity":
    # A function id whose stored identity does NOT intern back (a collision /
    # corrupt entry) is treated as CHANGED so its readers re-run, never skip.
    # We build a normal store, then CORRUPT the function interning image so the
    # id resolves to a different identity than the shallow entry records.
    let root = makeSourceRoot()
    let tests = rubyStore(root)
    var s = buildStore(tests).value
    # Replace the function interning namespace with an EMPTY one: now every
    # function id fails to intern back to its stored identity ⇒ treated as
    # changed ⇒ every reader re-runs (fail-safe, never a false skip).
    let emptyStore = buildStore(@[]).value
    s.funcInterning = emptyStore.funcInterning
    let res = invalidateShallow(s, tbSourceInterpreted, root, neverChangedSignal())
    require res.isOk
    # With the interning broken, BOTH tests must re-run (no false skip).
    check key64("t_uses_a") in res.value.rerun
    check key64("t_uses_b") in res.value.rerun

  # -------------------------------------------------------------------------
  test "store_read_error_failsafe_unreadable_current_state_reruns":
    # A test whose CURRENT state cannot be read (its trace/source is gone) ⇒
    # re-run, never skip. The deep recompute seam returns an Err / none for such
    # a test; invalidateDeep must fail-safe it to a re-run even though its STORED
    # deep hash is intact and would otherwise compare equal.
    let tests = reverseMapTests()
    let s = buildStore(tests).value
    let names = nameTable(tests)
    let alpha = tests[0].testId
    let beta  = tests[1].testId
    # Recompute: alpha's current state is UNREADABLE (Err), beta's is missing
    # (none), gamma recomputes cleanly to its unchanged hash. Built via a
    # closure-constructing proc so the captured table is a closure local (not a
    # GC'ed global), preserving gcsafe.
    proc makeRecompute(ts: seq[StoreTest]; aId, bId: uint64): CurrentDepsProc =
      var byId = initTable[uint64, seq[CachedDep]]()
      for t in ts: byId[t.testId] = t.deps
      (proc(testId: uint64): Result[Option[seq[CachedDep]], string] {.gcsafe.} =
        if testId == aId: return err("trace unreadable for alpha")
        if testId == bId: return ok(none(seq[CachedDep]))
        ok(some(byId.getOrDefault(testId))))
    let recompute = makeRecompute(tests, alpha, beta)
    let res = invalidateDeep(s, names, recompute, neverChangedSignal())
    require res.isOk
    let r = res.value
    # alpha (Err) and beta (none) MUST re-run as fail-safes...
    check alpha in r.rerun
    check beta in r.rerun
    check irFailSafe in r.reasons[alpha]
    check irFailSafe in r.reasons[beta]
    # ...gamma recomputed cleanly and unchanged ⇒ skipped.
    check tests[2].testId notin r.rerun

  test "store_read_error_failsafe_no_baseline_reruns":
    # A test enumerated in the suite but with NO stored deep-hash baseline cannot
    # be proven unchanged ⇒ re-run. We drive this via the names table: an id not
    # backed by a deep-forward entry would not enumerate, so instead we assert the
    # documented guard directly — a names table missing the queried id forces the
    # fail-safe (we cannot verify the name ⇒ never skip).
    let tests = reverseMapTests()
    let s = buildStore(tests).value
    # Empty names table: no test id can be verified against its interned name ⇒
    # every test fail-safes to a re-run (never a false skip on an unverifiable id).
    let emptyNames = initTable[uint64, string]()
    let recompute = deepRecompute(tests, initHashSet[uint64]())  # would be unchanged
    let res = invalidateDeep(s, emptyNames, recompute, neverChangedSignal())
    require res.isOk
    let skipped = skippedTests(s, res.value)
    require skipped.isOk
    check skipped.value.len == 0   # nothing skipped when no id can be verified
    for t in tests:
      check irFailSafe in res.value.reasons[t.testId]

  test "corrupt_store_never_silently_skips_shallow":
    # CRITICAL false-skip guard: a CORRUPT shallow-reverse image must NOT enumerate
    # to an empty key set (which would skip every test). `ctfs_store.allKeys`
    # propagates the load failure, so `invalidateShallow` returns an Err ⇒ the
    # caller re-runs the WHOLE suite, never a partial/total false skip.
    var s = buildStore(reverseMapTests()).value
    require s.shallowReverse.len >= 16
    for i in 0 ..< 16:        # corrupt the B-tree header/root page
      s.shallowReverse[i] = byte(0xFF)
    let res = invalidateShallow(s, tbSourceInterpreted, "/nonexistent",
                                neverChangedSignal())
    check res.isErr   # corruption surfaces as an error, NOT an empty skip-all

  test "corrupt_store_never_silently_skips_deep":
    # Same guard for the DEEP path's test universe: a corrupt deep-forward image
    # must error rather than enumerate empty (which would skip every test).
    let tests = reverseMapTests()
    var s = buildStore(tests).value
    require s.deepForward.len >= 16
    for i in 0 ..< 16:
      s.deepForward[i] = byte(0xFF)
    let recompute = deepRecompute(tests, initHashSet[uint64]())
    let res = invalidateDeep(s, nameTable(tests), recompute, neverChangedSignal())
    check res.isErr   # corrupt universe ⇒ error ⇒ caller re-runs the whole suite
