## native_recording.nim — an rr recording of the workspace's shared native
## fixture, for the suites that need a NATIVE recording's replay (rr, LLDB),
## which no recording of the corpus in `fixture_provider` is — and a Nim
## program recorded by `ct record` (`nimForkRecording`, at the end).
##
## The program is `codetracer-native-test-programs/c/sudoku_solver/main.c`
## (`$NATIVE_TEST_PROGRAMS_REPO`, else the workspace sibling). It is built and
## recorded by the native replay's own CLI — `ct-native-replay build` and
## `ct-native-replay record`, the path `src/db-backend/tests/test_harness`
## records the db-backend's native suites with — into
## `test-logs/tui-fixtures/native_sudoku_c-<key>/`, where `<key>` digests the
## program's source and the recorder binary's identity, so either changing
## records again rather than reusing a stale recording.
##
## The rules are `fixture_provider`'s:
##
##   * a MISSING prerequisite (no `ct-native-replay`, no `rr`, no fixture
##     checkout) is a loud, counted skip: `nativeRecording` answers why, and
##     the suite prints `MISSING-PREREQ SKIP:` with it;
##   * a recorder that is PRESENT and FAILS raises: a failure, never a skip.
##
## A session on the recording replays it through `ct-native-replay`, which
## `replay-server` finds through `CODETRACER_CT_NATIVE_REPLAY_CMD`: resolving
## the recording sets it for this process and its children.
##
## The recorder runs with nothing preloaded into it, and the fixture proves
## that before it records (`shim_free_exec`). A library preloaded into
## `rr record` itself — an agent session's command-trace shim is one — runs
## code in rr's forked child before the tracee's exec (`getcwd` into rr's own
## heap), rr records it, and the replay cannot write it back: every later
## session on the recording failed with "Failed to determine RR port from
## output" (`rr-stderr-*.log`: `write_data_with_holes() errno: EIO` at event
## 30). Measured 2026-11-12 on the Linux workstation (codetracer-pm issue
## `2026-11-12-rr-replay-of-a-c-program-that-uses-the-heap-fails-on-the-linux-workstation.md`).
## Neither `unset LD_PRELOAD` nor `env -u LD_PRELOAD` drops such a shim: it
## hooks `execve` and puts itself back, and a dynamic `env` loads it too, so
## the recordings this fixture made through `env -u LD_PRELOAD` were shimmed
## and failed to replay (2026-11-23; `shim_free_exec` has the measurement).
## The recording's key names the recipe (`RecordingRecipe`), so a recording
## an earlier fixture made that way is recorded again, not reused.
##
## On a hybrid Intel CPU it also confines this process and its children to the
## performance cores, because rr counts branches on the core PMU only: a stock
## rr that lands on an efficiency core dies with "Got 0 branch events, expected
## at least 500". Measured 2026-11-05 on an i9-12900K with rr 5.9.0, ten runs
## each: unconfined 5 passed and 5 failed, performance cores 10 of 10, efficiency
## cores 0 of 10. So the fixture failed at random, by which core rr chose, on a
## host whose counters work.

import std/[hashes, os, osproc, strutils, times]

import ./fixture_provider
import ./performance_cores
import ./shim_free_exec

type
  NativeRecording* = object
    ok*: bool
    tracePath*: string
      ## The trace directory (it holds `rr/`), as a front-end opens it.
    sourcePath*: string
      ## The recorded program's source, as its debug information names it.
    detail*: string
      ## Why there is no recording, when `ok` is false.

const NativeFixtureName* = "native_sudoku_c"

const RecordingRecipe = "record-" & ShimFreeRecipe
  ## Part of the recording's key: how it was recorded. Changing how the
  ## fixture records must change it, or a checkout keeps replaying a
  ## recording the old way made.

proc nativeTestPrograms*(): string =
  let fromEnv = getEnv("NATIVE_TEST_PROGRAMS_REPO")
  if fromEnv.len > 0: fromEnv
  else: repoRoot().parentDir / "codetracer-native-test-programs"

proc findCtNativeReplay*(): string =
  ## `ct-native-replay`: the variables the db-backend's harness and the
  ## replay server read, then the workspace sibling's debug build.
  for name in ["CT_NATIVE_REPLAY_PATH", "CODETRACER_CT_NATIVE_REPLAY_CMD",
               "CT_NATIVE_REPLAY_BIN"]:
    let path = getEnv(name)
    if path.len > 0 and fileExists(path):
      return path
  let sibling = repoRoot().parentDir / "codetracer-native-backend" /
                "target" / "debug" / "ct-native-replay"
  if fileExists(sibling): sibling else: ""

proc rrAvailable(): bool =
  try:
    execCmdEx("rr --version").exitCode == 0
  except OSError:
    false

