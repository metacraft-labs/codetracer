## agent_activity_evidence_view_test.nim
##
## AA-3 — the DOM the Agent Activity panel emits for an evidence tool call
## (`codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.1).
##
## The companion suite `evidence_call_vm_test.nim` asserts *what is decided*;
## this asserts *what is drawn* — that a handoff replaces the generic
## tool-call line, that the shape it names is only ever one that was measured,
## that every unopenable state renders a sentence and no affordance, and that
## the affordance actually reaches the ViewModel.
##
## ## Why this is a separate file from `views/isonim_views_test.nim`
##
## Following AA-2, which put `agent_activity_test_run_view_test.nim` beside
## this one.  Its original reason — that `isonim_views_test.nim` died with a
## SIGSEGV two thirds of the way through, so anything added after that point
## was unrunnable and silently green — was fixed in 289e0c95 and no longer
## applies.  Two reasons that do apply were weighed instead: that file
## currently carries 17 genuine pre-existing failures, so a new suite landing
## in it would be one signal among eighteen rather than a clean pass/fail; and
## the panel's other rendering milestone already lives here, so the two
## suites for one panel stay together.  Merging all three back is a tidy-up,
## and should be done deliberately rather than as a side effect of AA-3.
##
## TEST DOUBLE JUSTIFICATION (workspace policy — every mock must be justified
## in the test file's header).  **No mocks stand in for anything under test.**
## `MockRenderer` / `MockNode` are IsoNim's own headless renderer, which is
## the *same* view code the browser renderer runs (the view is generic over
## `R`); it is a DOM, not a stub of the view.  `ReplayDataStore` is built over
## `MockBackendService`, as every ViewModel suite here does, and nothing
## sends a backend request.  Where the host's answer about a dataset is
## needed it is supplied through the production entry point
## (`AgentActivityVM.applyEvidenceDataset`) rather than by reaching into
## state, so the test drives the same call `ui_js.onReviewDatasetRead` makes.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom

import backend/mock_backend
import store/replay_data_store
import store/types
import viewmodels/agent_activity_vm
import views/isonim_agent_activity_view

const
  CollectCommand =
    "ct review collect --diff main..HEAD --recordings .ct/runs -o review.json"
  HandoffCommand = "ct agent evidence review.json"

proc makeStore(): ReplayDataStore =
  createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())

proc findByClass(node: MockNode; cls: string): MockNode =
  ## First descendant (or self) carrying `cls` as a whole class word.
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  nil

proc findAllByClass(node: MockNode; cls: string): seq[MockNode] =
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        result.add node
        break
  for child in node.children:
    result.add findAllByClass(child, cls)

proc findById(node: MockNode; id: string): MockNode =
  if node.kind == mnkElement and
     node.attributes.getOrDefault("id", "") == id:
    return node
  for child in node.children:
    let found = findById(child, id)
    if found != nil:
      return found
  nil

proc toolCall(id, command, toolCallId: string): AgentActivityMessageEntry =
  AgentActivityMessageEntry(
    id: id, content: command, role: aamrAgent,
    toolName: command, toolCallId: toolCallId)

proc toolUpdate(id, toolCallId, status: string; output = ""):
    AgentActivityMessageEntry =
  AgentActivityMessageEntry(
    id: id, content: output, role: aamrAgent,
    toolCallId: toolCallId, status: status)

proc prose(id, text: string): AgentActivityMessageEntry =
  AgentActivityMessageEntry(id: id, content: text, role: aamrAgent)

proc feed(vm: AgentActivityVM; command: string; status = "completed") =
  ## A four-row session: prose, the handoff, its outcome, more prose.
  ##
  ## The prose is there so every "the card replaced the tool-call line"
  ## assertion is paired with a positive check that ordinary messages still
  ## render — otherwise "the line is gone" would be satisfied by a panel that
  ## drew nothing at all.
  vm.setMessages(@[
    prose("s:0", "Recording the parser tests"),
    toolCall("s:1", command, "t1"),
    toolUpdate("s:2", "t1", status,
      output = if status == "failed": "error: found no recordings" else: ""),
    prose("s:3", "Handed the review over.")])

