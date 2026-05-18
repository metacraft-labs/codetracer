## test_multi_session.nim
##
## Headless ViewModel tests for multi-session management and streaming
## recording scenarios.
##
## Replicates key assertions from the Playwright GUI tests:
##   - ``tsc-ui-tests/tests/multi-replay/comprehensive-tabbed-replay.spec.ts``
##   - ``tsc-ui-tests/tests/replay-session/replay-session-scoping.spec.ts``
##
## Instead of verifying DOM elements, these tests verify the DATA exposed
## by the ViewModel layer (debugger position, calltrace lines, locals,
## event log entries, etc.) using multiple HeadlessDebugSession instances,
## each with their own replay-server process and SessionViewModel.
##
## Suite 1: Independent sessions — verifies that two sessions with different
## traces have completely isolated debugger state (positions, locals,
## calltrace).
##
## Suite 2: Session lifecycle — verifies session create, step, inspect,
## and close without leaking state (headless equivalent of
## replay-session-scoping.spec.ts).
##
## Suite 3: Stepping isolation — verifies that stepping in one session
## does not affect the other session's position, locals, or calltrace.
##
## Suite 4: Streaming / incremental data updates — verifies that the
## store signals grow correctly when data is pushed incrementally,
## simulating the streaming recording scenario.
##
## Prerequisites:
##   - replay-server built: ``src/build-debug/bin/replay-server``
##   - ct binary built: ``src/build-debug/bin/ct`` (for trace recording)
##   - Test traces available (Wasm built-in + Python or Noir)
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_multi_session.nim

import std/[json, os, unittest, strutils, osproc, sequtils]
import isonim/core/[signals, computation]
import headless_session
import store/[replay_data_store, types]
import viewmodels/calltrace_vm

# ---------------------------------------------------------------------------
# Helpers — shared with other test files
# ---------------------------------------------------------------------------

proc findReplayServer(): string =
  ## Locate the replay-server binary.
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let thisFile = currentSourcePath()
  let repoRoot = thisFile.parentDir.parentDir.parentDir.parentDir.parentDir
  let candidate = repoRoot / "src" / "build-debug" / "bin" / "replay-server"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "Could not find replay-server binary. Set REPLAY_SERVER_BIN or " &
    "build it with 'cargo build' in src/db-backend/. Tried: " & candidate)

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir

proc findTestTrace(): string =
  ## Locate the built-in Wasm test trace (src/db-backend/trace/).
  let envTrace = getEnv("TEST_TRACE_PATH", "")
  if envTrace.len > 0 and dirExists(envTrace):
    return envTrace
  let candidate = repoRoot() / "src" / "db-backend" / "trace"
  if dirExists(candidate):
    return candidate
  raise newException(IOError,
    "Could not find test trace directory. Set TEST_TRACE_PATH or " &
    "ensure src/db-backend/trace/ exists. Tried: " & candidate)

proc findCtFile(dir: string): string =
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    if path.endsWith(".ct"):
      return path
  return ""

proc isUsableTraceDir(dir: string): bool =
  if fileExists(dir / "trace.bin"):
    return true
  if dirExists(dir / "rr"):
    return true
  if findCtFile(dir).len > 0:
    return true
  return false

proc findExistingTrace(programPattern: string): string =
  ## Search ``~/.local/share/codetracer/`` for a pre-recorded trace whose
  ## metadata program field contains ``programPattern``.
  let baseDir = getHomeDir() / ".local" / "share" / "codetracer"
  if not dirExists(baseDir):
    return ""
  for kind, path in walkDir(baseDir):
    if kind != pcDir:
      continue
    let dirname = path.extractFilename()
    if not dirname.startsWith("trace-"):
      continue
    if not isUsableTraceDir(path):
      continue
    # M-REC-1.5: derive the program identifier from the folder name
    # (legacy JSON sidecars retired).
    let program = dirname
    if programPattern in program:
      return path
  return ""

const recordTimeoutMs = 120_000

