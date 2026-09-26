## timeline_vm_test.nim
##
## Unit tests for TimelineVM — the ViewModel for the Timeline panel.
##
## Verifies:
## - Initial state defaults (zoomLevel, viewStart, viewEnd, hoveredTick)
## - seek sends a timeline-seek command to the backend
## - zoom updates zoomLevel, clamps below 0.1
## - pan updates viewStart and viewEnd
## - hover sets/clears the hovered tick
## - currentPosition memo reflects the store's debugger rrTicks
## - bounds memo returns min/max ticks from the timeline state
## - markers memo projects loaded calls, returns and error events
## - tickLabels memo gradates the extent at the current zoom
##
## ## WHAT CHANGED HERE FOR ISSUE #693, AND WHY A CASE WAS DELETED
##
## This file used to contain a case named *"markers returns min and max when
## timeline has data"*. It asserted that `TimelineVM.markers` answers two
## numbers — the recording's first and last tick — and it passed, because
## that is what the memo did. It was nevertheless **pinning the defect the
## issue reports as correct behaviour**: a field called `markers` that marks
## nothing makes the absence of call, return and exception marks
## (`Front-Ends/Electron-GUI.md:155`) look like a satisfied requirement to
## anyone reading the suite.
##
## So it is REPLACED rather than joined: the extent now lives on `bounds`,
## whose cases are below under that name and assert exactly what the old ones
## did, and `markers` is a projection of recorded events whose cases assert
## the events.
##
## `Verification-Harness-Traps.md` §7 is why this is written down: a green
## fixture is an assertion about what the world looks like, and this one said
## the world was fine.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/tests/gui/tests/timeline/timeline_vm_test.nim

import std/[json, unittest, options]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/timeline_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc commandsNamed(mock: MockBackendService; command: string):
    seq[ReceivedCommand] =
  for received in mock.receivedCommands:
    if received.command == command:
      result.add(received)

proc call(name: string; tick: uint64; depth: int): CallLine =
  ## One `ct/load-calltrace-section` row, reduced to the three fields the
  ## marker projection reads.
  CallLine(name: name, rrTicks: tick, depth: depth)

proc event(kindId: int; tick: uint64; kind = "event"): EventLogRow =
  ## One `ct/event-load` row, reduced to the two fields the marker
  ## projection reads. `kindId` is the wire's numeric `EventLogKind`, kept
  ## verbatim by `eventLogRowFromJson`.
  EventLogRow(kindId: kindId, kind: kind, rrTicks: tick)

proc kindsOf(marks: seq[TimelineMarker]): seq[TimelineMarkerKind] =
  for m in marks:
    result.add m.kind

proc ticksOf(marks: seq[TimelineMarker]): seq[uint64] =
  for m in marks:
    result.add m.tick

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "TimelineVM initial state":

  test "zoomLevel defaults to 1.0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.zoomLevel.val == 1.0
      dispose()

  test "viewStart defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.viewStart.val == 0'u64
      dispose()

  test "viewEnd defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.viewEnd.val == 0'u64
      dispose()

  test "hoveredTick defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.hoveredTick.val.isNone
      dispose()

  test "currentPosition starts at 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.currentPosition.val == 0'u64
      dispose()

  test "bounds starts empty when maxRRTicks is 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.bounds.val.len == 0
      dispose()

  test "markers starts empty on a store with no calltrace and no events":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.markers.val.len == 0
      dispose()

  test "tickLabels starts empty when the extent is unknown":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.tickLabels.val.len == 0
      dispose()

# ---------------------------------------------------------------------------
# seek
# ---------------------------------------------------------------------------

