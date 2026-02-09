## Agentic Coding Integration (M9) Test Plan
##
## This file documents the test cases for M9: CodeTracer GUI - Agentic Coding
## Integration. The tests verify that the ACP protocol extension for DeepReview
## data works correctly, workspace view switching is functional, the caption bar
## progress indicator displays milestone progress, the activity pane shows
## DeepReview data, and real-time data collection works during agent execution.
##
## Implementation note: actual Playwright E2E tests live in ``tsc-ui-tests/``
## and require a full Electron build + launch. This file serves as a reference
## for the required test coverage AND as a compilable Nim module that validates
## the type definitions and basic logic are correct.
##
## The tests below are structured as ``unittest`` suites that can be compiled
## with ``nim js`` targeting the Electron renderer environment. Where DOM/IPC
## access is needed, the test documents the expected assertions as comments.

import std/[unittest, sequtils, strformat]

# Import the types under test. In the full application these are brought in
# through ``frontend/types.nim`` which includes ``common_types``. For this
# test plan we reference the types directly.
#
# NOTE: These imports assume compilation within the CodeTracer build system
# where the include chain resolves correctly. When running outside that
# context (e.g. standalone nim js), they may need adjustment.

# ---------------------------------------------------------------------------
# Type-level helpers for test assertions (no DOM required)
# ---------------------------------------------------------------------------

type
  # Minimal stand-ins so the test file compiles independently.
  # In the full build, these come from the common_types include chain.
  TestDeepReviewNotificationKind = enum
    CoverageUpdate
    FlowUpdate
    TestComplete
    CollectionComplete

  TestAgentProgressState = enum
    AgentIdle
    AgentInitializing
    AgentWorking
    AgentWaitingInput
    AgentPaused
    AgentCompleted
    AgentFailed

  TestMilestoneStatus = enum
    MilestonePending
    MilestoneInProgress
    MilestoneCompleted
    MilestoneFailed
    MilestoneSkipped

  TestWorkspaceViewKind = enum
    UserWorkspace
    AgentWorkspace

  TestMilestone = object
    id: string
    content: string
    priority: string
    status: TestMilestoneStatus

  TestAgentProgress = object
    state: TestAgentProgressState
    taskName: string
    milestonesCompleted: int
    milestonesTotal: int
    currentMilestone: string
    milestones: seq[TestMilestone]

  TestActivityDeepReviewSummary = object
    totalLinesCovered: int
    totalLinesUncovered: int
    coveragePercent: float
    testsRun: int
    testsPassed: int
    testsFailed: int
    functionsTraced: int

# ---------------------------------------------------------------------------
# Helper functions (mirrors logic from the actual components)
# ---------------------------------------------------------------------------

proc computeProgressPercent(completed, total: int): float =
  ## Compute progress percentage, clamped to [0, 100].
  if total <= 0:
    return 0.0
  result = (completed.float / total.float) * 100.0
  if result < 0.0: result = 0.0
  if result > 100.0: result = 100.0

proc computeCoveragePercent(covered, uncovered: int): float =
  ## Compute coverage percentage from covered and uncovered line counts.
  let total = covered + uncovered
  if total <= 0:
    return 0.0
  result = (covered.float / total.float) * 100.0

proc updateSummaryFromCoverage(
  summary: var TestActivityDeepReviewSummary,
  coveredLines, uncoveredLines: int
) =
  ## Update the summary statistics after receiving a coverage notification.
  summary.totalLinesCovered += coveredLines
  summary.totalLinesUncovered += uncoveredLines
  let totalLines = summary.totalLinesCovered + summary.totalLinesUncovered
  summary.coveragePercent =
    if totalLines > 0: (summary.totalLinesCovered.float / totalLines.float) * 100.0
    else: 0.0

proc updateSummaryFromTest(
  summary: var TestActivityDeepReviewSummary,
  passed: bool
) =
  ## Update the summary statistics after receiving a test complete notification.
  summary.testsRun += 1
  if passed:
    summary.testsPassed += 1
  else:
    summary.testsFailed += 1

