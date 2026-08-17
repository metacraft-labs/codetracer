## ViewModel for the VCS / DeepReview changed-files panel.
##
## The legacy ``VCSComponent`` still owns git subprocess calls, file watching,
## hunk patch actions, and cross-panel DeepReview selection.  This VM carries
## the flat render snapshot consumed by the IsoNim VCS view.
##
## Commit graph:
##   Each ``VCSCommitRow`` carries a ``graphCells`` sequence — one
##   ``VCSGraphCell`` per visible branch lane.  The view renders them as a
##   small grid of coloured vertical lines and dots to the left of the commit
##   message, matching the VSCode Git Graph style.
##
## Accordion:
##   ``selectedCommitIndex`` doubles as the accordion open/close state:
##   clicking an already-selected commit sets ``selectedCommitIndex`` to -1
##   (collapsed); clicking a different one selects + expands it, and the view
##   renders ``changedFiles`` inline under that row.
##
## Infinite scroll:
##   ``loadingMore`` is set to true by the legacy component while a background
##   git-log page fetch is in progress.  The view shows a subtle loading row
##   at the bottom of the commit list until it flips back to false.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

type
  VCSGraphCellKind* = enum
    gckEmpty  ## no branch passes through this column for this row
    gckLine   ## a branch passes through (vertical line only)
    gckDot    ## this commit lives in this column (circle + line)

  VCSGraphCell* = object
    ## One cell of the commit-graph grid rendered to the left of each commit.
    kind*: VCSGraphCellKind
    colorIdx*: int ## index into the branch colour palette (0-5, cycled)

  VCSGraphConnector* = object
    ## A right-angle connector drawn between two lane columns in one commit row.
    ##
    ## Two kinds exist:
    ##   ``isTop = false`` (bottom connector):
    ##     Drawn from row centre → bottom.  Used at merge commits when a new
    ##     merge-parent lane opens below the dot.  Visual: dot lane at 50%
    ##     curves RIGHT (or LEFT) and runs down to the new lane at 100%.
    ##   ``isTop = true`` (top connector):
    ##     Drawn from row top → centre.  Used when a branch converges back
    ##     onto the dot lane (i.e. it is the common ancestor in the forward
    ##     direction).  Visual: feature lane at 0% curves into the dot lane
    ##     at 50%.
    fromLane*: int   ## source column
    toLane*:   int   ## destination column
    colorIdx*: int   ## branch colour palette index
    isTop*:    bool  ## true → top-half connector; false → bottom-half

  VCSCommitRow* = object
    hash*: string          ## abbreviated SHA-1 for display
    message*: string       ## commit subject
    relativeTime*: string  ## e.g. "3 hours ago"
    date*: string          ## absolute date in YYYY-MM-DD format (git %cs token)
    author*: string        ## author name, shown when the accordion is open
    fullHash*: string      ## full SHA-1, shown in the accordion header
    graphCells*: seq[VCSGraphCell] ## branch-graph columns for this row
    dotLane*: int                        ## column of the commit dot (-1 = none)
    connectors*: seq[VCSGraphConnector]  ## merge/fork connectors for this row

  VCSFileRow* = object
    status*: string
    path*: string
    baseName*: string
    additions*: int
    deletions*: int
    coverageText*: string
    selected*: bool

  VCSDiffLineRow* = object
    lineType*: string
    content*: string
    oldLine*: int
    newLine*: int

  VCSHunkRow* = object
    oldStart*: int
    oldCount*: int
    newStart*: int
    newCount*: int
    selected*: bool
    lines*: seq[VCSDiffLineRow]

  VCSDiffFileRow* = object
    fileIndex*: int
    status*: string
    path*: string
    additions*: int
    deletions*: int
    hunks*: seq[VCSHunkRow]

  VCSTraceContextRow* = object
    ## One selectable trace context of a review session — the control
    ## DeepReview-GUI.md §2 houses in the VCS panel header ("Trace context
    ## selector → The VCS panel header, populated only in DeepReview mode").
    ##
    ## It mirrors ``DeepReviewTraceContext`` (``common_types/
    ## codetracer_features/deepreview.nim``) reduced to what the header
    ## renders: the id the selection is expressed in, and the label shown in
    ## the dropdown.  It is deliberately a local row type rather than the
    ## store's ``DeepReviewTraceContextEntry`` so that this VM keeps depending
    ## on nothing but IsoNim — the standalone panel that owns that entry type
    ## is deleted in DR-R8.
    id*: int
    label*: string

  VCSViewMode* = enum
    ## What clicking a file row in the docked panel does — the "View mode
    ## toggle" of `codetracer-specs/GUI/Core-Panes/VCS-Panel.md`.
    vmUnifiedDiff  ## open a unified diff tab for the file (spec default,
                   ## `vcs.defaultView: "unified-diff"`)
    vmOpenFile     ## open the file itself in the editor

  VCSOpenActionKind* = enum
    ## What a click on a changed-file row resolves to.
    voaNone        ## nothing to open (no such row, or a row with no path)
    voaDiffTab     ## open/focus the unified diff tab for `target`
    voaSourceFile  ## open/focus the file itself in the editor

  VCSOpenAction* = object
    ## The decision a file-row click makes, as data.
    ##
    ## It is data rather than an effect so the decision is testable without a
    ## browser: the host (`ui/vcs.nim`) is a dispatcher over this value and
    ## owns only the GoldenLayout/Monaco side effects.
    kind*: VCSOpenActionKind
    index*: int     ## row index the click came from
    path*: string   ## file path as the row reports it
    target*: string ## diff target (`file:<path>`, `commit:<hash>:<path>`, …)
    status*: string ## diff status letter of the row ("M", "A", "D", "R", …)

  VCSVM* = ref object of ViewModel
    deepReviewMode*: Signal[bool]
    headerTitle*: Signal[string]
    headerIcon*: Signal[string]
    ## Summary line for the review the header describes — file count and the
    ## changeset's total +/-.  Empty in normal version-control mode, where the
    ## header describes a live working tree rather than a fixed changeset.
    statsText*: Signal[string]
    ## The review's selectable trace contexts, in export order.  Empty in
    ## normal version-control mode: a working tree has no recordings behind
    ## it.  DeepReview-GUI.md §6: "The selected trace context can be changed
    ## without leaving the review, from the selector in the VCS panel header".
    traceContexts*: Signal[seq[VCSTraceContextRow]]
    ## Id of the currently selected entry of ``traceContexts``.
    selectedTraceContextId*: Signal[int]
    isGitRepo*: Signal[bool]
    errorMessage*: Signal[string]
    currentBranch*: Signal[string]
    branches*: Signal[seq[string]]
    branchDropdownOpen*: Signal[bool]
    commits*: Signal[seq[VCSCommitRow]]
    ## Indices of all currently expanded commits (supports multi-select via
    ## ctrl+click / shift+click).  Empty seq means the accordion is collapsed.
    selectedCommitIndices*: Signal[seq[int]]
    ## Anchor for shift-click range selection; -1 when no anchor is set.
    lastClickedIndex*: Signal[int]
    ## Files per expanded commit: seq of (commitIndex, fileRows) pairs.
    ## Each expanded commit has its own entry so multiple accordions can show
    ## different file lists simultaneously.
    commitFilesMap*: Signal[seq[(int, seq[VCSFileRow])]]
    changedFiles*: Signal[seq[VCSFileRow]]  ## DeepReview mode file list
    ## What a file click does in the docked panel.  Distinct from
    ## `unifiedDiffActive`: this one never changes what the panel *renders*.
    viewMode*: Signal[VCSViewMode]
    ## True when this panel instance IS a unified diff — a dedicated diff tab,
    ## or the inline diff of an agentic-session review.  The docked panel keeps
    ## it false so toggling the view mode never replaces its commit history.
    unifiedDiffActive*: Signal[bool]
    diffFiles*: Signal[seq[VCSDiffFileRow]]
    selectedHunks*: Signal[seq[(int, int)]]
    hunkToolbarVisible*: Signal[bool]
    hunkCopyFeedback*: Signal[bool]
    loadingMore*: Signal[bool]  ## true while next commit page is being fetched

    fileCount*: Memo[int]
    selectedHunkCount*: Memo[int]

