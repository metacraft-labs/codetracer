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
##   4. the Agent Activity panel loads the session that produced the review,
##   5. every other panel keeps showing trace data.
##
## This module owns steps 1, 2 and 4.  It is one named routine — `enterReview`
## — rather than inline startup code because §7 requires all three launch
## paths to converge on it ("All three entry points converge on the same
## routine: load the dataset, populate the three panels, focus the VCS panel,
## open the first file").  Since DR-R7 all three do:
##
##   * `ct review <PATH>`  → `ui_js.onStartDeepReview` sets
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
## Step 4 — the agent session the dataset names, loaded into the Agent
## Activity panel — lives here so the no-agent path and the agentic handoff
## reach the same panel state rather than by two hand-kept-in-sync code paths.
## AA-1 deleted what used to sit alongside it: a static DeepReview roll-up of
## coverage, test results, a per-file table and a notification feed.  Every
## fact it restated the VCS panel already carries — the changeset, the
## per-file coverage badge and the review's stats line — so nothing moved,
## something stopped being said twice (DeepReview-GUI.md §2.1: "There is no
## 'DeepReview section' in this panel").
##
## Everything here is pure with respect to the DOM: the caller supplies the
## opener and the already-projected changeset rows, so the step is exercisable
## headlessly (see `src/tests/gui/tests/deepreview/deepreview_vm_test.nim`) and
## the imperative host (`src/frontend/ui/vcs.nim`) supplies the GoldenLayout
## side effects.

import isonim/core/signals

import ../store/types
import agent_activity_vm
import review_session
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
    ## produced it: `ct review <PATH>`, opening a trace that carries an
    ## associated diff, or the agentic handoff (DeepReview-GUI.md §1).
    title*: string
    commit*: string
      ## The commit the changeset belongs to, already abbreviated for display
      ## (`<12 hex>...`), or empty when the dataset names none.
      ##
      ## DeepReview-GUI.md §3: "The section header shows the review's file
      ## count and, when the changeset came from local git history, the commit
      ## it belongs to."  Abbreviated here, in the one shared projection,
      ## rather than in a view, so every launch path shows the same form.
    files*: seq[ReviewFile]
    traceContexts*: seq[VCSTraceContextRow]
    functionsTraced*: int

  ReviewHunkLine* = object
    ## One line of one hunk of a review's per-file diff.
    ##
    ## `kind` is spelled the way `DeepReviewHunkLine.type` is documented —
    ## "context" / "added" / "removed" — because that is what the review's
    ## consumers (`ui/unified_diff.nim`, `ui/deepreview.nim`) switch on.  The
    ## `VCSDiffLineRow` spellings ("add"/"delete", and a "hunk" row carrying
    ## the `@@` header) are normalised into it by `reviewHunksFor`.
    kind*: string
    content*: string
    oldLine*: int
    newLine*: int

  ReviewHunk* = object
    ## One hunk of a review's per-file diff, as a plain value.
    oldStart*: int
    oldCount*: int
    newStart*: int
    newCount*: int
    lines*: seq[ReviewHunkLine]

  ReviewFileDiff* = object
    ## The per-file half of a review dataset: everything the review's diff tab
    ## for *one* file renders, keyed by the path it belongs to.
    ##
    ## It is a separate value from `ReviewFile` (which is what the three panels
    ## render — a row, a coverage entry) because the two have different
    ## producers: every launch path fills in a `ReviewFile`, but only a path
    ## that carries a diff per file can fill in this.  Keeping the path on it
    ## is deliberate: the defect this type exists to prevent was a projection
    ## that returned hunks *without* knowing which file it was asked about, so
    ## every file of a changeset received the first file's diff.  A consumer
    ## can now check the answer it got names the file it asked for.
    path*: string
    status*: string
    additions*: int
    deletions*: int
    sourceContent*: string
      ## The file's full text, or "" when this review does not carry it.
      ##
      ## It is what context expansion reveals from (DeepReview-GUI.md §4.2),
      ## so a wrong answer here shows another file's lines inside this file's
      ## diff.  Empty is the honest answer; a copy of some other file's text
      ## is not.
    hunks*: seq[ReviewHunk]

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

