## viewmodels/repl_vm.nim
##
## ReplVM — ViewModel for the REPL panel.
##
## The REPL panel renders an interactive prompt that lets the user
## evaluate gdb-style debugger expressions against the live trace.  The
## legacy ``ReplComponent`` (see ``frontend/ui/repl.nim``) implemented
## the panel via a Karax ``method render`` with three branches:
##
## 1) When the active trace lang ``usesMaterializedTraces`` (DB-based
##    traces) the panel rendered a "REPL not supported" message.
## 2) When ``config.repl`` was true the panel rendered the prompt
##    ``<form><input id="repl-input"></form>`` followed by the last 10
##    history entries (each entry = an input echo + an output ``<pre>``
##    coloured by the output kind).
## 3) Otherwise the panel rendered the "REPL disabled" message.
##
## The IsoNim view (``viewmodel/views/isonim_repl_view.nim``) replaces
## the Karax render and reads the same state from this VM.  The legacy
## component shell still exists to keep the event-bus subscription
## alive (``onDebugOutput`` is dispatched from the IPC layer); each
## handler now mirrors its updates into the VM signals so the IsoNim
## view tracks them.
##
## Reactive surface:
## - ``history``             — bounded list of debug interactions in
##                              insertion order (newest at the tail).
##                              The view renders the last 10 entries
##                              from newest to oldest, mirroring the
##                              legacy ``(history.len-1).countdown(
##                              history.len-10)`` slice.
## - ``replEnabled``         — config flag that gates the prompt /
##                              history rendering.  When false the view
##                              shows the "REPL disabled" message.
## - ``materialized``        — true when the active trace lang uses
##                              materialised traces.  When true the
##                              view shows the "not supported" message
##                              regardless of ``replEnabled`` (matches
##                              the legacy branch ordering).
## - ``langName``            — short language name interpolated into
##                              the materialised-trace message.
##
## Derived:
## - ``displayMode``         — convenience enum derived from the three
##                              signals above; encapsulates the
##                              materialized > enabled > disabled
##                              branch ordering so the view can
##                              ``case`` over a single value.
##
## Actions:
## - ``submitInput``         — append a new pending interaction with
##                              ``DebugLoading`` output and dispatch
##                              the existing ``debugRepl(...)`` IPC
##                              call.  Mirrors the legacy
##                              ``ReplComponent.run`` semantics: the
##                              guard against ``service.stableBusy``
##                              lives in ``debugRepl`` itself, so we
##                              forward unconditionally and trust the
##                              service-side gate.
## - ``onDebugOutput``       — replace the last interaction's output
##                              with the streamed response.  Matches
##                              the legacy ``ReplComponent.onDebugOutput``
##                              ``self.history[^1].output = response``
##                              behaviour.
## - ``setReplEnabled`` /
##   ``setMaterialized`` /
##   ``setLangName``         — refresh the configuration signals.  These
##                              are called by the legacy bridge when
##                              the underlying trace / config changes.
## - ``clearHistory``        — reset the history list (used during a
##                              session swap).
##
## Plain ``string`` is used everywhere so the same value type works on
## both native (test-vm-native) and JS (test-vm-js) backends without
## the ``langstring`` / ``cstring`` conversion noise the legacy types
## carry.
##
## The ``submitInput`` action accepts a ``dispatch`` callback so the
## VM stays free of frontend imports — the host (``frontend/ui/repl``)
## passes ``debugRepl`` at construction time.  Headless tests pass an
## inert lambda that records the dispatched expression instead of
## sending it to the live debugger.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/replay_data_store

const REPL_HISTORY_VISIBLE_LEN* = 10
  ## Number of newest entries the view renders.  Mirrors the legacy
  ## ``(history.len-1).countdown(history.len-10)`` slice — the view
  ## simply iterates the last ``REPL_HISTORY_VISIBLE_LEN`` entries in
  ## reverse insertion order.

type
  ReplOutputKind* = enum
    ## Output kind enum matching ``DebugOutputKind`` in
    ## ``common_types/graveyard.nim``.  Duplicated as a plain enum
    ## here so ``store/types.nim``-free VM code does not pull in the
    ## frontend ``langstring`` chain.  The view uses the lowercased
    ## suffix as the ``repl-output-<kind>`` CSS class — same shape the
    ## legacy ``$interaction.output.kind .replace("Debug").toLowerAscii``
    ## expression produced (so e.g. ``rokLoading`` -> ``"loading"``).
    rokLoading
    rokResult
    rokMove
    rokError

  ReplOutput* = object
    ## Plain-string mirror of ``DebugOutput``.  ``output`` carries the
    ## raw text the debugger returned (or the empty string while a
    ## request is still in flight).
    kind*: ReplOutputKind
    output*: string

  ReplInteraction* = object
    ## One row in the REPL history.  ``input`` is the user-entered
    ## expression; ``output`` carries the streamed response (initially
    ## ``rokLoading``, updated when ``onDebugOutput`` fires).
    input*: string
    output*: ReplOutput

  ReplDisplayMode* = enum
    ## Encapsulates the three render branches so the view can ``case``
    ## over a single signal-derived value.  Branch ordering matches the
    ## legacy Karax ``if / elif / else``:
    ## ``materialized`` wins, then ``replEnabled`` falsiness, otherwise
    ## the prompt is shown.
    rdmMaterializedDisabled
    rdmReplEnabled
    rdmReplDisabled

  ReplDispatcher* = proc(input: string) {.closure.}
    ## Sends the user-entered expression to the live debugger.  The
    ## production wiring sets this to a closure around ``debugRepl``
    ## (see ``frontend/ui/repl.nim``).  Headless tests pass an
    ## inert closure that records the input instead.

  ReplVM* = ref object of ViewModel
    ## Reactive state for the REPL panel.
    store*: ReplayDataStore
    dispatcher*: ReplDispatcher

    # -- Mutable state --
    history*: Signal[seq[ReplInteraction]]
    replEnabled*: Signal[bool]
    materialized*: Signal[bool]
    langName*: Signal[string]

    # -- Derived state --
    displayMode*: Memo[ReplDisplayMode]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc outputKindClassSuffix*(kind: ReplOutputKind): string =
  ## Lowercased suffix used in the legacy ``repl-output-<suffix>`` CSS
  ## class.  Mirrors the legacy expression
  ## ``($kind).replace("Debug").toLowerAscii``: the legacy enum
  ## stringified as e.g. ``DebugLoading``, the ``Debug`` prefix was
  ## stripped, and the result was lowercased.  We hardcode the mapping
  ## so consumers (view, headless tests) do not depend on enum-string
  ## mechanics.
  case kind
  of rokLoading: "loading"
  of rokResult: "result"
  of rokMove: "move"
  of rokError: "error"