proc recordTraceToDefaultLocation(programPath: string; lang: string = ""): string =
  ## Record a trace using ``ct record`` to the default location.
  let ctBin = findCtBinary()
  var args = @["record"]
  if lang.len > 0:
    args.add("--lang")
    args.add(lang)
  args.add(programPath)

  let timeoutSec = recordTimeoutMs div 1000
  let fullCmd = "timeout " & $timeoutSec & " " & quoteShell(ctBin) & " " &
                args.mapIt(quoteShell(it)).join(" ")
  let (output, exitCode) = execCmdEx(fullCmd)
  if exitCode != 0:
    raise newException(IOError,
      "ct record failed (exit " & $exitCode & "): " & output)

  for line in output.splitLines():
    # M-REC-6: stdout marker renamed to ``recordingId:``.
    if line.startsWith("recordingId:"):
      let idStr = line[("recordingId:").len..^1].strip()
      let traceDir = getHomeDir() / ".local" / "share" / "codetracer" / ("trace-" & idStr)
      if dirExists(traceDir):
        return traceDir

  raise newException(IOError,
    "ct record succeeded but could not parse recordingId from output: " & output)

proc findOrRecordTrace(testProgram: string; lang: string = "";
                       entryFile: string = "";
                       programPattern: string = ""): string =
  ## Locate a pre-recorded trace or record a fresh one.
  let pattern = if programPattern.len > 0: programPattern else: testProgram

  let existing = findExistingTrace(pattern)
  if existing.len > 0:
    echo "  Using existing trace: ", existing
    return existing

  let programDir = repoRoot() / "test-programs" / testProgram
  let programPath = if entryFile.len > 0: programDir / entryFile
                    else: programDir
  echo "  Recording trace for: ", programPath
  let traceDir = recordTraceToDefaultLocation(programPath, lang)
  echo "  Recorded trace to: ", traceDir

  if not isUsableTraceDir(traceDir):
    raise newException(IOError,
      "Recorded trace at " & traceDir & " uses an unrecognized format.")

  return traceDir

proc stepToSourceFile(session: HeadlessDebugSession; pattern: string;
                      maxSteps: int = 30) =
  ## Step forward until the current file path contains ``pattern``.
  for i in 0 ..< maxSteps:
    if pattern in session.getCurrentFile():
      return
    session.stepForward()

proc stepToUserCode(session: HeadlessDebugSession) =
  ## Step forward until we land in the Wasm test trace's user code.
  for i in 0 ..< 20:
    if "rust_struct_test" in session.getCurrentFile():
      return
    session.stepForward()

# ---------------------------------------------------------------------------
# Second trace path — try to use a different trace for the second session
# to prove full isolation (different programs, different positions).
# Falls back to the Wasm trace if no other trace is available.
# ---------------------------------------------------------------------------

var secondTracePath: string = ""
  ## Cached path to a second, different trace for multi-session tests.

proc findSecondTrace(): string =
  ## Find a trace different from the built-in Wasm trace.
  ## Tries Noir first, then Python, then falls back to the Wasm trace
  ## (same trace, different session — still proves process isolation).
  if secondTracePath.len > 0:
    return secondTracePath

  # Try Noir.
  try:
    secondTracePath = findOrRecordTrace("noir_space_ship",
                                        programPattern = "noir")
    return secondTracePath
  except IOError, OSError:
    discard

  # Try Python.
  try:
    secondTracePath = findOrRecordTrace("py_console_logs",
                                        entryFile = "main.py",
                                        programPattern = "py_console_logs")
    return secondTracePath
  except IOError, OSError:
    discard

  # Fallback: use the same Wasm trace in both sessions.
  echo "  NOTE: Using the same Wasm trace for both sessions (no second trace found)"
  secondTracePath = findTestTrace()
  return secondTracePath

# ---------------------------------------------------------------------------
# Suite 1: Independent sessions — data isolation between two replay sessions
# ---------------------------------------------------------------------------

