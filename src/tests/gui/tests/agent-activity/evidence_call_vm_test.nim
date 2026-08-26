## evidence_call_vm_test.nim
##
## AA-3 — the agent's evidence handoff renders in the Agent Activity session
## feed as a clickable entry that loads its dataset
## (`codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.1,
## `codetracer-specs/DeepReview/Agent-Activity-Panel.milestones.org` AA-3).
##
## What is asserted here is the *projection and its gates*: which tool calls
## count as evidence, what each of the distinguishable states says, and
## whether a reviewer is offered a review to enter at all.
##
## TEST DOUBLE JUSTIFICATION (workspace policy — every mock must be justified
## in the test file's header).  **No mocks stand in for anything under test.**
## Two collaborators are supplied by the test rather than by production, and
## neither substitutes for logic:
##
##   1. The conversation is built as `AgentActivityMessageEntry` values, which
##      is the type *both* production producers hand the panel
##      (`review_session.sessionMessages` for a replayed session,
##      `agentic_session_vm.eventToActivityMessage` for a live one).  The
##      command lines in it are the ones
##      `docs/agent-prompt/deepreview-evidence.md` ships to agents verbatim,
##      so the recogniser is exercised against the text CodeTracer itself
##      tells agents to type.  Resolving a real agent session would need an
##      ACP child process to assert a *rendering* rule; that end of the chain
##      is covered by the Playwright suite, which speaks the real protocol to
##      a real process (`agent-activity-evidence.spec.ts`).
##   2. `ReviewOpenService` is constructed with a capturing `requestProc`.
##      That is the type's designed seam, not a stand-in for one:
##      `review_open.nim` exists so the host supplies the read, and the
##      production wiring (`ui_js.installAgentActivityReviewOpenService` →
##      `index/review_dataset.readReviewDatasetFile` →
##      `vcs.openReviewDataset`) is asserted end-to-end by the Playwright
##      suite.  What the capture makes assertable is the thing that matters
##      headlessly — *whether* a request is issued, for which dataset and of
##      which kind — including every case where it must not be issued at all.
##
## `ReplayDataStore` is built over `MockBackendService`, as every ViewModel
## suite in this directory does; nothing here sends a backend request.

import std/[options, unittest]

import isonim/core/[signals, computation, owner]

import backend/mock_backend
import store/replay_data_store
import store/types
import viewmodels/agent_activity_vm
import viewmodels/evidence_call_vm
import viewmodels/review_open

const
  # The two commands `ct agent prompt` installs into a project's agent
  # instructions, character for character.
  CollectCommand =
    "ct review collect --diff main..HEAD --recordings .ct/runs -o review.json"
  HandoffCommand = "ct agent evidence review.json"

proc toolCall(id, command: string; toolCallId = ""; status = ""):
    AgentActivityMessageEntry =
  ## A tool-call row, as both production projections build one: the
  ## invocation in `toolName`, and `content` falling back to it (which is
  ## what `review_session.eventContent` does when a `tool_call` carries no
  ## text of its own).
  AgentActivityMessageEntry(
    id: id,
    content: command,
    role: aamrAgent,
    toolName: command,
    toolCallId: toolCallId,
    status: status)

proc toolUpdate(id, toolCallId, status: string; output = ""):
    AgentActivityMessageEntry =
  ## The outcome row.  ACP's `tool_call_update` carries no title, which is
  ## why `toolName` is empty here and why an update can never be mistaken for
  ## a call.
  AgentActivityMessageEntry(
    id: id,
    content: output,
    role: aamrAgent,
    toolCallId: toolCallId,
    status: status)

proc prose(id, text: string): AgentActivityMessageEntry =
  AgentActivityMessageEntry(id: id, content: text, role: aamrAgent)

proc makeStore(): ReplayDataStore =
  createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())

# ---------------------------------------------------------------------------

