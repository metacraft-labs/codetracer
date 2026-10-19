## viewmodels/debug_controls_vm.nim
##
## DebugControlsVM — ViewModel for the debug control toolbar.
##
## This VM is mostly derived (memos) — it reads the debugger state from
## the store and exposes convenient booleans and text for the UI.
## Action procs delegate to `store.requestStep`.
##
## Its own state is what the toolbar remembers beyond the debugger's
## position, for every front-end alike (Shared-DOM-Front-Ends D7.1): the jump
## history and its cursor, the open history list, whether a test run is
## pending, and the toolbar surface the layout mode selects. Everything else
## is derived from the store's debugger and timeline signals.
##
## Actions go to the backend through `DebugCommands`, handed in at
## construction (D6): a host never assigns a callback onto the VM afterwards.
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

import std/[json, options]

import isonim/core/[signals, computation, owner, batch]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types, stop_timeline]
import ./history_cursor
from ./edit_mode_toolbar import EditToolbarModel, ToolbarMode, TopbarSurface,
  topbarSurface, DebugMode
export history_cursor

const
  HistoryJumpOperation* = "history-jump"
    ## `pendingOperation` while a history jump's move is in flight: the move
    ## it makes is not recorded.

type
  DebugCommands* = object
    ## What the toolbar asks the backend (or the host) to do. Built by whoever
    ## builds the session — `defaultDebugCommands` over the session's
    ## `BackendService`, with a host's own entries where only the host can do
    ## the thing — and handed to `createDebugControlsVM`. A nil entry is an
    ## action this host does not offer; its button is unavailable.
    step*: proc(actionId: string)
      ## A step or continue, by its toolbar id (`next`, `step-in`, …).
    runToEntry*: proc()
    reset*: proc()
      ## Restart the replay (the desktop restarts its replay server).
    stop*: proc()
    runTests*: proc(done: proc(succeeded: bool))
      ## Start the tests of the file the debugger is in; call `done` when the
      ## run finishes, however it finishes.
    historyJump*: proc(entry: JumpEntry)
      ## Go to a position of the jump history.

  JumpEntry* = object
    ## One position the user has been at, as the jump history holds it.
    location*: Location
    rrTicks*: uint64
    lastOperation*: string
      ## What moved the debugger here (`next`, `run-to-entry`, …); "" when
      ## nothing the toolbar issued did.

  HistoryListKind* = enum
    ## Which jump-history list is open (`jump-before` / `jump-after`).
    hlNone
    hlBefore
      ## The entries older than the cursor, most recent first.
    hlAfter
      ## The entries newer than the cursor, oldest first.

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

    commands*: DebugCommands
      ## The actions' route to the backend; set at construction.

    # -- Jump history (the GUI's, now every front-end's) --
    history*: Signal[seq[JumpEntry]]
      ## Every position the debugger stopped at, oldest first. A move made by
      ## a history jump is not recorded; a move made while the cursor is back
      ## in the history first drops the entries newer than the cursor, as a
      ## browser does.
    historyIndex*: Signal[int]
      ## The cursor, counted back from the newest entry: 1 is `history[^1]`
      ## (`history_cursor.nextHistoryIndex`'s convention).
    canGoBack*: Memo[bool]
    canGoForward*: Memo[bool]
    historyList*: Signal[HistoryListKind]
      ## The open history list (`jump-before` / `jump-after`), or `hlNone`.
    historyListEntries*: Memo[seq[JumpEntry]]
      ## The open list's entries, in the order the list shows them.
    pendingOperation*: string
      ## The toolbar action whose move has not arrived yet; recorded on the
      ## history entry that move creates.

    # -- Test runs --
    runTestsPending*: Signal[bool]
      ## A test run started from the toolbar has not finished. Cleared by the
      ## run's own completion (`DebugCommands.runTests`' callback).

    # -- Which surface the toolbar host carries --
    toolbarMode*: Signal[ToolbarMode]
      ## The layout mode the host is in; set by the host on every mode change.
    editToolbar*: Signal[Option[EditToolbarModel]]
      ## The edit-mode toolbar a platform composed, or none when none was
      ## installed (the debugger controls then stay in every mode).
    editToolbarInvoke*: proc(id: string)
      ## The edit-mode toolbar's action route, installed with its model.
    topbarSurface*: Memo[TopbarSurface]
      ## What the toolbar host shows: the debugger controls or the edit-mode
      ## commands (`edit_mode_toolbar.topbarSurface`).

    # -- Keyboard-chord lookup, for the toolbar tooltips --
    #
    # A THIRD BRIDGE CALLBACK, and for the reason the two above exist. The
    # chords live in `data.config.shortcutMap`, whose `Config` is
    # `frontend/types.nim`'s JS-flavoured ref object; `store/types.nim:3-8`
    # states the layering rule this VM keeps — "intentionally independent of
    # the legacy frontend types to avoid circular imports and keep the
    # ViewModel layer self-contained" — and importing it here would also break
    # the `vm-native` lane outright, since `frontend/types.nim` pulls in
    # kdom. So the host injects a plain `proc(string): string`, exactly as it
    # injects `onDapStep` / `onAction`.
    shortcutFor*: proc(actionId: string): string
      ## Returns the keyboard chord currently bound to a toolbar action id
      ## ("next", "run-to-entry", …), rendered the way `menu.nim`'s
      ## `loadShortcut` renders it, or "" when nothing is bound.
      ##
      ## Nil until `ui/debug.nim` wires it. Nil and "" are the same answer —
      ## a tooltip with no chord in it — so no caller needs to distinguish.
    shortcutsRevision*: Signal[int]
      ## Bumped by the host whenever `shortcutFor` starts answering
      ## differently — i.e. when a new `Config` is installed.
      ##
      ## THE ONE MUTABLE SIGNAL THIS VM OWNS, against the "holds no mutable
      ## signals of its own" note at the top of this file, and it earns the
      ## exception: `shortcutFor` is an opaque closure over `data.config`, so
      ## the reactive graph cannot see through it to the config it reads.
      ## Without a signal to depend on, `toolbarTooltip`'s render effect would
      ## run once at mount and then never again, and a rebind would leave the
      ## painted tooltip showing the OLD chord — the same stale-label defect
      ## as the hardcoded strings this replaces, just with a longer fuse.

