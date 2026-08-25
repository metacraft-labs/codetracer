## agent_activity_test_run_view_test.nim
##
## AA-2 — the DOM the Agent Activity panel emits for a `ct test` run.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.2: "`ct test`
## executions in the session are rendered as a **summary of the run** rather
## than as raw output", the summary "is **drillable**", and "Where a test has a
## recording, the drill-down **opens that recording**."  The two negative rules
## are asserted as hard as the positive one, because they are the ones a
## rendering can silently break: a test with no recording gets "no drill-down
## affordance — not with an affordance that fails when used", and a failed
## recording "must **not** offer a trace to open".
##
## The projection these render is asserted separately, in
## `test_run_summary_vm_test.nim`; what this file adds is that the DOM agrees
## with it.
##
## **Why this is a separate file rather than a suite inside
## `views/isonim_views_test.nim`, where the panel's other view tests live.**
## That file does not currently reach its own end: on the unmodified tree it
## dies with `SIGSEGV: Illegal storage access` at
## `isonim_views_test.nim(5388)` — a nil `findByClass(panel,
## "search-results-count")` dereferenced by `textContent`, downstream of the
## three known-failing "search results" cases from the find-in-files work.
## Every suite after that point, AA-1's own `no DeepReview roll-up` guard
## included, is therefore dead today.  Putting AA-2's rendering assertions
## there would have made them unrunnable and silently green.  They move back
## the moment that crash is fixed.
##
## TEST DOUBLE JUSTIFICATION (workspace policy).  Two collaborators are
## supplied by the test; neither substitutes for logic under test:
##
##   1. `MockRenderer` — IsoNim's headless renderer, the standard vehicle for
##      every view suite in this repository.  The production `WebRenderer`
##      needs a browser; the view code itself is generic over the renderer, so
##      the *same* `renderAgentActivityPanel` body runs either way.
##   2. `TraceOpenService` with a capturing `openProc` — the type's designed
##      seam (`trace_open.nim` exists so the host supplies the opening action).
##      What the capture makes assertable is exactly the thing at stake here:
##      whether a click issues a request, with which `--open-policy`, and — for
##      a test with no recording — that no click is even offered.
##
## The runner's event lines are written out literally rather than produced by
## `ct_test/contracts`, so this file is falsifiable against the *wire* format a
## session actually carries rather than against a serializer that could drift
## with its parser.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom

import backend/mock_backend
import store/replay_data_store
import store/types
import viewmodels/agent_activity_vm
import views/isonim_agent_activity_view

const TestId = "native-m11/c/gtest/tests/calc.c::test_add"
const OtherTestId = "native-m11/c/gtest/tests/calc.c::test_sub"

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

proc line(kind, testId: string; extra = ""): string =
  ## One line of the runner's NDJSON, in the shape `contracts.toJson` writes.
  result = "{\"schemaVersion\":1,\"kind\":\"" & kind &
    "\",\"providerId\":\"native-m11\",\"runId\":\"r1\",\"testId\":\"" &
    testId & "\",\"message\":\"\",\"output\":\"\",\"durationMs\":0"
  if extra.len > 0:
    result.add "," & extra
  result.add "}"

proc runWithRecording(): string =
  [
    line("record-started", TestId),
    line("test-started", TestId),
    line("recording-created", TestId,
      "\"trace\":{\"traceId\":\"t1\",\"recordingId\":\"rec-1\"," &
      "\"path\":\"/tmp/traces/add\",\"backend\":\"native\"," &
      "\"entryPoint\":\"tests/calc.c\",\"metadata\":{}}"),
    line("test-finished", TestId, "\"status\":\"passed\""),
    line("record-finished", TestId, "\"status\":\"passed\""),
  ].join("\n")

proc plainRun(): string =
  [
    line("run-started", ""),
    line("test-started", TestId),
    line("test-finished", TestId, "\"status\":\"passed\""),
    line("test-started", OtherTestId),
    line("test-finished", OtherTestId, "\"status\":\"failed\""),
    line("run-finished", "", "\"status\":\"failed\""),
  ].join("\n")

