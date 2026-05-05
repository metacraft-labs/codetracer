## IsoNim DOM view for the VCS / DeepReview changed-files panel.

import std/strformat

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/vcs_vm

const VCSContainerClass* = "component-container vcs-container"
const VCSNoRepoClass* = "vcs-no-repo"
const VCSNoFilesText* = "No changed files"
const VCSNoDiffText* = "No working tree changes."

type
  VCSCallbacks* = object
    onToggleBranchDropdown*: proc()
    onCheckoutBranch*: proc(branch: string)
    onSelectCommit*: proc(index: int)
    onSelectFile*: proc(index: int; path: string)
    onToggleUnifiedDiff*: proc()
    onRefresh*: proc()
    onSelectHunk*: proc(fileIdx, hunkIdx: int; shiftKey, ctrlKey: bool)
    onCopySelectedHunks*: proc()
    onStageSelectedHunks*: proc()
    onClearSelectedHunks*: proc()

proc statusClass*(status: string): string =
  case status
  of "A", "added": "vcs-status-added"
  of "D", "deleted": "vcs-status-deleted"
  of "M", "modified": "vcs-status-modified"
  else: "vcs-status-other"

proc diffStatusClass*(status: string): string =
  case status
  of "A", "added": "deepreview-diff-status deepreview-diff-added"
  of "D", "deleted": "deepreview-diff-status deepreview-diff-deleted"
  of "M", "modified": "deepreview-diff-status deepreview-diff-modified"
  else: "deepreview-diff-status"

proc statusLabel*(status: string): string =
  case status
  of "added": "A"
  of "deleted": "D"
  of "modified": "M"
  else: status

proc commitRowClass*(selected: bool): string =
  if selected: "vcs-commit-item vcs-commit-selected" else: "vcs-commit-item"

proc fileRowClass*(selected: bool): string =
  if selected: "vcs-file-item vcs-file-selected" else: "vcs-file-item"

proc toggleButtonClass*(active: bool): string =
  if active: "vcs-toggle-button vcs-toggle-active" else: "vcs-toggle-button"

proc hunkClass*(selected: bool): string =
  if selected: "deepreview-unified-hunk hunk-selected"
  else: "deepreview-unified-hunk"

proc diffLineClass*(lineType: string): string =
  case lineType
  of "added": "deepreview-unified-line deepreview-unified-line-added"
  of "removed": "deepreview-unified-line deepreview-unified-line-removed"
  else: "deepreview-unified-line deepreview-unified-line-context"

proc fileStatsText*(additions, deletions: int): string =
  if additions == 0 and deletions == 0:
    ""
  else:
    "+" & $additions & " -" & $deletions

proc hunkHeaderText*(hunk: VCSHunkRow): string =
  fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@"

proc hunkToolbarText*(count: int): string =
  $count & " hunk" & (if count == 1: "" else: "s") & " selected"

proc invokeToggleBranchDropdown(vm: VCSVM; callbacks: VCSCallbacks) =
  if callbacks.onToggleBranchDropdown != nil:
    callbacks.onToggleBranchDropdown()
  else:
    vm.branchDropdownOpen.val = not vm.branchDropdownOpen.val

proc invokeCheckoutBranch(callbacks: VCSCallbacks; branch: string) =
  if callbacks.onCheckoutBranch != nil:
    callbacks.onCheckoutBranch(branch)

proc invokeSelectCommit(vm: VCSVM; callbacks: VCSCallbacks; index: int) =
  if callbacks.onSelectCommit != nil:
    callbacks.onSelectCommit(index)
  else:
    vm.selectedCommitIndex.val = index

proc invokeSelectFile(callbacks: VCSCallbacks; index: int; path: string) =
  if callbacks.onSelectFile != nil:
    callbacks.onSelectFile(index, path)

proc invokeToggleUnifiedDiff(vm: VCSVM; callbacks: VCSCallbacks) =
  if callbacks.onToggleUnifiedDiff != nil:
    callbacks.onToggleUnifiedDiff()
  else:
    vm.unifiedDiffActive.val = not vm.unifiedDiffActive.val

proc invokeRefresh(callbacks: VCSCallbacks) =
  if callbacks.onRefresh != nil:
    callbacks.onRefresh()

