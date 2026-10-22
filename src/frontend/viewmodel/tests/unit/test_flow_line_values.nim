## test_flow_line_values.nim — the flow's per-line text an editor draws
## after each line (`viewmodels/flow_line_values`), from a window built by
## hand: no backend, nothing to mock.

import std/unittest

import viewmodels/[flow_layout, flow_line_values]

proc step(line, ticks: int; after: seq[(string, string)] = @[];
          before: seq[(string, string)] = @[]): FlowLayoutStep =
  result = FlowLayoutStep(line: line, rrTicks: ticks)
  for (e, t) in after: result.afterValues.add FlowValueText(expression: e, text: t)
  for (e, t) in before: result.beforeValues.add FlowValueText(expression: e, text: t)

suite "the flow's values, one line of text per source line":

  test "each line shows the step that ran it last at or before the tick":
    let w = FlowLayoutWindow(steps: @[
      step(3, 10, after = @[("i", "0")]),
      step(4, 11, after = @[("s", "0")]),
      step(3, 12, after = @[("i", "1")]),
      step(4, 13, after = @[("s", "1")])])
    let at12 = flowLineValues(w, 12)
    check at12.len == 2
    check at12[0].line == 3 and at12[0].text == "i=1"
    check at12[1].line == 4 and at12[1].text == "s=0"

  test "before any step ran, a line shows its first; before-values stand in":
    let w = FlowLayoutWindow(steps: @[
      step(7, 50, before = @[("x", "5")]),
      step(7, 60, after = @[("x", "6")])])
    check flowLineValues(w, 1) == @[FlowLineValue(line: 7, text: "x=5")]

  test "at most maxValues values, and a line with none is absent":
    let w = FlowLayoutWindow(steps: @[
      step(2, 1, after = @[("a", "1"), ("b", "2"), ("c", "3"), ("d", "4")]),
      step(5, 2)])
    let lines = flowLineValues(w, 9, maxValues = 2)
    check lines == @[FlowLineValue(line: 2, text: "a=1, b=2")]
