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
## backend whenever the debugger location or flowMode changes.
##
## Usage:
##   let vm = createFlowVM(store)
##   echo vm.flowMode.val          # fmCall
##   vm.setMode(fmLine)
##   echo vm.totalIterations.val   # derived from store data

import std/[json, options]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  FlowMode* = enum
    ## The three flow visualisation modes.
    fmCall      ## Show flow at the call level
    fmLine      ## Show flow at the line level
    fmFunction  ## Show flow at the function level

  FlowStepEntry* = object
    step*: int
    location*: string
    expression*: string
    beforeValue*: string
    afterValue*: string

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

    # -- Derived state --
    isLoading*: Memo[bool]
    totalIterations*: Memo[int]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setMode*(vm: FlowVM; mode: FlowMode) =
  ## Switch to a different flow mode. The auto-load effect will
  ## request new data because it depends on flowMode.
  vm.flowMode.val = mode

proc selectIteration*(vm: FlowVM; iteration: int) =
  ## Set the currently selected iteration index.
  ## Clamped to [0, totalIterations - 1].
  let maxIter = vm.totalIterations.val - 1
  if iteration < 0:
    vm.selectedIteration.val = 0
  elif maxIter >= 0 and iteration > maxIter:
    vm.selectedIteration.val = maxIter
  else:
    vm.selectedIteration.val = iteration

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
      isLoading: isLoading,
      totalIterations: totalIterations,
      disposeProc: dispose,
    )

    # Auto-load effect: whenever the debugger position or flow mode
    # changes, request fresh flow data from the backend.
    createEffect proc() =
      let ticks = store.debugger.val.rrTicks
      let mode = flowMode.val
      if ticks > 0'u64:
        let args = %*{
          "rrTicks": ticks,
          "flowMode": $mode,
        }
        discard store.backend.send("ct/load-flow", args)

    vm