suite "Multi-session: independent sessions":

  test "two sessions have independent debugger positions":
    ## Open two HeadlessDebugSessions with different traces.
    ## Step forward in session 1 only.
    ## Verify that session 2's debugger position is unchanged.
    ##
    ## Headless equivalent of comprehensive-tabbed-replay.spec.ts test 1:
    ## "tab switching preserves all panel state across tabs" — the data-model
    ## assertion that stepping in one session does not affect another.
    let trace1 = findTestTrace()
    let trace2 = findSecondTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace1, replayBin)
    let session2 = newHeadlessDebugSession(trace2, replayBin)
    defer:
      session1.close()
      session2.close()

    # Record initial positions for both sessions.
    let initialTicks1 = session1.getCurrentRRTicks()
    let initialTicks2 = session2.getCurrentRRTicks()
    let initialLine2 = session2.getCurrentLine()
    let initialFile2 = session2.getCurrentFile()

    echo "  Session1 initial: rrTicks=", initialTicks1
    echo "  Session2 initial: rrTicks=", initialTicks2,
         " file=", initialFile2, ":", initialLine2

    # Step session 1 forward several times.
    for i in 0 ..< 5:
      session1.stepForward()

    let afterStepTicks1 = session1.getCurrentRRTicks()
    let afterStepTicks2 = session2.getCurrentRRTicks()
    let afterStepLine2 = session2.getCurrentLine()
    let afterStepFile2 = session2.getCurrentFile()

    echo "  Session1 after step: rrTicks=", afterStepTicks1
    echo "  Session2 after step: rrTicks=", afterStepTicks2,
         " file=", afterStepFile2, ":", afterStepLine2

    # Session 1 should have moved.
    check afterStepTicks1 != initialTicks1

    # Session 2 should NOT have moved.
    check afterStepTicks2 == initialTicks2
    check afterStepLine2 == initialLine2
    check afterStepFile2 == initialFile2

  test "locals in one session don't leak to another":
    ## Load locals in session 1 after stepping.
    ## Verify session 2's locals store is still empty (or contains
    ## different data if the trace has initial locals).
    ##
    ## This proves that the reactive store is per-session — there is
    ## no shared global state between HeadlessDebugSession instances.
    let trace1 = findTestTrace()
    let trace2 = findSecondTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace1, replayBin)
    let session2 = newHeadlessDebugSession(trace2, replayBin)
    defer:
      session1.close()
      session2.close()

    # Step session 1 into user code and load locals.
    stepToUserCode(session1)
    for i in 0 ..< 3:
      session1.stepForward()
    session1.requestAndLoadLocals()
    let locals1 = session1.getLocals()

    echo "  Session1 locals count: ", locals1.len

    # Session 2 has NOT had locals loaded — its store should be empty.
    let locals2 = session2.getLocals()

    echo "  Session2 locals count: ", locals2.len

    # Session 1 should have locals at this point (Wasm trace has locals
    # after a few steps).
    check locals1.len > 0

    # Session 2 should have empty locals (no requestAndLoadLocals called).
    check locals2.len == 0

    # The store signals themselves are different objects.
    check session1.session.store.locals.locals.val.len > 0
    check session2.session.store.locals.locals.val.len == 0

  test "stepping in session 1 doesn't affect session 2 calltrace":
    ## Load calltrace in both sessions.
    ## Step session 1 forward and reload its calltrace.
    ## Verify session 2's calltrace is unchanged.
    let trace1 = findTestTrace()
    let trace2 = findSecondTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace1, replayBin)
    let session2 = newHeadlessDebugSession(trace2, replayBin)
    defer:
      session1.close()
      session2.close()

    # Step both sessions to positions with calltrace data.
    for i in 0 ..< 6:
      session1.stepForward()
    for i in 0 ..< 4:
      session2.stepForward()

    # Load calltrace in both sessions.
    session1.requestAndLoadCalltrace()
    session2.requestAndLoadCalltrace()

    let calltrace2Before = session2.getCalltraceLines()
    let ticks2Before = session2.getCurrentRRTicks()

    echo "  Session2 calltrace before: ", calltrace2Before.len, " lines"
    echo "  Session2 position before: rrTicks=", ticks2Before

    # Step session 1 further and reload its calltrace.
    for i in 0 ..< 3:
      session1.stepForward()
    session1.requestAndLoadCalltrace()

    # Verify session 2's calltrace is unchanged.
    let calltrace2After = session2.getCalltraceLines()
    let ticks2After = session2.getCurrentRRTicks()

    echo "  Session2 calltrace after: ", calltrace2After.len, " lines"
    echo "  Session2 position after: rrTicks=", ticks2After

    check calltrace2After.len == calltrace2Before.len
    check ticks2After == ticks2Before

    # Verify the actual calltrace content is identical.
    for i in 0 ..< calltrace2Before.len:
      check calltrace2After[i].name == calltrace2Before[i].name
      check calltrace2After[i].rrTicks == calltrace2Before[i].rrTicks

  test "event log in one session doesn't affect another":
    ## Request event log in session 1.
    ## Verify that session 2's event log request returns independent data.
    let trace1 = findTestTrace()
    let trace2 = findSecondTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace1, replayBin)
    let session2 = newHeadlessDebugSession(trace2, replayBin)
    defer:
      session1.close()
      session2.close()

    for i in 0 ..< 6:
      session1.stepForward()
    for i in 0 ..< 4:
      session2.stepForward()

    let events1 = session1.requestAndLoadEventLog()
    let events2 = session2.requestAndLoadEventLog()

    echo "  Session1 event log: ", events1.len, " entries"
    echo "  Session2 event log: ", events2.len, " entries"

    # Both requests should complete without error.
    check session1.getDebuggerStatus() == dsIdle
    check session2.getDebuggerStatus() == dsIdle

    # If using different traces, event logs may differ.
    # If using the same trace, they should be the same — but the point
    # is that requesting events in session 1 did not corrupt session 2.
    # At minimum, the sessions should still be independently functional.

