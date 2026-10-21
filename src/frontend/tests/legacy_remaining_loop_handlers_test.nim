## Exercise legacy DOM handlers after all loop iterations finish.
## DataTables is a protocol fake: sorting uses its order/draw API, not its
## external layout engine. The DOM and production header rendering are real.
## The noUiSlider fake records widget callbacks, and its measured width is
## supplied because jsdom has no layout engine. Slider binding and delayed
## callback dispatch remain production code. HistorySink replaces only the
## engine/scratchpad recipients so the real mediator's emitted payloads can
## be checked without opening a recording or booting the application.
import std/[unittest, jsffi, dom]
import ./legacy_loop_dom_bootstrap
import ../ui/event_log

proc makeTable(): JsObject {.importjs: "({selection: [], order: function(value) { if (value) { this.selection = value; return this; } return this.selection; }, draw: function() { return this; }})".}
proc selection(table: JsObject): int {.importjs: "#[\"selection\"][0][0]".}
proc click(node: Node) {.importjs: "#.dispatchEvent(new window.MouseEvent('click', {bubbles: true}))".}
proc failExit() {.importjs: "(function() { process.exitCode = 1; })()".}

suite "legacy handlers retain each loop item":
  test "event header first and middle columns sort their own indices":
    document.body.innerHTML = cstring"<div class='data-table'><table id='loop-header'></table></div>"
    let table = makeTable()
    let columns = @[
      js{title: cstring"First", className: cstring"first", data: cstring"first", visible: true},
      js{title: cstring"Middle", className: cstring"middle", data: cstring"middle", visible: true},
      js{title: cstring"Last", className: cstring"last", data: cstring"last", visible: true}]
    renderColumnHeader(cstring"loop-header", columns, table)
    click(document.querySelector(cstring".eventLog-column-header .first"))
    check selection(table) == 0
    if selection(table) != 0: failExit()
    click(document.querySelector(cstring".eventLog-column-header .middle"))
    check selection(table) == 1
    if selection(table) != 1: failExit()

import ../types
import ../js_assoc
import ../communication
import ../../common/ct_event
import ../ui/[value, editor, unified_diff]
import ../viewmodel/viewmodels/[generated_code_operation, review_flow_overlay]

# Only the destination of the history seek is substituted. The production
# renderer emits its real CtHistoryJump event through the real mediator.
type HistorySink = ref object of Subscriber
  ticks: seq[int]
  values: seq[cstring]
method emitRaw(s: HistorySink; kind: CtEventKind; payload: JsObject; source: Subscriber) =
  if kind == CtHistoryJump:
    s.ticks.add payload.to(types.Location).rrTicks
  elif kind == InternalAddToScratchpad:
    s.values.add payload.to(ValueWithExpression).value.i

proc leftDown(node: Node) {.importjs: "#.dispatchEvent(new window.MouseEvent('mousedown', {button: 0, bubbles: true}))".}
proc context(node: Node) {.importjs: "#.dispatchEvent(new window.MouseEvent('contextmenu', {bubbles: true}))".}
proc installSliderFake() {.importjs: "(function() { globalThis.noUiSlider = {create: function(el, opts) {el.noUiSlider = {on: function(name, cb) {el.slideCallback = cb;}, destroy: function() {}, set: function() {}};}}; })()".}
proc measurable(node: Node) {.importjs: "Object.defineProperty(#, 'clientWidth', {value: 120})".}
proc slide(node: Node; iteration: int) {.importjs: "#.slideCallback([], 0, [#], false, [])".}

suite "legacy value, generated targets and review sliders retain each item":
  test "history first and middle entries seek their own ticks":
    let sink = HistorySink()
    let api = MediatorWithSubscribers()
    api.subscribers[CtHistoryJump].add sink
    api.subscribers[InternalAddToScratchpad].add sink
    let state = StateComponent(api: api, valueHistory: JsAssoc[cstring, ValueHistory]{})
    state.valueHistory[cstring"x"] = ValueHistory(results: @[
      HistoryResult(location: types.Location(rrTicks: 11), value: intValue(1)),
      HistoryResult(location: types.Location(rrTicks: 22), value: intValue(2)),
      HistoryResult(location: types.Location(rrTicks: 33), value: intValue(3))])
    let component = ValueComponent(state: state, api: api, baseAddress: NO_ADDRESS)
    let root = renderHistoryTableDom(component, cstring"x", ChartComponent(viewKind: ViewTable))
    let nodes = root.querySelectorAll(cstring".history-value")
    leftDown(nodes[0])
    leftDown(nodes[1])
    check sink.ticks == @[11, 22]
    if sink.ticks != @[11, 22]: failExit()
    document.body.innerHTML = cstring"<div id='context-menu-container'></div>"
    context(nodes[0])
    click(document.querySelector(cstring"#menu-item-0"))
    let locations = root.querySelectorAll(cstring".history-location")
    context(locations[1])
    click(document.querySelector(cstring"#menu-item-0"))
    check sink.values == @[cstring"1", cstring"2"]
    if sink.values != @[cstring"1", cstring"2"]: failExit()

  test "generated-code first and middle target handlers open their own targets":
    var opened: seq[(cstring, int, string)]
    let commands = @[
      TargetCommand(target: GeneratedCodeTarget(id: "acir", displayName: "ACIR"), availability: gaEnabled),
      TargetCommand(target: GeneratedCodeTarget(id: "brillig", displayName: "Brillig"), availability: gaEnabled),
      TargetCommand(target: GeneratedCodeTarget(id: "ssa", displayName: "SSA"), availability: gaEnabled)]
    let entries = generatedCodeMenuItems(commands, cstring"/tmp/main.nr", 17,
      proc(path: cstring; line: int; targetId: string) =
        opened.add (path, line, targetId))
    entries[0].handler(nil)
    entries[1].handler(nil)
    let expected = @[(cstring"/tmp/main.nr", 17, "acir"),
                     (cstring"/tmp/main.nr", 17, "brillig")]
    check opened == expected
    if opened != expected: failExit()

  test "review sliders dispatch the function and loop shown beside each slider":
    # Only the noUiSlider external widget protocol and layout width are faked:
    # jsdom has no layout engine. The production binding loop and slide handler
    # are the code under test, including the delayed widget callback.
    installSliderFake()
    document.body.innerHTML = cstring"<div id='review-loop-slider-7-first-1'><div class='flow-loop-slider'></div></div><div id='review-loop-slider-7-middle-2'><div class='flow-loop-slider'></div></div><div id='review-loop-slider-7-last-3'><div class='flow-loop-slider'></div></div>"
    let first = document.querySelector(cstring"#review-loop-slider-7-first-1 .flow-loop-slider")
    let middle = document.querySelector(cstring"#review-loop-slider-7-middle-2 .flow-loop-slider")
    let last = document.querySelector(cstring"#review-loop-slider-7-last-3 .flow-loop-slider")
    measurable(first)
    measurable(middle)
    measurable(last)
    var selected: seq[string]
    let pending = bindReviewLoopSliders(7, @[
      ReviewLoopZone(functionKey: "first", loopIndex: 1, total: 4),
      ReviewLoopZone(functionKey: "middle", loopIndex: 2, total: 5),
      ReviewLoopZone(functionKey: "last", loopIndex: 3, total: 6)],
      proc(key: string; index, iteration: int) =
        selected.add key & ":" & $index & ":" & $iteration)
    check not pending
    if pending: failExit()
    slide(first, 2)
    slide(middle, 3)
    check selected == @["first:1:2", "middle:2:3"]
    if selected != @["first:1:2", "middle:2:3"]: failExit()
