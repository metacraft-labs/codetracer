## M0 — `e2e_ct_test_incremental_no_reprobuild`.
##
## `ct test --incremental` builds and decides skip vs re-run END-TO-END on the
## CONSOLIDATED, canonical codetracer engine, with NO reprobuild dependency in
## the build. The runner already lived standalone in codetracer; this test
## asserts it STILL does — and that it is now NATIVE-CAPABLE (the canonical engine
## wires the native instruction-byte backend the merge brought in from
## reprobuild's full copy).
##
## # What this proves (the two M0 load-bearing properties)
##
##   1. NO REPROBUILD IN THE BUILD. This test imports the production CLI module
##      (`incremental_cli`) and the canonical engine (`incremental/engine` +
##      `incremental/native_*`). The fact that this test COMPILES AND LINKS is
##      itself the assertion: if any engine/CLI module imported reprobuild's
##      `repro_ct_incremental`, the build would pull that tree in. None does (the
##      decision record's one-way dependency: codetracer never depends on
##      reprobuild). A static guard below additionally greps the engine sources.
##
##   2. A REAL SKIP-vs-RERUN DECISION END-TO-END, NATIVE-CAPABLE. Using the
##      committed `m8_native_c` C fixture compiled with the dev shell's `cc`, the
##      test drives the EXACT record → persist → reload → decide cache cycle the
##      CLI's `decideIncremental` runs (the engine's `record`/`saveCache`/
##      `loadCache`/`decide`), and asserts:
##        * an unchanged rebuild ⇒ SKIP (`idSkipUnchanged`);
##        * editing an EXECUTED native function ⇒ RE-RUN naming it
##          (`idRerunChanged`).
##      The native path was REJECTED up front before M0 ("native/compiled
##      languages are deferred"); it is now accepted, and `parseLanguage("native")`
##      resolves — proving the CLI gate was lifted.
##
## The native shallow hash reads only `cc` + `nm`/`otool` (the engine's
## `native_hash`), NOT the native-recorder dev shell, so this e2e is
## self-contained and reliably runnable in the targeted Nim test environment.
## (The live native RECORDING path — `recordNativeLive` driving the
## `ct_instrument` plugin — is exercised by the provider/live suites, which need
## the native-recorder sibling; this e2e exercises the DECISION engine the CLI
## hands the recorded trace to.)

import std/[unittest, os, strutils, times, osproc, json]

import incremental_cli
import incremental/engine
import incremental/native_trace   # NativeCalltraceFile

const
  fixturesDir =
    currentSourcePath().parentDir / "incremental" / "fixtures" / "m8_native_c"
  fixtureSource = fixturesDir / "src" / "native_funcs.c"
  buildScript = fixturesDir / "build.sh"
  # The executed set: the two pure position-independent leaves (see the fixture
  # README); `main` is excluded so the set carries no relocation-sensitive fn.
  executedSet = ["used_a", "used_b"]

var counter = 0

proc freshDir(): string =
  inc counter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / ("ct_e2e_no_repro_" & $stamp & "_" & $counter)
  createDir(dir)
  dir

proc compileInto(dir, sourceText: string): string =
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
    """{"format":"ctfs","note":"e2e native fixture: structural native signal."}""")

proc editedExecutedSource(): string =
  let original = readFile(fixtureSource)
  let edited = original.replace(
    "__attribute__((noinline)) int used_a(void) {\n  return 1;\n}",
    "__attribute__((noinline)) int used_a(void) {\n  int s = 0;\n  for (int i = 0; i < 10; i++) s += i;\n  return s + 1;\n}")
  doAssert edited != original, "used_a edit did not apply — fixture changed?"
  edited

suite "M0 e2e — ct test --incremental, no reprobuild dependency":

  test "native_language_is_no_longer_rejected_by_the_cli":
    # Before M0 the CLI's argument parser rejected native up front
    # ("native/compiled languages are deferred"); the canonical engine now wires
    # the native backend, so parsing `--language native` (and `c`) over the public
    # CLI surface must SUCCEED and resolve to `ilNative`.
    let dir = freshDir()
    let prog = dir / "prog.c"
    writeFile(prog, readFile(fixtureSource))
    for langArg in ["native", "c"]:
      let parsed = parseIncrementalArgs(
        @["--language", langArg, "--program", prog,
          "--cache", dir / "c.json", "--id", "t"])
      check parsed.isOk
      if parsed.isOk:
        check parsed.value.language == ilNative

  test "decides_skip_then_rerun_end_to_end_with_cache_roundtrip":
    let dir = freshDir()
    let cachePath = dir / "cache.json"

    # --- baseline: record + persist (the CLI's fresh-baseline branch) ----------
    let binBase = compileInto(dir / "base", readFile(fixtureSource))
    let traceBase = dir / "trace_base"
    writeNativeTrace(traceBase, binBase, executedSet)
    var cache = initCache(cachePath)
    # sourceRoot is ignored on the native route (deps carry the binary).
    check record(cache, "fixture_native", traceBase, "/unused").isOk
    check saveCache(cache).isOk
    check fileExists(cachePath)

    # --- unchanged rebuild ⇒ SKIP (reload the cache, as the CLI does) ----------
    block unchangedSkips:
      let reloaded = loadCache(cachePath)
      check reloaded.isOk
      let binAgain = compileInto(dir / "again", readFile(fixtureSource))
      let traceAgain = dir / "trace_again"
      writeNativeTrace(traceAgain, binAgain, executedSet)
      let d = decide("fixture_native", traceAgain, "/unused", reloaded.value)
      check d.kind == idSkipUnchanged

    # --- edit an EXECUTED function ⇒ RE-RUN naming it ---------------------------
    block executedEditReruns:
      let reloaded = loadCache(cachePath)
      check reloaded.isOk
      let binEdited = compileInto(dir / "edited", editedExecutedSource())
      let traceEdited = dir / "trace_edited"
      writeNativeTrace(traceEdited, binEdited, executedSet)
      let d = decide("fixture_native", traceEdited, "/unused", reloaded.value)
      check d.kind == idRerunChanged
      check "used_a" in d.changedFuncs
      check "used_b" notin d.changedFuncs

  test "no_codetracer_engine_module_imports_reprobuild":
    # Static guard backing property (1): NO engine/CLI source imports reprobuild's
    # repro_ct_incremental tree. (The successful build of THIS test is the primary
    # proof; this guard makes a regression fail loudly with a precise message.)
    let incrementalDir = currentSourcePath().parentDir / "incremental"
    let cliPath = currentSourcePath().parentDir / "incremental_cli.nim"
    var offenders: seq[string]
    for kind, path in walkDir(incrementalDir):
      if kind in {pcFile} and path.endsWith(".nim"):
        for line in readFile(path).splitLines():
          let s = line.strip()
          if (s.startsWith("import") or s.startsWith("include")) and
              ("repro_ct_incremental" in s or
               ("reprobuild" in s and "/" in s)):
            offenders.add path.extractFilename & ": " & s
    for line in readFile(cliPath).splitLines():
      let s = line.strip()
      if (s.startsWith("import") or s.startsWith("include")) and
          "repro_ct_incremental" in s:
        offenders.add "incremental_cli.nim: " & s
    if offenders.len > 0:
      checkpoint("reprobuild imports found:\n" & offenders.join("\n"))
    check offenders.len == 0