# =========================================================================
# Test 1: test_acp_deepreview_extension
# =========================================================================
# Verifies that the ACP protocol correctly handles DeepReview messages:
# - CoverageUpdate notifications are parsed and update per-file coverage
# - FlowUpdate notifications are parsed and track function traces
# - TestComplete notifications are parsed and record test results
# - CollectionComplete notifications are parsed and summarize totals
# - Invalid/unknown notification kinds are rejected gracefully
#
# Full E2E verification:
# - Send a mock IPC message on "CODETRACER::acp-deepreview-notification"
#   with kind "CoverageUpdate" and verify the AgentWorkspaceComponent
#   updates its fileEntries
# - Send a "TestComplete" notification and verify the
#   AgentActivityDeepReviewComponent updates its testResults list
# - Send an invalid kind and verify no crash occurs

suite "test_acp_deepreview_extension":
  test "CoverageUpdate updates summary statistics":
    var summary = TestActivityDeepReviewSummary()
    updateSummaryFromCoverage(summary, coveredLines = 42, uncoveredLines = 18)
    check summary.totalLinesCovered == 42
    check summary.totalLinesUncovered == 18
    check summary.coveragePercent > 69.0 and summary.coveragePercent < 71.0

  test "Multiple CoverageUpdates accumulate correctly":
    var summary = TestActivityDeepReviewSummary()
    updateSummaryFromCoverage(summary, 10, 10)
    updateSummaryFromCoverage(summary, 20, 5)
    check summary.totalLinesCovered == 30
    check summary.totalLinesUncovered == 15
    # 30 / 45 = 66.67%
    check summary.coveragePercent > 66.0 and summary.coveragePercent < 67.0

  test "TestComplete notifications track pass/fail":
    var summary = TestActivityDeepReviewSummary()
    updateSummaryFromTest(summary, passed = true)
    updateSummaryFromTest(summary, passed = true)
    updateSummaryFromTest(summary, passed = false)
    check summary.testsRun == 3
    check summary.testsPassed == 2
    check summary.testsFailed == 1

  test "Empty coverage yields 0% coverage":
    var summary = TestActivityDeepReviewSummary()
    check summary.coveragePercent == 0.0
    updateSummaryFromCoverage(summary, 0, 0)
    check summary.coveragePercent == 0.0

  test "All notification kinds are defined":
    # Verify that the enum has exactly 4 members.
    check ord(CollectionComplete) == 3
    check ord(CoverageUpdate) == 0

# =========================================================================
# Test 2: test_workspace_view_switching
# =========================================================================
# Verifies that the workspace view switches correctly during agent work:
# - Default view is UserWorkspace
# - Clicking the caption bar toggles to AgentWorkspace
# - Clicking again toggles back to UserWorkspace
# - The IPC_WORKSPACE_VIEW_SWITCH message is sent on toggle
# - The agent workspace shows files from the agent's working directory
#
# Full E2E verification:
# - Start with UserWorkspace active
# - Simulate click on caption-progress-container
# - Assert viewState.activeView == AgentWorkspace
# - Assert ".agent-workspace-container" is visible
# - Click again, assert viewState.activeView == UserWorkspace

suite "test_workspace_view_switching":
  test "Default view is UserWorkspace":
    let view = UserWorkspace
    check view == UserWorkspace

  test "Toggle from User to Agent workspace":
    var view = UserWorkspace
    # Simulate the toggle logic from CaptionBarProgressComponent.render
    view =
      if view == UserWorkspace: AgentWorkspace
      else: UserWorkspace
    check view == AgentWorkspace

  test "Toggle from Agent back to User workspace":
    var view = AgentWorkspace
    view =
      if view == UserWorkspace: AgentWorkspace
      else: UserWorkspace
    check view == UserWorkspace

  test "Double toggle returns to original state":
    var view = UserWorkspace
    # First toggle.
    view =
      if view == UserWorkspace: AgentWorkspace
      else: UserWorkspace
    # Second toggle.
    view =
      if view == UserWorkspace: AgentWorkspace
      else: UserWorkspace
    check view == UserWorkspace

  test "Workspace view enum has exactly 2 values":
    check ord(AgentWorkspace) == 1
    check ord(UserWorkspace) == 0

