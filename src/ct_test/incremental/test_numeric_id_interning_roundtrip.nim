## M4a — `test_numeric_id_interning_roundtrip`.
##
## The refined data model keys EVERY structure on COMPACT NUMERIC ids derived by
## interning strings (`key64`, FNV-1a 64-bit — byte-identical to the M3 bench).
## This test proves the interning is:
##
##   * STABLE — the same string always interns to the same id (pure FNV-1a, no
##     state), so ids are reproducible across runs / processes / the Rust side;
##   * REVERSIBLE — the id->name (id->identity, id->path) namespaces resolve a
##     stored id back to its original string; and
##   * SURVIVES RELOAD — the reverse resolution is identical after the store is
##     serialized and reloaded (the id->name map is persisted, not in-memory).
##
## The forward direction (name->id) is just `key64(name)` with NO stored map (the
## reference model's approach), so this test asserts that property directly: a
## name resolves to its id without consulting any namespace.

import std/unittest

import engine        # CachedDep, ExecutedFunction
import ctfs_store    # buildStore, key64, functionKey, StoreTest, ...

proc dep(name, file: string, defLine: int, shallow: string): CachedDep =
  CachedDep(fn: ExecutedFunction(name: name, file: file, defLine: defLine),
            shallow: shallow)

suite "M4a — numeric-id interning round-trip":

  test "key64_is_stable_and_matches_the_reference_basis":
    # FNV-1a 64-bit is a PURE function: identical input ⇒ identical id, every
    # call, no state. (The same algorithm/basis/prime as the Rust bench `key64`.)
    check key64("suite::group::test_x") == key64("suite::group::test_x")
    check key64("a") != key64("b")
    # The empty string interns to the FNV-1a offset basis (the algorithm's seed).
    check key64("") == 0xcbf29ce484222325'u64
    # A known vector: FNV-1a("a") == 0xaf63dc4c8601ec8c.
    check key64("a") == 0xaf63dc4c8601ec8c'u64

  test "function_key_distinguishes_identity_components":
    # Two functions with the same NAME but different file/defLine intern to
    # DIFFERENT ids (identity = name+file+defLine), so the reverse map never
    # conflates them.
    let f1 = ExecutedFunction(name: "f", file: "a.py", defLine: 1)
    let f2 = ExecutedFunction(name: "f", file: "b.py", defLine: 1)
    let f3 = ExecutedFunction(name: "f", file: "a.py", defLine: 9)
    check functionKey(f1) != functionKey(f2)
    check functionKey(f1) != functionKey(f3)
    check functionKey(f1) == functionKey(
      ExecutedFunction(name: "f", file: "a.py", defLine: 1))

  test "name_to_id_needs_no_stored_map":
    # The forward direction is pure `key64(name)`: a name resolves to its id with
    # NO namespace lookup. We assert the interned id stored for each test EQUALS
    # `key64(testName)` — so a reader recovers the id from the name alone.
    let names = @["suite::a::t1", "suite::b::t2 with spaces", "x"]
    var tests: seq[StoreTest]
    for n in names:
      tests.add StoreTest(testId: key64(n), testName: n, rootHash: "h",
                          deps: @[dep("fn", "f.py", 1, "s")], readFiles: @[])
    let s = buildStore(tests).value
    for n in names:
      # name -> id is pure; id -> name comes from the stored namespace.
      let id = key64(n)
      let back = s.testName(id)
      require back.isOk
      check back.value.isSome
      check back.value.get == n

  test "id_to_string_is_reversible_across_reload":
    # Build a store, serialize it, reload it, and confirm EVERY id resolves back
    # to its original string on the RELOADED store (the interning is persisted).
    let names = @["suite::g::alpha", "suite::g::beta", "suite::g::gamma"]
    var tests: seq[StoreTest]
    for i, n in names:
      tests.add StoreTest(
        testId: key64(n), testName: n, rootHash: "root_" & $i,
        deps: @[dep("lib::h", "lib.py", 10, "sh"),
                dep("only_" & $i, "f" & $i & ".py", 3, "s" & $i)],
        readFiles: @[(path: "data/r" & $i & ".json", mtime: int64(i))])
    let s0 = buildStore(tests).value
    let reloaded = loadStore(s0.serialize())
    require reloaded.isOk
    let s = reloaded.value
    # test id -> name
    for n in names:
      check s.testName(key64(n)).value.get == n
    # function id -> identity
    for t in tests:
      for d in t.deps:
        let fid = functionKey(d.fn)
        let ident = s.functionIdentity(fid)
        require ident.isOk
        check ident.value.get ==
          d.fn.name & "\0" & d.fn.file & "\0" & $d.fn.defLine
    # file id -> path
    for t in tests:
      for rf in t.readFiles:
        check s.filePath(key64(rf.path)).value.get == rf.path

  test "absent_id_resolves_to_none_not_error":
    # An id that was never interned reads back as `none` (a clean miss), never an
    # error — so a reader can probe ids safely.
    let tests = @[StoreTest(testId: key64("only"), testName: "only",
                            rootHash: "h", deps: @[], readFiles: @[])]
    let s = buildStore(tests).value
    let miss = s.testName(key64("never::interned"))
    require miss.isOk
    check miss.value.isNone
    let missFn = s.functionIdentity(key64("never::fn"))
    require missFn.isOk
    check missFn.value.isNone
