## test_agent_activity_deepreview_vm.nim
##
## Unit tests for ``AgentActivityDeepReviewVM`` — the ViewModel for the
## per-session collapsible Agent Activity DeepReview pane.
##
## Verifies:
## - Initial-state defaults (coverage / test summary signals, file
##   coverage / notification seqs, isExpanded toggle, derived
##   ``coveragePercent`` / ``hasFailures`` / ``notificationCount``
##   memos).
## - ``setCoverageSummary`` / ``setTestResults`` / ``setFileCoverage``
##   bulk-replace semantics + the matching memo updates.
## - ``appendNotification`` append + trim-to-``MAX_NOTIFICATIONS``
##   behaviour so the feed stays bounded across long-running sessions.
## - ``clearNotifications`` drops every row but leaves the coverage /
##   test signals untouched (parity with the legacy ``handleNotification``
##   surface).
## - ``toggleExpanded`` / ``setExpanded`` (idempotent re-set is a
##   no-op so subscribers do not refire pointlessly).
##
## Co-located per the Test-Co-Location-Convention so the panel's
## ViewModel tests live alongside the panel module's surface area in
## the gui-tests tree.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/agent-activity-deepreview/agent_activity_deepreview_vm_test.nim

import std/unittest
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/agent_activity_deepreview_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeFile(path: string;
              covered: int = 0;
              total: int = 0;
              hasFlow: bool = false): AgentDeepReviewFileCoverage =
  ## Test fixture builder for ``AgentDeepReviewFileCoverage`` rows.
  ## Defaults to a zero-coverage entry so each test can override only
  ## the fields it cares about.
  AgentDeepReviewFileCoverage(
    path: path,
    coveredLines: covered,
    totalLines: total,
    hasFlow: hasFlow,
  )

proc makeNotif(label: string;
               kind: AgentDeepReviewNotificationKind = adrnkCoverageUpdate;
               passed: bool = false): AgentDeepReviewNotification =
  ## Test fixture builder for ``AgentDeepReviewNotification`` rows.
  ## Mirrors the equivalent helper in
  ## ``isonim_views_test.nim::makeAdrNotif`` so the same shape works
  ## for both the headless view tests and the VM-only tests here.
  AgentDeepReviewNotification(label: label, kind: kind, passed: passed)

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "AgentActivityDeepReviewVM initial state":

  test "every signal defaults to its empty / closed value":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      check not vm.isExpanded.val
      check vm.fileCoverage.val.len == 0
      check vm.notifications.val.len == 0

      let summary = vm.coverageSummary.val
      check summary.totalLinesCovered == 0
      check summary.totalLinesUncovered == 0
      check summary.coveragePercent == 0.0
      check summary.functionsTraced == 0

      let results = vm.testResults.val
      check results.testsRun == 0
      check results.testsPassed == 0
      check results.testsFailed == 0
      check results.totalDurationMs == 0

      dispose()

  test "derived memos report the empty branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      check vm.coveragePercent.val == 0.0
      check not vm.hasFailures.val
      check vm.notificationCount.val == 0

      dispose()

  test "store reference is preserved":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      # The VM holds the same store ref the factory was given.
      # Behavioural sanity check — the store is the one constructed
      # via ``makeStoreWithMock``; ``cast[pointer]`` does not survive
      # the JS backend's emit and crashes node.
      check not vm.store.isNil
      check vm.store == store

      dispose()

# ---------------------------------------------------------------------------
# setCoverageSummary / setTestResults / setFileCoverage
# ---------------------------------------------------------------------------