proc nativeRecording*(): NativeRecording =
  ## The rr recording of the sudoku solver, recorded now unless this
  ## checkout's cache holds one for the same program and recorder.
  preferPerformanceCores()
  let source = nativeTestPrograms() / "c" / "sudoku_solver" / "main.c"
  result.sourcePath = source
  if not fileExists(source):
    result.detail = "the native fixture " & source & " is missing (check out " &
      "codetracer-native-test-programs beside codetracer, or set " &
      "NATIVE_TEST_PROGRAMS_REPO)"
    return
  let replay = findCtNativeReplay()
  if replay.len == 0:
    result.detail = "ct-native-replay was not found (build it with `just " &
      "ensure-ct-native-replay`, or set CT_NATIVE_REPLAY_PATH)"
    return
  if not rrAvailable():
    result.detail = "rr is not on PATH"
    return
  putEnv("CODETRACER_CT_NATIVE_REPLAY_CMD", replay)
  # The replay worker counts its starts against the free tier's daily quota
  # unless it is told it runs under a test (`test_harness` does the same).
  putEnv("CODETRACER_IN_UI_TEST", "1")
  let info = getFileInfo(replay)
  let key = toHex(hash(readFile(source) & "|" & $info.size & "|" &
                       $info.lastWriteTime.toUnix & "|" & RecordingRecipe),
                  12).toLowerAscii
  let dir = repoRoot() / "test-logs" / "tui-fixtures" /
            NativeFixtureName & "-" & key
  let trace = dir / "trace"
  # rr keeps an `incomplete` marker in the trace until it finishes. A recording
  # that died leaves its directory behind, and reusing that one failed every
  # later run in the checkout: "Failed to determine RR port from output".
  # A recording that packed the command-trace shim was made before the
  # fixture kept it out, under a key that cannot tell: recorded again.
  if dirExists(trace / "rr") and not fileExists(trace / "rr" / "incomplete") and
     packedShim(trace / "rr").len == 0:
    result.ok = true
    result.tracePath = trace
    return
  removeDir(dir)
  createDir(dir)
  let binary = dir / "sudoku_solver"
  # Nothing preloaded (the header says why), proven before the recorder runs.
  requireShimFree("ct-native-replay record")
  for args in [@["build", source, binary], @["record", "-o", trace, binary]]:
    let (output, code) = execShimFree(@[replay] & args)
    if code != 0:
      raise newException(IOError, "ct-native-replay " & args[0] &
        " failed (" & $code & "):\n" & output)
  if not dirExists(trace / "rr"):
    raise newException(IOError, "ct-native-replay record left no rr/ in " &
      trace)
  if fileExists(trace / "rr" / "incomplete"):
    raise newException(IOError, "ct-native-replay record exited 0 and left an " &
      "incomplete rr trace in " & trace)
  let packed = packedShim(trace / "rr")
  if packed.len > 0:
    raise newException(IOError, "ct-native-replay record packed the " &
      "command-trace shim (" & packed & ") into " & trace & ": it was " &
      "loaded into rr, and the recording will not replay")
  result.ok = true
  result.tracePath = trace

proc missingNativePrereq*(rec: NativeRecording): string =
  MissingPrereqSkipPrefix & " " & NativeFixtureName & " — " & rec.detail

# ---------------------------------------------------------------------------
# A Nim program recorded by `ct record` (CodeTracer's Nim, MCR)
# ---------------------------------------------------------------------------
#
# Generated-Code-Listing §13.4: `ct record` compiles a Nim program with
# CodeTracer's own Nim fork (`--sourcemap:on`, no `#line` directives) and
# keeps the C and its `.c.map` files in `<trace>/nimcache/`
# (`src/ct/trace/recorder_dispatch.nimNativeCompileArgs`). The example
# recording in codetracer-example-recordings was built by a STOCK compiler
# and bundles C with directives, so a suite over it alone never sees the
# recordings users make today. This one is recorded now, by the product's
# own `ct record`, of codetracer's `nim_flow_test` program.
#
# Prerequisites, each named when missing (a counted `MISSING-PREREQ SKIP:`):
# `ct` (`$CT_BIN`, else on the PATH), the MCR recorder `ct-mcr`
# (`$CODETRACER_CT_MCR_CMD`, else the sibling
# `codetracer-native-recorder/ct_cli/ct_cli`), `nim` on the PATH (the dev
# shell's is CodeTracer's fork) and `ct-native-replay` to replay it. A
# recorder that is present and fails raises.
#
# The recorder runs with nothing preloaded, proven first (`shim_free_exec`):
# a library preloaded into the recording process (agent-harbor's
# command-trace shim, in an agent session) is recorded with the program and
# its recording does not replay (codetracer-pm issue 2026-11-12, "rr replay
# of a C program that uses the heap fails on the Linux workstation").
# `env -u LD_PRELOAD`, used here before, does not drop that shim (2026-11-23).

