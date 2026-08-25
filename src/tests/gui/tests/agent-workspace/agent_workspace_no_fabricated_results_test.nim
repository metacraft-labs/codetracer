## agent_workspace_no_fabricated_results_test.nim
##
## AA-2 — the Agent Workspace summary bar states absent data instead of
## printing a zero that reads as a measurement.
##
## `codetracer-specs/DeepReview/Agent-Activity-Panel.milestones.org`, AA-1's
## "Found while checking the absence rule: a live violation of it elsewhere",
## which it assigns to AA-2:
##
##   "`isonim_agent_workspace_view.testsText` renders that as
##    `{testsPassed}/{testsRun} passed`, so the Agent Workspace panel prints
##    **1/1 passed** and **100.0%** whenever review mode is on and **0/0
##    passed** whenever it is off — in both cases a claim about a suite that
##    never ran, derived from a flag.  No test asserts on this path."
##
## AA-2's deliverable is to "decide the no-data rendering once, apply it to
## both surfaces, and cover it with a positive assertion — the negatives in
## `deepreview-gui.spec.ts` only prove the *review* window is silent."  So
## every case below pairs the negative (no fabricated figure) with a positive
## one (the panel drew, and a *real* measurement still renders), because "no
## 0/0" is otherwise satisfied by a panel that rendered nothing at all.
##
## The decision, stated once and shared with the session feed: where something
## happened, say so in words (`test_run_summary_vm.summaryText` →
## "No tests reported" for a run that reported no tests); where nothing
## happened, render nothing (`review_entry.coverageText`'s empty badge, and
## these three).
##
## TEST DOUBLE JUSTIFICATION (workspace policy).  Two, neither standing in for
## logic under test: `MockRenderer` (IsoNim's headless renderer — the view is
## generic over the renderer, so the same body runs in the browser) and
## `MockBackendService` (this suite sends no backend request; the store needs
## a service to construct).  The *production* fabrication that this pins the
## removal of is asserted directly against the production source, below.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom

import backend/mock_backend
import store/replay_data_store
import store/types
import viewmodels/agent_workspace_vm
import views/isonim_agent_workspace_view

proc makeStore(): ReplayDataStore =
  createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())

proc findByClass(node: MockNode; cls: string): MockNode =
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  nil

proc renderWith(vm: AgentWorkspaceVM; summary: AgentWorkspaceSummary):
    MockNode =
  vm.setWorkspaceMetadata("/tmp/agent-workspace", "session-1")
  vm.setFiles(@[AgentWorkspaceFileEntry(path: "src/main.nim")])
  vm.setSummary(summary)
  renderAgentWorkspacePanel(MockRenderer(), vm, componentId = 91)

