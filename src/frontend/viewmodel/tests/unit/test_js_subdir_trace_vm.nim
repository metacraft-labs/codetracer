## M1 — Headless ViewModel layer test for subdirectory trace loading (Issue #580).
##
## What this test proves:
##
##   1. If the `.ct` trace file is inside a subdirectory (e.g. `trace-1/trace.ct`)
##      within the recording directory, the `headless_session` successfully
##      initializes, loads the trace, and can navigate it.
##
## Compile + run:
##
##   nim c -r src/frontend/viewmodel/tests/unit/test_js_subdir_trace_vm.nim
##

import std/[json, options, os, osproc, strutils, unittest]

import ../../headless_session
import recorder_gate

# ---------------------------------------------------------------------------
# Fixture preparation
# ---------------------------------------------------------------------------

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if dirExists(dir / "src" / "db-backend") and dirExists(dir / "src" / "frontend"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate codetracer repo root from " & currentSourcePath())

proc findReplayServer(): string =
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let candidates = [
    repoRoot() / "src" / "build-debug" / "bin" / "replay-server",
    repoRoot() / "src" / "db-backend" / "target" / "debug" / "replay-server",
    repoRoot() / "src" / "db-backend" / "target" / "release" / "replay-server",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  raise newException(IOError,
    "missing replay-server; set REPLAY_SERVER_BIN or build via " &
    "`cd src/db-backend && cargo build`")

proc findJsRecorder(): string =
  let envPath = getEnv("CODETRACER_JS_RECORDER_PATH", "")
  if envPath.len > 0 and fileExists(envPath):
    return envPath
  let candidate = repoRoot() / ".." / "codetracer-js-recorder" /
    "packages" / "cli" / "dist" / "index.js"
  if fileExists(candidate):
    return candidate
  return ""

proc fixtureDir(): string =
  result = getTempDir() / ("ct_js_subdir_trace_vm_" & $getCurrentProcessId())

proc recordJsTraceInSubdir(): tuple[recordingDir, sourcePath: string] =
  let dir = fixtureDir()
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)

  let sourcePath = dir / "program.js"
  const program = "var a = 1; var b = 2;\n"
  writeFile(sourcePath, program)

  let recorder = findJsRecorder()
  let outParent = dir / "rec-out"
  createDir(outParent)
  let (_, code) = execCmdEx(
    "node " & quoteShell(recorder) & " record " & quoteShell(sourcePath) &
    " --out-dir " & quoteShell(outParent))
  doAssert code == 0,
    "JS recorder failed to record " & sourcePath & " (exit " & $code & ")"

  # JS recorder outputs a `trace-N` subdirectory under `outParent`.
  # Inside `outParent/trace-N/` there should be a `.ct` file.
  # We want `outParent` to be our recording folder.
  var traceSubdir = ""
  for kind, path in walkDir(outParent):
    if kind == pcDir and path.lastPathPart.startsWith("trace-"):
      traceSubdir = path
      break
  doAssert traceSubdir.len > 0,
    "JS recorder produced no trace-* directory under " & outParent

  # Find the `.ct` file in the subdirectory to verify it's there
  var foundCt = false
  for kind, path in walkDir(traceSubdir):
    if kind == pcFile and path.splitFile.ext == ".ct":
      foundCt = true
      break
  doAssert foundCt,
    "No .ct file found inside trace subdirectory: " & traceSubdir

  return (recordingDir: outParent, sourcePath: sourcePath)

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

suite "Headless ViewModel JS Subdirectory Trace loading":

  test "test_js_subdir_trace_vm_loads_and_navigates":
    requireRecorderOrSkip(findJsRecorder(), "codetracer-js-recorder",
        "CODETRACER_JS_RECORDER_PATH",
        "Build the codetracer-js-recorder sibling (just build)."):
      let fixture = recordJsTraceInSubdir()
      let replayServer = findReplayServer()

      # We initialize the session using `recordingDir` (which is `rec-out`).
      # This directory contains the `trace-N` subdirectory with the `.ct` file inside it.
      # The replay server must find this file and set it up correctly.
      var session = newHeadlessDebugSession(fixture.recordingDir, replayServer)

      # Verify that we can successfully query and navigate the session
      check session.getCurrentFile().endsWith("program.js")
      check session.getCurrentLine() == 1

      let initialCol = session.getCurrentColumn()
      check initialCol.isSome
      check initialCol.get() == 1

      # Continue forward should move to the next statement
      session.continueForward()
      check session.getCurrentLine() >= 1

when isMainModule:
  discard
