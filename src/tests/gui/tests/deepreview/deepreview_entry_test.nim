## One review-entry routine for all three launch paths (DR-R7).
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §1 lists three ways into a
## review — `ct --deepreview <PATH>`, opening a trace that is associated with a
## diff, and finishing an agentic coding session — and §7 requires them to
## converge: "All three entry points converge on the same routine: load the
## dataset, populate the three panels, focus the VCS panel, open the first
## file."
##
## Before DR-R7 they did not.  `ct --deepreview` went through
## `ui_js.onStartDeepReview`, the agentic handoff through
## `ui/agentic_session_launcher.syncDeepReview` (which additionally reached
## into a standalone `DeepReviewComponent` to set its view mode, selected file,
## trace context, execution index and iteration), and the diff-associated trace
## had no implementation at all — the structured diff reached the renderer and
## was dropped.
##
## This suite is the headless half of that convergence, in two layers:
##
##   * **Behaviour** — each launch path's *production* projection is driven
##     over the same `sample-review.json` fixture the Playwright suite launches
##     CodeTracer over, each result is fed to the one entry routine, and the
##     three resulting review states are compared.  It also pins the
##     idempotence obligation of
##     `codetracer-specs/GUI/Layout-And-Navigation/Layout-System.md`,
##     "DeepReview and the Layout" (obligation 3).
##   * **Source contract** (native only) — the wiring itself.  The hosts run
##     inside Electron with GoldenLayout and the DOM, so no headless test can
##     call them; reading the production sources is what asserts that they call
##     the shared routine rather than configuring review state their own way.
##     This mirrors `src/tests/gui/tests/layout/deepreview_layout_test.nim`,
##     whose source-contract suite exists for the same reason.
##
## No mocks beyond `MockBackendService`, which every ViewModel test uses to
## construct a `ReplayDataStore`: the review projections, the entry routine and
## the diff-to-dataset conversion are all real production code.

import std/[json, strutils, unittest]

import isonim/core/[computation, owner, signals]

import backend/mock_backend
import store/[replay_data_store, types]
import viewmodels/[agent_activity_deepreview_vm, agent_activity_vm,
  agent_workspace_vm, agentic_session_vm, deepreview_vm, editor_vm,
  review_entry, vcs_vm]
import ../../../../common/types as ct_types

# ---------------------------------------------------------------------------
# The fixture — one changeset, three launch paths
# ---------------------------------------------------------------------------

proc fixtureDirPath(): string {.compileTime.} =
  let p = currentSourcePath()
  var cut = p.rfind('/')
  let backslash = p.rfind('\\')
  if backslash > cut:
    cut = backslash
  p[0 .. cut] & "fixtures/"

const SampleReviewJson = staticRead(fixtureDirPath() & "sample-review.json")

