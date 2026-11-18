## The terminal keeps reading input while its VCS pane reads the repository.
##
## codetracer-pm issue 2026-11-17, "The terminal front-end stops reading input
## while its VCS pane runs git": the pane's `git status` / `git log` ran on the
## input loop, and on a loaded machine in a large checkout the front-end read
## no key for 70 s.
##
## DETERMINISTIC, NOT TIMED. A `git` first on `PATH` passes every command to
## the real git except `status` and `log`, which it holds until this suite
## creates a release file. While they are held, the front-end must open the
## command palette for F1 — which it cannot do if anything on its input loop is
## waiting for git, however long the case waits. Only then is git released,
## and the pane must still fill: the reads were held, not lost.
##
## No mocks of the product: the shipped binary, a real repository, the real
## git behind a gate.

import std/[monotimes, options, os, osproc, strutils, tempfiles, times, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 6

const
  Cols = 200
  Rows = 50

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc waitFor(sess: var TuiTestSession; needle: string;
             timeoutMs = 60000): bool =
  ## Whether `needle` appeared within `timeoutMs` — a ceiling for a STATE,
  ## generous for a loaded host; it costs nothing when the state comes at once.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    if sess.screenContents().contains(needle):
      return true
  false

proc fixtureRepo(): string =
  result = createTempDir("vcs-off-loop-", "") / "repo"
  let (output, code) = execCmdEx("bash " &
    quoteShell(lifecycle_support.repoRoot() / "scripts" / "plat47-vcs-fixture.sh") & " " &
    quoteShell(result))
  if code != 0:
    checkpoint(output)
  doAssert code == 0

proc gatedGit(dir, release: string): string =
  ## A directory holding a `git` that holds `status` and `log` until `release`
  ## exists, and runs the real git for everything else.
  let real = findExe("git")
  doAssert real.len > 0, "git is not on PATH"
  createDir(dir)
  let script = dir / "git"
  writeFile(script, "#!/bin/sh\n" &
    "case \" $* \" in\n" &
    "  *\" status \"*|*\" log \"*)\n" &
    "    while [ ! -e " & quoteShell(release) & " ]; do sleep 0.05; done ;;\n" &
    "esac\n" &
    "exec " & quoteShell(real) & " \"$@\"\n")
  setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
  dir

suite "the VCS pane's git never holds the terminal's input":

  test "F1 opens the palette while git status is held; released, the pane fills":
    let resolved = resolveFixture("calc")
    doAssert resolved.outcome == foRecorded, resolved.detail
    let repo = fixtureRepo()
    let scratch = repo.parentDir
    let release = scratch / "release-git"
    let bin = gatedGit(scratch / "bin", release)
    var sess = newTuiTest(tuiBinary(), @[resolved.tracePath])
      .width(Cols).height(Rows).workDir(repo)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("PATH", bin & ":" & getEnv("PATH"))
      .envSet("CODETRACER_TUI_LAYOUT_DIR", scratch / "layout")
      .carryRunMark()
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    # Git is held: nothing has released it, so no `status` has returned.
    ck not fileExists(release)
    sess.send("\x1bOP")  # F1, the palette
    ck sess.waitFor("PALETTE ")
    # Still held when the key was answered.
    ck not fileExists(release)
    sess.send("\x1b")
    writeFile(release, "")
    # The reads were held, not dropped: the pane fills once git answers.
    let strip = sess.regionText(1, 0, Cols, 1)
    let at = strip.find(" VCS ")
    ck at >= 0
    sess.sendMouseClick(1, at + 2)
    ck sess.waitFor("WORKING TREE (3)")
    sess.send(":quit\r")
    ck sess.waitExit(initDuration(seconds = 30)) == some(0)
    sess.close()
    removeDir(scratch)

  test "assertion count":
    check countedAssertions == ExpectedAssertions
