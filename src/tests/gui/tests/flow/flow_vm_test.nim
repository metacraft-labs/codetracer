## test_flow_vm.nim
##
## Unit tests for FlowVM — the ViewModel for the Flow panel.
##
## Verifies:
## - Initial state defaults (flowMode, selectedIteration, hoveredStep, etc.)
## - setMode changes flowMode
## - selectIteration updates with clamping
## - hoverStep sets/clears hovered step
## - clickStep sends navigation command
## - toggleRawValues toggles the boolean
## - isLoading memo reflects loading state
## - totalIterations memo reflects iteration count
## - Auto-load effect fires when debugger position or flowMode changes
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_flow_vm.nim

import std/[json, unittest, options]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/flow_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  ## Create a ReplayDataStore backed by a MockBackendService.
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

const LoopHeaderTicks* = @[2, 8, 14, 20, 26, 32, 38, 44, 50, 56]
  ## Loop-header ticks of a ten-iteration loop, six ticks apart.
  ##
  ## These are the numbers the #593/#595 reporter's recording produced: the
  ## backend window stays `[2, 8, 14, ... 56]` across the whole loop, so every
  ## iteration is six ticks long and the debugger only ever lands exactly on a
  ## header when it was jumped there. See `diag-flow-loops` / the issue thread.

proc loopFlowResponse(headerTicks: seq[int]; locationTicks: int): JsonNode =
  ## A `ct/load-flow` response carrying one loop with `headerTicks`, computed
  ## for a debugger stopped at `locationTicks`.
  ##
  ## Not a mock of the ViewModel — this is the wire format the Rust backend
  ## actually serialises (`FlowUpdate` / `FlowViewUpdate` / `Loop` in
  ## `src/db-backend/src/task.rs`, all `rename_all = "camelCase"`), including
  ## the placeholder `Loop::default()` the backend always puts at index 0
  ## (`FlowViewUpdate::new`). Getting that placeholder wrong is exactly the
  ## kind of off-by-one that makes the counter point at the wrong loop, so it
  ## is reproduced rather than simplified away.
  var loops = %*[
    {
      "base": 0, "baseIteration": 0, "internal": [],
      "first": -1, "last": -1, "registeredLine": -1,
      "iteration": 0, "stepCounts": [], "rrTicksForIterations": []
    }
  ]
  if headerTicks.len > 0:
    loops.add(%*{
      "base": 0,
      "baseIteration": -1,
      "internal": [],
      "first": 8,
      "last": 16,
      "registeredLine": 8,
      "iteration": headerTicks.len - 1,
      "stepCounts": [],
      "rrTicksForIterations": headerTicks
    })

  %*{
    "viewUpdates": [
      {
        "location": {"rrTicks": locationTicks, "line": 9, "path": "main.nr"},
        "positionStepCounts": {},
        "steps": [],
        "loops": loops,
        "branchesTaken": [],
        "loopIterationSteps": [],
        "relevantStepCount": [],
        "commentLines": []
      }
    ],
    "location": {"rrTicks": locationTicks, "line": 9, "path": "main.nr"},
    "error": false,
    "errorMessage": "",
    "finished": true,
    "status": {"kind": "FlowFinished", "steps": 0}
  }

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "FlowVM initial state":

  test "flowMode defaults to fmCall":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.flowMode.val == fmCall
      dispose()

  test "selectedIteration defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.selectedIteration.val == 0
      dispose()

  test "hoveredStep defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.hoveredStep.val.isNone
      dispose()

  test "showRawValues defaults to false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.showRawValues.val == false
      dispose()

  test "isLoading starts false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.isLoading.val == false
      dispose()

  test "totalIterations starts at 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      check vm.totalIterations.val == 0
      dispose()

# ---------------------------------------------------------------------------
# Flow mode
# ---------------------------------------------------------------------------

suite "FlowVM flow mode":

  test "setMode changes flowMode signal":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.setMode(fmLine)
      check vm.flowMode.val == fmLine

      vm.setMode(fmFunction)
      check vm.flowMode.val == fmFunction

      vm.setMode(fmCall)
      check vm.flowMode.val == fmCall

      dispose()

# ---------------------------------------------------------------------------
# Iteration selection
# ---------------------------------------------------------------------------