suite "AA-3 recognising the evidence handoff in a session":

  test "both shipped commands are recognised and name their dataset":
    let collect = parseEvidenceCommand(CollectCommand)
    check collect.isSome
    check collect.get == EvidenceCommand(
      kind: eckCollect, datasetPath: "review.json")

    let handoff = parseEvidenceCommand(HandoffCommand)
    check handoff.isSome
    check handoff.get == EvidenceCommand(
      kind: eckHandoff, datasetPath: "review.json")

  test "every spelling of the output flag names the same dataset":
    for command in [
        "ct review collect --recordings .ct/runs --output .deepreview",
        "ct review collect --recordings .ct/runs --output=.deepreview",
        "ct review collect --recordings .ct/runs -o .deepreview"]:
      let parsed = parseEvidenceCommand(command)
      check parsed.isSome
      check parsed.get.datasetPath == ".deepreview"

  test "the binary may be invoked by path, and may be preceded by a wrapper":
    for command in [
        "/nix/store/abc-codetracer/bin/ct agent evidence review.json",
        "src/build-debug/bin/ct agent evidence review.json",
        "env CODETRACER_AGENT_SESSION_ID=s ct agent evidence review.json"]:
      let parsed = parseEvidenceCommand(command)
      check parsed.isSome
      check parsed.get.datasetPath == "review.json"

  test "a quoted path with a space in it survives intact":
    # The case a naive whitespace split gets *wrong but plausibly*: it would
    # report "/home/a" as the dataset and the reviewer would be told a file
    # is missing when it is not.
    let parsed = parseEvidenceCommand(
      "ct agent evidence \"/home/a b/review.json\"")
    check parsed.isSome
    check parsed.get.datasetPath == "/home/a b/review.json"

  test "a command that names no dataset is not evidence":
    # `ct review collect` requires --output and `ct agent end-of-turn`
    # defaults it from the environment.  Neither may be guessed: a card that
    # could not name its dataset would have nothing to open and nothing
    # honest to say about its shape.
    check parseEvidenceCommand(
      "ct review collect --diff main..HEAD --recordings .ct/runs").isNone
    check parseEvidenceCommand("ct agent end-of-turn --diff main..HEAD").isNone
    check parseEvidenceCommand("ct agent evidence").isNone

  test "the hook form is recognised when it states its output":
    let parsed = parseEvidenceCommand(
      "ct agent end-of-turn --diff main..HEAD --output .deepreview")
    check parsed.isSome
    check parsed.get == EvidenceCommand(
      kind: eckCollect, datasetPath: ".deepreview")

  test "unrelated commands are not evidence":
    for command in [
        "ct review review.json",
        "ct record ./app",
        "git commit -am done",
        "cat review.json",
        "ct test run"]:
      check parseEvidenceCommand(command).isNone

suite "AA-3 only a tool call counts as evidence":

  test "prose that merely mentions the command produces no entry":
    # The fabrication this milestone family exists to prevent: an agent that
    # *says* it will collect evidence has collected none, and turning the
    # sentence into a clickable review would invent one.
    let calls = projectEvidenceCalls(@[
      prose("s:0", "Next I will run " & CollectCommand & " and hand it over."),
      prose("s:1", HandoffCommand)])
    check calls.len == 0

  test "the same text as a tool call does produce an entry":
    # Not vacuous: the previous case is silent because the row was prose, not
    # because the recogniser rejects the text.
    let calls = projectEvidenceCalls(@[toolCall("s:0", CollectCommand)])
    check calls.len == 1
    check calls[0].anchorId == "s:0"
    check calls[0].command == CollectCommand
    check calls[0].datasetPath == "review.json"

