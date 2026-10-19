## viewmodels/flow_vm.nim
##
## FlowVM — ViewModel for the Flow panel.
##
## Holds reactive state for:
## - Flow mode (call, line, function)
## - Selected iteration and hovered step
## - Whether to show raw values
##
## Derives:
## - `isLoading`: whether a flow data request is in flight
## - `totalIterations`: total number of iterations available
##
## Also creates an auto-load effect that requests flow data from the
## backend whenever the debugger location or flowMode changes, **and
## consumes the response**: the loop shape of the returned window and the
## trace tick the window was computed for are stored, and the selected
## iteration is re-derived from them.
##
## That last part is the whole point (#593/#595). The Omniscience loop
## counter is not a free-standing widget: it must show which iteration the
## debugger is *currently inside*, and the debugger's position and the loop
## window arrive together, in this response. A ViewModel that fires
## `ct/load-flow` and ignores the reply cannot express the bug at all —
## which is exactly how the previous "loop iteration display" tests here
## passed while the panel was broken: they wrote `iterationCount`
## themselves and asserted a setter.
##
## Usage:
##   let vm = createFlowVM(store)
##   echo vm.flowMode.val          # fmCall
##   vm.setMode(fmLine)
##   echo vm.totalIterations.val   # derived from the loaded flow window

import std/[algorithm, json, options, strutils, tables]

