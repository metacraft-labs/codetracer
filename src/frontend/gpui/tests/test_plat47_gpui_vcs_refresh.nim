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
## THE SECOND TRIGGER — THE RETURN TO THE WINDOW. The desktop also re-reads on
## its window `focus` event (VCS-Panel.md's focus-gain refresh, `ui/vcs.nim`
## `startFileWatching`); GPUI's equivalent is the renderer's inactive-to-active
## edge, which `gpui/main.nim` subscribes to through
## `window_chrome.subscribeWindow`'s `activated`. The second suite registers
## through `window_chrome.subscribeWindowOn` — the procedure `subscribeWindow`
## is — on a window it created, changes the repository from another program,
## and drives the activation through the shim's own bridging entry point
## (`gpui_notify_window_state`, which writes the registry field a live
## window's per-frame sample writes and runs the same dispatch). It requires
## the new row on the edge and BEFORE `VCSRefreshIntervalMs` could have
## elapsed, with no tick armed, so the interval cannot be what refreshed it.
## It then covers the return to a window that drew no frame while the user
## was away (another workspace, minimized). There, only the platform's
## activation report (`gpui_notify_window_activation`, which the renderer's
## activation observer calls) sees the window leave. The first frame after
## the return still reads as a return. Measured on headless sway before the
## renderer latched that report: after a workspace switch away and back,
## the pane kept the old rows until the next tick.
## Before the edge existed `subscribeWindow` took no `activated` and the
## shim had no activation dispatch: the pane kept the old rows until the next
## tick (codetracer-pm issue 2026-09-30, "the terminal's and GPUI's VCS panes
## do not refresh when their window regains focus").
##
## No mocks: the system `git` through the native VCS facade, a real
## repository, the real ViewModel and view, the real isonim-gpui shim. The
## one stand-in is the window's ACTIVATION, which a headless lane has no
## compositor to produce: `gpui_notify_window_state` is the shim's bridging
## entry point for exactly that (the counterpart of `gpui_notify_resize`),
## and the live sampling it stands in for (`NimRootView::render` →
## `update_chrome_state`) is the same function call with a sampled state.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import std/[monotimes, times]

import gpui/host/gpui_host
import gpui/window_chrome
import isonim_gpui/[bindings, window]
import view_vocabulary/pane_views
import viewmodels/vcs_vm
import ../../../common/view_vocabulary

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const ExpectedAssertions = 26

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

suite "PLAT-47 deliverable 4: GPUI's VCS pane refreshes when the window is activated":

  test "returning to the window re-reads the repository before the interval":
    let dir = createTempDir("plat47-gpui-vcs-activate-", "")
    let repo = dir / "repo"
    let (output, code) = execCmdEx("bash " &
      quoteShell(repoRoot / "scripts" / "plat47-vcs-fixture.sh") & " " &
      quoteShell(repo))
    if code != 0: checkpoint(output)
    ck code == 0
    let vm = openGpuiVcs(repo)
    resetWindows()
    # NO TICK IS ARMED for the whole case (and `resetWindows` disarmed any):
    # whatever refreshes the pane here is the activation, not the interval.
    gpui_set_tick(0'u32, nil)
    let win = createWindow("plat47-vcs-activation", 800, 600)
    var refreshes = 0
    var changed = 0
    # The registration `gpui/main.nim` makes, with `refreshGpuiVcs` (the body
    # its `refreshVcsPane` runs for both triggers) as the callback.
    ck subscribeWindowOn(win,
      proc(w, h: int) = discard,
      proc() = discard,
      proc() =
        inc refreshes
        if refreshGpuiVcs(vm, repo): inc changed)
    # The window comes up and is focused: its first activation.
    gpui_notify_window_state(win.id, 0, 0, 15, 0, 1, "")
    ck refreshes == 1
    ck changed == 0
    # The user switches to another program and writes a file there...
    gpui_notify_window_state(win.id, 0, 0, 15, 0, 0, "")
    writeFile(repo / "away.txt", "written while the window was in the background\n")
    let changedAt = getMonoTime()
    ck "? away.txt" notin labelsOf(vm)
    # ...and comes back: the edge re-reads the repository at once.
    gpui_notify_window_state(win.id, 0, 0, 15, 0, 1, "")
    let elapsed = (getMonoTime() - changedAt).inMilliseconds
    checkpoint("re-read " & $elapsed & " ms after the change")
    ck refreshes == 2
    ck changed == 1
    ck "? away.txt" in labelsOf(vm)
    ck elapsed < VCSRefreshIntervalMs
    # Staying in the window (a maximize while active) is not a return, and
    # neither is leaving it: neither re-reads.
    gpui_notify_window_state(win.id, 0, 0, 15, 1, 1, "")
    gpui_notify_window_state(win.id, 0, 0, 15, 1, 0, "")
    ck refreshes == 2
    # Back, then away to ANOTHER WORKSPACE: the window draws no frame while
    # hidden, so only the platform's activation report sees it leave and
    # come back. A file changes meanwhile.
    gpui_notify_window_state(win.id, 0, 0, 15, 1, 1, "")
    ck refreshes == 3
    ck gpui_notify_window_activation(win.id, 0) == 1
    writeFile(repo / "hidden.txt", "written while the window was hidden\n")
    ck gpui_notify_window_activation(win.id, 1) == 1
    # The first frame after the return samples the window active, as the
    # last frame before it did. It is still a return, and the pane re-reads.
    gpui_notify_window_state(win.id, 0, 0, 15, 1, 1, "")
    ck refreshes == 4
    ck "? hidden.txt" in labelsOf(vm)
    win.destroy()
    resetWindows()
    removeDir(dir)

suite "assertion tally":
  test "count":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
