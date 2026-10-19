## test_debug_controls_history.nim
##
## `DebugControlsVM` owns what the desktop's toolbar remembered beyond the
## debugger's position — the jump history and its cursor, the history lists
## behind `jump-before` / `jump-after`, a pending test run, and which surface
## the toolbar host shows — for every front-end (Shared-DOM-Front-Ends D7.1).
##
## Driven through the store's debugger position, the way every host moves it,
## with the backend a `MockBackendService`: the property under test is what
## the VM records and asks for, and the mock records every request it is
## asked to send. No renderer.

import std/[json, options, unittest]

import isonim/core/[signals, computation]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewmodels/[debug_controls_vm, edit_mode_toolbar]

proc moveTo(store: ReplayDataStore; ticks: uint64; line: int) =
  store.updateDebuggerPosition(ticks, "/src/main.py", line)

proc ticksOf(entries: seq[JumpEntry]): seq[uint64] =
  for e in entries: result.add e.rrTicks

proc newVM(): (ReplayDataStore, DebugControlsVM, MockBackendService) =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  (store, createDebugControlsVM(store), mock)

proc jumpsSent(mock: MockBackendService): seq[int] =
  for c in mock.receivedCommands:
    if c.command == "ct/history-jump":
      result.add c.args["rrTicks"].getInt

suite "the jump history":

  test "every new stop is recorded once, oldest first":
    let (store, vm, _) = newVM()
    store.moveTo(10, 1)
    store.moveTo(20, 2)
    store.moveTo(20, 2)          # the same stop again: one entry
    store.moveTo(30, 3)
    check vm.history.val.ticksOf == @[10'u64, 20, 30]
    check vm.historyIndex.val == 1
    check vm.canGoBack.val
    check not vm.canGoForward.val

  test "back and forward jump through the history, refused at the ends":
    let (store, vm, mock) = newVM()
    for t in 1 .. 3: store.moveTo(uint64(t * 10), t)
    vm.goBack()
    check mock.jumpsSent == @[20]
    check vm.historyIndex.val == 2
    store.moveTo(20, 2)          # the jump's own move: not recorded
    check vm.history.val.len == 3
    vm.goBack()
    vm.goBack()                  # already on the oldest: refused
    check mock.jumpsSent == @[20, 10]
    check not vm.canGoBack.val
    store.moveTo(10, 1)
    vm.goForward()
    check mock.jumpsSent == @[20, 10, 20]
    check vm.historyIndex.val == 2

  test "a move made back in the history drops the newer entries":
    let (store, vm, _) = newVM()
    for t in 1 .. 3: store.moveTo(uint64(t * 10), t)
    vm.goBack()
    store.moveTo(20, 2)          # arrival of the jump
    store.moveTo(25, 4)          # a step from there
    check vm.history.val.ticksOf == @[10'u64, 20, 25]
    check vm.historyIndex.val == 1
    check not vm.canGoForward.val

  test "the toolbar ids reach the same history":
    let (store, vm, mock) = newVM()
    for t in 1 .. 2: store.moveTo(uint64(t * 10), t)
    vm.invokeToolbarAction(HistoryBackActionId)
    check mock.jumpsSent == @[10]
    store.moveTo(10, 1)
    vm.invokeToolbarAction(HistoryForwardActionId)
    check mock.jumpsSent == @[10, 20]

  test "the operation that made a move is recorded with it":
    let (store, vm, _) = newVM()
    store.moveTo(1, 1)
    vm.invokeToolbarAction("next")
    store.moveTo(2, 2)
    check vm.history.val[^1].lastOperation == "next"

suite "the history lists (jump-before / jump-after)":

  test "jump-before lists the older entries, most recent first":
    let (store, vm, _) = newVM()
    for t in 1 .. 4: store.moveTo(uint64(t * 10), t)
    vm.invokeToolbarAction("jump-before")
    check vm.historyList.val == hlBefore
    check vm.historyListEntries.val.ticksOf == @[30'u64, 20, 10]

  test "jump-after lists the newer entries, oldest first":
    let (store, vm, _) = newVM()
    for t in 1 .. 4: store.moveTo(uint64(t * 10), t)
    vm.goBack()
    store.moveTo(30, 3)
    vm.goBack()
    store.moveTo(20, 2)
    vm.invokeToolbarAction("jump-after")
    check vm.historyListEntries.val.ticksOf == @[30'u64, 40]

  test "choosing an entry jumps there and closes the list":
    let (store, vm, mock) = newVM()
    for t in 1 .. 4: store.moveTo(uint64(t * 10), t)
    vm.jumpBefore()
    vm.chooseHistoryEntry(1)     # the second most recent older entry
    check mock.jumpsSent == @[20]
    check vm.historyIndex.val == 3
    check vm.historyList.val == hlNone
    check vm.historyListEntries.val.len == 0

  test "stopJump closes the list without jumping":
    let (store, vm, mock) = newVM()
    for t in 1 .. 2: store.moveTo(uint64(t * 10), t)
    vm.jumpBefore()
    vm.stopJump()
    check vm.historyList.val == hlNone
    check mock.jumpsSent.len == 0

suite "a test run started from the toolbar":

  test "pending until the run itself reports back":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    var finish: proc(succeeded: bool)
    var commands = defaultDebugCommands(store)
    commands.runTests = proc(done: proc(succeeded: bool)) = finish = done
    let vm = createDebugControlsVM(store, commands)
    vm.invokeToolbarAction("run-tests")
    check vm.runTestsPending.val
    vm.invokeToolbarAction("run-tests")   # a second press while pending: ignored
    finish(true)
    check not vm.runTestsPending.val

  test "a host without test runs offers none":
    let (_, vm, _) = newVM()
    vm.runTests()
    check not vm.runTestsPending.val

suite "the toolbar surface":

  test "debugger controls until a platform installs an edit-mode toolbar":
    let (_, vm, _) = newVM()
    check vm.topbarSurface.val == tsDebuggerControls
    vm.toolbarMode.val = EditMode
    check vm.topbarSurface.val == tsDebuggerControls
    vm.setEditToolbar(EditToolbarModel(mode: EditMode), proc(id: string) = discard)
    check vm.topbarSurface.val == tsEditCommands
    vm.toolbarMode.val = DebugMode
    check vm.topbarSurface.val == tsDebuggerControls

suite "a restarted replay":

  test "a new trace behind the store starts a new history":
    let (store, vm, _) = newVM()
    for t in 1 .. 3: store.moveTo(uint64(t * 10), t)
    vm.goBack()
    vm.jumpBefore()
    store.resetForNewSession()
    check vm.history.val.len == 0
    check vm.historyIndex.val == 1
    check vm.historyList.val == hlNone
    store.moveTo(5, 1)
    check vm.history.val.ticksOf == @[5'u64]
