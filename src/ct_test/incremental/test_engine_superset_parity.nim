## M0 — `test_engine_superset_parity`.
##
## The consolidated, CANONICAL codetracer engine (now a SUPERSET that wires BOTH
## the source/interpreted backends AND the native instruction-byte backend the
## native modules require) must reproduce the prior skip/re-run decisions of BOTH
## former copies on the shared fixtures — no behaviour lost in the merge:
##
##   * SOURCE / interpreted path (the decisions codetracer's engine already made
##     before the merge): driven over the committed `m0_three_funcs` Ruby trace +
##     source fixture, exactly as reprobuild's `t_invalidation_engine.nim` and
##     codetracer's prior incremental tests did. These decisions must be
##     BYTE-FOR-BYTE the same as before the merge.
##
##   * NATIVE / instruction-byte path (the decisions ONLY reprobuild's full copy
##     could make — the native wiring codetracer previously stripped): driven
##     over the committed `m8_native_c` C fixture, compiled with the dev shell's
##     `cc`, with a hand-crafted native calltrace pointing at the freshly-built
##     binary, exactly as reprobuild's `t_native_decision.nim` did. These prove
##     the native path now decides as reprobuild's copy did.
##
## This is a REAL parity test: it manipulates source/binary state and drives the
## engine's `record()` / `decide()` over real artifacts — it never asserts
## constants. The native path uses only `cc` + `nm`/`otool` (the engine's
## `native_hash`), NOT the native-recorder dev shell, so it is self-contained.
##
## Platform: on arm64-macOS the C fixture compiles to Mach-O; on Linux to ELF.
## The tests assert on DECISIONS/HASHES (not raw addresses), so they hold on both.

import std/[unittest, os, strutils, times, osproc, json]

import engine
import native_trace   # NativeCalltraceFile, readExecutedFunctionsNative
import native_hash    # shallowHashNative (the native parity guard)

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"

# ===========================================================================
# SOURCE / interpreted parity (the decisions the engine ALREADY made)
# ===========================================================================

const
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  # The trace records the source path as
  # `/fixtures/m0_three_funcs/src/three_funcs.rb`; the engine strips the leading
  # slash and resolves it under `sourceRoot`, so the temp source must live at
  # `<sourceRoot>/fixtures/m0_three_funcs/src/three_funcs.rb`.
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"
  sourceTestId = "fixture::three_funcs"

var sourceCounter = 0

proc makeSourceRoot(): string =
  ## Fresh temp dir with the fixture source copied to the path the trace expects.
  inc sourceCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("ct_parity_src_" & $stamp & "_" & $sourceCounter)
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(threeFuncsFixture / "src" / "three_funcs.rb", dst)
  root

proc editFunctionBody(root, funcName, newBody: string) =
  let path = root / relSourcePath
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip() == "def " & funcName:
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBody
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

proc deleteFunction(root, funcName: string) =
  let path = root / relSourcePath
  var lines = readFile(path).split('\n')
  var outLines: seq[string]
  var i = 0
  while i < lines.len:
    if lines[i].strip() == "def " & funcName:
      i += 1
      while i < lines.len and lines[i].strip() != "end":
        i += 1
      if i < lines.len: i += 1
      continue
    outLines.add lines[i]
    i += 1
  writeFile(path, outLines.join("\n"))

suite "M0 parity — source/interpreted path (decisions preserved)":

  test "source_unchanged_skips":
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, sourceTestId, threeFuncsTrace, root).isOk
    check decide(sourceTestId, threeFuncsTrace, root, cache).kind ==
      idSkipUnchanged

  test "source_changing_executed_function_reruns_naming_it":
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, sourceTestId, threeFuncsTrace, root).isOk
    editFunctionBody(root, "used_a", "42 + 1")
    let d = decide(sourceTestId, threeFuncsTrace, root, cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs

  test "source_changing_unexecuted_function_skips":
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, sourceTestId, threeFuncsTrace, root).isOk
    editFunctionBody(root, "unused_c", "999")
    check decide(sourceTestId, threeFuncsTrace, root, cache).kind ==
      idSkipUnchanged

  test "source_unknown_test_runs_fresh":
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check decide("never::recorded", threeFuncsTrace, root, cache).kind ==
      idRunFresh

  test "source_deleting_executed_dep_reruns_failsafe_changed":
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, sourceTestId, threeFuncsTrace, root).isOk
    deleteFunction(root, "used_a")
    let d = decide(sourceTestId, threeFuncsTrace, root, cache)
    # A removed executed dep is treated as changed — never a silent skip.
    check isRerun(d)
    check d.kind == idRerunChanged

