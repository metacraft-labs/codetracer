## agent_activity_failed_turn_view_test.nim
##
## #862: the DOM the Agent Activity panel emits for a turn the agent refused.
##
## `codetracer-specs/DeepReview/Agentic-Coding-Integration.md` §3.2 defines
## `AgentFailed` ("Task failed with error") and §3.3 gives it "Red X replaces
## icon".  A turn whose `session/prompt` the agent answered with an error
## reaches the panel as an agent message with `failed` set and the agent's
## reason in `errorMessage`; this file asserts the view paints it as failed,
## with the red X and the reason, and with no loading affordance left over.
##
## The Electron end-to-end twin (headless-first policy) is
## `acp_prompt_failure.spec.ts` in this directory: it drives a real refusal
## from a stub agent through the main process into this view.
##
## TEST DOUBLE JUSTIFICATION (workspace policy).  One collaborator is supplied
## by the test: `MockRenderer`, IsoNim's headless renderer and the standard
## vehicle for every view suite in this repository.  The production
## `WebRenderer` needs a browser; the view code is generic over the renderer,
## so the *same* `renderAgentActivityPanel` body runs either way.  The store's
## `MockBackendService` is only there because `createAgentActivityVM` needs a
## store; nothing here talks to a backend.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom

import backend/mock_backend
import store/replay_data_store
import store/types
import viewmodels/agent_activity_vm
import views/isonim_agent_activity_view

const Refusal =
  "Internal error (-32603): unexpected status 400 Bad Request: " &
  "{\"detail\":\"The 'gpt-6.1-sol' model is not supported when using " &
  "Codex with a ChatGPT account.\"}"

proc makeStore(): ReplayDataStore =
  createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())

proc hasClass(node: MockNode; cls: string): bool =
  node.kind == mnkElement and
    cls in node.attributes.getOrDefault("class", "").split(' ')

proc findByClass(node: MockNode; cls: string): MockNode =
  ## First descendant (or self) carrying `cls` as a whole class word.
  if node.hasClass(cls):
    return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  nil

proc countByClass(node: MockNode; cls: string): int =
  if node.hasClass(cls):
    inc result
  for child in node.children:
    result += countByClass(child, cls)

proc userTurn(): AgentActivityMessageEntry =
  AgentActivityMessageEntry(id: "user-0", content: "Explain this trace",
                            role: aamrUser)

proc refusedTurn(errorMessage = Refusal): AgentActivityMessageEntry =
  ## What the legacy carrier mirrors into the VM once the main process
  ## reports the refusal: the turn is over (not loading) and failed.
  AgentActivityMessageEntry(id: "100", content: "", role: aamrAgent,
                            isLoading: false, failed: true,
                            errorMessage: errorMessage)

suite "#862 a refused turn renders as AgentFailed":

  test "a refused turn shows a red X and the agent's reason verbatim":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 91)

      vm.setMessages(@[userTurn(), refusedTurn()])

      let turn = findByClass(panel, AgentActivityTurnFailedClass)
      check turn != nil
      check countByClass(panel, AgentActivityTurnFailedClass) == 1
      check findByClass(turn, AgentActivityTurnFailedIconClass) != nil
      let error = findByClass(turn, AgentActivityTurnErrorClass)
      check error != nil
      check error.textContent == Refusal

      dispose()

  test "a refused turn leaves no loading affordance behind":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 92)

      vm.setMessages(@[userTurn(), refusedTurn()])
      vm.setLoading(false)

      # No "Thinking" spinner, no "Agent is working" row …
      check findByClass(panel, "ai-status") == nil
      check findByClass(panel, "agent-working-indicator") == nil
      # … and the prompt offers Send again, not Stop.
      check findByClass(panel, "agent-start-button") != nil
      check findByClass(panel, "agent-stop-button") == nil

      dispose()

  test "the reason stays visible while the turn's thought block is collapsed":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 93)

      vm.setMessages(@[userTurn(), refusedTurn()])

      # A finished turn's thought block starts collapsed; the reason must not
      # be hidden inside it, or the user is back to not being told.
      let collapsed = findByClass(panel, "agent-thought-collapsed")
      check collapsed != nil
      check findByClass(collapsed, AgentActivityTurnErrorClass) == nil
      check findByClass(panel, AgentActivityTurnErrorClass) != nil

      dispose()

  test "a refusal with no reason still says the turn failed":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 94)

      vm.setMessages(@[userTurn(), refusedTurn(errorMessage = "")])

      let error = findByClass(panel, AgentActivityTurnErrorClass)
      check error != nil
      check error.textContent.strip().len > 0

      dispose()

  test "a turn already on screen repaints as failed when only its failure changes":
    # The messages signal only notifies when the new list differs under
    # `AgentActivityMessageEntry`'s `==`.  A turn that is already finished on
    # screen (for instance one the user cancelled before the agent's error
    # arrived) differs from its failed self only in `failed` and
    # `errorMessage`, so `==` must compare them or the pane never repaints.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 96)

      var turn = refusedTurn()
      turn.failed = false
      turn.errorMessage = ""
      vm.setMessages(@[userTurn(), turn])
      check findByClass(panel, AgentActivityTurnFailedClass) == nil

      vm.setMessages(@[userTurn(), refusedTurn()])
      let error = findByClass(panel, AgentActivityTurnErrorClass)
      check findByClass(panel, AgentActivityTurnFailedClass) != nil
      check error != nil
      if error != nil:
        check error.textContent == Refusal

      dispose()

  test "a turn that ended normally carries no failure marking":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 95)

      vm.setMessages(@[
        userTurn(),
        AgentActivityMessageEntry(id: "100", content: "Here is the answer.",
                                  role: aamrAgent, isLoading: false),
      ])

      check findByClass(panel, AgentActivityTurnFailedClass) == nil
      check findByClass(panel, AgentActivityTurnFailedIconClass) == nil
      check findByClass(panel, AgentActivityTurnErrorClass) == nil

      dispose()