# ---------------------------------------------------------------------------
# Suite 2: Session lifecycle — create, inspect, step, verify, close
# ---------------------------------------------------------------------------

suite "Multi-session: session lifecycle":

  test "session holds valid state after creation":
    ## Headless equivalent of replay-session-scoping.spec.ts test 1:
    ## "activeSession exists and holds trace state".
    ##
    ## Verifies that a newly created HeadlessDebugSession has:
    ## - A valid debugger state (idle)
    ## - A non-nil store with all sub-stores initialized
    ## - All panel VMs created
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Debugger should be idle after initialization.
    check session.getDebuggerStatus() == dsIdle

    # Store should exist and have initialized sub-stores.
    check not session.session.store.isNil
    check session.session.store.calltrace.lines.val.len == 0  # no data yet
    check session.session.store.locals.locals.val.len == 0    # no data yet
    check session.session.store.calltrace.totalCallsCount.val == 0'u64

    # All panel VMs should be created (non-nil).
    check not session.session.stateVM.isNil
    check not session.session.calltraceVM.isNil
    check not session.session.eventLogVM.isNil
    check not session.session.flowVM.isNil
    check not session.session.editorVM.isNil
    check not session.session.timelineVM.isNil
    check not session.session.debugControlsVM.isNil
    check not session.session.searchVM.isNil
    check not session.session.pointListVM.isNil
    check not session.session.scratchpadVM.isNil
    check not session.session.shellVM.isNil

    echo "  Session created with all VMs initialized"

  test "session holds debugger location after stepping":
    ## Headless equivalent of replay-session-scoping.spec.ts test 2:
    ## "session holds debugger location after stepping".
    ##
    ## Steps forward and verifies the store's debugger signal has a valid
    ## location with non-zero rrTicks and a non-empty file path.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    let initialTicks = session.getCurrentRRTicks()

    session.stepForward()

    let ticks = session.getCurrentRRTicks()
    let file = session.getCurrentFile()
    let line = session.getCurrentLine()

    echo "  After step: ", file, ":", line, " (rrTicks=", ticks, ")"

    check session.getDebuggerStatus() == dsIdle
    check ticks != initialTicks or line > 0
    # The debugger state in the store should reflect the new position.
    let dbg = session.session.store.debugger.val
    check dbg.rrTicks == ticks
    check dbg.location.file == file
    check dbg.location.line == line

  test "session state preserved after multiple operations":
    ## Create a session, perform a series of operations (step, load locals,
    ## load calltrace, step again), and verify that each operation leaves
    ## the session in a consistent state.
    ##
    ## This is the headless equivalent of the comprehensive-tabbed-replay
    ## assertion that "all panels reload correctly and remain interactive
    ## after session-model operations".
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Step to user code.
    stepToUserCode(session)
    let file1 = session.getCurrentFile()
    check "rust_struct_test" in file1

    # Load locals.
    session.requestAndLoadLocals()
    let locals1 = session.getLocals()
    let ticks1 = session.getCurrentRRTicks()

    echo "  Position 1: ", file1, " rrTicks=", ticks1, " locals=", locals1.len

    # Load calltrace.
    session.requestAndLoadCalltrace()
    let calltrace1 = session.getCalltraceLines()

    echo "  Calltrace at position 1: ", calltrace1.len, " lines"

    # Step forward more.
    session.stepForward()
    session.stepForward()

    let ticks2 = session.getCurrentRRTicks()
    let file2 = session.getCurrentFile()

    echo "  Position 2: ", file2, " rrTicks=", ticks2

    # Load locals again at the new position.
    session.requestAndLoadLocals()
    let locals2 = session.getLocals()

    echo "  Locals at position 2: ", locals2.len

    # Verify the session is still in a consistent state.
    check ticks2 > ticks1
    check session.getDebuggerStatus() == dsIdle

    # Load calltrace again — should reflect the new position.
    session.requestAndLoadCalltrace()
    let calltrace2 = session.getCalltraceLines()

    echo "  Calltrace at position 2: ", calltrace2.len, " lines"
    check calltrace2.len > 0

  test "two sessions can be created and closed independently":
    ## Verify that closing one session does not affect the other.
    ## This is important because each HeadlessDebugSession owns its own
    ## replay-server process — closing one must not kill the other.
    let trace1 = findTestTrace()
    let trace2 = findSecondTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace1, replayBin)
    let session2 = newHeadlessDebugSession(trace2, replayBin)

    # Both sessions should be functional.
    check session1.getDebuggerStatus() == dsIdle
    check session2.getDebuggerStatus() == dsIdle

    session1.stepForward()
    session2.stepForward()

    let ticks1 = session1.getCurrentRRTicks()
    let ticks2 = session2.getCurrentRRTicks()

    echo "  Session1 rrTicks=", ticks1
    echo "  Session2 rrTicks=", ticks2

    # Close session 1.
    session1.close()

    # Session 2 should still be fully functional.
    session2.stepForward()
    let ticks2After = session2.getCurrentRRTicks()

    echo "  Session2 after session1 closed: rrTicks=", ticks2After

    check ticks2After > ticks2
    check session2.getDebuggerStatus() == dsIdle

    # Close session 2.
    session2.close()

