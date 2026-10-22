## test_vcs_history_viewport.nim — **the terminal's VCS history reads the
## commits its list shows** (Viewport-Driven-Loading V6; codetracer-pm issue
## 2026-10-22, "the VCS history list's viewport is written by nothing").
##
## `VCSVM.historyViewport` decides how many commits the native refresh
## (`vcs_vm.refreshFromFacade`) asks `git log` for: every row up to the last
## one the list shows, plus `LeadRows` (`historyCommitCount`). Until the fix
## nothing wrote it, so every refresh read the unmeasured fallback,
## `VcsHistoryUnmeasured` (50) commits, however tall the list: a tall pane
## left its foot empty while the repository had more history, a short one paid
## for 50, and a reader who scrolled to the end of the 50 could go no further.
##
## Asserted here through the product's own entry points, on a terminal of a
## given size with the VCS tab shown (a press on its tab, as a user makes it):
##
##   1. a TALL list (a 120-row terminal) reads exactly the commits it shows
##      plus the lead — more than 50 — and its foot is not left empty;
##   2. a SHORT list (a 30-row terminal) reads fewer than 50;
##   3. scrolling to the end of what was read (the wheel, `handleToken` with
##      the bytes a terminal sends) reads more AT ONCE (`followViewport`, which
##      the shipped loop runs after every token), and the periodic re-read
##      keeps that depth;
##   4. a step down the list that stays short of the last commit read reads
##      nothing at once (no `git` per wheel notch);
##   5. a commit opened stays open while the history grows under it (PLAT-50:
##      a re-read keeps the open commit while the history is the same one,
##      read deeper);
##   6. a history read whole asks for nothing more at its end.
##
## No mocks: a REAL git repository built with the system `git` (150 empty
## commits on one branch), read through the product's `VcsSource` and the
## native VCS facade; the runtime and the shell in process, no session (the
## VCS pane needs none), as `test_plat50_shell.nim` drives them.

import std/[os, osproc, strutils, tempfiles, unittest]

import ../app/runtime
import ../app/tui_app
import ../app/views/shell
import ../app/views/vcs_pane
import ../app/layout/tab_strip
import ../app/layout/binding
import ../app/theme/capabilities
import ../host/vcs_source
import viewport
import viewmodels/vcs_vm
import headless_app/layout_model

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 33

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  HistoryCommits = 150
    ## More than any pane below lists plus its lead, so a read is cut by what
    ## it asked for and never by the history running out (case 5 aside).
  WheelDown = 65

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc newRuntime(cols, rows: int): TuiRuntime =
  result = newTuiRuntime(newTuiApp(), caps(), cols, rows)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc sgr(code, row, col: int; release = false): string =
  "\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
    (if release: "m" else: "M")

proc makeHistoryRepo(commits: int): string =
  ## A real repository on branch `history` with `commits` empty commits, the
  ## newest `commit <commits>`; a clean working tree.
  result = createTempDir("vcs-history-viewport-", "") / "repo"
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

proc showVcsTab(rt: TuiRuntime): bool =
  ## Press the VCS tab of the stack that holds it, so the VCS pane is shown.
  for region in rt.shellScreenOf().geometry.projection.regions:
    for k, title in region.tabs:
      if title.strip.toUpperAscii == "VCS":
        let spans = tabSpans(region.tabs, region.activeTab)
        let row = region.area.row
        let col = region.area.col + spans[k].startCol + spans[k].width div 2
        discard rt.handleToken(sgr(0, row, col), 0)
        discard rt.handleToken(sgr(0, row, col, release = true), 0)
        return true
  false

proc vcsContent(rt: TuiRuntime): CellArea =
  ## The rectangle the VCS pane's rows are painted in: its box below its tab
  ## strip (`runtime.inHandTrack`'s arithmetic), empty when it is not shown.
  let screen = rt.shellScreenOf()
  for region in screen.geometry.projection.regions:
    if region.pane == paneVcs:
      let frame = paneFrame(region.area, screen.geometry.body)
      return CellArea(col: region.area.col, row: region.area.row + 1,
                      width: frame.box.width, height: frame.box.height - 1)
  CellArea()

proc paintedRows(rt: TuiRuntime): int =
  ## How many rows of its rectangle the pane painted.
  let a = rt.vcsContent()
  var g = newStyledGrid(a.col + a.width, a.row + a.height)
  paintVcsPane(g, a, rt.app.vcs).rows.len

proc wheelToEnd(rt: TuiRuntime): int =
  ## Wheel down over the pane until it moves no further; the notches turned.
  let a = rt.vcsContent()
  var last = -1
  while rt.app.vcs.scrollTop != last and result < 1000:
    last = rt.app.vcs.scrollTop
    discard rt.handleToken(sgr(WheelDown, a.row + 1, a.col + 2), 0)
    inc result

