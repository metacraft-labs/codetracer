## test_gpui_vcs_history_viewport.nim — **GPUI's VCS history reads the commits
## its list shows** (Viewport-Driven-Loading V6; codetracer-pm issue
## 2026-10-22, "the VCS history list's viewport is written by nothing").
##
## The window reports the VCS pane's history viewport from the rows its body
## holds and the reader's place (`gpui/main.followVcsViewport`, after every
## arrangement and every wheel or scrubber move over the pane). That
## procedure is two calls, and this suite drives both on what the window
## itself would hand them:
##
##   * `leaves.vcsHistoryWindow` over the view the pane draws
##     (`pane_views.vcsPaneView` of the same `VCSVM`): the body's rows, and
##     the COMMIT rows above the first row shown — the branch, the working
##     tree and the captions are not history;
##   * `gpui_host.followGpuiVcsViewport`: the viewport written, and the
##     repository re-read at once when the list reaches the last commit read.
##
## Cases: a tall body reads more than 50 commits; a short one asks for no
## re-read and the next tick (`refreshGpuiVcs`) reads fewer than 50; a step
## down the list short of the last commit read re-reads nothing; the
## reader at the end of what was read gets more at once, keeping the commit
## they opened; a history read whole asks for nothing more.
##
## No mocks: a REAL repository built with the system `git`, read through the
## native VCS facade by the window's own host procedures. The window itself
## (a shim, a compositor) is not needed for these two calls and is not
## started; the tick and the activation in a real window are
## `test_plat47_gpui_vcs_refresh.nim`'s and `test_plat47_gpui_window.nim`'s.

import std/[os, osproc, tempfiles, unittest]

import gpui/host/gpui_host
import gpui/app/leaves
import view_vocabulary/pane_views
import viewmodels/vcs_vm
import isonim/core/signals

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const ExpectedAssertions = 22

const HistoryCommits = 150

proc makeHistoryRepo(commits: int): string =
  ## A real repository with `commits` empty commits, the newest
  ## `commit <commits>`; a clean working tree.
  result = createTempDir("gpui-vcs-history-", "") / "repo"
  createDir(result)
  let q = quoteShell(result)
  let (output, code) = execCmdEx(
    "set -e; export GIT_AUTHOR_NAME=h GIT_AUTHOR_EMAIL=h@invalid " &
    "GIT_COMMITTER_NAME=h GIT_COMMITTER_EMAIL=h@invalid; " &
    "git -C " & q & " -c init.defaultBranch=history init -q; " &
    "for i in $(seq 1 " & $commits & "); do git -C " & q &
    " -c commit.gpgsign=false commit -q --allow-empty -m \"commit $i\"; done")
  if code != 0:
    checkpoint(output)
  doAssert code == 0

proc follow(vm: VCSVM; repo: string; top, rows: int): bool =
  ## What `gpui/main.followVcsViewport` does for a body of `rows` rows with
  ## the reader at `top`.
  let w = vcsHistoryWindow(vcsPaneView(vm).root, top, rows)
  followGpuiVcsViewport(vm, repo, w.rows, w.firstRow)

suite "GPUI's VCS history reads what its list shows":

  test "the window counts the commits above the reader's place, not the captions":
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let vm = openGpuiVcs(repo)
    let view = vcsPaneView(vm).root
    # The branch caption, the working tree's caption, its clean text and the
    # commits' caption are the four rows above the first commit.
    ck vcsHistoryWindow(view, 0, 20) == (rows: 20, firstRow: 0)
    ck vcsHistoryWindow(view, 4, 20) == (rows: 20, firstRow: 0)
    ck vcsHistoryWindow(view, 14, 20) == (rows: 20, firstRow: 10)
    # Unmeasured: nothing to report.
    ck vcsHistoryWindow(view, 14, 0) == (rows: 0, firstRow: 0)

  test "a tall body reads every commit it can show, past the fixed 50":
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let vm = openGpuiVcs(repo)
    # Opened before the window measured the pane: the fallback.
    ck vm.commits.val.len == VcsHistoryUnmeasured
    ck follow(vm, repo, 0, 90)
    ck vm.commits.val.len == historyCommitCount(Viewport(rows: 90))
    ck vm.commits.val.len > VcsHistoryUnmeasured

  test "a short body re-reads nothing at once, and the next tick reads fewer":
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let vm = openGpuiVcs(repo)
    ck not follow(vm, repo, 0, 10)
    ck vm.commits.val.len == VcsHistoryUnmeasured
    ck refreshGpuiVcs(vm, repo)
    ck vm.commits.val.len == historyCommitCount(Viewport(rows: 10))
    ck vm.commits.val.len < VcsHistoryUnmeasured

  test "a step down the list short of its end reads nothing at once":
    # The count a viewport calls for carries the lead, so it grows with every
    # step down; re-reading whenever it grew would run `git` on the window's
    # loop per wheel step. Only reaching the end of what was read re-reads.
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let vm = openGpuiVcs(repo)
    discard follow(vm, repo, 0, 10)
    discard refreshGpuiVcs(vm, repo)
    let before = vm.commits.val.len
    # Ten commits scrolled past (four caption rows above the first), the
    # body's ten rows still short of the last commit read.
    let w = vcsHistoryWindow(vcsPaneView(vm).root, 14, 10)
    ck w.firstRow == 10
    ck w.firstRow + w.rows < before
    ck not follow(vm, repo, 14, 10)
    ck vm.commits.val.len == before

  test "the reader at the end of what was read gets more at once":
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let vm = openGpuiVcs(repo)
    discard follow(vm, repo, 0, 10)
    discard refreshGpuiVcs(vm, repo)
    let before = vm.commits.val.len
    # The commit the reader opened (PLAT-50) stays open across the deeper
    # read: same history, read further.
    vm.setCommits(vm.commits.val, [0], 0)
    # Scrolled as far as the wheel goes (`inHandTop` clamps the place).
    ck follow(vm, repo, high(int) div 2, 10)
    ck vm.commits.val.len > before
    ck vm.selectedCommitIndices.val == @[0]

  test "a history read whole asks for nothing more at its end":
    let repo = makeHistoryRepo(5)
    defer: removeDir(repo.parentDir)
    let vm = openGpuiVcs(repo)
    ck vm.commits.val.len == 5
    ck not follow(vm, repo, high(int) div 2, 3)

suite "GPUI VCS history viewport: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
