## The review-entry navigation step.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §7, "Transition into a
## Review", lists what happens when a review session starts, whichever of the
## three entry points started it:
##
##   1. the VCS panel populates with the changeset and becomes the visible tab
##      of its stack,
##   2. *the first modified file opens in the editor*,
##   3. flow data overlays onto its lines,
##   4. the Agent Activity DeepReview section populates,
##   5. every other panel keeps showing trace data.
##
## This module owns steps 1, 2 and 4.  It is one named routine — `enterReview`
## — rather than inline startup code because §7 requires all three launch
## paths to converge on it ("All three entry points converge on the same
## routine: load the dataset, populate the three panels, focus the VCS panel,
## open the first file").  Since DR-R7 all three do:
##
##   * `ct --deepreview <PATH>`  → `ui_js.onStartDeepReview` sets
##     `data.deepReviewData`; `tryInitLayout` calls
##     `vcs.startDeepReviewNavigation`;
##   * a trace with an associated diff → `ui_js.onTraceLoaded` assembles a
##     review dataset from the trace's structured diff and calls the same
##     host routine;
##   * the agentic handoff → `ui/agentic_session_launcher.syncDeepReview`
##     sets `data.deepReviewData` from the session's evidence and calls the
##     same host routine.
##
## None of them configures review state of its own any more.
##
## Step 4 — "The Agent Activity panel's DeepReview section populates with
## coverage and test results" — lives here for exactly the reason §2.1 gives:
## the section "must not require a live agent session: a review launched from
## the CLI over an exported dataset must populate it too".  Sharing one routine
## with the file-opening step is what makes the no-agent path and the agentic
## handoff populate the pane identically rather than by two hand-kept-in-sync
## code paths.
##
## Everything here is pure with respect to the DOM: the caller supplies the
## opener and the already-projected changeset rows, so the step is exercisable
## headlessly (see `src/tests/gui/tests/deepreview/deepreview_vm_test.nim` and
## `src/tests/gui/tests/agent-activity-deepreview/
## agent_activity_deepreview_vm_test.nim`) and the imperative host
## (`src/frontend/ui/vcs.nim`) supplies the GoldenLayout side effects.

import isonim/core/signals

import ../store/types
import agent_activity_deepreview_vm
import vcs_vm

type
  ReviewOpenProc* = proc(action: VCSOpenAction) {.closure.}
    ## Opens (or focuses) the editor document an action names.  Implemented by
    ## the host over `openLayoutTab` / `openTab`; implemented by tests over a
    ## list of document keys.

  ReviewFocusProc* = proc() {.closure.}
    ## Brings the review's panels to the front of the stacks that host them —
    ## Layout-System.md, "DeepReview and the Layout", obligation 2 ("Focus,
    ## not relocation").  Implemented by the host over GoldenLayout; nil for a
    ## host (or a test) with no layout.  Called at most *once* per review, by
    ## obligation 3.

  ReviewFile* = object
    ## One file of the changeset a review is bound to, reduced to what the
    ## three panels render.
    ##
    ## This is the review dataset as the ViewModel layer sees it: a plain
    ## value, with no `cstring`, no JS object and no dependency on
    ## `DeepReviewData` — which is a `common/types` type and therefore exists
    ## twice (once through `frontend/types`, once natively) and cannot be
    ## named by a ViewModel module at all.  `reviewDatasetFrom` is the one
    ## conversion, and it is generic precisely so that the *same* code runs
    ## over either copy.
    path*: string
    baseName*: string
    status*: string       ## "A" / "M" / "D" / "R", as the diff reports it
    additions*: int
    deletions*: int
    coveredLines*: int
    totalLines*: int
    hasFlow*: bool

  ReviewDataset* = object
    ## Everything the review-entry routine needs, whichever launch path
    ## produced it: `ct --deepreview <PATH>`, opening a trace that carries an
    ## associated diff, or the agentic handoff (DeepReview-GUI.md §1).
    title*: string
    files*: seq[ReviewFile]
    traceContexts*: seq[VCSTraceContextRow]
    functionsTraced*: int

proc `==`*(a, b: ReviewFile): bool {.noSideEffect.} =
  a.path == b.path and a.baseName == b.baseName and a.status == b.status and
    a.additions == b.additions and a.deletions == b.deletions and
    a.coveredLines == b.coveredLines and a.totalLines == b.totalLines and
    a.hasFlow == b.hasFlow

