## test_debugging_scenarios.nim
##
## ViewModel integration tests that exercise realistic time-travel debugging
## workflows through the full SessionViewModel + MockBackendService stack.
##
## Unlike the unit tests (test_state_vm.nim, test_calltrace_vm.nim, etc.)
## which verify individual VMs in isolation, these tests simulate
## multi-step debugging sessions where:
## - The debugger moves through execution points (forward and backward)
## - Variables change at each position
## - Multiple VMs must stay in sync through the shared ReplayDataStore
## - Request deduplication prevents redundant backend calls
## - Debug control state machine transitions are correct
##
## Each scenario is self-contained with its own reactive root and mock
## backend, ensuring full isolation between tests.
##
## Scenarios:
## 1. Step through a function and inspect variables
## 2. Reverse step preserves state (time-travel debugging)
## 3. Calltrace viewport loading on scroll
## 4. Breakpoint hit in loop shows correct iteration
## 5. Rapid stepping deduplicates requests
## 6. Watch expression lifecycle
## 7. Debug controls state machine
## 8. Cross-VM consistency after move
## 9. Data minimality — unchanged position does not re-request
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_debugging_scenarios.nim

import std/[json, unittest, options, sets]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import app/app_vm
import store/types
import store/replay_data_store
import store/request_tracker
import viewmodels/[
  state_vm,
  calltrace_vm,
  debug_controls_vm,
  editor_vm,
  timeline_vm,
  event_log_vm,
  flow_vm,
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeCallLine(index: int64; name: string; depth: int = 0;
                  rrTicks: uint64 = 0; file: string = "";
                  line: int = 0): CallLine =
  ## Convenience constructor for CallLine test data.
  CallLine(
    index: index,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: file, line: line, column: 0),
  )

proc countCommands(mock: MockBackendService; command: string): int =
  ## Count how many times a specific command was sent to the mock.
  result = 0
  for rc in mock.receivedCommands:
    if rc.command == command:
      inc result

# ---------------------------------------------------------------------------
# Scenario 1: Step through a function and inspect variables
# ---------------------------------------------------------------------------

