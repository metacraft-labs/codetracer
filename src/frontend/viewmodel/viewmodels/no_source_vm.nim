## viewmodels/no_source_vm.nim
##
## NoSourceVM — ViewModel for the "no source" placeholder panel.
##
## Drives the IsoNim view that replaces the legacy Karax
## ``method render`` on ``NoSourceComponent`` (see
## ``frontend/ui/no_source.nim``).  The panel is rendered inside the
## editor tab when the debugger lands on a location whose source
## cannot be opened — typically because the active recording stepped
## into a stripped library or a synthetic frame.
##
## The view layer needs only a small slice of the legacy component's
## state — a free-form message, the current high-level function /
## path / line, optional jump-history context, and an optional
## "Originating address" string sourced from the asm-instructions
## response.  The legacy assembly instructions list is intentionally
## not modelled here: it depends on a Karax-driven Monaco-adjacent
## render path and is reachable today only through the same Karax
## fallback as ``method render``.  Keeping the IsoNim panel focused
## on the placeholder/header DOM matches the migration scope laid
## out in the handoff doc (section 5.4 entry: "placeholder for
## missing source").
##
## Usage::
##
##   let vm = createNoSourceVM(store)
##   vm.setMessage("This frame has no source")
##   vm.setLocation(NoSourceLocationInfo(
##     functionName: "main",
##     path: "/usr/lib/...",
##     line: 42,
##   ))
##   vm.setHistory(NoSourceHistoryInfo(
##     hasHistory: true,
##     previousPath: "src/main.nim",
##     action: "step",
##   ))
##   vm.setOriginatingAddress("0x1234")
##   echo vm.message.val
##
## The ``jumpBack`` action emits ``ct/history-jump`` via the backend
## so a fully-IsoNim-driven Jump-back button still rewires the
## debugger position.  The legacy event-bus path remains the primary
## hook today (``NoSourceComponent.historyJump`` calls into the
## existing history-jump pipeline); the action is exposed here so
## headless tests can assert that clicking the IsoNim button reaches
## the backend.

import std/json

import isonim/core/[signals, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  NoSourceVM* = ref object of ViewModel
    ## Reactive state for the no-source placeholder panel.
    ##
    ## Mutable signals:
    ##   message              — free-form message rendered inside the
    ##                          first ``unknown-border`` block.  Empty
    ##                          string suppresses the ``<p>`` line
    ##                          (matching the legacy ``if message.len
    ##                          > 0`` guard).
    ##   location             — high-level function / path / line trio.
    ##   history              — optional jump-history context; the
    ##                          "Jump back" affordance depends on it.
    ##   originatingAddress   — short hex string sourced from the
    ##                          ``Instructions.address`` response.
    ##                          Empty hides the line.
    ##   stopSignalText       — non-empty when a stop signal other
    ##                          than ``NoStopSignal`` /
    ##                          ``OtherStopSignal`` reached the
    ##                          debugger; mirrors the legacy
    ##                          ``Signal received: ...`` line.
    ##
    ## The store reference is kept so ``jumpBack`` can dispatch via
    ## ``store.backend.send``.
    store*: ReplayDataStore

    # -- Mutable state --
    message*: Signal[string]
    location*: Signal[NoSourceLocationInfo]
    history*: Signal[NoSourceHistoryInfo]
    originatingAddress*: Signal[string]
    stopSignalText*: Signal[string]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setMessage*(vm: NoSourceVM; message: string) =
  ## Set the free-form message rendered above the location block.
  vm.message.val = message

proc setLocation*(vm: NoSourceVM; loc: NoSourceLocationInfo) =
  ## Replace the current high-level location info.
  vm.location.val = loc

proc setHistory*(vm: NoSourceVM; history: NoSourceHistoryInfo) =
  ## Replace the jump-history context.  Pass a default-constructed
  ## ``NoSourceHistoryInfo`` to clear it (``hasHistory = false``
  ## suppresses the optional rows + Jump-back button).
  vm.history.val = history

proc setOriginatingAddress*(vm: NoSourceVM; address: string) =
  ## Set the "Originating address: 0x..." text.  Empty string hides
  ## the line — matching the legacy code's empty-instructions
  ## fallback (the legacy view always emitted the row but with an
  ## empty hex value, which produced cosmetically empty markup; we
  ## simply omit the row in that case).
  vm.originatingAddress.val = address

proc setStopSignalText*(vm: NoSourceVM; text: string) =
  ## Set the "Signal received: ..." text shown at the bottom of the
  ## panel.  Empty string suppresses the line.
  vm.stopSignalText.val = text

proc jumpBack*(vm: NoSourceVM) =
  ## Trigger the "Jump back" action.  Forwards to the backend via
  ## ``ct/history-jump`` carrying the previous-path metadata.
  ##
  ## When ``hasHistory`` is false this is a no-op so the action is
  ## safe to call from the view's click handler regardless of the
  ## current state — the view simply hides the button when there is
  ## no history.
  let history = vm.history.val
  if not history.hasHistory:
    return
  let args = %*{
    "previousPath": history.previousPath,
    "action": history.action,
  }
  vm.store.requestHistoricalNavigation("ct/history-jump", args)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createNoSourceVM*(store: ReplayDataStore): NoSourceVM =
  ## Create a NoSourceVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty/inert default
  ## so the view renders the bare "Whoops!" shell on first paint.
  withViewModel proc(dispose: proc()): NoSourceVM =
    NoSourceVM(
      store: store,
      message: createSignal(""),
      location: createSignal(NoSourceLocationInfo()),
      history: createSignal(NoSourceHistoryInfo()),
      originatingAddress: createSignal(""),
      stopSignalText: createSignal(""),
      disposeProc: dispose,
    )