# ===========================================================================
# NATIVE / instruction-byte parity (the decisions ONLY the superset can make)
# ===========================================================================

const
  nativeFixture = fixturesDir / "m8_native_c"
  fixtureSource = nativeFixture / "src" / "native_funcs.c"
  buildScript = nativeFixture / "build.sh"
  # The test's executed set: the two pure position-independent leaves. `main` is
  # deliberately excluded so the executed set carries no relocation-sensitive
  # (call-containing) function — see the fixture README.
  nativeExecutedSet = ["used_a", "used_b"]

var nativeCounter = 0

proc nativeFreshDir(): string =
  inc nativeCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / ("ct_parity_native_" & $stamp & "_" & $nativeCounter)
  createDir(dir)
  dir

proc compileInto(dir, sourceText: string): string =
  ## Build `sourceText` into `<dir>/prog` via the fixture's build.sh; return the
  ## binary path. A broken toolchain surfaces loudly (never a silent "no change").
  createDir(dir)
  let src = dir / "prog.c"
  let binPath = dir / "prog"
  writeFile(src, sourceText)
  let (output, code) = execCmdEx(
    "bash " & quoteShell(buildScript) & " " &
    quoteShell(src) & " " & quoteShell(binPath))
  check code == 0
  if code != 0:
    echo "native fixture build failed:\n", output
  check fileExists(binPath)
  binPath

proc writeNativeTrace(traceDir, binary: string; executed: openArray[string]) =
  ## Hand-craft a native calltrace (`native_calltrace.json`) in the documented
  ## prototype shape, pointing `binary` at the freshly-built executable and
  ## listing exactly the EXECUTED function names, plus the native structural
  ## metadata signal so `detectBackend` routes to the native backend.
  createDir(traceDir)
  var calls = newJArray()
  var pc = 0x1000
  for name in executed:
    var c = newJObject()
    c["functionName"] = newJString(name)
    c["calleePc"] = newJInt(pc)
    calls.add c
    pc += 16
  var root = newJObject()
  root["binary"] = newJString(binary)
  root["calls"] = calls
  writeFile(traceDir / NativeCalltraceFile, root.pretty())
  writeFile(traceDir / "trace_db_metadata.json",
    """{"format":"ctfs","note":"native parity fixture: structural native signal."}""")

proc editedExecutedSource(): string =
  ## Edit an EXECUTED function (`used_a`): `return 1` → a loop. Changes used_a's
  ## emitted instruction bytes while leaving used_b/unused_c untouched.
  let original = readFile(fixtureSource)
  let edited = original.replace(
    "__attribute__((noinline)) int used_a(void) {\n  return 1;\n}",
    "__attribute__((noinline)) int used_a(void) {\n  int s = 0;\n  for (int i = 0; i < 10; i++) s += i;\n  return s + 1;\n}")
  doAssert edited != original, "used_a edit did not apply — fixture changed?"
  edited

proc editedUnexecutedSource(): string =
  ## Edit the UNEXECUTED function (`unused_c`). Must NOT change the instruction
  ## bytes of the executed leaves used_a/used_b (they are position-independent),
  ## so the test still SKIPS — see the fixture README.
  let original = readFile(fixtureSource)
  let edited = original.replace(
    "__attribute__((noinline)) int unused_c(void) {\n  return 99;\n}",
    "__attribute__((noinline)) int unused_c(void) {\n  volatile int s = 0;\n  for (int i = 0; i < 200; i++) s += i * i * i;\n  return s + 99;\n}")
  doAssert edited != original, "unused_c edit did not apply — fixture changed?"
  edited

proc nativeFreshCache(dir: string): IncrementalCache =
  initCache(dir / "cache.json")

