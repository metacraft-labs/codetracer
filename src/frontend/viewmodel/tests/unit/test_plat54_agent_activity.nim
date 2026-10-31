## test_plat54_agent_activity.nim — PLAT-54, the Agent Activity pane's
## SHARED model: the words and decisions the desktop's panel used to make in
## its render procs (`viewmodels/agent_activity_text`) and the rows the
## terminal and the GPUI window draw from the desktop's own `AgentActivityVM`
## (`viewmodels/agent_activity_feed`):
##
##   * a turn's header ("Thought for 3s", "Thinking 2s", "Failed", nothing for
##     a finished turn with no timing), the paragraph a finished turn promotes,
##     the "Last agent message" recap, the collapse default, a tool call's dot,
##     a changed file's +N -M (now the same arithmetic on every backend), a
##     run card's three states, an evidence card's five;
##   * the feed, in the desktop's order: the idle state, a review's session
##     notice, a replayed session with an AA-3 evidence card per handoff and an
##     AA-2 run card per `ct test` run, a user turn, an agent turn with its
##     tool-call groups, the prompts; every toggle a press runs;
##   * the actions: a recording opens only where one exists (AA-2), a review
##     opens only where the dataset was read (AA-3), each through the
##     ViewModel's own service;
##   * the desktop's panel, rendered under the MockRenderer from the SAME
##     ViewModel, says the same words the feed does, card by card;
##   * wrapping (no line wider than the pane, every row at least one line) and
##     the reader's position kept while rows arrive (deliverable 3);
##   * a live session's store entry as the feed, and the "working" state the
##     session tab's indicator reads.
##
## Pure, on both Nim backends (vm-unit, vm-unit-js). No mocks: the ViewModel
## is built with no store (it never reads one), and the two services the
## actions call are the ViewModel's own `TraceOpenService` /
## `ReviewOpenService` with a capturing closure — the one stand-in, and not a
## mock: it is exactly the seam a host installs, and the assertion is on the
## request the ViewModel issues through it. The real stack (the ACP replay
## agent, real files, real terminals) is `tui/tests/test_plat54_agent_activity`,
## the PTY suite and the GPUI suite.

import std/[options, strutils, tables, unittest]

import isonim/core/[signals, owner]
import isonim/testing/mock_dom

import store/types
import viewmodels/agent_activity_vm
import viewmodels/agent_activity_feed
import viewmodels/review_session
import viewmodels/omnibar_vm
import ../../editing_core
import views/isonim_agent_activity_view

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 193

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  EvidenceDir = "/tmp/ct-plat54-unit/evidence"
  RunnerLine = """{"schemaVersion":1,"kind":"test-started","providerId":"native-m11","runId":"r","testId":"t1","message":"","output":"","durationMs":0}
{"schemaVersion":1,"kind":"recording-created","providerId":"native-m11","runId":"r","testId":"t1","message":"recorded","output":"","durationMs":0,"trace":{"traceId":"tr","recordingId":"rec","path":"/tmp/ct-plat54-trace","backend":"native","entryPoint":"a.c","metadata":{}}}
{"schemaVersion":1,"kind":"test-finished","providerId":"native-m11","runId":"r","testId":"t1","status":"passed","message":"","output":"","durationMs":83}
{"schemaVersion":1,"kind":"test-started","providerId":"native-m11","runId":"r","testId":"t2","message":"","output":"","durationMs":0}
{"schemaVersion":1,"kind":"test-finished","providerId":"native-m11","runId":"r","testId":"t2","status":"failed","message":"","output":"","durationMs":12}"""

proc collect(name: string): string =
  "ct review collect --repo . --diff main..HEAD -o " & EvidenceDir & "/" & name

