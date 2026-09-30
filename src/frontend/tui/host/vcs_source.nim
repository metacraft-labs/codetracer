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

import std/[monotimes, times]

import ../../viewmodel/viewmodels/vcs_vm
import ../../viewmodel/platform/vcs
import ../../viewmodel/host/native_vcs
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
