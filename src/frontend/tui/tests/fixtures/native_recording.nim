## native_recording.nim — an rr recording of the workspace's shared native
## fixture, for the suites that need a NATIVE recording's replay (rr, LLDB),
## which no recording of the corpus in `fixture_provider` is.
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

import std/[hashes, os, osproc, strutils, times]

import ./fixture_provider

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
    result.detail = "rr is not on PATH (the codetracer dev shell provides it)"
    return
  putEnv("CODETRACER_CT_NATIVE_REPLAY_CMD", replay)
  # The replay worker counts its starts against the free tier's daily quota
  # unless it is told it runs under a test (`test_harness` does the same).
  putEnv("CODETRACER_IN_UI_TEST", "1")
  let info = getFileInfo(replay)
  let key = toHex(hash(readFile(source) & "|" & $info.size & "|" &
                       $info.lastWriteTime.toUnix), 12).toLowerAscii
  let dir = repoRoot() / "test-logs" / "tui-fixtures" /
            NativeFixtureName & "-" & key
  let trace = dir / "trace"
  if dirExists(trace / "rr"):
    result.ok = true
    result.tracePath = trace
    return
  removeDir(dir)
  createDir(dir)
  let binary = dir / "sudoku_solver"
  for args in [@["build", source, binary], @["record", "-o", trace, binary]]:
    let (output, code) = execCmdEx(quoteShellCommand(@[replay] & args))
    if code != 0:
      raise newException(IOError, "ct-native-replay " & args[0] &
        " failed (" & $code & "):\n" & output)
  if not dirExists(trace / "rr"):
    raise newException(IOError, "ct-native-replay record left no rr/ in " &
      trace)
  result.ok = true
  result.tracePath = trace

proc missingNativePrereq*(rec: NativeRecording): string =
  MissingPrereqSkipPrefix & " " & NativeFixtureName & " — " & rec.detail