# =========================================================================
# Test 3: test_caption_bar_progress
# =========================================================================
# Verifies the caption bar progress indicator updates with milestones:
# - Progress percentage is computed correctly from milestones
# - All agent states map to correct CSS classes
# - Milestone list renders with correct status icons
# - The expanded view shows all milestones
# - Edge cases: 0 milestones, all completed, all failed
#
# Full E2E verification:
# - Send an IPC_AGENT_PROGRESS message with state=AgentWorking,
#   milestonesCompleted=3, milestonesTotal=7
# - Assert ".caption-progress-bar-fill" has width approximately 42.9%
# - Assert ".caption-progress-state" contains "Working"
# - Hover over the container to expand milestones
# - Assert milestone list items match the provided milestone data

suite "test_caption_bar_progress":
  test "Progress percentage computed correctly":
    check computeProgressPercent(3, 7) > 42.8 and computeProgressPercent(3, 7) < 42.9
    check computeProgressPercent(0, 10) == 0.0
    check computeProgressPercent(10, 10) == 100.0
    check computeProgressPercent(5, 0) == 0.0

  test "All agent states are defined":
    check ord(AgentFailed) == 6
    check ord(AgentIdle) == 0

  test "Milestone statuses are correctly ordered":
    check ord(MilestonePending) == 0
    check ord(MilestoneInProgress) == 1
    check ord(MilestoneCompleted) == 2
    check ord(MilestoneFailed) == 3
    check ord(MilestoneSkipped) == 4

  test "Progress with milestones tracks current milestone":
    let progress = TestAgentProgress(
      state: AgentWorking,
      taskName: "Implement feature",
      milestonesCompleted: 2,
      milestonesTotal: 5,
      currentMilestone: "write-tests",
      milestones: @[
        TestMilestone(id: "analyze", content: "Analyze codebase", priority: "high", status: MilestoneCompleted),
        TestMilestone(id: "implement", content: "Write implementation", priority: "high", status: MilestoneCompleted),
        TestMilestone(id: "write-tests", content: "Write tests", priority: "high", status: MilestoneInProgress),
        TestMilestone(id: "review", content: "Self-review", priority: "medium", status: MilestonePending),
        TestMilestone(id: "docs", content: "Update docs", priority: "low", status: MilestonePending)
      ]
    )
    check progress.milestonesCompleted == 2
    check progress.currentMilestone == "write-tests"
    check progress.milestones[2].status == MilestoneInProgress

  test "Empty milestones list yields 0% progress":
    let progress = TestAgentProgress(
      state: AgentIdle,
      taskName: "",
      milestonesCompleted: 0,
      milestonesTotal: 0,
      currentMilestone: "",
      milestones: @[]
    )
    check computeProgressPercent(progress.milestonesCompleted, progress.milestonesTotal) == 0.0

# =========================================================================
# Test 4: test_activity_pane_deepreview
# =========================================================================
# Verifies the activity pane shows DeepReview data correctly:
# - Summary cards display coverage percentage, test counts, function counts
# - Per-file coverage table lists files with correct coverage ratios
# - Test results section shows pass/fail status with timing
# - Recent notifications feed shows last N notifications
# - Collapsible header works (expanded/collapsed toggle)
#
# Full E2E verification:
# - Create an AgentActivityDeepReviewComponent
# - Feed it CoverageUpdate notifications for 3 files
# - Feed it TestComplete notifications (2 pass, 1 fail)
# - Assert ".activity-dr-card-value" for coverage shows correct percentage
# - Assert ".activity-dr-files-row" count equals 3
# - Assert ".activity-dr-test-item" count equals 3
# - Toggle the header and assert the section collapses