proc `==`*(a, b: ReviewDataset): bool {.noSideEffect.} =
  a.title == b.title and a.files == b.files and
    a.traceContexts == b.traceContexts and
    a.functionsTraced == b.functionsTraced

proc reviewBaseName(path: string): string {.noSideEffect.} =
  var cut = -1
  for i in countdown(path.high, 0):
    if path[i] == '/' or path[i] == '\\':
      cut = i
      break
  if cut >= 0: path[cut + 1 .. ^1] else: path

proc coverageText(covered, total: int): string {.noSideEffect.} =
  ## The Changed Files row's coverage badge — "executed/total", or nothing at
  ## all when the dataset carries no coverage for the file.  An empty badge is
  ## the honest answer for a file nothing executed data was collected for;
  ## "0/0" would read as "measured, and nothing ran".
  if total > 0: $covered & "/" & $total else: ""

proc changedFileRows*(dataset: ReviewDataset): seq[VCSFileRow] =
  ## The dataset as the VCS panel's Changed Files rows (VCS-Panel.md,
  ## "Changed Files").  Selection is *not* decided here — `applyReviewDataset`
  ## owns it, because it is the one place that knows what the reviewer had
  ## selected before the data was refreshed.
  result = @[]
  for file in dataset.files:
    result.add(VCSFileRow(
      status: file.status,
      path: file.path,
      baseName: file.baseName,
      additions: file.additions,
      deletions: file.deletions,
      coverageText: coverageText(file.coveredLines, file.totalLines),
      selected: false))

proc coverageRows*(dataset: ReviewDataset): seq[AgentDeepReviewFileCoverage] =
  ## The dataset as the Agent Activity panel's per-file coverage rows —
  ## DeepReview-GUI.md §2.1, "Per-file coverage — one row per file in the
  ## review, aligned with the VCS panel's Changed Files rows".  The alignment
  ## is literal: both projections walk `dataset.files` in order, so row *i* of
  ## each describes the same file.
  result = @[]
  for file in dataset.files:
    result.add(AgentDeepReviewFileCoverage(
      path: file.path,
      coveredLines: file.coveredLines,
      totalLines: file.totalLines,
      hasFlow: file.hasFlow))

proc reviewDatasetFrom*[T](drData: T): ReviewDataset =
  ## Project an exported/assembled review dataset (`DeepReviewData`) into the
  ## ViewModel layer's `ReviewDataset`.
  ##
  ## It is generic over the *shape* rather than typed against `DeepReviewData`
  ## because that type is defined in `common/common_types/codetracer_features/
  ## deepreview.nim`, which is `include`d both by `frontend/types` (with
  ## `langstring = cstring`) and by `common/types` (with `langstring =
  ## string`).  The two copies are distinct types, so a ViewModel module can
  ## name neither without picking a backend.  Instantiating one generic proc
  ## over both means the renderer and the headless tests run *the same
  ## projection code* rather than two hand-kept-in-sync copies — which is the
  ## whole point of DR-R7: every launch path reaching the same review state.
  ##
  ## Everything is derived from the dataset; nothing is invented.  A file with
  ## no `diff` record is reported as modified with no counts rather than
  ## dropped, because dropping it would silently renumber the changeset.
  if drData.isNil:
    return ReviewDataset(title: "", files: @[], traceContexts: @[])

  let sessionTitle = $drData.sessionTitle
  let commitSha = $drData.commitSha
  result.title =
    if sessionTitle.len > 0:
      sessionTitle
    elif commitSha.len > 12:
      "Review: " & commitSha[0 ..< 12] & "..."
    else:
      "Review: " & commitSha

  result.traceContexts = @[]
  for ctx in drData.traceContexts:
    let label = $ctx.label
    # A context with no label would render an unpickable blank option, so it
    # is named after its id rather than dropped.
    result.traceContexts.add(VCSTraceContextRow(
      id: ctx.id,
      label: if label.len > 0: label else: "Trace " & $ctx.id))

  result.files = @[]
  var tracedFunctions: seq[string] = @[]
  for file in drData.files:
    let path = $file.path
    var executed = 0
    for cov in file.coverage:
      if cov.executed:
        executed += 1
    # `DeepReviewFunctionFlow` is *one execution* of a function, so several
    # entries can share a `functionKey`; counting entries would report four
    # "functions traced" for three functions called four times.  Keys are
    # qualified by path because a key is only unique within its file.
    for flow in file.flow:
      let key = path & ":" & $flow.functionKey
      if key notin tracedFunctions:
        tracedFunctions.add(key)
    let hasDiff = not file.diff.isNil
    let status =
      if hasDiff and ($file.diff.status).len > 0: $file.diff.status else: "M"
    result.files.add(ReviewFile(
      path: path,
      baseName: reviewBaseName(path),
      status: status,
      additions: if hasDiff: file.diff.linesAdded else: 0,
      deletions: if hasDiff: file.diff.linesRemoved else: 0,
      coveredLines: executed,
      totalLines: file.coverage.len,
      hasFlow: file.flow.len > 0))
  result.functionsTraced = tracedFunctions.len

