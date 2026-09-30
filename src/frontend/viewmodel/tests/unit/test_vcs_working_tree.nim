## test_vcs_working_tree.nim — PLAT-47 deliverable 4. **The VCS panel's
## working tree, read once for every front-end.**
##
## The desktop's VCS panel, the terminal's VCS pane and GPUI's all draw
## `VCSVM.workingTreeFiles`, filled from `git status --porcelain=v2 --branch`
## read by ONE reader (`platform/vcs.parsePorcelainV2`): the desktop runs the
## command itself (`ui/vcs.loadWorkingTree`), the native front-ends through the
## VCS facade (`vcs_vm.refreshFromFacade`). Asserted here on a REAL git
## repository (`scripts/plat47-vcs-fixture.sh`: a modified, an added and an
## untracked file, one untouched, on branch `plat47-vcs`):
##
##   1. the native facade's status, through the shared reader, gives the
##      branch and exactly those three files with `M`, `A` and `?`;
##   2. the desktop's own view (`isonim_vcs_view`, under IsoNim's mock
##      renderer — the same view code the Electron renderer mounts) draws them
##      as the "Working Tree" section, in git's order, with their letters;
##   3. the reader on hand-written lines of every other kind git emits
##      (renamed, unmerged, detached HEAD, ahead/behind);
##   4. a re-read — what every front-end does every `VCSRefreshIntervalMs` —
##      changes the pane's value (`workingStateKey`) exactly when the
##      repository moved: not on a repeat read, and yes when another program
##      adds a file or commits.
##
## No mocks of git or the filesystem. IsoNim's `MockRenderer` is the one
## stand-in, and it is not a mock: it is the renderer IsoNim ships for running
## a view without a browser, executing the desktop view's own code.

import std/[os, osproc, strutils, tables, tempfiles, unittest]

import isonim/core/[owner, signals]
import isonim/testing/mock_dom

import ../../viewmodels/vcs_vm
import ../../views/isonim_vcs_view
import ../../platform/vcs
import ../../host/desktop_native

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc repoRoot(): string =
  result = getEnv("CODETRACER_REPO_ROOT")
  if result.len == 0:
    result = currentSourcePath().parentDir.parentDir.parentDir.parentDir
      .parentDir.parentDir

proc textOf(n: MockNode): string =
  if n.kind == mnkText:
    return n.text
  for c in n.children:
    result.add textOf(c)

proc hasClass(n: MockNode; cls: string): bool =
  for part in n.attributes.getOrDefault("class", "").split(' '):
    if part == cls: return true
  false

proc allByClass(n: MockNode; cls: string; into: var seq[MockNode]) =
  if n.kind == mnkElement and n.hasClass(cls):
    into.add n
  for c in n.children:
    allByClass(c, cls, into)

proc fixtureRepo(): string =
  result = createTempDir("plat47-vcs-", "") / "repo"
  let script = repoRoot() / "scripts" / "plat47-vcs-fixture.sh"
  let (output, code) = execCmdEx("bash " & quoteShell(script) & " " &
                                 quoteShell(result))
  if code != 0:
    checkpoint("fixture script failed: " & output)
  doAssert code == 0

