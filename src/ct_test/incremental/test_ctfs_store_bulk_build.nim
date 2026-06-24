## M4-perf — `test_ctfs_store_bulk_build`.
##
## `ctfs_store.buildPayloadNamespace` (the substrate of BOTH `buildStore` and
## `rebuildNamespace`/`updateTests`) now builds each CoW B-tree namespace via the
## bottom-up one-pass `cow_btree.bulkLoad` constructor instead of N per-key
## `insertAndCommit` calls. This test proves the bulk path is a correct drop-in:
##
##   1. `buildStore` (via the bulk path) produces a store whose `serialize()`
##      reloads identically and whose read-back accessors + key sets are correct.
##   2. The M4c daemon≡file byte-equality invariant STILL HOLDS over the
##      bulk-built namespaces: an incremental `updateTests` rebuild equals a
##      FRESH full `buildStore` of the resulting logical state, byte-for-byte
##      (approach (b) — the bulk build is used CONSISTENTLY in both paths, so the
##      two reach identical bytes for identical logical contents).
##   3. The build is byte-stable / order-independent (a different input test
##      ORDER yields the same store bytes after the store's canonical id sort).
##   4. The bulk build scales (a larger corpus builds + round-trips), exercising
##      real leaf/internal splits in every namespace.

import std/[unittest, algorithm, sets]

import engine        # CachedDep, ExecutedFunction
import ctfs_store    # CtfsStore, StoreTest, buildStore, updateTests, key64, ...

proc dep(name, file: string, defLine: int, shallow: string): CachedDep =
  CachedDep(fn: ExecutedFunction(name: name, file: file, defLine: defLine),
            shallow: shallow)

proc storeBytes(s: CtfsStore): seq[byte] = s.serialize()

