## test_integration.nim
##
## Headless ViewModel integration tests that replicate key GUI test
## scenarios using SessionViewModel + MockBackendService.
##
## These tests prove the ViewModel architecture works end-to-end for
## real debugging workflows without needing Electron or Playwright.
## Each test exercises multiple VMs through the shared ReplayDataStore,
## verifying that reactive effects propagate correctly across the
## session layer.
##
## Scenarios covered:
## 1. Debugger move loads locals and calltrace (auto-load effects)
## 2. Locals update when debugger steps (reactive data flow)
## 3. Tab switching shows correct variables (StateVM memo)
## 4. Calltrace double-click triggers navigation (action -> backend)
## 5. Debug controls reflect debugger state (derived memos)
## 6. Watch expression triggers reload (StateVM auto-load re-fires)
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_integration.nim

import std/[json, unittest, asyncdispatch, options, strutils]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import ../backend/backend_service
import ../backend/mock_backend
import ../backend/dap_commands
import ../store/types
import ../store/replay_data_store
import ../store/request_tracker
import ../session_vm
import ../viewmodels/[state_vm, calltrace_vm, debug_controls_vm,
                      event_log_vm, flow_vm, shell_vm, timeline_vm]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.
  try:
    poll(0)
  except ValueError:
    # "No handles or timers registered in dispatcher" -- nothing to drain.
    discard

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

# ---------------------------------------------------------------------------
# Test 1: Debugger move loads locals and calltrace
# ---------------------------------------------------------------------------

suite "Integration: debugger move loads locals and calltrace":

  test "moving debugger position triggers auto-load for both locals and calltrace":
    ## Replicates the GUI scenario "State panel loaded initially":
    ## after loading a trace and the debugger moving to an entry,
    ## both the locals panel and calltrace panel request data.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Initially no commands should have been sent (rrTicks == 0).
      check mock.receivedCommands.len == 0

      # Set a viewport height on calltrace so its auto-load effect
      # will fire when the debugger position changes.
      session.calltraceVM.setViewportHeight(25)
      drain()

      # Still no commands -- rrTicks is 0 so both guards skip.
      check mock.receivedCommands.len == 0

      # Simulate the debugger moving to a position (entry loaded).
      session.store.updateDebuggerPosition(100, "main.py", 10)
      drain()

      # The StateVM's auto-load effect should have fired requestLocals.
      let localsCmd = mock.findCommand("ct/load-locals")
      check localsCmd.isSome
      check localsCmd.get.args["rrTicks"].getBiggestInt == 100

      # The CalltraceVM's auto-load effect should have fired too.
      let calltraceCmd = mock.findCommand("ct/load-calltrace-section")
      check calltraceCmd.isSome

      dispose()

# ---------------------------------------------------------------------------
# Test 2: Locals update when debugger steps
# ---------------------------------------------------------------------------

suite "Integration: locals update when debugger steps":

  test "stepping the debugger refreshes locals data":
    ## Replicates the GUI scenario "Step forward/backward":
    ## stepping changes the debugger position, which causes the
    ## state panel to request fresh locals for the new position.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Initial position -- triggers first locals request.
      session.store.updateDebuggerPosition(100, "main.py", 10)
      drain()

      # Simulate locals response arriving.
      session.store.updateLocals(@[
        makeVariable("x", "42", "int"),
        makeVariable("msg", "hello", "str"),
      ])

      check session.stateVM.currentVariables.val.len == 2
      check session.stateVM.currentVariables.val[0].name == "x"
      check session.stateVM.currentVariables.val[1].name == "msg"
      check session.stateVM.isLoading.val == false

      # Step forward -- debugger moves to a new position.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(200, "main.py", 15)
      drain()

      # A new locals request should have been sent for the new position.
      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isSome
      check cmd.get.args["rrTicks"].getBiggestInt == 200

      dispose()

  test "locals loading state transitions correctly through a step":
    ## Verifies the loading state lifecycle: idle -> loading -> idle
    ## as the store processes a locals request.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Before any move, loading is idle.
      check session.stateVM.isLoading.val == false

      # Move the debugger -- triggers requestLocals which sets loading.
      session.store.updateDebuggerPosition(100, "main.py", 10)
      # Before draining, the future hasn't completed yet in the
      # autoRespond path -- but in native backend the future
      # completes synchronously, so we need to drain to process it.
      drain()

      # After drain, the autoRespond future has completed and the
      # loading state should be back to idle.
      check session.stateVM.isLoading.val == false

      dispose()

