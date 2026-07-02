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

  VCSVM* = ref object of ViewModel
    deepReviewMode*: Signal[bool]
    headerTitle*: Signal[string]
    headerIcon*: Signal[string]
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

proc setDeepReviewMode*(vm: VCSVM; active: bool) =
  vm.deepReviewMode.val = active

proc setHeader*(vm: VCSVM; title: string; icon = "\239\132\166") =
  vm.headerTitle.val = title
  vm.headerIcon.val = icon

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