proc abbreviatedCommit*(commitSha: string): string =
  ## The display form of a review's commit: the first twelve hex characters
  ## and an ellipsis, or the whole thing when it is already short enough.
  ##
  ## Carried over verbatim from the deleted standalone panel's header
  ## (`ui/deepreview.nim`, `commitDisplay`) so the fact it showed is not lost
  ## with it — DR-R2 moved the session title and the stats into the VCS panel
  ## header but left this one behind.  Its specified home is the VCS panel's
  ## Changed Files section header (DeepReview-GUI.md §3).
  if commitSha.len > 12:
    commitSha[0 ..< 12] & "..."
  else:
    commitSha

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
    return ReviewDataset(title: "", commit: "", files: @[], traceContexts: @[])

  let sessionTitle = $drData.sessionTitle
  let commitSha = $drData.commitSha
  result.title =
    if sessionTitle.len > 0:
      sessionTitle
    elif commitSha.len > 12:
      "Review: " & commitSha[0 ..< 12] & "..."
    else:
      "Review: " & commitSha
  result.commit = abbreviatedCommit(commitSha)

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

# ---------------------------------------------------------------------------
# The per-file half of a review dataset
# ---------------------------------------------------------------------------

proc reviewHunksFor*(rows: openArray[VCSDiffFileRow]; path: string):
    seq[ReviewHunk] {.noSideEffect.} =
  ## The hunks `rows` carries **for `path`**, and for no other file.
  ##
  ## The `path` argument is the whole point.  Before DR-R7 the agentic
  ## launcher's equivalent took no file at all: it parsed the active editor's
  ## text as a patch once per changeset, so every file of a multi-file review
  ## was handed whichever file the editor happened to be showing — a reviewer
  ## opening a deleted `config.rs` was shown `main.rs`'s modification.  This
  ## keys off the row that names the file, so a file with no row in `rows` gets
  ## *no* hunks rather than someone else's.
  ##
  ## The first row naming `path` wins: `VCSDiffFileRow` is one entry per file
  ## of one changeset (`fileIndex` numbers them), so a second row for the same
  ## path would be a duplicate of the first rather than more of its diff.
  result = @[]
  for file in rows:
    if file.path != path:
      continue
    for hunk in file.hunks:
      var converted = ReviewHunk(lines: @[])
      for line in hunk.lines:
        # `VCSDiffLineRow` spells the kinds "add"/"delete"/"context" and
        # carries the `@@` header as a "hunk" row; `DeepReviewHunkLine.type`
        # is documented as one of "context"/"added"/"removed" and keeps the
        # header in the hunk's own start/count fields.
        let kind =
          case line.lineType
          of "add", "added": "added"
          of "delete", "deleted", "removed": "removed"
          of "hunk": ""
          else: "context"
        if kind.len == 0:
          continue
        converted.lines.add ReviewHunkLine(
          kind: kind,
          content: line.content,
          oldLine: line.oldLine,
          newLine: line.newLine)
      # A `VCSHunkRow` projected from an agent's diff text carries no `@@`
      # range, so the range is derived from the lines it does carry rather
      # than left at 0,0 (which renders as "@@ -0,0 +0,0 @@").
      converted.oldStart = if hunk.oldStart > 0: hunk.oldStart else: 0
      converted.newStart = if hunk.newStart > 0: hunk.newStart else: 0
      converted.oldCount = hunk.oldCount
      converted.newCount = hunk.newCount
      for line in converted.lines:
        if line.oldLine > 0:
          if converted.oldStart == 0:
            converted.oldStart = line.oldLine
          if hunk.oldCount == 0:
            converted.oldCount += 1
        if line.newLine > 0:
          if converted.newStart == 0:
            converted.newStart = line.newLine
          if hunk.newCount == 0:
            converted.newCount += 1
      result.add converted
    return

