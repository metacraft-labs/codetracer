## point_list_vm_test.nim
##
## Unit tests for PointListVM — the ViewModel for the Point List
## (tracepoints / breakpoints) panel.
##
## Verifies:
## - Initial state defaults (selectedPoint, editingPoint)
## - selectPoint sets/clears the selected point
## - startEditing sets editingPoint and also selects the point
## - stopEditing clears editingPoint
## - Editing and selection interact correctly
## - codetracer#886 (Pxor-Bugs M107): the pane lists BOTH kinds of point. A
##   breakpoint the engine verified (`applyVerifiedBreakpoints`) and a
##   tracepoint the desktop's tracepoint editor declared
##   (`sdk/tracepoints.declareTracepoint`) are both rows of
##   `PointListVM.points`, each with its own kind. A sweep annotates the
##   declared row and does not add a second one. Closing the tracepoint removes
##   only its row.
##
## The one fake is `MockBackendService`, because `createReplayDataStore` needs
## a backend. None of the operations under test sends a request: a declared
## tracepoint is not on the engine between sweeps, and the sweep's answer is
## written by `applyTracepointResults`, which reads no backend. The #886 suite
## asserts the mock received nothing, so the fake cannot hide a request.
##
## Run in the `vm-native` and `vm-js` lanes (ci/lib/test-lane-files.sh), or:
##   nim c -r --path:src/frontend/viewmodel src/tests/gui/tests/point-list/point_list_vm_test.nim

import std/[json, unittest, options]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/point_list_vm
import sdk/tracepoints

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

suite "PointListVM initial state":

  test "selectedPoint defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      check vm.selectedPoint.val.isNone
      dispose()

  test "editingPoint defaults to none":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      check vm.editingPoint.val.isNone
      dispose()

# ---------------------------------------------------------------------------
# selectPoint
# ---------------------------------------------------------------------------

suite "PointListVM selectPoint":

  test "selectPoint sets the selected point":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.selectPoint(some(3))
      check vm.selectedPoint.val == some(3)

      dispose()

  test "selectPoint with none clears the selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.selectPoint(some(5))
      vm.selectPoint(none(int))
      check vm.selectedPoint.val.isNone

      dispose()

  test "selectPoint can change to a different point":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.selectPoint(some(1))
      check vm.selectedPoint.val == some(1)

      vm.selectPoint(some(7))
      check vm.selectedPoint.val == some(7)

      dispose()

# ---------------------------------------------------------------------------
# startEditing
# ---------------------------------------------------------------------------

suite "PointListVM startEditing":

  test "startEditing sets editingPoint":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(2)
      check vm.editingPoint.val == some(2)

      dispose()

  test "startEditing also selects the point":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(4)
      check vm.selectedPoint.val == some(4)

      dispose()

  test "startEditing overrides previous editing point":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(1)
      check vm.editingPoint.val == some(1)

      vm.startEditing(3)
      check vm.editingPoint.val == some(3)
      check vm.selectedPoint.val == some(3)

      dispose()

# ---------------------------------------------------------------------------
# stopEditing
# ---------------------------------------------------------------------------

suite "PointListVM stopEditing":

  test "stopEditing clears editingPoint":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(2)
      check vm.editingPoint.val == some(2)

      vm.stopEditing()
      check vm.editingPoint.val.isNone

      dispose()

  test "stopEditing does not change selectedPoint":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.startEditing(5)
      check vm.selectedPoint.val == some(5)

      vm.stopEditing()
      check vm.editingPoint.val.isNone
      # Selection remains.
      check vm.selectedPoint.val == some(5)

      dispose()

  test "stopEditing is a no-op when not editing":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)

      vm.stopEditing()
      check vm.editingPoint.val.isNone

      dispose()

# ---------------------------------------------------------------------------
# codetracer#886: breakpoints AND tracepoints are rows of the pane
# ---------------------------------------------------------------------------

const
  mainRb = "/src/main.rb"
  breakpointLine = 19
  tracepointLine = 23

proc kindsAt(vm: PointListVM; line: int): seq[string] =
  ## The kinds of the pane's rows at `line` of `mainRb`, in order.
  for p in vm.points.val:
    if p.path == mainRb and p.line == line:
      result.add p.kind

proc countKind(vm: PointListVM; kind: string): int =
  for p in vm.points.val:
    if p.kind == kind:
      inc result

proc sweepOf(id: int; line: int; hits: int): seq[TracepointSweepHit] =
  ## `hits` hits of tracepoint `id` at `mainRb:line`, as a
  ## `ct/tracepoint-results` answer carries them.
  for i in 0 ..< hits:
    result.add TracepointSweepHit(tracepointId: id, rrTicks: uint64(100 + i),
                                  path: mainRb, line: line)

