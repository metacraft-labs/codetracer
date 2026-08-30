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
## Degraded state (Page-Descriptions.md §14) — this pane is the debugger's
## chrome, so it owns the rows that are about the debugger as a whole:
## - `degradedState`: resolved against `DebugControlsPaneDegradations`
## - `replayUsable`: gates every `can*` memo, so a replay that cannot run
##   never offers a button that cannot succeed
## - `capabilityRung`: §14.2's ladder as a value
## - `divergenceDetected` / `traceTruncated`: the two §14 banners, readable
##   even when a more severe row resolved ahead of them
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
    canReverseContinue*: Memo[bool]
    isRunning*: Memo[bool]
    statusText*: Memo[string]
    toolbarModeText*: Memo[string]
    recordingHeadText*: Memo[string]
    showRecordingHead*: Memo[bool]
    showJumpToLive*: Memo[bool]
    canJumpToLive*: Memo[bool]

    # -- Degraded state (Page-Descriptions.md §14) --
    degradedState*: Memo[PaneDegradation]
      ## Resolved against `DebugControlsPaneDegradations`. This pane is
      ## the debugger's chrome, so it owns both of §14's banners — the
      ## truncation banner "in the debugger" and the divergence banner
      ## "above the debugger" — and it is the pane that has to refuse to
      ## step when there is nothing to step through.
    replayUsable*: Memo[bool]
      ## Whether a replay engine can actually move this session. False
      ## for §14.1a's expired window, for its terminal unreplayable
      ## state, and for every §14.2 capability failure.
      ##
      ## Every `can*` memo below is gated on it. §14's rule that a
      ## terminal state must never be "a retry that cannot succeed" is
      ## a statement about buttons: a step button that is enabled over a
      ## replay that cannot run *is* that retry.
    capabilityRung*: Memo[CapabilityRung]
      ## §14.2's ladder as a value — which fallback the consumer should
      ## offer instead of the debugger. `crFullDebugger` means none.
    divergenceDetected*: Memo[bool]
      ## §14's divergence row is non-dismissible and must be visible even
      ## when a more severe degradation resolved ahead of it, so it is
      ## exposed alongside `degradedState` rather than only through it.
    traceTruncated*: Memo[bool]
      ## Likewise: §14's truncation banner offers "the option to request
      ## a deeper profile", which stays meaningful under a divergence
      ## banner that outranks it in `degradedState`.

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
  if vm.canReverseContinue.val:
    vm.store.requestStep(sdReverseContinue)

proc reverseStepIn*(vm: DebugControlsVM) =
  ## Issue a reverse step-in command if backward stepping is possible.
  if vm.canStepBackward.val:
    vm.store.requestStep(sdReverseStepIn)

proc reverseStepOut*(vm: DebugControlsVM) =
  ## Issue a reverse step-out command if backward stepping is possible.
  if vm.canStepBackward.val:
    vm.store.requestStep(sdReverseStepOut)

proc restoreAt*(vm: DebugControlsVM; rrTicks: uint64) =
  ## Restore a live MCR session into recorded history.
  vm.store.requestRestoreAt(rrTicks)

proc jumpToLive*(vm: DebugControlsVM) =
  ## Restore to the current live recording head.
  if vm.canJumpToLive.val:
    vm.store.jumpToLive()

proc liveToolbarActionAllowed(actionId: string): bool =
  actionId in ["next", "step-in", "step-out", "continue"]