proc fixtureReviewData(fixture: string): ct_types.DeepReviewData =
  ## Decode an exported review dataset the way `--deepreview` does.
  ##
  ## The renderer's decode is `cast[DeepReviewData](JSON.parse(...))`
  ## (`frontend/index/args.nim`), which no native test can perform; this is the
  ## same field-for-field mapping written out.  Everything downstream of it —
  ## `reviewDatasetFrom`, `enterReview` — is production code.
  let node = parseJson(fixture)
  result = ct_types.DeepReviewData(
    commitSha: node{"commitSha"}.getStr(""),
    baseCommitSha: node{"baseCommitSha"}.getStr(""),
    collectionTimeMs: node{"collectionTimeMs"}.getInt(0),
    recordingCount: node{"recordingCount"}.getInt(0),
    sessionTitle: node{"sessionTitle"}.getStr(""),
    traceContexts: @[],
    files: @[],
    callTrace: ct_types.DeepReviewCallTrace(nodes: @[]))
  if node.hasKey("traceContexts"):
    for ctx in node["traceContexts"].items:
      result.traceContexts.add(ct_types.DeepReviewTraceContext(
        id: ctx{"id"}.getInt(0),
        label: ctx{"label"}.getStr(""),
        recordingId: ctx{"recordingId"}.getStr("")))
  if not node.hasKey("files"):
    return
  for file in node["files"].items:
    var coverage: seq[ct_types.DeepReviewLineCoverage] = @[]
    if file.hasKey("coverage"):
      for cov in file["coverage"].items:
        coverage.add(ct_types.DeepReviewLineCoverage(
          line: cov{"line"}.getInt(0),
          executionCount: cov{"executionCount"}.getInt(0),
          executed: cov{"executed"}.getBool(false)))
    var flow: seq[ct_types.DeepReviewFunctionFlow] = @[]
    if file.hasKey("flow"):
      for entry in file["flow"].items:
        flow.add(ct_types.DeepReviewFunctionFlow(
          functionKey: entry{"functionKey"}.getStr(""),
          executionIndex: entry{"executionIndex"}.getInt(0),
          steps: @[]))
    var hunks: seq[ct_types.DeepReviewHunk] = @[]
    let diff = file{"diff"}
    if diff != nil and diff.hasKey("hunks"):
      for hunk in diff["hunks"].items:
        var lines: seq[ct_types.DeepReviewHunkLine] = @[]
        for line in hunk["lines"].items:
          lines.add(ct_types.DeepReviewHunkLine(
            `type`: line{"type"}.getStr(""),
            content: line{"content"}.getStr(""),
            oldLine: line{"oldLine"}.getInt(0),
            newLine: line{"newLine"}.getInt(0)))
        hunks.add(ct_types.DeepReviewHunk(
          oldStart: hunk{"oldStart"}.getInt(0),
          oldCount: hunk{"oldCount"}.getInt(0),
          newStart: hunk{"newStart"}.getInt(0),
          newCount: hunk{"newCount"}.getInt(0),
          lines: lines))
    result.files.add(ct_types.DeepReviewFileData(
      path: file{"path"}.getStr(""),
      contentHash: file{"contentHash"}.getStr(""),
      sourceContent: file{"sourceContent"}.getStr(""),
      symbols: @[],
      coverage: coverage,
      functions: @[],
      loops: @[],
      flow: flow,
      flags: ct_types.DeepReviewFileFlags(),
      diff: ct_types.DeepReviewFileDiff(
        status: if diff == nil: "M" else: diff{"status"}.getStr("M"),
        linesAdded: if diff == nil: 0 else: diff{"linesAdded"}.getInt(0),
        linesRemoved: if diff == nil: 0 else: diff{"linesRemoved"}.getInt(0),
        hunks: hunks)))

proc fixtureTraceDiff(fixture: string): ct_types.Diff =
  ## The same changeset as the structured diff a trace carries.
  ##
  ## `ct record --with-diff` stores exactly this shape in the trace folder
  ## (`ct/trace/multitrace.nim`), and it is what `--diff <path>` delivers to
  ## the renderer.  Building it from the fixture's own hunks is what lets the
  ## third launch path be compared with the other two: it is the same
  ## changeset, expressed the way that path receives it.
  result = ct_types.Diff(files: @[])
  let node = parseJson(fixture)
  if not node.hasKey("files"):
    return
  for file in node["files"].items:
    let path = file{"path"}.getStr("")
    let diff = file{"diff"}
    let status = if diff == nil: "M" else: diff{"status"}.getStr("M")
    let change =
      case status
      of "A": ct_types.FileAdded
      of "D": ct_types.FileDeleted
      of "R": ct_types.FileRenamed
      else: ct_types.FileChanged
    var chunks: seq[ct_types.Chunk] = @[]
    if diff != nil and diff.hasKey("hunks"):
      for hunk in diff["hunks"].items:
        var lines: seq[ct_types.DiffLine] = @[]
        for line in hunk["lines"].items:
          let kind =
            case line{"type"}.getStr("")
            of "added": ct_types.Added
            of "removed": ct_types.Deleted
            else: ct_types.NonChanged
          lines.add(ct_types.DiffLine(
            kind: kind,
            text: line{"content"}.getStr(""),
            previousLineNumber: line{"oldLine"}.getInt(0),
            currentLineNumber: line{"newLine"}.getInt(0)))
        chunks.add(ct_types.Chunk(
          previousFrom: hunk{"oldStart"}.getInt(0),
          previousCount: hunk{"oldCount"}.getInt(0),
          currentFrom: hunk{"newStart"}.getInt(0),
          currentCount: hunk{"newCount"}.getInt(0),
          lines: lines))
    result.files.add(ct_types.FileDiff(
      chunks: chunks,
      # A deleted file has no path in the new tree; the review must still name
      # it, which is the `previousPath` fallback in `reviewDataForTraceDiff`.
      previousPath: path,
      currentPath: if change == ct_types.FileDeleted: "" else: path,
      change: change))