suite "PointListVM lists tracepoints beside breakpoints (codetracer#886)":

  test "a declared tracepoint is a tracepoint row beside the breakpoint row, before any run":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createPointListVM(store)
      store.applyVerifiedBreakpoints(mainRb, [breakpointLine])
      store.declareTracepoint(mainRb, tracepointLine, "log(s1)")

      check vm.points.val.len == 2
      check vm.kindsAt(breakpointLine) == @[PointKindBreakpoint]
      check vm.kindsAt(tracepointLine) == @[PointKindTracepoint]
      let row = store.tracepointRowAt(mainRb, tracepointLine)
      check row.isSome
      check row.get.label == "log(s1)"
      check row.get.expression == "log(s1)"
      check row.get.enabled
      check row.get.resolution == DeclaredTracepointResolution
      check mock.receivedCommands.len == 0
      dispose()

  test "a tracepoint with nothing typed yet is still a row, with a placeholder label":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      store.declareTracepoint(mainRb, tracepointLine)
      check vm.kindsAt(tracepointLine) == @[PointKindTracepoint]
      check vm.points.val[0].label == EmptyTracepointLabel
      # Typing an expression and declaring again updates the one row.
      store.declareTracepoint(mainRb, tracepointLine, "log(s1)")
      check vm.points.val.len == 1
      check vm.points.val[0].label == "log(s1)"
      dispose()

  test "a line below 1 is not a place and declares nothing":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      store.declareTracepoint(mainRb, 0, "log(s1)")
      check vm.points.val.len == 0
      dispose()

  test "a tracepoint on a breakpoint's line is a row of its own":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      store.applyVerifiedBreakpoints(mainRb, [breakpointLine])
      store.declareTracepoint(mainRb, breakpointLine, "log(s1)")
      check vm.kindsAt(breakpointLine) ==
        @[PointKindBreakpoint, PointKindTracepoint]
      dispose()

  test "a sweep annotates the declared row and keeps the breakpoint row apart":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createPointListVM(store)
      store.applyVerifiedBreakpoints(mainRb, [breakpointLine])
      store.declareTracepoint(mainRb, tracepointLine, "log(s1)")
      let spec = TracepointSweepSpec(tracepointId: 7, path: mainRb,
                                     line: tracepointLine,
                                     expression: "log(s1)")
      store.applyTracepointResults(@[spec], sweepOf(7, tracepointLine, 3))

      check vm.points.val.len == 2
      check vm.countKind(PointKindTracepoint) == 1
      check vm.kindsAt(breakpointLine) == @[PointKindBreakpoint]
      let row = store.tracepointRowAt(mainRb, tracepointLine)
      check row.isSome
      check row.get.resolution == "swept"
      check row.get.detail == "3 hit(s)"
      check row.get.label == "log(s1)"
      check store.pointList.tracepointHits.val.len == 3
      # The breakpoint was not marked as swept.
      for p in vm.points.val:
        if p.kind == PointKindBreakpoint:
          check p.resolution == "verified"
      check mock.receivedCommands.len == 0
      dispose()

  test "disabling and closing the tracepoint touch only its row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      store.applyVerifiedBreakpoints(mainRb, [breakpointLine])
      store.declareTracepoint(mainRb, tracepointLine, "log(s1)")
      let spec = TracepointSweepSpec(tracepointId: 7, path: mainRb,
                                     line: tracepointLine,
                                     expression: "log(s1)")
      let hits = sweepOf(7, tracepointLine, 2)
      store.applyTracepointResults(@[spec], hits)

      check store.setDeclaredTracepointEnabled(mainRb, tracepointLine, false,
                                               hits)
      check not store.tracepointRowAt(mainRb, tracepointLine).get.enabled
      for p in vm.points.val:
        if p.kind == PointKindBreakpoint:
          check p.enabled

      check store.removeDeclaredTracepoint(mainRb, tracepointLine, hits)
      check vm.points.val.len == 1
      check vm.kindsAt(breakpointLine) == @[PointKindBreakpoint]
      check vm.countKind(PointKindTracepoint) == 0
      check store.pointList.tracepointHits.val.len == 0
      # A second close finds nothing and says so.
      check not store.removeDeclaredTracepoint(mainRb, tracepointLine, hits)
      dispose()

  test "a row a sweep moved is still found, re-declared at its line without a duplicate, and closed":
    # `applyTracepointResults` re-locates a row to where the engine reported
    # its first hit. The editor still knows the tracepoint by its own line.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      store.declareTracepoint(mainRb, tracepointLine, "log(s1)")
      let spec = TracepointSweepSpec(tracepointId: 3, path: mainRb,
                                     line: tracepointLine,
                                     expression: "log(s1)")
      let moved = sweepOf(3, tracepointLine + 1, 1)
      store.applyTracepointResults(@[spec], moved)
      check vm.kindsAt(tracepointLine + 1) == @[PointKindTracepoint]
      check store.heldTracepointLocation(mainRb, tracepointLine, moved) ==
        some((path: mainRb, line: tracepointLine + 1))

      # A second run declares the row at the editor's line again: one row.
      store.declareTracepoint(mainRb, tracepointLine, "log(s2)", swept = moved)
      check vm.points.val.len == 1
      check vm.kindsAt(tracepointLine) == @[PointKindTracepoint]
      check vm.points.val[0].expression == "log(s2)"

      store.applyTracepointResults(@[spec], moved)
      check vm.points.val.len == 1
      check store.removeDeclaredTracepoint(mainRb, tracepointLine, moved)
      check vm.points.val.len == 0
      dispose()
