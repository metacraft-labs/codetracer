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

import std/[json, options, sets, strutils, unittest]

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

proc findLast(mock: MockBackendService; command: string): JsonNode =
  ## The arguments of the most recent `command` sent; nil when none was.
  for i in countdown(mock.receivedCommands.high, 0):
    if mock.receivedCommands[i].command == command:
      return mock.receivedCommands[i].args

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
    let loader = createStopLoader(session)       # the default panes
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

proc flowWindowAnswer(ticks: int; line: int): JsonNode =
  ## A `ct/load-flow` answer: one view with one step that ran `line`.
  %*{"viewUpdates": [{
       "location": {"rrTicks": ticks, "line": line, "path": "/src/main.py",
                    "highLevelPath": "/src/main.py", "key": "k1",
                    "functionFirst": 1, "functionLast": 9},
       "positionStepCounts": {$line: [0]},
       "steps": [{"position": line, "loop": 0, "iteration": 0,
                  "stepCount": 0, "rrTicks": ticks, "exprOrder": ["x"],
                  "beforeValues": {"x": {"kind": 0, "i": "1",
                                         "typ": {"langType": "int"}}},
                  "afterValues": {}, "events": []}],
       "loops": [], "branchesTaken": [], "loopIterationSteps": [],
       "relevantStepCount": [line], "commentLines": []}],
     "location": {"rrTicks": ticks, "line": line, "path": "/src/main.py"},
     "error": false, "finished": true}

suite "HSF-D5: the stop loader loads the flow window":

  test "one stop asks for its flow window once, and the window is adopted":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(40, 3)
    mock.clearReceivedCommands()
    mock.expect("ct/load-flow", flowWindowAnswer(40, 3))
    let loader = createStopLoader(session, {spFlow})
    loader.loadStop()
    loader.loadStop()                            # same stop: nothing more
    drainPlatformCallbacks()
    check mock.sent("ct/load-flow") == 1
    let args = mock.findLast("ct/load-flow")
    check args["location"]["rrTicks"].getInt == 40
    check args["location"]["line"].getInt == 3
    check loader.status[spFlow].val == plsApplied
    let windows = session.flowVM.layoutWindows.val
    check windows.len == 1
    check windows[0].rrTicks == 40
    check windows[0].steps[0].beforeValues[0].expression == "x"

  test "a new stop and a new view granularity ask again":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(40, 3)
    let loader = createStopLoader(session, {spFlow})
    loader.loadStop()
    mock.clearReceivedCommands()
    session.store.moveTo(41, 4)
    loader.loadStop()
    check mock.sent("ct/load-flow") == 1
    session.flowVM.setMode(fmLine)
    loader.loadStop()
    check mock.sent("ct/load-flow") == 2

  test "nothing is asked before the debugger has a tick":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    mock.clearReceivedCommands()
    let loader = createStopLoader(session, {spFlow})
    loader.loadStop()
    check mock.sent("ct/load-flow") == 0

  test "a following loader asks on every stop by itself":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    let loader = createStopLoader(session, {spFlow})
    loader.follow()
    mock.clearReceivedCommands()
    session.store.moveTo(5, 1)
    session.store.moveTo(6, 2)
    check mock.sent("ct/load-flow") == 2

  test "the flow window is a default pane":
    check spFlow in DefaultStopPanes

suite "HSF-S1: an answer is applied to the stop it was asked at":

  test "an answer that lands after the debugger moved is dropped":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(10, 1)
    # Deferred from here on, so the oldest outstanding request is the
    # loader's (the other panels' effects answered the move above).
    mock.deferResponses = true
    # The locals alone: the flow window's load is the next case's.
    let loader = createStopLoader(session, {spLocals})
    loader.loadStop()
    check mock.pendingDeferredCount == 1
    session.store.moveTo(11, 2)                  # moved before the answer
    mock.settleDeferred(localsAnswer("stale"))
    drainPlatformCallbacks()
    check loader.status[spLocals].val == plsDropped
    check session.store.locals.locals.val.len == 0

