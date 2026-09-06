## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade —
## and never `viewmodel/*` directly.
##
## app/timeline_binding.nim — CTUI-8. The ONE place that turns `TimelineVM`,
## `EventLogVM` and a recorded calltrace into a `TimelineBarModel` and an
## `EventLogModel`.
##
## Same split, same three reasons, as CTUI-5's `source_binding.nim`, CTUI-6's
## `call_stack_binding.nim` and CTUI-7's `variables_binding.nim`: the views stay
## pure functions of a value, two stops stay comparable, and the panes' memory
## ceiling stays a property of a field a reader can see. This module reads;
## `views/timeline_bar.nim` and `views/event_log.nim` draw.
##
## ## WHAT THE TWO VIEWMODELS ACTUALLY OWN, MEASURED RATHER THAN ASSUMED
##
## Established by reading `src/frontend/viewmodel/` AND by running all three
## fixtures of CTUI-1's corpus through a real `replay-server`, 2026-09-06.
## Recorded here because the next reader would otherwise re-derive it, and
## because two of the four answers are the shape CTUI-5 found in
## `PointListVM.points`.
##
## 1. **`TimelineVM.currentPosition` and `TimelineVM.seek` are REAL, and they
##    are the product's own seek path.** `currentPosition` is a memo over
##    `store.debugger.rrTicks`; `seek` sends `ct/timeline-seek`, which
##    `dap_server.rs` routes straight into `Handler::goto_ticks`. Measured on
##    `noir_space_ship`: `TimelineVM.seek(300)` moved the store to tick 300,
##    line 12, and `SourceVM`, `StateVM`, `CalltraceVM` and `DebugControlsVM`
##    all read the same tick off the same store. That is CTUI-8's atomic
##    `goto`, and `tests/test_event_log_jump.nim` asserts all four panes.
##
## 2. **`TimelineVM.markers` is filled by NOTHING on a replay session, so the
##    scrubber's bounds do not come from it.** `markers` is a memo over
##    `store.timeline`, and the only writers of `store.timeline` are
##    `ReplayDataStore.updateRecordingHead` and the success arm of
##    `requestRestoreAt` — both LIVE-MCR paths, guarded by
##    `debugSessionMode in {liveMcr, liveMaterialized, historicalFromLive}` —
##    plus the collaboration signal serialiser. Measured: `markers == @[]` and
##    `store.timeline == (0, 0, 0)` on all three fixtures, before and after
##    stepping, and `seekAtFraction` returns early on `marks.len < 2` and does
##    nothing at all. `TimelineVM.seek` is unaffected and is what this binding
##    uses.
##
##    The recording's last tick DOES have a real source: every
##    `ct/event-load` row carries `maxRRTicks`, which the engine builds from the
##    reader's last step (`dap_handler.rs`'s `max_rr_ticks` arm and
##    `db.rs:1825`'s `last_step_id.0`). Measured: 171 on `calc`, 1314 on
##    `noir_space_ship`, 3896 on `wide_state`, one distinct value per recording.
##    `boundsFromEvents` reads it, and `timelineBarModelFor` asks the VM FIRST
##    so the day a host fills `store.timeline` the pane uses it — an
##    availability that were a constant would go on ignoring the signal.
##
## 3. **`EventLogVM.eventRows` is filled by NOTHING from a `ct/event-load`
##    response.** The auto-load effect in `viewmodels/event_log_vm.nim` sends
##    `ct/event-load` and hands the answer to `applyMarkerRowsResponse`, which
##    writes `markerRows` — the M25b correlation-marker projection — and never
##    `eventRows`. The only writer of `eventRows` is `appendLiveDebuggerStop`,
##    whose one product call site (`src/frontend/ui/event_log.nim`) is guarded
##    by `liveEventLogSession()`. Measured: `eventRows.len == 0` and
##    `markerRows.len == 0` on all three fixtures after a real `ct/event-load`
##    that returned 6, 70 and 6 events respectively.
##
##    So this binding takes the event page as a VALUE from the seam the host
##    wires to `ct/event-load` — exactly as CTUI-5 takes its breakpoints and
##    CTUI-6 its frames, and for the same class of reason. `EventLogVM` still
##    owns what it really owns: the SELECTION (`selectedRow`), the page size and
##    the page index, and `publishSelection` puts the pane's cursor there.
##
## 4. **Call boundaries are REAL and are the backend's own.**
##    `ct/load-calltrace-section` answers rows carrying `rrTicks` and `depth`.
##    Measured on `calc`: `@[0, 17, 21, 29, 32, 41, …]`, ascending, and a
##    `stackTrace` taken after seeking to one of them reports that call's name
##    as the top frame — two independent surfaces agreeing that the tick is a
##    call boundary. `tests/test_call_boundary_seeking.nim` asserts exactly that
##    pair, which is what "boundaries the backend agrees are boundaries" means.
##
## ## No mocks
##
## Nothing here constructs a ViewModel, a store or a backend. It takes the ones
## a real session built.