suite "FlowVM iteration selection":

  test "selectIteration sets the selected iteration":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 10
      vm.selectIteration(5)
      check vm.selectedIteration.val == 5

      dispose()

  test "selectIteration clamps negative values to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 10
      vm.selectIteration(-3)
      check vm.selectedIteration.val == 0

      dispose()

  test "selectIteration clamps to max iteration":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 5
      vm.selectIteration(99)
      check vm.selectedIteration.val == 4  # totalIterations - 1

      dispose()

  test "selectIteration allows 0 when no iterations":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      # iterationCount is 0, so totalIterations is 0.
      # maxIter = -1, so the else branch sets directly.
      vm.selectIteration(0)
      check vm.selectedIteration.val == 0

      dispose()

# ---------------------------------------------------------------------------
# Hover step
# ---------------------------------------------------------------------------

suite "FlowVM hover step":

  test "hoverStep sets the hovered step":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.hoverStep(some(3))
      check vm.hoveredStep.val == some(3)

      dispose()

  test "hoverStep with none clears the hovered step":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.hoverStep(some(7))
      check vm.hoveredStep.val.isSome

      vm.hoverStep(none(int))
      check vm.hoveredStep.val.isNone

      dispose()

# ---------------------------------------------------------------------------
# Click step (navigation)
# ---------------------------------------------------------------------------

suite "FlowVM clickStep":

  test "clickStep sends flow-jump command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      let cmdCountBefore = mock.receivedCommands.len

      vm.clickStep(42)
      drain()

      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      var found = false
      for cmd in jumpCmds:
        if cmd.command == "ct/flow-jump":
          check cmd.args["step"].getInt == 42
          check cmd.args["flowMode"].getStr == "fmCall"
          check cmd.args["iteration"].getInt == 0
          found = true
          break
      check found

      dispose()

  test "clickStep includes current mode and iteration":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      vm.setMode(fmLine)
      vm.iterationCount.val = 10
      vm.selectIteration(3)

      let cmdCountBefore = mock.receivedCommands.len

      vm.clickStep(7)
      drain()

      let jumpCmds = mock.receivedCommands[cmdCountBefore .. ^1]
      var found = false
      for cmd in jumpCmds:
        if cmd.command == "ct/flow-jump":
          check cmd.args["flowMode"].getStr == "fmLine"
          check cmd.args["iteration"].getInt == 3
          found = true
          break
      check found

      dispose()

# ---------------------------------------------------------------------------
# Raw values toggle
# ---------------------------------------------------------------------------

suite "FlowVM toggleRawValues":

  test "toggleRawValues flips the boolean":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      check vm.showRawValues.val == false

      vm.toggleRawValues()
      check vm.showRawValues.val == true

      vm.toggleRawValues()
      check vm.showRawValues.val == false

      dispose()

# ---------------------------------------------------------------------------
# isLoading memo
# ---------------------------------------------------------------------------

suite "FlowVM isLoading":

  test "isLoading reflects loading state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      check vm.isLoading.val == false

      vm.loadingState.val = lsLoading
      check vm.isLoading.val == true

      vm.loadingState.val = lsIdle
      check vm.isLoading.val == false

      dispose()

  test "isLoading is false when loading state is lsError":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.loadingState.val = lsError
      check vm.isLoading.val == false

      dispose()

# ---------------------------------------------------------------------------
# totalIterations memo
# ---------------------------------------------------------------------------

suite "FlowVM totalIterations":

  test "totalIterations reflects iterationCount":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.iterationCount.val = 15
      check vm.totalIterations.val == 15

      vm.iterationCount.val = 0
      check vm.totalIterations.val == 0

      dispose()

# ---------------------------------------------------------------------------
# Auto-load effect
# ---------------------------------------------------------------------------