proc invokeSelectHunk(callbacks: VCSCallbacks; fileIdx, hunkIdx: int;
                      shiftKey, ctrlKey: bool) =
  if callbacks.onSelectHunk != nil:
    callbacks.onSelectHunk(fileIdx, hunkIdx, shiftKey, ctrlKey)

proc appendRenderedChild(r: MockRenderer; host, child: MockNode) =
  ## Stable dynamic hosts receive finished IsoNim row nodes.
  r.appendChild(host, child)

when defined(js):
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}

  proc appendRenderedChild(r: WebRenderer; host, child: isonim_dom.Element) =
    ## Stable dynamic hosts receive finished IsoNim row nodes.
    r.appendChild(host, child)

proc attachHunkClick(r: MockRenderer; header: MockNode; callbacks: VCSCallbacks;
                     fileIdx, hunkIdx: int) =
  r.addEventListener(header, "click", proc() =
    callbacks.invokeSelectHunk(fileIdx, hunkIdx, false, false))

when defined(js):
  proc attachHunkClick(r: WebRenderer; header: isonim_dom.Element;
                       callbacks: VCSCallbacks; fileIdx, hunkIdx: int) =
    ## Web hunk selection needs Shift/Ctrl/Meta from the native click event;
    ## WebRenderer's declarative handler only exposes proc().
    isonim_dom.addEventListener(isonim_dom.Node(header), cstring"click",
      proc(ev: isonim_dom.Event) =
        var shiftKey: bool
        var ctrlKey: bool
        {.emit: "`shiftKey` = !!`ev`.shiftKey; `ctrlKey` = !!(`ev`.ctrlKey || `ev`.metaKey);".}
        callbacks.invokeSelectHunk(fileIdx, hunkIdx, shiftKey, ctrlKey)
        ev.preventDefault())

proc renderBranchPicker[R](r: R; vm: VCSVM; callbacks: VCSCallbacks): auto =
  ui(r):
    tdiv(class = "vcs-branch-picker"):
      tdiv(class = "vcs-branch-current",
           onclick = proc() = vm.invokeToggleBranchDropdown(callbacks)):
        span(class = "vcs-branch-icon"):
          text vm.headerIcon.val
        span(class = "vcs-branch-name"):
          text vm.currentBranch.val
        span(class = "vcs-branch-arrow"):
          text (if vm.branchDropdownOpen.val: "^" else: "v")
      if vm.branchDropdownOpen.val:
        tdiv(class = "vcs-branch-dropdown"):
          for branch in vm.branches.val:
            let branchLocal = branch
            tdiv(class = "vcs-branch-option",
                 onclick = proc() =
                   callbacks.invokeCheckoutBranch(branchLocal)):
              if branchLocal == vm.currentBranch.val:
                span(class = "vcs-branch-active-marker"):
                  text "* "
              text branchLocal

proc renderHeader[R](r: R; vm: VCSVM): auto =
  ui(r):
    tdiv(class = "vcs-branch-picker"):
      tdiv(class = "vcs-branch-current"):
        span(class = "vcs-branch-icon"):
          text vm.headerIcon.val
        span(class = "vcs-branch-name"):
          text vm.headerTitle.val

proc renderNoRepo[R](r: R; vm: VCSVM): auto =
  ui(r):
    tdiv(class = VCSNoRepoClass):
      tdiv(class = "vcs-no-repo-icon"):
        text vm.headerIcon.val
      tdiv(class = "vcs-no-repo-message"):
        text vm.errorMessage.val

proc renderCommitHistory[R](r: R; vm: VCSVM;
                            callbacks: VCSCallbacks): auto =
  var list: typeof(r.createElement("div"))
  let panel = ui(r):
    tdiv(class = "vcs-commit-history"):
      tdiv(class = "vcs-section-header"):
        text "Commits"
      tdiv(ref = list, class = "vcs-commit-list")
  for i, commit in vm.commits.val:
    let index = i
    let row = ui(r):
      tdiv(class = commitRowClass(i == vm.selectedCommitIndex.val),
           onclick = proc() =
             vm.invokeSelectCommit(callbacks, index)):
        span(class = "vcs-commit-hash"):
          text commit.hash
        span(class = "vcs-commit-message"):
          text commit.message
        span(class = "vcs-commit-time"):
          text commit.relativeTime
    r.appendRenderedChild(list, row)
  panel