suite "M0 parity — native instruction-byte path (superset wiring)":

  test "native_detect_routes_through_native_backend":
    let dir = nativeFreshDir()
    let bin = compileInto(dir / "x", readFile(fixtureSource))
    let trace = dir / "trace"
    writeNativeTrace(trace, bin, nativeExecutedSet)
    let backend = detectBackend(trace)
    check backend.isOk
    check backend.get() == tbNativeDwarf

  test "native_executed_set_matches_calltrace":
    let dir = nativeFreshDir()
    let bin = compileInto(dir / "x", readFile(fixtureSource))
    let trace = dir / "trace"
    writeNativeTrace(trace, bin, nativeExecutedSet)
    let execRes = readExecutedFunctionsNative(trace)
    check execRes.isOk
    var names: seq[string]
    for f in execRes.get():
      names.add f.name
      check f.file == bin    # native deps key on (name + owning binary)
      check f.defLine == 0   # unused for native
    check "used_a" in names
    check "used_b" in names
    check "main" notin names
    check "unused_c" notin names

  test "native_unchanged_binary_skips":
    let dir = nativeFreshDir()
    let binA = compileInto(dir / "a", readFile(fixtureSource))
    let traceA = dir / "trace_a"
    writeNativeTrace(traceA, binA, nativeExecutedSet)
    var cache = nativeFreshCache(dir)
    # sourceRoot is IGNORED on the native route (deps carry the binary); pass a
    # dummy to prove the source path is never touched.
    check record(cache, "native_test", traceA, "/nonexistent-source-root").isOk
    let binB = compileInto(dir / "b", readFile(fixtureSource))
    let traceB = dir / "trace_b"
    writeNativeTrace(traceB, binB, nativeExecutedSet)
    check decide("native_test", traceB, "/nonexistent-source-root", cache).kind ==
      idSkipUnchanged

  test "native_changing_executed_function_reruns_naming_it":
    let dir = nativeFreshDir()
    let binOrig = compileInto(dir / "orig", readFile(fixtureSource))
    let traceOrig = dir / "trace_orig"
    writeNativeTrace(traceOrig, binOrig, nativeExecutedSet)
    var cache = nativeFreshCache(dir)
    check record(cache, "native_test", traceOrig, "/unused").isOk
    let binEdited = compileInto(dir / "edited", editedExecutedSource())
    let traceEdited = dir / "trace_edited"
    writeNativeTrace(traceEdited, binEdited, nativeExecutedSet)
    let d = decide("native_test", traceEdited, "/unused", cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs
    check "used_b" notin d.changedFuncs

  test "native_changing_unexecuted_function_skips":
    let dir = nativeFreshDir()
    let binOrig = compileInto(dir / "orig", readFile(fixtureSource))
    let traceOrig = dir / "trace_orig"
    writeNativeTrace(traceOrig, binOrig, nativeExecutedSet)
    var cache = nativeFreshCache(dir)
    check record(cache, "native_test", traceOrig, "/unused").isOk
    let binEdited = compileInto(dir / "edited", editedUnexecutedSource())
    let traceEdited = dir / "trace_edited"
    writeNativeTrace(traceEdited, binEdited, nativeExecutedSet)
    # GUARD (keeps the skip honest, not coincidental): the executed functions'
    # instruction-byte hashes are GENUINELY unchanged across the unused_c edit.
    for fn in nativeExecutedSet:
      let hOrig = shallowHashNative(binOrig, fn)
      let hEdited = shallowHashNative(binEdited, fn)
      check hOrig.isOk and hEdited.isOk
      check hOrig.get() == hEdited.get()
    # And unused_c's OWN hash DID change (so the edit is real, not a no-op).
    let cOrig = shallowHashNative(binOrig, "unused_c")
    let cEdited = shallowHashNative(binEdited, "unused_c")
    check cOrig.isOk and cEdited.isOk
    check cOrig.get() != cEdited.get()
    check decide("native_test", traceEdited, "/unused", cache).kind ==
      idSkipUnchanged

  test "native_missing_binary_falls_back_to_rerun":
    let dir = nativeFreshDir()
    let binOrig = compileInto(dir / "orig", readFile(fixtureSource))
    let traceOrig = dir / "trace_orig"
    writeNativeTrace(traceOrig, binOrig, nativeExecutedSet)
    var cache = nativeFreshCache(dir)
    check record(cache, "native_test", traceOrig, "/unused").isOk
    # decide-time trace points at a binary that does NOT exist (the calltrace
    # file itself is present, so the readability guard passes).
    let traceMissing = dir / "trace_missing"
    writeNativeTrace(traceMissing, dir / "no_such_binary", nativeExecutedSet)
    let d = decide("native_test", traceMissing, "/unused", cache)
    # Never a skip: the missing binary makes every dep's current shallow hash the
    # reserved "missing" sentinel ⇒ the deps read as changed ⇒ idRerunChanged.
    check d.kind != idSkipUnchanged
    check isRerun(d)
    check d.kind == idRerunChanged