suite "FlowVM auto-load effect":

  test "changing rrTicks triggers flow data request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      # Initially rrTicks is 0 — no request should fire.
      let initialCount = mock.receivedCommands.len
      check initialCount == 0

      # Simulate debugger moving.
      var dbg = store.debugger.val
      dbg.rrTicks = 200'u64
      store.debugger.val = dbg
      drain()

      var found = false
      for cmd in mock.receivedCommands:
        if cmd.command == "ct/load-flow":
          # The engine's `CtLoadFlowArguments` (src/db-backend/src/task.rs)
          # has exactly two fields, `flowMode` and `location`, and the tick
          # lives INSIDE the location. The old shape — a top-level `rrTicks`
          # and `"flowMode": "fmCall"` — named a rendering granularity the
          # engine has never heard of and omitted the required location.
          check cmd.args.hasKey("location")
          check cmd.args["location"]["rrTicks"].getBiggestInt == 200
          check not cmd.args.hasKey("rrTicks")
          # A stable name, not an ordinal: see common/flow_mode_wire.nim.
          check cmd.args["flowMode"].getStr == FlowModeWireCall
          check cmd.args["flowMode"].kind == JString
          found = true
          break
      check found

      dispose()

  test "changing flowMode triggers flow data request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      # First, set rrTicks > 0 so the effect guard passes.
      var dbg = store.debugger.val
      dbg.rrTicks = 50'u64
      store.debugger.val = dbg
      drain()

      let countBefore = mock.receivedCommands.len

      vm.setMode(fmFunction)
      drain()

      # A new request should have been sent with the updated mode.
      var found = false
      for i in countBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "ct/load-flow":
          # Every view granularity is `call` to the engine — they differ in
          # how this panel lays the returned steps out, not in what it asks
          # for. Sending `"fmFunction"` was a category error; sending the
          # ordinal `2` would have been worse, because the engine's enum has
          # no third member and an out-of-range-but-plausible ordinal is
          # indistinguishable from a correct one at the call site.
          check cmd.args["flowMode"].getStr == FlowModeWireCall
          found = true
          break
      check found

      dispose()

  test "auto-load does not fire for rrTicks == 0":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      var dbg = store.debugger.val
      dbg.rrTicks = 0'u64
      store.debugger.val = dbg
      drain()

      for cmd in mock.receivedCommands:
        check cmd.command != "ct/load-flow"

      dispose()

  test "the ct/load-flow response is consumed into the VM's flow state":
    # This test replaces `iterationCount is not fed by any production code
    # path`, which in turn had replaced two tests (`test_flow_loop_iteration_
    # display`, `test_loop_controls_arrow_navigation`) cited by milestones
    # M32/M34 as covering the Omniscience loop counter. Those two wrote
    # `vm.iterationCount.val` themselves and then asserted that
    # `selectIteration(n)` sets `selectedIteration` to `n` — a tautology over a
    # clamp, on a signal nothing in production wrote, because `FlowVM` fired
    # `ct/load-flow` and dropped the reply.
    #
    # `FlowVM` now consumes it, so the gap is closed and this asserts the
    # wiring itself: a debugger move must leave the panel describing the loop
    # window the backend returned.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      mock.expect("ct/load-flow", loopFlowResponse(LoopHeaderTicks, 14))

      var dbg = store.debugger.val
      dbg.rrTicks = 14'u64
      store.debugger.val = dbg
      drain()

      check mock.findCommand("ct/load-flow").isSome
      check vm.loops.val.len == 2          # placeholder loop 0 + the real loop
      check vm.focusedLoop.val == 1
      check vm.windowRRTicks.val == 14
      check vm.iterationCount.val == LoopHeaderTicks.len
      check vm.loadingState.val == lsIdle
      check vm.isLoading.val == false

      dispose()

# ---------------------------------------------------------------------------
# Loop iteration counter (#593, #595)
# ---------------------------------------------------------------------------
#
# Specification: codetracer-specs/GUI/Debugging-Features/Omniscience-Flow.md.
#
#   "Loop Visualization — When code is inside a loop, Omniscience shows values
#    across iterations", rendered as `[Iteration: 1 of 5]` / `[Iteration 3/8]`.
#
# Two obligations follow from that rendering and are what these tests pin:
#
#   1. The left-hand number identifies WHICH iteration is being shown — so when
#      the debugger is inside iteration k, it must read k. It is not a counter
#      of clicks and it is not free to stay at 0 (#593).
#   2. The right-hand number is the loop's iteration count — "of 5", "/8" — a
#      property of the loop, not of where the cursor happens to be. It must not
#      change as the user walks through the loop (#595, the reporter's
#      "0 from 10 -> 0 from 8 -> 0 from 6").
#
# And from "Loop Slider Control — Click arrows for previous/next": one click
# moves exactly one iteration.
#
# The spec's ASCII sketches number iterations from 1 while the implementation
# indexes them from 0; the spec does not state which is normative, so these
# tests assert only relative movement and totals, never a specific origin.