proc ready(fileCount: int; commit = ""): EvidenceDataset =
  EvidenceDataset(state: edsReady, fileCount: fileCount, commit: commit)

# ---------------------------------------------------------------------------

suite "AA-3 an evidence tool call renders distinctly":

  test "the handoff becomes a card and the tool-call line is not painted":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 91)

      feed(vm, HandoffCommand)
      vm.applyEvidenceDataset("review.json", ready(4, "a1b2c3d4e5f6..."))

      let card = findById(panel, evidenceId("s:1"))
      check card != nil
      # The message the card replaced is not painted as a generic message…
      check findById(panel, AgentActivityMessageContentClass & "-s:1") == nil
      # …and everything around it renders unchanged.
      check findById(panel, AgentActivityMessageContentClass & "-s:0") != nil
      check findById(panel, AgentActivityMessageContentClass & "-s:3") != nil
      dispose()

  test "the card names the dataset, the command and the shape":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 92)

      feed(vm, CollectCommand)
      vm.applyEvidenceDataset("review.json", ready(4, "a1b2c3d4e5f6..."))

      let card = findById(panel, evidenceId("s:1"))
      check findByClass(card, "agent-evidence-kind").textContent ==
        "Collected review evidence"
      check findByClass(card, "agent-evidence-dataset").textContent ==
        "review.json"
      check findByClass(card, "agent-evidence-command").textContent ==
        CollectCommand
      check findByClass(card, "agent-evidence-shape").textContent ==
        "4 files · a1b2c3d4e5f6..."
      dispose()

  test "prose naming the command stays an ordinary message":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 93)

      vm.setMessages(@[prose("s:0", "I will run " & HandoffCommand)])

      check findByClass(panel, AgentActivityEvidenceClass) == nil
      check findById(panel, AgentActivityMessageContentClass & "-s:0") != nil
      dispose()

suite "AA-3 the affordance exists exactly where the review does":

  test "a read dataset offers the affordance and no explanatory note":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 94)

      feed(vm, HandoffCommand)
      vm.applyEvidenceDataset("review.json", ready(2))

      let card = findById(panel, evidenceId("s:1"))
      check findByClass(card, AgentActivityEvidenceOpenClass) != nil
      check findByClass(card, AgentActivityEvidenceNoteClass) == nil
      check "agent-evidence-ready" in
        card.attributes.getOrDefault("class", "")
      dispose()

  test "a missing dataset offers nothing and says why":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 95)

      feed(vm, HandoffCommand)
      vm.applyEvidenceDataset("review.json", EvidenceDataset(
        state: edsUnavailable,
        message: "no review dataset at review.json"))

      let card = findById(panel, evidenceId("s:1"))
      # Not vacuous: the card rendered, and rendered as unavailable.
      check card != nil
      check "agent-evidence-unavailable" in
        card.attributes.getOrDefault("class", "")
      check findByClass(card, AgentActivityEvidenceOpenClass) == nil
      check findByClass(card, "agent-evidence-actions") == nil
      check "could not be read" in
        findByClass(card, AgentActivityEvidenceNoteClass).textContent
      dispose()

  test "a failed command offers nothing, says why, and shows its output":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 96)

      feed(vm, CollectCommand, status = "failed")
      # Even with a readable dataset at that path, a command that failed did
      # not produce it.
      vm.applyEvidenceDataset("review.json", ready(9))

      let card = findById(panel, evidenceId("s:1"))
      check "agent-evidence-failed" in
        card.attributes.getOrDefault("class", "")
      check findByClass(card, AgentActivityEvidenceOpenClass) == nil
      check findByClass(card, AgentActivityEvidenceNoteClass).textContent ==
        "This command failed, so there is no review dataset to open."
      check findByClass(card, "agent-evidence-output").textContent ==
        "error: found no recordings"
      # And it does not claim a shape it has no right to.
      check findByClass(card, "agent-evidence-shape") == nil
      dispose()

  test "a command with no reported outcome offers nothing and says so":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 97)

      vm.setMessages(@[
        prose("s:0", "Collecting the review dataset"),
        toolCall("s:1", CollectCommand, "t1")])

      let card = findById(panel, evidenceId("s:1"))
      check card != nil
      check "agent-evidence-unreported" in
        card.attributes.getOrDefault("class", "")
      check findByClass(card, AgentActivityEvidenceOpenClass) == nil
      check findByClass(card, AgentActivityEvidenceNoteClass).textContent ==
        "No outcome has been reported for this command yet."
      dispose()

  test "a dataset nobody has read yet offers nothing and says it is reading":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 98)

      feed(vm, HandoffCommand)

      let card = findById(panel, evidenceId("s:1"))
      check "agent-evidence-reading" in
        card.attributes.getOrDefault("class", "")
      check findByClass(card, AgentActivityEvidenceOpenClass) == nil
      check findByClass(card, "agent-evidence-shape") == nil
      check findByClass(card, AgentActivityEvidenceNoteClass) != nil
      dispose()

  test "the card re-renders into an affordance when the answer arrives":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 99)

      feed(vm, HandoffCommand)
      check findByClass(panel, AgentActivityEvidenceOpenClass) == nil

      vm.applyEvidenceDataset("review.json", ready(3, "beef1234abcd..."))
      let card = findById(panel, evidenceId("s:1"))
      check findByClass(card, AgentActivityEvidenceOpenClass) != nil
      check findByClass(card, "agent-evidence-shape").textContent ==
        "3 files · beef1234abcd..."
      dispose()