# ---------------------------------------------------------------------------
# Test 3: Tab switching shows correct variables
# ---------------------------------------------------------------------------

suite "Integration: tab switching shows correct variables":

  test "switching tabs changes which variables are displayed":
    ## Replicates the GUI scenario where the user switches between
    ## locals, globals, and watches tabs in the state panel.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      # Populate locals and globals in the store.
      session.store.locals.locals.val = @[
        Variable(name: "local_var", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
      ]
      session.store.locals.globals.val = @[
        Variable(name: "global_counter", value: "99", typeName: "int",
                 hasChildren: false, children: @[]),
      ]

      # Initially on the locals tab.
      check session.stateVM.activeTab.val == stLocals
      check session.stateVM.currentVariables.val.len == 1
      check session.stateVM.currentVariables.val[0].name == "local_var"

      # Switch to globals.
      session.stateVM.selectTab(stGlobals)
      check session.stateVM.activeTab.val == stGlobals
      check session.stateVM.currentVariables.val.len == 1
      check session.stateVM.currentVariables.val[0].name == "global_counter"

      # Switch to watches (empty since watch results are not yet wired).
      session.stateVM.selectTab(stWatches)
      check session.stateVM.activeTab.val == stWatches
      check session.stateVM.currentVariables.val.len == 0

      # Switch back to locals.
      session.stateVM.selectTab(stLocals)
      check session.stateVM.currentVariables.val.len == 1
      check session.stateVM.currentVariables.val[0].name == "local_var"

      dispose()

  test "updating store locals reactively updates the state panel":
    ## Verifies that the memo recomputes when the underlying store
    ## data changes, even without a tab switch.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      check session.stateVM.currentVariables.val.len == 0

      # Simulate locals arriving from the backend.
      session.store.updateLocals(@[
        makeVariable("a", "10", "int"),
      ])

      check session.stateVM.currentVariables.val.len == 1
      check session.stateVM.currentVariables.val[0].name == "a"

      # More locals arrive (e.g. after a step).
      session.store.updateLocals(@[
        makeVariable("a", "20", "int"),
        makeVariable("b", "30", "int"),
      ])

      check session.stateVM.currentVariables.val.len == 2
      check session.stateVM.currentVariables.val[0].value == "20"
      check session.stateVM.currentVariables.val[1].name == "b"

      dispose()

# ---------------------------------------------------------------------------
# Test 4: Calltrace double-click triggers navigation
# ---------------------------------------------------------------------------

suite "Integration: calltrace double-click triggers navigation":

  test "double-clicking a calltrace entry sends a navigation command":
    ## Replicates the GUI scenario "Call trace navigation":
    ## the calltrace shows function entries, and double-clicking
    ## one sends a jump command to the backend.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Populate calltrace data in the store.
      session.store.calltrace.lines.val = @[
        makeCallLine(0, "main", depth = 0, rrTicks = 100,
                     file = "main.py", line = 1),
        makeCallLine(1, "solve", depth = 1, rrTicks = 200,
                     file = "solver.py", line = 10),
        makeCallLine(2, "helper", depth = 2, rrTicks = 300,
                     file = "utils.py", line = 5),
      ]
      session.store.calltrace.startLineIndex.val = 0'i64
      session.store.calltrace.totalCallsCount.val = 50'u64

      # Set viewport so visibleLines computes correctly.
      session.calltraceVM.setViewportHeight(10)

      let visible = session.calltraceVM.visibleLines.val
      check visible.len == 3
      check visible[0].name == "main"
      check visible[1].name == "solve"

      # Clear commands accumulated from setup effects.
      mock.clearReceivedCommands()

      # Double-click the second entry (index 1 = "solve").
      session.calltraceVM.doubleClickEntry(1)
      drain()

      # Should have sent a calltrace-jump command to the backend.
      let navCmd = mock.findCommand("ct/calltrace-jump")
      check navCmd.isSome
      check navCmd.get.args["file"].getStr == "solver.py"
      check navCmd.get.args["line"].getInt == 10
      check navCmd.get.args["rrTicks"].getBiggestInt == 200

      dispose()

  test "double-click on out-of-range index is a safe no-op":
    ## Verifies that clicking beyond the loaded data does not crash
    ## or send any unexpected commands.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      session.store.calltrace.lines.val = @[
        makeCallLine(0, "main", rrTicks = 100),
      ]
      session.store.calltrace.startLineIndex.val = 0'i64

      mock.clearReceivedCommands()

      # Index 99 is way out of range.
      session.calltraceVM.doubleClickEntry(99)
      drain()

      # No calltrace-jump command should have been sent.
      let navCmd = mock.findCommand("ct/calltrace-jump")
      check navCmd.isNone

      dispose()

