## test_timeline_vm.nim
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
## - markers memo returns min/max ticks from the timeline state
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_timeline_vm.nim

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

  test "markers starts empty when maxRRTicks is 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      check vm.markers.val.len == 0
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
# markers memo
# ---------------------------------------------------------------------------

suite "TimelineVM markers":

  test "markers returns min and max when timeline has data":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      var tl = store.timeline.val
      tl.minRRTicks = 10'u64
      tl.maxRRTicks = 9000'u64
      store.timeline.val = tl

      check vm.markers.val.len == 2
      check vm.markers.val[0] == 10'u64
      check vm.markers.val[1] == 9000'u64

      dispose()

  test "markers is empty when maxRRTicks is 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)

      check vm.markers.val.len == 0

      dispose()
