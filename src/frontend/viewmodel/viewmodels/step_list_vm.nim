## viewmodels/step_list_vm.nim
##
## StepListVM — ViewModel for the Step List panel.
##
## The Step List panel renders a linear list of recently-executed
## source lines around the current debugger position.  Each row carries
## a ``delta`` offset relative to the current step, a small
## ``StepLineLocation`` (path / line / function / rrTicks) and the
## source-line text the step landed on.  ``Call`` and ``Return`` rows
## also carry a list of ``expression = repr`` pairs that the view
## renders inline.  The shape mirrors the legacy ``LineStep`` record;
## see ``store/types.StepLine`` for the field-level docs.
##
## Reactive surface:
## - ``lineSteps``           — the rendered rows in display order.
## - ``currentLocation``     — the live debugger location used to flag
##                              the ``active-step-line`` row.
## - ``panelHeight``         — number of rows the panel can show
##                              (used by ``loadStepLinesFor`` to size
##                              the backend request — the legacy code
##                              measured ``offsetHeight`` of the GL
##                              container directly).
##
## Derived:
## - ``isEmpty``              — convenience for the empty-state.
##
## Actions:
## - ``setLineSteps``         — replace the row list wholesale.
## - ``appendLineSteps``      — append a streamed batch and re-sort by
##                              ``delta`` (mirrors the legacy
##                              ``onUpdatedLoadStepLines`` handler).
## - ``clearLineSteps``       — drop every row (used during a session
##                              switch / fresh ``loadStepLinesFor``).
## - ``setCurrentLocation``   — refresh the active-row reference.
## - ``setPanelHeight``       — cache the latest measured row capacity.
## - ``loadStepLinesFor``     — emit a ``ct/load-step-lines`` request
##                              for the given location.  In production
##                              the legacy ``FlowService.loadStepLines``
##                              issues an ``IPC`` message; routing the
##                              request through the backend lets
##                              headless tests verify the end-to-end
##                              flow without depending on Karax.
## - ``jumpToStepLine``       — emit a ``ct/line-step-jump`` request
##                              carrying the row's ``delta`` /
##                              ``rrTicks`` so the live debugger can
##                              advance to the corresponding step.
##                              This is the same wire shape Errors and
##                              Search Results use for navigation.
##
## The VM consumes the same ``LoadStepLinesUpdate`` semantics as the
## legacy component: ``onUpdatedLoadStepLines`` would call
## ``self.lineSteps.concat(update.results)`` and re-sort by ``delta``;
## ``onCompleteMove`` would re-fetch the rows for the new location.
## ``appendLineSteps`` and ``loadStepLinesFor`` reproduce that contract
## platform-neutrally.

import std/[algorithm, json]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

const DEFAULT_STEP_LIST_PANEL_HEIGHT = 16
  ## Conservative default for the row capacity used by
  ## ``loadStepLinesFor`` when the host has not yet measured the GL
  ## container.  The legacy code defaulted to ``offsetHeight / 26``;
  ## ~16 rows roughly matches a half-screen panel and avoids issuing a
  ## zero-row request.

type
  StepListVM* = ref object of ViewModel
    ## Reactive state for the Step List panel.
    store*: ReplayDataStore

    # -- Mutable state --
    lineSteps*: Signal[seq[StepLine]]
    currentLocation*: Signal[StepLineLocation]
    panelHeight*: Signal[int]

    # -- Derived state --
    isEmpty*: Memo[bool]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc cmpByDelta(a, b: StepLine): int =
  ## Comparator used to keep the list sorted by ``delta`` after
  ## streaming appends.  Mirrors the legacy ``sort(lineSteps, ...)``
  ## call in ``onUpdatedLoadStepLines``.
  cmp(a.delta, b.delta)

proc isCurrentRow*(line: StepLine; loc: StepLineLocation): bool =
  ## True when the given ``line`` describes the current debugger
  ## position.  Same triple-equality the legacy ``lineStepLineView``
  ## proc used (``rrTicks`` + ``path`` + ``line``).
  line.location.rrTicks == loc.rrTicks and
    line.location.path == loc.path and
    line.location.line == loc.line

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setLineSteps*(vm: StepListVM; lines: seq[StepLine]) =
  ## Replace the row list wholesale.  Used by the legacy
  ## ``loadStepLinesFor`` flow when a fresh request is issued — the
  ## previous rows are discarded before the streamed batches arrive.
  ## The list is sorted by ``delta`` here so callers can pass an
  ## unordered batch and still get a stable visual order.
  var sorted = lines
  sort(sorted, cmpByDelta)
  vm.lineSteps.val = sorted

