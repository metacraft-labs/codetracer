## nim_ct_recording.nim — a recording of a Nim program made the way a user
## makes one today: `ct record <program>.nim`, for the suites that need the C
## CodeTracer's own Nim compiler generates (Generated-Code-Listing §13.4).
##
## `ct record` compiles the program with `--sourcemap:on` into
## `<trace>/nimcache/` (`ct/trace/recorder_dispatch.nimNativeCompileArgs`)
## and records it with MCR (`ct-mcr`). The C that compiler writes carries no
## `#line` directives, only a Source Map v3 `.nim.c.map` beside each file —
## unlike the example recording (`codetracer-example-recordings/nim/flow_test`),
## which a stock compiler built. A front-end that maps only directives, or
## reads only what the recording's file tree serves (it serves none of the
## maps), shows nothing for every recording a user makes; this fixture is the
## recording that tells the two apart.
##
## Recorded on demand into `test-logs/gpui-fixtures/nim_ct_record-<key>/`,
## where `<key>` digests the program, the `ct` and `ct-mcr` binaries'
## identities and how it is recorded, so changing any of them records again
## rather than reusing a stale recording (`tui/tests/fixtures/native_recording`'s
## rule). The recorder runs as `env -u LD_PRELOAD ct record …`: a library
## preloaded into a recorder (an agent session's command-trace shim) runs
## code of its own in the recorded process tree, and a recording made that
## way may not replay (codetracer-pm issue
## `2026-11-12-rr-replay-of-a-c-program-that-uses-the-heap-fails-on-the-linux-workstation.md`).
##
## Prerequisites, named rather than assumed (`MISSING-PREREQ SKIP:` with which
## is missing): `ct` (`$CT_BIN`, else the checkout's `src/build-debug/bin/ct`,
## else `ct` on the PATH); `ct-mcr` (`$CODETRACER_CT_MCR_CMD`, else
## `$CODETRACER_CT_MCR_PATH`, else the sibling codetracer-native-recorder's
## `ct_cli/ct_cli`, which `scripts/detect-siblings.sh` exports the same way);
## and a CodeTracer Nim compiler — a compiler that writes no `.c.map` makes a
## recording this fixture is not about, so that is a skip too. A recorder
## that is PRESENT and FAILS raises: a failure, never a skip.

import std/[hashes, os, osproc, strutils, times]

const
  NimCtFixtureName* = "nim_ct_record"
  NimCtProgramName* = "squares_c"
  NimCtProgram* = """proc square(n: int): int =
  result = n * n

proc sumOfSquares(limit: int): int =
  for i in 1..limit:
    result += square(i)

let total = sumOfSquares(4)
echo "total=", total
"""
  NimCtRecipe = "ct-record-without-ld-preload"
    ## Part of the key: how the fixture records.

type
  NimCtRecording* = object
    ok*: bool
    tracePath*: string
      ## The trace folder (`trace.ct`, `nimcache/`), as a front-end opens it.
    programPath*: string
      ## The recorded Nim source.
    detail*: string
      ## Why there is no recording, when `ok` is false.

proc repoRootOf(): string =
  ## The checkout this file lives in: the first parent holding a `justfile`
  ## and `src/` (walked, not counted, as `fixture_provider.repoRoot` does).
  var dir = currentSourcePath().parentDir
  while dir.len > 1:
    if fileExists(dir / "justfile") and dirExists(dir / "src"):
      return dir
    dir = dir.parentDir
  getCurrentDir()

proc identity(path: string): string =
  let info = getFileInfo(path)
  path & ":" & $info.size & ":" & $info.lastWriteTime.toUnix

proc findCt(): string =
  let fromEnv = getEnv("CT_BIN")
  if fromEnv.len > 0:
    return (if fileExists(fromEnv): fromEnv else: "")
  let built = repoRootOf() / "src" / "build-debug" / "bin" / "ct"
  if fileExists(built): built else: findExe("ct")

proc findCtMcr(): string =
  for name in ["CODETRACER_CT_MCR_CMD", "CODETRACER_CT_MCR_PATH"]:
    let path = getEnv(name)
    if path.len > 0 and fileExists(path):
      return path
  let sibling = repoRootOf().parentDir / "codetracer-native-recorder" /
                "ct_cli" / "ct_cli"
  if fileExists(sibling): sibling else: ""

proc hasMaps(trace: string): bool =
  for f in walkDirRec(trace / "nimcache"):
    if f.endsWith(".nim.c.map"):
      return true
  false

proc nimCtRecording*(): NimCtRecording =
  ## The `ct record` recording of `NimCtProgram`, recorded now unless this
  ## checkout's cache holds one for the same program and recorders.
  let ct = findCt()
  if ct.len == 0:
    result.detail = "no `ct` (set CT_BIN, or `just build-once`)"
    return
  let mcr = findCtMcr()
  if mcr.len == 0:
    result.detail = "no `ct-mcr` (set CODETRACER_CT_MCR_CMD, or build " &
      "codetracer-native-recorder's `just build-ct-mcr`)"
    return
  # The replay of an MCR recording runs `ct-mcr` too, below the replay
  # server the front-end starts: the same binary for both.
  putEnv("CODETRACER_CT_MCR_CMD", mcr)
  putEnv("CODETRACER_IN_UI_TEST", "1")
  let key = toHex(hash(NimCtProgram & "|" & identity(ct) & "|" &
                       identity(mcr) & "|" & NimCtRecipe), 12).toLowerAscii
  let dir = repoRootOf() / "test-logs" / "gpui-fixtures" /
            NimCtFixtureName & "-" & key
  let program = dir / NimCtProgramName & ".nim"
  let trace = dir / "trace"
  result.programPath = program
  if fileExists(trace / "trace.ct") and hasMaps(trace):
    result.ok = true
    result.tracePath = trace
    return
  # A directory a failed or interrupted recording left (no `trace.ct`, or
  # no maps) is this fixture's own: recorded again.
  removeDir(dir)
  createDir(dir)
  writeFile(program, NimCtProgram)
  let (output, code) = execCmdEx(quoteShellCommand(
    @["env", "-u", "LD_PRELOAD", ct, "record", "-o", trace, program]),
    workingDir = dir)
  if code != 0:
    if "Nim compiler not found" in output:
      result.detail = "no Nim compiler for `ct record` (CODETRACER_NIM_EXE_PATH, " &
        "or `nim` on the PATH)"
      return
    raise newException(IOError, "ct record " & program & " failed (" & $code &
      "):\n" & output)
  if not fileExists(trace / "trace.ct"):
    raise newException(IOError, "ct record exited 0 and left no trace.ct in " &
      trace & ":\n" & output)
  if not hasMaps(trace):
    result.detail = "the `nim` `ct record` compiled with wrote no .nim.c.map " &
      "into " & trace / "nimcache" & ": it is not CodeTracer's Nim compiler"
    return
  result.ok = true
  result.tracePath = trace
