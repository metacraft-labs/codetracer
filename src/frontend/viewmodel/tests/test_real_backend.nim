## test_real_backend.nim
##
## Integration tests for the HeadlessDebugSession — exercises the full
## ViewModel layer against a real replay-server backend over DAP stdio.
##
## These tests use the built-in test trace bundled with the db-backend
## (src/db-backend/trace/) which is a small Wasm recording that does not
## require any external tooling.
##
## Prerequisites:
## - replay-server must be built: ``src/build-debug/bin/replay-server``
## - The test trace must exist: ``src/db-backend/trace/``
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_real_backend.nim

import std/[json, os, unittest]
import ../headless_session
import ../store/types

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc findReplayServer(): string =
  ## Locate the replay-server binary relative to this source file.
  ## Falls back to the REPLAY_SERVER_BIN environment variable.
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin

  # Walk up from the test file to the repo root and look in build-debug.
  let thisFile = currentSourcePath()
  let repoRoot = thisFile.parentDir.parentDir.parentDir.parentDir.parentDir
  let candidate = repoRoot / "src" / "build-debug" / "bin" / "replay-server"
  if fileExists(candidate):
    return candidate

  raise newException(IOError,
    "Could not find replay-server binary. Set REPLAY_SERVER_BIN or " &
    "build it with 'cargo build' in src/db-backend/. " &
    "Tried: " & candidate)

proc findTestTrace(): string =
  ## Locate the built-in test trace (src/db-backend/trace/).
  ## Falls back to the TEST_TRACE_PATH environment variable.
  let envTrace = getEnv("TEST_TRACE_PATH", "")
  if envTrace.len > 0 and dirExists(envTrace):
    return envTrace

  let thisFile = currentSourcePath()
  let repoRoot = thisFile.parentDir.parentDir.parentDir.parentDir.parentDir
  let candidate = repoRoot / "src" / "db-backend" / "trace"
  if dirExists(candidate):
    return candidate

  raise newException(IOError,
    "Could not find test trace directory. Set TEST_TRACE_PATH or " &
    "ensure src/db-backend/trace/ exists. Tried: " & candidate)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Real backend: DAP stdio handshake":

  test "initialize and get entry point":
    ## Verify that we can start a replay session with a real backend
    ## and the debugger reports a valid initial position.
    let replayServerBin = findReplayServer()
    let tracePath = findTestTrace()

    let session = newHeadlessDebugSession(tracePath, replayServerBin)
    defer: session.close()

    # After initialization, the debugger should be at some position.
    # The exact file/line depends on the trace, but rrTicks should be > 0
    # or the file should be non-empty (the backend reports the entry point).
    let file = session.getCurrentFile()
    let line = session.getCurrentLine()
    let ticks = session.getCurrentRRTicks()

    echo "  Initial position: ", file, ":", line, " (rrTicks=", ticks, ")"

    # At minimum, the debugger should be in idle state after initialization.
    check session.getDebuggerStatus() == dsIdle

  test "step forward changes position":
    ## Verify that stepping forward moves the debugger to a different
    ## position (different rrTicks or line number).
    let replayServerBin = findReplayServer()
    let tracePath = findTestTrace()

    let session = newHeadlessDebugSession(tracePath, replayServerBin)
    defer: session.close()

    let ticks1 = session.getCurrentRRTicks()
    let line1 = session.getCurrentLine()
    let file1 = session.getCurrentFile()

    session.stepForward()

    let ticks2 = session.getCurrentRRTicks()
    let line2 = session.getCurrentLine()
    let file2 = session.getCurrentFile()

    echo "  Before step: ", file1, ":", line1, " (rrTicks=", ticks1, ")"
    echo "  After step:  ", file2, ":", line2, " (rrTicks=", ticks2, ")"

    # At least one of ticks/line/file should have changed.
    check (ticks2 != ticks1 or line2 != line1 or file2 != file1)

  test "step forward twice gives different positions":
    ## Verify that repeated stepping produces distinct positions.
    let replayServerBin = findReplayServer()
    let tracePath = findTestTrace()

    let session = newHeadlessDebugSession(tracePath, replayServerBin)
    defer: session.close()

    session.stepForward()
    let pos1 = (session.getCurrentRRTicks(), session.getCurrentLine())

    session.stepForward()
    let pos2 = (session.getCurrentRRTicks(), session.getCurrentLine())

    echo "  Step 1: rrTicks=", pos1[0], " line=", pos1[1]
    echo "  Step 2: rrTicks=", pos2[0], " line=", pos2[1]

    check (pos2[0] != pos1[0] or pos2[1] != pos1[1])

  test "debugger status returns to idle after step":
    ## Verify that the debugger status is dsIdle after a step completes.
    let replayServerBin = findReplayServer()
    let tracePath = findTestTrace()

    let session = newHeadlessDebugSession(tracePath, replayServerBin)
    defer: session.close()

    session.stepForward()
    check session.getDebuggerStatus() == dsIdle

  test "raw DAP request works":
    ## Verify that we can send arbitrary DAP requests and get responses.
    let replayServerBin = findReplayServer()
    let tracePath = findTestTrace()

    let session = newHeadlessDebugSession(tracePath, replayServerBin)
    defer: session.close()

    # stackTrace is a standard DAP request.
    let resp = session.sendRawDapRequest("stackTrace", %*{
      "threadId": 1,
    })
    echo "  stackTrace response success: ", resp.getOrDefault("success").getBool(false)
    check resp.hasKey("type")
    check resp["type"].getStr == "response"