proc selectReviewRow*(vm: VCSVM; index: int): bool {.discardable.} =
  ## Mark row `index` of the changed-files list as the selected one.
  ##
  ## VCS-Panel.md, "Changed Files": "The selected row is highlighted".  The
  ## selection is exclusive: a review has exactly one file under inspection at
  ## a time, and it is the one the editor is showing.
  ##
  ## Returns true when a row was selected.
  let rows = vm.changedFiles.val
  if index < 0 or index >= rows.len:
    return false
  var updated = rows
  for i in 0 ..< updated.len:
    updated[i].selected = i == index
  vm.changedFiles.val = updated
  true

proc openReviewFile*(vm: VCSVM; index: int; open: ReviewOpenProc):
    VCSOpenAction {.discardable.} =
  ## Select row `index` and open its review representation in the editor.
  ##
  ## The representation is whatever `VCSVM.viewMode` currently selects — the
  ## VCS panel's view-mode toggle (VCS-Panel.md, "View mode toggle") — with
  ## the deleted-file rule applied by `openActionFor`.
  ##
  ## `open` is called at most once, and never for a row that does not exist:
  ## an empty changeset opens nothing rather than fabricating a document.
  result = vm.openActionForRow(index)
  if result.kind == voaNone:
    return
  discard vm.selectReviewRow(index)
  if open != nil:
    open(result)

proc openFirstReviewFile*(vm: VCSVM; open: ReviewOpenProc):
    VCSOpenAction {.discardable.} =
  ## §7 step 2: "The first modified file opens in the editor."
  vm.openReviewFile(0, open)

# ---------------------------------------------------------------------------
# §7 step 4 — the Agent Activity panel's DeepReview section (DR-R3)
# ---------------------------------------------------------------------------

proc reviewCoverageSummary*(files: openArray[AgentDeepReviewFileCoverage];
                            functionsTraced: int):
    AgentDeepReviewCoverageSummary {.noSideEffect.} =
  ## The changeset's aggregate coverage — DeepReview-GUI.md §2.1, "Coverage
  ## summary — aggregate executed / total lines and percentage for the
  ## changeset".
  ##
  ## Every value is derived from the rows, which are themselves derived from
  ## `DeepReviewFileData.coverage`; nothing is invented.  A changeset whose
  ## files carry no coverage at all yields 0% over 0 lines rather than a
  ## division by zero.
  var covered = 0
  var total = 0
  for file in files:
    covered += file.coveredLines
    total += file.totalLines
  AgentDeepReviewCoverageSummary(
    totalLinesCovered: covered,
    totalLinesUncovered: total - covered,
    coveragePercent:
      if total > 0: (covered.float / total.float) * 100.0 else: 0.0,
    functionsTraced: functionsTraced)

