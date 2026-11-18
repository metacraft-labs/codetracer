## test_calltrace_follows_debugger.nim — **after a jump, the call trace shows
## the call the debugger is in**, however far from the rows it holds.
##
## Call-Trace-Pane.md § Smart Collapsing: after a jump the pane shows the new
## current call. `CalltraceVM.followDebuggerCall` makes the selection follow
## the engine's `currentCallLineIndex` once per stop. It used to act only when
## that line was inside the section the store held, so a jump to a call past
## it (a Starknet transaction's failed call, 15,904 steps in, against a pane
## holding the first 35 lines) left the old section and the old mark on
## screen: nothing else moves the viewport. The follow now scrolls the pane to
## the line, and selects it once the section around it arrives.
##
## Driven through a store over a `MockBackendService` that does not answer
## (`autoRespond = false`), so each section the store holds is the one this
## test put there; a mock because what is asserted is the ViewModel's own
## reaction to the store, not an engine's answer.

import std/[options, unittest]

import isonim/core/signals

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewport
import viewmodels/calltrace_vm

proc line(index: int): CallLine =
  CallLine(index: index.int64, name: "f" & $index, depth: 1,
           callKey: "k" & $index,
           location: Location(file: "/src/main.cairo", line: index + 1),
           rrTicks: uint64(index + 1))

proc section(first, count: int): seq[CallLine] =
  for i in first ..< first + count: result.add line(i)

const Total = 300'u64