import std/[algorithm, options]

import codetracer_embed

import ./input/timeline_keys
import ./views/event_log
import ./views/timeline_bar
import ./views/tracepoint_manager

export event_log, timeline_bar, timeline_keys, tracepoint_manager

const
  NoTimelineBoundsNote* =
    "store.timeline is written only by the live-MCR paths; the bound comes " &
    "from ct/event-load's maxRRTicks"
  NoMarksNote* =
    "no tracepoint has been run over this recording"
  NoBookmarksNote* =
    "there is no bookmark concept in the ViewModel layer"
    ## §3.3.5's `◆` is "user-defined tracepoints AND bookmarks". A grep over
    ## `src/frontend/viewmodel/` on 2026-09-06 finds no bookmark of a TICK
    ## anywhere — every hit is a browser bookmark in the platform layer — so a
    ## bookmark here can only be one made in this session, and nothing persists
    ## it. Stated rather than left implicit so the day a store gains one, the
    ## one place to change is this constant and `marksFrom`.
  EmptyLogNote* =
    "the recording carries no events"

# ---------------------------------------------------------------------------
# Bounds
# ---------------------------------------------------------------------------

type
  TimelineBounds* = object
    ## The recording's extent, and where the answer came from.
    minTick*: uint64
    maxTick*: uint64
    known*: bool
    source*: string
      ## `"TimelineVM.markers"` or `"ct/event-load.maxRRTicks"`. Carried so a
      ## failure message says which surface answered, and so a test can assert
      ## that the fallback really was the fallback.

proc boundsFromVm*(vm: TimelineVM): TimelineBounds =
  ## `TimelineVM.markers`, when it has anything. See this module's header for
  ## why it normally does not, and why it is still asked first.
  result = TimelineBounds(minTick: 0, maxTick: 0, known: false, source: "")
  if vm.isNil:
    return
  let marks = vm.markers.val
  if marks.len < 2 or marks[1] <= marks[0]:
    return
  result = TimelineBounds(minTick: marks[0], maxTick: marks[1], known: true,
                          source: "TimelineVM.markers")

proc boundsFromEvents*(events: openArray[EventRow];
                       maxRRTicks: uint64): TimelineBounds =
  ## `ProgramEvent.maxRRTicks`, which is the recording's last step id.
  ##
  ## Takes the value the caller read off the wire rather than re-deriving it
  ## from `events`, because a recording with NO events still has a last step and
  ## the pane must still be able to draw a track for it. `events` is taken so
  ## that a caller with rows and no `maxRRTicks` still gets bounds that at least
  ## contain every event it holds — which is a weaker claim, and `source` says
  ## so.
  if maxRRTicks > 0:
    return TimelineBounds(minTick: 0, maxTick: maxRRTicks, known: true,
                          source: "ct/event-load.maxRRTicks")
  var highest = 0'u64
  for row in events:
    if row.tick > highest:
      highest = row.tick
  if highest == 0:
    return TimelineBounds(minTick: 0, maxTick: 0, known: false, source: "")
  TimelineBounds(minTick: 0, maxTick: highest, known: true,
                 source: "ct/event-load.events")

proc resolveBounds*(vm: TimelineVM; events: openArray[EventRow];
                    maxRRTicks: uint64): TimelineBounds =
  ## The VM first, the wire second. See this module's header.
  let fromVm = boundsFromVm(vm)
  if fromVm.known:
    return fromVm
  boundsFromEvents(events, maxRRTicks)

# ---------------------------------------------------------------------------
# Call spans and boundaries
# ---------------------------------------------------------------------------

proc spansFromCalltrace*(lines: openArray[CallLine];
                         maxTick: uint64): seq[TimelineSpan] =
  ## `ct/load-calltrace-section`'s rows as scrubber spans.
  ##
  ## A call's END is not on the wire — `CallLine` carries the tick the call
  ## STARTED at and its `depth`, and nothing says where it returned. So a span
  ## runs from its own tick to the next tick at the SAME OR SHALLOWER depth,
  ## which is where the call must have finished, and the last one runs to the
  ## end of the recording. That inference is stated here rather than hidden: it
  ## is exact for a well-nested calltrace and it is the only thing the answer
  ## supports.
  result = @[]
  for i, line in lines:
    var endTick = maxTick
    for j in i + 1 ..< lines.len:
      if lines[j].depth <= line.depth:
        endTick = (if lines[j].rrTicks > line.rrTicks: lines[j].rrTicks - 1
                   else: line.rrTicks)
        break
    result.add TimelineSpan(startTick: line.rrTicks,
                            endTick: max(endTick, line.rrTicks),
                            depth: line.depth, name: line.name)

