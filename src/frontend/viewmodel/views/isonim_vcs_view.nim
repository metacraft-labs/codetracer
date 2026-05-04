## IsoNim DOM view for the VCS / DeepReview changed-files panel.
##
## The view preserves the legacy selector/class surface used by the VCS CSS:
## ``component-container vcs-container``, ``vcs-branch-picker``,
## ``vcs-commit-history``, ``vcs-changed-files``, and the DeepReview unified
## diff classes used by hunk selection.

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
  of "A": "vcs-status-added"
  of "D": "vcs-status-deleted"
  of "M": "vcs-status-modified"
  else: "vcs-status-other"

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
  of "added": "deepreview-unified-line deepreview-line-added"
  of "removed": "deepreview-unified-line deepreview-line-removed"
  else: "deepreview-unified-line deepreview-line-context"

proc fileStatsText*(additions, deletions: int): string =
  if additions == 0 and deletions == 0:
    ""
  else:
    "+" & $additions & " -" & $deletions

proc hunkHeaderText*(hunk: VCSHunkRow): string =
  fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@"

proc hunkToolbarText*(count: int): string =
  $count & " hunk" & (if count == 1: "" else: "s") & " selected"

proc appendStatus(r: MockRenderer; parent: MockNode; status: string) =
  let cls = "vcs-file-status " & statusClass(status)
  let statusLocal = status
  let node = ui(r):
    span(class = cls):
      text statusLocal
  r.appendChild(parent, node)

proc appendFileStats(r: MockRenderer; parent: MockNode; additions, deletions: int) =
  if additions == 0 and deletions == 0:
    return
  let stats = ui(r):
    span(class = "vcs-file-stats"):
      if additions > 0:
        span(class = "vcs-stat-added"):
          text "+" & $additions
      if deletions > 0:
        span(class = "vcs-stat-deleted"):
          text "-" & $deletions
  r.appendChild(parent, stats)

proc renderBranchPickerMock(r: MockRenderer; vm: VCSVM;
                            callbacks: VCSCallbacks): MockNode =
  let panel = ui(r):
    tdiv(class = "vcs-branch-picker"):
      tdiv(class = "vcs-branch-current",
           onclick = proc() =
             if callbacks.onToggleBranchDropdown != nil:
               callbacks.onToggleBranchDropdown()
             else:
               vm.branchDropdownOpen.val = not vm.branchDropdownOpen.val):
        span(class = "vcs-branch-icon"):
          text vm.headerIcon.val
        span(class = "vcs-branch-name"):
          text vm.currentBranch.val
        span(class = "vcs-branch-arrow"):
          text (if vm.branchDropdownOpen.val: "^" else: "v")
  if vm.branchDropdownOpen.val:
    let dropdown = ui(r):
      tdiv(class = "vcs-branch-dropdown"):
        discard
    for branch in vm.branches.val:
      let branchLocal = branch
      let row = ui(r):
        tdiv(class = "vcs-branch-option",
             onclick = proc() =
               if callbacks.onCheckoutBranch != nil:
                 callbacks.onCheckoutBranch(branchLocal)):
          if branchLocal == vm.currentBranch.val:
            span(class = "vcs-branch-active-marker"):
              text "* "
          text branchLocal
      r.appendChild(dropdown, row)
    r.appendChild(panel, dropdown)
  panel

proc renderHeaderMock(r: MockRenderer; vm: VCSVM): MockNode =
  ui(r):
    tdiv(class = "vcs-branch-picker"):
      tdiv(class = "vcs-branch-current"):
        span(class = "vcs-branch-icon"):
          text vm.headerIcon.val
        span(class = "vcs-branch-name"):
          text vm.headerTitle.val