proc fixtureEvidenceFiles(fixture: string): seq[AgentServiceEvidenceFileEntry] =
  ## The same changeset as an agent session's recorded evidence — what
  ## `ct agent evidence` registers and `AgenticSessionVM.applyDeepReviewEvidence`
  ## projects (Agentic-Coding-Integration.md M5).
  result = @[]
  let node = parseJson(fixture)
  if not node.hasKey("files"):
    return
  for file in node["files"].items:
    let diff = file{"diff"}
    var patch = ""
    if diff != nil and diff.hasKey("hunks"):
      for hunk in diff["hunks"].items:
        for line in hunk["lines"].items:
          let content = line{"content"}.getStr("")
          patch.add(
            case line{"type"}.getStr("")
            of "added": (if content.startsWith("+"): content else: "+" & content)
            of "removed":
              (if content.startsWith("-"): content else: "-" & content)
            else: content)
          patch.add("\n")
    result.add(AgentServiceEvidenceFileEntry(
      path: file{"path"}.getStr(""),
      status: if diff == nil: "M" else: diff{"status"}.getStr("M"),
      linesAdded: if diff == nil: 0 else: diff{"linesAdded"}.getInt(0),
      linesRemoved: if diff == nil: 0 else: diff{"linesRemoved"}.getInt(0),
      diff: patch))

# ---------------------------------------------------------------------------
# Driving each launch path's production projection
# ---------------------------------------------------------------------------

proc cliLaunchDataset(): ReviewDataset =
  ## `ct --deepreview <PATH>`: the exported dataset, projected by the same
  ## generic routine the renderer instantiates over its own `DeepReviewData`.
  reviewDatasetFrom(fixtureReviewData(SampleReviewJson))

proc traceDiffLaunchDataset(): ReviewDataset =
  ## Opening a trace that is associated with a diff: the structured diff is
  ## assembled into a review dataset (`reviewDataForTraceDiff`, the same call
  ## `vcs.startReviewForTraceDiff` makes) and then projected by the same
  ## routine as any other dataset.
  reviewDatasetFrom(
    reviewDataForTraceDiff(fixtureTraceDiff(SampleReviewJson),
                           "Review: parser cleanup"))

proc agenticLaunchDataset(): ReviewDataset =
  ## The agentic handoff: an `AgenticSessionVM` carrying the session's
  ## evidence, projected by `agenticReviewDataset` — the projection
  ## `ui/agentic_session_launcher.deepReviewData` builds its `DeepReviewData`
  ## from before publishing it to the same host entry point.
  let mock = newMockBackendService()
  let store = createReplayDataStore(mock.toBackendService())
  let vm = createAgenticSessionVM(
    store, nil, createEditorVM(store), createAgentActivityVM(store),
    createAgentWorkspaceVM(store), createVCSVM(), createDeepReviewVM(store))
  var state = store.agentSessions.val
  state.sessions = @[AgentServiceSessionEntry(
    tabId: "agent:dr7",
    sessionId: "session-dr7",
    taskId: "task-dr7",
    backend: asbAcp,
    lifecycle: aslCompleted,
    title: "parser cleanup",
    evidence: AgentServiceEvidenceEntry(
      state: asesReady,
      traceId: "trace-dr7",
      testName: "latest passing run",
      workspacePath: "/tmp/agent-worktree",
      files: fixtureEvidenceFiles(SampleReviewJson)))]
  state.activeTabId = "agent:dr7"
  store.agentSessions.val = state
  # Production: this is what the `ct agent evidence` RPC ends up calling.
  doAssert vm.applyDeepReviewEvidence(state.sessions[0])
  vm.agenticReviewDataset()

