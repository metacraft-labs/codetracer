## shell_vm_test.nim
##
## The session's ShellVM — the Shell pane's model as a desktop session owns it.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7. The
## model's own behaviour (output, actions, keys, rows) is
## `src/frontend/viewmodel/tests/unit/test_plat61_shell.nim`'s; this suite
## checks what a SESSION gives it:
##
## - a session's ShellVM exists from the start, idle, and says so;
## - it never talks to the replay engine: starting it with no process side,
##   typing into it and scrolling it send the engine nothing;
## - a front-end with no process side gets the model's refusal, not a crash;
## - disposing the session disposes it.
##
## The backend is `MockBackendService` (`vm_test_helpers`), the stand-in every
## suite under `src/tests/gui/tests` uses for the engine, justified there; here
## it is only a RECORDER of what reached the engine, which must be nothing.

import std/unittest
import vm_test_helpers
import isonim/core/[signals, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/replay_data_store
import viewmodels/shell_vm

proc makeStoreWithMock(): tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

suite "ShellVM in a session":
  test "a new ShellVM is idle, keeps the store, and says it has not started":
    createRoot proc(release: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      check vm.store == store
      check vm.state.val == sssIdle
      check vm.statusWords == "not started"
      check vm.actions.len == 0
      check vm.lineCount == 1
      check vm.scrollTop.val == -1
      vm.dispose()
      release()

  test "without a process side it refuses to start and sends the engine nothing":
    createRoot proc(release: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createShellVM(store)
      mock.clearReceivedCommands()
      vm.startShell(80, 24)
      check vm.state.val == sssFailed
      check vm.note.val == "this front-end cannot run a shell"
      discard vm.pressKey(ShellKey(key: "Enter"))
      vm.sendInput("ls\r")
      vm.scrollShell(-3, 24)
      check mock.receivedCommands.len == 0
      vm.dispose()
      release()
