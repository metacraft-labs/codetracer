## Agent Activity DeepReview pane for the CodeTracer GUI (M9).
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_agent_activity_deepreview_view.nim``)
## that mounts directly into the GoldenLayout container.  The legacy
## ``AgentActivityDeepReviewComponent`` retains its module-level helpers
## (``handleNotification`` / ``onActivityDeepReviewNotification``) so
## the existing wiring (the ``IPC_DEEPREVIEW_NOTIFICATION`` IPC channel,
## the per-session dispatch fan-out) keeps feeding the panel; every
## state mutation now mirrors into the parallel
## ``AgentActivityDeepReviewVM`` via
## ``syncLegacyAgentActivityDeepReviewIntoVM`` so the IsoNim view is
## the single source of truth for the panel's DOM.
##
## Lifecycle:
## 1. ``utils.nim::makeAgentActivityDeepReviewComponent`` constructs the
##    legacy ``AgentActivityDeepReviewComponent`` and registers it under
##    ``Content.AgentActivityDeepReview`` (one instance per panel id).
## 2. ``layout.nim`` registers the GL container, then detects
##    ``Content.AgentActivityDeepReview`` is in ``isIsoNimComponent``
##    and calls ``tryMountIsoNimAgentActivityDeepReviewPanel`` instead
##    of invoking Karax.
## 3. The mount helper appends the IsoNim panel inside the
##    ``agentActivityDeepReviewComponent-{id}`` container and the
##    reactive effects keep the DOM in sync with the VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via
##    ``initAgentActivityDeepReviewVMWithStore`` so the panel uses the
##    production ``ReplayDataStore``.
##
## Reference: codetracer-specs/DeepReview/Agentic-Coding-Integration.md
##
## NOTE: rich per-row affordances (per-file coverage bar with the
## `coverageBarClass` / `coverageBarWidth` graphics, per-notification
## colour pills with the legacy `notificationCssClass` map, and the
## "Functions" summary card) remain a follow-up.  The IsoNim view
## renders one row per file / notification with stable per-kind /
## per-pass-fail modifiers so the existing
## ``static/styles/components/activity-dr.styl`` rules keep targeting
## the same selectors.

import
  ui_imports, ../utils, ../communication,
  std/[strformat, jsconsole]

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  AgentDeepReviewCoverageSummary, AgentDeepReviewTestResults,
  AgentDeepReviewFileCoverage, AgentDeepReviewNotification,
  AgentDeepReviewNotificationKind,
  adrnkCoverageUpdate, adrnkFlowTraceUpdate, adrnkTestComplete,
  adrnkCollectionComplete
from ../viewmodel/viewmodels/agent_activity_deepreview_vm import
  AgentActivityDeepReviewVM, createAgentActivityDeepReviewVM,
  setCoverageSummary, setTestResults, setFileCoverage,
  appendNotification, clearNotifications, setExpanded
when defined(js):
  from isonim/web/dom_api as isonim_dom_api import nil
  from ../viewmodel/views/isonim_agent_activity_deepreview_view import
    mountIsoNimAgentActivityDeepReviewPanel


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fileBasename(path: cstring): cstring =
  ## Extract the filename from a path for display.  Preserved as the
  ## legacy notification-label helper still uses it.
  let s = $path
  let idx = s.rfind('/')
  if idx >= 0:
    return cstring(s[idx + 1 .. ^1])
  return path

proc notificationLabel(notif: DeepReviewNotification): cstring =
  ## Human-readable label for a notification entry in the recent list.
  ## Materialised into the VM-side ``AgentDeepReviewNotification.label``
  ## so the IsoNim view can render the row body verbatim without
  ## re-importing the legacy formatting code.
  case notif.kind
  of CoverageUpdate:
    result = cstring(fmt"Coverage: {notif.filePath}")
  of FlowTraceUpdate:
    result = cstring(fmt"Flow: {notif.functionKey} (exec {notif.executionIndex})")
  of TestComplete:
    let status = if notif.passed: "PASS" else: "FAIL"
    result = cstring(fmt"Test {status}: {notif.testName} ({notif.durationMs}ms)")
  of CollectionComplete:
    result = cstring(fmt"Collection complete: {notif.totalFiles} files, {notif.totalFunctions} functions, {notif.totalTests} tests")