# ---------------------------------------------------------------------------
# Tooltip text
# ---------------------------------------------------------------------------

func tooltipText*(label, chord: string): string =
  ## THE one shape of a debugger control's tooltip (PLAT-49 finding 5): its
  ## label, and the key bound to it in parentheses — or the bare label when
  ## nothing is bound (never an empty pair of parentheses). The desktop's
  ## toolbar tooltip, GPUI's hover popover and the terminal's hover label all
  ## render this string; only WHERE they draw it is theirs.
  if chord.len == 0: label else: label & " (" & chord & ")"

proc toolbarTooltip*(vm: DebugControlsVM; actionId, label: string): string =
  ## The text of one toolbar button's tooltip: its label, plus the chord that
  ## is bound to it RIGHT NOW, in parentheses.
  ##
  ## THE POINT OF THIS PROC IS THAT THE CHORD IS READ, NOT WRITTEN. The
  ## toolbar used to carry `text "Next (F10)"` — a string literal, which
  ## `isonim/dsl/transform.nim`'s `isDynamic` classifies as STATIC, so it was
  ## painted once and could never change. It agreed with
  ## `default_config.yaml` only by coincidence and only until somebody
  ## rebound the key, at which point the toolbar would have gone on promising
  ## a chord that no longer did anything.
  ##
  ## Called from inside `ui()`, where it is a CALL and therefore `isDynamic`,
  ## so the DSL wraps it in a `createRenderEffect`. Reading
  ## `shortcutsRevision` here is what puts this effect in the reactive graph:
  ## bump the signal and every tooltip repaints from the new bindings.
  ##
  ## An unbound control gets its bare label rather than an empty pair of
  ## parentheses — the honest rendering of "no chord", and the same thing
  ## `menu.nim`'s `loadShortcut` does by returning "".
  discard vm.shortcutsRevision.val
  let chord =
    if vm.shortcutFor.isNil: ""
    else: vm.shortcutFor(actionId)
  tooltipText(label, chord)