type EnteredReview = object
  ## Everything a reviewer can observe after a review starts, captured from
  ## the two ViewModels the review-entry routine writes to.
  rows: seq[VCSFileRow]
  headerTitle: string
  statsText: string
  deepReviewMode: bool
  documents: seq[string]
  focusCalls: int
  traceLabels: seq[string]
  selectedTraceLabel: string
  coveragePaths: seq[string]
  coverageSummary: AgentDeepReviewCoverageSummary
  activitySelectedPath: string
  reviewActive: bool
  sectionVisible: bool
  sectionExpanded: bool
  testResultsAvailable: bool

proc snapshot(vcs: VCSVM; activity: AgentActivityDeepReviewVM;
              documents: seq[string]; focusCalls: int): EnteredReview =
  result.rows = vcs.changedFiles.val
  result.headerTitle = vcs.headerTitle.val
  result.statsText = vcs.statsText.val
  result.deepReviewMode = vcs.deepReviewMode.val
  result.documents = documents
  result.focusCalls = focusCalls
  for ctx in vcs.traceContexts.val:
    result.traceLabels.add(ctx.label)
    if ctx.id == vcs.currentTraceContextId():
      result.selectedTraceLabel = ctx.label
  for row in activity.fileCoverage.val:
    result.coveragePaths.add(row.path)
  result.coverageSummary = activity.coverageSummary.val
  result.activitySelectedPath = activity.selectedFilePath.val
  result.reviewActive = activity.reviewActive.val
  result.sectionVisible = activity.sectionVisible.val
  result.sectionExpanded = activity.isExpanded.val
  result.testResultsAvailable = activity.testResultsAvailable.val

proc enterFrom(dataset: ReviewDataset): EnteredReview =
  ## Run the one review-entry routine over a launch path's dataset, on fresh
  ## ViewModels, and record what a reviewer would see.
  ##
  ## The `open` callback stands in for the editor area: one entry per open
  ## document, keyed by the tab identity the host uses, so a repeated open
  ## focuses rather than duplicates.  The `focus` callback stands in for
  ## GoldenLayout retargeting the review's stacks.
  let mock = newMockBackendService()
  let store = createReplayDataStore(mock.toBackendService())
  let activity = createAgentActivityDeepReviewVM(store)
  let vcs = createVCSVM()
  var documents: seq[string] = @[]
  var focusCalls = 0
  discard enterReview(
    vcs, activity, dataset,
    proc(action: VCSOpenAction) =
      if action.documentKey notin documents:
        documents.add(action.documentKey),
    proc() = focusCalls += 1)
  snapshot(vcs, activity, documents, focusCalls)

proc changeset(dataset: ReviewDataset):
    seq[(string, string, int, int)] =
  for file in dataset.files:
    result.add((file.path, file.status, file.additions, file.deletions))

proc paths(rows: seq[VCSFileRow]): seq[string] =
  for row in rows:
    result.add(row.path)