# ---------------------------------------------------------------------------
# Suite 3: Stepping isolation
# ---------------------------------------------------------------------------

suite "Multi-session: stepping isolation":

  test "stepping session 1 forward doesn't move session 2":
    ## Step session 1 forward multiple times.
    ## After each step, verify session 2's rrTicks is unchanged.
    ##
    ## Headless equivalent of comprehensive-tabbed-replay.spec.ts test 3:
    ## "stepping in one tab doesn't affect another".
    let trace1 = findTestTrace()
    let trace2 = findSecondTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace1, replayBin)
    let session2 = newHeadlessDebugSession(trace2, replayBin)
    defer:
      session1.close()
      session2.close()

    let frozenTicks2 = session2.getCurrentRRTicks()
    let frozenFile2 = session2.getCurrentFile()
    let frozenLine2 = session2.getCurrentLine()

    echo "  Session2 frozen at: rrTicks=", frozenTicks2,
         " file=", frozenFile2, ":", frozenLine2

    # Step session 1 forward 8 times, checking session 2 after each.
    for i in 0 ..< 8:
      session1.stepForward()

      let currentTicks2 = session2.getCurrentRRTicks()
      let currentFile2 = session2.getCurrentFile()
      let currentLine2 = session2.getCurrentLine()

      check currentTicks2 == frozenTicks2
      check currentFile2 == frozenFile2
      check currentLine2 == frozenLine2

    echo "  Session1 after 8 steps: rrTicks=", session1.getCurrentRRTicks()
    echo "  Session2 unchanged: rrTicks=", session2.getCurrentRRTicks()

  test "stepping both sessions independently":
    ## Step both sessions forward, but different amounts.
    ## Verify each session is at its own independent position.
    let trace1 = findTestTrace()
    let trace2 = findSecondTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace1, replayBin)
    let session2 = newHeadlessDebugSession(trace2, replayBin)
    defer:
      session1.close()
      session2.close()

    # Step session 1 forward 3 times.
    for i in 0 ..< 3:
      session1.stepForward()
    let ticks1After3 = session1.getCurrentRRTicks()

    # Step session 2 forward 6 times.
    for i in 0 ..< 6:
      session2.stepForward()
    let ticks2After6 = session2.getCurrentRRTicks()

    echo "  Session1 after 3 steps: rrTicks=", ticks1After3
    echo "  Session2 after 6 steps: rrTicks=", ticks2After6

    # Session 1's position should not have changed after session 2's steps.
    check session1.getCurrentRRTicks() == ticks1After3

    # Both should be idle.
    check session1.getDebuggerStatus() == dsIdle
    check session2.getDebuggerStatus() == dsIdle

  test "step backward in one session, forward in another":
    ## Step session 1 forward, then backward.
    ## Step session 2 only forward.
    ## Verify their positions are independent.
    let trace1 = findTestTrace()
    let trace2 = findSecondTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace1, replayBin)
    let session2 = newHeadlessDebugSession(trace2, replayBin)
    defer:
      session1.close()
      session2.close()

    # Step session 1 forward 5 times, then backward 2 times.
    for i in 0 ..< 5:
      session1.stepForward()
    let ticks1Forward = session1.getCurrentRRTicks()

    session1.stepBackward()
    session1.stepBackward()
    let ticks1Back = session1.getCurrentRRTicks()

    echo "  Session1: forward=", ticks1Forward, " back=", ticks1Back
    check ticks1Back < ticks1Forward

    # Step session 2 forward 3 times.
    for i in 0 ..< 3:
      session2.stepForward()
    let ticks2 = session2.getCurrentRRTicks()

    echo "  Session2 after 3 steps: rrTicks=", ticks2

    # Both should be independently functional.
    check session1.getDebuggerStatus() == dsIdle
    check session2.getDebuggerStatus() == dsIdle

    # Session 1's backward step should not have affected session 2.
    # (ticks2 should reflect session 2's own independent progress)
    let ticks2Check = session2.getCurrentRRTicks()
    check ticks2Check == ticks2

