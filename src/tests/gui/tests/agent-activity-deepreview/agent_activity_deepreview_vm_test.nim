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

import std/[json, strutils, unittest]
import isonim/core/[signals, computation, owner]
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/agent_activity_deepreview_vm
import viewmodels/review_entry
import viewmodels/vcs_vm

const AgenticSessionFixtureJson =
  staticRead("../agentic-coding/fixtures/agent-session.json")

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

proc agenticSessionFixture(): JsonNode =
  ## Shared GUI fixture used by ``agentic-deepreview.spec.ts``.  Keeping
  ## this smoke pinned to the same JSON catches fixture/schema drift at
  ## the VM layer before the live ACP/Electron tests run.
  parseJson(AgenticSessionFixtureJson)

proc notificationKind(kind: string): AgentDeepReviewNotificationKind =
  case kind
  of "CoverageUpdate": adrnkCoverageUpdate
  of "FlowUpdate", "FlowTraceUpdate": adrnkFlowTraceUpdate
  of "TestComplete": adrnkTestComplete
  of "CollectionComplete": adrnkCollectionComplete
  else: adrnkCollectionComplete

proc notificationLabel(notif: JsonNode): string =
  case notif["kind"].getStr()
  of "CoverageUpdate":
    "Coverage updated: " & notif["filePath"].getStr()
  of "FlowUpdate", "FlowTraceUpdate":
    "Flow traced: " & notif["functionKey"].getStr()
  of "TestComplete":
    let status = if notif["passed"].getBool(): "passed" else: "failed"
    "Test " & status & ": " & notif["testName"].getStr()
  of "CollectionComplete":
    "DeepReview collection complete"
  else:
    "Unknown notification"

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

suite "AgentActivityDeepReviewVM agentic-coding smoke pairing":

  test "agentic fixture notifications populate summary files tests and feed":
    ## Smoke-level companion for agentic-deepreview.spec.ts:
    ## fixture notifications are reduced into the user-visible Activity
    ## DeepReview VM state.  Live ACP IPC dispatch, caption-bar progress,
    ## and Electron layout remain the next-layer integration boundary.
    createRoot proc(dispose: proc()) =
      let fixture = agenticSessionFixture()
      let expected = fixture["expectedSummary"]
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      var totalCovered = 0
      var totalUncovered = 0
      var testsRun = 0
      var testsPassed = 0
      var testsFailed = 0
      var functionsTraced = 0
      var totalDurationMs = 0
      var files: seq[AgentDeepReviewFileCoverage] = @[]

      for notif in fixture["notifications"]:
        case notif["kind"].getStr()
        of "CoverageUpdate":
          let covered = notif["linesCovered"].len
          let uncovered = notif["linesUncovered"].len
          totalCovered += covered
          totalUncovered += uncovered
          files.add(makeFile(
            notif["filePath"].getStr(),
            covered = covered,
            total = covered + uncovered))
        of "FlowUpdate", "FlowTraceUpdate":
          inc functionsTraced
          let flowPath = notif["flowFilePath"].getStr()
          for i in 0 ..< files.len:
            if files[i].path == flowPath:
              files[i].hasFlow = true
        of "TestComplete":
          inc testsRun
          totalDurationMs += notif["durationMs"].getInt()
          if notif["passed"].getBool():
            inc testsPassed
          else:
            inc testsFailed
        else:
          discard

        vm.appendNotification(AgentDeepReviewNotification(
          label: notificationLabel(notif),
          kind: notificationKind(notif["kind"].getStr()),
          passed: notif.hasKey("passed") and notif["passed"].getBool(),
        ))

      vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
        totalLinesCovered: totalCovered,
        totalLinesUncovered: totalUncovered,
        coveragePercent: expected["coveragePercent"].getFloat(),
        functionsTraced: functionsTraced,
      ))
      vm.setTestResults(AgentDeepReviewTestResults(
        testsRun: testsRun,
        testsPassed: testsPassed,
        testsFailed: testsFailed,
        totalDurationMs: totalDurationMs,
      ))
      vm.setFileCoverage(files)
      vm.setExpanded(true)

      check vm.coverageSummary.val.totalLinesCovered ==
        expected["totalLinesCovered"].getInt()
      check vm.coverageSummary.val.totalLinesUncovered ==
        expected["totalLinesUncovered"].getInt()
      check vm.coveragePercent.val == expected["coveragePercent"].getFloat()
      check vm.coverageSummary.val.functionsTraced ==
        expected["functionsTraced"].getInt()
      check vm.testResults.val.testsRun == expected["testsRun"].getInt()
      check vm.testResults.val.testsPassed == expected["testsPassed"].getInt()
      check vm.testResults.val.testsFailed == expected["testsFailed"].getInt()
      check vm.hasFailures.val
      check vm.fileCoverage.val.len == expected["fileCount"].getInt()
      check vm.fileCoverage.val[0].path == "src/feature.rs"
      check vm.fileCoverage.val[0].coveredLines == 15
      check vm.fileCoverage.val[0].totalLines == 20
      check vm.fileCoverage.val[0].hasFlow
      check vm.notificationCount.val == fixture["notifications"].len
      check vm.notifications.val[^1].label ==
        "Test failed: test_validate_input_empty"
      check vm.isExpanded.val

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

