## agent_activity_prompt_scope_view_test.nim
##
## The Agent Activity prompt is an INPUT element of the scope path.
##
## Base-Keymaps-And-Layer-Stack.md §5.2 / §6.2: the desktop reads its scope
## path off the DOM focus chain, and the views render the `data-scope-kind` /
## `data-scope-id` attributes that name each scope element — Find in Files
## stamps its query field (`isonim_search_results_view.nim`). The prompt
## textarea carried neither, so with the caret in it the focus was the list
## pane `agentActivity`, `Enter` resolved to `list.activate`, and the router
## stopped the key before the textarea's own handler could submit the prompt
## (codetracer-pm issue 2026-10-21, "Pressing Enter in the Agent Activity
## prompt box does not submit the prompt"). This file asserts the view now
## names the field itself.
##
## The Electron end-to-end twin (headless-first policy) is
## `enter_submits_prompt.spec.ts` in this directory: it presses Enter in the
## real pane and asserts the prompt reaches a stub agent.  The router's half
## (an input element on the path takes `Enter` from the list) is
## `src/frontend/viewmodel/tests/unit/test_native_text_field_scope.nim`.
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
import viewmodels/agent_activity_vm
import views/isonim_agent_activity_view
import keymap/scope_path

proc makeStore(): ReplayDataStore =
  createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())

proc findByTag(node: MockNode; tag: string): seq[MockNode] =
  ## Every descendant (or self) whose tag is `tag`.
  if node.kind == mnkElement and node.tag.toLowerAscii == tag:
    result.add node
  for child in node.children:
    result.add findByTag(child, tag)

suite "the Agent Activity prompt names itself in the scope path":

  test "the prompt textarea is the scope path's agent-prompt input":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 95)

      let areas = findByTag(panel, "textarea")
      check areas.len == 1
      let prompt = areas[0]
      check "agent-command-input" in
        prompt.attributes.getOrDefault("class", "").split(' ')
      check prompt.attributes.getOrDefault(ScopeKindAttribute, "") == $ekInput
      check prompt.attributes.getOrDefault(ScopeIdAttribute, "") ==
        AgentPromptInput
      # The producer reads exactly these two attributes into an element.
      let e = elementOfAttributes(
        prompt.attributes.getOrDefault(ScopeKindAttribute, ""),
        prompt.attributes.getOrDefault(ScopeIdAttribute, ""))
      check e.kind == ekInput
      check e.id == AgentPromptInput

      dispose()

  test "the prompt keeps its scope attributes while a turn runs":
    # The buttons effect re-renders Send / Stop on `isLoading`; the prompt
    # itself must stay the same named field either way.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 96)

      vm.setLoading(true)
      let prompt = findByTag(panel, "textarea")[0]
      check prompt.attributes.getOrDefault(ScopeIdAttribute, "") ==
        AgentPromptInput
      vm.setLoading(false)
      check prompt.attributes.getOrDefault(ScopeIdAttribute, "") ==
        AgentPromptInput

      dispose()
