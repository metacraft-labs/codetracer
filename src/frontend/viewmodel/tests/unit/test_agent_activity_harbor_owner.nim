## While an Agent Harbor worktree session drives the Agent Activity pane it is
## the one owner of the pane's conversation, busy state and session key
## (`agent_activity_vm.harborDrivesPane`, `applyAgentSession`).
##
## Before, the launcher and the pane's own ACP flow wrote those ViewModel
## fields in turn: the launcher for the running Harbor session, the flow for
## its own idle session in between. A running worktree session never offered
## Stop, and a stopped one never said it was cancelled
## (`agentic-coding/worktree-cancel-and-recover`).

import std/[strutils, unittest]

import isonim/core/[signals, owner]

import ../../viewmodels/agent_activity_vm
import ../../store/types

proc harbor(lifecycle: AgentServiceLifecycle;
            events: seq[AgentServiceEventEntry] = @[]): AgentServiceSessionEntry =
  AgentServiceSessionEntry(tabId: "agent:harbor:user-1", sessionId: "s-1",
    backend: asbHarbor, lifecycle: lifecycle, events: events)

suite "a Harbor session driving the Agent Activity pane":

  test "a Harbor entry with a session drives the pane; none or a pending one does not":
    check harbor(aslRunning).harborDrivesPane
    check not AgentServiceSessionEntry().harborDrivesPane
    check not AgentServiceSessionEntry(tabId: "agent:harbor:user-2",
      backend: asbHarbor, lifecycle: aslConnecting).harborDrivesPane

  test "a running session keeps the pane busy, a finished one leaves it idle":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      vm.setLoading(false)
      vm.applyAgentSession(harbor(aslRunning))
      check vm.isLoading.val
      for lifecycle in [aslCompleted, aslCancelled, aslError]:
        vm.setLoading(true)
        vm.applyAgentSession(harbor(lifecycle))
        check not vm.isLoading.val
      dispose()

  test "a stopped session's conversation says it was cancelled":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      vm.applyAgentSession(harbor(aslCancelled, @[AgentServiceEventEntry(
        id: "agent:harbor:user-1:cancelled:0", kind: aseCancelled,
        text: "Agent Harbor task cancelled", status: "cancelled")]))
      var conversation = ""
      for message in vm.messages.val:
        conversation.add message.content & "\n"
      check "cancelled" in conversation
      check vm.sessionKey.val == "agent:harbor:user-1"
      dispose()