proc failedRecording(): string =
  [
    line("record-started", TestId),
    line("test-started", TestId),
    line("output", TestId, "\"output\":\"ct-mcr: cannot open perf events\""),
    line("failure", TestId,
      "\"status\":\"failed\",\"message\":\"ct-mcr exited with 1\""),
    line("record-finished", TestId, "\"status\":\"failed\""),
  ].join("\n")

proc feed(vm: AgentActivityVM; content: string) =
  ## A two-message session: some prose, then the run.  The prose is there so
  ## every "the card replaced the raw output" assertion is paired with a
  ## positive check that ordinary messages still render — otherwise "no raw
  ## output" would be satisfied by a panel that drew nothing.
  vm.setMessages(@[
    AgentActivityMessageEntry(id: "s:0", content: "running the tests now",
                              role: aamrAgent),
    AgentActivityMessageEntry(id: "s:1", content: content, role: aamrAgent),
  ])

suite "AA-2 the session feed renders a ct test run as a summary":

  test "a ct test run renders as a summary card, not as raw runner output":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 81)

      feed(vm, plainRun())

      let card = findById(panel, testRunId("s:1"))
      check card != nil
      # The message the run replaced is not painted as text…
      check findById(panel, AgentActivityMessageContentClass & "-s:1") == nil
      # …and everything around it renders unchanged.
      check findById(panel, AgentActivityMessageContentClass & "-s:0") != nil
      let status = findByClass(card, "agent-test-run-status")
      check status != nil
      check status.textContent == "1 passed, 1 failed"
      check "schemaVersion" notin
        findByClass(panel, AgentActivityConversationClass).textContent

      dispose()

  test "an ordinary message that merely mentions ct test stays a message":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 82)

      vm.setMessages(@[AgentActivityMessageEntry(
        id: "s:0", content: "I will run ct test next", role: aamrAgent)])

      check findByClass(panel, AgentActivityTestRunClass) == nil
      check findById(panel, AgentActivityMessageContentClass & "-s:0") != nil

      dispose()

  test "the card is collapsed until clicked, then lists the tests":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 83)

      feed(vm, plainRun())
      check findByClass(panel, AgentActivityTestRowClass) == nil

      findByClass(panel, "agent-test-run-header").fireEvent("click")
      check vm.isTestRunExpanded("s:1")
      check findAllByClass(panel, AgentActivityTestRowClass).len == 2
      check findById(panel, testRowId("s:1", TestId)) != nil
      check findById(panel, testRowId("s:1", OtherTestId)) != nil

      findByClass(panel, "agent-test-run-header").fireEvent("click")
      check findByClass(panel, AgentActivityTestRowClass) == nil

      dispose()

  test "expanding a test shows its status, duration and captured output":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 84)

      feed(vm, [
        line("run-started", ""),
        line("test-started", TestId),
        line("output", TestId, "\"output\":\"assertion failed at 12\""),
        line("test-finished", TestId,
          "\"status\":\"failed\",\"durationMs\":1500"),
        line("run-finished", "", "\"status\":\"failed\",\"durationMs\":1500"),
      ].join("\n"))

      vm.toggleTestRun("s:1")
      check findByClass(panel, "agent-test-row-details") == nil

      findByClass(panel, "agent-test-row-header").fireEvent("click")
      let details = findByClass(panel, "agent-test-row-details")
      check details != nil
      check findByClass(details, "agent-test-row-detail").textContent ==
        "Status: failed · Duration: 1.5s"
      check findByClass(details, "agent-test-row-output").textContent ==
        "assertion failed at 12"

      dispose()