proc renderCommitHistoryMock(r: MockRenderer; vm: VCSVM;
                             callbacks: VCSCallbacks): MockNode =
  let panel = ui(r):
    tdiv(class = "vcs-commit-history"):
      tdiv(class = "vcs-section-header"):
        text "Commits"
      tdiv(class = "vcs-commit-list"):
        discard
  let list = panel.children[1]
  for i, commit in vm.commits.val:
    let index = i
    let row = ui(r):
      tdiv(class = commitRowClass(i == vm.selectedCommitIndex.val),
           onclick = proc() =
             if callbacks.onSelectCommit != nil:
               callbacks.onSelectCommit(index)
             else:
               vm.selectedCommitIndex.val = index):
        span(class = "vcs-commit-hash"):
          text commit.hash
        span(class = "vcs-commit-message"):
          text commit.message
        span(class = "vcs-commit-time"):
          text commit.relativeTime
    r.appendChild(list, row)
  panel

proc renderChangedFilesMock(r: MockRenderer; vm: VCSVM;
                            callbacks: VCSCallbacks): MockNode =
  let headerText =
    if vm.deepReviewMode.val:
      " (" & $vm.fileCount.val & " files)"
    elif vm.selectedCommitIndex.val >= 0 and
         vm.selectedCommitIndex.val < vm.commits.val.len:
      " (" & vm.commits.val[vm.selectedCommitIndex.val].hash & ")"
    else:
      ""
  let panel = ui(r):
    tdiv(class = "vcs-changed-files"):
      tdiv(class = "vcs-section-header"):
        text "Changed Files"
        span(class = "vcs-changed-files-commit"):
          text headerText
      tdiv(class = "vcs-file-list"):
        discard
  let list = panel.children[1]
  if vm.changedFiles.val.len == 0:
    let empty = ui(r):
      tdiv(class = "vcs-no-files"):
        text VCSNoFilesText
    r.appendChild(list, empty)
  else:
    for i, file in vm.changedFiles.val:
      let index = i
      let path = file.path
      let row = ui(r):
        tdiv(class = fileRowClass(file.selected),
             onclick = proc() =
               if callbacks.onSelectFile != nil:
                 callbacks.onSelectFile(index, path)):
          discard
      appendStatus(r, row, file.status)
      let name = ui(r):
        span(class = "vcs-file-name"):
          text file.baseName
      r.appendChild(row, name)
      appendFileStats(r, row, file.additions, file.deletions)
      if file.coverageText.len > 0:
        let coverage = ui(r):
          span(class = "vcs-file-coverage"):
            text file.coverageText
        r.appendChild(row, coverage)
      r.appendChild(list, row)
  panel

proc renderHunkToolbarMock(r: MockRenderer; vm: VCSVM;
                           callbacks: VCSCallbacks): MockNode =
  if not vm.hunkToolbarVisible.val or vm.selectedHunkCount.val == 0:
    return ui(r): tdiv()
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

proc renderUnifiedDiffMock(r: MockRenderer; vm: VCSVM;
                           callbacks: VCSCallbacks): MockNode =
  let panel = ui(r):
    tdiv(class = "deepreview-unified-diff"):
      discard
  r.appendChild(panel, renderHunkToolbarMock(r, vm, callbacks))
  if vm.diffFiles.val.len == 0:
    let empty = ui(r):
      tdiv(class = "deepreview-unified-empty"):
        text VCSNoDiffText
    r.appendChild(panel, empty)
    return panel
  for file in vm.diffFiles.val:
    let fileStatus = file.status
    let filePath = file.path
    let fileStats = fileStatsText(file.additions, file.deletions)
    let fileIndexForRows = file.fileIndex
    let fileNode = ui(r):
      tdiv(class = "deepreview-unified-file"):
        tdiv(class = "deepreview-unified-file-header"):
          span(class = "deepreview-diff-status"):
            text fileStatus
          span(class = "deepreview-unified-file-path"):
            text filePath
          span(class = "deepreview-unified-file-stats"):
            text fileStats
    for hunkIdx, hunk in file.hunks:
      let fileIndex = fileIndexForRows
      let hidx = hunkIdx
      let hunkSelected = hunk.selected
      let hunkHeader = hunkHeaderText(hunk)
      let hunkNode = ui(r):
        tdiv(class = hunkClass(hunkSelected)):
          tdiv(class = "deepreview-unified-hunk-header hunk-header-selectable",
               onclick = proc() =
                 if callbacks.onSelectHunk != nil:
                   callbacks.onSelectHunk(fileIndex, hidx, false, false)):
            if hunkSelected:
              span(class = "hunk-selection-indicator"):
                text "v"
            text hunkHeader
      for line in hunk.lines:
        let oldText = if line.oldLine > 0: $line.oldLine else: ""
        let newText = if line.newLine > 0: $line.newLine else: ""
        let lineClass = diffLineClass(line.lineType)
        let lineContent = line.content
        let prefix = case line.lineType
          of "added": "+"
          of "removed": "-"
          else: " "
        let lineNode = ui(r):
          tdiv(class = lineClass):
            span(class = "deepreview-unified-line-old"):
              text oldText
            span(class = "deepreview-unified-line-new"):
              text newText
            span(class = "deepreview-unified-line-prefix"):
              text prefix
            span(class = "deepreview-unified-line-content"):
              text lineContent
        r.appendChild(hunkNode, lineNode)
      r.appendChild(fileNode, hunkNode)
    r.appendChild(panel, fileNode)
  panel