suite "TimelineVM seek":

  test "seek sends timeline-seek command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      drain()

      let cmdCountBefore = mock.receivedCommands.len

      vm.seek(500'u64)
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "ct/timeline-seek":
          check cmd.args["rrTicks"].getBiggestInt == 500
          found = true
          break
      check found

      dispose()

  test "seek in live MCR restores through live recording":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      store.session.val = SessionState(
        connectionStatus: csConnected,
        debugSessionMode: liveMcr,
        lastLiveDebugSessionMode: liveMcr,
        recordingHeadRRTicks: 900'u64,
        recordingHeadLoadingState: lsIdle,
      )
      let vm = createTimelineVM(store)
      drain()
      mock.clearReceivedCommands()

      vm.seek(500'u64)
      drain()

      let restores = mock.commandsNamed(LiveMcrRestoreAtCommand)
      check restores.len == 1
      if restores.len == 1:
        check restores[0].args["rrTicks"].getBiggestInt == 500
      check store.session.val.debugSessionMode == historicalFromLive

      dispose()

  test "seekAtFraction maps visible timeline position to ticks":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      var tl = store.timeline.val
      tl.minRRTicks = 100'u64
      tl.maxRRTicks = 1100'u64
      store.timeline.val = tl
      let vm = createTimelineVM(store)
      drain()
      mock.clearReceivedCommands()

      vm.seekAtFraction(0.25)
      drain()

      let seeks = mock.commandsNamed("ct/timeline-seek")
      check seeks.len == 1
      if seeks.len == 1:
        check seeks[0].args["rrTicks"].getBiggestInt == 350

      dispose()

# ---------------------------------------------------------------------------
# zoom
# ---------------------------------------------------------------------------

suite "TimelineVM zoom":

  test "zoom updates zoomLevel":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      vm.zoom(3.5)
      check vm.zoomLevel.val == 3.5

      dispose()

  test "zoom clamps values below 0.1":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      vm.zoom(0.05)
      check vm.zoomLevel.val == 0.1

      vm.zoom(-1.0)
      check vm.zoomLevel.val == 0.1

      dispose()

# ---------------------------------------------------------------------------
# pan
# ---------------------------------------------------------------------------

suite "TimelineVM pan":

  test "pan updates viewStart and viewEnd":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      vm.pan(100'u64, 500'u64)
      check vm.viewStart.val == 100'u64
      check vm.viewEnd.val == 500'u64

      dispose()

# ---------------------------------------------------------------------------
# hover
# ---------------------------------------------------------------------------

suite "TimelineVM hover":

  test "hover sets the hovered tick":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      vm.hover(some(42'u64))
      check vm.hoveredTick.val == some(42'u64)

      dispose()

  test "hover with none clears the hovered tick":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      vm.hover(some(42'u64))
      check vm.hoveredTick.val.isSome

      vm.hover(none(uint64))
      check vm.hoveredTick.val.isNone

      dispose()

# ---------------------------------------------------------------------------
# currentPosition memo
# ---------------------------------------------------------------------------

suite "TimelineVM currentPosition":

  test "currentPosition reflects debugger rrTicks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      var dbg = store.debugger.val
      dbg.rrTicks = 750'u64
      store.debugger.val = dbg

      check vm.currentPosition.val == 750'u64

      dispose()

  test "currentPosition updates reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      var dbg = store.debugger.val
      dbg.rrTicks = 100'u64
      store.debugger.val = dbg
      check vm.currentPosition.val == 100'u64

      dbg.rrTicks = 200'u64
      store.debugger.val = dbg
      check vm.currentPosition.val == 200'u64

      dispose()

# ---------------------------------------------------------------------------
# bounds memo — the recording's EXTENT
#
# These two cases are the old "TimelineVM markers" suite, unchanged except for
# the name of the field they read. See this file's header for why the name
# moved.
# ---------------------------------------------------------------------------

suite "TimelineVM bounds":

  test "bounds returns min and max when timeline has data":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      var tl = store.timeline.val
      tl.minRRTicks = 10'u64
      tl.maxRRTicks = 9000'u64
      store.timeline.val = tl

      check vm.bounds.val.len == 2
      check vm.bounds.val[0] == 10'u64
      check vm.bounds.val[1] == 9000'u64

      dispose()

  test "bounds is empty when maxRRTicks is 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      check vm.bounds.val.len == 0

      dispose()

# ---------------------------------------------------------------------------
# markers memo — the recorded EVENTS
#
# `Front-Ends/Electron-GUI.md:155` obliges "Event markers (calls, returns,
# exceptions)". Each of the three has a different provenance and a different
# strength of claim, and the cases are grouped so that is visible:
#
#   * a CALL tick is the backend's own (`CallLine.rrTicks`);
#   * a RETURN tick is INFERRED from `depth`, because a call's end is not on
#     the wire at all;
#   * an EXCEPTION is an `EventLogKind.Error` row — the only one of the three
#     the event-log vocabulary can answer, since it has no Call and no Return.
# ---------------------------------------------------------------------------

suite "TimelineVM markers — calls and returns from the calltrace":

  test "one loaded call yields one call marker and NO return marker":
    ## The last row of a window has no next row at the same or shallower
    ## depth, so nothing on the wire says where its frame ended. The pane must
    ## not invent one — see `callMarkers`' doc comment.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      store.calltrace.lines.val = @[call("main", 10'u64, 0)]

      check vm.markers.val.len == 1
      check vm.markers.val[0].kind == tmkCall
      check vm.markers.val[0].tick == 10'u64
      check vm.markers.val[0].label == "main"

      dispose()

  test "a nested call returns just before the next row at its own depth":
    ## `main`@10 depth 0, `inner`@20 depth 1, `after`@31 depth 1.
    ## `inner`'s frame is last live at 30 — one tick before `after`, the next
    ## row at the same depth. `main` and `after` are the last rows at their
    ## depths and get no return.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      store.calltrace.lines.val = @[
        call("main", 10'u64, 0),
        call("inner", 20'u64, 1),
        call("after", 31'u64, 1),
      ]

      let marks = vm.markers.val
      check kindsOf(marks) == @[tmkCall, tmkCall, tmkReturn, tmkCall]
      check ticksOf(marks) == @[10'u64, 20'u64, 30'u64, 31'u64]
      # The return belongs to `inner`, not to `after`: a mark that carried the
      # wrong name would place the right tick under the wrong function, and a
      # tick-only assertion could not tell the two apart.
      check marks[2].label == "inner"

      dispose()

  test "a call closed by a SHALLOWER row is still closed":
    ## The rule is *"the next row at the same OR shallower depth"*, and this
    ## fixture is the one that can tell the two halves apart.
    ##
    ## `inner`@20 depth 1, `sibling`@40 depth 0, and **no row at depth 1
    ## after `inner` at all**. A window that begins mid-tree is ordinary
    ## rather than contrived: the calltrace is paged (`CalltraceStore` carries
    ## `startLineIndex` / `totalCallsCount`), so a page's first row is at
    ## whatever depth the tree had reached. Under `depth == line.depth`,
    ## `inner` finds no closer and its return disappears.
    ##
    ## **A three-row fixture would NOT discriminate, and that was measured
    ## rather than assumed.** With `outer`@10 d0 / `inner`@20 d1 /
    ## `sibling`@40 d0, both rules put a return at 39 — `==` from `outer`,
    ## `<=` from `outer` and `inner` both — and the `(tick, kind)` dedup makes
    ## the two outcomes byte-identical. The `==` mutant survived that fixture;
    ## it dies on this one. (`Verification-Harness-Traps.md` §7: read the
    ## green fixture as adversarially as the red ones.)
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      store.calltrace.lines.val = @[
        call("inner", 20'u64, 1),
        call("sibling", 40'u64, 0),
      ]

      let marks = vm.markers.val
      check kindsOf(marks) == @[tmkCall, tmkReturn, tmkCall]
      check ticksOf(marks) == @[20'u64, 39'u64, 40'u64]
      check marks[1].label == "inner"

      dispose()

  test "two frames ending at the same tick collapse to one return mark":
    ## `outer`@10 d0, `inner`@20 d1, `sibling`@40 d0. `sibling` closes BOTH
    ## frames, so both produce a return at 39 and the `(tick, kind)` dedup
    ## keeps one — a track cannot draw two marks at one tick anyway. **The
    ## survivor is the INNERMOST**, which is the more specific answer for a
    ## tooltip: `callMarkers` pops its depth stack deepest-first and
    ## `sortedMarkers` sorts stably (`std/algorithm.sort` is documented
    ## stable), so `inner`'s return is the one that is kept.
    ##
    ## This case DOCUMENTS the collapse; it is not a discriminating arm for
    ## the depth rule — see the case above for why.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      store.calltrace.lines.val = @[
        call("outer", 10'u64, 0),
        call("inner", 20'u64, 1),
        call("sibling", 40'u64, 0),
      ]

      let marks = vm.markers.val
      check kindsOf(marks) == @[tmkCall, tmkCall, tmkReturn, tmkCall]
      check ticksOf(marks) == @[10'u64, 20'u64, 39'u64, 40'u64]
      check marks[2].label == "inner"

      dispose()

  test "two calls recorded at the SAME tick collapse to one mark":
    ## Dedup collapses `(tick, kind)` duplicates so an overlapping page cannot
    ## double a mark. This case is the other side of that: two DISTINCT calls
    ## that genuinely share a tick must not silently become one — and here it
    ## does collapse, which is the honest limit of a tick-keyed track and is
    ## asserted rather than left to be discovered.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      store.calltrace.lines.val = @[
        call("a", 10'u64, 0),
        call("b", 10'u64, 1),
      ]

      check vm.markers.val.len == 1
      check vm.markers.val[0].tick == 10'u64

      dispose()

  test "markers updates reactively when the calltrace window changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      check vm.markers.val.len == 0
      store.calltrace.lines.val = @[call("main", 10'u64, 0)]
      check vm.markers.val.len == 1
      store.calltrace.lines.val = @[]
      check vm.markers.val.len == 0

      dispose()

suite "TimelineVM markers — exceptions from the event log":

  test "an EventLogKind.Error row becomes an exception marker":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      store.eventLog.rows.val = @[event(ErrorEventKindId, 77'u64, "error")]

      check vm.markers.val.len == 1
      check vm.markers.val[0].kind == tmkException
      check vm.markers.val[0].tick == 77'u64
      check vm.markers.val[0].label == "error"

      dispose()

  test "ordinary I/O event rows produce NO markers":
    ## The negative control for the case above. Without it, an
    ## `exceptionMarkers` wired to return every row would pass that case and
    ## fill the track with every `print` in the recording.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      store.eventLog.rows.val = @[
        event(0, 10'u64, "stdout"),      # Write
        event(1, 20'u64, "write file"),  # WriteFile
        event(3, 30'u64, "read"),        # Read
        event(12, 40'u64, "trace"),      # TraceLogEvent
      ]

      check vm.markers.val.len == 0

      dispose()

  test "calls and exceptions are merged ascending by tick":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      store.calltrace.lines.val = @[
        call("main", 10'u64, 0),
        call("inner", 90'u64, 1),
      ]
      store.eventLog.rows.val = @[
        event(ErrorEventKindId, 50'u64, "error"),
        event(0, 60'u64, "stdout"),
      ]

      let marks = vm.markers.val
      check ticksOf(marks) == @[10'u64, 50'u64, 90'u64]
      check kindsOf(marks) == @[tmkCall, tmkException, tmkCall]

      dispose()

# ---------------------------------------------------------------------------
# tickLabels memo
# ---------------------------------------------------------------------------

suite "TimelineVM tickLabels":

  test "five gradations at 1x, spanning the whole extent":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      var tl = store.timeline.val
      tl.minRRTicks = 0'u64
      tl.maxRRTicks = 400'u64
      store.timeline.val = tl

      check vm.tickLabels.val == @[0'u64, 100'u64, 200'u64, 300'u64, 400'u64]

      dispose()

  test "zooming in adds a gradation per doubling and zooming out removes one":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      var tl = store.timeline.val
      tl.minRRTicks = 0'u64
      tl.maxRRTicks = 1000'u64
      store.timeline.val = tl

      check vm.tickLabels.val.len == 5
      vm.zoom(2.0)
      check vm.tickLabels.val.len == 6
      vm.zoom(4.0)
      check vm.tickLabels.val.len == 7
      vm.zoom(0.5)
      check vm.tickLabels.val.len == 4

      dispose()

  test "the label count is clamped to 2..9":
    check tickLabelCount(1.0) == 5
    check tickLabelCount(1024.0) == 9
    check tickLabelCount(1_000_000.0) == 9
    check tickLabelCount(0.1) == 2
    # `zoom` clamps to 0.1, but the projection is a pure function and is
    # called from places that have not been through `zoom`.
    check tickLabelCount(0.0) == 2

  test "the first and last labels are exactly the extent's ends":
    ## A gradation computed as `min + i * span div count` lands one tick short
    ## of `max`, which puts the last number under a label that is not the end
    ## of the recording. Asserted on a span that does not divide evenly.
    let labels = tickLabelsFor(7'u64, 1000'u64, 5)
    check labels.len == 5
    check labels[0] == 7'u64
    check labels[^1] == 1000'u64

  test "an empty or inverted range yields no labels":
    check tickLabelsFor(0'u64, 0'u64, 5).len == 0
    check tickLabelsFor(100'u64, 50'u64, 5).len == 0
    check tickLabelsFor(0'u64, 100'u64, 1).len == 0

# ---------------------------------------------------------------------------
# tickAtFraction / hoverAtFraction
# ---------------------------------------------------------------------------

suite "TimelineVM tickAtFraction":

  test "tickAtFraction is none while the extent is unknown":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.tickAtFraction(0.5).isNone
      dispose()

  test "tickAtFraction agrees with the tick seekAtFraction navigates to":
    ## ONE ARITHMETIC, and this is the case that says so. Before the two
    ## shared a body a hover could report one tick while a click at the same
    ## pixel seeked to another, and nothing would have gone red.
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      var tl = store.timeline.val
      tl.minRRTicks = 100'u64
      tl.maxRRTicks = 1100'u64
      store.timeline.val = tl
      let vm = createTimelineVM(store)
      drain()
      mock.clearReceivedCommands()

      let reported = vm.tickAtFraction(0.25)
      check reported == some(350'u64)

      vm.seekAtFraction(0.25)
      drain()
      let seeks = mock.commandsNamed("ct/timeline-seek")
      check seeks.len == 1
      if seeks.len == 1:
        check seeks[0].args["rrTicks"].getBiggestInt == int64(reported.get)

      dispose()

  test "fractions outside 0..1 are clamped to the recording's ends":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      var tl = store.timeline.val
      tl.minRRTicks = 100'u64
      tl.maxRRTicks = 1100'u64
      store.timeline.val = tl
      let vm = createTimelineVM(store)

      check vm.tickAtFraction(-3.0) == some(100'u64)
      check vm.tickAtFraction(9.0) == some(1100'u64)

      dispose()

  test "hoverAtFraction writes the hovered tick, and clears it off-extent":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      # No extent yet: hovering must not invent a tick.
      vm.hoverAtFraction(0.5)
      check vm.hoveredTick.val.isNone

      var tl = store.timeline.val
      tl.minRRTicks = 0'u64
      tl.maxRRTicks = 200'u64
      store.timeline.val = tl

      vm.hoverAtFraction(0.5)
      check vm.hoveredTick.val == some(100'u64)

      dispose()
