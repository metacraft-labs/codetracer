## Agent Activity DeepReview pane for the CodeTracer GUI (M9).
##
## Enhances the agent activity view with an integrated DeepReview data
## panel that displays alongside the agent conversation. Shows:
##
## - Coverage summary (total covered/uncovered lines, percentage)
## - Test results (passed/failed/total with timing)
## - Per-file coverage table
## - Recent DeepReview notifications (coverage updates, flow traces)
##
## This component is designed to be rendered as a collapsible section
## within the existing ``AgentActivityComponent`` layout. It receives
## data from the same ACP session and is updated in real-time as the
## agent works.
##
## The component subscribes to ``IPC_DEEPREVIEW_NOTIFICATION`` messages
## and maintains its own state independently from the workspace view,
## so the user can see DeepReview metrics without switching workspaces.
##
## Reference: codetracer-specs/DeepReview/Agentic-Coding-Integration.md

import
  ui_imports, ../utils,
  std/[strformat, jsconsole]

from dom import Node, document, getElementById

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc coverageBarWidth(entry: ActivityFileEntry): cstring =
  ## Compute the width percentage for a coverage bar based on covered/total lines.
  if entry.totalLines <= 0:
    return cstring"0%"
  let pct = (entry.coveredLines.float / entry.totalLines.float) * 100.0
  result = cstring(fmt"{pct:.1f}%")

proc coverageBarClass(entry: ActivityFileEntry): cstring =
  ## Return a CSS class based on coverage level for colour coding.
  if entry.totalLines <= 0:
    return cstring"coverage-bar-none"
  let pct = (entry.coveredLines.float / entry.totalLines.float) * 100.0
  if pct >= 80.0:
    return cstring"coverage-bar-good"
  elif pct >= 50.0:
    return cstring"coverage-bar-moderate"
  else:
    return cstring"coverage-bar-low"

proc fileBasename(path: cstring): cstring =
  ## Extract the filename from a path for display.
  let s = $path
  let idx = s.rfind('/')
  if idx >= 0:
    return cstring(s[idx + 1 .. ^1])
  return path

proc notificationLabel(notif: DeepReviewNotification): cstring =
  ## Human-readable label for a notification entry in the recent list.
  case notif.kind
  of CoverageUpdate:
    result = cstring(fmt"Coverage: {notif.filePath}")
  of FlowUpdate:
    result = cstring(fmt"Flow: {notif.functionKey} (exec {notif.executionIndex})")
  of TestComplete:
    let status = if notif.passed: "PASS" else: "FAIL"
    result = cstring(fmt"Test {status}: {notif.testName} ({notif.durationMs}ms)")
  of CollectionComplete:
    result = cstring(fmt"Collection complete: {notif.totalFiles} files, {notif.totalFunctions} functions, {notif.totalTests} tests")

proc notificationCssClass(notif: DeepReviewNotification): cstring =
  ## CSS class for notification colour coding.
  case notif.kind
  of CoverageUpdate: cstring"activity-dr-notif-coverage"
  of FlowUpdate: cstring"activity-dr-notif-flow"
  of TestComplete:
    if notif.passed: cstring"activity-dr-notif-test-pass"
    else: cstring"activity-dr-notif-test-fail"
  of CollectionComplete: cstring"activity-dr-notif-complete"

# ---------------------------------------------------------------------------
# Notification handling
# ---------------------------------------------------------------------------

proc handleNotification*(self: AgentActivityDeepReviewComponent, notification: DeepReviewNotification) =
  ## Process an incoming DeepReview notification and update component state.
  self.recentNotifications.add(notification)

  # Keep only the most recent 50 notifications to avoid unbounded growth.
  const MAX_RECENT = 50
  if self.recentNotifications.len > MAX_RECENT:
    self.recentNotifications = self.recentNotifications[self.recentNotifications.len - MAX_RECENT .. ^1]

  case notification.kind
  of CoverageUpdate:
    # Update or add the file entry.
    var found = false
    for i in 0 ..< self.fileEntries.len:
      if self.fileEntries[i].path == notification.filePath:
        self.fileEntries[i].coveredLines = notification.linesCovered.len
        self.fileEntries[i].totalLines =
          notification.linesCovered.len + notification.linesUncovered.len
        found = true
        break
    if not found:
      self.fileEntries.add(ActivityFileEntry(
        path: notification.filePath,
        coveredLines: notification.linesCovered.len,
        totalLines: notification.linesCovered.len + notification.linesUncovered.len,
        hasFlow: false
      ))

    # Recompute summary.
    var totalCovered = 0
    var totalUncovered = 0
    for entry in self.fileEntries:
      totalCovered += entry.coveredLines
      totalUncovered += (entry.totalLines - entry.coveredLines)
    self.drSummary.totalLinesCovered = totalCovered
    self.drSummary.totalLinesUncovered = totalUncovered
    let totalLines = totalCovered + totalUncovered
    self.drSummary.coveragePercent =
      if totalLines > 0: (totalCovered.float / totalLines.float) * 100.0
      else: 0.0

  of FlowUpdate:
    for i in 0 ..< self.fileEntries.len:
      if self.fileEntries[i].path == notification.flowFilePath:
        self.fileEntries[i].hasFlow = true
        break
    self.drSummary.functionsTraced += 1

  of TestComplete:
    self.testResults.add(notification)
    self.drSummary.testsRun += 1
    if notification.passed:
      self.drSummary.testsPassed += 1
    else:
      self.drSummary.testsFailed += 1

  of CollectionComplete:
    discard

