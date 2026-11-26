## When a change to the editor's rendered lines should re-render the flow.
##
## The flow watches Monaco's `.view-lines` for `childList` mutations and
## re-renders its values when the last render left some of them without a
## node. Re-rendering is itself a `.view-lines` mutation: it adds and replaces
## view zones and content widgets, so the watcher sees its own work.
##
## The watcher used to ask whether EVERY step with values had a node. A render
## only draws each line's current step (one iteration of each loop), so in any
## flow with a loop of more than one iteration that question is never answered
## yes, and every mutation re-rendered the whole flow — including the one the
## re-render had just caused. A flow whose values are large (a sudoku solver's
## 10 x 9 x 9 `boards` at every step) kept the renderer busy for over 30 s and
## could crash it.
##
## The rule here bounds it on two counts:
## - only the steps the last render tried to draw count as missing;
## - a re-render that left as many missing as before made no progress, and
##   another one would not either, so the watcher stops until the flow is
##   rendered afresh (`reset`).
##
## No imports, so it compiles on both backends and is unit-tested headlessly
## (`src/tests/gui/tests/editor/flow_reload_gate_test.nim`).

type
  FlowReloadGate* = object
    stalled*: bool
      ## A watcher re-render left as many steps without a node as it found.

proc initFlowReloadGate*(): FlowReloadGate =
  FlowReloadGate(stalled: false)

proc reset*(gate: var FlowReloadGate) =
  ## A fresh render of the flow (new flow data, a resize, a mode change):
  ## what is missing now is not the watcher's doing.
  gate = initFlowReloadGate()

proc shouldReload*(gate: FlowReloadGate; missing: int): bool =
  ## Whether a `.view-lines` mutation should re-render the flow, given how
  ## many of the last render's steps still have no node.
  missing > 0 and not gate.stalled

proc recordReload*(gate: var FlowReloadGate; missingBefore, missingAfter: int) =
  ## After a re-render the watcher asked for. One that drew nothing new stalls
  ## the watcher: the next would not draw anything either.
  if missingAfter >= missingBefore:
    gate.stalled = true

proc onLinesMutated*(gate: var FlowReloadGate; missing: proc(): int;
    reload: proc()) =
  ## The watcher's whole response to a `.view-lines` `childList` mutation.
  ## `missing` counts the last render's steps that have no node; `reload`
  ## re-renders the flow (and, in the editor, mutates `.view-lines` again).
  let before = missing()
  if not gate.shouldReload(before):
    return
  reload()
  gate.recordReload(before, missing())