suite "AgentActivityDeepReviewVM coverage / tests / files setters":

  test "setCoverageSummary bulk-replaces the value + memo updates":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
        totalLinesCovered: 80,
        totalLinesUncovered: 20,
        coveragePercent: 80.0,
        functionsTraced: 4,
      ))
      check vm.coverageSummary.val.totalLinesCovered == 80
      check vm.coverageSummary.val.totalLinesUncovered == 20
      check vm.coverageSummary.val.coveragePercent == 80.0
      check vm.coverageSummary.val.functionsTraced == 4
      check vm.coveragePercent.val == 80.0

      # Re-set with a different percentage — the memo flips.
      vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
        coveragePercent: 33.3,
      ))
      check vm.coveragePercent.val == 33.3

      dispose()

  test "setTestResults bulk-replaces + flips hasFailures memo":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      vm.setTestResults(AgentDeepReviewTestResults(
        testsRun: 5, testsPassed: 5, testsFailed: 0,
        totalDurationMs: 120,
      ))
      check vm.testResults.val.testsRun == 5
      check vm.testResults.val.testsPassed == 5
      check vm.testResults.val.testsFailed == 0
      check vm.testResults.val.totalDurationMs == 120
      check not vm.hasFailures.val

      vm.setTestResults(AgentDeepReviewTestResults(
        testsRun: 7, testsPassed: 5, testsFailed: 2,
      ))
      check vm.testResults.val.testsFailed == 2
      check vm.hasFailures.val

      dispose()

  test "setFileCoverage replaces the per-file table wholesale":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      vm.setFileCoverage([
        makeFile("/repo/a.nim", covered = 1, total = 2),
        makeFile("/repo/b.nim", covered = 4, total = 4, hasFlow = true),
      ])
      check vm.fileCoverage.val.len == 2
      check vm.fileCoverage.val[0].path == "/repo/a.nim"
      check vm.fileCoverage.val[1].hasFlow

      vm.setFileCoverage([makeFile("/repo/c.nim")])
      check vm.fileCoverage.val.len == 1
      check vm.fileCoverage.val[0].path == "/repo/c.nim"

      vm.setFileCoverage([])
      check vm.fileCoverage.val.len == 0

      dispose()

# ---------------------------------------------------------------------------
# appendNotification / clearNotifications
# ---------------------------------------------------------------------------

suite "AgentActivityDeepReviewVM notifications feed":

  test "appendNotification grows the seq + bumps notificationCount":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      vm.appendNotification(makeNotif("first"))
      check vm.notifications.val.len == 1
      check vm.notificationCount.val == 1

      vm.appendNotification(makeNotif("second", kind = adrnkFlowTraceUpdate))
      check vm.notifications.val.len == 2
      check vm.notificationCount.val == 2
      check vm.notifications.val[1].kind == adrnkFlowTraceUpdate

      dispose()

  test "appendNotification trims to MAX_NOTIFICATIONS":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      # Push enough rows to overflow the cap.
      for i in 0 ..< (MAX_NOTIFICATIONS + 12):
        vm.appendNotification(makeNotif("n" & $i))

      check vm.notifications.val.len == MAX_NOTIFICATIONS
      check vm.notificationCount.val == MAX_NOTIFICATIONS
      # The trimmed seq retains the MOST RECENT rows so the first
      # entry must be ``n12`` (oldest 12 rows discarded).
      check vm.notifications.val[0].label == "n12"
      check vm.notifications.val[^1].label ==
        "n" & $(MAX_NOTIFICATIONS + 11)

      dispose()

  test "clearNotifications drops the feed but keeps coverage / tests":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
        totalLinesCovered: 9, totalLinesUncovered: 1,
        coveragePercent: 90.0,
      ))
      vm.setTestResults(AgentDeepReviewTestResults(
        testsRun: 3, testsPassed: 3, testsFailed: 0))
      vm.setFileCoverage([makeFile("/a.nim", 1, 1)])
      vm.appendNotification(makeNotif("alpha"))
      vm.appendNotification(makeNotif("beta"))
      check vm.notificationCount.val == 2

      vm.clearNotifications()

      check vm.notifications.val.len == 0
      check vm.notificationCount.val == 0
      # Coverage / tests / files are untouched.
      check vm.coverageSummary.val.coveragePercent == 90.0
      check vm.testResults.val.testsRun == 3
      check vm.fileCoverage.val.len == 1

      dispose()

# ---------------------------------------------------------------------------
# isExpanded toggle
# ---------------------------------------------------------------------------

suite "AgentActivityDeepReviewVM isExpanded":

  test "toggleExpanded flips the bool":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      check not vm.isExpanded.val

      vm.toggleExpanded()
      check vm.isExpanded.val

      vm.toggleExpanded()
      check not vm.isExpanded.val

      dispose()

  test "setExpanded forces the value":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      vm.setExpanded(true)
      check vm.isExpanded.val

      vm.setExpanded(false)
      check not vm.isExpanded.val

      # Re-setting the same value is a no-op (subscribers do not
      # refire pointlessly).  Behavioural check — the val stays the
      # same.
      vm.setExpanded(false)
      check not vm.isExpanded.val

      vm.setExpanded(true)
      vm.setExpanded(true)
      check vm.isExpanded.val

      dispose()
