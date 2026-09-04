## state_render_storm_test.nim
##
## Companion gate for the State-panel re-render storm the user reported as
## "some jumps resulted in very rapid re-rendering of the state panel while the
## call trace panel was also showing a 'Loading' indicator ... I was able to
## trigger the rapid redrawing by closing and re-opening files."
##
## WHAT THIS FILE DOES AND DOES NOT COVER
## --------------------------------------
## The storm itself was NOT in this layer, and this file exists partly to say
## so, because the first diagnosis said it was.
##
## `ui/editor.nim`'s `scheduleInitialFlowLoad` used to retry at 20Hz for up to
## 200 attempts, re-emitting `InternalLastCompleteMove` on every tick;
## `middleware.nim` replays that as a full `CtCompleteMove` fan-out. The pane
## that actually repainted per replay is the LEGACY `StateComponent`, whose
## `onCompleteMove` -> `onMove` -> `loadLocals` chain (`ui/state.nim`) emits
## `CtLoadLocals` unconditionally, with no dedup anywhere on it. That path is
## a browser module and is gated by
## `tests/state/state_pane_no_render_storm.spec.ts`, which counts the requests
## against a real trace.
##
## The ViewModel layer was innocent, and the reason is worth pinning: IsoNim's
## `writeSignal` (isonim/core/signals.nim) returns early when
## `state.value == value`, and `DebuggerState` is a plain object, so structural
## equality absorbs a redundant replay before any effect sees it. That is load
## bearing and it is invisible — nothing in `replay_data_store` says it, and
## its own comment ("Always construct and assign a new DebuggerState so the
## signal fires") reads as though the write always propagates, which is what
## sent the first diagnosis to the wrong layer. Give `DebuggerState` a field
## that never compares equal — a timestamp, a sequence number, a ref — or hand
## the signal a custom comparator, and the ViewModel layer silently joins the
## storm.
##
## THE CONTROL ARM
## ---------------
## `distinctPositions` drives the same effect with 145 DIFFERENT positions and
## requires 145 runs. Without it the assertion below is a ceiling nothing can
## exceed, and would pass just as happily against a store whose signal never
## fired at all. If that arm ever stops reporting one run per position, this
## file is no longer testing anything and must be repaired rather than trusted.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/state/state_render_storm_test.nim

import std/[strformat, unittest]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/state_vm

# The number of `InternalLastCompleteMove` replays one storm produced in the
# field: 143-147 over ~4.8s, from `scheduleInitialFlowLoad`'s 200-attempt,
# 50ms retry loop. Using the measured figure rather than a round number keeps
# both arms comparable to the field measurement.
const ReplayCount = 145

proc makeStoreWithMock(): tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

suite "StateVM render storm":

  test "control arm: distinct positions each re-run the effect":
    # THE HARNESS PROOF — see the module header.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      var runs = 0
      createEffect proc() =
        let dbg = store.debugger.val
        discard dbg.rrTicks
        runs += 1
      drain()

      let baseline = runs
      for i in 1 .. ReplayCount:
        store.updateDebuggerPosition(
          rrTicks = uint64(i), file = "main.rs", line = i)
        drain()

      let observed = runs - baseline
      check:
        observed == ReplayCount
      if observed != ReplayCount:
        checkpoint(&"control arm saw {observed} effect runs across " &
                   &"{ReplayCount} DISTINCT positions; the harness cannot " &
                   "observe a storm and the assertions below prove nothing")
      dispose()

  test "an identical move replayed 145 times re-runs the effect once":
    # The absorption the ViewModel layer depends on, made explicit.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      var runs = 0
      createEffect proc() =
        let dbg = store.debugger.val
        discard dbg.rrTicks
        runs += 1
      drain()

      let baseline = runs
      for _ in 0 ..< ReplayCount:
        store.updateDebuggerPosition(
          rrTicks = 4242'u64, file = "main.rs", line = 17)
        drain()

      # One: the first write moves off the initial (0, "", 0) state. The
      # remaining 144 are byte-identical and must be absorbed by
      # `writeSignal`'s equality check before any observer is queued.
      let observed = runs - baseline
      check:
        observed == 1
      if observed != 1:
        checkpoint(&"{ReplayCount} replays of ONE unchanged position " &
                   &"(rrTicks=4242 main.rs:17) re-ran the effect {observed} " &
                   "times; DebuggerState no longer compares equal to itself, " &
                   "so every panel ViewModel now re-runs per replayed move")
      dispose()

  test "the State pane's own auto-load absorbs the replay too":
    # The same property, asserted through the real `StateVM` effect rather
    # than a stand-in, at the exact proc the legacy pane repaints from.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      # `onWatchesChangedProc` IS the legacy repaint: `ui/state.nim` wires it
      # to `StateComponent.loadLocals`. Counting it counts repaint requests.
      var repaints = 0
      vm.onWatchesChangedProc = proc(expressions: seq[string]) =
        repaints += 1
      drain()

      let baseline = repaints
      for _ in 0 ..< ReplayCount:
        store.updateDebuggerPosition(
          rrTicks = 4242'u64, file = "main.rs", line = 17)
        drain()

      let observed = repaints - baseline
      check:
        observed == 1
      if observed != 1:
        checkpoint(&"StateVM asked the legacy pane to reload locals " &
                   &"{observed} times across {ReplayCount} replays of one " &
                   "unchanged position; expected 1")
      dispose()

  test "a DB-trace move at a fixed rrTicks=0 still re-runs per source line":
    # DB-backed traces hold rrTicks at 0 for EVERY position — the documented
    # reason `updateDebuggerPosition` refuses to guard on the tick. The
    # absorption above must come from whole-value equality, not from the tick,
    # or those traces freeze after their first position.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      var repaints = 0
      vm.onWatchesChangedProc = proc(expressions: seq[string]) =
        repaints += 1
      drain()

      let baseline = repaints
      for line in 10 .. 14:
        store.updateDebuggerPosition(rrTicks = 0'u64, file = "main.rs", line = line)
        drain()
        for _ in 0 ..< 20:
          store.updateDebuggerPosition(rrTicks = 0'u64, file = "main.rs", line = line)
          drain()

      let observed = repaints - baseline
      check:
        observed == 5
      if observed != 5:
        checkpoint(&"a DB trace (rrTicks pinned to 0) produced {observed} " &
                   "repaints across 5 distinct source lines and 100 replays; " &
                   "expected exactly 5 — one per line, none per replay")
      dispose()