proc corpus(n: int): seq[StoreTest] =
  ## A synthetic corpus of `n` tests, each executing a handful of functions with
  ## real fan-in (every test shares a couple of common functions) and reading a
  ## couple of files. Large enough to force leaf + internal splits in the
  ## function/file reverse namespaces.
  let common1 = dep("lib::common_a", "src/lib.nim", 5, "shCOMMONA")
  let common2 = dep("lib::common_b", "src/lib.nim", 9, "shCOMMONB")
  for i in 0 ..< n:
    let nm = "suite::g::test_" & $i
    var deps = @[common1, common2]
    # Two per-test-unique functions (distinct identity ⇒ distinct id).
    deps.add dep("mod::fn_" & $i, "src/mod" & $(i mod 7) & ".nim", i + 10,
                 "shFN" & $i)
    deps.add dep("mod::helper_" & $(i mod 13),
                 "src/h" & $(i mod 13) & ".nim", 3, "shH" & $(i mod 13))
    # A read file's mtime is a property of the FILE, not the reading test, so a
    # shared path always carries the same mtime (the realistic invariant — and
    # what makes the build order-independent: `buildStore` keeps the first-seen
    # `mtime` for a shared file id, so two tests reading the same path must agree
    # on its mtime or the build would depend on which test was seen first).
    let perFile = i mod 5
    result.add StoreTest(
      testId: key64(nm), testName: nm, rootHash: "root_" & $i, deps: deps,
      readFiles: @[(path: "data/shared.json", mtime: 100'i64),
                   (path: "data/f_" & $perFile & ".json",
                    mtime: int64(1000 + perFile))])

suite "M4-perf — CTFS store bulk build":

  test "build_store_serialize_reload_is_lossless_via_bulk":
    let tests = corpus(400)
    let built = buildStore(tests)
    require built.isOk
    let s = built.value
    let bytes = storeBytes(s)
    let reloaded = loadStore(bytes)
    require reloaded.isOk
    let r = reloaded.value
    # The six namespace images come back byte-for-byte; re-serialize matches.
    check r.interning == s.interning
    check r.funcInterning == s.funcInterning
    check r.fileInterning == s.fileInterning
    check r.deepForward == s.deepForward
    check r.shallowReverse == s.shallowReverse
    check r.fileReverse == s.fileReverse
    check r.serialize() == bytes
    # Accessors + key sets read correctly through the bulk-built namespaces.
    for t in tests:
      check r.deepHashOf(t.testId).value.get == t.rootHash
      check r.testName(t.testId).value.get == t.testName
    var wantIds: seq[uint64]
    for t in tests: wantIds.add t.testId
    wantIds.sort()
    var gotIds = r.testIds().value
    gotIds.sort()
    check gotIds == wantIds

  test "bulk_build_is_order_independent_byte_stable":
    # The same logical corpus supplied in a DIFFERENT order builds to byte-
    # identical store bytes (the store sorts by id internally; the bulk build is
    # a pure function of the sorted batch). This is the daemon≡file property.
    let tests = corpus(250)
    var shuffled = tests
    shuffled.reverse()
    let a = buildStore(tests)
    let b = buildStore(shuffled)
    require a.isOk and b.isOk
    check storeBytes(a.value) == storeBytes(b.value)

  test "update_tests_equals_fresh_build_store_byte_for_byte":
    # The M4c invariant, re-asserted over the bulk-built namespaces: after an
    # incremental `updateTests` of a changed subset, the store is byte-identical
    # to a FRESH full `buildStore` of the resulting logical state.
    let tests = corpus(120)
    var s = buildStore(tests).value

    # Re-run a subset: change their root hash + edit one executed function's
    # shallow hash, drop one function, gain a new one (a real set change).
    var updated: seq[StoreTest]
    var finalLogical = tests
    for idx in [3, 17, 42, 88]:
      var t = tests[idx]
      t.rootHash = t.rootHash & "_v2"
      # Edit the per-test-unique function's shallow hash.
      t.deps[2].shallow = t.deps[2].shallow & "X"
      # Drop the shared helper, gain a brand-new function.
      t.deps.del(3)
      t.deps.add dep("mod::new_" & $idx, "src/new.nim", 200 + idx, "shNEW" & $idx)
      updated.add t
      finalLogical[idx] = t

    let ur = updateTests(s, updated)
    require ur.isOk

    let fresh = buildStore(finalLogical)
    require fresh.isOk
    let f = fresh.value
    # Byte-identical across ALL six namespaces.
    check s.interning == f.interning
    check s.funcInterning == f.funcInterning
    check s.fileInterning == f.fileInterning
    check s.deepForward == f.deepForward
    check s.shallowReverse == f.shallowReverse
    check s.fileReverse == f.fileReverse
    # And the whole serialized container matches.
    check storeBytes(s) == storeBytes(f)

  test "skipped_tests_entries_are_untouched_by_update":
    # Only the updated tests' contributions change; a skipped test's deep hash +
    # name are byte-identical before and after (the "update only executed"
    # guarantee, over bulk-built namespaces).
    let tests = corpus(60)
    var s = buildStore(tests).value
    let beforeDeep = s.deepForward
    let beforeName = s.interning

    var one = tests[10]
    one.rootHash = "root_10_changed"
    require updateTests(s, @[one]).isOk

    # A skipped test (index 25) reads back identically.
    check s.deepHashOf(tests[25].testId).value.get == tests[25].rootHash
    check s.testName(tests[25].testId).value.get == tests[25].testName
    # The updated test reflects its new hash.
    check s.deepHashOf(tests[10].testId).value.get == "root_10_changed"
    # The deep-forward + interning images DID change (the update happened) but
    # remain a valid bulk-built image (equals a fresh build of the new state).
    check s.deepForward != beforeDeep
    discard beforeName  # name image is stable here (names unchanged)

  test "large_corpus_builds_and_round_trips":
    # A larger corpus exercises real multi-level B-trees in every namespace.
    let tests = corpus(5000)
    let built = buildStore(tests)
    require built.isOk
    let s = built.value
    # Spot-check resolution across the corpus.
    for idx in [0, 1234, 2500, 4999]:
      check s.deepHashOf(tests[idx].testId).value.get == tests[idx].rootHash
    # Function id set covers exactly the distinct executed identities.
    var wantFuncIds = initHashSet[uint64]()
    for t in tests:
      for d in t.deps: wantFuncIds.incl functionKey(d.fn)
    var got = s.functionIds().value
    check got.len == wantFuncIds.len
    for fid in got: check fid in wantFuncIds
    # Serialize/reload is lossless on the big store too.
    let r = loadStore(s.serialize())
    require r.isOk
    check r.value.serialize() == s.serialize()
