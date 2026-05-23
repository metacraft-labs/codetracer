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
## - `markers`: a seq of notable tick positions (min and max from timeline)
##
## Also creates an auto-load effect that sends a seek command to the
## backend when the user navigates to a different tick.
##
## Usage:
##   let vm = createTimelineVM(store)
##   echo vm.zoomLevel.val             # 1.0
##   vm.zoom(2.0)
##   echo vm.currentPosition.val       # derived from store

import std/[json, math, options]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

type
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
    ##   markers         — notable tick positions from the timeline state
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
    markers*: Memo[seq[uint64]]

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
  let marks = vm.markers.val
  if marks.len < 2 or marks[1] <= marks[0]:
    return
  let clamped = min(1.0, max(0.0, fraction))
  let startTick = marks[0]
  let range = marks[1] - marks[0]
  let offset = uint64(round(float(range) * clamped))
  vm.seek(startTick + offset)

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

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createTimelineVM*(store: ReplayDataStore): TimelineVM =
  ## Create a TimelineVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for `currentPosition` and `markers`
  withViewModel proc(dispose: proc()): TimelineVM =
    let zoomLevel = createSignal(1.0)
    let viewStart = createSignal(0'u64)
    let viewEnd = createSignal(0'u64)
    let hoveredTick = createSignal(none(uint64))

    # Derived: the debugger's current position in the recording.
    let currentPosition = createMemo[uint64] proc(): uint64 =
      store.debugger.val.rrTicks

    # Derived: notable timeline markers (min, max ticks from the timeline).
    let markers = createMemo[seq[uint64]] proc(): seq[uint64] =
      let tl = store.timeline.val
      if tl.maxRRTicks == 0'u64:
        return newSeq[uint64]()
      @[tl.minRRTicks, tl.maxRRTicks]

    TimelineVM(
      store: store,
      zoomLevel: zoomLevel,
      viewStart: viewStart,
      viewEnd: viewEnd,
      hoveredTick: hoveredTick,
      currentPosition: currentPosition,
      markers: markers,
      disposeProc: dispose,
    )
