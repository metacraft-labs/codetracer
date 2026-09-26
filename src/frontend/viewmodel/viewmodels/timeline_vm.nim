## viewmodels/timeline_vm.nim
##
## TimelineVM — ViewModel for the Timeline panel.
##
## Holds reactive state for:
## - Zoom level
## - View window (start/end ticks)
## - Hovered tick position
##
## Derives:
## - `currentPosition`: the debugger's current rrTicks position
## - `bounds`: the recording's extent as `@[minTick, maxTick]`, or `@[]`
## - `markers`: recorded CALL, RETURN and ERROR events as tick positions
## - `tickLabels`: the ticks the pane writes numbers at, for the current zoom
##
## Also creates an auto-load effect that sends a seek command to the
## backend when the user navigates to a different tick.
##
## Usage:
##   let vm = createTimelineVM(store)
##   echo vm.zoomLevel.val             # 1.0
##   vm.zoom(2.0)
##   echo vm.currentPosition.val       # derived from store
##
## ## WHERE THE TIMELINE'S DATA COMES FROM, MEASURED RATHER THAN ASSUMED
##
## Established 2026-09-24 by reading the DAP surface (`dap_server.rs`,
## `dap_handler.rs`, `store/replay_data_store.nim`) for issue #693, whose
## first question was whether the payload feeding this pane carries event
## kinds at all. The answer decides what the pane can honestly draw, so it is
## recorded here rather than left to the next reader to re-derive.
##
## 1. **There is no timeline READ route.** `ct/timeline-seek` is the only
##    `timeline` string on the wire (`dap_server.rs:2171`), and it is a WRITE
##    — `dap_server.rs` routes it straight into `Handler::goto_ticks`. Nothing
##    asks the engine for a timeline and nothing answers with one.
##
## 2. **`store.timeline` is three integers and carries no kinds.**
##    `TimelineState` (`store/types.nim`) is `minRRTicks` / `maxRRTicks` /
##    `currentRRTicks`. Its writers are the live-MCR recording-head update,
##    the success arm of `requestRestoreAt`, the collaboration signal
##    serialiser, and — since PLAT-41 — `applyEventLogRows`, which raises
##    `maxRRTicks` to the extent the event log learned. That is the whole of
##    it. So `bounds` below is *exactly* the old `markers`, renamed to say
##    what it is.
##
## 3. **Event kinds with ticks DO exist in this store, from two OTHER routes.**
##    - `ct/load-calltrace-section` → `CalltraceStore.lines`, whose `CallLine`
##      carries `rrTicks`, `depth` and `name`. Those ticks are the backend's
##      own call boundaries; the TUI measured them against `stackTrace` on the
##      `calc` fixture and the two agree (`tui/app/timeline_binding.nim`, §4).
##      **A call's END is not on the wire**, so a RETURN is inferred: a frame
##      is last live just before the next row at the same or shallower depth.
##      Exact for a well-nested calltrace, and the only thing the answer
##      supports.
##    - `ct/event-load` → `EventLogStore.rows`, whose `EventLogRow` carries
##      `kindId` and `rrTicks`. **`EventLogKind` has no `Call` and no
##      `Return`** (`common/common_types/codetracer_features/events.nim`) —
##      it is an I/O vocabulary — so the only one of `Electron-GUI.md:155`'s
##      three kinds it can answer is the third: `Error`, which the engine
##      writes for a recorded error/exception (`dap_handler.rs`'s
##      `prepare_eventual_error_event_message`, `trace_processor.rs`'s
##      `EndOfProgram::Error`).
##
## 4. **Both of those signals hold a WINDOW, not the whole recording.**
##    `EventLogStore.rows`' own doc comment says so ("a page and not the whole
##    log"), and `CalltraceStore` carries `startLineIndex` / `totalCallsCount`
##    / `finished` for the same reason. So `markers` is a projection of *what
##    this session has loaded*, and a pane must say so rather than imply the
##    marks are everything the recording contains. A whole-recording marker
##    set needs a backend route that does not exist; that is separate work.