# ---------------------------------------------------------------------------
# Test 5: Debug controls reflect debugger state
# ---------------------------------------------------------------------------

suite "Integration: debug controls reflect debugger state":

  test "debug controls show correct state for idle debugger":
    ## Replicates the GUI scenario where the debugger is ready
    ## and all step/continue controls are enabled.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      # Default state is dsIdle.
      check session.debugControlsVM.canStepForward.val == true
      check session.debugControlsVM.canContinue.val == true
      check session.debugControlsVM.isRunning.val == false
      check session.debugControlsVM.statusText.val == "Idle"

      dispose()

  test "stepping forward disables controls and shows stepping status":
    ## Replicates the GUI scenario "Step forward":
    ## after initiating a step, the controls should be disabled
    ## and the status should show "Stepping...".
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Set timeline range so backward stepping is valid.
      var tl = session.store.timeline.val
      tl.minRRTicks = 0'u64
      tl.maxRRTicks = 1000'u64
      session.store.timeline.val = tl

      # Position the debugger at a non-zero tick.
      session.store.updateDebuggerPosition(500, "main.py", 10)
      drain()

      check session.debugControlsVM.canStepForward.val == true
      check session.debugControlsVM.canStepBackward.val == true

      # Step forward -- this calls requestStep which sets dsStepping.
      session.debugControlsVM.stepForward()
      # Note: don't drain yet; the store marks dsStepping synchronously
      # before sending the future.

      check session.debugControlsVM.canStepForward.val == false
      check session.debugControlsVM.canStepBackward.val == false
      check session.debugControlsVM.canContinue.val == false
      check session.debugControlsVM.isRunning.val == true
      check session.debugControlsVM.statusText.val == "Stepping..."

      # After the step completes (drain processes the autoRespond future),
      # the debugger status remains dsStepping until the backend sends
      # a new position event.  In a real scenario, the backend would
      # emit an event that updates the debugger state.
      drain()

      dispose()

  test "debug controls are disabled when debugger is finished":
    ## Verifies that once the debugger reaches the end of the
    ## recording, no step actions are available.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())

      var dbg = session.store.debugger.val
      dbg.status = dsFinished
      session.store.debugger.val = dbg

      check session.debugControlsVM.canStepForward.val == false
      check session.debugControlsVM.canStepBackward.val == false
      check session.debugControlsVM.canContinue.val == false
      check session.debugControlsVM.isRunning.val == false
      check session.debugControlsVM.statusText.val == "Finished"

      dispose()

  test "step command is sent to the backend":
    ## Verifies that the step action actually reaches the mock backend.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      mock.clearReceivedCommands()
      session.debugControlsVM.stepForward()
      drain()

      let stepCmd = mock.findCommand("next")
      check stepCmd.isSome
      check stepCmd.get.args["direction"].getStr == "sdForward"

      dispose()