# ---------------------------------------------------------------------------
# DR-R3: the Agent Activity panel as DeepReview's third pillar
# ---------------------------------------------------------------------------
#
# `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1: "In DeepReview mode the
# panel gains a DeepReview section showing … Coverage summary … Per-file
# coverage … The section is populated from the same review dataset that drives
# the VCS panel and the editor.  It must not require a live agent session: a
# review launched from the CLI over an exported dataset must populate it too."
#
# The dataset is the same `sample-review.json` the Playwright suite launches
# CodeTracer over and the same fixture `deepreview/deepreview_vm_test.nim`
# drives the VCS side of review entry with, so both halves of §2.1's "two views
# of one selection" are described against one changeset.
#
# The projection below mirrors `reviewCoverageRows` / `deepReviewRows` in
# `src/frontend/ui/vcs.nim`, which walk the JS `DeepReviewData` object and are
# therefore not importable here.

proc drFixtureDirPath(): string {.compileTime.} =
  let p = currentSourcePath()
  var cut = p.rfind('/')
  let backslash = p.rfind('\\')
  if backslash > cut:
    cut = backslash
  p[0 .. cut] & "../deepreview/fixtures/"

const SampleReviewJson = staticRead(drFixtureDirPath() & "sample-review.json")
const EmptyReviewJson = staticRead(drFixtureDirPath() & "empty-review.json")

proc coverageRowsFromFixture(fixture: string):
    seq[AgentDeepReviewFileCoverage] =
  ## Project a DeepReview export's `files[].coverage` into the Agent Activity
  ## pane's per-file coverage rows, the way `vcs.nim`'s `reviewCoverageRows`
  ## does: one row per file in the changeset, `coveredLines` = the lines the
  ## recording executed, `totalLines` = the lines the export carries coverage
  ## for, `hasFlow` = the file has at least one recorded function flow.
  result = @[]
  let data = parseJson(fixture)
  if not data.hasKey("files"):
    return
  for file in data["files"].items:
    var executed = 0
    var covered = 0
    if file.hasKey("coverage"):
      for cov in file["coverage"].items:
        covered += 1
        if cov{"executed"}.getBool(false):
          executed += 1
    result.add(AgentDeepReviewFileCoverage(
      path: file{"path"}.getStr(""),
      coveredLines: executed,
      totalLines: covered,
      hasFlow: file.hasKey("flow") and file["flow"].len > 0,
    ))

proc tracedFunctionsFromFixture(fixture: string): int =
  ## Distinct function keys the export carries a recorded flow for.  Mirrors
  ## `vcs.nim`'s `reviewTracedFunctions`.
  var seen: seq[string] = @[]
  let data = parseJson(fixture)
  if not data.hasKey("files"):
    return 0
  for file in data["files"].items:
    if not file.hasKey("flow"):
      continue
    for flow in file["flow"].items:
      let key = file{"path"}.getStr("") & ":" & flow{"functionKey"}.getStr("")
      if key notin seen:
        seen.add(key)
  seen.len