proc invokeToolbarStep*(vm: DebugControlsVM; actionId: string) =
  ## Dispatch a production toolbar step action.
  ##
  ## The legacy DAP bridge is still the preferred route because it also emits
  ## operation-status events.  If the bridge is not installed yet, fall back to
  ## the shared ReplayDataStore backend so the button still reaches DAP.
  if vm.store.session.val.debugSessionMode == liveMcr:
    if actionId.liveToolbarActionAllowed and
        (if actionId == "continue": vm.canContinue.val else: vm.canStepForward.val):
      vm.store.requestLiveToolbarAction(actionId)
    return

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

    # Derived: the §14 degraded state this pane renders, and the three
    # projections of it the toolbar needs. Declared first because every
    # `can*` memo below reads `replayUsable`.
    let degradedState = createMemo[PaneDegradation] proc(): PaneDegradation =
      resolveDegradation(store.degradedSnapshot(), DebugControlsPaneDegradations)

    let replayUsable = createMemo[bool] proc(): bool =
      let snapshot = store.degradedSnapshot()
      not (snapshot.degradationPresent(pdPermanentlyUnreplayable) or
           snapshot.degradationPresent(pdReplayWindowExpired) or
           snapshot.degradationPresent(pdEngineUnavailable))

    let capabilityRung = createMemo[CapabilityRung] proc(): CapabilityRung =
      capabilityRung(store.degraded.capability.val)

    let divergenceDetected = createMemo[bool] proc(): bool =
      store.degraded.integrity.val == tiDivergent

    let traceTruncated = createMemo[bool] proc(): bool =
      store.degraded.integrity.val == tiTruncated

    # Derived: the debugger can step forward when it is idle and has
    # not finished the recording.
    let canStepForward = createMemo[bool] proc(): bool =
      let dbg = store.debugger.val
      replayUsable.val and dbg.status in {dsIdle}

    # Derived: whether this session can navigate backward at all. The
    # debugger must be idle, the session must not be tracking a live
    # recording head, and backward navigation must be available — which
    # it is when:
    #   * the backend explicitly advertised it (`supportsStepBack`, from the DAP
    #     initialize capabilities), or
    #   * the current position is past the start of the timeline
    #     (`rrTicks > minRRTicks`), or
    #   * this is a *completed* (non-live) replay — a recorded DB/materialized
    #     trace is inherently time-travellable, so backward navigation is always
    #     supported regardless of whether the `supportsStepBack` capability made
    #     it through in time (it can be dropped when the DAP initialize response
    #     races session-VM creation) and regardless of whether `rrTicks` is
    #     tracked for this backend (DB traces do not populate rr ticks). This
    #     keeps the reverse-step buttons enabled on completed Noir/DB replays,
    #     where they were wrongly disabled.
    #
    # ONE predicate, used by every backward control.
    #
    # It was two. `canStepBackward` grew the `completedReplay` clause
    # above; `canReverseContinue` was left asking for `supportsStepBack`
    # and nothing else, even though the change that introduced the clause
    # names "reverse step-over / step-in / step-out / continue" as the
    # buttons it was fixing. The result was the reported bug surviving in
    # exactly one of the four: on a completed replay whose DAP
    # `initialize` response lost the race with session-VM creation —
    # the race that motivated the clause — reverse-step became enabled
    # and reverse-continue stayed greyed out.
    #
    # Keeping the rule in one memo is what stops the two from drifting
    # apart again; they are not independently tunable policies, they are
    # the same question ("can this session go backwards at all?") asked
    # by different buttons.
    let backwardNavigationAvailable = createMemo[bool] proc(): bool =
      let dbg = store.debugger.val
      let tl = store.timeline.val
      let session = store.session.val
      replayUsable.val and
        session.debugSessionMode notin {liveMcr, liveMaterialized} and
        dbg.status == dsIdle and
        (session.supportsStepBack or
          session.debugSessionMode == completedReplay or
          dbg.rrTicks > tl.minRRTicks)

    let canStepBackward = createMemo[bool] proc(): bool =
      backwardNavigationAvailable.val

    # Derived: continue is possible when the debugger is idle.
    let canContinue = createMemo[bool] proc(): bool =
      let dbg = store.debugger.val
      replayUsable.val and dbg.status == dsIdle

    let canReverseContinue = createMemo[bool] proc(): bool =
      backwardNavigationAvailable.val

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

    let toolbarModeText = createMemo[string] proc(): string =
      case store.session.val.debugSessionMode
      of completedReplay: ""
      of liveMcr: "Live MCR"
      of liveMaterialized: "Live recording"
      of historicalFromLive: "Historical replay"

    let recordingHeadText = createMemo[string] proc(): string =
      let session = store.session.val
      if session.recordingHeadLoadingState == lsLoading:
        "Head: loading"
      elif session.recordingHeadLoadingState == lsError:
        "Head: error"
      else:
        "Head: " & $session.recordingHeadRRTicks

    let showRecordingHead = createMemo[bool] proc(): bool =
      store.session.val.debugSessionMode in {
        liveMcr,
        liveMaterialized,
        historicalFromLive,
      }

    let showJumpToLive = createMemo[bool] proc(): bool =
      store.session.val.debugSessionMode == historicalFromLive

    let canJumpToLive = createMemo[bool] proc(): bool =
      let session = store.session.val
      let dbg = store.debugger.val
      replayUsable.val and
        session.debugSessionMode == historicalFromLive and
        session.recordingHeadLoadingState != lsLoading and
        session.recordingHeadLoadingState != lsError and
        session.recordingHeadRRTicks > 0'u64 and
        dbg.status == dsIdle

    DebugControlsVM(
      store: store,
      canStepForward: canStepForward,
      canStepBackward: canStepBackward,
      canContinue: canContinue,
      canReverseContinue: canReverseContinue,
      isRunning: isRunning,
      statusText: statusText,
      toolbarModeText: toolbarModeText,
      recordingHeadText: recordingHeadText,
      showRecordingHead: showRecordingHead,
      showJumpToLive: showJumpToLive,
      canJumpToLive: canJumpToLive,
      degradedState: degradedState,
      replayUsable: replayUsable,
      capabilityRung: capabilityRung,
      divergenceDetected: divergenceDetected,
      traceTruncated: traceTruncated,
      disposeProc: dispose,
    )