proc reviewFileDiffs*(dataset: ReviewDataset;
                      rows: openArray[VCSDiffFileRow];
                      sourceContentPath = "";
                      sourceContentText = ""): seq[ReviewFileDiff] =
  ## The review's per-file diffs, one per file of `dataset`, in the changeset's
  ## order — the value `ui/agentic_session_launcher.deepReviewData` turns into
  ## `DeepReviewFileData`/`DeepReviewFileDiff` by copying fields.
  ##
  ## It lives here, on the ViewModel layer, rather than in the launcher because
  ## the launcher is JS-only (it needs Electron, GoldenLayout and the DOM) and
  ## therefore unreachable from a headless test — which is how the "every file
  ## gets the first file's hunks" defect survived unnoticed.  Everything that
  ## *decides* anything is in here; what stays in the launcher is a field-for-
  ## field conversion into the `cstring` flavour of `DeepReviewData`.
  ##
  ## `sourceContentPath` / `sourceContentText` are the one file whose full text
  ## the caller has (for the agentic path: whatever the editor is showing).
  ## Only that file receives it — see `ReviewFileDiff.sourceContent`.
  result = @[]
  for file in dataset.files:
    result.add ReviewFileDiff(
      path: file.path,
      status: file.status,
      additions: file.additions,
      deletions: file.deletions,
      sourceContent:
        if sourceContentPath.len > 0 and file.path == sourceContentPath:
          sourceContentText
        else:
          "",
      hunks: reviewHunksFor(rows, file.path))

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

# ---------------------------------------------------------------------------
# The VCS panel's changed-files selection
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
  # count and total +/-.  Per-file coverage rides on each Changed Files row
  # instead (`VCSFileRow.coverageText`), and test results are reported nowhere,
  # because a review dataset has none — see `reviewStatsText`.
  vcs.setHeader(dataset.title, statsText = reviewStatsText(rows),
                reviewCommit = dataset.commit)
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
                  dataset: ReviewDataset;
                  open: ReviewOpenProc;
                  focus: ReviewFocusProc = nil;
                  wantedTraceContextId = KeepCurrentTraceContext;
                  conversation: AgentActivityVM = nil;
                  session = ReviewSession(state: rssAbsent)):
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
  ##   4. the Agent Activity panel loads the session the dataset names
  ##      (step 4) — §2.1 is emphatic that a review "must not require a live
  ##      agent session", so an absent reference is an ordinary no-op rather
  ##      than an error, and it happens here rather than on the agentic path
  ##      only;
  ##   2. the three panels are focused and the first modified file opens
  ##      (step 2) — **once**;
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
  ## `conversation` may be nil — a host whose layout has no Agent Activity
  ## panel still gets a navigable review.  An empty changeset does not count as
  ## entering: a dataset that arrives later still opens its first file.
  if vcs.isNil:
    return VCSOpenAction(kind: voaNone, index: -1)
  let selected = vcs.applyReviewDataset(dataset, wantedTraceContextId)
  # RV-6, §2.1 step 4: the agent session that produced the review, loaded into
  # the Agent Activity panel.  It happens here — in the one entry routine — so
  # a CLI-launched review and an agentic handoff show the session identically.
  #
  # An absent session is a no-op, which is what keeps a dataset with no
  # reference reviewing exactly as it did before RV-6.  Since AA-1 this is the
  # whole of what a review puts into that panel: the roll-up that used to be
  # populated alongside it is gone.
  applyReviewSession(conversation, session)
  if not vcs.reviewEntered.val and selected >= 0:
    vcs.reviewEntered.val = true
    if focus != nil:
      focus()
    result = vcs.openReviewFile(selected, open)