proc changedFilesHeaderText(vm: VCSVM): string =
  if vm.deepReviewMode.val:
    " (" & $vm.fileCount.val & " files)"
  elif vm.selectedCommitIndex.val >= 0 and
       vm.selectedCommitIndex.val < vm.commits.val.len:
    " (" & vm.commits.val[vm.selectedCommitIndex.val].hash & ")"
  else:
    ""

proc renderChangedFiles[R](r: R; vm: VCSVM;
                           callbacks: VCSCallbacks): auto =
  var list: typeof(r.createElement("div"))
  let panel = ui(r):
    tdiv(class = "vcs-changed-files"):
      tdiv(class = "vcs-section-header"):
        text "Changed Files"
        span(class = "vcs-changed-files-commit"):
          text changedFilesHeaderText(vm)
      tdiv(ref = list, class = "vcs-file-list")
  if vm.changedFiles.val.len == 0:
    let empty = ui(r):
      tdiv(class = "vcs-no-files"):
        text VCSNoFilesText
    r.appendRenderedChild(list, empty)
  else:
    for i, file in vm.changedFiles.val:
      let index = i
      let path = file.path
      let row = ui(r):
        tdiv(class = fileRowClass(file.selected),
             onclick = proc() =
               callbacks.invokeSelectFile(index, path)):
          span(class = "vcs-file-status " & statusClass(file.status)):
            text statusLabel(file.status)
          span(class = "vcs-file-name"):
            text file.baseName
          if file.additions > 0 or file.deletions > 0:
            span(class = "vcs-file-stats"):
              if file.additions > 0:
                span(class = "vcs-stat-added"):
                  text "+" & $file.additions
              if file.deletions > 0:
                span(class = "vcs-stat-deleted"):
                  text "-" & $file.deletions
          if file.coverageText.len > 0:
            span(class = "vcs-file-coverage"):
              text file.coverageText
      r.appendRenderedChild(list, row)
  panel

proc renderHunkToolbar[R](r: R; vm: VCSVM;
                          callbacks: VCSCallbacks): auto =
  ui(r):
    tdiv(class = "hunk-toolbar"):
      span(class = "hunk-toolbar-count"):
        text hunkToolbarText(vm.selectedHunkCount.val)
      tdiv(class = "hunk-toolbar-actions"):
        tdiv(class = "hunk-toolbar-button",
             onclick = proc() =
               if callbacks.onCopySelectedHunks != nil:
                 callbacks.onCopySelectedHunks()):
          text (if vm.hunkCopyFeedback.val: "Copied!" else: "Copy as patch")
        tdiv(class = "hunk-toolbar-button",
             onclick = proc() =
               if callbacks.onStageSelectedHunks != nil:
                 callbacks.onStageSelectedHunks()):
          text "Stage hunks"
        tdiv(class = "hunk-toolbar-button hunk-toolbar-button-subtle",
             onclick = proc() =
               if callbacks.onClearSelectedHunks != nil:
                 callbacks.onClearSelectedHunks()):
          text "Clear"

proc renderDiffLine[R](r: R; line: VCSDiffLineRow): auto =
  let oldText = if line.oldLine > 0: $line.oldLine else: ""
  let newText = if line.newLine > 0: $line.newLine else: ""
  let prefix = case line.lineType
    of "added": "+"
    of "removed": "-"
    else: " "
  ui(r):
    tdiv(class = diffLineClass(line.lineType)):
      span(class = "deepreview-unified-gutter-old"):
        text oldText
      span(class = "deepreview-unified-gutter-new"):
        text newText
      span(class = "deepreview-unified-line-prefix"):
        text prefix
      span(class = "deepreview-unified-line-content"):
        text line.content

proc renderDiffHunk[R](r: R; fileIndex, hunkIdx: int; hunk: VCSHunkRow;
                       callbacks: VCSCallbacks): auto =
  var header: typeof(r.createElement("div"))
  let node = ui(r):
    tdiv(class = hunkClass(hunk.selected)):
      tdiv(ref = header,
           class = "deepreview-unified-hunk-header hunk-header-selectable"):
        if hunk.selected:
          span(class = "hunk-selection-indicator"):
            text "v"
        text hunkHeaderText(hunk)
  for line in hunk.lines:
    r.appendRenderedChild(node, renderDiffLine(r, line))
  r.attachHunkClick(header, callbacks, fileIndex, hunkIdx)
  node