proc renderVCSPanel*(r: MockRenderer; vm: VCSVM;
                     callbacks: VCSCallbacks = VCSCallbacks()): MockNode =
  var body: MockNode
  let panel = ui(r):
    tdiv(class = VCSContainerClass):
      tdiv(ref = body, class = "vcs-panel-body"):
        discard

  createRenderEffect proc() =
    r.clearChildren(body)
    if vm.deepReviewMode.val:
      r.appendChild(body, renderHeaderMock(r, vm))
      r.appendChild(body, renderChangedFilesMock(r, vm, callbacks))
    elif not vm.isGitRepo.val:
      let noRepo = ui(r):
        tdiv(class = VCSNoRepoClass):
          tdiv(class = "vcs-no-repo-icon"):
            text vm.headerIcon.val
          tdiv(class = "vcs-no-repo-message"):
            text vm.errorMessage.val
      r.appendChild(body, noRepo)
    else:
      r.appendChild(body, renderBranchPickerMock(r, vm, callbacks))
      let toggle = ui(r):
        tdiv(class = "vcs-diff-toggle"):
          tdiv(class = toggleButtonClass(vm.unifiedDiffActive.val),
               onclick = proc() =
                 if callbacks.onToggleUnifiedDiff != nil:
                   callbacks.onToggleUnifiedDiff()
                 else:
                   vm.unifiedDiffActive.val = not vm.unifiedDiffActive.val):
            text "Unified Diff"
      r.appendChild(body, toggle)
      if vm.unifiedDiffActive.val:
        r.appendChild(body, renderUnifiedDiffMock(r, vm, callbacks))
      else:
        r.appendChild(body, renderCommitHistoryMock(r, vm, callbacks))
        r.appendChild(body, renderChangedFilesMock(r, vm, callbacks))
      let refresh = ui(r):
        tdiv(class = "vcs-refresh",
             onclick = proc() =
               if callbacks.onRefresh != nil:
                 callbacks.onRefresh()):
          text "Refresh"
      r.appendChild(body, refresh)
  panel