proc replayedSession(): ReviewSession =
  ## The AA-2 / AA-3 replay agent's transcripts, as `ct` resolves them.
  ReviewSession(state: rssLoaded, sessionId: "s", backend: "acp", events: @[
    ReviewSessionEvent(kind: "thought", text: "Collecting the review"),
    ReviewSessionEvent(kind: "toolCall", toolName: collect("one.json"),
                       toolCallId: "c1"),
    ReviewSessionEvent(kind: "toolCallUpdate", toolCallId: "c1",
                       status: "completed", text: "wrote one.json"),
    ReviewSessionEvent(kind: "toolCall", toolName: collect("failed.json"),
                       toolCallId: "c2"),
    ReviewSessionEvent(kind: "toolCallUpdate", toolCallId: "c2",
                       status: "failed", text: "error: no recordings"),
    ReviewSessionEvent(kind: "toolCall", toolName: collect("pending.json"),
                       toolCallId: "c3"),
    ReviewSessionEvent(kind: "toolCall", toolName: "ct test record --json-events",
                       toolCallId: "t"),
    ReviewSessionEvent(kind: "toolCallUpdate", toolCallId: "t",
                       status: "completed", text: RunnerLine),
    ReviewSessionEvent(kind: "message", text: "One test fails.")])

proc kinds(rows: seq[AgentFeedRow]): seq[AgentFeedRowKind] =
  for r in rows: result.add r.kind

proc rowOf(rows: seq[AgentFeedRow]; kind: AgentFeedRowKind;
           nth = 0): AgentFeedRow =
  var n = 0
  for r in rows:
    if r.kind == kind:
      if n == nth: return r
      inc n

proc spansText(r: AgentFeedRow): string =
  for s in r.spans: result.add s.text

proc textOf(node: MockNode): string = node.textContent

proc has(rows: seq[AgentFeedRow]; kind: AgentFeedRowKind): bool =
  for r in rows:
    if r.kind == kind: return true

proc findAll(node: MockNode; cls: string): seq[MockNode] =
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        result.add node
        break
  for c in node.children:
    result.add findAll(c, cls)

suite "PLAT-54 the panel's words, decided once":

  test "a turn's header":
    var m = AgentActivityMessageEntry(id: "a", role: aamrAgent)
    ck thoughtHeaderLabel(m) == ""
    m.isLoading = true
    ck thoughtHeaderLabel(m) == "Thinking"
    m.thinkingEndedAt = 3000.0
    m.createdAt = 1000.0
    ck thoughtHeaderLabel(m) == "Thinking 2s"
    m.duration = 75.0
    ck thoughtHeaderLabel(m) == "Thought for 1m 15s"
    m.failed = true
    ck thoughtHeaderLabel(m) == "Failed"
    ck canceledSuffix("") == "(canceled)"
    ck canceledSuffix("Thinking") == " (canceled)"

  test "the paragraph a finished turn promotes, and the recap":
    var m = AgentActivityMessageEntry(id: "a", role: aamrAgent, segments: @[
      AgentActivitySegment(content: "first\n\nsecond paragraph"),
      AgentActivitySegment(isToolCall: true, toolName: "ls",
                           toolStatus: "completed")])
    let groups = computeSegGroups(m.segments)
    ck groups.len == 2
    let f = finalTurnText(m, groups)
    ck f.text == "second paragraph"
    ck f.groupIndex == 0
    m.segments[0].content = "Last agent message: Some(\"done\\nnow\")"
    ck finalTurnText(m, computeSegGroups(m.segments)).text == "done\nnow"
    m.isLoading = true
    ck finalTurnText(m, groups).groupIndex == -1
    ck not startsCollapsed(m, groups)
    m.isLoading = false
    ck startsCollapsed(m, groups)
    ck not startsCollapsed(AgentActivityMessageEntry(content: "flat"), @[])

  test "a tool call's dot, a file's lines, the card states":
    ck toolState("completed") == atsDone
    ck toolState("failed") == atsFailed
    ck toolState("in_progress") == atsRunning
    ck toolState("") == atsRunning
    ck computeDiffStats("a\nb\nc", "a\nc\nd\ne") == (2, 1)
    ck computeDiffStats("", "") == (0, 0)
    ck filesChangedText(1) == "1 file changed"
    ck filesChangedText(3) == "3 files changed"
    ck wallClockTime(0.0) == ""
    ck relativeTimeAt(0.0, 5000.0) == ""
    ck relativeTimeAt(1000.0, 61_000.0) == "1m ago"

  test "agent markdown as spans":
    let segs = parseInlineCode("run `ls` **now**\n| a | b |\n|---|---|\n| 1 | 2 |")
    ck segs[1].kind == mskCode
    ck segs[1].content == "ls"
    ck segs[3].kind == mskBold
    var tables = 0
    for s in segs:
      if s.kind == mskTable: inc tables
    ck tables == 1