proc populateReviewActivity*(activity: AgentActivityDeepReviewVM;
                             files: openArray[AgentDeepReviewFileCoverage];
                             functionsTraced: int) =
  ## §7 step 4: "The Agent Activity panel's DeepReview section populates with
  ## coverage and test results."
  ##
  ## `files` is the review's changeset already projected into coverage rows —
  ## the host walks `DeepReviewData`, which is a JS object and cannot be read
  ## from a headless build, so the projection stays on the host side and the
  ## decision stays here.
  ##
  ## Test results are *not* set: `DeepReviewData` carries none (no test name,
  ## no pass/fail, no duration), so a dataset-launched review has nothing to
  ## report and the row is marked unavailable rather than zeroed — see
  ## `setTestResultsUnavailable`.  A live agent session that already reported
  ## a run keeps it: entering a review must not erase a fact somebody
  ## observed.
  if activity.isNil:
    return
  activity.setFileCoverage(files)
  activity.setCoverageSummary(reviewCoverageSummary(files, functionsTraced))
  if not activity.testResultsAvailable.val:
    activity.setTestResultsUnavailable()
  activity.setReviewActive(true)
  # The section is collapsible, and collapsed by default so it stays out of
  # the way of an agent conversation.  A review is the case where it is the
  # point of the panel — §2.1: the review answers "what was run, what did it
  # cover, and what passed" here — so entering one opens it.  The reviewer can
  # still fold it away; nothing re-opens it afterwards.
  activity.setExpanded(true)

# ---------------------------------------------------------------------------
# §2.1 — "two views of one selection"
# ---------------------------------------------------------------------------

proc selectedReviewPath*(vm: VCSVM): string =
  ## Path of the changed-files row the VCS panel currently has selected, or
  ## the empty string when none is.
  for row in vm.changedFiles.val:
    if row.selected:
      return row.path
  ""

proc reviewRowIndexForPath*(vm: VCSVM; path: string): int =
  ## Index of the changed-files row naming `path`, or -1.  Hosts use it to
  ## turn a selection arriving from the coverage table into the same
  ## row-index gesture a click in the Changed Files list produces.
  if path.len == 0:
    return -1
  let rows = vm.changedFiles.val
  for i in 0 ..< rows.len:
    if rows[i].path == path:
      return i
  -1

proc selectReviewRowByPath*(vm: VCSVM; path: string): bool {.discardable.} =
  ## Select the changed-files row whose path is `path`.  Returns false — and
  ## changes nothing — when the review has no such file, so a selection
  ## arriving from the other view cannot blank the VCS panel's highlight.
  let index = vm.reviewRowIndexForPath(path)
  if index < 0:
    return false
  vm.selectReviewRow(index)

proc syncActivitySelectionFromVCS*(vcs: VCSVM;
                                   activity: AgentActivityDeepReviewVM):
    bool {.discardable.} =
  ## VCS panel -> per-file coverage table.  DeepReview-GUI.md §2.1:
  ## "Selecting a file in either the VCS panel or the per-file coverage table
  ## should agree with the other; they are two views of one selection."
  if vcs.isNil or activity.isNil:
    return false
  let path = vcs.selectedReviewPath()
  if path.len == 0:
    return false
  activity.setSelectedFilePath(path)
  true

proc selectActivityReviewFile*(vcs: VCSVM;
                               activity: AgentActivityDeepReviewVM;
                               path: string): bool {.discardable.} =
  ## Per-file coverage table -> VCS panel: the other direction of the same
  ## agreement.  Both views move together or neither does — a path the review
  ## does not contain is rejected rather than half-applied, which is what
  ## keeps "two views of one selection" true rather than approximately true.
  if activity.isNil or path.len == 0:
    return false
  if not vcs.isNil and not vcs.selectReviewRowByPath(path):
    return false
  activity.setSelectedFilePath(path)
  true

# ---------------------------------------------------------------------------
# The whole entry step
# ---------------------------------------------------------------------------

const KeepCurrentTraceContext* = low(int)
  ## `applyReviewDataset`'s default: keep whichever trace context the panel
  ## already has selected.  A distinct sentinel is needed because 0 is a
  ## perfectly ordinary context id (`DeepReviewTraceContext.id` is 0-based in
  ## the exported datasets).

