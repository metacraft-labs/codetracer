## viewmodels/trace_log_vm.nim
##
## TraceLogVM — ViewModel for the Trace Log panel.
##
## The Trace Log panel renders a tabular list of every tracepoint stop
## captured by the active trace session.  The legacy
## ``TraceLogComponent`` (see ``frontend/ui/trace_log.nim``) implemented
## the panel via a Karax ``method render`` that delegated row layout to
## a DataTables grid.  Columns: ``rrTicks`` indicator, ``file:line``,
## function name, formatted locals.  Row click → ``CtEventJump``.
##
## The IsoNim view (``viewmodel/views/isonim_trace_log_view.nim``)
## replaces the Karax render and reads the same state from this VM.
## The legacy component shell still exists to keep its event-bus
## subscriptions wired (``CtTracepointResults`` etc.); each handler now
## mirrors its updates into the VM signals so the IsoNim view tracks
## them.
##
## Reactive surface:
## - ``entries``         — captured ``TraceLogEntry`` rows in display
##                         order (sorted ascending by ``rrTicks``,
##                         matching the legacy DataTables order).
## - ``selectedIndex``   — index of the selected row.  ``-1`` means no
##                         selection.
##
## Derived:
## - ``isEmpty``         — convenience for the empty-state.
## - ``rowCount``        — total entry count (used by tests).
##
## Actions:
## - ``addEntry``         — append a captured tracepoint stop and
##                          re-sort by ``rrTicks``.
## - ``setEntries``       — bulk-replace the row list (used by
##                          ``syncLegacyTraceLogIntoVM`` when the
##                          legacy component already carries captured
##                          stops).
## - ``clearEntries``     — wipe every entry (e.g. session restart).
## - ``selectEntry``      — refresh ``selectedIndex``.
## - ``jumpToEntry``      — dispatch ``ct/event-jump`` for the row's
##                          ``eventId``.  Used by the IsoNim row's
##                          ``onclick`` handler.  Mirrors the legacy
##                          ``CtEventJump`` event payload that the
##                          DataTables row click emitted.
##
## ``string`` is used everywhere so the same value works on both
## native (``test-vm-native``) and JS (``test-vm-js``) backends without
## ``cstring`` / ``langstring`` conversion noise.

import std/[algorithm, json, strutils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

const NO_SELECTED_INDEX* = -1
  ## Sentinel value for ``selectedIndex`` meaning "no row selected".

type
  TraceLogVM* = ref object of ViewModel
    ## Reactive state for the Trace Log panel.
    store*: ReplayDataStore

    # -- Mutable state --
    entries*: Signal[seq[TraceLogEntry]]
    selectedIndex*: Signal[int]

    # -- Derived state --
    isEmpty*: Memo[bool]
    rowCount*: Memo[int]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc cmpByRRTicks(a, b: TraceLogEntry): int =
  ## Comparator that keeps entries sorted ascending by ``rrTicks``.
  ## Mirrors the legacy DataTables ``order: [[0, "asc"]]`` config (the
  ## first column in the legacy grid was ``rrTicks``).
  cmp(a.rrTicks, b.rrTicks)

proc fileLineText*(entry: TraceLogEntry): string =
  ## "<filename>:<line>" — same shape the legacy column renderer
  ## produced via ``rsplit("/", 1)``.
  let path = entry.path
  let lastSlash = path.rfind('/')
  let filename = if lastSlash >= 0: path[lastSlash + 1 .. ^1] else: path
  filename & ":" & $entry.line

proc rrTicksScale*(rrTicks, minRRTicks, maxRRTicks: int): int =
  ## Percentage [0, 100] used to position the
  ## ``event-rr-ticks-line`` indicator.  Mirrors the legacy
  ## ``renderRRTicksLine`` arithmetic without the cstring HTML.
  if maxRRTicks <= minRRTicks:
    return 0
  let span = maxRRTicks - minRRTicks
  let offset = rrTicks - minRRTicks
  let clamped =
    if offset < 0: 0
    elif offset > span: span
    else: offset
  result = clamped * 100 div span

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setEntries*(vm: TraceLogVM; entries: seq[TraceLogEntry]) =
  ## Bulk-replace the entry list (sorted by ``rrTicks`` to match the
  ## legacy DataTables ordering).  Used by the legacy bridge to
  ## replay an accumulated set of stops into the VM when the panel
  ## becomes visible.  Also resets the selection because indices
  ## may no longer refer to the same row.
  var sorted = entries
  sorted.sort(cmpByRRTicks)
  vm.entries.val = sorted
  vm.selectedIndex.val = NO_SELECTED_INDEX

proc addEntry*(vm: TraceLogVM; entry: TraceLogEntry) =
  ## Append a captured tracepoint stop and re-sort by ``rrTicks``.
  ## Mirrors the legacy ``rows.add`` call inside
  ## ``onTracepointResults`` followed by the DataTables redraw.
  var existing = vm.entries.val
  existing.add(entry)
  existing.sort(cmpByRRTicks)
  vm.entries.val = existing

proc clearEntries*(vm: TraceLogVM) =
  ## Drop every captured row and reset the selection.  Used during a
  ## session switch / fresh tracepoint run.
  vm.entries.val = @[]
  vm.selectedIndex.val = NO_SELECTED_INDEX

proc selectEntry*(vm: TraceLogVM; index: int) =
  ## Refresh the selected-row reference.  ``NO_SELECTED_INDEX``
  ## clears the selection.  Out-of-range indices that are not the
  ## sentinel are clamped to the sentinel so the view never paints
  ## a phantom selection on a non-existent row.
  let total = vm.entries.val.len
  if index == NO_SELECTED_INDEX or index < 0 or index >= total:
    vm.selectedIndex.val = NO_SELECTED_INDEX
  else:
    vm.selectedIndex.val = index

proc jumpToEntry*(vm: TraceLogVM; index: int) =
  ## Dispatch ``ct/event-jump`` for the row at ``index``.  Mirrors the
  ## legacy ``CtEventJump`` payload (a ``ProgramEvent`` whose
  ## ``rrEventId`` field carries the event identifier).  An out-of-
  ## range index is a silent no-op.
  let rows = vm.entries.val
  if index < 0 or index >= rows.len:
    return
  let entry = rows[index]
  vm.selectedIndex.val = index
  let args = %*{
    "eventId": entry.eventId,
    "rrTicks": entry.rrTicks,
    "path": entry.path,
    "line": entry.line,
  }
  vm.store.requestHistoricalNavigation("ct/event-jump", args)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createTraceLogVM*(store: ReplayDataStore): TraceLogVM =
  ## Create a TraceLogVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty/inert default
  ## so the view renders the empty-state placeholder on first paint.
  withViewModel proc(dispose: proc()): TraceLogVM =
    let entries = createSignal(newSeq[TraceLogEntry]())
    let selectedIndex = createSignal(NO_SELECTED_INDEX)

    let isEmpty = createMemo[bool] proc(): bool =
      entries.val.len == 0

    let rowCount = createMemo[int] proc(): int =
      entries.val.len

    TraceLogVM(
      store: store,
      entries: entries,
      selectedIndex: selectedIndex,
      isEmpty: isEmpty,
      rowCount: rowCount,
      disposeProc: dispose,
    )