# ---------------------------------------------------------------------------
# Notification handling
# ---------------------------------------------------------------------------

proc handleNotification*(self: AgentActivityDeepReviewComponent, notification: DeepReviewNotification) =
  ## Process an incoming DeepReview notification and update component
  ## state.  The legacy ``self.*`` fields are kept up-to-date for any
  ## historical caller; the parallel ``AgentActivityDeepReviewVM`` is
  ## also mirrored via ``syncLegacyAgentActivityDeepReviewIntoVM``
  ## below so the IsoNim view repaints in lock-step.
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

  of FlowTraceUpdate:
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
# Module-level VM/store/component slots so the IsoNim mount and any
# legacy bridge handlers can find each other across calls.  Mirrors
# the pattern used by trace_log / scratchpad / filesystem / command.
# ---------------------------------------------------------------------------

var agentActivityDeepReviewVMInstance*: AgentActivityDeepReviewVM
var agentActivityDeepReviewVMStore: ReplayDataStore
var agentActivityDeepReviewComponentRef: AgentActivityDeepReviewComponent
# Track which AgentActivityDeepReviewComponent ids have already
# mounted their IsoNim view.  The GL container is keyed by
# ``agentActivityDeepReviewComponent-{id}`` so each open panel
# instance gets its own mount.
var isoNimAgentActivityDeepReviewMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimAgentActivityDeepReviewPanel*()

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  The legacy
  ## record carries cstring everywhere; an unconditional ``$`` would
  ## throw inside ``cstrToNimstr`` for null cstrings.
  if s.isNil:
    ""
  else:
    $s

proc legacyKindToVm(kind: DeepReviewNotificationKind):
    AgentDeepReviewNotificationKind =
  ## Map the legacy ``DeepReviewNotificationKind`` enum to its
  ## VM-side counterpart.  One-to-one mapping; both enums carry the
  ## same four variants in the same order.
  case kind
  of CoverageUpdate: adrnkCoverageUpdate
  of FlowTraceUpdate: adrnkFlowTraceUpdate
  of TestComplete: adrnkTestComplete
  of CollectionComplete: adrnkCollectionComplete

proc legacySummaryToVm(summary: ActivityDeepReviewSummary):
    AgentDeepReviewCoverageSummary =
  ## Translate the legacy ``ActivityDeepReviewSummary`` into the
  ## flat VM-side ``AgentDeepReviewCoverageSummary`` value.  Only
  ## the coverage / functions-traced fields are mirrored — the test
  ## roll-up lives in a separate VM signal so the IsoNim view can
  ## subscribe to either independently.
  result = AgentDeepReviewCoverageSummary(
    totalLinesCovered: summary.totalLinesCovered,
    totalLinesUncovered: summary.totalLinesUncovered,
    coveragePercent: summary.coveragePercent,
    functionsTraced: summary.functionsTraced,
  )

proc legacyTestResultsToVm(summary: ActivityDeepReviewSummary):
    AgentDeepReviewTestResults =
  ## Pull the test-results triplet out of the legacy summary record.
  ## ``totalDurationMs`` is currently advisory — the legacy summary
  ## does not carry an aggregate duration so the bridge sets it to
  ## zero; the IsoNim view paints it as ``"0/N"`` until a
  ## per-test-duration roll-up is wired up.
  result = AgentDeepReviewTestResults(
    testsRun: summary.testsRun,
    testsPassed: summary.testsPassed,
    testsFailed: summary.testsFailed,
    totalDurationMs: 0,
  )

proc legacyFileEntryToVm(entry: ActivityFileEntry):
    AgentDeepReviewFileCoverage =
  ## Translate one legacy ``ActivityFileEntry`` into a flat
  ## ``AgentDeepReviewFileCoverage`` value.
  result = AgentDeepReviewFileCoverage(
    path: safeStr(entry.path),
    coveredLines: entry.coveredLines,
    totalLines: entry.totalLines,
    hasFlow: entry.hasFlow,
  )

