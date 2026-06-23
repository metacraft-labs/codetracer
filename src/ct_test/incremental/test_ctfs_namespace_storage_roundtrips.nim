## M4a — `test_ctfs_namespace_storage_roundtrips`.
##
## Each of the five refined-model structures the CTFS-namespace store
## (`ctfs_store.nim`) holds must round-trip LOSSLESSLY through the CoW B-tree
## namespaces (`codetracer_ctfs/cow_btree.nim`): build → serialize → reload →
## equal. The structures, all keyed on compact numeric ids:
##
##   1. interning (testId -> name, functionId -> identity, fileId -> path),
##   2. the deep-hash forward map (testId -> root hash),
##   3. the shallow REVERSE structure (functionId -> { shallow, [testIds] }),
##      built by INVERTING the per-test executed sets, and
##   4. the file reverse index (fileId -> { [testIds], mtime }) — the M6 slot.
##
## The data is the record-time data the engine produces (a `CachedTest`-shaped
## per-test executed set + hashes), projected into `StoreTest`s. The test
## asserts the read-back accessors return exactly what was built, AND that the
## whole store survives a serialize/reload byte-for-byte.

import std/[unittest, tables, algorithm]

import engine        # CachedDep, ExecutedFunction
import ctfs_store    # CtfsStore, StoreTest, buildStore, key64, functionKey, ...

proc dep(name, file: string, defLine: int, shallow: string): CachedDep =
  CachedDep(fn: ExecutedFunction(name: name, file: file, defLine: defLine),
            shallow: shallow)