proc checkEnteredState(entered: EnteredReview; launchPath: string) =
  ## The review state every launch path must reach — everything except the
  ## coverage numbers, which are a property of the dataset rather than of the
  ## entry (see the test body).
  checkpoint("launch path: " & launchPath)
  # §7 step 1 — the VCS panel populates with the changeset, and the first row
  # is the selected one.
  check entered.deepReviewMode
  check entered.rows.paths() ==
    @["src/main.rs", "src/utils.rs", "src/config.rs"]
  check entered.rows[0].selected
  check not entered.rows[1].selected
  check not entered.rows[2].selected
  check entered.statsText == "3 files +16 -10"
  # DR-R2 — the header's trace-context state, with a run selected.  *Which*
  # run differs by launch path (the exported dataset declares two, an agent
  # session has the one it recorded, and a diff-associated trace is its own
  # single run), so the labels are asserted per path in the test body; what
  # every path must reach is a review that knows which run its data belongs
  # to rather than one with nothing selected.
  check entered.traceLabels.len >= 1
  check entered.selectedTraceLabel.len > 0
  check entered.selectedTraceLabel == entered.traceLabels[0]
  # §7 step 2 — the first modified file opens, exactly once, and the review's
  # panels are focused, exactly once.
  check entered.documents == @["diff:file:src/main.rs"]
  check entered.focusCalls == 1
  # §7 step 4 / §2.1 — the Agent Activity panel's DeepReview section: one
  # coverage row per changed file, in the changeset's order, agreeing with the
  # VCS panel's selection ("two views of one selection").
  check entered.reviewActive
  check entered.sectionVisible
  check entered.sectionExpanded
  check entered.coveragePaths ==
    @["src/main.rs", "src/utils.rs", "src/config.rs"]
  check entered.activitySelectedPath == "src/main.rs"
  # No launch path carries test results: `DeepReviewData` has no field for
  # them and an agent session's evidence has no pass/fail roll-up either, so
  # all three report "not available" rather than a zeroed run that would read
  # as "all tests passed".
  check not entered.testResultsAvailable

# ---------------------------------------------------------------------------