proc watchRows(store: ReplayDataStore): seq[string] =
  ## The watch answers the Variables pane lists after the variables
  ## (`StateVM.currentVariables` reads them from this signal by name): each
  ## watch row as `name=value`.
  for row in store.locals.watches.val:
    result.add row.name & "=" & row.value

proc answeringFromTheRequest(mock: MockBackendService): BackendService =
  ## The mock's transport, except that a `ct/load-locals` is answered FROM ITS
  ## OWN ARGUMENTS, the way the engine answers it
  ## (`db-backend/src/watch_expression.rs`): the stop's one local `x`, plus one
  ## row marked `value.isWatch` for each expression the request named in
  ## `watchExpressions` — and none for an expression it did not name.
  ##
  ## WHY NOT A CANNED ANSWER. Issue #855 is a request that drops the watch
  ## list after a move. A canned answer carrying a watch row would put the
  ## watch back on screen whatever the request asked, which is exactly the
  ## defect such a test could not see. Answering from the request is what
  ## makes "the watch is still shown" mean "the watch was still asked for".
  ## The value is the request's tick, so each answer is also tied to its stop.
  ##
  ## Every request still goes through the mock first, so it is validated
  ## against `VALID_DAP_COMMANDS` and recorded in `receivedCommands`.
  result = mock.toBackendService()
  let inner = result.sendProc
  result.sendProc = proc(command: string;
                         args: JsonNode): BackendFuture[JsonNode] =
    let viaMock = inner(command, args)
    if command != "ct/load-locals":
      return viaMock
    let ticks = $args{"rrTicks"}.getBiggestInt(0)
    var rows = newJArray()
    rows.add %*{"expression": "x", "value": {
      "kind": 7, "i": ticks, "typ": {"kind": 7, "langType": "int"}}}
    for w in args{"watchExpressions"}.getElems:
      rows.add %*{"expression": w.getStr, "value": {
        "kind": 7, "i": ticks, "isWatch": true,
        "typ": {"kind": 7, "langType": "int"}}}
    newCompletedFuture[JsonNode](%*{"success": true, "body": {"locals": rows}})

