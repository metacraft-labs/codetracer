## viewmodels/debug_controls_vm.nim
##
## DebugControlsVM — ViewModel for the debug control toolbar.
##
## This VM is mostly derived (memos) — it reads the debugger state from
## the store and exposes convenient booleans and text for the UI.
## Action procs delegate to `store.requestStep`.
##
## Holds no mutable signals of its own; everything is derived from
## the store's debugger and timeline signals.
##
## Derives:
## - `canStepForward`: whether a forward step is possible
## - `canStepBackward`: whether a backward step is possible
## - `canContinue`: whether continue / reverse-continue is possible
## - `isRunning`: whether the debugger is currently stepping or running
## - `statusText`: human-readable debugger status string
##
## Usage:
##   let vm = createDebugControlsVM(store)
##   echo vm.statusText.val      # "Idle"
##   vm.stepForward()
##   echo vm.isRunning.val       # true (while stepping)

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

type
  DebugControlsVM* = ref object of ViewModel
    ## Reactive state for the debug control toolbar.
    ##
    ## Derived memos:
    ##   canStepForward   — whether a forward step is allowed
    ##   canStepBackward  — whether a backward step is allowed
    ##   canContinue      — whether continue/reverse-continue is allowed
    ##   isRunning        — whether the debugger is mid-step or running
    ##   statusText       — human-readable status string
    ##
    ## The store reference is used for reading debugger state and
    ## issuing step commands.
    store*: ReplayDataStore

    # -- Derived state (all memos) --
    canStepForward*: Memo[bool]
    canStepBackward*: Memo[bool]
    canContinue*: Memo[bool]
    isRunning*: Memo[bool]
    statusText*: Memo[string]

    # -- Legacy bridge callbacks --
    # These are set by the Karax debug component to delegate stepping
    # to the existing DAP-based event mediator, which is the only path
    # that actually reaches the replay backend today.
    # When the new ct/step backend path is wired end-to-end, these
    # callbacks can be removed and the VM action procs used directly.
    onDapStep*: proc(action: cstring)
      ## Called by IsoNim view buttons for DAP-based step actions.
      ## Maps to `dapStep(api, action)` in the legacy system.
    onAction*: proc(action: string)
      ## Called by IsoNim view buttons for non-step actions
      ## (e.g. "run-to-entry", "reset-operation", "history-back").
      ## Maps to `DebugComponent.action(id)` in the legacy system.

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc stepForward*(vm: DebugControlsVM) =
  ## Issue a forward step command if the debugger is in a steppable state.
  if vm.canStepForward.val:
    vm.store.requestStep(sdForward)

proc stepBackward*(vm: DebugControlsVM) =
  ## Issue a backward step command if the debugger is in a steppable state.
  if vm.canStepBackward.val:
    vm.store.requestStep(sdBackward)

proc stepIn*(vm: DebugControlsVM) =
  ## Issue a step-in command if the debugger is in a steppable state.
  if vm.canStepForward.val:
    vm.store.requestStep(sdStepIn)

proc stepOut*(vm: DebugControlsVM) =
  ## Issue a step-out command if the debugger is in a steppable state.
  if vm.canStepForward.val:
    vm.store.requestStep(sdStepOut)

proc continueExecution*(vm: DebugControlsVM) =
  ## Issue a continue command if the debugger is in a continuable state.
  if vm.canContinue.val:
    vm.store.requestStep(sdContinue)

proc reverseContinue*(vm: DebugControlsVM) =
  ## Issue a reverse-continue command if the debugger is in a continuable state.
  if vm.canContinue.val:
    vm.store.requestStep(sdReverseContinue)

proc reverseStepIn*(vm: DebugControlsVM) =
  ## Issue a reverse step-in command if backward stepping is possible.
  if vm.canStepBackward.val:
    vm.store.requestStep(sdReverseStepIn)

proc reverseStepOut*(vm: DebugControlsVM) =
  ## Issue a reverse step-out command if backward stepping is possible.
  if vm.canStepBackward.val:
    vm.store.requestStep(sdReverseStepOut)

proc invokeToolbarStep*(vm: DebugControlsVM; actionId: string) =
  ## Dispatch a production toolbar step action.
  ##
  ## The legacy DAP bridge is still the preferred route because it also emits
  ## operation-status events.  If the bridge is not installed yet, fall back to
  ## the shared ReplayDataStore backend so the button still reaches DAP.
  if not vm.onDapStep.isNil:
    vm.onDapStep(cstring(actionId))
    return

  case actionId
  of "next": vm.stepForward()
  of "reverse-next": vm.stepBackward()
  of "step-in": vm.stepIn()
  of "step-out": vm.stepOut()
  of "continue": vm.continueExecution()
  of "reverse-continue": vm.reverseContinue()
  of "reverse-step-in": vm.reverseStepIn()
  of "reverse-step-out": vm.reverseStepOut()
  else: discard

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createDebugControlsVM*(store: ReplayDataStore): DebugControlsVM =
  ## Create a DebugControlsVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up derived memos that read the store's debugger and timeline
  ## signals to determine which actions are available and what the
  ## current status text should be.
  withViewModel proc(dispose: proc()): DebugControlsVM =

    # Derived: the debugger can step forward when it is idle and has
    # not finished the recording.
    let canStepForward = createMemo[bool] proc(): bool =
      let dbg = store.debugger.val
      dbg.status in {dsIdle}

    # Derived: the debugger can step backward when it is idle and
    # the current position is past the start of the timeline.
    let canStepBackward = createMemo[bool] proc(): bool =
      let dbg = store.debugger.val
      let tl = store.timeline.val
      dbg.status == dsIdle and dbg.rrTicks > tl.minRRTicks

    # Derived: continue is possible when the debugger is idle.
    let canContinue = createMemo[bool] proc(): bool =
      let dbg = store.debugger.val
      dbg.status == dsIdle

    # Derived: the debugger is running if it is stepping or running.
    let isRunning = createMemo[bool] proc(): bool =
      let dbg = store.debugger.val
      dbg.status in {dsStepping, dsRunning}

    # Derived: human-readable status text.
    let statusText = createMemo[string] proc(): string =
      let dbg = store.debugger.val
      case dbg.status
      of dsIdle:     "Idle"
      of dsStepping: "Stepping..."
      of dsRunning:  "Running..."
      of dsFinished: "Finished"
      of dsError:    "Error"

    DebugControlsVM(
      store: store,
      canStepForward: canStepForward,
      canStepBackward: canStepBackward,
      canContinue: canContinue,
      isRunning: isRunning,
      statusText: statusText,
      disposeProc: dispose,
    )