suite "PLAT-54 the feed, in the desktop's order":

  test "with nothing at all, the idle state and its chips":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      let rows = vm.agentFeed()
      ck rows.kinds == @[frIdleHeading, frIdleSubtitle, frIdleChip,
                         frIdleChip, frIdleChip]
      ck rows[0].spansText == AgentIdleHeading
      ck promptPlaceholder(vm) == AgentActivityPlaceholderText
      let effect = vm.runFeedAction(rows[2], rows[2].press)
      ck effect.handled
      ck vm.inputValue.val == AgentIdleChips[0]
      dispose()

  test "a session that could not be loaded says so, first":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      applyReviewSession(vm, ReviewSession(state: rssUnavailable,
        sessionId: "gone", message: "unknown session: gone"))
      let rows = vm.agentFeed()
      ck rows.len == 1
      ck rows[0].kind == frNotice
      ck "could not be loaded" in rows[0].spansText
      ck "unknown session: gone" in rows[0].spansText
      dispose()

  test "a replayed session: evidence cards and a run card in place":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      applyReviewSession(vm, replayedSession())
      vm.applyEvidenceDataset(EvidenceDir & "/one.json",
        EvidenceDataset(state: edsReady, fileCount: 4, commit: "a1b2c3d4"))
      let rows = vm.agentFeed()
      var headers: seq[AgentFeedRow] = @[]
      for r in rows:
        if r.kind == frEvidenceHeader: headers.add r
      ck headers.len == 3
      ck headers[0].state == "ready"
      ck headers[1].state == "failed"
      ck headers[2].state == "unreported"
      ck headers[0].buttons.len == 1
      ck headers[0].buttons[0].label == AgentOpenReviewLabel
      ck headers[1].buttons.len == 0
      ck headers[2].buttons.len == 0
      ck "4 files" in headers[0].spansText
      ck rows.rowOf(frEvidenceOutput).spansText == "error: no recordings"
      # The run card replaced the runner's raw output: no schemaVersion.
      for r in rows:
        ck "schemaVersion" notin r.spansText
      let run = rows.rowOf(frTestRun)
      ck run.state == "failed"
      ck "1 passed" in run.spansText
      # The order is the session's: the evidence cards come before the run.
      var evidenceAt, runAt = -1
      for i, r in rows:
        if r.kind == frEvidenceHeader and evidenceAt < 0: evidenceAt = i
        if r.kind == frTestRun: runAt = i
      ck evidenceAt >= 0 and runAt > evidenceAt
      dispose()

  test "the run card drills down, and a recording opens only where one is":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      var opened: seq[TraceOpenRequest] = @[]
      vm.traceOpen = TraceOpenService(openProc: proc(r: TraceOpenRequest) =
        opened.add r)
      applyReviewSession(vm, replayedSession())
      var rows = vm.agentFeed()
      ck not rows.has(frTestRow)   # collapsed by default
      let run = rows.rowOf(frTestRun)
      discard vm.runFeedAction(run, run.press)
      rows = vm.agentFeed()
      let recorded = rows.rowOf(frTestRow, 0)
      let failed = rows.rowOf(frTestRow, 1)
      ck recorded.kind == frTestRow and recorded.state == "passed"
      ck recorded.buttons.len == 2
      ck failed.state == "failed" and failed.buttons.len == 0
      ck vm.runFeedAction(recorded, recorded.buttons[1]).handled
      ck opened.len == 1
      ck opened[0].tracePath == "/tmp/ct-plat54-trace"
      ck opened[0].policy == topNewTab
      ck not vm.runFeedAction(failed,
        AgentFeedAction(kind: faOpenRecording)).handled
      ck opened.len == 1
      discard vm.runFeedAction(recorded, recorded.press)
      rows = vm.agentFeed()
      ck rows.rowOf(frTestDetail).spansText == "Status: passed · Duration: 83ms"
      dispose()

  test "a review opens only from a card whose dataset was read":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      var asked: seq[ReviewDatasetRequest] = @[]
      vm.reviewOpen = ReviewOpenService(requestProc:
        proc(r: ReviewDatasetRequest) = asked.add r)
      applyReviewSession(vm, replayedSession())
      # Inspecting: one request per completed call's dataset, before a click.
      var inspects = 0
      for r in asked:
        if r.kind == rdrInspect: inc inspects
      ck inspects == 1
      var rows = vm.agentFeed()
      let reading = rows.rowOf(frEvidenceHeader)
      ck reading.state == "reading"
      ck not vm.runFeedAction(reading,
        AgentFeedAction(kind: faOpenEvidence)).handled
      vm.applyEvidenceDataset(EvidenceDir & "/one.json",
        EvidenceDataset(state: edsReady, fileCount: 2))
      rows = vm.agentFeed()
      let ready = rows.rowOf(frEvidenceHeader)
      ck vm.runFeedAction(ready, ready.buttons[0]).handled
      ck asked[^1].kind == rdrOpen
      ck asked[^1].datasetPath == EvidenceDir & "/one.json"
      dispose()

  test "an agent turn: collapsed when done, its tool groups, a toggle":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      vm.setMessages(@[
        AgentActivityMessageEntry(id: "u", role: aamrUser, content: "fix it"),
        AgentActivityMessageEntry(id: "a", role: aamrAgent, duration: 3.0,
          segments: @[
            AgentActivitySegment(content: "Looking."),
            AgentActivitySegment(isToolCall: true, toolName: "grep",
                                 toolStatus: "completed", toolCallId: "1"),
            AgentActivitySegment(isToolCall: true, toolName: "sed",
                                 toolStatus: "failed", toolCallId: "2"),
            AgentActivitySegment(content: "Done: fixed.")],
          diffs: @[AgentActivityDiffEntry(id: 0, path: "a.nim",
                                          original: "x", modified: "x\ny")])])
      var rows = vm.agentFeed()
      ck rows[0].kind == frUserHeader
      let header = rows.rowOf(frAgentHeader)
      ck "Thought for 3s" in header.spansText
      # Collapsed: the header, the promoted final text, the files.
      ck not rows.has(frToolCall)
      ck rows.rowOf(frText, 1).spansText == "Done: fixed."
      ck rows.rowOf(frDiffHeader).spansText == "1 file changed"
      ck rows.rowOf(frDiffFile).spansText == "a.nim  +1 -0"
      discard vm.runFeedAction(header, header.press)
      rows = vm.agentFeed()
      let current = rows.rowOf(frToolCall)
      ck current.spansText == "sed" and current.state == "failed"
      let toggle = rows.rowOf(frToolsToggle)
      ck "2 tools used" in toggle.spansText
      discard vm.runFeedAction(toggle, toggle.press)
      rows = vm.agentFeed()
      ck rows.rowOf(frToolCall, 0).spansText == "grep"
      ck rows.rowOf(frToolCall, 0).state == "done"
      dispose()

  test "the prompts: a password and a permission with three answers":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      vm.setPromptFlags(wantsPassword = true, wantsPermission = true)
      vm.setPermissionInfo("Run `rm -rf build`")
      let rows = vm.agentFeed()
      ck rows.has(frPasswordPrompt)
      ck rows.rowOf(frPermissionText).spansText == "Run `rm -rf build`"
      let sub = rows.rowOf(frPermissionSubtitle)
      ck sub.buttons.len == 3
      ck sub.buttons[0].arg == "allow_once"
      ck sub.buttons[2].label == "Deny"
      dispose()