const NimForkFixtureName* = "nim_fork_flow"

proc ctBinary(): string =
  let fromEnv = getEnv("CT_BIN")
  if fromEnv.len > 0 and fileExists(fromEnv): fromEnv
  else: findExe("ct")

proc ctMcrBinary(): string =
  let fromEnv = getEnv("CODETRACER_CT_MCR_CMD")
  if fromEnv.len > 0 and fileExists(fromEnv):
    return fromEnv
  let sibling = repoRoot().parentDir / "codetracer-native-recorder" /
                "ct_cli" / "ct_cli"
  if fileExists(sibling): sibling else: ""

proc identity(path: string): string =
  ## What changes when a binary is rebuilt: its size and modification time.
  let info = getFileInfo(path)
  $info.size & "@" & $info.lastWriteTime.toUnix

proc ctRecordingOfNim(source, fixtureName: string): NativeRecording =
  ## The `ct record` recording of the Nim program `source`, recorded now
  ## unless this checkout's cache holds one for the same program and tools.
  result.sourcePath = source
  let ct = ctBinary()
  let mcr = ctMcrBinary()
  let nim = findExe("nim")
  let replay = findCtNativeReplay()
  if not fileExists(source):
    result.detail = source & " is missing"
  elif ct.len == 0:
    result.detail = "`ct` was not found (set CT_BIN, or put it on PATH)"
  elif mcr.len == 0:
    result.detail = "the MCR recorder ct-mcr was not found (set " &
      "CODETRACER_CT_MCR_CMD, or build codetracer-native-recorder's ct_cli)"
  elif nim.len == 0:
    result.detail = "`nim` is not on PATH"
  elif replay.len == 0:
    result.detail = "ct-native-replay was not found (set " &
      "CODETRACER_CT_NATIVE_REPLAY_CMD)"
  if result.detail.len > 0:
    return
  putEnv("CODETRACER_CT_NATIVE_REPLAY_CMD", replay)
  putEnv("CODETRACER_CT_MCR_CMD", mcr)
  putEnv("CODETRACER_IN_UI_TEST", "1")
  let key = toHex(hash(readFile(source) & "|" & identity(ct) & "|" &
                       identity(mcr) & "|" & nim & "|" & ShimFreeRecipe),
                  12).toLowerAscii
  # OUTSIDE THE CHECKOUT, unlike every other fixture here: Nim reads the
  # `config.nims` of the main module's directory and its parents, and the
  # checkout's root one (paths, defines, a force-imported test module) made
  # `ct record` build a program its recorder could not run ("cannot map the
  # recording's GEID page", measured 2026-11-13). A user's program is not
  # compiled under CodeTracer's own configuration, so the fixture's is not.
  let dir = getTempDir() / "codetracer-tui-fixtures" /
            fixtureName & "-" & key
  let trace = dir / "trace"
  let program = dir / "src" / source.extractFilename
  result.sourcePath = program
  if fileExists(trace / "trace.ct") and dirExists(trace / "nimcache") and
     fileExists(program):
    result.ok = true
    result.tracePath = trace
    return
  removeDir(dir)
  createDir(dir / "src")
  copyFile(source, program)
  requireShimFree("ct record")
  let (output, code) = execShimFree(@[ct, "record", "-o", trace, program],
                                    workingDir = dir / "src")
  if code != 0:
    raise newException(IOError, "ct record " & program & " failed (" & $code &
      "):\n" & output)
  if not fileExists(trace / "trace.ct") or not dirExists(trace / "nimcache"):
    raise newException(IOError, "ct record exited 0 and left no trace.ct " &
      "and nimcache/ in " & trace & ":\n" & output)
  result.ok = true
  result.tracePath = trace

proc nimForkRecording*(): NativeRecording =
  ## The `ct record` recording of `nim_flow_test.nim`.
  ctRecordingOfNim(repoRoot() / "src" / "db-backend" / "test-programs" /
                   "nim" / "nim_flow_test.nim", NimForkFixtureName)

const NimMacroFixtureName* = "nim_macro_steps"

proc nimMacroRecording*(): NativeRecording =
  ## Editor-Hosted-Front-Ends §E15: the `ct record` recording of
  ## `test-programs/nim_macro_steps/main.nim` — a macro call (`addTwice`) on
  ## line 17 whose expansion is `expanded.nim` lines 1–4, and a template on
  ## line 18. Its `macro_sourcemap_main.json` and `nimcache/expanded.nim` are
  ## in the trace folder, where the replay and the source provider read them.
  ctRecordingOfNim(repoRoot() / "test-programs" / "nim_macro_steps" /
                   "main.nim", NimMacroFixtureName)