suite "#855: a watch's result survives a move":
  # Reported (GitHub #855): add a watch, step, and the Watches tab is empty
  # until another watch is added, which brings every watch back. The answer
  # to a move must still carry the user's watches, because the store writes
  # `store.locals.watches` from every answer (`writeLocalsResponse`).

  test "host-driven loader: a watch added and answered is still shown after a move":
    # The terminal's and GPUI's shape: `native_host.loadStopPanes` calls
    # `loadStop` once the stop has settled.
    let mock = newMockBackendService(autoRespond = true)
    let session = createSessionVM(mock.answeringFromTheRequest())
    session.store.claimLocalsLoading()
    session.initializePanelViewModels()
    let loader = createStopLoader(session)
    session.store.moveTo(10, 1)
    loader.loadStop()
    drainPlatformCallbacks()
    check session.store.watchRows().len == 0
    # Added the way the watch input form adds it (`StateVM.addWatch`, which on
    # a session with a collaboration core goes through the shared document
    # and its projection).
    session.stateVM.addWatch("total")
    loader.loadStop()
    drainPlatformCallbacks()
    check session.store.watchRows() == @["total=10"]
    session.store.moveTo(11, 2)
    loader.loadStop()
    drainPlatformCallbacks()
    check loader.status[spLocals].val == plsApplied
    check session.store.locals.locals.val.len == 1
    check session.store.watchRows() == @["total=11"]
    check mock.findLast("ct/load-locals")["watchExpressions"] == %*["total"]

  test "following session: a watch added and answered is still shown after a move":
    # The web renderer's shape: `ui_js` builds a `DebuggerSession` whose stop
    # loader follows the store (`slmFollow`).
    let mock = newMockBackendService(autoRespond = true)
    let s = newDebuggerSession(mock.answeringFromTheRequest())
    s.attach(localFolderTrace("/tmp/trace"))
    s.store.moveTo(20, 1)
    drainPlatformCallbacks()
    s.session.stateVM.addWatch("total")
    drainPlatformCallbacks()
    check s.store.watchRows() == @["total=20"]
    mock.clearReceivedCommands()
    s.store.moveTo(21, 2)
    drainPlatformCallbacks()
    check mock.sent("ct/load-locals") == 1
    check s.store.watchRows() == @["total=21"]
    # A second move, and a move back to the first stop, keep it too.
    s.store.moveTo(22, 3)
    drainPlatformCallbacks()
    check s.store.watchRows() == @["total=22"]
    s.store.moveTo(20, 1)
    drainPlatformCallbacks()
    check s.store.watchRows() == @["total=20"]
    s.dispose()

  test "after the session-load process list, a watch is still shown after a move":
    # Every launch is answered with an unsolicited `ct/listProcesses`, a
    # single-trace one too (`dap_server.rs::dispatch_session_load_event`,
    # over `wrap_single_trace_as_session`), and the renderer hands it to
    # `applyListProcessesResponse` (`ui_js`'s `subscribeListProcesses`). The
    # views, the watch input and the collaboration projection hold the
    # StateVM the session was built with, so that is the one the watch is
    # added to here.
    let mock = newMockBackendService(autoRespond = true)
    let s = newDebuggerSession(mock.answeringFromTheRequest())
    s.attach(localFolderTrace("/tmp/trace"))
    let shown = s.session.stateVM
    check not shown.isNil
    s.session.applyListProcessesResponse(%*{"processes": [{
      "recordingId": "main", "role": "", "displayName": "trace",
      "defaultThreadPrefix": "", "threadCount": 1, "threadIds": [1]}]})
    s.store.moveTo(40, 1)
    drainPlatformCallbacks()
    shown.addWatch("total")
    drainPlatformCallbacks()
    check s.store.watchRows() == @["total=40"]
    s.store.moveTo(41, 2)
    drainPlatformCallbacks()
    check mock.findLast("ct/load-locals")["watchExpressions"] == %*["total"]
    check s.store.watchRows() == @["total=41"]
    s.dispose()

  test "a stop where the watch no longer resolves still clears its old value":
    # The rule `writeLocalsResponse` documents, which a fix for #855 must not
    # undo: an answer that carries no row for a watch is not papered over
    # with the previous stop's value.
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.stateVM.addWatch("total")
    let loader = createStopLoader(session)
    session.store.moveTo(30, 1)
    mock.expect("ct/load-locals", %*{"success": true, "body": {"locals": [
      {"expression": "total", "value": {"kind": 7, "i": "5", "isWatch": true,
                                        "typ": {"kind": 7, "langType": "int"}}}]}})
    loader.loadStop()
    drainPlatformCallbacks()
    check session.store.watchRows() == @["total=5"]
    session.store.moveTo(31, 2)
    mock.expect("ct/load-locals", localsAnswer("x"))
    loader.loadStop()
    drainPlatformCallbacks()
    check loader.status[spLocals].val == plsApplied
    check mock.findLast("ct/load-locals")["watchExpressions"] == %*["total"]
    check session.store.watchRows().len == 0

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

proc cutLocal(name: string; held, total: int): JsonNode =
  ## A `ct/load-locals` answer whose one local is a sequence the budget cut
  ## to its first `held` of `total` elements (`elementsTotal`).
  var elements = newJArray()
  for i in 0 ..< held:
    elements.add %*{"kind": 7, "i": $i, "typ": {"langType": "int"}}
  %*{"success": true, "body": {"locals": [{"expression": name, "value": {
    "kind": 0, "elements": elements, "elementsTotal": total,
    "typ": {"kind": 0, "langType": "seq[int]"}}}]}}