proc sampleTests(): seq[StoreTest] =
  ## A small but representative corpus: three tests sharing some functions (so
  ## the reverse map has real fan-in) and reading some files.
  let shared = dep("lib::helper", "src/lib.py", 10, "shHELPER")
  let onlyA = dep("a::only", "src/a.py", 3, "shONLYA")
  let onlyB = dep("b::only", "src/b.py", 7, "shONLYB")
  let shared2 = dep("lib::util", "src/lib.py", 40, "shUTIL")

  let names = ["suite::g::test_alpha", "suite::g::test_beta", "suite::g::test_gamma"]
  result = @[
    StoreTest(testId: key64(names[0]), testName: names[0],
              rootHash: "rootALPHA", deps: @[shared, onlyA, shared2],
              readFiles: @[(path: "data/fixtures/f1.json", mtime: 111'i64)]),
    StoreTest(testId: key64(names[1]), testName: names[1],
              rootHash: "rootBETA", deps: @[shared, onlyB],
              readFiles: @[(path: "data/fixtures/f1.json", mtime: 111'i64),
                           (path: "data/fixtures/f2.json", mtime: 222'i64)]),
    StoreTest(testId: key64(names[2]), testName: names[2],
              rootHash: "rootGAMMA", deps: @[shared2],
              readFiles: @[]),
  ]

suite "M4a — CTFS namespace storage round-trips":

  test "interning_roundtrips_test_function_file":
    let tests = sampleTests()
    let built = buildStore(tests)
    require built.isOk
    let s = built.value
    # testId -> name
    for t in tests:
      let n = s.testName(t.testId)
      require n.isOk
      check n.value.isSome
      check n.value.get == t.testName
    # functionId -> identity, for every executed function across the corpus.
    for t in tests:
      for d in t.deps:
        let fid = functionKey(d.fn)
        let ident = s.functionIdentity(fid)
        require ident.isOk
        check ident.value.isSome
        check ident.value.get == d.fn.name & "\0" & d.fn.file & "\0" & $d.fn.defLine
    # fileId -> path, for every read file.
    for t in tests:
      for rf in t.readFiles:
        let fid = key64(rf.path)
        let p = s.filePath(fid)
        require p.isOk
        check p.value.isSome
        check p.value.get == rf.path

  test "deep_forward_map_roundtrips":
    let tests = sampleTests()
    let s = buildStore(tests).value
    for t in tests:
      let h = s.deepHashOf(t.testId)
      require h.isOk
      check h.value.isSome
      check h.value.get == t.rootHash
    # A never-stored id reads back as none (not an error).
    let absent = s.deepHashOf(key64("no::such::test"))
    require absent.isOk
    check absent.value.isNone

  test "shallow_reverse_structure_inverts_the_per_test_sets":
    let tests = sampleTests()
    let s = buildStore(tests).value
    # The shared function `lib::helper` was executed by alpha AND beta.
    let helperId = key64("lib::helper" & "\0" & "src/lib.py" & "\0" & "10")
    let helper = s.shallowEntryOf(helperId)
    require helper.isOk
    check helper.value.isSome
    let he = helper.value.get
    check he.shallow == "shHELPER"
    check he.name == "lib::helper"
    var ids = he.testIds
    ids.sort()
    var want = @[key64("suite::g::test_alpha"), key64("suite::g::test_beta")]
    want.sort()
    check ids == want
    # `lib::util` was executed by alpha AND gamma.
    let utilId = key64("lib::util" & "\0" & "src/lib.py" & "\0" & "40")
    let util = s.shallowEntryOf(utilId).value.get
    check util.shallow == "shUTIL"
    var uids = util.testIds
    uids.sort()
    var uwant = @[key64("suite::g::test_alpha"), key64("suite::g::test_gamma")]
    uwant.sort()
    check uids == uwant
    # `a::only` was executed by alpha alone.
    let onlyAId = key64("a::only" & "\0" & "src/a.py" & "\0" & "3")
    let onlyA = s.shallowEntryOf(onlyAId).value.get
    check onlyA.testIds == @[key64("suite::g::test_alpha")]

  test "file_reverse_index_roundtrips_with_fan_in":
    let tests = sampleTests()
    let s = buildStore(tests).value
    # f1.json was read by alpha AND beta; f2.json by beta only.
    let f1 = s.fileEntryOf(key64("data/fixtures/f1.json"))
    require f1.isOk
    check f1.value.isSome
    let f1e = f1.value.get
    check f1e.path == "data/fixtures/f1.json"
    check f1e.mtime == 111
    var f1ids = f1e.testIds
    f1ids.sort()
    var f1want = @[key64("suite::g::test_alpha"), key64("suite::g::test_beta")]
    f1want.sort()
    check f1ids == f1want
    let f2e = s.fileEntryOf(key64("data/fixtures/f2.json")).value.get
    check f2e.testIds == @[key64("suite::g::test_beta")]
    check f2e.mtime == 222

  test "whole_store_serialize_reload_is_lossless":
    let tests = sampleTests()
    let s = buildStore(tests).value
    let bytes = s.serialize()
    let reloaded = loadStore(bytes)
    require reloaded.isOk
    let r = reloaded.value
    # The six namespace images come back byte-for-byte.
    check r.interning == s.interning
    check r.funcInterning == s.funcInterning
    check r.fileInterning == s.fileInterning
    check r.deepForward == s.deepForward
    check r.shallowReverse == s.shallowReverse
    check r.fileReverse == s.fileReverse
    # And re-serializing the reloaded store yields the identical container.
    check r.serialize() == bytes
    # Every structure still reads correctly after the reload.
    for t in tests:
      check r.deepHashOf(t.testId).value.get == t.rootHash
      check r.testName(t.testId).value.get == t.testName

  test "key_enumeration_matches_the_built_corpus":
    let tests = sampleTests()
    let s = buildStore(tests).value
    # All test ids present in the deep-forward map == the corpus ids.
    var wantTestIds: seq[uint64]
    for t in tests: wantTestIds.add t.testId
    wantTestIds.sort()
    let gotTestIds = s.testIds()
    require gotTestIds.isOk
    var got = gotTestIds.value
    got.sort()
    check got == wantTestIds
    # The function ids cover exactly the distinct executed-function identities.
    var wantFuncIds: seq[uint64]
    var seen = initTable[uint64, bool]()
    for t in tests:
      for d in t.deps:
        let fid = functionKey(d.fn)
        if not seen.hasKey(fid):
          seen[fid] = true
          wantFuncIds.add fid
    wantFuncIds.sort()
    var gotFuncIds = s.functionIds().value
    gotFuncIds.sort()
    check gotFuncIds == wantFuncIds

  test "point_update_deep_changes_only_the_target_entry":
    # The daemon hot path (groundwork): a single test's deep-forward entry is
    # updated copy-on-write; every other entry is untouched and the key set is
    # unchanged. (The daemon LOOP is M4c; this proves the storage primitive.)
    let tests = sampleTests()
    let s = buildStore(tests).value
    let target = tests[1].testId  # beta
    let updated = pointUpdateDeep(s.deepForward, target, "rootBETA_v2")
    require updated.isOk
    var s2 = s
    s2.deepForward = updated.value
    check s2.deepHashOf(target).value.get == "rootBETA_v2"
    # Every other entry unchanged.
    check s2.deepHashOf(tests[0].testId).value.get == "rootALPHA"
    check s2.deepHashOf(tests[2].testId).value.get == "rootGAMMA"
    # Key set unchanged.
    var ids = s2.testIds().value
    ids.sort()
    var want: seq[uint64]
    for t in tests: want.add t.testId
    want.sort()
    check ids == want