proc setup(follow: bool): (ReplayDataStore, CalltraceVM) =
  let mock = newMockBackendService(autoRespond = false)
  let store = createReplayDataStore(mock.toBackendService())
  let vm = createCalltraceVM(store)
  if follow: vm.followDebuggerCall()
  store.updateCalltraceSection(section(0, 35), 0'i64, Total)
  vm.setViewport(Viewport(rows: 10, firstRow: 0))
  (store, vm)

proc moveTo(store: ReplayDataStore; ticks: uint64) =
  ## A move: the debugger is at a new stop. No section has answered for it
  ## yet.
  store.debugger.val = DebuggerState(rrTicks: ticks,
    location: Location(file: "/src/main.cairo", line: int(ticks)))

proc answer(store: ReplayDataStore; currentLine: int64) =
  ## A section answering at the current stop, as `applyCalltraceResponse`
  ## records one: the engine's `currentCallLineIndex`, tagged with the stop.
  store.calltrace.currentLineIndex.val = currentLine
  store.calltrace.answeredStop.val = stopIdentityOf(store.debugger.val)

proc stopAt(store: ReplayDataStore; ticks: uint64; currentLine: int64) =
  ## A move, and the section's answer for it.
  store.moveTo(ticks)
  store.answer(currentLine)

suite "after a jump the call trace shows the current call":

  test "an unmeasured bootstrap keeps the first row until the view reports its height":
    # Native open learns totals with one metadata row, before it can report
    # the pane's real height. Its current call may be just outside that row.
    let mock = newMockBackendService(autoRespond = false)
    let store = createReplayDataStore(mock.toBackendService())
    let vm = createCalltraceVM(store)
    vm.followDebuggerCall()
    store.updateCalltraceSection(section(0, 1), 0'i64, Total)
    let serial = vm.revealScroll.val.serial
    store.stopAt(20, 1)
    check vm.viewport.val.rows == 0
    check vm.viewport.val.firstRow == 0
    check vm.revealScroll.val.serial == serial
    vm.setViewport(Viewport(rows: 10, firstRow: 0))
    store.updateCalltraceSection(section(0, 15), 0'i64, Total)
    store.answer(1)
    check vm.selectedEntry.val == some(1'i64)
    check vm.viewport.val.firstRow == 0

  test "a pending far call is centred when the first measured viewport arrives":
    let mock = newMockBackendService(autoRespond = false)
    let store = createReplayDataStore(mock.toBackendService())
    let vm = createCalltraceVM(store)
    vm.followDebuggerCall()
    store.updateCalltraceSection(section(0, 1), 0'i64, Total)
    let serial = vm.revealScroll.val.serial
    store.stopAt(15904, 250)
    check vm.viewport.val.firstRow == 0
    check vm.revealScroll.val.serial == serial
    # No new section or stop arrives: measurement alone must resume follow.
    vm.setViewport(Viewport(rows: 10, firstRow: 0))
    check vm.viewport.val.firstRow == 245
    check vm.revealScroll.val.serial == serial + 1
    store.updateCalltraceSection(section(240, 30), 240'i64, Total)
    store.answer(250)
    check vm.selectedEntry.val == some(250'i64)

  test "a measured one-row viewport still reveals a far current call":
    let (store, vm) = setup(follow = true)
    vm.setViewport(Viewport(rows: 1, firstRow: 0))
    let serial = vm.revealScroll.val.serial
    store.stopAt(15904, 250)
    check vm.viewport.val.rows == 1
    check vm.viewport.val.firstRow == 250
    check vm.revealScroll.val.serial == serial + 1

  test "control: a current call inside the held section is selected in place":
    let (store, vm) = setup(follow = true)
    store.stopAt(20, 12)
    check vm.selectedEntry.val == some(12'i64)
    check vm.viewport.val.firstRow == 0

  test "a current call past the held section scrolls the pane to it":
    let (store, vm) = setup(follow = true)
    let serial = vm.revealScroll.val.serial
    store.stopAt(15904, 250)
    check vm.viewport.val.firstRow == 245     # centred: 250 - rows div 2
    check vm.revealScroll.val.serial == serial + 1
    check vm.revealScroll.val.firstRow == 245

  test "and the call is selected once the section around it arrives":
    let (store, vm) = setup(follow = true)
    store.stopAt(15904, 250)
    store.updateCalltraceSection(section(240, 30), 240'i64, Total)
    store.answer(250)
    check vm.selectedEntry.val == some(250'i64)

  test "the previous stop's answer is not followed for the next stop":
    # The race an Event Log jump hit: the landing marked line 1, the jump
    # moved the debugger, and the store still held the landing's answer.
    let (store, vm) = setup(follow = true)
    store.stopAt(20, 1)
    check vm.selectedEntry.val == some(1'i64)
    store.moveTo(15904)                         # no answer for it yet
    check vm.selectedEntry.val == some(1'i64)   # nothing re-marked from stale data
    check vm.viewport.val.firstRow == 0
    store.answer(250)                           # the answer for the jump
    check vm.viewport.val.firstRow == 245       # and it is followed
    store.updateCalltraceSection(section(240, 30), 240'i64, Total)
    store.answer(250)
    check vm.selectedEntry.val == some(250'i64)

  test "control: without the follow, a jump moves neither the pane nor the mark":
    let (store, vm) = setup(follow = false)
    store.stopAt(15904, 250)
    check vm.viewport.val.firstRow == 0
    check vm.selectedEntry.val == none(int64)

  test "a stop is revealed once, so the reader can scroll away from it":
    let (store, vm) = setup(follow = true)
    store.stopAt(15904, 250)
    vm.setViewport(Viewport(rows: 10, firstRow: 0))
    store.calltrace.currentLineIndex.val = 250   # the same stop answering again
    check vm.viewport.val.firstRow == 0

suite "a row selected for a move keeps its mark when the move lands":
  # Click-Navigation.md §2.1-§2.3: the clicked row is the one marked. A row
  # click selects its call and jumps to it, and when the call shares its
  # first step with calls it makes, the engine reports the INNERMOST of them
  # as current. Line 5 stands for the clicked call and line 8 for that deeper
  # frame, both open at the step the jump lands on.

  test "the clicked call stays marked at the stop the jump lands on":
    let (store, vm) = setup(follow = true)
    store.stopAt(20, 1)
    vm.selectCallForMove("k5")
    check vm.selectedEntry.val == some(5'i64)
    store.stopAt(6, 8)                    # the jump; the engine says line 8
    check vm.selectedEntry.val == some(5'i64)
    check vm.selectedCallKey.val == "k5"

  test "and the next move is followed again":
    let (store, vm) = setup(follow = true)
    store.stopAt(20, 1)
    vm.selectCallForMove("k5")
    store.stopAt(6, 8)
    store.stopAt(30, 12)                  # a step: the mark follows it
    check vm.selectedEntry.val == some(12'i64)

  test "an answer for the stop the selection was made at is not the move's":
    # The section can answer again at the old stop before the jump lands;
    # that answer must neither be followed nor use the selection up.
    let (store, vm) = setup(follow = true)
    store.stopAt(20, 1)
    vm.selectCallForMove("k5")
    store.answer(1)                       # the same stop answering again
    check vm.selectedEntry.val == some(5'i64)
    store.stopAt(6, 8)
    check vm.selectedEntry.val == some(5'i64)

  test "control: a plain selectCall before the move is replaced by the follow":
    # The defect this suite pins: a selection made with `selectCall` alone
    # loses its mark to the engine's innermost frame.
    let (store, vm) = setup(follow = true)
    store.stopAt(20, 1)
    vm.selectCall("k5")
    store.stopAt(6, 8)
    check vm.selectedEntry.val == some(8'i64)