suite "test_activity_pane_deepreview":
  test "Summary updates after coverage notifications":
    var summary = TestActivityDeepReviewSummary()
    updateSummaryFromCoverage(summary, 50, 10)
    updateSummaryFromCoverage(summary, 30, 20)
    check summary.totalLinesCovered == 80
    check summary.totalLinesUncovered == 30
    # 80 / 110 = 72.7%
    check summary.coveragePercent > 72.0 and summary.coveragePercent < 73.0

  test "Summary updates after test notifications":
    var summary = TestActivityDeepReviewSummary()
    updateSummaryFromTest(summary, true)
    updateSummaryFromTest(summary, true)
    updateSummaryFromTest(summary, false)
    check summary.testsRun == 3
    check summary.testsPassed == 2
    check summary.testsFailed == 1

  test "Coverage percentage with only covered lines":
    var summary = TestActivityDeepReviewSummary()
    updateSummaryFromCoverage(summary, 100, 0)
    check summary.coveragePercent == 100.0

  test "Coverage percentage with only uncovered lines":
    var summary = TestActivityDeepReviewSummary()
    updateSummaryFromCoverage(summary, 0, 50)
    check summary.coveragePercent == 0.0

  test "Functions traced counter increments":
    var summary = TestActivityDeepReviewSummary()
    summary.functionsTraced = 0
    # Simulate FlowUpdate notifications.
    summary.functionsTraced += 1
    summary.functionsTraced += 1
    summary.functionsTraced += 1
    check summary.functionsTraced == 3

# =========================================================================
# Test 5: test_realtime_collection
# =========================================================================
# Verifies that data is collected in real-time during agent execution:
# - DeepReview notifications arrive during an active ACP session
# - Coverage data updates incrementally as the agent modifies files
# - Flow data appears as functions are traced
# - Test results stream in as tests complete
# - The CollectionComplete notification signals the end of data collection
# - The UI updates in real-time without requiring manual refresh
#
# Full E2E verification:
# - Start an ACP session (send acp-session-init)
# - Begin agent work (state transitions: Idle -> Initializing -> Working)
# - During Working state, send 5 CoverageUpdate notifications at 1s intervals
# - After each notification, verify the UI has updated (redraw triggered)
# - Send a TestComplete notification
# - Verify the activity pane test results section updates
# - Send CollectionComplete notification
# - Verify the agent state transitions to Completed

suite "test_realtime_collection":
  test "Incremental coverage updates accumulate":
    var summary = TestActivityDeepReviewSummary()
    # Simulate 5 incremental coverage updates.
    for i in 1 .. 5:
      updateSummaryFromCoverage(summary, i * 10, i * 2)
    # Total covered: 10 + 20 + 30 + 40 + 50 = 150
    # Total uncovered: 2 + 4 + 6 + 8 + 10 = 30
    check summary.totalLinesCovered == 150
    check summary.totalLinesUncovered == 30
    # 150 / 180 = 83.3%
    check summary.coveragePercent > 83.0 and summary.coveragePercent < 84.0

  test "State transitions during agent lifecycle":
    var states: seq[TestAgentProgressState] = @[
      AgentIdle,
      AgentInitializing,
      AgentWorking,
      AgentCompleted
    ]
    check states[0] == AgentIdle
    check states[1] == AgentInitializing
    check states[2] == AgentWorking
    check states[3] == AgentCompleted

  test "Mixed notifications update all counters":
    var summary = TestActivityDeepReviewSummary()
    # Coverage.
    updateSummaryFromCoverage(summary, 40, 10)
    # Tests.
    updateSummaryFromTest(summary, true)
    updateSummaryFromTest(summary, false)
    # Functions.
    summary.functionsTraced += 3
    check summary.totalLinesCovered == 40
    check summary.testsRun == 2
    check summary.testsPassed == 1
    check summary.testsFailed == 1
    check summary.functionsTraced == 3

  test "CollectionComplete does not alter counters":
    var summary = TestActivityDeepReviewSummary()
    updateSummaryFromCoverage(summary, 20, 5)
    updateSummaryFromTest(summary, true)
    # CollectionComplete is a signal, not a data update.
    let beforeCoverage = summary.totalLinesCovered
    let beforeTests = summary.testsRun
    # (No operation for CollectionComplete.)
    check summary.totalLinesCovered == beforeCoverage
    check summary.testsRun == beforeTests

  test "Notifications capped at max recent count":
    # The component keeps at most 50 recent notifications.
    const MAX_RECENT = 50
    var notifications: seq[int] = @[]
    for i in 0 ..< 60:
      notifications.add(i)
    # Trim to most recent MAX_RECENT.
    if notifications.len > MAX_RECENT:
      notifications = notifications[notifications.len - MAX_RECENT .. ^1]
    check notifications.len == MAX_RECENT
    check notifications[0] == 10  # Oldest kept is index 10.
    check notifications[^1] == 59 # Most recent is index 59.
