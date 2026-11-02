## test_flow_window_model.nim
##
## `FlowVM` holds the flow window every surface draws from (Shared-DOM-Front-
## Ends D7.4 (b)): the desktop's inline flow, the terminal's and GPUI's
## overlays, the VS Code host. This suite decodes a real captured window
## (`fixtures/flow/zk_shields_flow_window.json`, `noir_space_ship`'s
## `iterate_asteroids`, verbatim from the engine) and checks that the decoded
## model carries what the desktop's `ui/flow.nim` used to read off the wire
## itself: each value's recorded tree and its flow-budget text, the step's
## `return` value and events, the loops with their pass counts and per-pass
## tables, the line → steps index, the branch tables and the line facts, and
## which call and tick the window is of — for every view of the window.
##
## It also pins that the readers which existed before (the inline values the
## terminal and GPUI draw, `flow_line_values`) see exactly what they saw: the
## `return` pseudo-expression is carried beside the variables, not among them.
##
## The backend is a `MockBackendService` only so a `FlowVM` can be built; the
## windows are applied directly, as the `ct/updated-flow` handler applies them.

import std/[json, os, strutils, tables, unittest]

import isonim/core/[signals, owner]

import backend/[backend_service, mock_backend]
import store/replay_data_store
import viewmodels/[flow_vm, flow_layout, flow_line_values]

const fixturePath = currentSourcePath().parentDir / ".." / "fixtures" /
  "flow" / "zk_shields_flow_window.json"

const fixtureText = staticRead(fixturePath)
  ## Embedded at compile time, so the suite runs on the JS backend too.

proc fixtureView(): JsonNode =
  parseJson(fixtureText)["viewUpdate"]

proc stepAt(window: FlowLayoutWindow; stepCount: int): FlowLayoutStep =
  for step in window.steps:
    if step.stepCount == stepCount:
      return step
  doAssert false, "no step " & $stepCount

proc valueOf(values: seq[FlowValueText]; name: string): FlowValueText =
  for v in values:
    if v.expression == name:
      return v
  doAssert false, "no value " & name

proc names(values: seq[FlowValueText]): seq[string] =
  for v in values:
    result.add v.expression

suite "one decoded window":

  test "the window says which call and tick it is of":
    let window = flowLayoutWindowOf(fixtureView())
    check window.key == "1"
    check window.functionName == "iterate_asteroids"
    check window.rrTicks == 9
    check window.highLevelPath.endsWith("noir_space_ship/src/shield.nr")
    check window.location.functionFirst == 0
    check window.location.functionLast == 6

  test "the envelope's location and finished flag win over the view's":
    var envelope = %*{"finished": true, "location": {"key": "7",
      "path": "/p.nr", "highLevelPath": "/p.nr", "functionName": "f",
      "rrTicks": 42}}
    let window = flowLayoutWindowOf(fixtureView(), envelope)
    check window.key == "7"
    check window.rrTicks == 42
    check window.finished
    # The function extent is the view's own.
    check window.location.functionLast == 6

  test "each value carries its recorded tree beside its text":
    let window = flowLayoutWindowOf(fixtureView())
    let step = window.stepAt(3)
    check step.line == 5
    check step.loopIndex == 1
    let i = step.beforeValues.valueOf("i")
    check not i.value.isNil
    check i.value{"kind"}.getInt == 7
    check i.text.len > 0
    let masses = step.beforeValues.valueOf("masses")
    check masses.value{"kind"}.getInt == 0
    check masses.text.len > 0

  test "a value cut to the flow budget says so":
    let long = %*{"kind": 9, "text": "x".repeat(400), "typ": {"kind": 9,
      "langType": "String", "cType": "", "labels": [], "memberTypes": []}}
    var view = %*{"steps": [{"stepCount": 0, "position": 1, "loop": 0,
      "iteration": 0, "rrTicks": 1, "exprOrder": ["s"],
      "beforeValues": {"s": long}, "afterValues": {}, "events": []}]}
    let s = flowLayoutWindowOf(view).steps[0].beforeValues.valueOf("s")
    check s.truncated
    check s.text.len < 400

  test "the return value is beside the variables, not among them":
    let window = flowLayoutWindowOf(fixtureView())
    let step = window.stepAt(0)
    check "return" in step.exprOrder
    check "return" notin step.beforeValues.names
    check not step.beforeReturn.value.isNil
    check step.beforeReturn.expression == "return"
    check step.afterReturn.value.isNil
    # A step that recorded no return value carries none.
    check window.stepAt(3).beforeReturn.value.isNil

  test "the loops carry their pass counts, ticks and per-pass tables":
    let window = flowLayoutWindowOf(fixtureView())
    check window.loops.len == 2
    let loop = window.loops[1]
    check loop.first == 4
    check loop.last == 15
    check loop.iteration == 8
    check loop.rrTicksForIterations.len == 9
    check loop.iterationSteps.len > 0

  test "the line → steps index is the engine's":
    let window = flowLayoutWindowOf(fixtureView())
    check window.positionStepCounts[1] == @[0]
    check window.positionStepCounts[10] == @[7, 16, 25, 34, 43, 52, 61, 70]
    for line, stepCounts in window.positionStepCounts:
      for stepCount in stepCounts:
        check window.stepAt(stepCount).line == line

  test "the branch tables and line facts are the engine's":
    let window = flowLayoutWindowOf(fixtureView())
    check window.branchesTaken.len == 2
    check window.branchesTaken[0].len == 1
    check window.branchesTaken[1].len == 9
    check window.branchesTaken[0][0].table[10] == 2
    check window.relevantStepCount[0 .. 3] == @[1, 2, 4, 5]
    check 17 in window.commentLines
    # The line facts read off the decoded window are the ones read off the
    # wire: one decoder.
    check flowLineFactsOf(window) == flowLineFacts(fixtureView())
    check flowStyledLinesOf(window, finished = false).len > 0

  test "a step's events are decoded":
    var view = %*{"steps": [{"stepCount": 4, "position": 2, "loop": 0,
      "iteration": 0, "rrTicks": 5, "exprOrder": [], "beforeValues": {},
      "afterValues": {}, "events": [
        {"kind": 0, "text": "hello\n", "metadata": "", "rrTicks": 5},
        {"kind": 11, "text": "boom", "metadata": "", "rrTicks": 5}]}]}
    let events = flowLayoutWindowOf(view).steps[0].events
    check events.len == 2
    check events[0].kind == 0
    check events[0].text == "hello\n"
    check events[1].kind == 11

suite "the inline values the terminal and GPUI draw":

  test "no inline value is the return pseudo-expression":
    let window = flowLayoutWindowOf(fixtureView())
    for lineValue in flowLineValues(window, rrTicks = high(int), maxValues = 8):
      check "return=" notin lineValue.text

suite "FlowVM adopts every view of a window":

  test "each view is decoded, and the source view is layoutWindow":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let vm = createFlowVM(createReplayDataStore(mock.toBackendService()))
      var second = fixtureView().copy
      second["location"]["functionLast"] = %20
      vm.applyFlowUpdate(%*{"finished": true,
        "location": fixtureView()["location"],
        "viewUpdates": [fixtureView(), second]})
      let windows = vm.layoutWindows.val
      check windows.len == 2
      check windows[0] == vm.layoutWindow.val
      check windows[1].location.functionLast == 20
      check windows[0].finished
      check vm.styledLines.val == flowLineFacts(fixtureView())
      check vm.loops.val.len == 2
      dispose()