# ---------------------------------------------------------------------------
# The transport strip
# ---------------------------------------------------------------------------

const TransportActions* = [
  ("reverse-next", "Reverse next"),
  ("next", "Next"),
  ("reverse-step-in", "Reverse step in"),
  ("step-in", "Step in"),
  ("reverse-step-out", "Reverse step out"),
  ("step-out", "Step out"),
  ("reverse-continue", "Reverse continue"),
  ("continue", "Continue"),
  ("run-to-entry", "Run to entry")]
  ## **The debugger's transport actions, in the desktop toolbar's order, with
  ## its labels** (`views/isonim_debug_controls_view`), named once so every
  ## front-end offers the same set (PLAT-41's DIFF-10). The ids are the ones
  ## `invokeToolbarStep` dispatches on.

func transportLabel*(actionId: string): string =
  ## A transport action's label (`TransportActions`), or the id itself.
  for (id, label) in TransportActions:
    if id == actionId:
      return label
  actionId

func transportTooltip*(actionId, chord: string): string =
  ## A transport action's tooltip — `tooltipText` over its label — for the
  ## front-ends that hold the chord themselves (the terminal's keymap, GPUI's
  ## desktop bindings) rather than in this ViewModel's `shortcutFor`.
  tooltipText(transportLabel(actionId), chord)

proc toolbarTooltip*(vm: DebugControlsVM; actionId: string): string =
  ## A TRANSPORT control's tooltip with its label from `TransportActions` —
  ## what the desktop's toolbar renders (PLAT-49: the label as well as the
  ## chord comes from this ViewModel, not from the view).
  vm.toolbarTooltip(actionId, transportLabel(actionId))

proc transportAvailable*(vm: DebugControlsVM; actionId: string): bool =
  ## Whether a transport action is legal at this stop — the desktop toolbar's
  ## rule, read from the ViewModel's own memos: forward motions on
  ## `canStepForward`, backward ones on `canStepBackward`, the two continues on
  ## their own, and run-to-entry always.
  case actionId
  of "next", "step-in", "step-out": vm.canStepForward.val
  of "reverse-next", "reverse-step-in", "reverse-step-out": vm.canStepBackward.val
  of "continue": vm.canContinue.val
  of "reverse-continue": vm.canReverseContinue.val
  else: true

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

  if not vm.commands.step.isNil:
    vm.pendingOperation = actionId
    vm.commands.step(actionId)
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
# Jump history
# ---------------------------------------------------------------------------

proc recordStop*(vm: DebugControlsVM; location: Location; rrTicks: uint64) =
  ## Record the debugger's arrival at a stop, with the desktop's rules
  ## (`DebugComponent.onCompleteMove` before this VM held the history): the
  ## same position twice is one entry; a move a history jump made is not
  ## recorded; a move made while the cursor is back in the history drops the
  ## entries newer than the cursor first.
  var entries = vm.history.val
  if entries.len > 0 and entries[^1].rrTicks == rrTicks and
     entries[^1].location == location:
    vm.pendingOperation = ""
    return
  if vm.pendingOperation == HistoryJumpOperation:
    vm.pendingOperation = ""
    return
  let cursor = vm.historyIndex.val
  if cursor > 1 and entries.len >= cursor:
    entries.setLen(entries.len - cursor + 1)
  entries.add JumpEntry(location: location, rrTicks: rrTicks,
                        lastOperation: vm.pendingOperation)
  vm.pendingOperation = ""
  vm.history.val = entries
  vm.historyIndex.val = 1

proc resetHistory*(vm: DebugControlsVM) =
  ## Forget the history (a restarted replay starts a new one).
  vm.history.val = newSeq[JumpEntry]()
  vm.historyIndex.val = 1
  vm.historyList.val = hlNone
  vm.pendingOperation = ""