suite "PLAT-54 the desktop's panel says what the feed says":

  test "card by card, the same words from the same ViewModel":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      applyReviewSession(vm, replayedSession())
      vm.applyEvidenceDataset(EvidenceDir & "/one.json",
        EvidenceDataset(state: edsReady, fileCount: 4, commit: "a1b2c3d4"))
      vm.toggleTestRun(vm.testRuns.val[0].anchorId)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, 1)
      let rows = vm.agentFeed()
      let cards = findAll(panel, "agent-evidence")
      var headers: seq[AgentFeedRow] = @[]
      for row in rows:
        if row.kind == frEvidenceHeader: headers.add row
      ck cards.len == headers.len
      for i, card in cards:
        let kind = findAll(card, "agent-evidence-kind")
        ck kind.len == 1 and textOf(kind[0]) == headers[i].spans[0].text
        ck ("agent-evidence-" & headers[i].state) in
           card.attributes.getOrDefault("class", "")
      let runs = findAll(panel, "agent-test-run-title")
      ck runs.len == 1
      ck textOf(runs[0]) == rows.rowOf(frTestRun).spans[1].text
      let names = findAll(panel, "agent-test-row-name")
      ck names.len == 2
      ck textOf(names[0]) == rows.rowOf(frTestRow, 0).spans[1].text.strip()
      let notice = findAll(panel, "agent-session-notice")
      ck notice.len == 0 and not rows.has(frNotice)
      dispose()