suite "FlowVM loop iteration counter":

  test "the selected iteration is the one CONTAINING the debugger's ticks":
    # #593. `rrTicksForIterations` holds each iteration's loop-HEADER tick, so
    # a debugger stopped anywhere in the body sits strictly between two of them.
    # Reading the window without re-deriving the selection from those ticks is
    # what left the counter reading 0 forever.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 14))
      check vm.selectedIteration.val == 2      # exactly on iteration 2's header

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 16))
      check vm.selectedIteration.val == 2      # inside iteration 2's body

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 19))
      check vm.selectedIteration.val == 2      # still, right up to the next header

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 20))
      check vm.selectedIteration.val == 3

      dispose()

  test "successive windows count up 0, 1, 2 and keep the total":
    # The headless statement of the reporter's sequence in #595: six forward
    # moves, one iteration apart. The counter must follow the debugger and the
    # total must not move at all.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, LoopHeaderTicks[0]))
      let total = vm.totalIterations.val
      check total == LoopHeaderTicks.len

      for iteration in 0 ..< LoopHeaderTicks.len:
        # A jump to an iteration lands the debugger on that iteration's header;
        # the reload is what the arrow click ultimately produces.
        vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, LoopHeaderTicks[iteration]))
        check vm.selectedIteration.val == iteration
        check vm.totalIterations.val == total

      dispose()

  test "a reload does not reset the counter to the start of the loop":
    # The precise shape of #593 in the Karax UI: every debugger move builds a
    # brand-new component with an empty loop state, and that state used to be
    # created with `activeIteration = 0`. Adopting a window must never move the
    # user back to iteration 0 unless the debugger really is in iteration 0.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 50))
      check vm.selectedIteration.val == 8

      # Same window, delivered again (the UI reloads flow on every move).
      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 50))
      check vm.selectedIteration.val == 8

      dispose()

  test "ticks before the loop select the first iteration, after it the last":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 1))
      check vm.selectedIteration.val == 0

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 9_999))
      check vm.selectedIteration.val == LoopHeaderTicks.len - 1

      dispose()

  test "a window with no loop reports no iterations and selects 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, 20))
      check vm.totalIterations.val > 0

      vm.applyFlowUpdate(loopFlowResponse(@[], 20))
      check vm.focusedLoop.val == -1
      check vm.totalIterations.val == 0
      check vm.selectedIteration.val == 0

      dispose()

  test "a malformed response is reported, not adopted":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.applyFlowUpdate(newJNull())
      check vm.loadingState.val == lsError

      vm.applyFlowUpdate(%*{})
      check vm.loadingState.val == lsError

      vm.applyFlowUpdate(%*{"viewUpdates": newJArray()})
      check vm.loadingState.val == lsError

      dispose()

suite "FlowVM loop control arrows":

  test "forward and backward move exactly one iteration":
    # Spec, "Loop Slider Control": "Click arrows for previous/next".
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, LoopHeaderTicks[0]))
      check vm.selectedIteration.val == 0

      for expected in 1 .. 5:
        vm.stepIterationForward()
        check vm.selectedIteration.val == expected

      for expected in countdown(4, 0):
        vm.stepIterationBackward()
        check vm.selectedIteration.val == expected

      dispose()

  test "the arrows clamp at both end stops":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, LoopHeaderTicks[0]))

      vm.stepIterationBackward()
      check vm.selectedIteration.val == 0

      vm.selectIteration(vm.maxIteration())
      vm.stepIterationForward()
      check vm.selectedIteration.val == vm.maxIteration()

      dispose()

  test "arrows are inert while no loop is loaded":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)

      check vm.maxIteration() == -1
      vm.stepIterationForward()
      check vm.selectedIteration.val == 0
      vm.stepIterationBackward()
      check vm.selectedIteration.val == 0

      dispose()