suite "the terminal's VCS history reads what its list shows":

  test "a tall list reads every commit it shows, past the fixed 50":
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let rt = newRuntime(200, 120)
    ck rt.showVcsTab()
    let a = rt.vcsContent()
    checkpoint("VCS pane: " & $a)
    # The fixture is what the case says: a list taller than the fallback.
    ck a.height + LeadRows > VcsHistoryUnmeasured
    let vcs = newVcsSource(repo)
    defer: vcs.close()
    vcs.refresh(rt)
    checkpoint("commits read: " & $rt.app.vcs.commits.len)
    ck rt.app.vcs.commits.len > VcsHistoryUnmeasured
    ck rt.app.vcs.commits.len ==
      historyCommitCount(Viewport(rows: a.height, firstRow: 0))
    # The newest commit first, and no row of the pane left empty while the
    # repository has more history than it shows.
    ck rt.app.vcs.commits[0].subject == "commit " & $HistoryCommits
    ck rt.paintedRows() == a.height

  test "a short list reads fewer than 50":
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let rt = newRuntime(200, 30)
    ck rt.showVcsTab()
    let a = rt.vcsContent()
    checkpoint("VCS pane: " & $a)
    ck a.height > 0
    ck a.height + LeadRows < VcsHistoryUnmeasured
    let vcs = newVcsSource(repo)
    defer: vcs.close()
    vcs.refresh(rt)
    checkpoint("commits read: " & $rt.app.vcs.commits.len)
    ck rt.app.vcs.commits.len < VcsHistoryUnmeasured
    ck rt.app.vcs.commits.len ==
      historyCommitCount(Viewport(rows: a.height, firstRow: 0))

  test "scrolling to the end of what was read reads more":
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let rt = newRuntime(200, 30)
    ck rt.showVcsTab()
    let vcs = newVcsSource(repo)
    defer: vcs.close()
    vcs.refresh(rt)
    let before = rt.app.vcs.commits.len
    ck rt.wheelToEnd() > 1
    # AT ONCE: the loop runs `followViewport` after the token, and it reads
    # the commits the list now reaches without waiting for the interval.
    ck vcs.followViewport(rt)
    let grown = rt.app.vcs.commits.len
    checkpoint("commits read: " & $before & " -> " & $grown)
    ck grown > before
    # The reading position is the reader's: the re-read did not move it.
    ck rt.app.vcs.scrollTop > 0
    # The periodic re-read keeps that depth rather than falling back to the
    # top of the history.
    vcs.refresh(rt)
    ck rt.app.vcs.commits.len == grown
    # Every notch at the new end reads further, as far as the history goes.
    var steps = 0
    while rt.app.vcs.commits.len < HistoryCommits and steps < 100:
      discard rt.wheelToEnd()
      discard vcs.followViewport(rt)
      inc steps
    ck rt.app.vcs.commits.len == HistoryCommits
    ck rt.app.vcs.commits[^1].subject == "commit 1"

  test "a step down the list short of its end reads nothing at once":
    # The count a viewport calls for carries the lead, so it grows with every
    # step down; re-reading whenever it grew would run `git` per wheel notch.
    # Only reaching the end of what was read re-reads at once.
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let rt = newRuntime(200, 30)
    ck rt.showVcsTab()
    let vcs = newVcsSource(repo)
    defer: vcs.close()
    vcs.refresh(rt)
    let before = rt.app.vcs.commits.len
    let a = rt.vcsContent()
    var notches = 0
    while rt.vcsHistoryWindow().firstRow < 3 and notches < 20:
      discard rt.handleToken(sgr(WheelDown, a.row + 1, a.col + 2), 0)
      inc notches
    let w = rt.vcsHistoryWindow()
    checkpoint("window after " & $notches & " notches: " & $w)
    # The fixture is what the case says: commits scrolled past, the list
    # still short of the last commit read.
    ck w.firstRow > 0
    ck w.firstRow + w.rows < before
    ck not vcs.followViewport(rt)
    ck rt.app.vcs.commits.len == before

  test "a commit opened stays open while the history grows under it":
    let repo = makeHistoryRepo(HistoryCommits)
    defer: removeDir(repo.parentDir)
    let rt = newRuntime(200, 30)
    ck rt.showVcsTab()
    let vcs = newVcsSource(repo)
    defer: vcs.close()
    vcs.refresh(rt)
    vcs.toggleCommit(rt, 0)
    ck rt.app.vcs.expandedCommit == 0
    let before = rt.app.vcs.commits.len
    discard rt.wheelToEnd()
    ck vcs.followViewport(rt)
    ck rt.app.vcs.commits.len > before
    ck rt.app.vcs.expandedCommit == 0

  test "a history read whole asks for nothing more at its end":
    let repo = makeHistoryRepo(5)
    defer: removeDir(repo.parentDir)
    let rt = newRuntime(200, 30)
    ck rt.showVcsTab()
    let vcs = newVcsSource(repo)
    defer: vcs.close()
    vcs.refresh(rt)
    ck rt.app.vcs.commits.len == 5
    discard rt.wheelToEnd()
    ck not vcs.followViewport(rt)
    ck rt.app.vcs.commits.len == 5

suite "VCS history viewport: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
