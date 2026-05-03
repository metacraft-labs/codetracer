## test_agent_activity_vm.nim
##
## Unit tests for ``AgentActivityVM`` — the ViewModel for the ACP
## Agent Activity conversation panel.

import std/unittest
import isonim/core/[signals, computation, owner]
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/agent_activity_vm

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeMessage(id, content: string;
                 role: AgentActivityMessageRole = aamrAgent):
    AgentActivityMessageEntry =
  AgentActivityMessageEntry(id: id, content: content, role: role)

suite "AgentActivityVM initial state":

  test "defaults reflect an idle empty panel":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)

      check vm.messages.val.len == 0
      check vm.terminals.val.len == 0
      check vm.inputValue.val == ""
      check not vm.isLoading.val
      check not vm.reRecordInProgress.val
      check not vm.wantsPassword.val
      check not vm.wantsPermission.val
      check vm.sessionKey.val == ""
      check vm.messageCount.val == 0
      check vm.terminalCount.val == 0
      check not vm.hasMessages.val

      dispose()

suite "AgentActivityVM setters":

  test "setMessages updates messageCount and hasMessages":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)

      vm.setMessages(@[
        makeMessage("u1", "hello", aamrUser),
        makeMessage("a1", "hi"),
      ])

      check vm.messages.val.len == 2
      check vm.messageCount.val == 2
      check vm.hasMessages.val
      check vm.messages.val[0].role == aamrUser

      dispose()

  test "setTerminals updates terminalCount":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)

      vm.setTerminals(@[
        AgentActivityTerminalEntry(id: "term-1", shellId: 10),
        AgentActivityTerminalEntry(id: "term-2", shellId: 11),
      ])

      check vm.terminals.val.len == 2
      check vm.terminalCount.val == 2
      check vm.terminals.val[1].shellId == 11

      dispose()

  test "scalar setters update prompt and session state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)

      vm.setInputValue("record")
      vm.setLoading(true)
      vm.setReRecordInProgress(true)
      vm.setPromptFlags(true, true)
      vm.setSessionKey("session-1")

      check vm.inputValue.val == "record"
      check vm.isLoading.val
      check vm.reRecordInProgress.val
      check vm.wantsPassword.val
      check vm.wantsPermission.val
      check vm.sessionKey.val == "session-1"

      dispose()

  test "clearConversation resets transient render state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)

      vm.setMessages(@[makeMessage("a", "b")])
      vm.setTerminals(@[AgentActivityTerminalEntry(id: "t", shellId: 1)])
      vm.setInputValue("text")
      vm.setLoading(true)
      vm.setReRecordInProgress(true)
      vm.setPromptFlags(true, true)

      vm.clearConversation()

      check vm.messages.val.len == 0
      check vm.terminals.val.len == 0
      check vm.inputValue.val == ""
      check not vm.isLoading.val
      check not vm.reRecordInProgress.val
      check not vm.wantsPassword.val
      check not vm.wantsPermission.val

      dispose()