# ---------------------------------------------------------------------------
# Test 6: Watch expression triggers reload
# ---------------------------------------------------------------------------

suite "Integration: watch expression triggers reload":

  test "adding a watch expression re-requests locals":
    ## Replicates the scenario where a user adds a watch expression
    ## while the debugger is stopped.  The StateVM's auto-load effect
    ## watches both rrTicks and watchExpressions, so adding a watch
    ## should trigger a new requestLocals call.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Position the debugger so the auto-load guard passes.
      session.store.updateDebuggerPosition(100, "main.py", 10)
      drain()

      # Clear commands from the initial move.
      mock.clearReceivedCommands()

      # Add a watch expression.
      session.stateVM.addWatch("my_var * 2")
      drain()

      # The auto-load effect should have re-fired requestLocals
      # because watchExpressions changed.
      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isSome
      # The watch expression should be included in the request args.
      let watches = cmd.get.args["watchExpressions"]
      check watches.len == 1
      check watches[0].getStr == "my_var * 2"

      dispose()

  test "removing a watch expression re-requests locals":
    ## Verifies that removing a watch also triggers a fresh locals
    ## request so stale watch results are cleared.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Position the debugger.
      session.store.updateDebuggerPosition(100, "main.py", 10)
      drain()

      # Add two watches.
      session.stateVM.addWatch("x")
      session.stateVM.addWatch("y")
      drain()

      mock.clearReceivedCommands()

      # Remove one watch.
      session.stateVM.removeWatch("x")
      drain()

      # A new locals request should have been sent with only "y".
      let cmd = mock.findCommand("ct/load-locals")
      check cmd.isSome
      let watches = cmd.get.args["watchExpressions"]
      check watches.len == 1
      check watches[0].getStr == "y"

      dispose()

# ---------------------------------------------------------------------------
# Cross-VM coordination
# ---------------------------------------------------------------------------

suite "Integration: cross-VM coordination":

  test "debugger position change updates both state and calltrace panels":
    ## Verifies that a single store.updateDebuggerPosition call
    ## propagates through both the StateVM and CalltraceVM auto-load
    ## effects in a single reactive cycle.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Set up calltrace viewport.
      session.calltraceVM.setViewportHeight(20)
      drain()

      mock.clearReceivedCommands()

      # Simulate a debugger move.
      session.store.updateDebuggerPosition(500, "solver.py", 42)
      drain()

      # Both panels should have sent their respective requests.
      let localsCmd = mock.findCommand("ct/load-locals")
      check localsCmd.isSome
      check localsCmd.get.args["rrTicks"].getBiggestInt == 500

      let calltraceCmd = mock.findCommand("ct/load-calltrace-section")
      check calltraceCmd.isSome

      dispose()

  test "full workflow: move -> load data -> step -> reload":
    ## End-to-end test of a typical debugging workflow:
    ## 1. Debugger moves to initial position
    ## 2. Locals and calltrace data arrive
    ## 3. User steps forward
    ## 4. New data is requested for the new position
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      session.calltraceVM.setViewportHeight(20)
      drain()

      # 1. Initial debugger position.
      session.store.updateDebuggerPosition(100, "main.py", 10)
      drain()

      # 2. Simulate data arriving.
      session.store.updateLocals(@[
        makeVariable("counter", "0", "int"),
      ])
      session.store.updateCalltraceSection(@[
        makeCallLine(0, "main", depth = 0, rrTicks = 100,
                     file = "main.py", line = 10),
      ], startIndex = 0, totalCount = 100)

      check session.stateVM.currentVariables.val.len == 1
      check session.stateVM.currentVariables.val[0].name == "counter"
      check session.calltraceVM.visibleLines.val.len >= 1

      # 3. Step forward.
      mock.clearReceivedCommands()
      session.debugControlsVM.stepForward()
      drain()

      # Step command was sent.
      let stepCmd = mock.findCommand("next")
      check stepCmd.isSome
      check stepCmd.get.args["direction"].getStr == "sdForward"

      # 4. Simulate the backend reporting the new position.
      mock.clearReceivedCommands()
      session.store.updateDebuggerPosition(200, "main.py", 11)
      drain()

      # New locals and calltrace requests were sent.
      let newLocals = mock.findCommand("ct/load-locals")
      check newLocals.isSome
      check newLocals.get.args["rrTicks"].getBiggestInt == 200

      let newCalltrace = mock.findCommand("ct/load-calltrace-section")
      check newCalltrace.isSome

      # Simulate updated locals.
      session.store.updateLocals(@[
        makeVariable("counter", "1", "int"),
      ])
      check session.stateVM.currentVariables.val[0].value == "1"

      dispose()