suite "AA-2 the Agent Workspace summary states absent data":

  test "an unmeasured workspace prints no tests figure and no 0/0":
    createRoot proc(dispose: proc()) =
      let vm = createAgentWorkspaceVM(makeStore())
      let panel = renderWith(vm, AgentWorkspaceSummary())
      let bar = findByClass(panel, AgentWorkspaceSummaryClass)
      # Not vacuous: the panel rendered its summary bar and its file list.
      check bar != nil
      check findByClass(panel, AgentWorkspaceFileListClass) != nil
      let barText = bar.textContent
      check "Tests:" notin barText
      check "0/0" notin barText
      check "0 passed" notin barText
      check "Coverage:" notin barText
      check "0.0%" notin barText
      check "Functions traced:" notin barText
      # …and what the bar is *for* is still there.
      check "Coverage" in barText   # the overlay toggle, "Show Coverage"
      dispose()

  test "a measured workspace still prints exactly what was measured":
    createRoot proc(dispose: proc()) =
      let vm = createAgentWorkspaceVM(makeStore())
      let panel = renderWith(vm, AgentWorkspaceSummary(
        totalLinesCovered: 7,
        totalLinesUncovered: 3,
        coveragePercent: 70.0,
        testsRun: 5,
        testsPassed: 4,
        testsFailed: 1,
        functionsTraced: 2))
      let barText = findByClass(panel, AgentWorkspaceSummaryClass).textContent
      check "Tests: 4/5 passed" in barText
      check "Coverage: 70.0%" in barText
      check "Functions traced: 2" in barText
      dispose()

  test "a suite that genuinely ran and failed everything is not silenced":
    ## The rule is about *absent* data, not about zero being unprintable.  A
    ## run of five tests where none passed reports "0/5 passed", because that
    ## is a measurement.
    createRoot proc(dispose: proc()) =
      let vm = createAgentWorkspaceVM(makeStore())
      let panel = renderWith(vm, AgentWorkspaceSummary(
        testsRun: 5, testsPassed: 0, testsFailed: 5))
      let barText = findByClass(panel, AgentWorkspaceSummaryClass).textContent
      check "Tests: 0/5 passed" in barText
      dispose()

  test "a coverage percentage on its own is a measurement, and still prints":
    ## Regression guard.  The first cut of this rule keyed `hasCoverageData`
    ## solely on the line totals, which silently dropped a summary that
    ## carried a real `coveragePercent` and no line counts beside it — the
    ## mirror of the defect this file exists to prevent, a measurement hidden
    ## rather than an invented one shown.  It went unnoticed because the only
    ## test covering it lives in `views/isonim_views_test.nim`
    ## ("workspace metadata renders header summary body and editor id"), which
    ## the native lane never reaches: that file SIGSEGVs at line 5388, and
    ## everything after it is dead there.  Asserted here too, in a file that
    ## runs on both backends.
    createRoot proc(dispose: proc()) =
      let vm = createAgentWorkspaceVM(makeStore())
      let panel = renderWith(vm, AgentWorkspaceSummary(
        coveragePercent: 62.5, testsRun: 4, testsPassed: 3, testsFailed: 1,
        functionsTraced: 2))
      let barText = findByClass(panel, AgentWorkspaceSummaryClass).textContent
      check "Coverage: 62.5%" in barText
      check "Tests: 3/4 passed" in barText
      check "Functions traced: 2" in barText
      dispose()

  test "the text helpers say nothing rather than nothing-shaped-like-zero":
    check testsText(AgentWorkspaceSummary()) == ""
    check summaryCoverageText(AgentWorkspaceSummary()) == ""
    check functionsTracedText(AgentWorkspaceSummary()) == ""
    check not AgentWorkspaceSummary().hasTestResults
    check not AgentWorkspaceSummary().hasCoverageData
    check testsText(AgentWorkspaceSummary(testsRun: 1, testsPassed: 1)) ==
      "1/1 passed"
    check summaryCoverageText(AgentWorkspaceSummary(
      totalLinesCovered: 1, coveragePercent: 100.0)) == "100.0%"
    # Line totals alone are a measurement — a file with 100 uncovered lines
    # and none covered really is 0.0% covered — and so is a percentage alone.
    check summaryCoverageText(AgentWorkspaceSummary(
      totalLinesUncovered: 100, coveragePercent: 0.0)) == "0.0%"
    check summaryCoverageText(AgentWorkspaceSummary(
      coveragePercent: 62.5)) == "62.5%"

when not defined(js):
  ## The two suites below read the production sources.
  ##
  ## Not through the GUI, because the defect *was* a source-level one — seven
  ## counters written from `launcher.vm.vcs.deepReviewMode.val` — and a
  ## rendering test cannot distinguish "the producer stopped fabricating" from
  ## "the renderer now hides the fabrication".  Both had to happen, so both are
  ## asserted: the rendering rule in the suites above, the producer here.
  ##
  ## Native-only for the same reason `agent_activity_rollup_removal_test.nim`
  ## and `deepreview_entry_test.nim`'s source-contract suites are: the JS
  ## backend has no `readFile`.  Everything above runs on both backends.
  import std/os

  suite "AA-2 the producer no longer fabricates the summary":

    test "syncWorkspace does not derive the summary from deepReviewMode":
      let source = readFile("src/frontend/ui/agentic_session_launcher.nim")
      let syncStart = source.find("proc syncWorkspace(")
      check syncStart >= 0
      let syncEnd = source.find("\nproc ", syncStart + 1)
      check syncEnd > syncStart
      let body = source[syncStart ..< syncEnd]
      check "drSummary" notin body
      check "ActivityDeepReviewSummary" notin body
      check "testsPassed" notin body
      check "coveragePercent" notin body

    test "the accumulating producer is untouched":
      ## The counters have exactly one legitimate producer, and AA-2 must not
      ## have taken it with the fabrication: `handleDeepReviewNotification`
      ## still accumulates real notifications into the same field.
      let source = readFile("src/frontend/ui/agent_workspace.nim")
      check "self.drSummary.testsRun += 1" in source
      check "self.drSummary.testsPassed += 1" in source
      check "self.drSummary.functionsTraced += 1" in source
      check "self.drSummary.coveragePercent =" in source
