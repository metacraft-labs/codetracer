## agent_activity_replayed_session_view_test.nim
##
## A session loaded into a review shows its messages' text.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1: opening a review
## loads the agent session that produced it "so the reviewer can read what
## the agent actually did ... the same view they would have had if they had
## watched the session live and it had ended".  A finished live turn is
## collapsed, with its last text promoted to a final message outside the
## collapsed block.  A loaded session's rows (`review_session.sessionMessages`)
## carry flat `content` and no streamed `segments`, so there was nothing to
## promote, yet they were collapsed all the same: each row rendered as a bare
## "Thinking" header over a `display: none` block, and the reviewer read
## nothing (the DeepReview Agent Activity specs' "Expected substring ...
## Received 'Thinking…'").  Such a row now stays open, and its header no
## longer carries "Thinking", the in-progress placeholder, on a turn that is
## over: a finished row with no timing to report has no label at all.
##
## This file asserts the text is VISIBLE, i.e. outside every subtree the
## stylesheet hides, rather than merely present in the DOM: it was present
## all along.
##
## The Electron end-to-end twins are
## `agent-activity-deepreview/agent-activity-evidence.spec.ts`
## (`e2e_evidence_tool_calls_render_distinctly_from_generic_tool_calls`) and
## `agent-activity-test-run.spec.ts`
## (`e2e_ct_test_run_renders_as_a_summary_not_raw_output`).
##
## TEST DOUBLE JUSTIFICATION (workspace policy).  One collaborator is supplied
## by the test: `MockRenderer`, IsoNim's headless renderer and the standard
## vehicle for every view suite in this repository.  The production
## `WebRenderer` needs a browser; the view code is generic over the renderer,
## so the *same* `renderAgentActivityPanel` body runs either way.  The
## stylesheet is not loaded by the mock, so `visibleText` applies its two
## `display: none` rules by class.  The store's `MockBackendService` is only
## there because `createAgentActivityVM` needs a store; nothing here talks to
## a backend.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom

import backend/mock_backend
import store/replay_data_store
import store/types
import viewmodels/agent_activity_vm
import viewmodels/review_session
import views/isonim_agent_activity_view

proc makeStore(): ReplayDataStore =
  createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())

proc hidden(node: MockNode): bool =
  ## The two classes `styles/components/agent_activity.styl` hides with
  ## `display: none !important`.
  if node.kind != mnkElement:
    return false
  let classes = node.attributes.getOrDefault("class", "").split(' ')
  "agent-thought-collapsed" in classes or
    "agent-final-message-hidden" in classes

proc visibleText(node: MockNode): string =
  ## What a reader sees: the text outside every hidden subtree.
  if node.hidden:
    return ""
  if node.kind == mnkText:
    return node.text
  for child in node.children:
    result.add visibleText(child)

proc countByClass(node: MockNode; cls: string): int =
  if node.kind == mnkElement and
      cls in node.attributes.getOrDefault("class", "").split(' '):
    inc result
  for child in node.children:
    result += countByClass(child, cls)

proc labels(node: MockNode): seq[string] =
  ## The text of every header label (`.agent-thought-label`), in order.
  if node.kind == mnkElement and "agent-thought-label" in
      node.attributes.getOrDefault("class", "").split(' '):
    result.add textContent(node)
  for child in node.children:
    result.add labels(child)

proc loaded(events: varargs[ReviewSessionEvent]): ReviewSession =
  ReviewSession(state: rssLoaded, sessionId: "session-fixture",
                events: @events)

suite "a session loaded into a review shows its messages":

  test "each replayed message's text is visible, once":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 110)

      applyReviewSession(vm, loaded(
        ReviewSessionEvent(kind: "thought",
                           text: "Collecting the first review dataset"),
        ReviewSessionEvent(kind: "message",
                           text: "The tokenizer change is ready to read.")))

      let seen = visibleText(panel)
      check seen.count("Collecting the first review dataset") == 1
      check seen.count("The tokenizer change is ready to read.") == 1
      # Still one content block per row, which is how the RV-6 spec
      # (`agent-activity-session.spec.ts`) addresses the rows.
      check countByClass(panel, AgentActivityMessageContentClass) == 2
      check countByClass(panel, "agent-thought-collapsed") == 0
      # A finished row is not "Thinking": with no timing to report its
      # header has no label, and no empty label element either (the header
      # spaces its items with a flex gap an empty one would still claim).
      check seen.count("Thinking") == 0
      check labels(panel).len == 0
      check countByClass(panel, "agent-thought-header") == 2

      dispose()

  test "a live turn that is still running keeps its open content":
    # A loading message was never collapsed; it is unchanged.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 111)

      vm.setMessages([AgentActivityMessageEntry(
        id: "live-0", content: "Reading the tokenizer", role: aamrAgent,
        isLoading: true)])

      check visibleText(panel).count("Reading the tokenizer") == 1
      # While it runs, "Thinking" is exactly what its header should say.
      check labels(panel) == @["Thinking"]

      dispose()

  test "a finished streamed turn is unchanged: its last text is promoted":
    # The segments path keeps collapsing: it has text to promote.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 112)

      vm.setMessages([AgentActivityMessageEntry(
        id: "live-1", content: "", role: aamrAgent, isLoading: false,
        duration: 3.0,
        segments: @[
          AgentActivitySegment(content: "Looking at the diff"),
          AgentActivitySegment(isToolCall: true, toolCallId: "t1",
                               toolName: "read_file",
                               toolStatus: "completed"),
          AgentActivitySegment(content: "Done reading.")])])

      let seen = visibleText(panel)
      check seen.count("Done reading.") == 1
      # The earlier text stays inside the collapsed thought block.
      check seen.count("Looking at the diff") == 0

      dispose()