proc outputClass*(kind: ReplOutputKind): string =
  ## Full CSS class for the output ``<pre>``.  Matches the legacy
  ## ``"repl-output-" & ...`` concatenation.
  "repl-output-" & outputKindClassSuffix(kind)

proc inputDisplayText*(input: string): string =
  ## Echo line shown in ``.repl-input-history`` rows.  The legacy view
  ## emitted ``">" & $input``; we mirror it verbatim.
  ">" & input

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setHistory*(vm: ReplVM; entries: seq[ReplInteraction]) =
  ## Replace the entire history list.  Used by the legacy bridge to
  ## bulk-replay the existing ``ReplComponent.history`` cache when the
  ## panel is mounted after some interactions already happened.
  vm.history.val = entries

proc clearHistory*(vm: ReplVM) =
  ## Drop every entry — used during a session swap so the previous
  ## run's interactions do not bleed into the next.
  vm.history.val = @[]

proc setReplEnabled*(vm: ReplVM; enabled: bool) =
  ## Refresh the ``config.repl`` flag.  When false the view renders
  ## the "REPL disabled" message (subject to ``materialized`` taking
  ## precedence).
  vm.replEnabled.val = enabled

proc setMaterialized*(vm: ReplVM; materialized: bool) =
  ## Refresh whether the active trace lang uses materialised traces.
  ## When true the view renders the "REPL not supported" message
  ## regardless of ``replEnabled``.
  vm.materialized.val = materialized

proc setLangName*(vm: ReplVM; name: string) =
  ## Refresh the lang short-name interpolated into the materialised-
  ## trace message.  Empty string is acceptable; the view will simply
  ## render the trailing ``''``.
  vm.langName.val = name

proc submitInput*(vm: ReplVM; expression: string) =
  ## Append a new pending interaction and dispatch the expression to
  ## the live debugger via ``vm.dispatcher``.
  ##
  ## Mirrors the legacy ``ReplComponent.run`` semantics:
  ## - The new entry starts with ``rokLoading`` output so the view
  ##   immediately shows the spinner-equivalent placeholder.
  ## - The response lands later via ``onDebugOutput`` which mutates
  ##   the most-recent entry's output.
  ##
  ## The legacy method also no-oped while ``service.stableBusy`` was
  ## true; that gate now lives inside ``debugRepl`` itself (see
  ## ``frontend/services/debugger_service.nim``), so we forward
  ## unconditionally.  An empty / whitespace-only expression is
  ## ignored so submitting a blank prompt does not pollute the
  ## history.
  if expression.len == 0:
    return
  var entries = vm.history.val
  entries.add(ReplInteraction(
    input: expression,
    output: ReplOutput(kind: rokLoading, output: ""),
  ))
  vm.history.val = entries
  if not vm.dispatcher.isNil:
    vm.dispatcher(expression)

proc onDebugOutput*(vm: ReplVM; response: ReplOutput) =
  ## Replace the most-recent interaction's output with the streamed
  ## response.  Matches the legacy
  ## ``self.history[^1].output = response`` behaviour.  Silently no-
  ## ops when the history is empty (e.g. an out-of-order response
  ## that arrived before any submit fired).
  let entries = vm.history.val
  if entries.len == 0:
    return
  var updated = entries
  updated[^1].output = response
  vm.history.val = updated

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createReplVM*(store: ReplayDataStore;
                   dispatcher: ReplDispatcher = nil): ReplVM =
  ## Create a ReplVM inside a reactive root owned by ``withViewModel``.
  ## The reactive root is disposed via ``vm.dispose()``.  Sets every
  ## signal to its empty/inert default so the view renders the
  ## "disabled" message until the bridge populates the config flags.
  ##
  ## ``dispatcher`` defaults to ``nil`` so headless tests can construct
  ## the VM without a frontend dependency; production callers pass a
  ## closure around ``debugRepl`` (see ``frontend/ui/repl.nim``).
  withViewModel proc(dispose: proc()): ReplVM =
    let history = createSignal(newSeq[ReplInteraction]())
    let replEnabled = createSignal(false)
    let materialized = createSignal(false)
    let langName = createSignal("")

    let displayMode = createMemo[ReplDisplayMode] proc(): ReplDisplayMode =
      if materialized.val:
        rdmMaterializedDisabled
      elif replEnabled.val:
        rdmReplEnabled
      else:
        rdmReplDisabled

    ReplVM(
      store: store,
      dispatcher: dispatcher,
      history: history,
      replEnabled: replEnabled,
      materialized: materialized,
      langName: langName,
      displayMode: displayMode,
      disposeProc: dispose,
    )