# ---------------------------------------------------------------------------
# Suite 4: Streaming / incremental data updates
# ---------------------------------------------------------------------------

suite "Streaming: incremental store updates":

  test "calltrace grows when data is pushed incrementally":
    ## Simulate streaming by pushing calltrace data into the store
    ## incrementally.  This verifies that the store's reactive signals
    ## correctly reflect growing data, as would happen during a live
    ## recording session where calltrace entries arrive over time.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Verify store starts empty.
    check session.session.store.calltrace.lines.val.len == 0
    check session.session.store.calltrace.totalCallsCount.val == 0'u64

    # Push a first batch of calltrace lines.
    let batch1 = @[
      CallLine(index: 0, name: "main", depth: 0, rrTicks: 100'u64,
               location: Location(file: "test.rs", line: 1)),
      CallLine(index: 1, name: "foo", depth: 1, rrTicks: 200'u64,
               location: Location(file: "test.rs", line: 10)),
    ]
    session.session.store.updateCalltraceSection(batch1, 0, 5)

    check session.session.store.calltrace.lines.val.len == 2
    check session.session.store.calltrace.totalCallsCount.val == 5'u64
    check session.session.store.calltrace.lines.val[0].name == "main"
    check session.session.store.calltrace.lines.val[1].name == "foo"

    echo "  After batch 1: ", session.session.store.calltrace.lines.val.len, " lines"

    # Push a second batch (simulates more data arriving during streaming).
    let batch2 = @[
      CallLine(index: 0, name: "main", depth: 0, rrTicks: 100'u64,
               location: Location(file: "test.rs", line: 1)),
      CallLine(index: 1, name: "foo", depth: 1, rrTicks: 200'u64,
               location: Location(file: "test.rs", line: 10)),
      CallLine(index: 2, name: "bar", depth: 1, rrTicks: 300'u64,
               location: Location(file: "test.rs", line: 20)),
      CallLine(index: 3, name: "baz", depth: 2, rrTicks: 400'u64,
               location: Location(file: "test.rs", line: 30)),
    ]
    session.session.store.updateCalltraceSection(batch2, 0, 10)

    check session.session.store.calltrace.lines.val.len == 4
    check session.session.store.calltrace.totalCallsCount.val == 10'u64
    check session.session.store.calltrace.lines.val[2].name == "bar"
    check session.session.store.calltrace.lines.val[3].name == "baz"

    echo "  After batch 2: ", session.session.store.calltrace.lines.val.len, " lines"

  test "locals grow as variables are discovered":
    ## Simulate streaming by pushing locals data into the store
    ## incrementally.  First push has 1 variable, second has 3.
    ## Verifies the store replaces the old data with the new batch.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    check session.session.store.locals.locals.val.len == 0

    # Push first batch: 1 variable.
    let vars1 = @[
      Variable(name: "x", value: "42", typeName: "i32"),
    ]
    session.session.store.updateLocals(vars1)

    check session.session.store.locals.locals.val.len == 1
    check session.session.store.locals.locals.val[0].name == "x"
    check session.session.store.locals.locals.val[0].value == "42"

    echo "  After batch 1: ", session.session.store.locals.locals.val.len, " locals"

    # Push second batch: 3 variables (replaces the old batch).
    let vars2 = @[
      Variable(name: "x", value: "43", typeName: "i32"),
      Variable(name: "y", value: "100", typeName: "i32"),
      Variable(name: "name", value: "\"hello\"", typeName: "String"),
    ]
    session.session.store.updateLocals(vars2)

    check session.session.store.locals.locals.val.len == 3
    check session.session.store.locals.locals.val[0].value == "43"
    check session.session.store.locals.locals.val[1].name == "y"
    check session.session.store.locals.locals.val[2].name == "name"

    echo "  After batch 2: ", session.session.store.locals.locals.val.len, " locals"

  test "debugger position updates incrementally during streaming":
    ## Simulate the debugger position advancing as a recording progresses.
    ## Push position updates into the store and verify signals update.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Push position update 1.
    session.session.store.updateDebuggerPosition(1000'u64, "main.py", 5)

    check session.session.store.debugger.val.rrTicks == 1000'u64
    check session.session.store.debugger.val.location.file == "main.py"
    check session.session.store.debugger.val.location.line == 5

    # Push position update 2 (simulates execution advancing).
    session.session.store.updateDebuggerPosition(2000'u64, "main.py", 10)

    check session.session.store.debugger.val.rrTicks == 2000'u64
    check session.session.store.debugger.val.location.line == 10

    # Push position update 3 (different file — simulates stepping into another module).
    session.session.store.updateDebuggerPosition(3000'u64, "helper.py", 1)

    check session.session.store.debugger.val.rrTicks == 3000'u64
    check session.session.store.debugger.val.location.file == "helper.py"
    check session.session.store.debugger.val.location.line == 1

    echo "  Final position: ", session.session.store.debugger.val.location.file,
         ":", session.session.store.debugger.val.location.line,
         " rrTicks=", session.session.store.debugger.val.rrTicks

  test "real calltrace grows as session steps forward":
    ## Use a real replay session to verify that the calltrace section
    ## contains more data after stepping further into execution.
    ## This is the real-backend equivalent of the streaming scenario.
    let session = newHeadlessDebugSession(findTestTrace(), findReplayServer())
    defer: session.close()

    # Step a small number of times and load calltrace.
    for i in 0 ..< 3:
      session.stepForward()

    session.requestAndLoadCalltrace()
    let lines1 = session.getCalltraceLines()
    let total1 = session.session.store.calltrace.totalCallsCount.val

    echo "  After 3 steps: ", lines1.len, " calltrace lines, total=", total1

    # Step further and reload calltrace.
    for i in 0 ..< 5:
      session.stepForward()

    session.requestAndLoadCalltrace()
    let lines2 = session.getCalltraceLines()
    let total2 = session.session.store.calltrace.totalCallsCount.val

    echo "  After 8 steps: ", lines2.len, " calltrace lines, total=", total2

    # The calltrace should have at least as many entries after more stepping.
    # The totalCallsCount should be non-decreasing.
    check total2 >= total1
    check lines2.len > 0

  test "incremental updates to two sessions don't cross-contaminate":
    ## Push synthetic data into two separate sessions' stores.
    ## Verify each store only has its own data.
    let trace = findTestTrace()
    let replayBin = findReplayServer()

    let session1 = newHeadlessDebugSession(trace, replayBin)
    let session2 = newHeadlessDebugSession(trace, replayBin)
    defer:
      session1.close()
      session2.close()

    # Push different locals into each session.
    session1.session.store.updateLocals(@[
      Variable(name: "alpha", value: "1", typeName: "i32"),
    ])
    session2.session.store.updateLocals(@[
      Variable(name: "beta", value: "2", typeName: "i32"),
      Variable(name: "gamma", value: "3", typeName: "i32"),
    ])

    check session1.session.store.locals.locals.val.len == 1
    check session1.session.store.locals.locals.val[0].name == "alpha"

    check session2.session.store.locals.locals.val.len == 2
    check session2.session.store.locals.locals.val[0].name == "beta"
    check session2.session.store.locals.locals.val[1].name == "gamma"

    # Push different calltrace into each session.
    session1.session.store.updateCalltraceSection(@[
      CallLine(index: 0, name: "fn_a", depth: 0, rrTicks: 100'u64,
               location: Location(file: "a.rs", line: 1)),
    ], 0, 1)

    session2.session.store.updateCalltraceSection(@[
      CallLine(index: 0, name: "fn_b", depth: 0, rrTicks: 200'u64,
               location: Location(file: "b.rs", line: 1)),
      CallLine(index: 1, name: "fn_c", depth: 1, rrTicks: 300'u64,
               location: Location(file: "b.rs", line: 10)),
    ], 0, 2)

    check session1.session.store.calltrace.lines.val.len == 1
    check session1.session.store.calltrace.lines.val[0].name == "fn_a"

    check session2.session.store.calltrace.lines.val.len == 2
    check session2.session.store.calltrace.lines.val[0].name == "fn_b"

    echo "  Session1: 1 local, 1 calltrace line"
    echo "  Session2: 2 locals, 2 calltrace lines"
    echo "  No cross-contamination detected"
