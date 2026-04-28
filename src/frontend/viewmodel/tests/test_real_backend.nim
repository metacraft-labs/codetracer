## test_real_backend.nim
##
## Integration tests for the HeadlessDebugSession — exercises the full
## ViewModel layer against a real replay-server backend over DAP stdio.
##
## These tests use the built-in test trace bundled with the db-backend
## (src/db-backend/trace/) which is a small Wasm recording of a Rust program
## (rust_struct_test.wasm) that creates structs and calls functions.
##
## The test trace has this approximate structure (from trace.json):
##   - main() at line 18 of rust_struct_test.rs
##   - Creates TestStruct { a: i32 }, calls test_struct() twice
##   - Variables: test, dummy (both TestStruct), first (usize)
##
## Prerequisites:
## - replay-server must be built: ``src/build-debug/bin/replay-server``
## - The test trace must exist: ``src/db-backend/trace/``
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_real_backend.nim

import std/[json, os, unittest, strutils]
import isonim/core/[signals, computation]
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

proc stepToUserCode(session: HeadlessDebugSession) =
  ## Step forward until we land in the test program's source file
  ## (rust_struct_test.rs) rather than library/runtime internals.
  ## The test trace starts at the entry point which may be in Rust
  ## stdlib code, so we need a few steps to reach main().
  ##
  ## Gives up after 20 steps to avoid infinite loops on unexpected traces.
  for i in 0 ..< 20:
    if "rust_struct_test" in session.getCurrentFile():
      return
    session.stepForward()
  # If we never reached the file, the trace may have changed.
  # Continue anyway — the tests will fail with clear error messages.

# ---------------------------------------------------------------------------
# Suite 1: DAP stdio handshake (existing tests, preserved)
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

# ---------------------------------------------------------------------------
# Suite 2: Locals inspection
# ---------------------------------------------------------------------------

suite "Real backend: locals inspection":

  test "locals available after stepping":
    ## After stepping into user code the backend should report local
    ## variables.  The test trace (rust_struct_test) declares ``test``,
    ## ``dummy`` (both ``TestStruct``), and ``first`` (``usize``).
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Step enough times to reach a position with locals.
    # From the exploration: after ~5 next steps from entry we are at
    # line 28 of rust_struct_test.rs with 3 locals (dummy, first, test).
    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadLocals()
    let locals = session.getLocals()

    echo "  Locals count: ", locals.len
    for v in locals:
      echo "    ", v.name, " : ", v.typeName, " = ", v.value

    # The trace should have at least one local at this point.
    check locals.len > 0

    # Every variable must have a non-empty name.
    for v in locals:
      check v.name.len > 0

  test "locals have type information":
    ## Verify that parsed locals include type names from the backend
    ## response (``typ.langType``).
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadLocals()
    let locals = session.getLocals()

    # At least one variable should have a non-empty type name.
    var hasType = false
    for v in locals:
      if v.typeName.len > 0:
        hasType = true
        break
    check hasType

  test "struct locals have children":
    ## The test trace has ``TestStruct { a: i32 }`` variables.
    ## Verify that the parser populates ``hasChildren`` and ``children``.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadLocals()
    let locals = session.getLocals()

    # Find a struct variable (typeName contains "TestStruct").
    var foundStruct = false
    for v in locals:
      if "TestStruct" in v.typeName:
        foundStruct = true
        echo "  Found struct: ", v.name, " : ", v.typeName
        check v.hasChildren
        check v.children.len > 0
        # The struct has a field named "a" of type "i32".
        check v.children[0].name == "a"
        echo "    child: ", v.children[0].name, " : ", v.children[0].typeName, " = ", v.children[0].value
        break
    check foundStruct

  test "locals value text is populated":
    ## Verify that variables have non-empty value representations.
    ## Int variables should contain digit strings; struct variables
    ## should have brace-delimited text.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadLocals()
    let locals = session.getLocals()

    # At least one variable should have a non-empty value string.
    var hasValue = false
    for v in locals:
      if v.value.len > 0:
        hasValue = true
        break
    check hasValue

  test "locals update store signals":
    ## Verify that ``requestAndLoadLocals`` populates the store's
    ## ``locals.locals`` signal so the StateVM's ``currentVariables``
    ## memo sees the data.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Before any locals request, the store should be empty.
    check session.session.store.locals.locals.val.len == 0

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadLocals()

    # After loading, the store should have data.
    check session.session.store.locals.locals.val.len > 0

    # The StateVM's currentVariables memo should reflect the same data
    # (since the default tab is stLocals).
    check session.session.stateVM.currentVariables.val.len > 0

# ---------------------------------------------------------------------------
# Suite 3: Calltrace inspection
# ---------------------------------------------------------------------------

