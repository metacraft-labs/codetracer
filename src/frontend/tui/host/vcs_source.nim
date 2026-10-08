## tui/host/vcs_source.nim — PLAT-47 deliverable 4. **The terminal's VCS pane
## is filled from the desktop's VCS ViewModel.**
##
## The host half of the pane: it owns a `VCSVM` (the ViewModel the desktop's
## VCS panel draws), fills it through the platform's VCS facade
## (`vcs_vm.refreshFromFacade` — system git, `git status --porcelain=v2
## --branch` read by the same `parsePorcelainV2` the desktop's panel reads
## with) and hands the app layer the value `views/vcs_pane.nim` paints.
##
## WHICH DIRECTORY, AS THE DESKTOP DECIDES IT (`ui/git_cli.gitWorkingDirectory`,
## `index/args.nim`): the project folder in Edit mode, and the process's own
## working directory for a replay — the desktop sets `startOptions.folder` to
## `process.cwd()` when it opens a recording.
##
## Refreshed at open and then every `VcsRefreshMs`, the desktop's own
## `refreshIntervalMs`, so an edit made in another terminal shows up here as it
## does there.

import std/[monotimes, os, times]

import ../../viewmodel/viewmodels/vcs_vm
import ../../viewmodel/platform/vcs
import ../../viewmodel/host/native_vcs
import ../../viewmodel/host/native_vcs_details
import ../app/runtime
import ../app/tui_app
import ../app/views/vcs_pane

import isonim/core/[owner, signals]

const VcsRefreshMs* = VCSRefreshIntervalMs
  ## `ui/vcs.nim`'s `refreshIntervalMs`: the one interval
  ## (`vcs_vm.VCSRefreshIntervalMs`).

type
  VcsSource* = ref object
    vm*: VCSVM
    directory*: string
    facade: VcsFacade
    lastRefresh: MonoTime
    dispose: proc()

proc paneModelOf*(vm: VCSVM): VcsPaneModel =
  ## The shared ViewModel as the pane's value — every field read, nothing
  ## derived that the desktop's view does not also show.
  result = VcsPaneModel(
    loaded: true,
    isRepo: vm.isGitRepo.val,
    message: vm.errorMessage.val,
    branch: vm.currentBranch.val,
    workingTreeTitle: VCSWorkingTreeTitle,
    cleanText: VCSCleanTreeText)
  for f in vm.workingTreeFiles.val:
    result.files.add VcsFileLine(status: f.status, path: f.path)
  for c in vm.commits.val:
    result.commits.add VcsCommitLine(hash: c.hash, subject: c.message)
  # PLAT-50 (K53): the commit a click opened, and its files.
  result.expandedCommit = -1
  let selected = vm.selectedCommitIndices.val
  if selected.len == 1:
    for (index, files) in vm.commitFilesMap.val:
      if index == selected[0]:
        result.expandedCommit = index
        for f in files:
          result.commitFiles.add VcsFileLine(status: f.status, path: f.path)

proc newVcsSource*(directory: string;
                   facade: VcsFacade = nil): VcsSource =
  ## A source for `directory`. `facade` defaults to the system git
  ## (`native_vcs`, the facade the desktop's native instantiation serves).
  result = VcsSource(directory: directory,
                     facade: (if facade.isNil: nativeVcs(NativeVcsProfile)
                              else: facade))
  let src = result
  createRoot proc(dispose: proc()) =
    src.vm = createVCSVM()
    src.dispose = dispose

proc refresh*(s: VcsSource; rt: TuiRuntime) =
  ## Read the repository now and publish the pane's value.
  if s.isNil:
    return
  s.vm.refreshFromFacade(s.facade, s.directory)
  s.lastRefresh = getMonoTime()
  rt.app.vcs = paneModelOf(s.vm)

proc tick*(s: VcsSource; rt: TuiRuntime): bool =
  ## Refresh when `VcsRefreshMs` has passed; whether the pane's value changed.
  if s.isNil:
    return false
  if (getMonoTime() - s.lastRefresh).inMilliseconds < VcsRefreshMs:
    return false
  let before = rt.app.vcs
  s.refresh(rt)
  rt.app.vcs != before

proc close*(s: VcsSource) =
  if not s.isNil and not s.dispose.isNil:
    s.dispose()

proc toggleCommit*(s: VcsSource; rt: TuiRuntime; index: int) =
  ## PLAT-50 (K53): a click on commit `index` — the desktop's accordion
  ## (`VCSVM.selectedCommitIndex`'s rule): it opens, listing the files it
  ## changed (`git diff-tree`, as `ui/vcs.nim` reads them), and closes the one
  ## open before; a click on the open one closes it.
  if s.isNil:
    return
  let commits = s.vm.commits.val
  if index < 0 or index >= commits.len:
    return
  let selected = s.vm.selectedCommitIndices.val
  if selected == @[index]:
    s.vm.setCommits(commits, [])
    s.vm.removeCommitFiles(index)
  else:
    var rows: seq[VCSFileRow] = @[]
    let c = commits[index]
    for (status, path) in commitChangedFiles(
        s.directory, (if c.fullHash.len > 0: c.fullHash else: c.hash)):
      rows.add VCSFileRow(status: status, path: path,
                          baseName: path.extractFilename)
    s.vm.syncCommitFilesMap([])
    s.vm.setCommitFiles(index, rows)
    s.vm.setCommits(commits, [index], index)
  rt.app.vcs = paneModelOf(s.vm)

proc fileDiff*(s: VcsSource; status, path: string; hash = ""): string =
  ## PLAT-50 (K34): a changed file's diff — the working tree's (`hash` "")
  ## or the change commit `hash` made to it.
  if s.isNil:
    return ""
  if hash.len > 0: commitFileDiff(s.directory, hash, path)
  else: workingTreeFileDiff(s.directory, path, status)

proc applyClick*(s: VcsSource; rt: TuiRuntime; c: PaneClickRequest): bool =
  ## PLAT-50: a click in the VCS pane (`runtime.routePaneClick`'s `pcVcsDiff`
  ## / `pcVcsCommit`), in either product mode — a changed file's diff in the
  ## content overlay (the desktop opens it in a diff tab), a commit opened or
  ## closed. Answers whether the click was the pane's.
  if s.isNil:
    return false
  case c.kind
  of pcVcsCommit:
    s.toggleCommit(rt, int(c.index))
    true
  of pcVcsDiff:
    let text = s.fileDiff(c.text, c.path, c.behaviour)
    rt.app.content = ContentOverlay(
      open: true, diff: true,
      title: "diff " & c.path &
             (if c.behaviour.len > 0: "  (commit " & c.behaviour & ")"
              else: "  (working tree)"),
      text: (if text.len > 0: text else: "no changes to show for " & c.path))
    true
  else:
    false