proc `==`*(a, b: VCSGraphCell): bool {.noSideEffect.} =
  a.kind == b.kind and a.colorIdx == b.colorIdx

proc `==`*(a, b: VCSGraphConnector): bool {.noSideEffect.} =
  a.fromLane == b.fromLane and a.toLane == b.toLane and a.colorIdx == b.colorIdx and
    a.isTop == b.isTop

proc `==`*(a, b: VCSCommitRow): bool {.noSideEffect.} =
  a.hash == b.hash and a.message == b.message and
    a.relativeTime == b.relativeTime and a.date == b.date and
    a.author == b.author and a.fullHash == b.fullHash and
    a.graphCells == b.graphCells and
    a.dotLane == b.dotLane and a.connectors == b.connectors

proc `==`*(a, b: VCSFileRow): bool {.noSideEffect.} =
  a.status == b.status and a.path == b.path and
    a.baseName == b.baseName and a.additions == b.additions and
    a.deletions == b.deletions and a.coverageText == b.coverageText and
    a.selected == b.selected

proc `==`*(a, b: VCSDiffLineRow): bool {.noSideEffect.} =
  a.lineType == b.lineType and a.content == b.content and
    a.oldLine == b.oldLine and a.newLine == b.newLine

proc `==`*(a, b: VCSHunkRow): bool {.noSideEffect.} =
  a.oldStart == b.oldStart and a.oldCount == b.oldCount and
    a.newStart == b.newStart and a.newCount == b.newCount and
    a.selected == b.selected and a.lines == b.lines