suite "Review entry — one routine for all three launch paths (DR-R7)":

  test "the fixture projection matches the review dataset":
    ## Guards every test below: if the fixture loses its files, its coverage
    ## or its trace contexts, they must fail loudly rather than compare two
    ## empty reviews and agree.  It also covers `reviewDatasetFrom` itself,
    ## which is now the single projection all three launch paths use.
    let dataset = cliLaunchDataset()
    check dataset.title == "DeepReview: parser cleanup"
    check dataset.files.len == 3
    check dataset.files[0].path == "src/main.rs"
    check dataset.files[0].baseName == "main.rs"
    check dataset.files[0].status == "M"
    check dataset.files[0].additions == 8
    check dataset.files[0].deletions == 3
    check dataset.files[0].coveredLines == 15
    check dataset.files[0].totalLines == 17
    check dataset.files[0].hasFlow
    check dataset.files[1].path == "src/utils.rs"
    check dataset.files[1].status == "A"
    check dataset.files[2].path == "src/config.rs"
    check dataset.files[2].status == "D"
    check dataset.files[2].totalLines == 0
    check not dataset.files[2].hasFlow
    # Three distinct function keys across four recorded executions.
    check dataset.functionsTraced == 3
    check dataset.traceContexts.len == 2
    check dataset.traceContexts[0].label == "latest passing run"
    check dataset.traceContexts[1].label == "previous run"

  test "test_all_launch_paths_reach_the_same_review_state":
    ## DeepReview-GUI.md §7: "All three entry points converge on the same
    ## routine: load the dataset, populate the three panels, focus the VCS
    ## panel, open the first file."
    createRoot proc(dispose: proc()) =
      let cli = cliLaunchDataset()
      let traceDiff = traceDiffLaunchDataset()
      let agentic = agenticLaunchDataset()

      # 1. Every path describes the same changeset.  The counts are *derived*
      #    on two of the three paths (the structured diff carries no summary,
      #    so `reviewDataForTraceDiff` counts its lines), so agreement here is
      #    a real cross-check rather than a copy of one number.
      check cli.changeset() == @[
        ("src/main.rs", "M", 8, 3),
        ("src/utils.rs", "A", 8, 0),
        ("src/config.rs", "D", 0, 7)]
      check traceDiff.changeset() == cli.changeset()
      check agentic.changeset() == cli.changeset()

      # 2. Entering the review from each dataset reaches the same state.
      let a = enterFrom(cli)
      let b = enterFrom(traceDiff)
      let c = enterFrom(agentic)

      checkEnteredState(a, "ct --deepreview")
      checkEnteredState(b, "trace with an associated diff")
      checkEnteredState(c, "agentic handoff")

      # The three are the same state, not three states that each happen to
      # satisfy the assertions above: same rows (status, path, basename and
      # counts), same open document, same selection.
      for i in 0 ..< 3:
        check a.rows[i].path == b.rows[i].path
        check a.rows[i].path == c.rows[i].path
        check a.rows[i].status == b.rows[i].status
        check a.rows[i].status == c.rows[i].status
        check a.rows[i].baseName == b.rows[i].baseName
        check a.rows[i].baseName == c.rows[i].baseName
        check a.rows[i].additions == b.rows[i].additions
        check a.rows[i].additions == c.rows[i].additions
        check a.rows[i].deletions == b.rows[i].deletions
        check a.rows[i].deletions == c.rows[i].deletions
        check a.rows[i].selected == b.rows[i].selected
        check a.rows[i].selected == c.rows[i].selected
      check a.documents == b.documents
      check a.documents == c.documents
      check a.headerTitle == "DeepReview: parser cleanup"
      check b.headerTitle == "Review: parser cleanup"
      check c.headerTitle == "DeepReview: parser cleanup"

      # Which run each path reviews, named honestly by its own source.
      check a.traceLabels == @["latest passing run", "previous run"]
      check b.traceLabels == @["recorded run"]
      check c.traceLabels == @["latest passing run"]

      # …and the one row-level difference the datasets genuinely have: only a
      # collected review dataset carries per-line coverage, so only its rows
      # can show a coverage badge (VCS-Panel.md, "Changed Files").
      check a.rows[0].coverageText == "15/17"
      check b.rows[0].coverageText == ""
      check c.rows[0].coverageText == ""

      # 3. What the paths genuinely do NOT share is coverage, and they say so
      #    rather than inventing it.  Only a dataset collected by
      #    `ct-rr-support deepreview collect` carries per-line coverage: a
      #    trace's `--with-diff` diff has none, and an agent session's
      #    evidence (`AgentServiceEvidenceFileEntry`) has none either.
      check a.coverageSummary.totalLinesCovered == 20
      check a.coverageSummary.totalLinesUncovered == 4
      check a.coverageSummary.functionsTraced == 3
      check b.coverageSummary.totalLinesCovered == 0
      check b.coverageSummary.functionsTraced == 0
      check c.coverageSummary.totalLinesCovered == 0
      check c.coverageSummary.functionsTraced == 0
      # …and the coverage table still has a row per file on those two paths,
      # so the third pillar is populated rather than blank (§2.1).
      check b.coveragePaths.len == 3
      check c.coveragePaths.len == 3

      dispose()

  test "test_review_entry_is_idempotent":
    ## Layout-System.md, "DeepReview and the Layout", obligation 3:
    ## "re-entering a review on a layout persisted from an earlier review
    ## session must not accumulate duplicate tabs or re-focus over a selection
    ## the user has since changed within the same session."
    ##
    ## Every launch path re-enters: `ui_js.tryInitLayout` runs on every layout
    ## mount attempt, and `agentic_session_launcher.syncProductPanels` re-runs
    ## `syncDeepReview` on every sync of the product panels.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let activity = createAgentActivityDeepReviewVM(store)
      let vcs = createVCSVM()
      let dataset = cliLaunchDataset()

      var documents: seq[string] = @[]
      var opens = 0
      var focusCalls = 0
      let open = proc(action: VCSOpenAction) =
        opens += 1
        if action.documentKey notin documents:
          documents.add(action.documentKey)
      let focus = proc() = focusCalls += 1

      discard enterReview(vcs, activity, dataset, open, focus)
      check documents == @["diff:file:src/main.rs"]
      check opens == 1
      check focusCalls == 1

      # The reviewer moves to another file, the way a click in the Changed
      # Files list does.
      check selectReviewRow(vcs, 2)
      check syncActivitySelectionFromVCS(vcs, activity)
      check vcs.changedFiles.val[2].selected
      check activity.selectedFilePath.val == "src/config.rs"

      # …and the review is re-entered, with the same dataset.
      discard enterReview(vcs, activity, dataset, open, focus)

      # No second open, no second document, no re-focus.
      check opens == 1
      check documents == @["diff:file:src/main.rs"]
      check focusCalls == 1
      # …and the reviewer's own selection survived, in both views of it.
      check vcs.changedFiles.val[2].selected
      check not vcs.changedFiles.val[0].selected
      check activity.selectedFilePath.val == "src/config.rs"
      # The data is still refreshed on re-entry: that is the half of
      # `syncDeepReview` that stays.
      check vcs.changedFiles.val.len == 3
      check activity.fileCoverage.val.len == 3

      dispose()

  test "a review that starts with no files can still open its first file later":
    ## The one-shot must be spent on an *entry*, not on a call.  A launch path
    ## whose dataset has not arrived yet (or a layout mount that happens
    ## before it does) must not consume it — that ordering bug is exactly why
    ## DR-R1's guard had to be checked after the review-mode test.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let activity = createAgentActivityDeepReviewVM(store)
      let vcs = createVCSVM()
      var documents: seq[string] = @[]
      let open = proc(action: VCSOpenAction) =
        if action.documentKey notin documents:
          documents.add(action.documentKey)

      discard enterReview(vcs, activity, ReviewDataset(title: "empty"), open)
      check documents.len == 0
      check not vcs.reviewEntered.val

      discard enterReview(vcs, activity, cliLaunchDataset(), open)
      check documents == @["diff:file:src/main.rs"]
      check vcs.reviewEntered.val

      dispose()

  test "an agentic review names its run even without a DeepReview ViewModel":
    ## `createAgenticSessionVM`'s `deepReview` parameter is optional, and the
    ## review's trace context must not depend on it: the run an agent recorded
    ## is a fact of the session's evidence, and a review with no context at all
    ## resolves to "nothing selected" in the VCS header.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createAgenticSessionVM(
        store, nil, createEditorVM(store), createAgentActivityVM(store),
        createAgentWorkspaceVM(store), createVCSVM())
      var state = store.agentSessions.val
      state.sessions = @[AgentServiceSessionEntry(
        tabId: "agent:dr7-no-vm",
        title: "parser cleanup",
        evidence: AgentServiceEvidenceEntry(
          state: asesReady,
          testName: "recorded regression run",
          files: fixtureEvidenceFiles(SampleReviewJson)))]
      state.activeTabId = "agent:dr7-no-vm"
      store.agentSessions.val = state
      doAssert vm.applyDeepReviewEvidence(state.sessions[0])

      let dataset = vm.agenticReviewDataset()
      check dataset.files.len == 3
      check dataset.traceContexts.len == 1
      check dataset.traceContexts[0].label == "recorded regression run"

      dispose()

  test "the trace-associated diff keeps the hunks the diff tab renders":
    ## The dataset the second launch path assembles is not only a file list:
    ## it is what the Monaco diff tab reads (`ui/unified_diff.loadFromReview`),
    ## so the hunks and their line kinds have to survive the conversion.
    let data = reviewDataForTraceDiff(fixtureTraceDiff(SampleReviewJson),
                                      "Review: parser cleanup")
    check data.files.len == 3
    let main = data.files[0]
    check main.path == "src/main.rs"
    check main.diff.hunks.len == 1
    check main.diff.hunks[0].oldStart == 2
    check main.diff.hunks[0].newStart == 2
    check main.diff.hunks[0].lines.len == 13
    check main.diff.hunks[0].lines[0].`type` == "context"
    check main.diff.hunks[0].lines[1].`type` == "removed"
    check main.diff.hunks[0].lines[1].oldLine == 3
    check main.diff.hunks[0].lines[1].newLine == 0
    # A deleted file has no path in the new tree; the review names it anyway.
    check data.files[2].path == "src/config.rs"
    check data.files[2].diff.status == "D"