proc vcsRowsFromFixture(fixture: string): seq[VCSFileRow] =
  ## The VCS panel's own changed-file rows for the same changeset — the other
  ## half of §2.1's "two views of one selection".
  result = @[]
  let data = parseJson(fixture)
  if not data.hasKey("files"):
    return
  for file in data["files"].items:
    let path = file{"path"}.getStr("")
    let slash = path.rfind('/')
    let diff = file{"diff"}
    result.add(VCSFileRow(
      status: if diff != nil: diff{"status"}.getStr("M") else: "M",
      path: path,
      baseName: if slash >= 0: path[slash + 1 .. ^1] else: path,
      additions: if diff == nil: 0 else: diff{"linesAdded"}.getInt(0),
      deletions: if diff == nil: 0 else: diff{"linesRemoved"}.getInt(0),
      selected: false,
    ))

proc datasetFromFixture(fixture: string): ReviewDataset =
  ## The same changeset as the two projections above, in the shape the one
  ## review-entry routine takes (DR-R7).  Composed from them rather than
  ## re-derived, so the tests keep describing exactly the changeset the
  ## fixture assertions above pin down.
  let coverage = coverageRowsFromFixture(fixture)
  let rows = vcsRowsFromFixture(fixture)
  result = ReviewDataset(
    title: "DeepReview: parser cleanup",
    files: @[],
    traceContexts: @[],
    functionsTraced: tracedFunctionsFromFixture(fixture))
  for i, row in rows:
    result.files.add(ReviewFile(
      path: row.path,
      baseName: row.baseName,
      status: row.status,
      additions: row.additions,
      deletions: row.deletions,
      coveredLines: coverage[i].coveredLines,
      totalLines: coverage[i].totalLines,
      hasFlow: coverage[i].hasFlow))