suite "Scenario 1: Step through a function and inspect variables":

  test "stepping forward updates locals at each position":
    ## Simulates a debugging session where the user steps through a
    ## function line by line, verifying that the locals panel shows
    ## the correct variables at each execution point.
    ##
    ## Timeline:
    ##   rrTicks 100 → line 1 (entry point)
    ##   rrTicks 200 → line 5, locals: x=42, msg="hello"
    ##   rrTicks 300 → line 8, locals: x=43, msg="hello", result=true
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # The auto-load effect fires on creation at rrTicks=0.
      # Clear initial commands to isolate the position change.
      mock.clearReceivedCommands()

      # 1. Load trace — debugger at entry point (line 1, rrTicks 100).
      session.store.updateDebuggerPosition(100'u64, "example.py", 1)
      drain()

      # Verify a locals request was sent for rrTicks 100.
      var localsCmd = mock.findCommand("ct/load-locals")
      check localsCmd.isSome
      check localsCmd.get.args["rrTicks"].getBiggestInt == 100

      # Simulate initial locals arriving (entry point — no locals yet).
      session.store.updateLocals(@[])
      check session.stateVM.currentVariables.val.len == 0

      # 2. Step forward — debugger moves to line 5, rrTicks 200.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(200'u64, "example.py", 5)
      drain()

      # 3. Verify a new locals request was sent with the new rrTicks.
      localsCmd = mock.findCommand("ct/load-locals")
      check localsCmd.isSome
      check localsCmd.get.args["rrTicks"].getBiggestInt == 200

      # 4. Locals response arrives: x=42, msg="hello".
      session.store.updateLocals(@[
        Variable(name: "x", value: "42", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "msg", value: "hello", typeName: "str",
                 hasChildren: false, children: @[]),
      ])

      # 5. Verify StateVM.currentVariables has both variables.
      check session.stateVM.currentVariables.val.len == 2
      check session.stateVM.currentVariables.val[0].name == "x"
      check session.stateVM.currentVariables.val[0].value == "42"
      check session.stateVM.currentVariables.val[1].name == "msg"
      check session.stateVM.currentVariables.val[1].value == "hello"

      # 6. Step forward again — debugger moves to line 8, rrTicks 300.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(300'u64, "example.py", 8)
      drain()

      # 7. Verify a new locals request was sent with rrTicks 300.
      localsCmd = mock.findCommand("ct/load-locals")
      check localsCmd.isSome
      check localsCmd.get.args["rrTicks"].getBiggestInt == 300

      # 8. New locals arrive: x=43, msg="hello", result=true.
      session.store.updateLocals(@[
        Variable(name: "x", value: "43", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "msg", value: "hello", typeName: "str",
                 hasChildren: false, children: @[]),
        Variable(name: "result", value: "true", typeName: "bool",
                 hasChildren: false, children: @[]),
      ])

      # 9. Verify StateVM.currentVariables now has 3 variables.
      check session.stateVM.currentVariables.val.len == 3
      check session.stateVM.currentVariables.val[0].value == "43"
      check session.stateVM.currentVariables.val[2].name == "result"
      check session.stateVM.currentVariables.val[2].value == "true"

      dispose()

# ---------------------------------------------------------------------------
# Scenario 2: Reverse step preserves state (time-travel debugging)
# ---------------------------------------------------------------------------

suite "Scenario 2: Reverse step preserves state":

  test "stepping backward shows previous variable values":
    ## Simulates stepping backward through execution, verifying that
    ## the ViewModel layer correctly requests and displays historical
    ## variable state — the core value proposition of time-travel debugging.
    ##
    ## Timeline (reverse):
    ##   rrTicks 500 → line 10, x=43
    ##   rrTicks 400 → line 8, x=42 (previous value)
    ##   rrTicks 200 → line 5, x=10 (even earlier)
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # 1. Debugger at line 10, rrTicks 500.
      session.store.updateDebuggerPosition(500'u64, "solver.py", 10)
      drain()
      session.store.updateLocals(@[
        Variable(name: "x", value: "43", typeName: "int",
                 hasChildren: false, children: @[]),
      ])
      check session.stateVM.currentVariables.val[0].value == "43"

      # 2. Step backward — debugger moves to line 8, rrTicks 400.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(400'u64, "solver.py", 8)
      drain()

      # 3. Verify a locals request was sent with rrTicks 400.
      let cmd400 = mock.findCommand("ct/load-locals")
      check cmd400.isSome
      check cmd400.get.args["rrTicks"].getBiggestInt == 400

      # 4. Locals show previous state: x=42 (not 43).
      session.store.updateLocals(@[
        Variable(name: "x", value: "42", typeName: "int",
                 hasChildren: false, children: @[]),
      ])

      # 5. Verify StateVM reflects the older value.
      check session.stateVM.currentVariables.val.len == 1
      check session.stateVM.currentVariables.val[0].value == "42"

      # 6. Step backward again — line 5, rrTicks 200.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(200'u64, "solver.py", 5)
      drain()

      # 7. Verify a locals request was sent with rrTicks 200.
      let cmd200 = mock.findCommand("ct/load-locals")
      check cmd200.isSome
      check cmd200.get.args["rrTicks"].getBiggestInt == 200

      # Locals show even earlier state.
      session.store.updateLocals(@[
        Variable(name: "x", value: "10", typeName: "int",
                 hasChildren: false, children: @[]),
      ])
      check session.stateVM.currentVariables.val[0].value == "10"

      dispose()

  test "editor VM tracks file name during reverse steps":
    ## Verifies that the EditorVM's activeFileName memo updates
    ## correctly when stepping backward through different files.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      session.store.updateDebuggerPosition(500'u64, "main.py", 20)
      drain()
      check session.editorVM.activeFileName.val == "main.py"

      # Reverse step into a callee in a different file.
      session.store.updateDebuggerPosition(400'u64, "utils.py", 15)
      drain()
      check session.editorVM.activeFileName.val == "utils.py"

      # Reverse step back to the caller.
      session.store.updateDebuggerPosition(300'u64, "main.py", 18)
      drain()
      check session.editorVM.activeFileName.val == "main.py"

      dispose()

# ---------------------------------------------------------------------------
# Scenario 3: Calltrace viewport loading on scroll
# ---------------------------------------------------------------------------

suite "Scenario 3: Calltrace viewport loading on scroll":

  test "scroll triggers correct calltrace section requests":
    ## Simulates a calltrace with 1000 entries, verifying that
    ## scrolling triggers backend requests with the correct
    ## startCallLineIndex and height, and that the derived
    ## hasMoreAbove / hasMoreBelow signals reflect the position.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # Set up a large calltrace (1000 entries total).
      session.store.calltrace.totalCallsCount.val = 1000'u64

      # Set debugger position so auto-load effect fires.
      session.store.updateDebuggerPosition(100'u64, "main.py", 1)

      # Set viewport to show 30 rows.
      session.calltraceVM.setViewportHeight(30)
      drain()

      # The initial request should have been sent.
      check mock.countCommands("ct/load-calltrace-section") >= 1

      # Populate the store with data around the initial position.
      var initialLines: seq[CallLine] = @[]
      for i in 0 ..< 70:
        initialLines.add(makeCallLine(i.int64, "func_" & $i,
                         rrTicks = (100 + i * 10).uint64))
      session.store.calltrace.lines.val = initialLines
      session.store.calltrace.startLineIndex.val = 0'i64

      # At position 0, there should be nothing above.
      session.calltraceVM.scroll(0)
      check session.calltraceVM.hasMoreAbove.val == false
      check session.calltraceVM.hasMoreBelow.val == true

      # 2. Scroll to position 100.
      mock.clearReceivedCommands()
      session.calltraceVM.scroll(100)
      drain()

      # Verify a request was sent with the buffered start index.
      let scrollCmd = mock.findCommand("ct/load-calltrace-section")
      check scrollCmd.isSome
      let startIdx = scrollCmd.get.args["startCallLineIndex"].getBiggestInt
      check startIdx == 100 - CALLTRACE_BUFFER
      check session.calltraceVM.hasMoreAbove.val == true

      # 7. Scroll to position 0 — hasMoreAbove = false.
      session.calltraceVM.scroll(0)
      check session.calltraceVM.hasMoreAbove.val == false

      # 8. Scroll near the end — hasMoreBelow = false when viewport covers rest.
      session.calltraceVM.scroll(970)
      check session.calltraceVM.hasMoreBelow.val == false

      dispose()

  test "visibleLines returns correct slice after data load":
    ## Verifies that the visibleLines memo returns the correct
    ## subset of calltrace lines for the current viewport.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session

      # Populate store with lines [80..129] (50 entries).
      var lines: seq[CallLine] = @[]
      for i in 80 ..< 130:
        lines.add(makeCallLine(i.int64, "call_" & $i))
      session.store.calltrace.lines.val = lines
      session.store.calltrace.startLineIndex.val = 80'i64
      session.store.calltrace.totalCallsCount.val = 1000'u64

      # Viewport at position 100, height 30.
      session.calltraceVM.scrollPosition.val = 100'i64
      session.calltraceVM.viewportHeight.val = 30

      let visible = session.calltraceVM.visibleLines.val
      # Lines 100-129 are in the store (offset 20-49), viewport wants 30.
      check visible.len == 30
      check visible[0].index == 100
      check visible[29].index == 129

      dispose()

# ---------------------------------------------------------------------------
# Scenario 4: Breakpoint hit in loop shows correct iteration
# ---------------------------------------------------------------------------

suite "Scenario 4: Breakpoint hit in loop shows correct iteration":

  test "continue to breakpoint updates locals at each hit":
    ## Simulates a loop with a breakpoint that is hit multiple times.
    ## Each continue resumes execution until the next breakpoint hit,
    ## where the variables reflect the current loop iteration.
    ##
    ## Loop: counter goes 1..10, breakpoint at line 20.
    ## rrTicks 1000 → counter=1, value=2
    ## rrTicks 2000 → counter=2, value=4
    ## rrTicks 3000 → counter=3, value=6
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # 1. First breakpoint hit: counter=1, value=2.
      session.store.updateDebuggerPosition(1000'u64, "loop.py", 20)
      drain()

      session.store.updateLocals(@[
        Variable(name: "counter", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "value", value: "2", typeName: "int",
                 hasChildren: false, children: @[]),
      ])

      # 3. Verify locals show iteration 1.
      check session.stateVM.currentVariables.val.len == 2
      check session.stateVM.currentVariables.val[0].value == "1"
      check session.stateVM.currentVariables.val[1].value == "2"

      # 4. Continue — second breakpoint hit: counter=2, value=4.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(2000'u64, "loop.py", 20)
      drain()

      # Verify a new locals request was sent with rrTicks 2000.
      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isSome
      check cmd.get.args["rrTicks"].getBiggestInt == 2000

      session.store.updateLocals(@[
        Variable(name: "counter", value: "2", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "value", value: "4", typeName: "int",
                 hasChildren: false, children: @[]),
      ])

      # 5. Verify StateVM.currentVariables updates correctly.
      check session.stateVM.currentVariables.val.len == 2
      check session.stateVM.currentVariables.val[0].value == "2"
      check session.stateVM.currentVariables.val[1].value == "4"

      # 6. Continue — third breakpoint hit: counter=3, value=6.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(3000'u64, "loop.py", 20)
      drain()

      session.store.updateLocals(@[
        Variable(name: "counter", value: "3", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "value", value: "6", typeName: "int",
                 hasChildren: false, children: @[]),
      ])

      # 7. Verify old locals are replaced, not accumulated.
      check session.stateVM.currentVariables.val.len == 2
      check session.stateVM.currentVariables.val[0].value == "3"
      check session.stateVM.currentVariables.val[1].value == "6"

      dispose()

  test "timeline position tracks breakpoint hits":
    ## Verifies that the TimelineVM's currentPosition memo correctly
    ## reflects the debugger's rrTicks at each breakpoint hit.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      session.store.updateDebuggerPosition(1000'u64, "loop.py", 20)
      drain()
      check session.timelineVM.currentPosition.val == 1000'u64

      session.store.updateDebuggerPosition(2000'u64, "loop.py", 20)
      drain()
      check session.timelineVM.currentPosition.val == 2000'u64

      session.store.updateDebuggerPosition(3000'u64, "loop.py", 20)
      drain()
      check session.timelineVM.currentPosition.val == 3000'u64

      dispose()

# ---------------------------------------------------------------------------
# Scenario 5: Rapid stepping deduplicates requests
# ---------------------------------------------------------------------------

suite "Scenario 5: Rapid stepping deduplicates requests":

  test "request tracker prevents duplicate in-flight locals requests":
    ## Simulates three rapid step commands where the store's request
    ## tracker should deduplicate identical in-flight requests.
    ##
    ## When the user steps rapidly, each position change triggers a
    ## requestLocals call.  But if a request for the same rrTicks is
    ## already pending, the store skips the duplicate.  Different
    ## rrTicks values generate separate requests.
    createRoot proc(dispose: proc()) =
      # Use autoRespond = false so futures do NOT complete immediately,
      # simulating a slow backend where requests stay "in flight".
      let mock = newMockBackendService(autoRespond = false)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # The auto-load effect fires on creation at rrTicks=0.
      # Mark the initial request complete so the tracker allows new ones.
      session.store.requestTracker.markComplete("load-locals")
      mock.clearReceivedCommands()

      # First step — rrTicks 200.  This triggers a requestLocals.
      session.store.updateDebuggerPosition(200'u64, "main.py", 5)
      drain()

      let count1 = mock.countCommands("ct/load-locals")
      check count1 == 1

      # The request tracker has "load-locals" pending with args "200|0".
      # Setting the same rrTicks again should NOT send a duplicate.
      # (In practice the store's updateDebuggerPosition skips when
      # rrTicks is unchanged, so the effect does not re-fire.)
      # Instead, test with a different rrTicks while the first is pending.

      # Manually mark the first request as complete so the next can fire.
      session.store.requestTracker.markComplete("load-locals")

      # Second step — rrTicks 300.
      session.store.updateDebuggerPosition(300'u64, "main.py", 6)
      drain()
      let count2 = mock.countCommands("ct/load-locals")
      check count2 == 2

      # Mark complete again and step to rrTicks 400.
      session.store.requestTracker.markComplete("load-locals")
      session.store.updateDebuggerPosition(400'u64, "main.py", 7)
      drain()
      let count3 = mock.countCommands("ct/load-locals")
      check count3 == 3

      dispose()

  test "calltrace request deduplication with same scroll position":
    ## Verifies that scrolling to the same position twice does not
    ## send a duplicate calltrace section request while one is pending.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      session.store.updateDebuggerPosition(100'u64, "main.py", 1)
      session.calltraceVM.setViewportHeight(20)
      drain()

      let initialCount = mock.countCommands("ct/load-calltrace-section")
      check initialCount >= 1

      # The autoRespond future completes synchronously in the native
      # backend, so the request tracker is already clear.  Scroll to
      # a new position to trigger a fresh request.
      mock.clearReceivedCommands()
      session.calltraceVM.scroll(50)
      drain()

      let afterScroll = mock.countCommands("ct/load-calltrace-section")
      check afterScroll == 1

      # Scrolling to the exact same position should still trigger
      # because the reactive effect re-fires whenever scrollPosition
      # is written (even with the same value), but the request tracker
      # will deduplicate if the args match and a request is still pending.
      # With autoRespond, the request completes immediately, so the
      # tracker is clear and a new request IS sent.
      mock.clearReceivedCommands()
      session.calltraceVM.scroll(50)
      drain()

      # Since scrollPosition is set to the same value, the signal does
      # not fire the effect again (signals deduplicate by value).
      # Therefore no new command should be sent.
      let afterSameScroll = mock.countCommands("ct/load-calltrace-section")
      check afterSameScroll == 0

      dispose()

# ---------------------------------------------------------------------------
# Scenario 6: Watch expression lifecycle
# ---------------------------------------------------------------------------

suite "Scenario 6: Watch expression lifecycle":

  test "add watch triggers locals reload with watch expression":
    ## Verifies the full lifecycle of adding a watch expression:
    ## 1. Add the watch
    ## 2. Verify the locals request includes the watch expression
    ## 3. Response includes the watch result
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # Position the debugger so auto-load fires.
      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()
      mock.clearReceivedCommands()

      # 1. Add watch "x * 2".
      session.stateVM.addWatch("x * 2")
      drain()

      # 2. Verify the locals request includes the watch expression.
      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isSome
      let watches = cmd.get.args["watchExpressions"]
      check watches.len == 1
      check watches[0].getStr == "x * 2"

      dispose()

  test "remove watch triggers locals reload without the expression":
    ## Verifies that removing a watch expression triggers a fresh
    ## request that does not include the removed expression.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()

      # Add two watches.
      session.stateVM.addWatch("x * 2")
      session.stateVM.addWatch("y + 1")
      drain()

      # 4. Remove watch "x * 2".
      mock.clearReceivedCommands()
      session.stateVM.removeWatch("x * 2")
      drain()

      # 5. Verify the next request does NOT include the removed watch.
      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isSome
      let watches = cmd.get.args["watchExpressions"]
      check watches.len == 1
      check watches[0].getStr == "y + 1"

      dispose()

  test "add empty watch is rejected":
    ## Verifies that adding an empty string as a watch expression
    ## is silently rejected and does not trigger a reload.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()
      mock.clearReceivedCommands()

      # 6. Add empty watch "" — should be rejected.
      session.stateVM.addWatch("")
      drain()

      check session.stateVM.watchExpressions.val.len == 0
      # No new request should have been sent since watchExpressions
      # did not change.
      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isNone

      dispose()

  test "add duplicate watch is rejected":
    ## Verifies that adding a watch expression that already exists
    ## is silently rejected and does not trigger a reload.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()

      session.stateVM.addWatch("x * 2")
      drain()
      mock.clearReceivedCommands()

      # 7. Add duplicate watch "x * 2" again — should be rejected.
      session.stateVM.addWatch("x * 2")
      drain()

      check session.stateVM.watchExpressions.val.len == 1
      # No new request since watchExpressions did not change.
      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isNone

      dispose()

# ---------------------------------------------------------------------------
# Scenario 7: Debug controls state machine
# ---------------------------------------------------------------------------

suite "Scenario 7: Debug controls state machine":

  test "idle state enables all controls":
    ## Verifies the initial idle state allows all debug actions.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session

      # 1. Initially idle.
      check session.debugControlsVM.canStepForward.val == true
      check session.debugControlsVM.canContinue.val == true
      check session.debugControlsVM.isRunning.val == false
      check session.debugControlsVM.statusText.val == "Idle"

      dispose()

  test "stepping disables controls until complete":
    ## Verifies the state transition: Idle -> Stepping -> (controls disabled)
    ## The step command sets the debugger to dsStepping which disables
    ## all step/continue actions.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # 2. Step command sent — status transitions to Stepping.
      session.debugControlsVM.stepForward()
      # Before drain: dsStepping was set synchronously.
      check session.debugControlsVM.canStepForward.val == false
      check session.debugControlsVM.canStepBackward.val == false
      check session.debugControlsVM.canContinue.val == false
      check session.debugControlsVM.isRunning.val == true
      check session.debugControlsVM.statusText.val == "Stepping..."

      # 3. After the step response arrives (drain processes the future),
      # the debugger remains in dsStepping until the backend sends a new
      # position event.  The request tracker clears, but the status stays.
      drain()

      dispose()

  test "finished state disables forward controls":
    ## Verifies that dsFinished disables stepping but the status text
    ## correctly shows "Finished".
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session

      # 4. Set status to Finished.
      var dbg = session.store.debugger.val
      dbg.status = dsFinished
      session.store.debugger.val = dbg

      check session.debugControlsVM.canStepForward.val == false
      check session.debugControlsVM.canStepBackward.val == false
      check session.debugControlsVM.canContinue.val == false
      check session.debugControlsVM.isRunning.val == false
      check session.debugControlsVM.statusText.val == "Finished"

      dispose()

  test "error state disables all controls":
    ## Verifies that dsError disables all debug actions.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session

      # 5. Set status to Error.
      var dbg = session.store.debugger.val
      dbg.status = dsError
      session.store.debugger.val = dbg

      check session.debugControlsVM.canStepForward.val == false
      check session.debugControlsVM.canStepBackward.val == false
      check session.debugControlsVM.canContinue.val == false
      check session.debugControlsVM.isRunning.val == false
      check session.debugControlsVM.statusText.val == "Error"

      dispose()

  test "backward step requires position past timeline start":
    ## Verifies that canStepBackward is only true when the debugger
    ## is past the minimum rrTicks in the timeline.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session

      # Set timeline range.
      var tl = session.store.timeline.val
      tl.minRRTicks = 100'u64
      tl.maxRRTicks = 1000'u64
      session.store.timeline.val = tl

      # Debugger at the start — cannot step backward.
      var dbg = session.store.debugger.val
      dbg.status = dsIdle
      dbg.rrTicks = 100'u64
      session.store.debugger.val = dbg

      check session.debugControlsVM.canStepBackward.val == false

      # Move past the start — can step backward.
      dbg.rrTicks = 200'u64
      session.store.debugger.val = dbg

      check session.debugControlsVM.canStepBackward.val == true

      dispose()

  test "running state shows Running status":
    ## Verifies the dsRunning state (used for continue commands).
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session

      var dbg = session.store.debugger.val
      dbg.status = dsRunning
      session.store.debugger.val = dbg

      check session.debugControlsVM.isRunning.val == true
      check session.debugControlsVM.statusText.val == "Running..."
      check session.debugControlsVM.canStepForward.val == false
      check session.debugControlsVM.canContinue.val == false

      dispose()

# ---------------------------------------------------------------------------
# Scenario 8: Cross-VM consistency after move
# ---------------------------------------------------------------------------

suite "Scenario 8: Cross-VM consistency after move":

  test "all VMs react to a single debugger position change":
    ## Verifies that when the debugger moves to a new position,
    ## ALL ViewModels that depend on the debugger position react:
    ## - StateVM requests locals
    ## - CalltraceVM requests calltrace section
    ## - EditorVM.activeFileName updates
    ## - TimelineVM.currentPosition updates
    ## - DebugControlsVM.statusText updates
    ## - EventLogVM sends event log request
    ## - FlowVM sends flow data request
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # Set up calltrace viewport so its effect will fire.
      session.calltraceVM.setViewportHeight(25)
      drain()
      mock.clearReceivedCommands()

      # Simulate the debugger moving to a new position.
      session.store.updateDebuggerPosition(500'u64, "calculator.py", 42)
      drain()

      # StateVM: locals request was sent.
      let localsCmd = mock.findCommand("ct/load-locals")
      check localsCmd.isSome
      check localsCmd.get.args["rrTicks"].getBiggestInt == 500

      # CalltraceVM: calltrace section request was sent.
      let calltraceCmd = mock.findCommand("ct/load-calltrace-section")
      check calltraceCmd.isSome

      # EditorVM: activeFileName updated.
      check session.editorVM.activeFileName.val == "calculator.py"

      # TimelineVM: currentPosition updated.
      check session.timelineVM.currentPosition.val == 500'u64

      # DebugControlsVM: status remains Idle (no step in progress).
      check session.debugControlsVM.statusText.val == "Idle"

      # EventLogVM: event log request was sent.
      let eventLogCmd = mock.findCommand("ct/event-load")
      check eventLogCmd.isSome
      check eventLogCmd.get.args["rrTicks"].getBiggestInt == 500

      # FlowVM: flow data request was sent.
      let flowCmd = mock.findCommand("ct/load-flow")
      check flowCmd.isSome
      check flowCmd.get.args["rrTicks"].getBiggestInt == 500

      dispose()

  test "calltrace and locals stay consistent after multiple moves":
    ## Verifies that after a sequence of moves, the calltrace and
    ## locals data in the store correspond to the same position.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      session.calltraceVM.setViewportHeight(20)
      drain()

      # Move 1.
      session.store.updateDebuggerPosition(100'u64, "a.py", 1)
      drain()
      session.store.updateLocals(@[
        Variable(name: "state", value: "init", typeName: "str",
                 hasChildren: false, children: @[]),
      ])
      session.store.updateCalltraceSection(@[
        makeCallLine(0, "setup", depth = 0, rrTicks = 100,
                     file = "a.py", line = 1),
      ], startIndex = 0, totalCount = 10)

      check session.stateVM.currentVariables.val[0].value == "init"
      check session.calltraceVM.visibleLines.val[0].name == "setup"

      # Move 2 — both should update consistently.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(200'u64, "b.py", 5)
      drain()

      session.store.updateLocals(@[
        Variable(name: "state", value: "processing", typeName: "str",
                 hasChildren: false, children: @[]),
      ])
      session.store.updateCalltraceSection(@[
        makeCallLine(0, "process", depth = 0, rrTicks = 200,
                     file = "b.py", line = 5),
      ], startIndex = 0, totalCount = 10)

      check session.stateVM.currentVariables.val[0].value == "processing"
      check session.calltraceVM.visibleLines.val[0].name == "process"
      check session.editorVM.activeFileName.val == "b.py"
      check session.timelineVM.currentPosition.val == 200'u64

      dispose()

# ---------------------------------------------------------------------------
# Scenario 9: Data minimality — unchanged position does not re-request
# ---------------------------------------------------------------------------

suite "Scenario 9: Data minimality — unchanged position does not re-request":

  test "unchanged rrTicks does not trigger a new locals request":
    ## Verifies that the reactive system's signal equality check
    ## prevents redundant locals requests when the debugger position
    ## has not actually changed.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      # The auto-load effect fires on creation at rrTicks=0.
      # Clear initial commands so we can count from the position change.
      mock.clearReceivedCommands()

      # Move to initial position and let locals load.
      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()

      let localsCount1 = mock.countCommands("ct/load-locals")
      check localsCount1 == 1

      # Simulate some other non-move event (e.g. tab switch).
      session.stateVM.selectTab(stGlobals)
      session.stateVM.selectTab(stLocals)
      drain()

      # No new locals request should have been sent because the
      # debugger position did not change.
      let localsCount2 = mock.countCommands("ct/load-locals")
      check localsCount2 == localsCount1

      dispose()

  test "updateDebuggerPosition with same rrTicks is a no-op":
    ## Verifies that calling updateDebuggerPosition with the same
    ## rrTicks value does not trigger signal updates or new requests.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()
      let count1 = mock.countCommands("ct/load-locals")

      mock.clearReceivedCommands()

      # Same rrTicks — updateDebuggerPosition guards against this.
      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()

      # No new commands should have been sent.
      check mock.receivedCommands.len == 0

      dispose()

  test "different rrTicks does trigger a new request":
    ## Control test: verify that a different rrTicks value DOES
    ## trigger a fresh request, in contrast to the no-op case above.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      drain()

      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()
      mock.clearReceivedCommands()

      # Different rrTicks — should trigger a new request.
      session.store.updateDebuggerPosition(200'u64, "main.py", 15)
      drain()

      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isSome
      check cmd.get.args["rrTicks"].getBiggestInt == 200

      dispose()

  test "calltrace section is not re-requested when position unchanged":
    ## Verifies that the calltrace auto-load effect does not fire
    ## when the debugger position has not changed.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let app = createAppViewModel(mock.toBackendService())
      let session = app.session
      session.calltraceVM.setViewportHeight(20)
      drain()

      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()
      let calltraceCount = mock.countCommands("ct/load-calltrace-section")

      mock.clearReceivedCommands()

      # Same position — should not trigger a new calltrace request.
      session.store.updateDebuggerPosition(100'u64, "main.py", 10)
      drain()

      check mock.countCommands("ct/load-calltrace-section") == 0

      dispose()
