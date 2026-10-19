## test_stop_loader.nim
##
## HSF-S1 Tier-1: the SDK's stop loader (`sdk/stop_loader.nim`) — what is
## loaded when the debugger stops, decided once, for every front-end.
##
## Properties:
##   * one stop issues each OPEN pane's load once, and a closed pane's never;
##   * the answer is decoded and applied by the shared decoder, on both the
##     whole-response (stdio, worker, mock) and the body-only (`DapApi`)
##     envelope;
##   * an answer that lands after the debugger moved is dropped (PLAT-29);
##   * a failed load is retried at the same stop, a successful one is not;
##   * a `DebuggerSession` in `slmFollow` loads by itself, one in
##     `slmHostDriven` only when asked, and in both `StateVM`'s own
##     `ct/load-locals` stands down, so a stop sends exactly one.
##
## WHY A MOCK. `MockBackendService` is the SDK's declared test transport
## (CodeTracer-Embed-SDK.md §3.1); what is under test is which requests the
## loader sends and what it does with the answers, which a real replay-server
## would answer with data this suite would then have to reproduce. The real
## backend's side is covered by the terminal suites that drive
## `native_host.loadStopPanes` against `replay-server`
## (`tui/tests/test_plat29_inline_values.nim`, `test_plat47_call_trace.nim`).
## `deferResponses` gives the worker-shaped asynchronous answers the PLAT-29
## case needs.
##
## Compile and run, on BOTH backends:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_stop_loader.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_stop_loader.nim

import std/[json, options, strutils, unittest]

import isonim/core/[signals, async_compat]

import backend/[backend_service, mock_backend]
import session_vm
import store/[replay_data_store, types]
import viewmodels/[state_vm, calltrace_vm, flow_vm]
import sdk/[debugger_session, stop_loader, trace_source]

proc localsAnswer(names: varargs[string]): JsonNode =
  ## A whole `ct/load-locals` response carrying an int local per name.
  var locals = newJArray()
  for n in names:
    locals.add %*{"expression": n,
                  "value": {"kind": 0, "i": "1", "typ": {"langType": "int"}}}
  %*{"success": true, "body": {"locals": locals}}

proc moveTo(store: ReplayDataStore; ticks: uint64; line: int) =
  store.updateDebuggerPosition(ticks, "/src/main.py", line)

proc sent(mock: MockBackendService; command: string): int =
  for c in mock.receivedCommands:
    if c.command == command:
      inc result

proc newLoaderSession(mock: MockBackendService): SessionViewModel =
  ## A session built the way `DebuggerSession.markReady` builds it: the
  ## locals claimed before the panels exist.
  result = createSessionVM(mock.toBackendService())
  result.store.claimLocalsLoading()
  result.initializePanelViewModels()

suite "HSF-S1: the stop loader issues each open pane's load once per stop":

  test "one stop issues the locals once; a closed pane's load is not issued":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(100, 3)
    mock.clearReceivedCommands()
    mock.expect("ct/load-locals", localsAnswer("x", "y"))
    let loader = createStopLoader(session)       # spLocals only
    loader.loadStop()
    loader.loadStop()                            # same stop: nothing more
    drainPlatformCallbacks()
    check mock.sent("ct/load-locals") == 1
    check mock.sent("stackTrace") == 0           # closed pane
    check loader.status[spLocals].val == plsApplied
    check session.store.locals.locals.val.len == 2
    check session.store.locals.loadedForRRTicks.val == 100

  test "the request carries the GUI's budgets and the state pane's watches":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.stateVM.watchExpressions.val = @["total"]
    session.store.moveTo(7, 1)
    mock.clearReceivedCommands()
    let loader = createStopLoader(session)
    loader.loadStop()
    let args = mock.findCommand("ct/load-locals").get.args
    check args["countBudget"].getInt == LocalsCountBudget
    check args["minCountLimit"].getInt == LocalsMinCountLimit
    check args["depthLimit"].getInt == LocalsDepthLimit
    check args["rrTicks"].getInt == 7
    check args["watchExpressions"] == %*["total"]

  test "a new stop, and a new watch list at the same stop, load again":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(1, 1)
    let loader = createStopLoader(session)
    loader.loadStop()
    session.store.moveTo(2, 2)
    loader.loadStop()
    session.stateVM.watchExpressions.val = @["n"]
    loader.loadStop()
    check mock.sent("ct/load-locals") == 3

  test "a failed load is retried at the same stop":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(5, 1)
    mock.expect("ct/load-locals", %*{"success": false, "message": "busy"})
    let loader = createStopLoader(session)
    loader.loadStop()
    drainPlatformCallbacks()
    check loader.status[spLocals].val == plsFailed
    mock.expect("ct/load-locals", localsAnswer("x"))
    loader.loadStop()
    drainPlatformCallbacks()
    check loader.status[spLocals].val == plsApplied
    check mock.sent("ct/load-locals") == 2

  test "a body-only answer (the DapApi transport) is decoded the same":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(9, 4)
    mock.expect("ct/load-locals", localsAnswer("a", "b", "c")["body"])
    let loader = createStopLoader(session)
    loader.loadStop()
    drainPlatformCallbacks()
    check session.store.locals.locals.val.len == 3