proc legacyFileEntriesToVm(entries: seq[ActivityFileEntry]):
    seq[AgentDeepReviewFileCoverage] =
  ## Bulk translation helper — invoked from
  ## ``syncLegacyAgentActivityDeepReviewIntoVM`` so the VM signal is
  ## updated in one go.
  result = @[]
  for entry in entries:
    result.add(legacyFileEntryToVm(entry))

proc legacyNotifToVm(notif: DeepReviewNotification):
    AgentDeepReviewNotification =
  ## Translate one legacy ``DeepReviewNotification`` ref into a
  ## flat ``AgentDeepReviewNotification`` value.  ``label`` is
  ## materialised here through ``notificationLabel`` so the IsoNim
  ## view can render the row body verbatim without re-importing
  ## the legacy formatting code.  ``passed`` is preserved only for
  ## ``TestComplete`` rows so the per-row pass / fail tint matches
  ## the legacy view; other variants leave it false.
  let label = $notificationLabel(notif)
  let passed = (notif.kind == TestComplete) and notif.passed
  result = AgentDeepReviewNotification(
    label: label,
    kind: legacyKindToVm(notif.kind),
    passed: passed,
  )

proc legacyNotifsToVm(notifs: seq[DeepReviewNotification]):
    seq[AgentDeepReviewNotification] =
  ## Bulk translation helper for the recent-notifications feed.
  result = @[]
  for n in notifs:
    result.add(legacyNotifToVm(n))

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyAgentActivityDeepReviewIntoVM*(
    self: AgentActivityDeepReviewComponent) =
  ## Bulk-replay the legacy DeepReview state into the VM.  Called
  ## from layout / event-bus boilerplate so the panel reflects
  ## whatever ``handleNotification`` already accumulated.  Defensive
  ## nil-checks so a partially-initialised component can call
  ## through this without exploding.
  if agentActivityDeepReviewVMInstance.isNil or self.isNil:
    return
  agentActivityDeepReviewVMInstance.setCoverageSummary(
    legacySummaryToVm(self.drSummary))
  agentActivityDeepReviewVMInstance.setTestResults(
    legacyTestResultsToVm(self.drSummary))
  agentActivityDeepReviewVMInstance.setFileCoverage(
    legacyFileEntriesToVm(self.fileEntries))
  # Replace the notifications signal in one shot — clear and re-append
  # so the seq stays bounded by ``MAX_NOTIFICATIONS`` (the VM helper
  # trims after each ``appendNotification``).
  agentActivityDeepReviewVMInstance.clearNotifications()
  for n in self.recentNotifications:
    agentActivityDeepReviewVMInstance.appendNotification(legacyNotifToVm(n))
  agentActivityDeepReviewVMInstance.setExpanded(self.expanded)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initAgentActivityDeepReviewVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel
  ## ``AgentActivityDeepReviewVM`` using an externally-provided
  ## ``ReplayDataStore`` (typically the shared store from
  ## ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance
  ## already exists (created by ``initAgentActivityDeepReviewVM``
  ## before the real backend was available) it is replaced so the
  ## panel uses the real backend.
  if agentActivityDeepReviewVMInstance != nil:
    clog "AgentActivityDeepReviewVM: replacing existing instance with shared-store version"
    isoNimAgentActivityDeepReviewMountedIds = JsAssoc[int, bool]{}
  agentActivityDeepReviewVMStore = store
  agentActivityDeepReviewVMInstance = createAgentActivityDeepReviewVM(store)
  clog "AgentActivityDeepReviewVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimAgentActivityDeepReviewPanel()

