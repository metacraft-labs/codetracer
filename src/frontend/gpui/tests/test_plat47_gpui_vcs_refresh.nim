## test_plat47_gpui_vcs_refresh.nim — PLAT-47 deliverable 4, below the window.
## **GPUI's VCS pane re-reads its repository as the desktop's panel does, and
## is redrawn exactly when the repository moved.**
##
## The window arms a tick at `VCSRefreshIntervalMs` (the desktop's own
## `refreshIntervalMs`, `gpui_set_tick` in `gpui/main.nim`) whose body is
## `gpui_host.refreshGpuiVcs`, and draws the pane again only when that answers
## `true`. This suite drives that procedure on a REAL git repository
## (`scripts/plat47-vcs-fixture.sh`) with changes made by another program —
## a file written, a commit made — and reads the pane the way the window
## draws it: the vocabulary view of the same `VCSVM`
## (`pane_views.vcsPaneView`). The tick itself, in a real window, is
## `test_plat47_gpui_window.nim`'s (the `vcs-refresh` frame).
##
## No mocks: the system `git` through the native VCS facade, a real
## repository, the real ViewModel and view.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import gpui/host/gpui_host
import view_vocabulary/pane_views
import viewmodels/vcs_vm
import ../../../common/view_vocabulary

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const ExpectedAssertions = 11

let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc labelsOf(vm: VCSVM): seq[string] =
  ## Every text and option label of the pane as the window draws it.
  proc walk(n: ViewNode; into: var seq[string]) =
    if n.isNil: return
    if n.text.len > 0: into.add n.text
    if n.label.len > 0: into.add n.label
    for o in n.options: into.add o.label
    for c in n.children: walk(c, into)
  walk(vcsPaneView(vm).root, result)

suite "PLAT-47 deliverable 4: GPUI's VCS pane refreshes like the desktop's":

  test "a re-read picks up another program's changes and reports them once":
    let dir = createTempDir("plat47-gpui-vcs-refresh-", "")
    let repo = dir / "repo"
    let (output, code) = execCmdEx("bash " &
      quoteShell(repoRoot / "scripts" / "plat47-vcs-fixture.sh") & " " &
      quoteShell(repo))
    if code != 0: checkpoint(output)
    ck code == 0
    let vm = openGpuiVcs(repo)
    ck "? scratch.txt" in labelsOf(vm)
    # Nothing moved: no redraw.
    ck not refreshGpuiVcs(vm, repo)
    # Another program writes a file: the next tick redraws, and the pane
    # lists it with the desktop's untracked state.
    writeFile(repo / "late.txt", "written while the window was open\n")
    ck refreshGpuiVcs(vm, repo)
    let after = labelsOf(vm)
    checkpoint($after)
    ck "? late.txt" in after
    ck after.anyIt(it.startsWith(VCSWorkingTreeTitle & " (4)"))
    # And the tick after that has nothing new.
    ck not refreshGpuiVcs(vm, repo)
    # A commit made elsewhere moves the history.
    let (_, committed) = execCmdEx("git -C " & quoteShell(repo) &
      " -c user.name=x -c user.email=x@invalid -c commit.gpgsign=false" &
      " commit -q -m later")
    ck committed == 0
    ck refreshGpuiVcs(vm, repo)
    ck labelsOf(vm).anyIt(it.endsWith(" later"))
    # The interval the window arms is the desktop's.
    ck VCSRefreshIntervalMs == 5000
    removeDir(dir)

suite "assertion tally":
  test "count":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