# ---------------------------------------------------------------------------
# The `ct/load-flow` boundary: vocabulary, request shape, and the event path
# ---------------------------------------------------------------------------
#
# `ct/load-flow` had two `FlowMode` enums that did not agree — the engine's
# two-valued query mode (`Call | Diff`, src/db-backend/src/task.rs) and this
# panel's three-valued view granularity (`fmCall | fmLine | fmFunction`) —
# and the panel sent `$mode` at a field the engine read as an ordinal.
#
# The visible symptom was a rejected request. The dangerous one was not: an
# ordinal that crosses a boundary where the two sides have different
# cardinality does not fail, it silently means something else, and a window
# for the wrong location looks exactly like a window for the right one.
#
# So the wire form is a name, `common/flow_mode_wire.nim` is the single Nim
# source of it, and `src/db-backend/tests/flow_mode_wire_test.rs` reads that
# file so the two languages cannot drift apart without a test failing. These
# cases pin the Nim half.

suite "FlowVM — the ct/load-flow engine boundary":

  test "the wire vocabulary is exactly what the engine parses":
    # The Rust half asserts the same two strings against `FLOW_MODE_WIRE_NAMES`
    # in src/db-backend/src/task.rs, and reads this vocabulary out of
    # common/flow_mode_wire.nim to prove they are the same list.
    check FlowModeWireNames == ["call", "diff"]
    check FlowModeWireCall == "call"
    check FlowModeWireDiff == "diff"
    check flowModeWireOrdinal("call") == 0
    check flowModeWireOrdinal("diff") == 1
    # An unknown spelling must be reportable, never silently defaulted.
    check flowModeWireOrdinal("fmCall") == -1
    check flowModeWireOrdinal("") == -1

  test "every view granularity maps to a name the engine knows":
    # Totality is the property: a fourth `fm*` member cannot compile without
    # someone deciding what it means to the engine, and no granularity may
    # map to a string outside the shared vocabulary.
    for mode in FlowMode.low .. FlowMode.high:
      let wire = engineFlowModeWireName(mode)
      check flowModeWireOrdinal(wire) >= 0
      check wire != $mode

  test "the request carries flowMode and location, and nothing else":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      discard createFlowVM(store)
      drain()

      var dbg = store.debugger.val
      dbg.rrTicks = 314'u64
      dbg.location = Location(file: "main.nr", line: 9, callstackDepth: 2)
      store.debugger.val = dbg
      drain()

      var found = false
      for cmd in mock.receivedCommands:
        if cmd.command == "ct/load-flow":
          found = true
          # `CtLoadFlowArguments` has exactly these two fields and both are
          # required — no `#[serde(default)]` on the container.
          check cmd.args.kind == JObject
          check cmd.args.hasKey("flowMode")
          check cmd.args.hasKey("location")
          check cmd.args.len == 2
          check cmd.args["flowMode"].kind == JString
          check cmd.args["location"]["path"].getStr == "main.nr"
          check cmd.args["location"]["line"].getInt == 9
          check cmd.args["location"]["rrTicks"].getBiggestInt == 314
          check cmd.args["location"]["callstackDepth"].getInt == 2
      check found

      dispose()

  test "the window arrives on the ct/updated-flow event, not the reply":
    # `ct/load-flow`'s real answer is a queued event
    # (`src/db-backend/src/dap.rs`). A panel that consumed only the reply
    # would be permanently empty against the engine while every mock-driven
    # test passed — the request/response half of this boundary is not the
    # whole boundary.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()
      check vm.loops.val.len == 0

      mock.emitEvent(%*{
        "kind": UpdatedFlowEventKind,
        "data": loopFlowResponse(LoopHeaderTicks, LoopHeaderTicks[0]),
      })
      drain()

      check vm.loops.val.len > 0
      check vm.totalIterations.val == LoopHeaderTicks.len

      dispose()

  test "the event is recognised under the DAP name too":
    # Which spelling arrives depends on whether the backend-manager is in
    # the path. Recognising only one is a silent empty panel on the other.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      mock.emitEvent(%*{
        "kind": UpdatedFlowCommandName,
        "data": loopFlowResponse(LoopHeaderTicks, LoopHeaderTicks[0]),
      })
      drain()

      check vm.loops.val.len > 0

      dispose()

  test "an unrelated event never disturbs the flow window":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      vm.applyFlowUpdate(loopFlowResponse(LoopHeaderTicks, LoopHeaderTicks[0]))
      let before = vm.loops.val.len
      check before > 0

      mock.emitEvent(%*{"kind": "CtUpdatedTable", "data": %*{}})
      drain()

      check vm.loops.val.len == before

      dispose()