proc initAgentActivityDeepReviewVM*() =
  ## Lazy fallback used when no shared store has been provided yet.
  ## Same shape as ``initFilesystemVM`` / ``initCommandPaletteVM`` —
  ## a stub backend so the panel can still render before
  ## ``configureMiddleware`` runs.
  if agentActivityDeepReviewVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  agentActivityDeepReviewVMStore = createReplayDataStore(stubBackend)
  agentActivityDeepReviewVMInstance =
    createAgentActivityDeepReviewVM(agentActivityDeepReviewVMStore)
  clog "AgentActivityDeepReviewVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimAgentActivityDeepReviewPanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimAgentActivityDeepReviewPanel*() =
    ## Mount the IsoNim Agent Activity DeepReview panel view into
    ## the GoldenLayout-managed container.  The container's id is
    ## ``agentActivityDeepReviewComponent-{id}`` — each open panel
    ## instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container
    ## appears (capped at 200 attempts, ~2 s) since GoldenLayout
    ## creates the host slightly after the layout state changes
    ## (mirrors ``tryMountIsoNimFilesystemPanel`` /
    ## ``tryMountIsoNimCommandPalettePanel``).
    if agentActivityDeepReviewVMInstance.isNil:
      return
    if agentActivityDeepReviewComponentRef.isNil:
      return
    let componentId = agentActivityDeepReviewComponentRef.id
    if isoNimAgentActivityDeepReviewMountedIds.hasKey(componentId):
      return

    let key = cstring("agentActivityDeepReviewComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimAgentActivityDeepReviewMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = isonim_dom_api.getElementById(
        isonim_dom_api.document, key)
      if isonim_dom_api.isNodeNil(isonim_dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimAgentActivityDeepReviewPanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = isonim_dom_api.Node(container)
      while not isonim_dom_api.isNodeNil(containerNode.firstChild):
        discard isonim_dom_api.removeChild(
          containerNode, containerNode.firstChild)

      isoNimAgentActivityDeepReviewMountedIds[componentId] = true
      try:
        mountIsoNimAgentActivityDeepReviewPanel(
          container, agentActivityDeepReviewVMInstance)
      except:
        cerror "tryMountIsoNimAgentActivityDeepReviewPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync any state the legacy component already carries so
      # the freshly-mounted view reflects the latest data.
      if not agentActivityDeepReviewComponentRef.isNil:
        syncLegacyAgentActivityDeepReviewIntoVM(
          agentActivityDeepReviewComponentRef)

    doMount()
else:
  proc tryMountIsoNimAgentActivityDeepReviewPanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initAgentActivityDeepReviewVM*``) compile on
    ## every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  The base ``Component.render()`` returns a valid empty
# VNode for any generic callers.
# ---------------------------------------------------------------------------

method register*(self: AgentActivityDeepReviewComponent,
                 api: MediatorWithSubscribers) =
  ## Register the component with the mediator event system and bring
  ## up the IsoNim ``AgentActivityDeepReviewVM`` lazily so the mount
  ## procedure can find it; the shared-store version is installed by
  ## ``configureMiddleware`` if the ViewModel layer is enabled.
  self.api = api
  initAgentActivityDeepReviewVM()
  if agentActivityDeepReviewComponentRef.isNil:
    agentActivityDeepReviewComponentRef = self
    tryMountIsoNimAgentActivityDeepReviewPanel()

# ---------------------------------------------------------------------------
# IPC handler
# ---------------------------------------------------------------------------

proc onActivityDeepReviewNotification*(sender: js, response: JsObject) {.async.} =
  ## IPC handler for DeepReview notifications targeted at the activity pane.
  ## Dispatches to the matching ``AgentActivityDeepReviewComponent`` by
  ## session id.  After updating the legacy component state via
  ## ``handleNotification``, mirrors the resulting state into the
  ## parallel ``AgentActivityDeepReviewVM`` via
  ## ``syncLegacyAgentActivityDeepReviewIntoVM`` so the IsoNim view
  ## repaints.
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
          kind: FlowTraceUpdate,
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
      # Mirror the just-updated legacy state into the IsoNim VM so
      # the live panel repaints in lock-step.
      syncLegacyAgentActivityDeepReviewIntoVM(activityDr)
      break