suite "AA-3 selecting an evidence call asks for its dataset":

  test "clicking the affordance issues an open request for that dataset":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      var observed: seq[string] = @[]
      let callbacks = AgentActivityCallbacks(
        onOpenEvidence: proc(anchorId, datasetPath: string) =
          observed.add anchorId & " " & datasetPath)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 100,
                                           callbacks = callbacks)

      feed(vm, HandoffCommand)
      requests = @[]
      vm.applyEvidenceDataset("review.json", ready(4))

      findByClass(panel, AgentActivityEvidenceOpenClass).fireEvent("click")
      check requests.len == 1
      check requests[0].kind == rdrOpen
      check requests[0].datasetPath == "review.json"
      check requests[0].anchorId == "s:1"
      check observed == @["s:1 review.json"]
      dispose()

  test "several evidence calls render as several independent cards":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 101)

      vm.setMessages(@[
        toolCall("s:0",
          "ct review collect --recordings .ct/runs -o iteration-1.json", "t1"),
        toolUpdate("s:1", "t1", "completed"),
        prose("s:2", "That was not enough; recording again."),
        toolCall("s:3",
          "ct review collect --recordings .ct/runs -o iteration-2.json", "t2"),
        toolUpdate("s:4", "t2", "completed")])
      vm.applyEvidenceDataset("iteration-1.json", ready(1))
      vm.applyEvidenceDataset("iteration-2.json", ready(6))

      check findAllByClass(panel, AgentActivityEvidenceClass).len == 2
      # Each names its own dataset and its own shape…
      check findByClass(findById(panel, evidenceId("s:0")),
        "agent-evidence-shape").textContent == "1 file"
      check findByClass(findById(panel, evidenceId("s:3")),
        "agent-evidence-shape").textContent == "6 files"
      # …and clicking the second asks for the second.
      requests = @[]
      findByClass(findById(panel, evidenceId("s:3")),
        AgentActivityEvidenceOpenClass).fireEvent("click")
      check requests.len == 1
      check requests[0].datasetPath == "iteration-2.json"
      dispose()

  test "the panel never asks for a dataset it did not offer":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 102)

      feed(vm, HandoffCommand)
      vm.applyEvidenceDataset("review.json", EvidenceDataset(
        state: edsUnavailable, message: "no review dataset at review.json"))
      requests = @[]
      # There is no button to click, and asking anyway is refused.
      check findByClass(panel, AgentActivityEvidenceOpenClass) == nil
      check not vm.openEvidence("s:1")
      check requests.len == 0
      dispose()