suite "PLAT-47 deliverable 4: one working tree for every VCS pane":

  test "the native facade reads the branch and the three changed files":
    let repo = fixtureRepo()
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.refreshFromFacade(newDesktopNativePlatform().vcs, repo)
      ck vm.isGitRepo.val
      ck vm.currentBranch.val == "plat47-vcs"
      ck vm.headerTitle.val == "plat47-vcs"
      var got: seq[string] = @[]
      for f in vm.workingTreeFiles.val:
        got.add f.status & " " & f.path
      checkpoint("working tree: " & $got)
      ck got == @["A added.txt", "M notes.txt", "? scratch.txt"]
      # The commit history came through the same facade.
      ck vm.commits.val.len == 1
      ck vm.commits.val[0].message == "Initial fixture commit"
      dispose()
    removeDir(repo.parentDir)

  test "the desktop's view draws them as the Working Tree section":
    let repo = fixtureRepo()
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.refreshFromFacade(newDesktopNativePlatform().vcs, repo)
      let root = renderVCSPanel(MockRenderer(), vm)
      var sections: seq[MockNode] = @[]
      root.allByClass("vcs-working-tree", sections)
      ck sections.len == 1
      ck textOf(sections[0]).contains(VCSWorkingTreeTitle & " (3)")
      var rows: seq[MockNode] = @[]
      root.allByClass("vcs-working-file", rows)
      var drawn: seq[string] = @[]
      for row in rows:
        var status, path: seq[MockNode]
        row.allByClass("vcs-working-status", status)
        row.allByClass("vcs-working-path", path)
        drawn.add textOf(status[0]) & " " & textOf(path[0])
      ck drawn == @["A added.txt", "M notes.txt", "? scratch.txt"]
      # The untouched file is not a change.
      ck not textOf(root).contains("unchanged.txt")
      dispose()
    removeDir(repo.parentDir)

  test "a periodic re-read moves the pane's value exactly when the repository moved":
    let repo = fixtureRepo()
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let facade = newDesktopNativePlatform().vcs
      vm.refreshFromFacade(facade, repo)
      let first = vm.workingStateKey()
      ck first.len > 0
      vm.refreshFromFacade(facade, repo)
      ck vm.workingStateKey() == first          # nothing moved
      writeFile(repo / "late.txt", "written by another program\n")
      vm.refreshFromFacade(facade, repo)
      let second = vm.workingStateKey()
      ck second != first
      var got: seq[string] = @[]
      for f in vm.workingTreeFiles.val:
        got.add f.status & " " & f.path
      ck "? late.txt" in got
      # A commit elsewhere moves it too (history and working tree).
      let (_, code) = execCmdEx("git -C " & quoteShell(repo) &
        " -c user.name=x -c user.email=x@invalid -c commit.gpgsign=false" &
        " commit -q -m later")
      ck code == 0
      vm.refreshFromFacade(facade, repo)
      ck vm.workingStateKey() != second
      ck vm.commits.val.len == 2
      # One interval for every front-end's refresh: the desktop's 5 s.
      ck VCSRefreshIntervalMs == 5000
      dispose()
    removeDir(repo.parentDir)

  test "a directory that is not a repository says so and lists nothing":
    let dir = createTempDir("plat47-novcs-", "")
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.refreshFromFacade(newDesktopNativePlatform().vcs, dir)
      ck not vm.isGitRepo.val
      ck vm.errorMessage.val == "Not a git repository"
      ck vm.workingTreeFiles.val.len == 0
      dispose()
    removeDir(dir)

  test "the reader handles every kind of line git emits":
    let s = parsePorcelainV2(
      "# branch.oid 0123\n" &
      "# branch.head (detached)\n" &
      "# branch.upstream origin/main\n" &
      "# branch.ab +2 -3\n" &
      "1 .D N... 100644 100644 000000 aaaa aaaa gone.txt\n" &
      "2 R. N... 100644 100644 100644 bbbb bbbb R100 new name.txt\told.txt\n" &
      "u UU N... 100644 100644 100644 100644 c1 c2 c3 conflict.txt\n" &
      "1 AM N... 000000 100644 100644 0000 dddd staged then edited.txt\n" &
      "? dir/untracked.txt\n")
    ck s.detached
    ck s.upstream == "origin/main"
    ck s.ahead == 2 and s.behind == 3
    ck s.changes.len == 5
    var letters: seq[string] = @[]
    for c in s.changes:
      letters.add workingTreeStatusLetter(c) & " " & c.path
    # A file added to the index and then edited is still NEW to the
    # repository: the staged state wins (`AM` reads `A`).
    ck letters == @["D gone.txt", "R new name.txt", "U conflict.txt",
                    "A staged then edited.txt", "? dir/untracked.txt"]
    ck s.changes[1].previousPath == "old.txt"
    let rows = workingTreeRowsOf(s)
    ck rows[4].baseName == "untracked.txt"

echo "CHECKS: ", CHECKS