import isonim/core/[signals, computation, owner, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

# The iteration arithmetic is shared verbatim with the legacy Karax loop
# control in `ui/flow.nim`, so that both surfaces can never disagree about
# which iteration a tick belongs to. `flow_loop_math` imports nothing and
# compiles on both backends; see its header.
import ../../ui/flow_loop_math
# PLAT-42 — the per-line flow decision. `flowStyledLines` is the body of the
# desktop editor's `flowStyleLines`; calling it here rather than re-deriving
# "which lines ran" is what keeps every medium on ONE rule
# (Verification-Harness-Traps §30). It is imported from `common/` rather than
# from `ui/flow_line_styles` (which re-exports it with the CSS classes) so the
# Embed SDK facade reaches no module of the desktop UI tree.
import ../../../common/flow_line_rule
export flow_line_rule.FlowStyledLine, flow_line_rule.FlowLineStyleKind

# The `ct/load-flow` wire vocabulary, shared with the engine. A leaf module
# with no imports, exactly so both this layer and `common_types` can hold the
# same strings; see its header for why the wire form is a name.
import ../../../common/flow_mode_wire
# PLAT-2's value pipeline, for the flow pane's values (`flowValueText`).
import ../../../common/value_presentation
import ../../../common/value_presentation/json_adapter
export flow_mode_wire

type
  FlowMode* = enum
    ## The three flow visualisation modes.
    ##
    ## This is a **view granularity**, local to the panel. It is NOT the
    ## engine's `ct/load-flow` flow mode, which has two values (`call`,
    ## `diff`) and selects a different *query*. `engineFlowModeWireName`
    ## below is the only place the two meet.
    fmCall      ## Show flow at the call level
    fmLine      ## Show flow at the line level
    fmFunction  ## Show flow at the function level

  FlowStepEntry* = object
    step*: int
    location*: string
    expression*: string
    beforeValue*: string
    afterValue*: string

  FlowLoopInfo* = object
    ## One loop of the loaded flow window, as the backend describes it in
    ## `FlowViewUpdate.loops` (`src/db-backend/src/task.rs`).
    ##
    ## Only the fields the loop control needs are kept. `rrTicksForIterations`
    ## holds the trace tick of each iteration's loop HEADER, so it is a list of
    ## interval starts, not of positions the debugger stops on — see
    ## `flow_loop_math.activeIterationForTicks`.
    first*: int              ## First source line of the loop (its header).
    last*: int               ## Last source line of the loop body.
    registeredLine*: int     ## Line the loop control is attached to.
    rrTicksForIterations*: seq[int]

  FlowVM* = ref object of ViewModel
    ## Reactive state for the Flow panel.
    ##
    ## Mutable signals:
    ##   flowMode          — which flow mode is active
    ##   selectedIteration — index of the selected iteration
    ##   hoveredStep       — index of the step currently under the cursor
    ##   showRawValues     — whether to display raw (unformatted) values
    ##
    ## Derived memos:
    ##   isLoading         — whether a flow data request is in flight
    ##   totalIterations   — total number of iterations from the backend
    ##
    ## The store reference is kept for the auto-load effect and
    ## for navigation actions (click-step jump).
    store*: ReplayDataStore

    # -- Mutable state --
    flowMode*: Signal[FlowMode]
    selectedIteration*: Signal[int]
    hoveredStep*: Signal[Option[int]]
    showRawValues*: Signal[bool]

    # -- Internal state for flow data --
    # These are owned by the VM since ReplayDataStore does not yet
    # have a dedicated flow sub-store.
    iterationCount*: Signal[int]
    loadingState*: Signal[LoadingState]
    steps*: Signal[seq[FlowStepEntry]]

    # -- Loaded flow window (written by `applyFlowUpdate`) --
    loops*: Signal[seq[FlowLoopInfo]]
      ## Loops of the current window, index-aligned with the backend's
      ## `FlowViewUpdate.loops`. Entry 0 is the backend's placeholder
      ## `Loop::default()` and is never a real loop.
    focusedLoop*: Signal[int]
      ## Index into `loops` of the loop whose control is on screen, or -1
      ## when the window contains no loop.
    windowRRTicks*: Signal[int]
    appliedWindows*: int
      ## How many windows `applyFlowUpdate` has adopted. Not a signal: nothing
      ## renders it. The load effect compares it across a request to learn
      ## whether the `ct/updated-flow` EVENT already delivered this request's
      ## window, in which case the reply must not overwrite it.
    styledLines*: Signal[seq[FlowStyledLine]]
      ## PLAT-42 — what the flow can say about each SOURCE line of the window:
      ## `flskHit` (the line ran in this window) or `flskSkip` (it lies inside
      ## a branch arm that was not taken). Lines with no claim are absent.
      ##
      ## This is the per-line fact `PLAT22-PG2` said the ViewModel did not
      ## have. It was on the wire all along — `branchesTaken`, the function
      ## extent and `relevantStepCount` — and `applyFlowUpdate` discarded it,
      ## keeping only the loops.
      ## The debugger tick the current window was loaded for. This is the
      ## input the active iteration is derived from.

    # -- Derived state --
    isLoading*: Memo[bool]
    totalIterations*: Memo[int]

# ---------------------------------------------------------------------------
# The engine boundary
# ---------------------------------------------------------------------------

const
  UpdatedFlowCommandName* = "ct/updated-flow"
    ## The DAP event name the engine emits (`src/db-backend/src/dap.rs`).
  UpdatedFlowEventKind* = "CtUpdatedFlow"
    ## The same event as the legacy renderer's event-bus spells it, which is
    ## what `RealBackendService` puts in `kind`. Both are accepted because
    ## which one arrives depends on whether the backend-manager is in the
    ## path, and a panel that recognised only one would be silently empty
    ## against the other.

proc engineFlowModeWireName*(mode: FlowMode): string =
  ## Translate this panel's view granularity into the engine's `ct/load-flow`
  ## flow mode.
  ##
  ## The two vocabularies are genuinely different and always were: the panel
  ## has three rendering granularities, the engine has two query modes
  ## (`call`, `diff`). What made that a defect rather than a design was
  ## sending `$mode` — `"fmCall"` — at a field the engine reads as a mode
  ## selector. It rejected the string outright; had the wire form been the
  ## ordinal the two enums *looked* like they shared, `fmLine` would have
  ## arrived as `diff` and silently answered a different question.
  ##
  ## All three view granularities are call flow as far as the engine is
  ## concerned — they differ in how the returned steps are laid out, which
  ## is a rendering decision this panel makes locally. `diff` has no view
  ## granularity behind it yet and is reached from the legacy Karax editor.
  ##
  ## The `case` is exhaustive on purpose: a fourth `fm*` member will not
  ## compile until someone decides what it means to the engine, which is the
  ## whole point of routing the translation through one named proc.
  case mode
  of fmCall, fmLine, fmFunction:
    FlowModeWireCall

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setMode*(vm: FlowVM; mode: FlowMode) =
  ## Switch to a different flow mode. The auto-load effect will
  ## request new data because it depends on flowMode.
  vm.flowMode.val = mode

proc maxIteration*(vm: FlowVM): int =
  ## Highest selectable iteration index, or -1 when no loop is loaded.
  ##
  ## Single definition on purpose: the counter's total, the arrows' clamp and
  ## their end-stop state must all agree. `ui/flow.nim` has the matching
  ## `maxLoopIteration`.
  vm.totalIterations.val - 1

proc selectIteration*(vm: FlowVM; iteration: int) =
  ## Set the currently selected iteration index.
  ## Clamped to [0, totalIterations - 1].
  let maxIter = vm.maxIteration()
  if iteration < 0:
    vm.selectedIteration.val = 0
  elif maxIter >= 0 and iteration > maxIter:
    vm.selectedIteration.val = maxIter
  else:
    vm.selectedIteration.val = iteration

proc stepIterationForward*(vm: FlowVM) =
  ## The "next iteration" arrow of the loop control.
  ##
  ## Spec (`codetracer-specs/GUI/Debugging-Features/Omniscience-Flow.md`,
  ## "Loop Slider Control"): "Click arrows for previous/next" — one click is
  ## one iteration, never two (#595).
  vm.selectIteration(nextIteration(vm.selectedIteration.val, vm.maxIteration()))

proc stepIterationBackward*(vm: FlowVM) =
  ## The "previous iteration" arrow of the loop control. See above.
  vm.selectIteration(previousIteration(vm.selectedIteration.val, vm.maxIteration()))

proc hoverStep*(vm: FlowVM; step: Option[int]) =
  ## Set the currently hovered step. Pass `none(int)` to clear.
  vm.hoveredStep.val = step

proc clickStep*(vm: FlowVM; step: int) =
  ## Navigate to the source location of the given flow step.
  ## Sends a jump command to the backend.
  let args = %*{
    "step": step,
    "flowMode": $vm.flowMode.val,
    "iteration": vm.selectedIteration.val,
  }
  discard vm.store.backend.send("ct/flow-jump", args)

proc toggleRawValues*(vm: FlowVM) =
  ## Toggle whether raw (unformatted) values are shown.
  vm.showRawValues.val = not vm.showRawValues.val

proc setSteps*(vm: FlowVM; steps: openArray[FlowStepEntry]) =
  vm.steps.val = @steps

# ---------------------------------------------------------------------------
# Consuming the `ct/load-flow` response
# ---------------------------------------------------------------------------

proc jsonInt(node: JsonNode; fallback: int = 0): int =
  ## Tolerant integer read.
  ##
  ## The backend's `RRTicks`/`Position`/`Iteration` are newtype structs, which
  ## serde serialises transparently as bare numbers, but the DAP transport has
  ## historically also delivered them as strings on some hosts. Accept both
  ## rather than silently producing 0, which would look exactly like the bug
  ## this ViewModel exists to catch.
  if node.isNil:
    return fallback
  case node.kind
  of JInt: int(node.getBiggestInt)
  of JFloat: int(node.getFloat)
  of JString:
    try: parseInt(node.getStr) except ValueError: fallback
  else: fallback

proc parseFlowLoop(node: JsonNode): FlowLoopInfo =
  result = FlowLoopInfo(first: -1, last: -1, registeredLine: -1)
  if node.isNil or node.kind != JObject:
    return
  result.first = jsonInt(node{"first"}, -1)
  result.last = jsonInt(node{"last"}, -1)
  result.registeredLine = jsonInt(node{"registeredLine"}, -1)
  let ticks = node{"rrTicksForIterations"}
  if not ticks.isNil and ticks.kind == JArray:
    for tick in ticks:
      result.rrTicksForIterations.add(jsonInt(tick, 0))

proc pickFocusedLoop(loops: seq[FlowLoopInfo]): int =
  ## Index of the loop whose control the user sees, or -1.
  ##
  ## Index 0 is the backend's `Loop::default()` placeholder — `ui/flow.nim`'s
  ## `createLoopStates` skips it for the same reason. Among the rest, take the
  ## first that actually recorded iterations; a window with a single loop (the
  ## common case, and the one the loop-control specs exercise) therefore
  ## resolves unambiguously, and a window with none yields -1.
  for index in 1 ..< loops.len:
    if loops[index].rrTicksForIterations.len > 0:
      return index
  -1

type
  # A typed view of ONE flow window, holding exactly the fields
  # `flowStyledLines` reads. The wire's own type (`FlowViewUpdate`) is built on
  # `TableLike`, which is a JS object on the web backend; this view is what the
  # shared predicate is instantiated over on the native one. It is a second
  # SHAPE for the one rule's input, not a second rule.
  FlowLineExtent = object
    firstLine, lastLine: int
  FlowLineBranches = object
    table: Table[int, int]
    extents: Table[int, FlowLineExtent]
  FlowLineSpan = object
    functionFirst, functionLast: int
  FlowLineWindow = object
    location: FlowLineSpan
    branchesTaken: seq[seq[FlowLineBranches]]
    commentLines: seq[int]
    relevantStepCount: seq[int]

const NotTaken = 2
  ## `BranchState.NotTaken`'s ordinal on the wire (`Unknown, Taken, NotTaken`
  ## in `common_types/codetracer_features/flow.nim`). `insideUntakenBranch`
  ## names it through `mixin`, so this is the value it compares against here.
  ## `test_flow_line_facts.nim` asserts the ordinal against the enum itself, so
  ## a reordering of the enum fails a test rather than silently inverting
  ## which arms are dimmed.

const Taken = 1
  ## `BranchState.Taken`'s ordinal on the wire, the sibling of `NotTaken` above
  ## and named here for the same reason: `insideUntakenBranch` reaches it
  ## through `mixin`, so it has to be a symbol in THIS scope for the
  ## instantiation over `FlowLineWindow` to compile. It is read by the rule's
  ## "an arm entered anywhere outranks a sweep that says it was not" clause.
  ##
  ## Not having it here is a compile error and not a silent wrong answer:
  ## `nim js src/frontend/ui_js.nim` fails with *"undeclared identifier:
  ## 'Taken'"* pointing at `flow_line_rule.nim` from this file's instantiation.

const
  FlowWireNotTakenOrdinal* = NotTaken
    ## `NotTaken`, exported under a name that cannot capture the `mixin`, for
    ## the test that pins it.
  FlowWireTakenOrdinal* = Taken
    ## `Taken`, likewise. Pinned against the enum by `test_flow_line_facts.nim`,
    ## so a reordering of `BranchState` fails a test rather than quietly turning
    ## "this arm ran" into "this arm did not".

proc intKeyedTable[V](node: JsonNode; conv: proc (n: JsonNode): V): Table[int, V] =
  result = initTable[int, V]()
  if node.isNil or node.kind != JObject:
    return
  for k, v in node:
    try:
      result[parseInt(k)] = conv(v)
    except ValueError:
      discard  # a non-numeric key is not a line; the wire never sends one

proc intList(node: JsonNode): seq[int] =
  result = @[]
  if node.isNil or node.kind != JArray:
    return
  for n in node:
    if n.kind == JInt: result.add n.getInt

proc flowLineWindow(view: JsonNode): FlowLineWindow =
  ## Parse the fields `flowStyledLines` needs out of one wire view update.
  let loc = view{"location"}
  if not loc.isNil and loc.kind == JObject:
    result.location = FlowLineSpan(
      functionFirst: loc{"functionFirst"}.getInt(0),
      functionLast: loc{"functionLast"}.getInt(0))
  result.commentLines = intList(view{"commentLines"})
  result.relevantStepCount = intList(view{"relevantStepCount"})
  let bt = view{"branchesTaken"}
  if not bt.isNil and bt.kind == JArray:
    for group in bt:
      var row: seq[FlowLineBranches] = @[]
      if group.kind == JArray:
        for entry in group:
          row.add FlowLineBranches(
            table: intKeyedTable[int](entry{"table"},
              proc (n: JsonNode): int = n.getInt(0)),
            extents: intKeyedTable[FlowLineExtent](entry{"extents"},
              proc (n: JsonNode): FlowLineExtent =
                FlowLineExtent(firstLine: n{"firstLine"}.getInt(0),
                               lastLine: n{"lastLine"}.getInt(0))))
      result.branchesTaken.add row

proc flowLineFacts*(view: JsonNode): seq[FlowStyledLine] =
  ## The per-line facts of one wire view update, decided by the shared rule.
  ## Exported so a test can drive it with a real captured window.
  ##
  ## Two sources, one per kind of line, and neither is re-derived here:
  ##
  ##   * every line `flowStyledLines` classifies — the shared dimming rule;
  ##   * the arm HEADERS, which that rule deliberately skips because the
  ##     desktop editor paints them in a separate pass (`conditionStyleLines`).
  ##     A header whose state is `Taken` or `NotTaken` is a line whose test was
  ##     EVALUATED, so it ran — `GUI/Debugging-Features/Omniscience-Flow.md`
  ##     requires the header of a declined arm to stay undimmed for exactly
  ##     that reason. It is reported as `flskHit`. A header whose state is
  ##     `Unknown` carries no claim and is left out.
  ##
  ## Sorted by line, one entry per line.
  if view.isNil or view.kind != JObject:
    return @[]
  let window = flowLineWindow(view)
  result = flowStyledLines(window, finished = false)
  if window.branchesTaken.len > 0 and window.branchesTaken[0].len > 0:
    for header, state in window.branchesTaken[0][0].table:
      if state != 0 and header > window.location.functionFirst and
         header <= window.location.functionLast:
        result.add FlowStyledLine(position: header, kind: flskHit)
  result.sort(proc (a, b: FlowStyledLine): int = cmp(a.position, b.position))

proc flowValueText(value: JsonNode): string =
  ## One recorded value as the flow pane prints it: PLAT-2's pipeline at the
  ## flow surface's budget, so it reads as every other surface reads it.
  if value.isNil or value.kind == JNull: ""
  else: present(json_adapter.toPValue(value), FlowBudget).root.text

proc flowStepEntriesOf*(view: JsonNode): seq[FlowStepEntry] =
  ## The window's steps as the flow pane's rows: one row per step and
  ## expression, in the order the engine evaluated them (`exprOrder`), with the
  ## value before and after the step.
  if view.isNil or view.kind != JObject: return
  let steps = view{"steps"}
  if steps.isNil or steps.kind != JArray: return
  var file = ""
  let loc = view{"location"}
  if not loc.isNil and loc.kind == JObject:
    file = loc{"highLevelPath"}.getStr("")
    if file.len == 0: file = loc{"path"}.getStr("")
  let base = file[file.rfind('/') + 1 .. ^1]
  for st in steps:
    if st.kind != JObject: continue
    let line = jsonInt(st{"position"}, 0)
    let count = jsonInt(st{"stepCount"}, 0)
    let before = st{"beforeValues"}
    let after = st{"afterValues"}
    var order: seq[string] = @[]
    let orderNode = st{"exprOrder"}
    if not orderNode.isNil and orderNode.kind == JArray:
      for e in orderNode: order.add e.getStr("")
    if order.len == 0 and not after.isNil and after.kind == JObject:
      for k, _ in after: order.add k
      order.sort()
    for expr in order:
      if expr.len == 0: continue
      result.add FlowStepEntry(
        step: count,
        location: base & ":" & $line,
        expression: expr,
        beforeValue: flowValueText(if before.isNil: nil else: before{expr}),
        afterValue: flowValueText(if after.isNil: nil else: after{expr}))

proc applyFlowUpdate*(vm: FlowVM; response: JsonNode) =
  ## Adopt a `ct/load-flow` response.
  ##
  ## The critical line is the last one. A flow window is (re)loaded on every
  ## debugger move, and in the Karax UI a brand-new component is constructed
  ## for it, so whatever iteration the user had selected before the move is
  ## gone. If the new window is adopted without re-deriving the selection, the
  ## counter shows iteration 0 for as long as the session lasts however far
  ## into the loop the debugger actually is — issue #593 — and the next click
  ## on the "next" arrow computes `0 + 1` and jumps the user back to iteration
  ## 1 — issue #595. Re-deriving it from `location.rrTicks`, which the backend
  ## sends alongside the window, is what keeps the two in agreement.
  if response.isNil or response.kind != JObject:
    vm.loadingState.val = lsError
    return

  let viewUpdates = response{"viewUpdates"}
  if viewUpdates.isNil or viewUpdates.kind != JArray or viewUpdates.len == 0:
    vm.loadingState.val = lsError
    return

  # The backend returns one view update per `EditorView`; the source view is
  # first and is the only one the loop control is rendered on.
  let view = viewUpdates[0]

  var loops: seq[FlowLoopInfo] = @[]
  let loopsNode = view{"loops"}
  if not loopsNode.isNil and loopsNode.kind == JArray:
    for loopNode in loopsNode:
      loops.add(parseFlowLoop(loopNode))

  # `location` on the envelope is the debugger's position this window was
  # computed for; fall back to the view's own copy.
  var locationNode = response{"location"}
  if locationNode.isNil or locationNode.kind != JObject:
    locationNode = view{"location"}
  let ticks = jsonInt(if locationNode.isNil: nil else: locationNode{"rrTicks"}, 0)

  let focused = pickFocusedLoop(loops)

  vm.loops.val = loops
  vm.focusedLoop.val = focused
  vm.styledLines.val = flowLineFacts(view)
  # PLAT-41: THE STEPS ARE KEPT. The flow pane's rows are the window's own
  # steps, and until 2026-09-23 this function adopted the loops and the line
  # facts and dropped the steps on the floor, so the pane said "no flow steps
  # have been loaded" beside an editor drawing the same window's overlay.
  vm.steps.val = flowStepEntriesOf(view)
  vm.windowRRTicks.val = ticks
  vm.iterationCount.val =
    if focused >= 0: loops[focused].rrTicksForIterations.len else: 0
  vm.loadingState.val = lsIdle
  inc vm.appliedWindows

  if focused >= 0:
    vm.selectedIteration.val =
      activeIterationForTicks(loops[focused].rrTicksForIterations, ticks)
  else:
    vm.selectedIteration.val = 0

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createFlowVM*(store: ReplayDataStore): FlowVM =
  ## Create a FlowVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for `isLoading` and `totalIterations`
  ## 3. An auto-load effect that requests flow data when the debugger
  ##    location or flowMode changes
  withViewModel proc(dispose: proc()): FlowVM =
    let flowMode = createSignal(fmCall)
    let selectedIteration = createSignal(0)
    let hoveredStep = createSignal(none(int))
    let showRawValues = createSignal(false)

    # Internal flow state (not yet in ReplayDataStore).
    let iterationCount = createSignal(0)
    let loadingState = createSignal(lsIdle)
    let steps = createSignal(newSeq[FlowStepEntry]())
    let loops = createSignal(newSeq[FlowLoopInfo]())
    let focusedLoop = createSignal(-1)
    let windowRRTicks = createSignal(0)
    let styledLines = createSignal(newSeq[FlowStyledLine]())

    # Derived: loading indicator.
    let isLoading = createMemo[bool] proc(): bool =
      loadingState.val == lsLoading

    # Derived: total iterations from the internal state.
    let totalIterations = createMemo[int] proc(): int =
      iterationCount.val

    let vm = FlowVM(
      store: store,
      flowMode: flowMode,
      selectedIteration: selectedIteration,
      hoveredStep: hoveredStep,
      showRawValues: showRawValues,
      iterationCount: iterationCount,
      loadingState: loadingState,
      steps: steps,
      loops: loops,
      focusedLoop: focusedLoop,
      windowRRTicks: windowRRTicks,
      appliedWindows: 0,
      styledLines: styledLines,
      isLoading: isLoading,
      totalIterations: totalIterations,
      disposeProc: dispose,
    )

    # `ct/load-flow` answers with a queued `ct/updated-flow` EVENT
    # (`src/db-backend/src/dap.rs:329`), not with its reply. A panel that
    # consumed only the reply would stay empty forever against the real
    # engine while every mock-driven test passed — the same event-path
    # hazard the transport adapter hit. Subscribe here, using the same
    # `data`-or-bare envelope convention `replay_data_store
    # .installBackendEventHandlers` uses.
    block installFlowEventHandler:
      let vmRef = vm
      store.backend.onEvent proc(event: JsonNode) =
        if event.isNil or event.kind != JObject or not event.hasKey("kind"):
          return
        let kind = event["kind"].getStr
        if kind != UpdatedFlowEventKind and kind != UpdatedFlowCommandName:
          return
        let payload =
          if event.hasKey("data"): event["data"]
          else: event
        vmRef.applyFlowUpdate(payload)

    # Auto-load effect: whenever the debugger position or flow mode
    # changes, request fresh flow data from the backend.
    #
    # See the matching dedup in ``event_log_vm.nim`` for the rationale.
    #
    # THIS COMMENT USED TO SAY ``updateDebuggerPosition`` "reassigns
    # ``store.debugger`` without value equality". THAT IS FALSE, and it was
    # believed long enough to be quoted into a bug brief as though it were a
    # measurement. IsoNim's ``writeSignal`` (isonim/core/signals.nim) returns
    # early on ``state.value == value``, and ``DebuggerState`` is a plain
    # object, so a byte-identical reassignment notifies nobody — measured at
    # 145 identical writes re-running an effect exactly once, in
    # ``src/tests/gui/tests/state/state_render_storm_test.nim``, which exists
    # to keep that from being re-derived wrongly a third time.
    #
    # What the guard below is actually for: ``store.debugger`` is reassigned
    # once per panel per CtCompleteMove, and those writes are not all equal —
    # each panel syncs the position it saw, so location fields can differ at
    # one ``rrTicks``. Keying on the tick and the view mode collapses that to
    # one request. Without it ``ct/load-flow`` is issued several times per
    # move, which is
    # both wasteful and (in combination with the ``fmCall`` JSON-arg
    # mismatch the backend currently rejects) noisy in the host logs.
    var lastTicks: uint64 = 0
    var lastMode = ""
    var hasFired = false
    createEffect proc() =
      let ticks = store.debugger.val.rrTicks
      let mode = flowMode.val
      # Two different strings, deliberately.
      #
      # `wireMode` is the engine's vocabulary — see
      # `engineFlowModeWireName`. All three view granularities map to
      # `call`, because that is genuinely the same query.
      #
      # `viewMode` is this panel's, and it is what the dedup keys on. Keying
      # the dedup on the wire name instead would silently stop re-requesting
      # when the user switched granularity, which is a behaviour change this
      # fix has no business making.
      let wireMode = engineFlowModeWireName(mode)
      let viewMode = $mode
      if ticks > 0'u64:
        if hasFired and ticks == lastTicks and viewMode == lastMode:
          return
        lastTicks = ticks
        lastMode = viewMode
        hasFired = true
        # `CtLoadFlowArguments` (src/db-backend/src/task.rs) requires
        # `flowMode` and `location`; `rrTicks` is not a field it reads, it
        # lives inside `location`. Sending the tick at the top level and no
        # location at all is why this request never once succeeded.
        let position = store.debugger.val.location
        let args = %*{
          "flowMode": wireMode,
          "location": {
            "path": position.file,
            "line": position.line,
            "rrTicks": ticks,
            "callstackDepth": position.callstackDepth,
          },
        }
        loadingState.val = lsLoading
        # Consume the response. Firing the request and dropping the reply is
        # what made every loop-iteration assertion at this layer vacuous; see
        # the module header.
        let appliedBefore = vm.appliedWindows
        let future = store.backend.send("ct/load-flow", args)
        let vmRef = vm
        onComplete(future,
          proc(response: JsonNode) =
            # The reply is only *sometimes* the window. `ct/load-flow`'s real
            # answer is the queued `ct/updated-flow` event (dap.rs:329); the
            # backend-manager converts that event into a response for some
            # deployments (backend_manager.rs:1001), so both paths must feed
            # the same applier. Consuming only the reply is how a panel ends
            # up permanently empty against the engine while its tests pass.
            #
            # BUT NOT BOTH FOR ONE REQUEST. A synchronous transport (the
            # native hosts' stdio adapter) delivers the event before the reply
            # completes, and a reply adopted after it would replace the real
            # window with whatever the reply carries — or, when the reply is a
            # bare DAP envelope, flip a loaded panel to `lsError`.
            if vmRef.appliedWindows != appliedBefore:
              return
            # A DAP envelope carries the window under `body`.
            let window =
              if not response.isNil and response.kind == JObject and
                 response{"viewUpdates"}.isNil and
                 not response{"body"}.isNil: response["body"]
              else: response
            vmRef.applyFlowUpdate(window),
          proc(message: string) =
            # A failed flow load must not leave the panel claiming to still be
            # loading forever, and must not leave a stale window's loop shape
            # in place attributed to the new position.
            vmRef.loops.val = @[]
            vmRef.focusedLoop.val = -1
            vmRef.iterationCount.val = 0
            vmRef.loadingState.val = lsError)

    vm