suite "Agent Activity DeepReview — populated by a review (DR-R3)":

  test "the fixture projection matches the review dataset":
    ## Guards the tests below: if the fixture loses its files or its coverage,
    ## they must fail loudly rather than assert about an empty changeset.
    let rows = coverageRowsFromFixture(SampleReviewJson)
    check rows.len == 3
    check rows[0].path == "src/main.rs"
    check rows[0].coveredLines == 15
    check rows[0].totalLines == 17
    check rows[0].hasFlow
    check rows[1].path == "src/utils.rs"
    check rows[1].coveredLines == 5
    check rows[1].totalLines == 7
    check rows[2].path == "src/config.rs"
    check rows[2].totalLines == 0
    check not rows[2].hasFlow
    check tracedFunctionsFromFixture(SampleReviewJson) == 3
    check coverageRowsFromFixture(EmptyReviewJson).len == 0

  test "test_review_entry_populates_agent_activity_coverage":
    ## §2.1: "Coverage summary — aggregate executed / total lines and
    ## percentage for the changeset" and "Per-file coverage — one row per file
    ## in the review, aligned with the VCS panel's Changed Files rows".
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let activity = createAgentActivityDeepReviewVM(store)
      let vcs = createVCSVM()
      vcs.setDeepReviewMode(true)
      vcs.setChangedFiles(vcsRowsFromFixture(SampleReviewJson))

      var documents: seq[string] = @[]
      discard enterReview(
        vcs, activity,
        datasetFromFixture(SampleReviewJson),
        proc(a: VCSOpenAction) =
          if a.documentKey notin documents:
            documents.add(a.documentKey))

      # Aggregate coverage across the changeset: 15/17 + 5/7 + 0/0.
      check activity.coverageSummary.val.totalLinesCovered == 20
      check activity.coverageSummary.val.totalLinesUncovered == 4
      check abs(activity.coveragePercent.val - 83.3333) < 0.01
      check activity.coverageSummary.val.functionsTraced == 3

      # One row per file in the changeset, in the changeset's order.
      check activity.fileCoverage.val.len == 3
      check activity.fileCoverage.val[0].path == "src/main.rs"
      check activity.fileCoverage.val[0].coveredLines == 15
      check activity.fileCoverage.val[0].totalLines == 17
      check activity.fileCoverage.val[0].hasFlow
      check activity.fileCoverage.val[2].path == "src/config.rs"
      check not activity.fileCoverage.val[2].hasFlow

      # The section is only shown once a review has data to put in it, and a
      # review opens it — collapsed is the right default beside an agent
      # conversation, not beside a review.
      check activity.reviewActive.val
      check activity.sectionVisible.val
      check activity.isExpanded.val

      # Review entry still opens the first file (DR-R1) — the two steps run
      # from one routine.
      check documents == @["diff:file:src/main.rs"]

      dispose()

  test "test_cli_review_without_agent_session_populates_the_pane":
    ## §2.1: "It must not require a live agent session: a review launched from
    ## the CLI over an exported dataset must populate it too."  Nothing here
    ## constructs an agent session, publishes an ACP notification or appends a
    ## single feed row — the dataset alone fills the pane.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let activity = createAgentActivityDeepReviewVM(store)

      populateReviewActivity(
        activity,
        coverageRowsFromFixture(SampleReviewJson),
        tracedFunctionsFromFixture(SampleReviewJson))

      check activity.fileCoverage.val.len == 3
      check activity.coverageSummary.val.totalLinesCovered == 20
      check abs(activity.coveragePercent.val - 83.3333) < 0.01
      check activity.reviewActive.val
      # No agent ran, so there is no activity feed: the pane is populated
      # from the dataset, not from a notification stream.
      check activity.notificationCount.val == 0

      dispose()

  test "test_agent_activity_reports_absent_test_results_honestly":
    ## §2.1 lists test results, but `DeepReviewData` carries none — there is
    ## no test-name, pass/fail or duration field in the exported type (see
    ## `src/common/common_types/codetracer_features/deepreview.nim`).  The row
    ## must therefore say so; "0 run, 0 passed" reads as "all tests passed".
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let activity = createAgentActivityDeepReviewVM(store)

      # Unavailable is the *default*: a pane nobody has told about a test run
      # must not claim a green run either.
      check not activity.testResultsAvailable.val

      populateReviewActivity(
        activity,
        coverageRowsFromFixture(SampleReviewJson),
        tracedFunctionsFromFixture(SampleReviewJson))

      check not activity.testResultsAvailable.val
      check activity.testResults.val.testsRun == 0
      check activity.testResults.val.testsPassed == 0
      check not activity.hasFailures.val

      # A live agent session reporting a run flips the flag — the state is a
      # real fact about the data, not a constant.
      activity.setTestResults(AgentDeepReviewTestResults(
        testsRun: 3, testsPassed: 3, testsFailed: 0, totalDurationMs: 12))
      check activity.testResultsAvailable.val

      # …and a second review entry over a dataset with no tests must not
      # silently erase what the session reported.
      populateReviewActivity(
        activity,
        coverageRowsFromFixture(SampleReviewJson),
        tracedFunctionsFromFixture(SampleReviewJson))
      check activity.testResultsAvailable.val
      check activity.testResults.val.testsRun == 3

      dispose()

  test "test_agent_activity_file_selection_agrees_with_vcs":
    ## §2.1: "Selecting a file in either the VCS panel or the per-file
    ## coverage table should agree with the other; they are two views of one
    ## selection."
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let activity = createAgentActivityDeepReviewVM(store)
      let vcs = createVCSVM()
      vcs.setDeepReviewMode(true)
      vcs.setChangedFiles(vcsRowsFromFixture(SampleReviewJson))

      discard enterReview(
        vcs, activity, datasetFromFixture(SampleReviewJson), nil)

      # Review entry leaves both views on the first file.
      check vcs.changedFiles.val[0].selected
      check activity.selectedFilePath.val == "src/main.rs"
      check activity.selectedFileIndex.val == 0

      # Coverage table -> VCS panel.
      check selectActivityReviewFile(vcs, activity, "src/utils.rs")
      check activity.selectedFilePath.val == "src/utils.rs"
      check activity.selectedFileIndex.val == 1
      check vcs.changedFiles.val[1].selected
      check not vcs.changedFiles.val[0].selected

      # VCS panel -> coverage table.
      check selectReviewRow(vcs, 2)
      check syncActivitySelectionFromVCS(vcs, activity)
      check activity.selectedFilePath.val == "src/config.rs"
      check activity.selectedFileIndex.val == 2
      check vcs.changedFiles.val[2].selected

      # A path the review does not contain moves neither view.
      check not selectActivityReviewFile(vcs, activity, "src/absent.rs")
      check activity.selectedFilePath.val == "src/config.rs"
      check vcs.changedFiles.val[2].selected

      dispose()