proc jumpToHistoryIndex(vm: DebugControlsVM; index: int) =
  let entries = vm.history.val
  if index < 1 or index > entries.len or vm.commands.historyJump.isNil:
    return
  vm.historyIndex.val = index
  vm.pendingOperation = HistoryJumpOperation
  vm.commands.historyJump(entries[^index])

proc moveInHistory*(vm: DebugControlsVM; direction: HistoryDirection) =
  ## Move the cursor one entry and jump there. Refused — nothing happens —
  ## at either end (`nextHistoryIndex`).
  let next = nextHistoryIndex(vm.history.val.len, vm.historyIndex.val,
                              direction)
  if next != 0:
    vm.jumpToHistoryIndex(next)

proc goBack*(vm: DebugControlsVM) = vm.moveInHistory(hdOlder)
proc goForward*(vm: DebugControlsVM) = vm.moveInHistory(hdNewer)

proc jumpBefore*(vm: DebugControlsVM) =
  ## Open the list of the positions before the cursor (`jump-before`).
  vm.historyList.val = hlBefore

proc jumpAfter*(vm: DebugControlsVM) =
  ## Open the list of the positions after the cursor (`jump-after`).
  vm.historyList.val = hlAfter

proc stopJump*(vm: DebugControlsVM) =
  ## Close the open history list.
  vm.historyList.val = hlNone

proc chooseHistoryEntry*(vm: DebugControlsVM; position: int) =
  ## Jump to the entry at `position` of the open list
  ## (`historyListEntries[position]`) and close the list.
  let kind = vm.historyList.val
  let entries = vm.history.val
  let cursor = vm.historyIndex.val
  vm.historyList.val = hlNone
  if position < 0:
    return
  case kind
  of hlNone: discard
  of hlBefore:
    # Most recent first: list position 0 is the entry just older than the
    # cursor, `[^(cursor + 1)]`.
    let index = cursor + 1 + position
    if index <= entries.len:
      vm.jumpToHistoryIndex(index)
  of hlAfter:
    # Oldest first: list position 0 is the entry just newer than the cursor.
    let index = cursor - 1 - position
    if index >= 1:
      vm.jumpToHistoryIndex(index)

# ---------------------------------------------------------------------------
# Toolbar actions other than steps
# ---------------------------------------------------------------------------

proc runTests*(vm: DebugControlsVM) =
  ## Start the tests; pending until the run reports back.
  if vm.commands.runTests.isNil or vm.runTestsPending.val:
    return
  vm.runTestsPending.val = true
  let vmRef = vm
  vm.commands.runTests(proc(succeeded: bool) =
    vmRef.runTestsPending.val = false)

proc runToEntry*(vm: DebugControlsVM) =
  if not vm.commands.runToEntry.isNil:
    vm.pendingOperation = "run-to-entry"
    vm.commands.runToEntry()

proc resetOperation*(vm: DebugControlsVM) =
  ## Restart the replay; the history starts again with it.
  if not vm.commands.reset.isNil:
    vm.resetHistory()
    vm.commands.reset()

proc stopOperation*(vm: DebugControlsVM) =
  if not vm.commands.stop.isNil:
    vm.commands.stop()

proc setEditToolbar*(vm: DebugControlsVM; model: EditToolbarModel;
                     invoke: proc(id: string)) =
  ## Install (or replace) the composed edit-mode toolbar.
  vm.editToolbarInvoke = invoke
  vm.editToolbar.val = some(model)

proc invokeToolbarAction*(vm: DebugControlsVM; actionId: string) =
  ## Every toolbar action by the id its button carries — the one route a
  ## button, a key chord and a menu item take, on every front-end.
  case actionId
  of "next", "reverse-next", "step-in", "step-out", "continue",
     "reverse-continue", "reverse-step-in", "reverse-step-out":
    vm.invokeToolbarStep(actionId)
  of "run-to-entry": vm.runToEntry()
  of "reset-operation", "full-reset-operation": vm.resetOperation()
  of "stop": vm.stopOperation()
  of "run-tests": vm.runTests()
  of "jump-before": vm.jumpBefore()
  of "jump-after": vm.jumpAfter()
  of HistoryBackActionId, HistoryForwardActionId:
    vm.moveInHistory(historyDirectionOfAction(actionId))
  of "jump-to-live": vm.jumpToLive()
  else: discard

