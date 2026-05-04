## ViewModel for the VCS / DeepReview changed-files panel.
##
## The legacy ``VCSComponent`` still owns git subprocess calls, file watching,
## hunk patch actions, and cross-panel DeepReview selection.  This VM carries
## the flat render snapshot consumed by the IsoNim VCS view.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

type
  VCSCommitRow* = object
    hash*: string
    message*: string
    relativeTime*: string

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
    selectedCommitIndex*: Signal[int]
    changedFiles*: Signal[seq[VCSFileRow]]
    unifiedDiffActive*: Signal[bool]
    diffFiles*: Signal[seq[VCSDiffFileRow]]
    selectedHunks*: Signal[seq[(int, int)]]
    hunkToolbarVisible*: Signal[bool]
    hunkCopyFeedback*: Signal[bool]

    fileCount*: Memo[int]
    selectedHunkCount*: Memo[int]

proc `==`*(a, b: VCSCommitRow): bool {.noSideEffect.} =
  a.hash == b.hash and a.message == b.message and
    a.relativeTime == b.relativeTime

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
                 selectedIndex: int) =
  vm.commits.val = @commits
  if commits.len == 0:
    vm.selectedCommitIndex.val = -1
  elif selectedIndex < 0:
    vm.selectedCommitIndex.val = 0
  elif selectedIndex >= commits.len:
    vm.selectedCommitIndex.val = commits.len - 1
  else:
    vm.selectedCommitIndex.val = selectedIndex

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
  vm.selectedCommitIndex.val = -1
  vm.changedFiles.val = @[]
  vm.unifiedDiffActive.val = false
  vm.diffFiles.val = @[]
  vm.selectedHunks.val = @[]
  vm.hunkToolbarVisible.val = false
  vm.hunkCopyFeedback.val = false

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
      selectedCommitIndex: createSignal(-1),
      changedFiles: changedFiles,
      unifiedDiffActive: createSignal(false),
      diffFiles: createSignal(newSeq[VCSDiffFileRow]()),
      selectedHunks: selectedHunks,
      hunkToolbarVisible: createSignal(false),
      hunkCopyFeedback: createSignal(false),
      fileCount: fileCount,
      selectedHunkCount: selectedHunkCount,
      disposeProc: dispose,
    )