suite "HSF-S1: an answer is applied to the stop it was asked at":

  test "an answer that lands after the debugger moved is dropped":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(10, 1)
    # Deferred from here on, so the oldest outstanding request is the
    # loader's (the other panels' effects answered the move above).
    mock.deferResponses = true
    let loader = createStopLoader(session)
    loader.loadStop()
    check mock.pendingDeferredCount == 1
    session.store.moveTo(11, 2)                  # moved before the answer
    mock.settleDeferred(localsAnswer("stale"))
    drainPlatformCallbacks()
    check loader.status[spLocals].val == plsDropped
    check session.store.locals.locals.val.len == 0

suite "HSF-S1: the call-stack fallback (PLAT-47)":

  test "asked only when the recording has no call trace":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(3, 1)
    mock.expect("stackTrace", %*{"success": true, "body": {"stackFrames": [
      {"name": "evaluate"}, {"name": "main"}]}})
    let loader = createStopLoader(session, {spCallStackFallback})
    loader.loadStop()
    drainPlatformCallbacks()
    check mock.sent("stackTrace") == 1
    check session.calltraceVM.fallbackStack.val == @["evaluate", "main"]
    # A call trace arrives at the same stop: the fallback is cleared, with no
    # second request.
    session.store.updateCalltraceSection(
      @[makeCallLine("main", 0, 3'u64)], 0'i64, 1'u64)
    loader.loadStop()
    drainPlatformCallbacks()
    check mock.sent("stackTrace") == 1
    check session.calltraceVM.fallbackStack.val.len == 0

suite "HSF-S1: DebuggerSession runs the stop loader":

  test "slmFollow: one stop sends exactly one ct/load-locals, by itself":
    let mock = newMockBackendService(autoRespond = true)
    let s = newDebuggerSession(mock.toBackendService())
    s.attach(localFolderTrace("/tmp/trace"))
    mock.clearReceivedCommands()
    s.store.moveTo(42, 6)
    drainPlatformCallbacks()
    check mock.sent("ct/load-locals") == 1
    s.store.moveTo(43, 7)
    drainPlatformCallbacks()
    check mock.sent("ct/load-locals") == 2
    s.dispose()

  test "slmHostDriven: nothing is sent until the host asks":
    let mock = newMockBackendService(autoRespond = true)
    let s = newDebuggerSession(mock.toBackendService(),
                               stopLoading = slmHostDriven)
    s.attach(localFolderTrace("/tmp/trace"))
    mock.clearReceivedCommands()
    s.store.moveTo(42, 6)
    drainPlatformCallbacks()
    check mock.sent("ct/load-locals") == 0
    s.stops.loadStop()
    drainPlatformCallbacks()
    check mock.sent("ct/load-locals") == 1
    s.dispose()

  test "a disposed session's loader stops following":
    let mock = newMockBackendService(autoRespond = true)
    let s = newDebuggerSession(mock.toBackendService())
    s.attach(localFolderTrace("/tmp/trace"))
    let store = s.store
    s.dispose()
    mock.clearReceivedCommands()
    store.moveTo(50, 1)
    drainPlatformCallbacks()
    check mock.sent("ct/load-locals") == 0

proc flowUpdate(mode: string; line: int): JsonNode =
  ## A `ct/updated-flow` payload with one step at `line`, naming the query it
  ## answers as the engine does (`FlowUpdate.mode`).
  %*{"mode": mode, "error": false, "finished": true,
     "location": {"path": "/src/main.py", "line": line, "rrTicks": 1},
     "viewUpdates": [{
       "location": {"path": "/src/main.py", "line": line},
       "loops": [],
       "steps": [{"position": line, "stepCount": 1, "exprOrder": ["x"],
                  "beforeValues": {},
                  "afterValues": {"x": {"kind": 0, "i": "1",
                                        "typ": {"langType": "int"}}}}]}]}

proc diffRequests(mock: MockBackendService): int =
  for c in mock.receivedCommands:
    if c.command == "ct/load-flow" and c.args{"flowMode"}.getStr("") == "diff":
      inc result

suite "HSF-D4: the trace diff's flow":

  test "a diff session asks for the diff flow once, whatever the stops":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.flowVM.diffSession.val = true
    let loader = createStopLoader(session)
    # `FlowVM`'s own call-flow effect sends `ct/load-flow` on every move too,
    # and the mock answers by command, in order: queue a diff answer for each
    # request either sender can make. A diff answer to the call request is
    # routed to the diff signals by its `mode`, so it cannot fake the count.
    for _ in 1 .. 8:
      mock.expect("ct/load-flow", %*{"success": true,
                                      "body": flowUpdate("diff", 4)})
    for i in 1 .. 3:
      session.store.moveTo(uint64(i), i)
      loader.loadStop()
      drainPlatformCallbacks()
    check mock.diffRequests() == 1
    check loader.status[spDiffFlow].val == plsApplied
    check session.flowVM.diffSteps.val.len == 1
    check session.flowVM.diffLoadingState.val == lsIdle

  test "a session without a diff never asks for one":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    let loader = createStopLoader(session)
    for i in 1 .. 3:
      session.store.moveTo(uint64(i), i)
      loader.loadStop()
    drainPlatformCallbacks()
    check mock.diffRequests() == 0
    check loader.status[spDiffFlow].val == plsNone

  test "a following loader asks when the host marks the session a diff":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(3, 3)
    let loader = createStopLoader(session)
    loader.follow()
    drainPlatformCallbacks()
    check mock.diffRequests() == 0
    session.flowVM.diffSession.val = true
    drainPlatformCallbacks()
    check mock.diffRequests() == 1

  test "a diff answer on the event never replaces the call window":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    let flow = session.flowVM
    mock.emitEvent(%*{"kind": UpdatedFlowCommandName,
                      "data": flowUpdate("call", 7)})
    check flow.steps.val.len == 1
    let callWindow = flow.steps.val
    mock.emitEvent(%*{"kind": UpdatedFlowCommandName,
                      "data": flowUpdate("diff", 12)})
    check flow.steps.val == callWindow
    check flow.diffSteps.val.len == 1
    check flow.diffSteps.val[0].location.endsWith(":12")

  test "an update without a mode (an older engine) is a call flow":
    check not isDiffFlowUpdate(%*{"viewUpdates": []})
    check isDiffFlowUpdate(%*{"mode": "diff"})
    check not isDiffFlowUpdate(%*{"mode": "call"})

suite "BackendService response envelopes":

  test "whole responses and bare bodies read the same":
    check responseSucceeded(%*{"success": true, "body": {"a": 1}})
    check not responseSucceeded(%*{"success": false, "message": "no"})
    check responseSucceeded(%*{"a": 1})
    check not responseSucceeded(newJNull())
    check responseBody(%*{"success": true, "body": {"a": 1}}) == %*{"a": 1}
    check responseBody(%*{"a": 1}) == %*{"a": 1}
    check responseBody(%*{"success": true}) == newJObject()
    check responseBody(newJNull()) == newJObject()