import std/[algorithm, json, math, options, strutils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
  TimelineMarkerKind* = enum
    ## The three event kinds `Front-Ends/Electron-GUI.md:155` obliges the
    ## timeline to mark: *"Event markers (calls, returns, exceptions)"*.
    ##
    ## Deliberately only three. Bookmarks, tracepoint hits and multi-track
    ## lanes are a design question with no normative spec section behind it
    ## (the BlockTracer research at `BlockTracer/Debugger-UX-Research.md` §7.1
    ## argues for event-typed lanes, but it is research about the BlockTracer
    ## static page and does not govern this pane), so they are not modelled
    ## here rather than modelled speculatively.
    tmkCall       ## A recorded call's ENTRY tick — `CallLine.rrTicks`.
    tmkReturn     ## The last tick a recorded call's frame was live at.
    tmkException  ## A recorded error event — `EventLogKind.Error`.

  TimelineMarker* = object
    ## One mark on the timeline track.
    tick*: uint64
    kind*: TimelineMarkerKind
    label*: string
      ## What the mark is, for a tooltip and for a failure message: the
      ## function name for a call or a return, the event's display kind for
      ## an exception. May be empty when the producer gave none.

  TimelineVM* = ref object of ViewModel
    ## Reactive state for the Timeline panel.
    ##
    ## Mutable signals:
    ##   zoomLevel    — the current zoom factor (1.0 = default)
    ##   viewStart    — first visible tick in the timeline viewport
    ##   viewEnd      — last visible tick in the timeline viewport
    ##   hoveredTick  — tick under the cursor, or none
    ##
    ## Derived memos:
    ##   currentPosition — the debugger's current rrTicks
    ##   bounds          — the recording's extent, from the timeline state
    ##   markers         — recorded call / return / error events
    ##   tickLabels      — the ticks the pane writes numbers at
    ##
    ## The store reference is kept for derived state and seek actions.
    store*: ReplayDataStore

    # -- Mutable state --
    zoomLevel*: Signal[float]
    viewStart*: Signal[uint64]
    viewEnd*: Signal[uint64]
    hoveredTick*: Signal[Option[uint64]]

    # -- Derived state --
    currentPosition*: Memo[uint64]

    bounds*: Memo[seq[uint64]]
      ## The recording's extent as `@[minTick, maxTick]`, or `@[]` when it is
      ## not known yet.
      ##
      ## **This field was called `markers` until 2026-09-24**, and the rename
      ## is the point rather than tidying: a reader who asked this ViewModel
      ## for "markers" got two numbers that are not marks of anything, and
      ## `timeline_vm_test.nim` pinned that as correct behaviour under the
      ## name *"markers returns min and max when timeline has data"*. The
      ## extent and the marks are two different facts and now have two names.
      ##
      ## The `seq` shape (rather than a `TimelineBounds` object) is kept
      ## because `tui/app/timeline_binding.boundsFromVm`, `gpui/app/leaves`
      ## and `views/isonim_timeline_view` all read it as `marks[0]` /
      ## `marks[1]` guarded by `len < 2`, and a rename that also changed the
      ## shape would have mixed two changes in one diff.

    markers*: Memo[seq[TimelineMarker]]
      ## Recorded calls, returns and errors, ascending by tick.
      ##
      ## A projection of the calltrace and event-log WINDOWS this session has
      ## loaded — see this module's header, point 4. Empty is a completely
      ## ordinary answer: neither pane has to have loaded anything.

    tickLabels*: Memo[seq[uint64]]
      ## The ticks the pane writes a number at, ascending, first and last
      ## always included. Empty when the extent is unknown.

# ---------------------------------------------------------------------------
# The `EventLogKind.Error` ordinal, derived-checked
# ---------------------------------------------------------------------------
#
# `EventLogRow.kindId` is the wire's numeric `EventLogKind`, kept verbatim by
# `replay_data_store.eventLogRowFromJson` on purpose. To recognise the error
# kind this module needs that enum's ordinal — and it cannot import the enum:
# `common/common_types/codetracer_features/events.nim` needs `langstring` from
# its parent, and `store/types.nim` is deliberately *"independent of the legacy
# frontend types to avoid circular imports"*.
#
# So the ordinal is written down, exactly as `edit_mode_toolbar.ToolbarMode`
# mirrors `LayoutMode` — and, like that mirror, it is DERIVED-CHECKED against
# the declaration so it cannot drift silently. A hand-maintained magic number
# is the failure mode this repository has been bitten by repeatedly; a number
# whose build fails when the enum is reordered is not.

const EventLogKindSrc =
  staticRead("../../../common/common_types/codetracer_features/events.nim")

const ErrorEventKindId* = 11
  ## `ord(EventLogKind.Error)`. Checked below against the declaration.

static:
  # Anchored to the DECLARATION, not to a doc comment: the module's prose
  # mentions several of these words too, and a scan that matches prose is
  # satisfied by prose (`Verification-Harness-Traps.md` §4d).
  let at = EventLogKindSrc.find("EventLogKind* {.pure.} = enum")
  doAssert at >= 0,
    "EventLogKind is no longer declared where timeline_vm reads it"
  var declared: seq[string] = @[]
  for line in EventLogKindSrc[at .. ^1].splitLines:
    let t = line.strip
    if t.startsWith("EventLogKind*"): continue
    if t.len == 0 or t.startsWith("#"): continue
    # A member is a bare identifier with a trailing comma. The first line
    # carrying `*` or `=` is the next declaration, which ends the enum.
    if '*' in t or '=' in t: break
    declared.add t.strip(chars = {',', ' '})
  doAssert declared.len > ErrorEventKindId,
    "EventLogKind declares only " & $declared.len & " members: " & $declared
  doAssert declared[ErrorEventKindId] == "Error",
    "EventLogKind ordinal " & $ErrorEventKindId & " is '" &
      declared[ErrorEventKindId] & "', not 'Error': " & $declared

# ---------------------------------------------------------------------------
# Projections — pure, so a test can drive them without a store
# ---------------------------------------------------------------------------

func callMarkers*(lines: openArray[CallLine]): seq[TimelineMarker] =
  ## The call-entry and inferred-return marks of one calltrace window.
  ##
  ## The entry tick is the backend's own (`CallLine.rrTicks`). The RETURN is
  ## inferred, because a call's end is not on the wire: a frame is last live
  ## just before the next row at the same or shallower depth. The SAME rule
  ## `tui/app/timeline_binding.spansFromCalltrace` uses, stated here rather
  ## than hidden, and it is exact for a well-nested calltrace.
  ##
  ## **The last call of a window gets no return mark**, and neither does any
  ## frame still open when the window ends. `spansFromCalltrace` ends its span
  ## at `maxTick` because a span must have an end; a marker need not exist at
  ## all, and inventing one would put a return where the wire says nothing —
  ## which is exactly the kind of plausible-looking fabrication this pane is
  ## being repaired for.
  ##
  ## ONE PASS WITH A DEPTH STACK, not the nested scan `spansFromCalltrace`
  ## uses. The two agree row for row — a frame is closed by the next row at
  ## the same or shallower depth either way — but the nested scan is O(n²) on
  ## a monotonically deepening window, and this memo recomputes on every
  ## calltrace page. The TUI's version answers a handful of spans for one
  ## screen; this one can be handed a whole page.
  result = @[]
  var openFrames: seq[int] = @[]   ## indices into `lines`, deepest last
  for j, line in lines:
    # Every frame at this depth or deeper ended before `line` began. Popping
    # deepest-first means that when several end at the same tick, the
    # INNERMOST is the one that survives the `(tick, kind)` dedup in
    # `sortedMarkers` — the more specific answer for a tooltip.
    while openFrames.len > 0 and lines[openFrames[^1]].depth >= line.depth:
      let closed = openFrames.pop()
      if line.rrTicks > lines[closed].rrTicks:
        result.add TimelineMarker(tick: line.rrTicks - 1, kind: tmkReturn,
                                  label: lines[closed].name)
    result.add TimelineMarker(tick: line.rrTicks, kind: tmkCall,
                              label: line.name)
    openFrames.add j

func exceptionMarkers*(rows: openArray[EventLogRow]): seq[TimelineMarker] =
  ## The error marks of one event-log window.
  ##
  ## `EventLogKind.Error` is the ONLY one of `Electron-GUI.md:155`'s three
  ## kinds the event log can answer — that enum has no `Call` and no `Return`
  ## (see this module's header, point 3).
  result = @[]
  for row in rows:
    if row.kindId == ErrorEventKindId:
      result.add TimelineMarker(tick: row.rrTicks, kind: tmkException,
                                label: row.kind)

func sortedMarkers*(marks: seq[TimelineMarker]): seq[TimelineMarker] =
  ## Ascending by tick, then by kind so the order is total and a failure
  ## message reads the same on every run. Duplicates of the same `(tick,
  ## kind)` collapse: two windows can overlap, and one recorded call must not
  ## become two marks because the pane paged twice.
  result = marks
  result.sort(proc(a, b: TimelineMarker): int =
    if a.tick < b.tick: -1
    elif a.tick > b.tick: 1
    elif ord(a.kind) < ord(b.kind): -1
    elif ord(a.kind) > ord(b.kind): 1
    else: 0)
  var deduped: seq[TimelineMarker] = @[]
  for m in result:
    if deduped.len > 0 and deduped[^1].tick == m.tick and
       deduped[^1].kind == m.kind:
      continue
    deduped.add m
  result = deduped

func tickLabelCount*(zoomLevel: float): int =
  ## How many numbers the pane writes along the track at this zoom.
  ##
  ## Five at 1x, one more per doubling, one fewer per halving, clamped to
  ## 2..9. The rule is about LABEL DENSITY and nothing else: the pane draws
  ## the whole recording, because `viewStart` / `viewEnd` are written by
  ## `pan` and read by nobody, so zoom cannot yet change the rendered RANGE.
  ## Wiring a visible window is panning semantics and is out of scope for
  ## issue #693 — see `Pxor-Bugs.milestones.org` M51.
  let level = if zoomLevel > 0.0: zoomLevel else: 0.1
  let steps = int(floor(log2(level)))
  result = 5 + steps
  if result < 2: result = 2
  elif result > 9: result = 9

func tickLabelsFor*(minTick, maxTick: uint64; count: int): seq[uint64] =
  ## `count` ticks evenly spaced across `[minTick, maxTick]`, both ends
  ## included. Empty when the range is not a range.
  result = @[]
  if maxTick <= minTick or count < 2:
    return
  let span = maxTick - minTick
  for i in 0 ..< count:
    # Multiply before dividing so the ends land exactly on `minTick` and
    # `maxTick` rather than one tick short of them.
    result.add minTick + (span * uint64(i)) div uint64(count - 1)

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc seek*(vm: TimelineVM; tick: uint64) =
  ## Navigate to the given tick in the recording.
  ## Live sessions must restore from the growing recording; completed replay
  ## sessions use the generic timeline seek command.
  let mode = vm.store.session.val.debugSessionMode
  if mode in {liveMcr, liveMaterialized, historicalFromLive}:
    vm.store.requestRestoreAt(tick)
  else:
    let args = %*{"rrTicks": tick}
    vm.store.requestHistoricalNavigation("ct/timeline-seek", args)

proc seekAtFraction*(vm: TimelineVM; fraction: float) =
  ## Navigate by a 0..1 position along the visible timeline range.
  let extent = vm.bounds.val
  if extent.len < 2 or extent[1] <= extent[0]:
    return
  let clamped = min(1.0, max(0.0, fraction))
  let startTick = extent[0]
  let range = extent[1] - extent[0]
  let offset = uint64(round(float(range) * clamped))
  vm.seek(startTick + offset)

proc tickAtFraction*(vm: TimelineVM; fraction: float): Option[uint64] =
  ## The tick a 0..1 position along the track points at, or `none` when the
  ## extent is unknown.
  ##
  ## **One arithmetic, one function.** `seekAtFraction` navigates and this
  ## answers; before they shared a body, a hover reading one tick and a click
  ## seeking to another was constructible, and `Verification-Harness-Traps.md`
  ## §30 is about exactly that — two copies of one predicate let a control
  ## agree with itself while the rule is broken.
  let extent = vm.bounds.val
  if extent.len < 2 or extent[1] <= extent[0]:
    return none(uint64)
  let clamped = min(1.0, max(0.0, fraction))
  let range = extent[1] - extent[0]
  some(extent[0] + uint64(round(float(range) * clamped)))

proc zoom*(vm: TimelineVM; level: float) =
  ## Set the zoom level. Values below 0.1 are clamped.
  if level < 0.1:
    vm.zoomLevel.val = 0.1
  else:
    vm.zoomLevel.val = level

proc pan*(vm: TimelineVM; startTick: uint64; endTick: uint64) =
  ## Set the visible window of the timeline.
  vm.viewStart.val = startTick
  vm.viewEnd.val = endTick

proc hover*(vm: TimelineVM; tick: Option[uint64]) =
  ## Set the hovered tick. Pass `none(uint64)` to clear.
  vm.hoveredTick.val = tick

proc hoverAtFraction*(vm: TimelineVM; fraction: float) =
  ## Put the hover cursor at a 0..1 position along the track.
  ##
  ## The `.timeline-hover-tooltip` element and `hoveredTick` have existed
  ## since the pane was written and NOTHING in the web renderer ever wrote
  ## the signal, so the tooltip could not appear in the product — only in the
  ## headless view tests, which call `vm.hover` directly. This is the action
  ## the renderer's `mousemove` needs.
  vm.hover(vm.tickAtFraction(fraction))

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createTimelineVM*(store: ReplayDataStore): TimelineVM =
  ## Create a TimelineVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for `currentPosition`, `bounds`, `markers` and
  ##    `tickLabels`
  withViewModel proc(dispose: proc()): TimelineVM =
    let zoomLevel = createSignal(1.0)
    let viewStart = createSignal(0'u64)
    let viewEnd = createSignal(0'u64)
    let hoveredTick = createSignal(none(uint64))

    # Derived: the debugger's current position in the recording.
    let currentPosition = createMemo[uint64] proc(): uint64 =
      store.debugger.val.rrTicks

    # Derived: the recording's extent (min, max ticks from the timeline).
    let bounds = createMemo[seq[uint64]] proc(): seq[uint64] =
      let tl = store.timeline.val
      if tl.maxRRTicks == 0'u64:
        return newSeq[uint64]()
      @[tl.minRRTicks, tl.maxRRTicks]

    # Derived: the recorded events this session has loaded, as marks. See the
    # module header for what each source can and cannot answer.
    let markers = createMemo[seq[TimelineMarker]] proc(): seq[TimelineMarker] =
      sortedMarkers(callMarkers(store.calltrace.lines.val) &
                    exceptionMarkers(store.eventLog.rows.val))

    # Derived: where the pane writes numbers, at the current zoom.
    let tickLabels = createMemo[seq[uint64]] proc(): seq[uint64] =
      let extent = bounds.val
      if extent.len < 2:
        return newSeq[uint64]()
      tickLabelsFor(extent[0], extent[1], tickLabelCount(zoomLevel.val))

    TimelineVM(
      store: store,
      zoomLevel: zoomLevel,
      viewStart: viewStart,
      viewEnd: viewEnd,
      hoveredTick: hoveredTick,
      currentPosition: currentPosition,
      bounds: bounds,
      markers: markers,
      tickLabels: tickLabels,
      disposeProc: dispose,
    )