when not defined(js):
  ## Source contract — the wiring the behavioural suite cannot reach.
  ##
  ## `ui/vcs.nim`, `ui_js.nim` and `ui/agentic_session_launcher.nim` need
  ## Electron, GoldenLayout and the DOM to run, so nothing headless can call
  ## them.  What can be asserted is that they are wired through the shared
  ## routine — which is the whole content of this milestone, and precisely
  ## what a behavioural test on the ViewModel layer cannot distinguish.

  const
    LauncherPath = "src/frontend/ui/agentic_session_launcher.nim"
    UiJsPath = "src/frontend/ui_js.nim"
    VcsPath = "src/frontend/ui/vcs.nim"

  proc source(path: string): string =
    ## `readFile` raising here is the right failure: it means the production
    ## file this contract describes was moved or deleted.
    readFile(path)

  proc bodyOf(path, signature: string): string =
    ## A proc's body, up to the next top-level `proc`.
    let body = source(path)
    let start = body.find(signature)
    check start >= 0
    let rest = body[start .. ^1]
    let stop = rest.find("\nproc ", 1)
    if stop < 0: rest else: rest[0 ..< stop]

  suite "One review-entry routine (source contract, DR-R7)":

    test "the agentic handoff is wired through the shared routine":
      ## The behavioural half of `test_agentic_handoff_needs_no_deepreview_component`
      ## lives in `src/tests/gui/tests/agentic-coding/agentic_deepreview_m5_test.nim`,
      ## where a real `ct agent evidence` run drives the handoff; this is the
      ## wiring half.  The handoff used to end by configuring a standalone
      ## `DeepReviewComponent` — view mode, selected file, trace context,
      ## execution index, iteration — which is both the surface
      ## DeepReview-GUI.md §7 forbids and a second convention for state the
      ## review already owns.  It must now reach full review state without one
      ## existing at all.
      let body = bodyOf(LauncherPath, "proc syncDeepReview(")
      check body.contains("vcs.startDeepReviewNavigation(data)")
      check not body.contains("DeepReviewComponent")
      check not body.contains("requestDeepReviewPanelRefresh")
      # …and the panel is not opened for the session either, so there is no
      # component to configure.
      let whole = source(LauncherPath)
      check not whole.contains("DeepReviewComponent")
      check not whole.contains("ensurePanel(Content.DeepReview")
      # The data-plumbing half of `syncDeepReview` stays: it is what publishes
      # the review dataset every panel reads.
      check body.contains("data.deepReviewActive = true")
      check body.contains("data.deepReviewData = launcher.deepReviewData()")
      check body.contains("data.startOptions.deepReview = data.deepReviewData")

    test "the CLI launch path enters the review through the same routine":
      ## `ct --deepreview` cannot open a tab from `onStartDeepReview` itself
      ## (the message can arrive before GoldenLayout exists), so entry runs
      ## from `tryInitLayout` — but through the same host routine.
      let body = source(UiJsPath)
      check body.contains("vcs.startDeepReviewNavigation(data)")

    test "opening a trace with an associated diff enters the review":
      ## DeepReview-GUI.md §1, launch method 2.  Every stage before the
      ## renderer already forwarded the diff; `onTraceLoaded` used to drop it.
      let body = bodyOf(UiJsPath, "proc onTraceLoaded(")
      check body.contains("response.withDiff")
      check body.contains("vcs.startReviewForTraceDiff(")

    test "the host has no module-level one-shot guard any more":
      ## DR-R1 guarded "open the first file once" with a module-level `var` in
      ## `ui/vcs.nim`.  A global cannot be reset between tests, cannot tell two
      ## panels apart, and — as DR-R7's brief recorded — was consumed *before*
      ## the review-mode check, so a call that arrived with no review data
      ## spent it.  The flag now lives on the panel's ViewModel.
      let body = source(VcsPath)
      check not body.contains("var deepReviewNavigationDone")
      let entry = bodyOf(VcsPath, "proc startDeepReviewNavigation*(")
      let modeCheck = entry.find("data.deepReviewActive")
      let panelLookup = entry.find("componentMapping[Content.VCS]")
      check modeCheck >= 0
      check panelLookup >= 0
      check modeCheck < panelLookup

    test "the review's panels are populated by one routine, not per path":
      ## Every launch path reaches `enterReview`; none of them writes review
      ## state of its own.
      let entry = bodyOf(VcsPath, "proc startReviewNavigation*(")
      check entry.contains("enterReview(")
      let launcher = source(LauncherPath)
      check not launcher.contains("setCoverageSummary")
      check not launcher.contains("data.deepReviewSelectedFileIndex")