proc `==`*(a, b: VCSDiffFileRow): bool {.noSideEffect.} =
  a.fileIndex == b.fileIndex and a.status == b.status and
    a.path == b.path and a.additions == b.additions and
    a.deletions == b.deletions and a.hunks == b.hunks

proc `==`*(a, b: VCSTraceContextRow): bool {.noSideEffect.} =
  a.id == b.id and a.label == b.label

proc `==`*(a, b: VCSOpenAction): bool {.noSideEffect.} =
  a.kind == b.kind and a.index == b.index and a.path == b.path and
    a.target == b.target and a.status == b.status

proc isDeletedStatus*(status: string): bool {.noSideEffect.} =
  ## True for the diff statuses that mean "this path is gone from the new
  ## tree".  Git reports the letter; the DeepReview export and some of the
  ## panel's own helpers use the spelled-out word, so both are accepted.
  status == "D" or status == "deleted"

proc documentKey*(action: VCSOpenAction): string {.noSideEffect.} =
  ## The identity of the editor document this action asks for.
  ##
  ## It is what makes "opening a file that is already open focuses the
  ## existing tab" work: the host keys diff tabs by `diff:<target>`
  ## (`Component.independentTabPath`, matched in `utils.openLayoutTab`) and
  ## source tabs by the editor tab path (matched in `utils.openTab`), so two
  ## clicks on one row must produce one key.
  case action.kind
  of voaNone: ""
  of voaDiffTab: "diff:" & action.target
  of voaSourceFile: action.path

proc openActionFor*(vm: VCSVM; index: int; path, target, status: string):
    VCSOpenAction =
  ## Resolve what clicking a changed-file row does.  Pure: no signals are
  ## written, nothing is opened.
  ##
  ## This is the single decision point for both normal version control and
  ## DeepReview mode — DeepReview-GUI.md §3: "clicking a file opens it in the
  ## editor, in the representation the view mode toggle currently selects …
  ## it works identically in normal VCS mode and in DeepReview mode".
  ##
  ## Deleted files are the one case the two specs are silent about, and
  ## DR-R1 decides it here: a file with status `D` has no content in the new
  ## tree, so it always resolves to the diff tab that shows the removal,
  ## never to an "open file" for a path that no longer exists.
  if path.len == 0 and target.len == 0:
    return VCSOpenAction(kind: voaNone, index: index)
  let diffTarget = if target.len > 0: target else: "file:" & path
  let wantsSource = vm.viewMode.val == vmOpenFile and not isDeletedStatus(status)
  VCSOpenAction(
    kind: if wantsSource: voaSourceFile else: voaDiffTab,
    index: index,
    path: path,
    target: diffTarget,
    status: status)

proc openActionForRow*(vm: VCSVM; index: int): VCSOpenAction =
  ## `openActionFor` for a row of the panel's own changed-files list — the
  ## list DeepReview mode renders, and the one the review-entry step walks.
  let rows = vm.changedFiles.val
  if index < 0 or index >= rows.len:
    return VCSOpenAction(kind: voaNone, index: index)
  let row = rows[index]
  vm.openActionFor(index, row.path, "file:" & row.path, row.status)