proc boundariesFromCalltrace*(lines: openArray[CallLine]): seq[uint64] =
  ## The ticks `[` and `]` may land on: one per recorded call, ascending and
  ## deduplicated.
  ##
  ## THE BACKEND'S OWN NUMBERS, unmodified. Sorted here only so a failure
  ## message reads in the order a reader expects; `timeline_keys.nextAfter` does
  ## not require it.
  result = @[]
  for line in lines:
    if line.rrTicks notin result:
      result.add line.rrTicks
  result.sort()

proc nameAtBoundary*(lines: openArray[CallLine]; tick: uint64): string =
  ## Which call the backend says starts at `tick`, or "".
  for line in lines:
    if line.rrTicks == tick:
      return line.name

# ---------------------------------------------------------------------------
# The event log
# ---------------------------------------------------------------------------

proc mutationTicks*(rows: openArray[EventRow]): seq[uint64] =
  ## The ticks `{` and `}` may land on: recorded writes that did NOT go to a
  ## terminal.
  ##
  ## §4.2 calls them "memory/storage writes" and `views/event_log.categoryFor`
  ## is the one place that decides which wire kinds those are. EVERY event in
  ## CTUI-1's corpus is `Write` with `stdout = true`, so this returns `@[]` on
  ## all three fixtures and `tests/test_event_log_jump.nim` asserts that as an
  ## equality — the day a recorder emits a storage write, the suite says so.
  result = @[]
  for row in rows:
    if row.category == ecMutation and row.tick notin result:
      result.add row.tick
  result.sort()

proc eventLogModelFor*(pages: EventPages;
                       currentTick: uint64;
                       pageSize = DefaultEventPageSize;
                       note = EmptyLogNote): EventLogModel =
  ## The pane's model over a server-pagination seam.
  ##
  ## Nothing is fetched here: `ensureWindow` is the one entry point and the
  ## caller decides which window it needs. See `views/event_log.nim`'s header.
  initEventLogModel(pages = pages, pageSize = pageSize,
                    currentTick = currentTick, note = note)

proc publishSelection*(vm: EventLogVM; model: EventLogModel) =
  ## Put the pane's cursor where `EventLogVM` keeps it.
  ##
  ## `selectRow` writes ONE signal and issues no backend command, which is the
  ## property CTUI-6 needed from `CalltraceVM.selectEntry` and CTUI-7 from
  ## `StateVM.selectPath`: moving a cursor must not move the program. The SEEK
  ## is a separate, explicit act — see `seekTo` below — and that separation is
  ## what makes "one selection, one atomic goto" countable.
  if vm.isNil:
    return
  if model.selected < 0:
    vm.selectRow(none(int))
  else:
    vm.selectRow(some(model.selected))

proc seekTo*(vm: TimelineVM; tick: uint64) =
  ## THE ONE SEEK. `TimelineVM.seek` sends `ct/timeline-seek`, which the engine
  ## routes into `goto_ticks` and answers with a `stopped` + `ct/complete-move`
  ## pair; the host pumps those and every pane reads the new position off the
  ## one store. Wrapped here rather than called directly so that every seek in
  ## this front-end goes through one line of code, which is what makes "exactly
  ## one goto per selection" a property a test can count.
  if vm.isNil:
    return
  vm.seek(tick)

# ---------------------------------------------------------------------------
# The scrubber
# ---------------------------------------------------------------------------

proc timelineBarModelFor*(vm: TimelineVM;
                          bounds: TimelineBounds;
                          spans: seq[TimelineSpan] = @[];
                          marks: seq[TimelineMark] = @[];
                          currentTick = 0'u64): TimelineBarModel =
  ## The scrubber's model for the CURRENT stop.
  ##
  ## `currentTick` defaults to the VM's own `currentPosition` when a VM is
  ## given, so the needle is on the memo the product renders rather than on a
  ## number the caller happened to have.
  let tick =
    if not vm.isNil and currentTick == 0'u64: vm.currentPosition.val
    else: currentTick
  initTimelineBarModel(
    minTick = bounds.minTick,
    maxTick = bounds.maxTick,
    currentTick = tick,
    boundsKnown = bounds.known,
    boundsNote = (if bounds.known: "" else: NoTimelineBoundsNote),
    spans = spans,
    marks = marks,
    marksNote = (if marks.len > 0: "" else: NoMarksNote))

proc targetsFor*(bounds: TimelineBounds;
                 callBoundaries: seq[uint64];
                 mutations: seq[uint64]): TimelineTargets =
  ## Everything `[`, `]`, `{`, `}` and `t <tick> Enter` may land on.
  TimelineTargets(callBoundaries: callBoundaries, mutations: mutations,
                  minTick: bounds.minTick, maxTick: bounds.maxTick)