proc defaultDebugCommands*(store: ReplayDataStore): DebugCommands =
  ## The commands every host can issue over the session's `BackendService`:
  ## steps (`requestStep`), run to entry and history jumps. Reset, stop and
  ## test runs are a host's to supply.
  DebugCommands(
    step: proc(actionId: string) =
      let direction =
        case actionId
        of "reverse-next": sdBackward
        of "step-in": sdStepIn
        of "step-out": sdStepOut
        of "continue": sdContinue
        of "reverse-continue": sdReverseContinue
        of "reverse-step-in": sdReverseStepIn
        of "reverse-step-out": sdReverseStepOut
        else: sdForward
      store.requestStep(direction),
    runToEntry: proc() =
      discard store.backend.send("ct/run-to-entry", newJObject()),
    historyJump: proc(entry: JumpEntry) =
      discard store.backend.send("ct/history-jump", %*{
        "path": entry.location.file, "line": entry.location.line,
        "rrTicks": entry.rrTicks,
        "sourceGeneration": entry.location.sourceGeneration}))

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createDebugControlsVM*(store: ReplayDataStore;
                            commands: DebugCommands): DebugControlsVM =
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

    # -- The jump history and the toolbar surface (own state) --
    let history = createSignal(newSeq[JumpEntry]())
    let historyIndex = createSignal(1)
    let historyList = createSignal(hlNone)
    let toolbarMode = createSignal(DebugMode)
    let editToolbar = createSignal(none(EditToolbarModel))
    let canGoBack = createMemo[bool] proc(): bool =
      nextHistoryIndex(history.val.len, historyIndex.val, hdOlder) != 0
    let canGoForward = createMemo[bool] proc(): bool =
      nextHistoryIndex(history.val.len, historyIndex.val, hdNewer) != 0
    let historyListEntries = createMemo[seq[JumpEntry]] proc(): seq[JumpEntry] =
      let entries = history.val
      let cursor = historyIndex.val
      case historyList.val
      of hlNone: discard
      of hlBefore:
        var index = cursor + 1
        while index <= entries.len:
          result.add entries[^index]
          inc index
      of hlAfter:
        var index = cursor - 1
        while index >= 1:
          result.add entries[^index]
          dec index
    let surface = createMemo[TopbarSurface] proc(): TopbarSurface =
      topbarSurface(toolbarMode.val, editToolbar.val.isSome)

    var vm: DebugControlsVM
    let vmRef = proc(): DebugControlsVM = vm
    vm = DebugControlsVM(
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
      shortcutsRevision: createSignal(0),
      commands: commands,
      history: history,
      historyIndex: historyIndex,
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      historyList: historyList,
      historyListEntries: historyListEntries,
      runTestsPending: createSignal(false),
      toolbarMode: toolbarMode,
      editToolbar: editToolbar,
      topbarSurface: surface,
      disposeProc: dispose,
    )
    # A different trace behind the same store starts a new history.
    var seenGeneration = store.sessionGeneration.val
    createEffect proc() =
      let generation = store.sessionGeneration.val
      if generation != seenGeneration:
        seenGeneration = generation
        untrack(proc() = vmRef().resetHistory())

    # Every stop the debugger reaches is offered to the history; a stop is
    # its position AND its tick (`stopIdentityOf`), so two lines at one tick
    # are two entries. Untracked beyond the identity, as the stop loader is.
    var lastIdentity = ""
    createEffect proc() =
      let state = store.debugger.val
      let identity = stopIdentityOf(state)
      if state.rrTicks == 0'u64 and state.location.file.len == 0:
        return
      if identity == lastIdentity:
        return
      lastIdentity = identity
      untrack(proc() = vmRef().recordStop(state.location, state.rrTicks))
    vm

proc createDebugControlsVM*(store: ReplayDataStore): DebugControlsVM =
  ## A DebugControlsVM over the commands every host can issue through the
  ## session's backend (`defaultDebugCommands`).
  createDebugControlsVM(store, defaultDebugCommands(store))