proc applyReviewDataset*(vcs: VCSVM; dataset: ReviewDataset;
                         wantedTraceContextId = KeepCurrentTraceContext):
    int {.discardable.} =
  ## Populate the VCS panel from a review dataset, and report which row ends
  ## up selected.
  ##
  ## This is DeepReview-GUI.md §7 step 1 — "The VCS panel populates with the
  ## changeset data" — and it is re-runnable: every launch path re-syncs its
  ## data (the agentic launcher on every product-panel sync, the CLI path on
  ## every panel re-render), and a refresh must not throw away what the
  ## reviewer is looking at.  So the selection is carried across *by path*:
  ## the row the reviewer selected stays selected as long as the changeset
  ## still contains that file, and only a review that has no selection yet
  ## falls back to the first row.
  if vcs.isNil:
    return -1
  let previous = vcs.selectedReviewPath()
  var rows = dataset.changedFileRows()
  result = -1
  if rows.len > 0:
    result = 0
    if previous.len > 0:
      for i in 0 ..< rows.len:
        if rows[i].path == previous:
          result = i
          break
    rows[result].selected = true

  vcs.setDeepReviewMode(true)
  # DeepReview-GUI.md §2: the VCS panel header owns the review's session title
  # *and* its stats.  The stats summarise only what the dataset carries — file
  # count and total +/-; coverage and test results belong to the Agent
  # Activity panel (§2.1).
  vcs.setHeader(dataset.title, statsText = reviewStatsText(rows))
  vcs.setTraceContexts(dataset.traceContexts)
  # An unknown or unset preference resolves to the review's first context,
  # which is what `DeepReviewTraceContext`'s own contract says the default is
  # — without it a freshly started review shows a dropdown with no option
  # marked selected.
  let wanted =
    if wantedTraceContextId == KeepCurrentTraceContext:
      vcs.selectedTraceContextId.val
    else:
      wantedTraceContextId
  vcs.setSelectedTraceContextId(
    resolveTraceContextId(dataset.traceContexts, wanted))
  vcs.setGitRepoState(true)
  vcs.setBranchState("", @[], false)
  vcs.setCommits(@[], @[])
  vcs.setChangedFiles(rows)
  # The docked panel is never a diff surface (#561): a unified diff is its own
  # editor tab.  Cleared explicitly so a panel that once hosted one cannot
  # leave a stale diff behind.
  vcs.setUnifiedDiff(false, @[])
  vcs.setHunkState(@[], false, false)

proc enterReview*(vcs: VCSVM;
                  activity: AgentActivityDeepReviewVM;
                  dataset: ReviewDataset;
                  open: ReviewOpenProc;
                  focus: ReviewFocusProc = nil;
                  wantedTraceContextId = KeepCurrentTraceContext):
    VCSOpenAction {.discardable.} =
  ## **The** review-entry routine.  Every launch path calls this one
  ## (DeepReview-GUI.md §7: "All three entry points converge on the same
  ## routine: load the dataset, populate the three panels, focus the VCS
  ## panel, open the first file").
  ##
  ## In order, and matching §7's "Transition into a Review":
  ##
  ##   1. the VCS panel populates with the changeset, the session title, the
  ##      stats line and the trace-context selector (steps 1, and DR-R2);
  ##   4. the Agent Activity panel's DeepReview section populates with the
  ##      review's coverage (step 4) — §2.1 is emphatic that this "must not
  ##      require a live agent session", which is why it happens here rather
  ##      than on the agentic path only;
  ##   2. the three panels are focused and the first modified file opens
  ##      (step 2) — **once**;
  ##      and the changed-files list and the coverage table end up naming the
  ##      same file (§2.1, "two views of one selection").
  ##
  ## Steps 3 and 5 belong to the replay data behind the review and are not
  ## this routine's to perform.
  ##
  ## *Idempotence* (Layout-System.md, "DeepReview and the Layout",
  ## obligation 3) is the reason the last group is guarded: re-entering a
  ## review — which every path does whenever its data is re-synced — refreshes
  ## the data but does not open a second tab, does not drag the reviewer back
  ## to the first file, and does not re-focus over a tab they switched to.
  ##
  ## `activity` may be nil — a host whose layout has no Agent Activity panel
  ## still gets a navigable review.  An empty changeset does not count as
  ## entering: a dataset that arrives later still opens its first file.
  if vcs.isNil:
    return VCSOpenAction(kind: voaNone, index: -1)
  let selected = vcs.applyReviewDataset(dataset, wantedTraceContextId)
  populateReviewActivity(activity, dataset.coverageRows(),
                         dataset.functionsTraced)
  if not vcs.reviewEntered.val and selected >= 0:
    vcs.reviewEntered.val = true
    if focus != nil:
      focus()
    result = vcs.openReviewFile(selected, open)
  discard syncActivitySelectionFromVCS(vcs, activity)
