## test_hsf_sdk_jobs.nim — the jobs an embedding host used to do itself and
## the Embed SDK now does for it: decoding a value off the wire, deciding which
## values a stop changed, and drawing the values recorded on a line.
##
## Each case is the NAMED killer of one arm of
## `run-hsf-sdk-mutations.py`, beside this file. A host that drew its panes
## from the shared store stopped carrying these checks when it stopped
## carrying the code, so they live where the code lives now:
##
##   * an Int's value survives the decoder (a kind read wrongly gives a row
##     with a name, a type and no value — which every row count survives);
##   * the "changed" mark is a fact about the VALUE, not about the selection;
##   * an unchanged value is not marked changed;
##   * a name that was not in scope at the anchor is recorded as ADDED.
##     Every front-end draws an added binding and a modified one alike, with
##     the changed-value style (`value_changes.isModified`); that is the
##     intended design. What this case guards is the distinction the model
##     keeps, so a caller that wants to draw them differently still can;
##   * a recorded string is drawn with its text in the values-on-lines
##     overlay;
##   * a loader that starts following at a stop asks about THAT stop, so the
##     position a session lands on has its locals;
##   * a move keeps the values on screen until its own answer arrives, so the
##     pane is never painted empty at a position that has values;
##   * a click on a call-trace row jumps to that row's own tick, and a click on
##     an event-log row jumps to that event.
##
## WHY A MOCK. As in `test_stop_loader.nim`: `MockBackendService` is the SDK's
## declared test transport (CodeTracer-Embed-SDK.md §3.1), and what is under
## test is what the SDK does with an answer, not what a replay-server sends.
##
## Compile and run, on BOTH backends:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_hsf_sdk_jobs.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_hsf_sdk_jobs.nim

import std/[json, options, tables, unittest]
import isonim/core/[signals, async_compat]
import backend/[backend_service, mock_backend]
import session_vm
import store/[replay_data_store, locals_answer, types]
import viewmodels/[state_vm, flow_vm, value_changes, calltrace_vm, event_log_vm]
import sdk/stop_loader
import ../../../../common/value_presentation/json_adapter

proc vals(pairs: openArray[(string, string)]): Table[string, string] =
  for (k, v) in pairs: result[k] = v

proc moveTo(store: ReplayDataStore; ticks: uint64; line: int) =
  store.updateDebuggerPosition(ticks, "/src/main.py", line)

proc sent(mock: MockBackendService; command: string): int =
  for c in mock.receivedCommands:
    if c.command == command:
      inc result

proc newLoaderSession(mock: MockBackendService): SessionViewModel =
  ## A session built the way `DebuggerSession.markReady` builds it.
  result = createSessionVM(mock.toBackendService())
  result.store.claimLocalsLoading()
  result.initializePanelViewModels()

proc wireInt(text: string): JsonNode =
  %*{"kind": tkInt, "i": text, "typ": {"langType": "int"}}

proc wireString(text: string): JsonNode =
  %*{"kind": tkString, "text": text, "typ": {"langType": "string"}}

proc flowAnswerWith(ticks, line: int; name: string;
                    value: JsonNode): JsonNode =
  ## A `ct/load-flow` answer: one view, one step that recorded `name`.
  %*{"viewUpdates": [{
       "location": {"rrTicks": ticks, "line": line, "path": "/src/main.py",
                    "highLevelPath": "/src/main.py", "key": "k1",
                    "functionFirst": 1, "functionLast": 9},
       "positionStepCounts": {$line: [0]},
       "steps": [{"position": line, "loop": 0, "iteration": 0,
                  "stepCount": 0, "rrTicks": ticks, "exprOrder": [name],
                  "beforeValues": {name: value},
                  "afterValues": {}, "events": []}],
       "loops": [], "branchesTaken": [], "loopIterationSteps": [],
       "relevantStepCount": [line], "commentLines": []}],
     "location": {"rrTicks": ticks, "line": line, "path": "/src/main.py"},
     "error": false, "finished": true}

suite "HSF SDK jobs: a value off the wire":

  test "an Int local is drawn with its value":
    let v = variableFromValue("count", wireInt("42"))
    check v.name == "count"
    check v.value == "42"