suite "AA-2 drilling from a test into its recording":

  test "a recorded test offers the drill-down and opens that recording":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var opened: seq[TraceOpenRequest] = @[]
      vm.traceOpen = TraceOpenService(
        openProc: proc(request: TraceOpenRequest) = opened.add request)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 85)

      feed(vm, runWithRecording())
      vm.toggleTestRun("s:1")

      let openButton = findByClass(panel, AgentActivityOpenRecordingClass)
      check openButton != nil
      openButton.fireEvent("click")
      check opened.len == 1
      check opened[0].tracePath == "/tmp/traces/add"
      check opened[0].recordingId == "rec-1"
      check opened[0].testId == TestId
      check opened[0].policy == topCurrentTab

      # Both halves of the --open-policy distinction are reachable.
      findByClass(panel, AgentActivityOpenRecordingClass & "-new-tab")
        .fireEvent("click")
      check opened.len == 2
      check opened[1].policy == topNewTab

      dispose()

  test "a test with no recording renders with no drill-down affordance":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      var opened = 0
      vm.traceOpen = TraceOpenService(
        openProc: proc(request: TraceOpenRequest) = inc opened)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 86)

      feed(vm, plainRun())
      vm.toggleTestRun("s:1")

      # Not vacuous: the rows rendered; the affordance did not.
      check findAllByClass(panel, AgentActivityTestRowClass).len == 2
      check findByClass(panel, AgentActivityOpenRecordingClass) == nil
      check findByClass(panel,
        AgentActivityOpenRecordingClass & "-new-tab") == nil
      check findByClass(panel, "agent-test-row-actions") == nil
      check opened == 0

      dispose()

  test "a failed recording shows diagnostics and offers no trace":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 87)

      feed(vm, failedRecording())
      vm.toggleTestRun("s:1")

      let row = findById(panel, testRowId("s:1", TestId))
      check row != nil
      check AgentActivityTestRowPrefix & "failed" in
        row.attributes.getOrDefault("class", "")
      check findByClass(panel, AgentActivityOpenRecordingClass) == nil

      findByClass(panel, "agent-test-row-header").fireEvent("click")
      check findByClass(panel, AgentActivityRecordingFailedClass) != nil
      let diagnostic = findByClass(panel, "agent-test-row-diagnostic")
      check diagnostic != nil
      check diagnostic.textContent == "ct-mcr exited with 1"
      check findByClass(panel, "agent-test-row-output").textContent ==
        "ct-mcr: cannot open perf events"
      # Still nothing to open, now that the details are visible.
      check findByClass(panel, AgentActivityOpenRecordingClass) == nil

      dispose()

suite "AA-2 an in-progress run, and a run with nothing to report":

  test "an in-progress run renders before the process exits":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 88)

      feed(vm, [
        line("run-started", ""),
        line("test-started", TestId),
      ].join("\n"))
      let card = findByClass(panel, AgentActivityTestRunClass)
      check card != nil
      check AgentActivityTestRunClass & "-running" in
        card.attributes.getOrDefault("class", "")
      check findByClass(card, "agent-test-run-status").textContent ==
        "1 running"

      # The same feed, once the rest of the stream has arrived.
      feed(vm, plainRun())
      let finished = findByClass(panel, AgentActivityTestRunClass)
      check AgentActivityTestRunClass & "-running" notin
        finished.attributes.getOrDefault("class", "")
      check findByClass(finished, "agent-test-run-status").textContent ==
        "1 passed, 1 failed"

      dispose()

  test "a run that reported no tests says so rather than printing 0 passed":
    ## The rule AA-1 preserved when it deleted the Tests card, applied to the
    ## surface AA-1 preserved it *for*: absent data is stated, never rendered
    ## as a zero that reads as success.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 89)

      feed(vm, [
        line("run-started", ""),
        line("run-finished", "", "\"status\":\"passed\""),
      ].join("\n"))

      let status = findByClass(panel, "agent-test-run-status")
      check status != nil
      check status.textContent == "No tests reported"
      let conversation =
        findByClass(panel, AgentActivityConversationClass).textContent
      check "0 passed" notin conversation
      check "0/0" notin conversation
      # Not vacuous: the panel did draw.
      check conversation.len > 0

      dispose()