suite "AA-3 what became of the call":

  test "a call with no outcome reported says exactly that":
    let calls = projectEvidenceCalls(@[
      toolCall("s:0", CollectCommand, toolCallId = "t1")])
    check calls.len == 1
    check calls[0].state == ecsUnreported
    check calls[0].evidenceNoteText() ==
      "No outcome has been reported for this command yet."
    check not calls[0].canOpenEvidence()

  test "a completed update marks the call completed":
    let calls = projectEvidenceCalls(@[
      toolCall("s:0", CollectCommand, toolCallId = "t1"),
      prose("s:1", "collected"),
      toolUpdate("s:2", "t1", "completed", output = "wrote review.json")])
    check calls.len == 1
    check calls[0].state == ecsCompleted
    # The update is *not* adjacent to the call: pairing is by tool call id.
    check calls[0].failureText == ""

  test "a failed update keeps the backend's own output and offers nothing":
    let calls = projectEvidenceCalls(@[
      toolCall("s:0", CollectCommand, toolCallId = "t1"),
      toolUpdate("s:1", "t1", "failed",
        output = "error: `ct review collect` found no recordings")])
    check calls.len == 1
    check calls[0].state == ecsFailed
    check calls[0].failureText ==
      "error: `ct review collect` found no recordings"
    check calls[0].evidenceNoteText() ==
      "This command failed, so there is no review dataset to open."
    check not calls[0].canOpenEvidence()

  test "an update for another call does not settle this one":
    let calls = projectEvidenceCalls(@[
      toolCall("s:0", CollectCommand, toolCallId = "t1"),
      toolUpdate("s:1", "t2", "completed")])
    check calls.len == 1
    check calls[0].state == ecsUnreported

  test "an unrecognised status is never read as success":
    for status in ["", "in_progress", "pending", "weird"]:
      let calls = projectEvidenceCalls(@[
        toolCall("s:0", CollectCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", status)])
      check calls[0].state == ecsUnreported

suite "AA-3 what the card says about the dataset":

  test "a read dataset prints its file count and commit":
    var call = EvidenceCall(
      anchorId: "s:0", kind: eckHandoff, command: HandoffCommand,
      datasetPath: "review.json", state: ecsCompleted,
      dataset: EvidenceDataset(
        state: edsReady, fileCount: 4, commit: "a1b2c3d4e5f6..."))
    check call.evidenceDatasetShapeText() == "4 files · a1b2c3d4e5f6..."
    check call.evidenceNoteText() == ""
    check call.canOpenEvidence()

  test "one file is not printed as '1 files'":
    var call = EvidenceCall(state: ecsCompleted, datasetPath: "review.json",
      dataset: EvidenceDataset(state: edsReady, fileCount: 1))
    check call.evidenceDatasetShapeText() == "1 file"

  test "a genuinely empty changeset still prints its zero":
    # The rule is about *absent* data, not about zero being unprintable: this
    # dataset was read, and it covers no files.  Saying nothing here would be
    # the mirror defect — a measurement hidden.
    var call = EvidenceCall(state: ecsCompleted, datasetPath: "review.json",
      dataset: EvidenceDataset(state: edsReady, fileCount: 0))
    check call.evidenceDatasetShapeText() == "0 files"

  test "a dataset with no commit prints no commit":
    var call = EvidenceCall(state: ecsCompleted, datasetPath: "review.json",
      dataset: EvidenceDataset(state: edsReady, fileCount: 2, commit: ""))
    check call.evidenceDatasetShapeText() == "2 files"

  test "an unread dataset claims no shape at all":
    for state in [edsUnknown, edsUnavailable]:
      var call = EvidenceCall(state: ecsCompleted, datasetPath: "review.json",
        dataset: EvidenceDataset(state: state, fileCount: 7))
      check call.evidenceDatasetShapeText() == ""
      check not call.canOpenEvidence()

  test "a failed command claims no shape, even for a readable path":
    # A session that collected twice into one path — failing, then succeeding
    # — leaves a perfectly readable file at the failed call's path.  Printing
    # its shape on that card would attribute a real measurement to a command
    # that did not produce it.  Shape and affordance are therefore decided by
    # the same predicate, so they cannot disagree.
    var call = EvidenceCall(state: ecsFailed, datasetPath: "review.json",
      dataset: EvidenceDataset(state: edsReady, fileCount: 9))
    check call.evidenceDatasetShapeText() == ""
    check not call.canOpenEvidence()

  test "a call that names no dataset claims no shape":
    var call = EvidenceCall(state: ecsCompleted, datasetPath: "",
      dataset: EvidenceDataset(state: edsReady, fileCount: 3))
    check call.evidenceDatasetShapeText() == ""
    check not call.canOpenEvidence()

  test "a missing dataset says so, quoting the reader":
    var call = EvidenceCall(
      anchorId: "s:0", datasetPath: "/tmp/gone/review.json",
      state: ecsCompleted,
      dataset: EvidenceDataset(
        state: edsUnavailable,
        message: "no review dataset at /tmp/gone/review.json"))
    check call.evidenceNoteText() ==
      "The review dataset at /tmp/gone/review.json could not be read. " &
      "no review dataset at /tmp/gone/review.json"
    check not call.canOpenEvidence()

  test "every state that cannot be opened says something":
    # The other half of the absence rule: wherever there is no affordance,
    # there is a sentence naming which state it is, and the sentences are
    # mutually distinct — rendering the same one for all of them would defeat
    # the point.
    var notes: seq[string] = @[]
    for call in [
        EvidenceCall(state: ecsUnreported),
        EvidenceCall(state: ecsFailed),
        EvidenceCall(state: ecsCompleted, datasetPath: "review.json",
          dataset: EvidenceDataset(state: edsUnknown)),
        EvidenceCall(state: ecsCompleted, datasetPath: "review.json",
          dataset: EvidenceDataset(state: edsUnavailable))]:
      check not call.canOpenEvidence()
      let note = call.evidenceNoteText()
      check note.len > 0
      check note notin notes
      notes.add note
    # And the openable state says nothing, because the affordance speaks.
    check EvidenceCall(state: ecsCompleted, datasetPath: "review.json",
      dataset: EvidenceDataset(state: edsReady)).evidenceNoteText() == ""

# ---------------------------------------------------------------------------
# The ViewModel: requests issued, and requests refused
# ---------------------------------------------------------------------------

suite "AA-3 the panel reads a dataset, once, and only when there is one":

  test "a completed call has its dataset inspected exactly once":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)

      let conversation = @[
        toolCall("s:0", CollectCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed")]
      vm.setMessages(conversation)
      check requests.len == 1
      check requests[0].kind == rdrInspect
      check requests[0].datasetPath == "review.json"
      check requests[0].anchorId == "s:0"

      # The legacy carrier re-syncs the conversation on every render.  Asking
      # again per render would read the file dozens of times for one answer.
      vm.setMessages(conversation)
      vm.setMessages(conversation)
      check requests.len == 1
      dispose()

  test "a call with no reported outcome is not inspected":
    # Its output may not exist yet, and reporting "missing" about a file that
    # is merely not finished would be a wrong statement rather than a missing
    # one.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      vm.setMessages(@[toolCall("s:0", CollectCommand, toolCallId = "t1")])
      # Not vacuous: the card exists, it is simply not asking about a file.
      check vm.evidenceCallCount.val == 1
      check requests.len == 0
      dispose()

  test "two calls naming one dataset read it once, and both show it":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      vm.setMessages(@[
        toolCall("s:0", CollectCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed"),
        toolCall("s:2", HandoffCommand, toolCallId = "t2"),
        toolUpdate("s:3", "t2", "completed")])
      check vm.evidenceCallCount.val == 2
      check requests.len == 1

      vm.applyEvidenceDataset("review.json",
        EvidenceDataset(state: edsReady, fileCount: 3, commit: "abc123"))
      for anchor in ["s:0", "s:2"]:
        let call = vm.evidenceCallFor(anchor)
        check call.isSome
        check call.get.dataset.fileCount == 3
        check call.get.canOpenEvidence()
      dispose()

  test "a panel wired after the session loaded still reads its datasets":
    # The ordering hole a one-shot creates: a VM built *before* the host
    # installs the service records its placeholders and can send nothing, so
    # without the retry its cards would sit at "Reading …" for the life of
    # the window.  `installAgentActivityReviewOpenService` calls this after
    # back-filling, which is the only moment the answer can change.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      vm.setMessages(@[
        toolCall("s:0", CollectCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed")])

      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      vm.retryPendingEvidenceInspections()
      check requests.len == 1
      check requests[0].kind == rdrInspect
      check requests[0].datasetPath == "review.json"

      # An answered path is not read again.
      vm.applyEvidenceDataset("review.json",
        EvidenceDataset(state: edsReady, fileCount: 2))
      vm.retryPendingEvidenceInspections()
      check requests.len == 1
      dispose()

  test "a host answer survives the conversation being re-synced":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) = discard)
      let conversation = @[
        toolCall("s:0", CollectCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed")]
      vm.setMessages(conversation)
      vm.applyEvidenceDataset("review.json",
        EvidenceDataset(state: edsReady, fileCount: 5))
      vm.setMessages(conversation)
      check vm.evidenceCallFor("s:0").get.dataset.fileCount == 5
      dispose()

suite "AA-3 several evidence calls are independently selectable":

  test "each call opens its own dataset":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      vm.setMessages(@[
        toolCall("s:0",
          "ct review collect --recordings .ct/runs -o iteration-1.json",
          toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed"),
        prose("s:2", "That was not enough; recording again."),
        toolCall("s:3",
          "ct review collect --recordings .ct/runs -o iteration-2.json",
          toolCallId = "t2"),
        toolUpdate("s:4", "t2", "completed")])
      check vm.evidenceCallCount.val == 2
      for path in ["iteration-1.json", "iteration-2.json"]:
        vm.applyEvidenceDataset(path,
          EvidenceDataset(state: edsReady, fileCount: 2))

      requests = @[]
      check vm.openEvidence("s:3")
      check requests.len == 1
      check requests[0].kind == rdrOpen
      check requests[0].datasetPath == "iteration-2.json"

      check vm.openEvidence("s:0")
      check requests.len == 2
      check requests[1].datasetPath == "iteration-1.json"
      dispose()

suite "AA-3 the panel refuses to open what it cannot":

  test "a dataset reported missing is not opened even if asked":
    # The view gates the affordance on `canOpenEvidence`; this gates the
    # action on the same fact, so a rendering that is a moment stale cannot
    # enter a review over a dataset that has just been reported gone.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      vm.setMessages(@[
        toolCall("s:0", HandoffCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed")])
      requests = @[]
      vm.applyEvidenceDataset("review.json",
        EvidenceDataset(state: edsUnavailable, message: "no review dataset"))
      check not vm.openEvidence("s:0")
      check requests.len == 0
      dispose()

  test "a dataset nobody has read yet is not opened":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      vm.setMessages(@[
        toolCall("s:0", HandoffCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed")])
      requests = @[]
      check not vm.openEvidence("s:0")
      check requests.len == 0
      dispose()

  test "a failed command is not opened":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      vm.setMessages(@[
        toolCall("s:0", CollectCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "failed", output = "no recordings")])
      # Even if a dataset happened to be readable at that path, a command
      # that failed did not produce it.
      vm.applyEvidenceDataset("review.json",
        EvidenceDataset(state: edsReady, fileCount: 9))
      requests = @[]
      check not vm.openEvidence("s:0")
      check requests.len == 0
      dispose()

  test "an unknown anchor opens nothing":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var requests: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) =
          requests.add request)
      check not vm.openEvidence("nothing:here")
      check requests.len == 0
      dispose()

  test "a panel with no host reads nothing and opens nothing":
    # `reviewOpen` is nil in a headless renderer-less panel.  The honest
    # answer is that no dataset is ever known to be readable, so no card
    # offers an affordance — not a crash, and not an affordance that fails.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      vm.setMessages(@[
        toolCall("s:0", HandoffCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed")])
      check vm.evidenceCallCount.val == 1
      check not vm.evidenceCallFor("s:0").get.canOpenEvidence()
      check not vm.openEvidence("s:0")
      dispose()

suite "AA-3 the conversation keeps its other content":

  test "a session with runs and evidence renders both, each anchored":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      vm.setMessages(@[
        prose("s:0", "Recording the calculator tests"),
        toolCall("s:1", CollectCommand, toolCallId = "t1"),
        toolUpdate("s:2", "t1", "completed"),
        prose("s:3", "Done.")])
      check vm.messageCount.val == 4
      check vm.evidenceCallCount.val == 1
      check vm.evidenceIndex("s:1") == 0
      # Every other row is left to the ordinary message rendering.
      for anchor in ["s:0", "s:2", "s:3"]:
        check vm.evidenceIndex(anchor) == -1
      dispose()

  test "clearing the conversation clears the evidence and what was read":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      vm.reviewOpen = ReviewOpenService(
        requestProc: proc(request: ReviewDatasetRequest) = discard)
      vm.setMessages(@[
        toolCall("s:0", HandoffCommand, toolCallId = "t1"),
        toolUpdate("s:1", "t1", "completed")])
      vm.applyEvidenceDataset("review.json",
        EvidenceDataset(state: edsReady, fileCount: 3))
      vm.clearConversation()
      check vm.evidenceCallCount.val == 0
      check vm.datasetFor("review.json").state == edsUnknown
      dispose()