suite "HSF SDK jobs: what a stop changed":

  test "an unchanged value is not marked changed":
    var t = initValueTimeline()
    t.observe(1, vals({"x": "1", "y": "1"}))
    t.observe(2, vals({"x": "2", "y": "1"}))
    let d = t.diffAt(2)
    check d.changeFor("y") == vchUnchanged
    check not d.isModified("y")
    check d.isModified("x")

  test "a name new in scope is recorded as added, not modified":
    var t = initValueTimeline()
    t.observe(1, vals({"x": "1"}))
    t.observe(2, vals({"x": "1", "n": "5"}))
    let d = t.diffAt(2)
    check d.changeFor("n") == vchAdded
    # Drawn alike with a modified value, by design.
    check d.isModified("n")

  test "the changed mark follows the value, not the selection":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    var t = initValueTimeline()
    t.observe(1, vals({"x": "1", "y": "1"}))
    t.observe(2, vals({"x": "2", "y": "1"}))
    let vm = session.stateVM
    vm.valueChanges.val = t.diffAt(2)
    vm.selectedPath.val = "y"
    check vm.isChanged("x")
    check not vm.isChanged("y")

suite "HSF SDK jobs: the values recorded on a line":

  test "a recorded string is drawn with its text":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(40, 3)
    mock.clearReceivedCommands()
    mock.expect("ct/load-flow",
                flowAnswerWith(40, 3, "name", wireString("ship")))
    let loader = createStopLoader(session, {spFlow})
    loader.loadStop()
    drainPlatformCallbacks()
    let windows = session.flowVM.layoutWindows.val
    check windows.len == 1
    check windows[0].steps.len == 1
    check windows[0].steps[0].beforeValues.len == 1
    check windows[0].steps[0].beforeValues[0].expression == "name"
    check windows[0].steps[0].beforeValues[0].text == "\"ship\""

suite "HSF SDK jobs: the stop a session lands on":

  test "a loader that starts following at a stop asks about that stop":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(42, 6)
    mock.clearReceivedCommands()
    mock.expect("ct/load-locals", %*{"success": true, "body": {"locals": [
      {"expression": "x", "value": wireInt("7")}]}})
    let loader = createStopLoader(session)
    loader.follow()
    drainPlatformCallbacks()
    check mock.sent("ct/load-locals") == 1
    check loader.status[spLocals].val == plsApplied
    check session.store.locals.locals.val.len == 1

suite "HSF SDK jobs: a move and its answer":

  test "a move keeps the values on screen until its answer arrives":
    let mock = newMockBackendService(autoRespond = true)
    let session = newLoaderSession(mock)
    session.store.moveTo(10, 1)
    mock.expect("ct/load-locals", %*{"success": true, "body": {"locals": [
      {"expression": "x", "value": wireInt("1")}]}})
    let loader = createStopLoader(session, {spLocals})
    loader.loadStop()
    drainPlatformCallbacks()
    check session.store.locals.locals.val.len == 1
    mock.deferResponses = true
    session.store.moveTo(11, 2)
    loader.loadStop()
    check mock.pendingDeferredCount == 1
    check session.store.locals.locals.val.len == 1

suite "HSF SDK jobs: a click on a row goes where the row says":

  test "a call-trace row's click jumps to that row's own tick":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    let vm = createCalltraceVM(store)
    let body = %*{
      "startCallLineIndex": 0,
      "totalCallsCount": 1,
      "callLines": [{
        "depth": 0,
        "content": {"count": 0, "hiddenChildren": false, "call": {
          "rawName": "transfer", "key": "4", "children": [],
          "location": {"path": "/src/token.cairo", "line": 23,
                       "rrTicks": 3426, "callstackDepth": 1}}}}]}
    check store.applyCalltraceResponse(body) == 1
    mock.clearReceivedCommands()
    vm.doubleClickEntry(0)
    let jump = mock.findCommand("ct/calltrace-jump")
    check jump.isSome
    check jump.isSome and jump.get.args["rrTicks"].getInt == 3426

  test "an event-log row's click jumps to that event":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    let vm = createEventLogVM(store)
    vm.appendLiveDebuggerStop(EventLogRow(
      eventId: 512'u64, eventIndex: 0, kindId: 1, kind: "Write",
      file: "token.cairo", line: 91, value: "storage write",
      rrTicks: 512'u64, maxRRTicks: 4096'u64))
    mock.clearReceivedCommands()
    vm.doubleClickRow(0)
    let jump = mock.findCommand("ct/event-jump")
    check jump.isSome
    check jump.isSome and jump.get.args["directLocationRRTicks"].getBiggestInt == 512