proc appendLineSteps*(vm: StepListVM; lines: seq[StepLine]) =
  ## Append a streamed batch and re-sort by ``delta``.  Mirrors the
  ## legacy ``onUpdatedLoadStepLines`` handler:
  ## ``self.lineSteps = self.lineSteps.concat(update.results)`` followed
  ## by ``sort(... cmp delta)``.
  if lines.len == 0:
    return
  var entries = vm.lineSteps.val
  for line in lines:
    entries.add(line)
  sort(entries, cmpByDelta)
  vm.lineSteps.val = entries

proc clearLineSteps*(vm: StepListVM) =
  ## Reset the row list.  Called when starting a fresh request so the
  ## previous run's rows do not bleed into the next.
  vm.lineSteps.val = @[]

proc setCurrentLocation*(vm: StepListVM; loc: StepLineLocation) =
  ## Refresh the live debugger location used to flag the
  ## ``active-step-line`` row.  The legacy view re-read this every
  ## render via ``data.services.debugger.location``; the VM caches it
  ## as a signal so view re-renders do not require touching the legacy
  ## record.
  vm.currentLocation.val = loc

proc setPanelHeight*(vm: StepListVM; rows: int) =
  ## Cache the latest measured row capacity.  ``rows`` is the number of
  ## rows the panel can show — the legacy code computed it as
  ## ``offsetHeight div STEP_LINE_HEIGHT_PX``.  Values <=0 are clamped
  ## to ``DEFAULT_STEP_LIST_PANEL_HEIGHT`` so a missing measurement
  ## does not produce a degenerate request.
  if rows <= 0:
    vm.panelHeight.val = DEFAULT_STEP_LIST_PANEL_HEIGHT
  else:
    vm.panelHeight.val = rows

proc loadStepLinesFor*(vm: StepListVM; loc: StepLineLocation) =
  ## Issue a ``ct/load-step-lines`` request for ``loc``.  Resets the
  ## row list before the streamed responses arrive, mirroring the
  ## legacy ``loadStepLinesFor`` proc.  The backend reply lands as
  ## individual ``appendLineSteps`` calls dispatched by the UI bridge.
  vm.clearLineSteps()
  vm.setCurrentLocation(loc)
  let count =
    if vm.panelHeight.val <= 0: DEFAULT_STEP_LIST_PANEL_HEIGHT
    else: vm.panelHeight.val
  let args = %*{
    "path": loc.path,
    "line": loc.line,
    "rrTicks": loc.rrTicks,
    "count": count,
  }
  discard vm.store.backend.send("ct/load-step-lines", args)

proc jumpToStepLine*(vm: StepListVM; line: StepLine) =
  ## Dispatch a ``ct/line-step-jump`` request for the given row.  The
  ## legacy view called ``data.services.debugger.lineStepJump(line)``;
  ## routing this via the backend keeps the signal flow self-contained
  ## for headless tests.  The same ``delta`` / ``rrTicks`` payload is
  ## what the live debugger needs to translate the click into either a
  ## ``StepIn`` repeat or a ``jumpToLocalStep`` based on the trace
  ## kind.
  let args = %*{
    "delta": line.delta,
    "path": line.location.path,
    "line": line.location.line,
    "rrTicks": line.location.rrTicks,
  }
  discard vm.store.backend.send("ct/line-step-jump", args)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createStepListVM*(store: ReplayDataStore): StepListVM =
  ## Create a StepListVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty/inert default
  ## so the view renders the empty placeholder on first paint.
  withViewModel proc(dispose: proc()): StepListVM =
    let lineSteps = createSignal(newSeq[StepLine]())
    let currentLocation = createSignal(StepLineLocation())
    let panelHeight = createSignal(DEFAULT_STEP_LIST_PANEL_HEIGHT)

    let isEmpty = createMemo[bool] proc(): bool =
      lineSteps.val.len == 0

    StepListVM(
      store: store,
      lineSteps: lineSteps,
      currentLocation: currentLocation,
      panelHeight: panelHeight,
      isEmpty: isEmpty,
      disposeProc: dispose,
    )