# ---------------------------------------------------------------------------
# Component lifecycle
# ---------------------------------------------------------------------------

method register*(self: AgentActivityDeepReviewComponent, api: MediatorWithSubscribers) =
  ## Register the component with the mediator event system.
  self.api = api

# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------

proc renderSummaryCards(self: AgentActivityDeepReviewComponent): VNode =
  ## Render the top-level summary cards (coverage, tests, functions).
  let summary = self.drSummary
  let coverageText = fmt"{summary.coveragePercent:.1f}%"

  buildHtml(tdiv(class = "activity-dr-summary")):
    # Coverage card.
    tdiv(class = "activity-dr-card"):
      tdiv(class = "activity-dr-card-label"): text "Coverage"
      tdiv(class = "activity-dr-card-value"): text coverageText
      tdiv(class = "activity-dr-card-detail"):
        text fmt"{summary.totalLinesCovered} covered / {summary.totalLinesUncovered} uncovered"

    # Tests card.
    tdiv(class = "activity-dr-card"):
      tdiv(class = "activity-dr-card-label"): text "Tests"
      tdiv(class = "activity-dr-card-value"):
        text fmt"{summary.testsPassed}/{summary.testsRun}"
      if summary.testsFailed > 0:
        tdiv(class = "activity-dr-card-detail activity-dr-card-warn"):
          text fmt"{summary.testsFailed} failed"
      else:
        tdiv(class = "activity-dr-card-detail"):
          text "all passing"

    # Functions card.
    tdiv(class = "activity-dr-card"):
      tdiv(class = "activity-dr-card-label"): text "Functions"
      tdiv(class = "activity-dr-card-value"):
        text fmt"{summary.functionsTraced}"
      tdiv(class = "activity-dr-card-detail"):
        text "traced"

proc renderFileTable(self: AgentActivityDeepReviewComponent): VNode =
  ## Render the per-file coverage table.
  if self.fileEntries.len == 0:
    return buildHtml(tdiv(class = "activity-dr-files-empty")):
      text "No files with coverage data yet."

  buildHtml(tdiv(class = "activity-dr-files")):
    tdiv(class = "activity-dr-files-header"):
      span(class = "activity-dr-files-col-name"): text "File"
      span(class = "activity-dr-files-col-coverage"): text "Coverage"
      span(class = "activity-dr-files-col-bar"): text ""
      span(class = "activity-dr-files-col-flow"): text "Flow"

    for entry in self.fileEntries:
      let barClass = coverageBarClass(entry)
      tdiv(class = "activity-dr-files-row"):
        span(class = "activity-dr-files-col-name"):
          text fileBasename(entry.path)
        span(class = "activity-dr-files-col-coverage"):
          text cstring(fmt"{entry.coveredLines}/{entry.totalLines}")
        span(class = cstring(fmt"activity-dr-files-col-bar {barClass}")):
          tdiv(class = "activity-dr-coverage-bar"):
            tdiv(
              class = "activity-dr-coverage-bar-fill",
              style = style(StyleAttr.width, coverageBarWidth(entry))
            )
        span(class = "activity-dr-files-col-flow"):
          if entry.hasFlow:
            text "yes"
          else:
            text "--"

proc renderTestResults(self: AgentActivityDeepReviewComponent): VNode =
  ## Render the list of test results.
  if self.testResults.len == 0:
    return buildHtml(tdiv(class = "activity-dr-tests-empty")):
      text "No test results yet."

  buildHtml(tdiv(class = "activity-dr-tests")):
    tdiv(class = "activity-dr-tests-header"):
      text fmt"Test Results ({self.testResults.len})"

    for testNotif in self.testResults:
      let statusClass =
        if testNotif.passed: "activity-dr-test-pass"
        else: "activity-dr-test-fail"
      tdiv(class = cstring(fmt"activity-dr-test-item {statusClass}")):
        span(class = "activity-dr-test-status"):
          text (if testNotif.passed: "PASS" else: "FAIL")
        span(class = "activity-dr-test-name"):
          text $testNotif.testName
        span(class = "activity-dr-test-duration"):
          text fmt"{testNotif.durationMs}ms"