proc reviewStatsText*(files: openArray[VCSFileRow]): string {.noSideEffect.} =
  ## The review summary the VCS panel header shows next to the session title
  ## — DeepReview-GUI.md §2, "Session title / stats → The VCS panel header".
  ##
  ## Only what a review dataset actually carries is summarised: the number of
  ## changed files and the changeset's total added/removed line counts, both
  ## of which come from ``DeepReviewData.files[].diff``.  Coverage and test
  ## results deliberately do NOT appear here: they belong to the Agent
  ## Activity panel (§2.1, DR-R3), and ``DeepReviewData`` carries no
  ## test-results field at all, so a "tests 0/0" stat would be invented
  ## rather than reported.
  if files.len == 0:
    return ""
  var additions = 0
  var deletions = 0
  for file in files:
    additions += file.additions
    deletions += file.deletions
  result = $files.len & (if files.len == 1: " file" else: " files")
  if additions > 0 or deletions > 0:
    result.add(" +" & $additions & " -" & $deletions)

proc resolveTraceContextId*(contexts: openArray[VCSTraceContextRow];
                            wanted: int): int {.noSideEffect.} =
  ## The trace context that should be selected given a caller's preference.
  ##
  ## ``wanted`` is honoured when it names one of ``contexts``; otherwise the
  ## first context wins, because "the first entry is selected by default"
  ## (``DeepReviewTraceContext``'s own contract).  A review with no contexts
  ## resolves to 0, which no option carries, so nothing renders as selected.
  for ctx in contexts:
    if ctx.id == wanted:
      return wanted
  if contexts.len > 0: contexts[0].id else: 0

proc setDeepReviewMode*(vm: VCSVM; active: bool) =
  vm.deepReviewMode.val = active

proc setHeader*(vm: VCSVM; title: string; icon = "\239\132\166";
                statsText = "") =
  ## ``statsText`` mirrors ``DeepReviewVM.setHeader``'s third argument.  It
  ## defaults to empty so the normal version-control callers clear it: the
  ## review summary must not survive into a live working-tree session.
  vm.headerTitle.val = title
  vm.headerIcon.val = icon
  vm.statsText.val = statsText

proc setTraceContexts*(vm: VCSVM;
                       contexts: openArray[VCSTraceContextRow]) =
  vm.traceContexts.val = @contexts

proc setSelectedTraceContextId*(vm: VCSVM; id: int) =
  vm.selectedTraceContextId.val = id

proc hasTraceContextChoice*(vm: VCSVM): bool =
  ## Whether the header should offer the trace-context selector at all.
  ##
  ## Review mode only — the control has no meaning for a working tree — and
  ## only when there is something to choose between: a review that declares a
  ## single context would render a dropdown whose every option is the current
  ## one.
  vm.deepReviewMode.val and vm.traceContexts.val.len >= 2

proc setGitRepoState*(vm: VCSVM; isRepo: bool; errorMessage = "") =
  vm.isGitRepo.val = isRepo
  vm.errorMessage.val = errorMessage

proc setBranchState*(vm: VCSVM; current: string; branches: openArray[string];
                     dropdownOpen: bool) =
  vm.currentBranch.val = current
  vm.branches.val = @branches
  vm.branchDropdownOpen.val = dropdownOpen

proc setCommits*(vm: VCSVM; commits: openArray[VCSCommitRow];
                 selectedIndices: openArray[int];
                 lastClicked: int = -1) =
  ## Update the commit list and multi-select state.
  ## ``selectedIndices`` is the set of expanded commit indices; out-of-range
  ## values are silently dropped so callers don't need to clamp manually.
  vm.commits.val = @commits
  var clamped: seq[int] = @[]
  for idx in selectedIndices:
    if idx >= 0 and idx < commits.len:
      clamped.add(idx)
  vm.selectedCommitIndices.val = clamped
  vm.lastClickedIndex.val = lastClicked

proc setCommitFiles*(vm: VCSVM; commitIndex: int;
                     files: openArray[VCSFileRow]) =
  ## Insert or update the file list for a single expanded commit in the map.
  var newMap = vm.commitFilesMap.val
  for i, pair in newMap:
    if pair[0] == commitIndex:
      newMap[i] = (commitIndex, @files)
      vm.commitFilesMap.val = newMap
      return
  newMap.add((commitIndex, @files))
  vm.commitFilesMap.val = newMap