when defined(js):
  proc renderVCSPanel*(r: WebRenderer; vm: VCSVM;
                       callbacks: VCSCallbacks = VCSCallbacks()):
                       isonim_dom.Element =
    var body: isonim_dom.Element
    let panel = ui(r):
      tdiv(class = VCSContainerClass):
        tdiv(ref = body, class = "vcs-panel-body"):
          discard

    createRenderEffect proc() =
      let deepReviewMode = vm.deepReviewMode.val
      let isRepo = vm.isGitRepo.val
      let errorMessage = cstring(vm.errorMessage.val)
      let icon = cstring(vm.headerIcon.val)
      let headerTitle = cstring(vm.headerTitle.val)
      let currentBranch = cstring(vm.currentBranch.val)
      let branchOpen = vm.branchDropdownOpen.val
      let unifiedActive = vm.unifiedDiffActive.val
      let selectedCommit = vm.selectedCommitIndex.val
      let fileCount = vm.fileCount.val
      let hunkCount = vm.selectedHunkCount.val
      let hunkVisible = vm.hunkToolbarVisible.val
      let hunkCopied = vm.hunkCopyFeedback.val
      {.emit: """
        const body = `body`;
        body.innerHTML = '';
        const make = (tag, cls, text) => {
          const el = document.createElement(tag);
          if (cls) el.className = cls;
          if (text !== undefined && text !== null) el.textContent = text;
          return el;
        };
        const statusClass = (status) => {
          if (status === 'A') return 'vcs-status-added';
          if (status === 'D') return 'vcs-status-deleted';
          if (status === 'M') return 'vcs-status-modified';
          return 'vcs-status-other';
        };
        const fileRowClass = (selected) =>
          selected ? 'vcs-file-item vcs-file-selected' : 'vcs-file-item';
        const branchPicker = (title, clickable) => {
          const picker = make('div', 'vcs-branch-picker');
          const current = make('div', 'vcs-branch-current');
          if (clickable) current.addEventListener('click', () => {
            if (`callbacks`.onToggleBranchDropdown) `callbacks`.onToggleBranchDropdown();
          });
          current.appendChild(make('span', 'vcs-branch-icon', `icon`));
          current.appendChild(make('span', 'vcs-branch-name', title));
          if (clickable) current.appendChild(make('span', 'vcs-branch-arrow', `branchOpen` ? '^' : 'v'));
          picker.appendChild(current);
          return picker;
        };
        const changedFilesShell = (headerText) => {
          const root = make('div', 'vcs-changed-files');
          const header = make('div', 'vcs-section-header', 'Changed Files');
          header.appendChild(make('span', 'vcs-changed-files-commit', headerText));
          root.appendChild(header);
          const list = make('div', 'vcs-file-list');
          root.appendChild(list);
          return [root, list];
        };
        if (`deepReviewMode`) {
          body.appendChild(branchPicker(`headerTitle`, false));
        } else if (!`isRepo`) {
          const noRepo = make('div', 'vcs-no-repo');
          noRepo.appendChild(make('div', 'vcs-no-repo-icon', `icon`));
          noRepo.appendChild(make('div', 'vcs-no-repo-message', `errorMessage`));
          body.appendChild(noRepo);
        } else {
          body.appendChild(branchPicker(`currentBranch`, true));
          if (`branchOpen`) {
            const dropdown = make('div', 'vcs-branch-dropdown');
            body.querySelector('.vcs-branch-picker').appendChild(dropdown);
          }
          const diffToggle = make('div', 'vcs-diff-toggle');
          const toggle = make('div', `unifiedActive` ? 'vcs-toggle-button vcs-toggle-active' : 'vcs-toggle-button', 'Unified Diff');
          toggle.addEventListener('click', () => {
            if (`callbacks`.onToggleUnifiedDiff) `callbacks`.onToggleUnifiedDiff();
          });
          diffToggle.appendChild(toggle);
          body.appendChild(diffToggle);
        }
      """.}

      for branch in vm.branches.val:
        let branchLocal = cstring(branch)
        let active = branch == vm.currentBranch.val
        {.emit: """
          const dropdown = body.querySelector('.vcs-branch-dropdown');
          if (dropdown) {
            const row = make('div', 'vcs-branch-option');
            const branchName = `branchLocal`;
            row.addEventListener('click', () => {
              if (`callbacks`.onCheckoutBranch) `callbacks`.onCheckoutBranch(branchName);
            });
            if (`active`) row.appendChild(make('span', 'vcs-branch-active-marker', '* '));
            row.appendChild(document.createTextNode(branchName));
            dropdown.appendChild(row);
          }
        """.}

      if deepReviewMode:
        {.emit: """
          const [root, list] = changedFilesShell(' (' + `fileCount` + ' files)');
          body.appendChild(root);
        """.}
      elif isRepo and not unifiedActive:
        {.emit: """
          const history = make('div', 'vcs-commit-history');
          history.appendChild(make('div', 'vcs-section-header', 'Commits'));
          const commitList = make('div', 'vcs-commit-list');
          history.appendChild(commitList);
          body.appendChild(history);
        """.}
        for i, commit in vm.commits.val:
          let idx = i
          let hash = cstring(commit.hash)
          let message = cstring(commit.message)
          let relativeTime = cstring(commit.relativeTime)
          let rowClass = cstring(commitRowClass(i == selectedCommit))
          {.emit: """
            const list = body.querySelector('.vcs-commit-list');
            if (list) {
              const row = make('div', `rowClass`);
              const commitIndex = `idx`;
              row.addEventListener('click', () => {
                if (`callbacks`.onSelectCommit) `callbacks`.onSelectCommit(commitIndex);
              });
              row.appendChild(make('span', 'vcs-commit-hash', `hash`));
              row.appendChild(make('span', 'vcs-commit-message', `message`));
              row.appendChild(make('span', 'vcs-commit-time', `relativeTime`));
              list.appendChild(row);
            }
          """.}
        let headerText =
          if selectedCommit >= 0 and selectedCommit < vm.commits.val.len:
            cstring(" (" & vm.commits.val[selectedCommit].hash & ")")
          else:
            cstring""
        {.emit: """
          const [root, list] = changedFilesShell(`headerText`);
          body.appendChild(root);
        """.}
      elif isRepo and unifiedActive:
        {.emit: """
          const diff = make('div', 'deepreview-unified-diff');
          body.appendChild(diff);
          if (`hunkVisible` && `hunkCount` > 0) {
            const toolbar = make('div', 'hunk-toolbar');
            toolbar.appendChild(make('span', 'hunk-toolbar-count',
              String(`hunkCount`) + ' hunk' + (`hunkCount` === 1 ? '' : 's') + ' selected'));
            const actions = make('div', 'hunk-toolbar-actions');
            const copy = make('div', 'hunk-toolbar-button', `hunkCopied` ? 'Copied!' : 'Copy as patch');
            copy.addEventListener('click', () => {
              if (`callbacks`.onCopySelectedHunks) `callbacks`.onCopySelectedHunks();
            });
            const stage = make('div', 'hunk-toolbar-button', 'Stage hunks');
            stage.addEventListener('click', () => {
              if (`callbacks`.onStageSelectedHunks) `callbacks`.onStageSelectedHunks();
            });
            const clear = make('div', 'hunk-toolbar-button hunk-toolbar-button-subtle', 'Clear');
            clear.addEventListener('click', () => {
              if (`callbacks`.onClearSelectedHunks) `callbacks`.onClearSelectedHunks();
            });
            actions.appendChild(copy); actions.appendChild(stage); actions.appendChild(clear);
            toolbar.appendChild(actions);
            diff.appendChild(toolbar);
          }
        """.}

      for i, file in vm.changedFiles.val:
        let index = i
        let status = cstring(file.status)
        let name = cstring(file.baseName)
        let path = cstring(file.path)
        let rowClass = cstring(fileRowClass(file.selected))
        let additions = file.additions
        let deletions = file.deletions
        let coverage = cstring(file.coverageText)
        {.emit: """
          const list = body.querySelector('.vcs-file-list');
          if (list) {
            const row = make('div', `rowClass`);
            const fileIndex = `index`;
            const filePath = `path`;
            row.addEventListener('click', () => {
              if (`deepReviewMode`) {
                list.querySelectorAll('.vcs-file-item').forEach((item) => {
                  item.classList.remove('vcs-file-selected');
                });
                row.classList.add('vcs-file-selected');
              }
              if (`callbacks`.onSelectFile) `callbacks`.onSelectFile(fileIndex, filePath);
            });
            row.appendChild(make('span', 'vcs-file-status ' + statusClass(`status`), `status`));
            row.appendChild(make('span', 'vcs-file-name', `name`));
            if (`additions` > 0 || `deletions` > 0) {
              const stats = make('span', 'vcs-file-stats');
              if (`additions` > 0) stats.appendChild(make('span', 'vcs-stat-added', '+' + `additions`));
              if (`deletions` > 0) stats.appendChild(make('span', 'vcs-stat-deleted', '-' + `deletions`));
              row.appendChild(stats);
            }
            const coverageText = `coverage` || '';
            if (coverageText.length > 0) row.appendChild(make('span', 'vcs-file-coverage', coverageText));
            list.appendChild(row);
          }
        """.}

      if vm.changedFiles.val.len == 0 and (deepReviewMode or (isRepo and not unifiedActive)):
        {.emit: """
          const list = body.querySelector('.vcs-file-list');
          if (list) list.appendChild(make('div', 'vcs-no-files', 'No changed files'));
        """.}

      if isRepo and unifiedActive:
        if vm.diffFiles.val.len == 0:
          {.emit: """
            const diff = body.querySelector('.deepreview-unified-diff');
            if (diff) diff.appendChild(make('div', 'deepreview-unified-empty', 'No working tree changes.'));
          """.}
        for file in vm.diffFiles.val:
          let fileIndex = file.fileIndex
          let path = cstring(file.path)
          let status = cstring(file.status)
          let stats = cstring(fileStatsText(file.additions, file.deletions))
          {.emit: """
            const diff = body.querySelector('.deepreview-unified-diff');
            if (diff) {
              const fileEl = make('div', 'deepreview-unified-file');
              fileEl.setAttribute('data-file-index', String(`fileIndex`));
              const header = make('div', 'deepreview-unified-file-header');
              header.appendChild(make('span', 'deepreview-diff-status', `status`));
              header.appendChild(make('span', 'deepreview-unified-file-path', `path`));
              if (`stats`.length > 0) header.appendChild(make('span', 'deepreview-unified-file-stats', `stats`));
              fileEl.appendChild(header);
              diff.appendChild(fileEl);
            }
          """.}
          for hunkIdx, hunk in file.hunks:
            let hidx = hunkIdx
            let headerText = cstring(hunkHeaderText(hunk))
            let hunkCls = cstring(hunkClass(hunk.selected))
            let selected = hunk.selected
            {.emit: """
              const fileEl = body.querySelector('.deepreview-unified-file[data-file-index="' + `fileIndex` + '"]');
              if (fileEl) {
                const hunk = make('div', `hunkCls`);
                const header = make('div', 'deepreview-unified-hunk-header hunk-header-selectable');
                const selectedFileIndex = `fileIndex`;
                const selectedHunkIndex = `hidx`;
                if (`selected`) header.appendChild(make('span', 'hunk-selection-indicator', 'v'));
                header.appendChild(document.createTextNode(`headerText`));
                header.addEventListener('click', (ev) => {
                  if (`callbacks`.onSelectHunk) {
                    `callbacks`.onSelectHunk(selectedFileIndex, selectedHunkIndex, !!ev.shiftKey, !!(ev.ctrlKey || ev.metaKey));
                  }
                  ev.preventDefault();
                });
                hunk.appendChild(header);
                fileEl.appendChild(hunk);
              }
            """.}
            for line in hunk.lines:
              let cls = cstring(diffLineClass(line.lineType))
              let content = cstring(line.content)
              let oldText = if line.oldLine > 0: cstring($line.oldLine) else: cstring""
              let newText = if line.newLine > 0: cstring($line.newLine) else: cstring""
              let prefix = case line.lineType
                of "added": cstring"+"
                of "removed": cstring"-"
                else: cstring" "
              {.emit: """
                const hunks = body.querySelectorAll('.deepreview-unified-file[data-file-index="' + `fileIndex` + '"] .deepreview-unified-hunk');
                const hunk = hunks[hunks.length - 1];
                if (hunk) {
                  const row = make('div', `cls`);
                  row.appendChild(make('span', 'deepreview-unified-line-old', `oldText`));
                  row.appendChild(make('span', 'deepreview-unified-line-new', `newText`));
                  row.appendChild(make('span', 'deepreview-unified-line-prefix', `prefix`));
                  row.appendChild(make('span', 'deepreview-unified-line-content', `content`));
                  hunk.appendChild(row);
                }
              """.}

      if isRepo and not deepReviewMode:
        {.emit: """
          const refresh = make('div', 'vcs-refresh', 'Refresh');
          refresh.addEventListener('click', () => {
            if (`callbacks`.onRefresh) `callbacks`.onRefresh();
          });
          body.appendChild(refresh);
        """.}

    panel

  proc mountIsoNimVCSPanel*(container: isonim_dom.Element; vm: VCSVM;
                            callbacks: VCSCallbacks = VCSCallbacks()) =
    let r = WebRenderer()
    let panel = renderVCSPanel(r, vm, callbacks)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
