## viewmodels/terminal_output_vm.nim
##
## TerminalOutputVM — ViewModel for the Terminal Output panel.
##
## Holds reactive state for:
## - The list of rendered terminal lines (``TerminalLine`` seq)
## - Whether the panel is still waiting for the initial event load
## - The current debugger ``rrTicks`` position (used to colour fragments
##   as past / active / future)
##
## Derives:
## - ``isLoading``: whether the panel is in its pre-load state
##   (no terminal events have arrived yet).
## - ``isEmpty``: whether the panel finished loading and has no
##   terminal output to display.
##
## Mirrors the contract of the legacy ``TerminalOutputComponent`` in
## ``frontend/ui/terminal_output.nim``: events arrive via the
## ``CtLoadedTerminal`` mediator subscription, the legacy code converts
## them to ANSI-decorated HTML using the ``ansi_up`` JS library and
## groups them by line.  The VM stores the resulting ``TerminalLine``
## values verbatim so the IsoNim view can render them without
## re-running the legacy splitter.  This keeps the VM platform-neutral
## (no JS-only dependencies) which lets the headless tests under
## ``src/tests/gui/tests/views/isonim_views_test.nim`` exercise the
## full reactive flow on the native backend.
##
## Usage::
##
##   let vm = createTerminalOutputVM(store)
##   vm.setLines(@[TerminalLine(lineIndex: 0, fragments: @[
##       TerminalEventFragment(htmlText: "hello", eventIndex: 0, rrTicks: 5)
##   ])])
##   echo vm.lines.val.len     # 1
##
## When a navigation handler needs to jump to the source event the
## view calls ``vm.jumpToEvent(eventIndex)``; the VM then looks up the
## fragment's ``rrTicks`` and emits a ``ct/event-jump`` request via
## the backend.  The legacy event-bus path remains the primary jump
## hook today (the legacy ``TerminalOutputComponent.register`` path
## still dispatches ``CtEventJump``), but the VM exposing the same
## action keeps the signal flow self-contained for headless tests.

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  TerminalOutputVM* = ref object of ViewModel
    ## Reactive state for the Terminal Output panel.
    ##
    ## Mutable signals:
    ##   lines           — the terminal lines currently rendered.
    ##   initialLoad     — true until the first ``setLines`` call lands.
    ##                     Mirrors the legacy ``initialUpdate`` flag;
    ##                     drives the "Loading record output..." overlay
    ##                     vs. the "no terminal output" overlay vs. the
    ##                     populated lines.
    ##   currentRRTicks  — the debugger's current rrTicks position; the
    ##                     view compares this against each fragment's
    ##                     ``rrTicks`` to pick the past/active/future
    ##                     colour class.
    ##
    ## Derived memos:
    ##   isLoading       — ``initialLoad and lines.len == 0``.
    ##   isEmpty         — ``not initialLoad and lines.len == 0``.
    ##
    ## The store reference is kept so ``jumpToEvent`` can dispatch a
    ## backend request via ``store.backend.send``.
    store*: ReplayDataStore

    # -- Mutable state --
    lines*: Signal[seq[TerminalLine]]
    initialLoad*: Signal[bool]
    currentRRTicks*: Signal[uint64]

    # -- Derived state --
    isLoading*: Memo[bool]
    isEmpty*: Memo[bool]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setLines*(vm: TerminalOutputVM; lines: seq[TerminalLine]) =
  ## Replace the rendered lines wholesale.  Marks ``initialLoad`` as
  ## false — every subsequent render distinguishes "loading" from
  ## "empty trace output" via the ``isEmpty`` memo.
  vm.initialLoad.val = false
  vm.lines.val = lines

proc clearLines*(vm: TerminalOutputVM) =
  ## Reset to the pre-load state.  Used when the host component's
  ## ``restart`` runs (new trace loaded) or before requesting a fresh
  ## terminal load.
  vm.initialLoad.val = true
  vm.lines.val = @[]

proc setCurrentRRTicks*(vm: TerminalOutputVM; rrTicks: uint64) =
  ## Update the debugger position so fragment colour classes refresh.
  vm.currentRRTicks.val = rrTicks

proc jumpToEvent*(vm: TerminalOutputVM; eventIndex: int) =
  ## Navigate to the program event referenced by ``eventIndex``.
  ## Looks the rrTicks up via the rendered lines so the request is
  ## self-contained — no separate ``ProgramEvent`` cache needed.
  ## If the fragment is not found (e.g. the lines were cleared
  ## between the click and this dispatch) the call is a no-op.
  for line in vm.lines.val:
    for fragment in line.fragments:
      if fragment.eventIndex == eventIndex:
        let args = %*{
          "eventIndex": eventIndex,
          "directLocationRRTicks": fragment.rrTicks,
          "kind": "Write",
        }
        vm.store.requestHistoricalNavigation("ct/event-jump", args)
        return

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createTerminalOutputVM*(store: ReplayDataStore): TerminalOutputVM =
  ## Create a TerminalOutputVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults (``initialLoad = true``,
  ##    no lines, ``rrTicks = 0``).
  ## 2. Derived memos for ``isLoading`` and ``isEmpty``.
  ## 3. A subscription to the store's ``debugger`` signal so
  ##    ``currentRRTicks`` mirrors the debugger position automatically
  ##    — bridges the legacy ``CtCompleteMove`` event to the VM
  ##    without requiring the legacy component to call into the VM
  ##    directly.
  withViewModel proc(dispose: proc()): TerminalOutputVM =
    let lines = createSignal(newSeq[TerminalLine]())
    let initialLoad = createSignal(true)
    let currentRRTicks = createSignal(0'u64)

    # Derived: pre-load state — no lines and still waiting for the
    # first response.
    let isLoading = createMemo[bool] proc(): bool =
      initialLoad.val and lines.val.len == 0

    # Derived: post-load empty state — first response arrived but the
    # trace produced no terminal output.
    let isEmpty = createMemo[bool] proc(): bool =
      (not initialLoad.val) and lines.val.len == 0

    let vm = TerminalOutputVM(
      store: store,
      lines: lines,
      initialLoad: initialLoad,
      currentRRTicks: currentRRTicks,
      isLoading: isLoading,
      isEmpty: isEmpty,
      disposeProc: dispose,
    )

    # Mirror the debugger's rrTicks into ``currentRRTicks`` so the
    # view's per-fragment class effects re-fire whenever the user
    # navigates the recording.  The store's ``debugger`` signal is
    # updated by ``updateDebuggerPosition`` from both the legacy
    # CtCompleteMove handler and the VM-driven step path.
    createEffect proc() =
      currentRRTicks.val = store.debugger.val.rrTicks

    vm
