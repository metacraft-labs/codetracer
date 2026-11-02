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
## THE LOCALS ARE READ BY WINDOW (Viewport-Driven-Loading, Decided Q4).
## A sweep's answer carries each hit's tick and location, which is what a
## row and the timeline need; the view reports the rows it shows
## (``setViewport``) and the locals of those rows are read from the engine
## — ``ct/update-table`` on each tracepoint's event slot, for the window of
## that tracepoint's hits the rows span — once per row.
##
## ``string`` is used everywhere so the same value works on both
## native (``test-vm-native``) and JS (``test-vm-js``) backends without
## ``cstring`` / ``langstring`` conversion noise.

import std/[algorithm, json, strutils, tables]
import ./action_sink

import isonim/core/[signals, computation, owner, batch, async_compat]
import isonim/viewmodel

import ../../../common/value_presentation
import ../backend/backend_service
import ../store/[replay_data_store, types]
from ../store/locals_answer import presentedValueText
import ../viewport

export viewport

const NO_SELECTED_INDEX* = -1
  ## Sentinel value for ``selectedIndex`` meaning "no row selected".

type
  TraceLogVM* = ref object of ViewModel
    ## Reactive state for the Trace Log panel.
    actionSink*: ActionSink
      ## Set in a mirror session: user actions go to the primary
      ## (`action_sink`); nil on a primary.
    store*: ReplayDataStore

    # -- Mutable state --
    entries*: Signal[seq[TraceLogEntry]]
    selectedIndex*: Signal[int]
    viewport*: Signal[Viewport]
      ## The rows the view shows (`setViewport`).
    viewportGate: ViewportGate

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

proc setSweepHits*(vm: TraceLogVM; hits: seq[TracepointSweepHit];
                   maxRRTicks: int) =
  ## The rows of one sweep's answer (`ct/tracepoint-results`) for a front-end
  ## that holds the answer as the store's hits rather than as the desktop's
  ## legacy stops (`ui/trace_log.nim`): the VS Code extension host. One row
  ## per hit; the locals are read by window, as on the desktop
  ## (Viewport-Driven-Loading, Decided Q4), except a hit that failed, whose
  ## row says why.
  var rows: seq[TraceLogEntry] = @[]
  for hit in hits:
    rows.add TraceLogEntry(
      rrTicks: int(hit.rrTicks), minRRTicks: 0, maxRRTicks: maxRRTicks,
      path: hit.path, line: hit.line,
      localsText: hit.errorMessage,
      localsLoaded: hit.errorMessage.len > 0,
      tracepointId: hit.tracepointId)
  vm.setEntries(rows)

proc addEntry*(vm: TraceLogVM; entry: TraceLogEntry) =
  ## Append a captured tracepoint stop and re-sort by ``rrTicks``.
  ## Mirrors the legacy ``rows.add`` call inside
  ## ``onTracepointResults`` followed by the DataTables redraw.
  var existing = vm.entries.val
  existing.add(entry)
  existing.sort(cmpByRRTicks)
  vm.entries.val = existing

proc setViewport*(vm: TraceLogVM; v: Viewport) =
  ## The rows the view shows — the ONE way a view tells this ViewModel what
  ## it shows (Viewport-Driven-Loading V1). Debounced on the store's
  ## `viewportScheduler`; the locals of those rows are then read.
  # A mirror reports its measured size to the primary and keeps it too.
  discard vm.actionSink.forwards("viewport", "set", %*{
    "pane": "traceLog", "rows": v.rows, "depth": v.cols,
    "firstRow": v.firstRow})
  vm.viewportGate.submit(v)

proc localsTextOf*(locals: JsonNode): string =
  ## One hit's locals (`StringAndValueTuple`s, `{"Field0": name, "Field1":
  ## value}`) as the row shows them: `name=value`, a `log("…")` message bare.
  if locals.isNil or locals.kind != JArray:
    return
  var parts: seq[string] = @[]
  for pair in locals:
    let name = pair.getOrDefault("Field0").getStr("")
    let value = pair.getOrDefault("Field1")
    let text = presentedValueText(value, TracepointBudget)
    # A `log("…")` argument is a literal whose expression IS its value: the
    # message itself, not `"…"="…"`.
    if name == text:
      parts.add text
    else:
      parts.add name & "=" & text
  parts.join(" ")