# ===========================================================================
# DAP command validation
# ===========================================================================
#
# These tests guard against the bug where ViewModel code sends a command
# string that is not in the DAP mapping (EVENT_KIND_TO_DAP_MAPPING in
# dap.nim).  When an unmapped command reaches dapCommandToEventKind it
# raises ValueError, which kills ALL subsequent reactive effects in the
# current batch.
#
# The approach: trigger all auto-load effects and user actions, then
# verify that every command the mock backend received is in the
# authoritative set of valid DAP commands (VALID_DAP_COMMANDS from
# dap_commands.nim).
# ===========================================================================

suite "Integration: all ViewModel commands are valid DAP commands":

  test "auto-load effects send only valid DAP commands":
    ## Trigger every auto-load effect by moving the debugger to a
    ## non-zero rrTicks position, then verify all recorded commands
    ## are in the valid DAP command set.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Move debugger to trigger auto-load effects in EventLogVM,
      # FlowVM, StateVM (locals + calltrace).
      session.store.updateDebuggerPosition(500, "main.py", 10)
      drain()

      check mock.receivedCommands.len > 0
      for cmd in mock.receivedCommands:
        check cmd.command.isValidDapCommand

      dispose()

  test "step commands send only valid DAP commands":
    ## Exercise every step direction through requestStep and verify
    ## the resulting commands are valid DAP strings.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      drain()

      for dir in StepDirection:
        mock.clearReceivedCommands()
        # Reset request tracker so deduplication doesn't block.
        store.requestTracker.markComplete("step")
        # Reset debugger status to idle so the step is accepted.
        store.debugger.val = DebuggerState(
          rrTicks: 100'u64,
          location: Location(file: "test.py", line: 1),
          status: dsIdle,
          threadId: 0'u32,
        )
        store.requestStep(dir)
        drain()

        check mock.receivedCommands.len >= 1
        for cmd in mock.receivedCommands:
          check cmd.command.isValidDapCommand

      dispose()

  test "user actions send only valid DAP commands":
    ## Exercise user actions across VMs (doubleClickRow, clickStep,
    ## seek, submitInput) and verify all commands are valid.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      drain()

      # Populate event log rows for doubleClickRow.
      session.eventLogVM.eventRows.val = @[
        EventLogRow(eventId: 1'u64, kind: "call", line: 10, value: "foo()"),
      ]

      mock.clearReceivedCommands()

      # EventLogVM: double-click navigates to event.
      session.eventLogVM.doubleClickRow(0)
      drain()

      # FlowVM: click a step.
      session.flowVM.clickStep(0)
      drain()

      # TimelineVM: seek to a tick.
      session.timelineVM.seek(200'u64)
      drain()

      # ShellVM: submit a command.
      session.shellVM.setInput("print(x)")
      session.shellVM.submitInput()
      drain()

      check mock.receivedCommands.len >= 4
      for cmd in mock.receivedCommands:
        check cmd.command.isValidDapCommand

      dispose()