suite "PLAT-54 lines and the reader's place":

  test "wrapping: no line wider than the pane, every row at least one line":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      applyReviewSession(vm, replayedSession())
      let rows = vm.agentFeed()
      for width in [12, 20, 37, 80]:
        let lines = wrapFeed(rows, width)
        var seen = newSeq[bool](rows.len)
        var widest = 0
        for l in lines:
          seen[l.row] = true
          var w = 0
          for s in l.spans: w += runeMeasure(s.text)
          widest = max(widest, w)
        ck widest <= width
        ck false notin seen
      dispose()

  test "rows arriving keep a reader who scrolled up on their line":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      var messages: seq[AgentActivityMessageEntry] = @[]
      for i in 0 ..< 30:
        messages.add AgentActivityMessageEntry(id: "m" & $i, role: aamrAgent,
                                               content: "line " & $i)
      vm.setMessages(messages)
      var rows = vm.agentFeed()
      var lines = wrapFeed(rows, 40)
      var scroll = initFeedScroll()
      scroll.settle(rows, lines, 10)
      ck scroll.follow
      ck scroll.top == maxTop(lines.len, 10)
      scroll.scrollTo(5, rows, lines, 10)
      ck not scroll.follow
      let key = rows[lines[5].row].key
      # More rows arrive, ABOVE nothing and below everything.
      for i in 30 ..< 45:
        messages.add AgentActivityMessageEntry(id: "m" & $i, role: aamrAgent,
                                               content: "line " & $i)
      vm.setMessages(messages)
      rows = vm.agentFeed()
      lines = wrapFeed(rows, 40)
      scroll.settle(rows, lines, 10)
      ck scroll.top == 5
      ck rows[lines[scroll.top].row].key == key
      # A notice appears above: the same line stays at the top.
      vm.setSessionNotice("Agent session s loaded.")
      rows = vm.agentFeed()
      lines = wrapFeed(rows, 40)
      scroll.settle(rows, lines, 10)
      ck rows[lines[scroll.top].row].key == key
      ck scroll.top == 6
      # Back at the end, it follows again.
      scroll.scrollTo(lines.len, rows, lines, 10)
      ck scroll.follow
      dispose()