# ---------------------------------------------------------------------------
# The deletion guard (DR-R8)
# ---------------------------------------------------------------------------
#
# `Content.AgentActivityDeepReview` is a DIFFERENT id from the deleted
# `Content.DeepReview`, and the names are nearly identical.  DR-R8 deletes the
# standalone review panel; deleting this one instead would delete DR-R3's
# entire pillar — DeepReview-GUI.md §2.1: "The Agent Activity panel is the
# third pillar, not an adjacent feature."
#
# Honest scope, stated because the milestone asks for it: the *registration*
# half of this is not falsifiable against the code as it stood before DR-R8 —
# the pane was registered then too.  It is listed as the explicit guard
# against deleting the wrong DeepReview, not as new coverage.  The
# *population* half is DR-R3's and is falsifiable (before DR-R3 the pane's
# only caller anywhere was a storybook fixture).

suite "Agent Activity DeepReview survives the DR-R8 deletion":

  test "test_agent_activity_deepreview_survives_the_deletion":
    ## The behavioural half: after the deletion the pane still populates from
    ## a review dataset, with no agent session and no standalone panel in the
    ## picture.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let activity = createAgentActivityDeepReviewVM(store)
      let vcs = createVCSVM()
      vcs.setDeepReviewMode(true)
      vcs.setChangedFiles(vcsRowsFromFixture(SampleReviewJson))

      var documents: seq[string] = @[]
      discard enterReview(
        vcs, activity, datasetFromFixture(SampleReviewJson),
        proc(action: VCSOpenAction) = documents.add(action.documentKey))

      check activity.reviewActive.val
      check activity.sectionVisible.val
      check activity.fileCoverage.val.len == 3
      check activity.coverageSummary.val.totalLinesCovered == 20
      check activity.selectedFilePath.val == "src/main.rs"
      # …and the Editor pillar still opens the first file from the same call.
      check documents == @["diff:file:src/main.rs"]

      dispose()

when not defined(js):
  ## The registration half is a source contract: `Content` and the panel
  ## registry live in modules that need Electron to run, so reading them is
  ## the only way to assert headlessly that DR-R8 removed `Content.DeepReview`
  ## and left `Content.AgentActivityDeepReview` alone.
  import std/os

  proc contractSource(path: string): string =
    ## `readFile` raising here is the right failure: it means a production
    ## file this contract describes was moved or deleted.
    readFile(path)

  suite "Agent Activity DeepReview registration (source contract)":

    test "the pane keeps its content id, its registration and its component":
      let contents = contractSource(
        "src/common/common_types/codetracer_features/frontend.nim")
      check contents.contains("AgentActivityDeepReview = 39")

      # `index/config.editModeHiddenContentIds` — the pane is a replay-only
      # panel and must still be hidden in edit mode.
      let config = contractSource("src/frontend/index/config.nim")
      check config.contains("ord(Content.AgentActivityDeepReview)")

      # `utils.makeComponent` — the component is still constructible.
      let utils = contractSource("src/frontend/utils.nim")
      check utils.contains("makeAgentActivityDeepReviewComponent")

      # `ui/layout.nim` — still in the direct-mount set and still synced.
      let layout = contractSource("src/frontend/ui/layout.nim")
      check layout.contains("Content.AgentActivityDeepReview")
      check layout.contains(
        "agent_activity_deepreview.tryMountIsoNimAgentActivityDeepReviewPanel")

      # The whole retained stack is still on disk.
      for path in [
          "src/frontend/ui/agent_activity_deepreview.nim",
          "src/frontend/viewmodel/viewmodels/agent_activity_deepreview_vm.nim",
          "src/frontend/viewmodel/views/isonim_agent_activity_deepreview_view.nim",
          # DeepReviewVM is architecture, not legacy: `AgenticSessionVM`
          # composes it, so DR-R8 retains it too.
          "src/frontend/viewmodel/viewmodels/deepreview_vm.nim"]:
        check fileExists(path)

    test "the standalone panel's id and modules are the ones that went":
      let contents = contractSource(
        "src/common/common_types/codetracer_features/frontend.nim")
      check not contents.contains("DeepReview = 36")

      check not fileExists("src/frontend/ui/deepreview.nim")
      check not fileExists(
        "src/frontend/viewmodel/views/isonim_deepreview_view.nim")
