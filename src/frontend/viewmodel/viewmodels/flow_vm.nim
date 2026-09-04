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

import std/[json, options, strutils]

import isonim/core/[signals, computation, owner, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

# The iteration arithmetic is shared verbatim with the legacy Karax loop
# control in `ui/flow.nim`, so that both surfaces can never disagree about
# which iteration a tick belongs to. `flow_loop_math` imports nothing and
# compiles on both backends; see its header.
import ../../ui/flow_loop_math

# The `ct/load-flow` wire vocabulary, shared with the engine. A leaf module
# with no imports, exactly so both this layer and `common_types` can hold the
# same strings; see its header for why the wire form is a name.
import ../../../common/flow_mode_wire
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
  vm.windowRRTicks.val = ticks
  vm.iterationCount.val =
    if focused >= 0: loops[focused].rrTicksForIterations.len else: 0
  vm.loadingState.val = lsIdle

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
            vmRef.applyFlowUpdate(response),
          proc(message: string) =
            # A failed flow load must not leave the panel claiming to still be
            # loading forever, and must not leave a stale window's loop shape
            # in place attributed to the new position.
            vmRef.loops.val = @[]
            vmRef.focusedLoop.val = -1
            vmRef.iterationCount.val = 0
            vmRef.loadingState.val = lsError)

    vm
