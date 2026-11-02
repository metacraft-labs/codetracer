## viewmodels/flow_line_values.nim — the flow's values, one line of text per
## source line, for an editor that draws them itself.
##
## VS Code draws the flow as decorations after each line (Shared-DOM-Front-
## Ends D9: "decorations and inlay hints for values and flow ... fed from the
## host's ViewModels, never computed in TypeScript"). This turns the window
## `FlowVM` holds (`layoutWindow`) into that text: for each line of the
## window, the values recorded at the step that ran it most recently at or
## before the debugger's tick (the first step when none has run yet), the
## values after the step when it recorded them, before it otherwise.
##
## Pure, and on both backends.

import std/strutils

import ./flow_layout

type
  FlowLineValue* = object
    line*: int
      ## 1-based source line.
    text*: string
      ## `expr=value, …`, at most `maxValues` of them.

proc stepFor(window: FlowLayoutWindow; steps: seq[int]; rrTicks: int): int =
  ## The index of the step of `steps` that ran most recently at or before
  ## `rrTicks`; the first one when none has.
  result = steps[0]
  for index in steps:
    if window.steps[index].rrTicks <= rrTicks:
      result = index

func valuesText(values: seq[FlowValueText]; maxValues: int): string =
  var parts: seq[string] = @[]
  for v in values:
    if parts.len >= maxValues:
      break
    if v.expression.len == 0:
      continue
    parts.add v.expression & "=" & v.text
  parts.join(", ")

proc flowLineValues*(window: FlowLayoutWindow; rrTicks: int;
                     maxValues = 3): seq[FlowLineValue] =
  ## The window's lines with something to show, ascending.
  for group in window.groupStepsByLine():
    if group.stepCounts.len == 0:
      continue
    let step = window.steps[window.stepFor(group.stepCounts, rrTicks)]
    let values =
      if step.afterValues.len > 0: step.afterValues else: step.beforeValues
    let text = valuesText(values, maxValues)
    if text.len > 0:
      result.add FlowLineValue(line: group.line, text: text)

type
  FlowLoopLine* = object
    line*: int
      ## 1-based line the loop's control is attached to.
    locationInside*: bool
      ## Whether the debugger's line is in the loop's body, so the editor
      ## shows the control there open.

proc flowLoopLines*(window: FlowLayoutWindow; debuggerLine: int):
    seq[FlowLoopLine] =
  ## The window's loops, each where its control goes. Loop 0 is the function
  ## itself (`FlowLayoutWindow.loops[0]`), not a loop the user steps through.
  for i in 1 ..< window.loops.len:
    let loop = window.loops[i]
    if loop.registeredLine <= 0:
      continue
    result.add FlowLoopLine(
      line: loop.registeredLine,
      locationInside: debuggerLine >= loop.first and debuggerLine <= loop.last)