proc renderDiffFile[R](r: R; file: VCSDiffFileRow;
                       callbacks: VCSCallbacks): auto =
  let fileIndex = file.fileIndex
  let stats = fileStatsText(file.additions, file.deletions)
  let node = ui(r):
    tdiv(class = "deepreview-unified-file",
         `data-file-index` = $fileIndex):
      tdiv(class = "deepreview-unified-file-header"):
        span(class = diffStatusClass(file.status)):
          text statusLabel(file.status)
        span(class = "deepreview-unified-file-path"):
          text file.path
        span(class = "deepreview-unified-file-stats"):
          text stats
  for hunkIdx, hunk in file.hunks:
    r.appendRenderedChild(node, renderDiffHunk(r, fileIndex, hunkIdx, hunk,
                                               callbacks))
  node

proc renderUnifiedDiff[R](r: R; vm: VCSVM;
                          callbacks: VCSCallbacks): auto =
  let panel = ui(r):
    tdiv(class = "deepreview-unified-diff")
  if vm.hunkToolbarVisible.val and vm.selectedHunkCount.val > 0:
    r.appendRenderedChild(panel, renderHunkToolbar(r, vm, callbacks))
  if vm.diffFiles.val.len == 0:
    let empty = ui(r):
      tdiv(class = "deepreview-unified-empty"):
        text VCSNoDiffText
    r.appendRenderedChild(panel, empty)
  else:
    for file in vm.diffFiles.val:
      r.appendRenderedChild(panel, renderDiffFile(r, file, callbacks))
  panel

proc renderDiffToggle[R](r: R; vm: VCSVM; callbacks: VCSCallbacks): auto =
  ui(r):
    tdiv(class = "vcs-diff-toggle"):
      tdiv(class = toggleButtonClass(vm.unifiedDiffActive.val),
           onclick = proc() =
             vm.invokeToggleUnifiedDiff(callbacks)):
        text "Unified Diff"

proc renderRefresh[R](r: R; callbacks: VCSCallbacks): auto =
  ui(r):
    tdiv(class = "vcs-refresh",
         onclick = proc() = callbacks.invokeRefresh()):
      text "Refresh"

proc renderVCSPanelImpl[R](r: R; vm: VCSVM;
                           callbacks: VCSCallbacks): auto =
  var body: typeof(r.createElement("div"))
  let panel = ui(r):
    tdiv(class = VCSContainerClass):
      tdiv(ref = body, class = "vcs-panel-body")

  createRenderEffect proc() =
    r.clearChildren(body)
    if vm.deepReviewMode.val:
      r.appendRenderedChild(body, renderHeader(r, vm))
      r.appendRenderedChild(body, renderChangedFiles(r, vm, callbacks))
    elif not vm.isGitRepo.val:
      r.appendRenderedChild(body, renderNoRepo(r, vm))
    else:
      r.appendRenderedChild(body, renderBranchPicker(r, vm, callbacks))
      r.appendRenderedChild(body, renderDiffToggle(r, vm, callbacks))
      if vm.unifiedDiffActive.val:
        r.appendRenderedChild(body, renderUnifiedDiff(r, vm, callbacks))
      else:
        r.appendRenderedChild(body, renderCommitHistory(r, vm, callbacks))
        r.appendRenderedChild(body, renderChangedFiles(r, vm, callbacks))
      r.appendRenderedChild(body, renderRefresh(r, callbacks))

  panel

proc renderVCSPanel*(r: MockRenderer; vm: VCSVM;
                     callbacks: VCSCallbacks = VCSCallbacks()): MockNode =
  renderVCSPanelImpl(r, vm, callbacks)

when defined(js):
  proc renderVCSPanel*(r: WebRenderer; vm: VCSVM;
                       callbacks: VCSCallbacks = VCSCallbacks()):
                       isonim_dom.Element =
    renderVCSPanelImpl(r, vm, callbacks)

  proc mountIsoNimVCSPanel*(container: isonim_dom.Element; vm: VCSVM;
                            callbacks: VCSCallbacks = VCSCallbacks()) =
    let r = WebRenderer()
    let panel = renderVCSPanel(r, vm, callbacks)
    # External mount interop: GoldenLayout owns the container outside this view.
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