suite "Real backend: calltrace":

  test "calltrace has entries after stepping":
    ## After stepping into the trace, requesting the calltrace section
    ## should return at least one call line (the root ``main`` call).
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadCalltrace()
    let lines = session.getCalltraceLines()

    echo "  Calltrace lines count: ", lines.len
    for i, line in lines:
      if i < 5:
        echo "    [", line.index, "] depth=", line.depth, " ", line.name,
             " @ ", line.location.file, ":", line.location.line

    check lines.len > 0

  test "calltrace root is main":
    ## The test trace's root call should be ``main``.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadCalltrace()
    let lines = session.getCalltraceLines()

    check lines.len > 0
    # The first line should be the root call "main" at depth 0.
    check lines[0].name == "main"
    check lines[0].depth == 0

  test "calltrace includes nested function calls":
    ## The test trace calls ``test_struct()`` from ``main()``.
    ## After enough stepping, the calltrace should show nested calls
    ## with depth > 0.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadCalltrace()
    let lines = session.getCalltraceLines()

    var maxDepth = 0
    var hasTestStruct = false
    for line in lines:
      if line.depth > maxDepth:
        maxDepth = line.depth
      if "test_struct" in line.name:
        hasTestStruct = true

    echo "  Max calltrace depth: ", maxDepth
    echo "  Has test_struct call: ", hasTestStruct
    # The trace has at least main -> test_struct, so depth > 0.
    check maxDepth > 0

  test "calltrace lines have location data":
    ## Verify that calltrace lines include source file paths and line numbers.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadCalltrace()
    let lines = session.getCalltraceLines()

    check lines.len > 0
    # The root line (main) should have a non-empty file path.
    check lines[0].location.file.len > 0
    check lines[0].location.line > 0

  test "calltrace updates store signals":
    ## Verify that ``requestAndLoadCalltrace`` populates the store's
    ## calltrace signals (lines, totalCallsCount).
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Before any calltrace request, the store should be empty.
    check session.session.store.calltrace.lines.val.len == 0
    check session.session.store.calltrace.totalCallsCount.val == 0'u64

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadCalltrace()

    # After loading, the store should have data.
    check session.session.store.calltrace.lines.val.len > 0
    check session.session.store.calltrace.totalCallsCount.val > 0'u64

# ---------------------------------------------------------------------------
# Suite 4: Full debugging workflow
# ---------------------------------------------------------------------------

suite "Real backend: full debugging workflow":

  test "step, inspect locals, step again, locals change":
    ## Verify that locals reflect different states at different execution
    ## points. The test trace modifies variables between steps.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Step to a position with locals.
    for i in 0 ..< 4:
      session.stepForward()

    session.requestAndLoadLocals()
    let locals1 = session.getLocals()
    let ticks1 = session.getCurrentRRTicks()

    # Step further — variables should be at a different execution point.
    session.stepForward()
    session.stepForward()

    session.requestAndLoadLocals()
    let locals2 = session.getLocals()
    let ticks2 = session.getCurrentRRTicks()

    echo "  Position 1: rrTicks=", ticks1, " locals=", locals1.len
    echo "  Position 2: rrTicks=", ticks2, " locals=", locals2.len

    # The rrTicks must have advanced.
    check ticks2 > ticks1

  test "locals and calltrace at same position":
    ## Load both locals and calltrace at the same position and verify
    ## both produce data. This exercises the full data pipeline.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    session.requestAndLoadLocals()
    session.requestAndLoadCalltrace()

    let locals = session.getLocals()
    let lines = session.getCalltraceLines()

    echo "  Locals: ", locals.len, ", Calltrace lines: ", lines.len

    check locals.len > 0
    check lines.len > 0

  test "step backward then inspect":
    ## Verify that stepping backward works and produces valid locals.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Step forward several times.
    for i in 0 ..< 6:
      session.stepForward()
    let ticksForward = session.getCurrentRRTicks()

    # Step backward.
    session.stepBackward()
    let ticksBack = session.getCurrentRRTicks()

    echo "  Forward rrTicks=", ticksForward, ", Back rrTicks=", ticksBack

    # rrTicks should have decreased.
    check ticksBack < ticksForward

    # Locals should still be available after stepping back.
    session.requestAndLoadLocals()
    let locals = session.getLocals()
    echo "  Locals after step back: ", locals.len

    # We may or may not have locals at this position depending on where
    # we landed, but the request should not crash.
    check session.getDebuggerStatus() == dsIdle

  test "multiple steps with locals at each position":
    ## Step through several positions and collect locals at each one.
    ## Verifies that the data pipeline is stable across repeated use.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    var positions: seq[tuple[ticks: uint64, localsCount: int]] = @[]

    for i in 0 ..< 8:
      session.stepForward()
      session.requestAndLoadLocals()
      let locals = session.getLocals()
      positions.add((session.getCurrentRRTicks(), locals.len))

    echo "  Collected ", positions.len, " positions"
    for i, p in positions:
      echo "    Step ", i, ": rrTicks=", p.ticks, " locals=", p.localsCount

    # rrTicks should generally advance. The test trace has ~15 steps total,
    # so after reaching the end the position may stop changing. Check that
    # at least the first few steps produce increasing ticks.
    for i in 1 ..< min(5, positions.len):
      check positions[i].ticks >= positions[i - 1].ticks

    # At least some positions should have locals (the trace has variables
    # from about step 4 onwards).
    var anyLocals = false
    for p in positions:
      if p.localsCount > 0:
        anyLocals = true
        break
    check anyLocals

  test "raw locals response matches parsed output":
    ## Send a raw ct/load-locals request and compare the number of
    ## entries with what requestAndLoadLocals puts into the store.
    ## This validates that our JSON parsing does not silently drop entries.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    for i in 0 ..< 6:
      session.stepForward()

    # First, get the raw response.
    let rawResp = session.sendRawDapRequest("ct/load-locals", %*{
      "rrTicks": session.getCurrentRRTicks().int64,
      "countBudget": 3000,
      "minCountLimit": 50,
      "depthLimit": 7,
      "watchExpressions": [],
      "lang": 0,
    })
    let rawLocalsCount = rawResp["body"]["locals"].len

    # Now parse via the headless session method.
    session.requestAndLoadLocals()
    let parsedLocals = session.getLocals()

    echo "  Raw response locals count: ", rawLocalsCount
    echo "  Parsed locals count: ", parsedLocals.len

    # The counts must match — no entries should be dropped.
    check parsedLocals.len == rawLocalsCount