proc applyTraceLocals*(vm: TraceLogVM; tracepointId: int;
                       locals: JsonNode) =
  ## Apply one `ct/update-table` answer's `traceLocals` for `tracepointId`:
  ## the locals of its hits, indexed by each hit's place among them.
  if locals.isNil or locals.kind != JArray:
    return
  var rows = vm.entries.val
  var ordinal = 0
  var changed = false
  for i in 0 ..< rows.len:
    if rows[i].tracepointId != tracepointId:
      continue
    if not rows[i].localsLoaded and ordinal < locals.len and
       locals[ordinal].kind == JArray and locals[ordinal].len > 0:
      rows[i].localsText = localsTextOf(locals[ordinal])
      rows[i].localsLoaded = true
      changed = true
    inc ordinal
  if changed:
    vm.entries.val = rows

proc askTraceLocals(vm: TraceLogVM; tracepointId, start, count: int) =
  ## ONE `ct/update-table` on `tracepointId`'s event slot for its hits
  ## `start ..< start + count`, applied when it answers. A proc of its own so
  ## each request's callback holds its own tracepoint (a closure made in a
  ## loop would share the loop's variable).
  let fut = vm.store.backend.send("ct/update-table", %*{
    "tableArgs": {"columns": [], "draw": 0, "length": count, "order": [],
                  "search": {"value": "", "regex": false}, "start": start},
    "selectedKinds": {},
    "isTrace": true,
    "eventSlot": tracepointId})
  onComplete(fut,
    proc(response: JsonNode) =
      if responseSucceeded(response):
        vm.applyTraceLocals(tracepointId,
          responseBody(response).getOrDefault("traceLocals")),
    proc(message: string) = discard)

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
  if vm.actionSink.forwards("traceLog", "selectEntry",
      %*{"index": index}):
    return
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
  if vm.actionSink.forwards("traceLog", "jumpToEntry",
      %*{"index": index}):
    return
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
    let viewport = createSignal(Viewport())
    let viewportGate = newViewportGate(
      proc(): ViewportScheduler =
        if store.isNil: nil else: store.viewportScheduler,
      proc(v: Viewport) = viewport.val = v)

    let isEmpty = createMemo[bool] proc(): bool =
      entries.val.len == 0

    let rowCount = createMemo[int] proc(): int =
      entries.val.len

    let vm = TraceLogVM(
      store: store,
      entries: entries,
      selectedIndex: selectedIndex,
      viewport: viewport,
      viewportGate: viewportGate,
      isEmpty: isEmpty,
      rowCount: rowCount,
      disposeProc: dispose,
    )

    if not store.isNil and not store.backend.isNil:
      # THE WINDOW'S LOCALS: the rows the view shows plus the 20/10
      # buffers. For each tracepoint among the rows not read yet, ONE
      # `ct/update-table` for the window of that tracepoint's hits they
      # span; a window already asked is not asked again.
      var asked = initTable[string, bool]()
      createEffect proc() =
        let w = listWindow(viewport.val)
        let rows = entries.val
        if w.count <= 0 or rows.len == 0:
          return
        var ordinals = initTable[int, int]()
        var spans = initTable[int, (int, int)]()
        for i, row in rows:
          let ord = ordinals.getOrDefault(row.tracepointId, 0)
          ordinals[row.tracepointId] = ord + 1
          if i < w.start or i >= w.start + w.count or row.localsLoaded:
            continue
          let (a, b) = spans.getOrDefault(row.tracepointId, (high(int), -1))
          spans[row.tracepointId] = (min(a, ord), max(b, ord))
        for id, span in spans:
          let (first, last) = span
          let key = $id & ":" & $first & ":" & $last & ":" & $rows.len
          if key in asked:
            continue
          asked[key] = true
          vm.askTraceLocals(id, first, last - first + 1)

    vm
