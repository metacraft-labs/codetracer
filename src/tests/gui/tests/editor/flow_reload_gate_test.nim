## Headless tests for `src/frontend/ui/flow_reload_gate.nim`: how many times
## the flow's `.view-lines` watcher re-renders the flow.
##
## Regression target: drawing main's flow in the Pascal sudoku solver kept the
## renderer busy for 34 s, or crashed it. Every step of main's loops carries
## `boards` (10 x 9 x 9 cells). The watcher re-rendered the whole flow on every
## `childList` mutation of Monaco's `.view-lines` while some step had no node,
## and the re-render was itself such a mutation. A render draws only each
## line's current step, so steps of the other iterations never got a node and
## the cycle never ended.
##
## The one stand-in, and why it is not a mock: `SimulatedEditor` is the loop
## the browser runs. A re-render queues one more `.view-lines` mutation (the
## view zones it replaces), and the editor delivers queued mutations to the
## watcher until none is left. Its `drawable` count is how many of the render's
## steps Monaco can give a node to. The counts are the subject; no timing is
## involved, so the result does not depend on the host's load.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/editor/flow_reload_gate_test.nim

import std/unittest

import ../../../../frontend/ui/flow_reload_gate

type
  SimulatedEditor = ref object
    targets: int        ## steps the last render tried to draw
    drawn: int          ## of those, steps that have a node
    drawable: int       ## steps a render can give a node to
    perRender: int      ## nodes one render adds, up to `drawable`
    pending: int        ## `.view-lines` mutations not yet delivered
    reloads: int

const DeliveryCap = 500
  ## Far above any bounded answer: an unbounded watcher reaches it.

proc render(editor: SimulatedEditor) =
  inc editor.reloads
  editor.drawn = min(editor.drawable, editor.drawn + editor.perRender)
  inc editor.pending  # the render replaced view zones: one more mutation

proc deliverAll(editor: SimulatedEditor; gate: var FlowReloadGate) =
  var delivered = 0
  while editor.pending > 0 and delivered < DeliveryCap:
    dec editor.pending
    inc delivered
    gate.onLinesMutated(
      proc(): int = editor.targets - editor.drawn,
      proc() = editor.render())

suite "flow reload gate":

  test "a flow whose large previews never all get a node is re-rendered once, not forever":
    # Main's flow in the sudoku solver: 88 lines drawn, of which some steps
    # (here 12) cannot get a node. Scrolling or the first draw delivers one
    # mutation; each re-render delivers another.
    var gate = initFlowReloadGate()
    let editor = SimulatedEditor(targets: 88, drawn: 76, drawable: 76,
      perRender: 88, pending: 1)
    editor.deliverAll(gate)
    check editor.reloads == 1
    check editor.pending == 0
    check gate.stalled

  test "re-renders continue while each one draws more":
    var gate = initFlowReloadGate()
    let editor = SimulatedEditor(targets: 10, drawn: 6, drawable: 10,
      perRender: 1, pending: 1)
    editor.deliverAll(gate)
    check editor.drawn == 10
    check editor.reloads == 4
    check not gate.stalled

  test "a flow with every drawn step in place is not re-rendered":
    var gate = initFlowReloadGate()
    let editor = SimulatedEditor(targets: 10, drawn: 10, drawable: 10,
      perRender: 1, pending: 3)
    editor.deliverAll(gate)
    check editor.reloads == 0

  test "a fresh render of the flow lets the watcher try again":
    var gate = initFlowReloadGate()
    let editor = SimulatedEditor(targets: 5, drawn: 2, drawable: 2,
      perRender: 5, pending: 1)
    editor.deliverAll(gate)
    check editor.reloads == 1
    gate.reset()
    editor.drawable = 5
    editor.pending = 1
    editor.deliverAll(gate)
    check editor.reloads == 2
    check editor.drawn == 5