proc removeCommitFiles*(vm: VCSVM; commitIndex: int) =
  ## Remove the file list for a commit that is no longer expanded.
  var newMap: seq[(int, seq[VCSFileRow])] = @[]
  for pair in vm.commitFilesMap.val:
    if pair[0] != commitIndex:
      newMap.add(pair)
  vm.commitFilesMap.val = newMap

proc syncCommitFilesMap*(vm: VCSVM;
                         entries: openArray[(int, seq[VCSFileRow])]) =
  ## Replace the entire commitFilesMap with the provided entries.
  ## Called by syncLegacyVCSIntoVM to push the full per-commit file cache.
  vm.commitFilesMap.val = @entries

proc setChangedFiles*(vm: VCSVM; files: openArray[VCSFileRow]) =
  vm.changedFiles.val = @files

proc setViewMode*(vm: VCSVM; mode: VCSViewMode) =
  vm.viewMode.val = mode

proc setUnifiedDiff*(vm: VCSVM; active: bool;
                     files: openArray[VCSDiffFileRow]) =
  vm.unifiedDiffActive.val = active
  vm.diffFiles.val = @files

proc setHunkState*(vm: VCSVM; selected: openArray[(int, int)];
                   toolbarVisible: bool; copyFeedback: bool) =
  vm.selectedHunks.val = @selected
  vm.hunkToolbarVisible.val = toolbarVisible
  vm.hunkCopyFeedback.val = copyFeedback

proc setLoadingMore*(vm: VCSVM; loading: bool) =
  vm.loadingMore.val = loading

proc clearPanel*(vm: VCSVM) =
  vm.deepReviewMode.val = false
  vm.headerTitle.val = ""
  vm.headerIcon.val = "\239\132\166"
  vm.statsText.val = ""
  vm.traceContexts.val = @[]
  vm.selectedTraceContextId.val = 0
  vm.isGitRepo.val = false
  vm.errorMessage.val = ""
  vm.currentBranch.val = ""
  vm.branches.val = @[]
  vm.branchDropdownOpen.val = false
  vm.commits.val = @[]
  vm.selectedCommitIndices.val = @[]
  vm.lastClickedIndex.val = -1
  vm.commitFilesMap.val = @[]
  vm.changedFiles.val = @[]
  vm.viewMode.val = vmUnifiedDiff
  vm.unifiedDiffActive.val = false
  vm.diffFiles.val = @[]
  vm.selectedHunks.val = @[]
  vm.hunkToolbarVisible.val = false
  vm.hunkCopyFeedback.val = false
  vm.loadingMore.val = false

proc createVCSVM*(): VCSVM =
  withViewModel proc(dispose: proc()): VCSVM =
    let changedFiles = createSignal(newSeq[VCSFileRow]())
    let selectedHunks = createSignal(newSeq[(int, int)]())

    let fileCount = createMemo[int] proc(): int =
      changedFiles.val.len

    let selectedHunkCount = createMemo[int] proc(): int =
      selectedHunks.val.len

    VCSVM(
      deepReviewMode: createSignal(false),
      headerTitle: createSignal(""),
      headerIcon: createSignal("\239\132\166"),
      statsText: createSignal(""),
      traceContexts: createSignal(newSeq[VCSTraceContextRow]()),
      selectedTraceContextId: createSignal(0),
      isGitRepo: createSignal(false),
      errorMessage: createSignal(""),
      currentBranch: createSignal(""),
      branches: createSignal(newSeq[string]()),
      branchDropdownOpen: createSignal(false),
      commits: createSignal(newSeq[VCSCommitRow]()),
      selectedCommitIndices: createSignal(newSeq[int]()),
      lastClickedIndex: createSignal(-1),
      commitFilesMap: createSignal(newSeq[(int, seq[VCSFileRow])]()),
      changedFiles: changedFiles,
      viewMode: createSignal(vmUnifiedDiff),
      unifiedDiffActive: createSignal(false),
      diffFiles: createSignal(newSeq[VCSDiffFileRow]()),
      selectedHunks: selectedHunks,
      hunkToolbarVisible: createSignal(false),
      hunkCopyFeedback: createSignal(false),
      loadingMore: createSignal(false),
      fileCount: fileCount,
      selectedHunkCount: selectedHunkCount,
      disposeProc: dispose,
    )