suite "PLAT-54 the prompt's add-context menu (DeepReview-GUI §2.2.7)":

  test "the four items, in the desktop's order and words":
    var labels: seq[string] = @[]
    for item in AgentAddContextItem:
      labels.add item.label
    ck labels == @["Upload attachment", "Files & folders", "Editor selection",
                   "Recording / trace"]
    # The desktop's dropdown draws exactly these, from the same enum.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      vm.addContextDropdownOpen.val = true
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, 1)
      var drawn: seq[string] = @[]
      for item in findAll(panel, "agent-add-context-menu-item"):
        # The label alone, whatever else a row carries.
        drawn.add textOf(findAll(item, "ct-menu-item-label")[0]).strip()
      ck drawn == labels
      dispose()

  test "the header a prompt with attachments carries":
    ck contextPromptText("fix it", []) == "fix it"
    ck contextPromptText("fix it", ["src/a.nim", "src/a.nim:3-5"]) ==
       "Context paths:\n- src/a.nim\n- src/a.nim:3-5\n\nfix it"
    ck editorSelectionContext("src/a.nim", 5, 3) == "src/a.nim:3-5"
    ck editorSelectionContext("src/a.nim", 7, 7) == "src/a.nim:7"
    ck editorSelectionContext("", 1, 2) == ""
    ck withContextPath(["a"], "a") == @["a"]
    ck withContextPath(["a"], " b ") == @["a", "b"]
    # The lines *Editor selection* attaches: the caret's, or the selection's.
    var d = initEditingDocument("src/a.nim", "one\ntwo\nthree\nfour\nfive\n")
    d.moveCaretTo(2, 0)
    ck d.selectedLines == (first: 3, last: 3)
    d.extendSelectionTo(3, 2)
    ck d.selectedLines == (first: 3, last: 4)
    d.moveCaretTo(4, 1)
    d.extendSelectionTo(1, 0)
    ck d.selectedLines == (first: 2, last: 5)
    # A selection that ends at the START of a line does not cover it — on
    # the native document, and in the desktop's reading of Monaco's ranges
    # (`selectedLinesOf`), so the two attach the same lines.
    d.moveCaretTo(2, 0)
    d.extendSelectionTo(4, 0)
    ck d.selectedLines == (first: 3, last: 4)
    ck selectedLinesOf([(startLine: 3, startColumn: 1, endLine: 5,
                         endColumn: 1)], 9) == (first: 3, last: 4)
    ck selectedLinesOf([(startLine: 3, startColumn: 2, endLine: 5,
                         endColumn: 3)], 9) == (first: 3, last: 5)
    # Nothing selected: the caret's line. Several ranges: all of them.
    ck selectedLinesOf([(startLine: 4, startColumn: 2, endLine: 4,
                         endColumn: 2)], 4) == (first: 4, last: 4)
    ck selectedLinesOf([(startLine: 7, startColumn: 1, endLine: 7,
                         endColumn: 4),
                        (startLine: 2, startColumn: 1, endLine: 3,
                         endColumn: 2)], 1) == (first: 2, last: 7)
    ck selectedLinesOf([], 6) == (first: 6, last: 6)
    # A path is attached once, however often it is chosen.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      vm.addContextPath("src/a.nim:3")
      vm.addContextPath("src/a.nim:3")
      ck vm.contextPaths.val == @["src/a.nim:3"]
      dispose()

  test "the desktop's Editor selection: the editor's lines, or disabled and why":
    # The desktop's dropdown asks its host, as it draws, why *Editor
    # selection* is unavailable (`editorSelectionUnavailableReason`): a
    # reason draws the item disabled with the reason as its hover text; none
    # draws it enabled, and a press hands the host the item.
    for (reason, enabled) in [(AgentNoEditorSelectionReason, false), ("", true)]:
      createRoot proc(dispose: proc()) =
        let vm = createAgentActivityVM(nil)
        vm.addContextDropdownOpen.val = true
        var picked = 0
        let callbacks = AgentActivityCallbacks(
          editorSelectionUnavailableReason: proc(): string = reason,
          onAddEditorSelection: proc() = inc picked)
        let r = MockRenderer()
        let panel = renderAgentActivityPanel[MockRenderer, MockNode](
          r, vm, 1, callbacks = callbacks)
        let items = findAll(panel, "agent-add-context-menu-item")
        ck items.len == 4
        let item = items[ord(aciEditorSelection)]
        ck textOf(item).contains(aciEditorSelection.label)
        let disabled = findAll(item, "ct-menu-item--disabled").len > 0
        ck disabled == not enabled
        ck item.attributes.getOrDefault("title", "") == reason
        item.fireEvent("click")
        ck picked == (if enabled: 1 else: 0)
        dispose()

  test "attachments are rows above the prompt, each removable by its path":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      vm.addContextPath("src/a.nim")
      vm.addContextPath("src/b.nim:2-4")
      # Idle, the attachments still follow the idle rows.
      var rows = vm.agentFeed()
      ck rows.kinds == @[frIdleHeading, frIdleSubtitle, frIdleChip,
                         frIdleChip, frIdleChip, frContextPath, frContextPath]
      ck rows[5].spansText == AgentContextChipLead & "src/a.nim"
      ck rows[6].buttons.len == 1 and
         rows[6].buttons[0].kind == faRemoveContext and
         rows[6].buttons[0].label == AgentContextRemoveLabel
      # After a conversation too, last.
      applyReviewSession(vm, replayedSession())
      rows = vm.agentFeed()
      ck rows[^1].kind == frContextPath and rows[^2].kind == frContextPath
      ck rows[^3].kind != frContextPath
      # `[×]` removes the row's own path…
      let first = rows[^2]
      let effect = vm.runFeedAction(first, first.buttons[0])
      ck effect.handled
      ck vm.contextPaths.val == @["src/b.nim:2-4"]
      # …and a press read off a stale line removes nothing else.
      let stale = vm.runFeedAction(first, first.buttons[0])
      ck not stale.handled
      ck vm.contextPaths.val == @["src/b.nim:2-4"]
      dispose()

  test "the omnibox's attach modes":
    ck classifyOmnibarQuery(":attach src/a").mode == omAttach
    ck classifyOmnibarQuery(":attach src/a").needle == "src/a"
    ck classifyOmnibarQuery(":attach-recording /tmp/r").mode ==
       omAttachRecording
    ck classifyOmnibarQuery(":attach-recording /tmp/r").needle == "/tmp/r"
    ck classifyOmnibarQuery(":attachx").mode == omCommand
    ck desktopKindOf(omAttach) == omCommand and
       desktopKindOf(omAttachRecording) == omCommand
    let index = @[
      OmnibarEntry(kind: omFile, label: "parser.nim", detail: "src",
                   target: "src/parser.nim"),
      OmnibarEntry(kind: omFile, label: "lexer.nim", detail: "src",
                   target: "src/lexer.nim"),
      OmnibarEntry(kind: omRecording, label: "trace-1", detail: "",
                   target: "/tmp/traces/trace-1"),
      OmnibarEntry(kind: omCommand, label: "Step over", target: "step")]
    # Files and their folders, each once; no command, no recording.
    var labels: seq[string] = @[]
    for r in rankOmnibar(index, omAttach, ""):
      ck r.entry.kind == omAttach
      labels.add r.entry.label
    ck labels.len == 3
    ck "src/" in labels and "parser.nim" in labels and "lexer.nim" in labels
    # A typed path is offered first, as typed.
    let typed = rankOmnibar(index, omAttach, "docs/notes.md")
    ck typed[0].entry.target == "docs/notes.md"
    # The recording mode finds the recordings only.
    let recs = rankOmnibar(index, omAttachRecording, "")
    ck recs.len == 1 and recs[0].entry.target == "/tmp/traces/trace-1" and
       recs[0].entry.kind == omAttachRecording

suite "PLAT-54 a live session's entry as the feed":

  test "events in order, working while it runs, done when it ends":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(nil)
      var session = AgentServiceSessionEntry(tabId: "tab", lifecycle: aslRunning)
      session.events.add AgentServiceEventEntry(id: "e0", kind: aseMessage,
                                                text: "Reading")
      vm.applyAgentSession(session)
      ck vm.isLoading.val
      ck agentSessionRunning(session)
      var rows = vm.agentFeed()
      # In flight and still thinking: the header says so, as the desktop's.
      ck rows.rowOf(frAgentHeader).state == "running"
      ck "Thinking" in rows.rowOf(frAgentHeader).spansText
      session.events.add AgentServiceEventEntry(id: "e1", kind: aseCompleted,
                                                text: "Finished")
      session.lifecycle = aslCompleted
      vm.applyAgentSession(session)
      ck not vm.isLoading.val
      rows = vm.agentFeed()
      ck rows.rowOf(frText, 1).spansText == "Finished"
      ck vm.sessionKey.val == "tab"
      dispose()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
