## test_shell_vm.nim
##
## Unit tests for ShellVM — the ViewModel for the Shell / REPL panel.
##
## Verifies:
## - Initial state defaults (inputBuffer, scrollPosition, inputHistory, historyIndex)
## - setInput updates the input buffer
## - submitInput adds to history, clears buffer, sends backend command
## - submitInput ignores empty input
## - historyUp navigates to older entries
## - historyDown navigates to newer entries
## - historyDown past most recent clears buffer and exits history mode
## - scroll updates scroll position, clamps negative values
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_shell_vm.nim

import std/[json, unittest, asyncdispatch, options]
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import ../backend/backend_service
import ../backend/mock_backend
import ../store/types
import ../store/replay_data_store
import ../viewmodels/shell_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.
  try:
    poll(0)
  except ValueError:
    discard

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "ShellVM initial state":

  test "inputBuffer defaults to empty string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      check vm.inputBuffer.val == ""
      dispose()

  test "scrollPosition defaults to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      check vm.scrollPosition.val == 0
      dispose()

  test "inputHistory defaults to empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      check vm.inputHistory.val.len == 0
      dispose()

  test "historyIndex defaults to -1":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      check vm.historyIndex.val == -1
      dispose()

# ---------------------------------------------------------------------------
# setInput
# ---------------------------------------------------------------------------

suite "ShellVM setInput":

  test "setInput updates the input buffer":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("print(x)")
      check vm.inputBuffer.val == "print(x)"

      dispose()

  test "setInput can set to empty string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("hello")
      vm.setInput("")
      check vm.inputBuffer.val == ""

      dispose()

# ---------------------------------------------------------------------------
# submitInput
# ---------------------------------------------------------------------------

suite "ShellVM submitInput":

  test "submitInput adds to history and clears buffer":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("print(x)")
      vm.submitInput()

      check vm.inputHistory.val == @["print(x)"]
      check vm.inputBuffer.val == ""
      check vm.historyIndex.val == -1

      dispose()

  test "submitInput sends shell-eval command":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createShellVM(store)
      drain()

      let cmdCountBefore = mock.receivedCommands.len

      vm.setInput("echo 42")
      vm.submitInput()
      drain()

      var found = false
      for i in cmdCountBefore ..< mock.receivedCommands.len:
        let cmd = mock.receivedCommands[i]
        if cmd.command == "ct/shell-eval":
          check cmd.args["command"].getStr == "echo 42"
          found = true
          break
      check found

      dispose()

  test "submitInput ignores empty input":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createShellVM(store)
      drain()

      let cmdCountBefore = mock.receivedCommands.len

      vm.submitInput()
      drain()

      # No command should have been sent.
      check mock.receivedCommands.len == cmdCountBefore
      check vm.inputHistory.val.len == 0

      dispose()

  test "submitInput accumulates history":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("cmd1")
      vm.submitInput()
      vm.setInput("cmd2")
      vm.submitInput()
      vm.setInput("cmd3")
      vm.submitInput()

      check vm.inputHistory.val == @["cmd1", "cmd2", "cmd3"]

      dispose()

# ---------------------------------------------------------------------------
# historyUp
# ---------------------------------------------------------------------------

suite "ShellVM historyUp":

  test "historyUp navigates to most recent entry":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("first")
      vm.submitInput()
      vm.setInput("second")
      vm.submitInput()

      vm.historyUp()
      check vm.inputBuffer.val == "second"
      check vm.historyIndex.val == 1

      dispose()

  test "historyUp navigates to older entries":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("a")
      vm.submitInput()
      vm.setInput("b")
      vm.submitInput()
      vm.setInput("c")
      vm.submitInput()

      vm.historyUp()
      check vm.inputBuffer.val == "c"

      vm.historyUp()
      check vm.inputBuffer.val == "b"

      vm.historyUp()
      check vm.inputBuffer.val == "a"

      dispose()

  test "historyUp stops at oldest entry":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("only")
      vm.submitInput()

      vm.historyUp()
      check vm.inputBuffer.val == "only"
      check vm.historyIndex.val == 0

      # Another up should not change anything.
      vm.historyUp()
      check vm.inputBuffer.val == "only"
      check vm.historyIndex.val == 0

      dispose()

  test "historyUp is no-op when history is empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.historyUp()
      check vm.inputBuffer.val == ""
      check vm.historyIndex.val == -1

      dispose()

# ---------------------------------------------------------------------------
# historyDown
# ---------------------------------------------------------------------------

suite "ShellVM historyDown":

  test "historyDown navigates to newer entries":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("a")
      vm.submitInput()
      vm.setInput("b")
      vm.submitInput()

      # Navigate up to oldest.
      vm.historyUp()
      vm.historyUp()
      check vm.inputBuffer.val == "a"

      # Navigate down.
      vm.historyDown()
      check vm.inputBuffer.val == "b"

      dispose()

  test "historyDown past most recent clears buffer and exits history":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("cmd")
      vm.submitInput()

      vm.historyUp()
      check vm.inputBuffer.val == "cmd"

      vm.historyDown()
      check vm.inputBuffer.val == ""
      check vm.historyIndex.val == -1

      dispose()

  test "historyDown is no-op when not navigating history":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.setInput("something")
      vm.historyDown()
      check vm.inputBuffer.val == "something"
      check vm.historyIndex.val == -1

      dispose()

# ---------------------------------------------------------------------------
# scroll
# ---------------------------------------------------------------------------

suite "ShellVM scroll":

  test "scroll updates scrollPosition":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.scroll(50)
      check vm.scrollPosition.val == 50

      dispose()

  test "scroll clamps negative values to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)

      vm.scroll(-10)
      check vm.scrollPosition.val == 0

      dispose()