proc elementsAnswer(start, n: int; more: bool): JsonNode =
  var elements = newJArray()
  for i in start ..< start + n:
    elements.add %*{"kind": 7, "i": $i, "typ": {"langType": "int"}}
  %*{"success": true, "body": {"elements": elements, "startIndex": start,
                                "total": 120, "more": more}}

suite "V1 / Load More: the State pane's next elements":

  test "a cut collection says so, and Load More appends the next slice":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(10, 2)
    mock.expect("ct/load-locals", cutLocal("xs", 50, 120))
    let loader = createStopLoader(session)
    loader.loadStop()
    drainPlatformCallbacks()
    let xs = session.store.locals.locals.val[0]
    check xs.moreElements
    check xs.elementsTotal == 120
    check xs.children.len == 50

    mock.clearReceivedCommands()
    mock.expect("ct/load-value-elements", elementsAnswer(50, 50, true))
    session.stateVM.loadMore("xs")
    check "xs" in session.stateVM.loadingMore.val
    session.stateVM.loadMore("xs")             # in flight: not asked twice
    check mock.sent("ct/load-value-elements") == 1
    let args = mock.findCommand("ct/load-value-elements").get.args
    check args["expression"].getStr == "xs"
    check args["startIndex"].getInt == 50
    check args["count"].getInt == LoadMoreCount
    check args["rrTicks"].getInt == 10
    drainPlatformCallbacks()
    let grown = session.store.locals.locals.val[0]
    check grown.children.len == 100
    check grown.children[50].name == "[50]"
    check grown.moreElements
    check "xs" notin session.stateVM.loadingMore.val

    mock.expect("ct/load-value-elements", elementsAnswer(100, 20, false))
    session.stateVM.loadMore("xs")
    drainPlatformCallbacks()
    let whole = session.store.locals.locals.val[0]
    check whole.children.len == 120
    check not whole.moreElements

  test "Load More adds the rows the measured pane shows, plus the lead buffer":
    # Viewport-Driven-Loading V2, "Value children": the count is the expanded
    # node's visible region, never a fixed number; unmeasured, the default.
    check loadMoreCountFor(Viewport()) == LoadMoreCount
    check loadMoreCountFor(Viewport(rows: 12)) == 12 + LeadRows
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(14, 2)
    mock.expect("ct/load-locals", cutLocal("xs", 50, 120))
    let loader = createStopLoader(session)
    loader.loadStop()
    drainPlatformCallbacks()
    session.stateVM.setViewport(Viewport(rows: 12))
    mock.clearReceivedCommands()
    mock.expect("ct/load-value-elements", elementsAnswer(50, 32, true))
    session.stateVM.loadMore("xs")
    let args = mock.findCommand("ct/load-value-elements").get.args
    check args["startIndex"].getInt == 50
    check args["count"].getInt == 12 + LeadRows

  test "a row with nothing more asks nothing":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(11, 2)
    mock.expect("ct/load-locals", localsAnswer("x"))
    let loader = createStopLoader(session)
    loader.loadStop()
    drainPlatformCallbacks()
    mock.clearReceivedCommands()
    session.stateVM.loadMore("x")
    session.stateVM.loadMore("nope")
    check mock.sent("ct/load-value-elements") == 0

  test "an answer about a stop the debugger has left is dropped":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(12, 2)
    mock.expect("ct/load-locals", cutLocal("xs", 50, 120))
    let loader = createStopLoader(session)
    loader.loadStop()
    drainPlatformCallbacks()
    mock.expect("ct/load-value-elements", elementsAnswer(50, 50, true))
    session.stateVM.loadMore("xs")
    session.store.moveTo(13, 3)                # moved before the answer
    drainPlatformCallbacks()
    check session.stateVM.loadingMore.val.len == 0
    if session.store.locals.locals.val.len > 0 and
       session.store.locals.locals.val[0].name == "xs":
      check session.store.locals.locals.val[0].children.len <= 50