proc renderRecentNotifications(self: AgentActivityDeepReviewComponent): VNode =
  ## Render the recent notifications feed (most recent first).
  if self.recentNotifications.len == 0:
    return buildHtml(tdiv(class = "activity-dr-notifs-empty")):
      text "No recent notifications."

  buildHtml(tdiv(class = "activity-dr-notifs")):
    tdiv(class = "activity-dr-notifs-header"):
      text "Recent Activity"

    # Show most recent 10 notifications in reverse order.
    let startIdx = max(0, self.recentNotifications.len - 10)
    var i = self.recentNotifications.len - 1
    while i >= startIdx:
      let notif = self.recentNotifications[i]
      let notifClass = notificationCssClass(notif)
      tdiv(class = cstring(fmt"activity-dr-notif-item {notifClass}")):
        text notificationLabel(notif)
      i -= 1

# ---------------------------------------------------------------------------
# Main render
# ---------------------------------------------------------------------------

method render*(self: AgentActivityDeepReviewComponent): VNode =
  ## Render the full agent activity DeepReview pane.
  ## This is intended to be embedded as a collapsible section within
  ## the agent activity view.

  result = buildHtml(tdiv(class = "activity-dr-container")):
    # Collapsible header.
    tdiv(
      class = "activity-dr-header",
      onclick = proc(ev: Event, n: VNode) =
        self.expanded = not self.expanded
        redrawAll()
    ):
      let chevron = if self.expanded: "v" else: ">"
      span(class = "activity-dr-chevron"):
        text chevron
      span(class = "activity-dr-header-label"):
        text "DeepReview"
      # Show a compact coverage percentage in the header when collapsed.
      if not self.expanded:
        span(class = "activity-dr-header-badge"):
          text cstring(fmt"{self.drSummary.coveragePercent:.1f}%")

    if self.expanded:
      self.renderSummaryCards()
      self.renderFileTable()
      self.renderTestResults()
      self.renderRecentNotifications()

# ---------------------------------------------------------------------------
# IPC handler
# ---------------------------------------------------------------------------

proc onActivityDeepReviewNotification*(sender: js, response: JsObject) {.async.} =
  ## IPC handler for DeepReview notifications targeted at the activity pane.
  ## Dispatches to the matching ``AgentActivityDeepReviewComponent`` by session id.
  let sessionId =
    if response.hasOwnProperty(cstring"sessionId"):
      response[cstring"sessionId"].to(cstring)
    else:
      cstring""

  if sessionId.len == 0:
    return

  for _, comp in data.ui.componentMapping[Content.AgentActivityDeepReview]:
    let activityDr = AgentActivityDeepReviewComponent(comp)
    if activityDr.sessionId == sessionId:
      # Parse the notification kind.
      let kindStr =
        if response.hasOwnProperty(cstring"kind"):
          response[cstring"kind"].to(cstring)
        else:
          cstring""

      case $kindStr
      of "CoverageUpdate":
        var linesCovered: seq[int] = @[]
        var linesUncovered: seq[int] = @[]
        let notification = DeepReviewNotification(
          sessionId: sessionId,
          kind: CoverageUpdate,
          filePath: response[cstring"filePath"].to(cstring),
          linesCovered: linesCovered,
          linesUncovered: linesUncovered
        )
        activityDr.handleNotification(notification)
      of "FlowUpdate":
        let notification = DeepReviewNotification(
          sessionId: sessionId,
          kind: FlowUpdate,
          flowFilePath: response[cstring"flowFilePath"].to(cstring),
          functionKey: response[cstring"functionKey"].to(cstring),
          executionIndex: response[cstring"executionIndex"].to(int),
          stepCount: response[cstring"stepCount"].to(int)
        )
        activityDr.handleNotification(notification)
      of "TestComplete":
        let notification = DeepReviewNotification(
          sessionId: sessionId,
          kind: TestComplete,
          testName: response[cstring"testName"].to(cstring),
          passed: response[cstring"passed"].to(bool),
          durationMs: response[cstring"durationMs"].to(int),
          traceContextId: response[cstring"traceContextId"].to(cstring)
        )
        activityDr.handleNotification(notification)
      of "CollectionComplete":
        let notification = DeepReviewNotification(
          sessionId: sessionId,
          kind: CollectionComplete,
          totalFiles: response[cstring"totalFiles"].to(int),
          totalFunctions: response[cstring"totalFunctions"].to(int),
          totalTests: response[cstring"totalTests"].to(int)
        )
        activityDr.handleNotification(notification)
      else:
        console.log cstring(fmt"[activity-dr] unknown notification kind: {kindStr}")
      redrawAll()
      break
