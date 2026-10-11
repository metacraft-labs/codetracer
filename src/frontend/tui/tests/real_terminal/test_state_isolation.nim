## test_state_isolation.nim — **a test run never touches the user's own
## per-user state.** The guard for `test_support/state_isolation.nim`.
##
## ## The defect this pins
##
## The shipped terminal writes its layout document on every exit that changed
## anything (PLAT-45's "remembers its own layout", `persistLayoutForSession`).
## A real-terminal suite run outside the lane runner inherited the developer's
## environment, so it opened the developer's remembered arrangement and wrote
## its own back over `~/.local/state/codetracer/tui-layout.json`.
##
## ## What is asserted, and how the user's files are protected WHILE asserting
##
##   1. This very process was isolated by the forced import: `XDG_STATE_HOME`
##      and `CODETRACER_TUI_LAYOUT_DIR` exist and neither lies inside the
##      user's state home.
##   2. The SHIPPED binary, spawned the way every suite spawns it — inheriting
##      the environment, naming NO state directory of its own — and made to
##      change its layout (`:dock bottom`, written through), writes its
##      document into this process's private directory and nowhere else.
##
## Case 2 is also run with `HOME` pointed at an empty temporary home, and the
## assertion is that the temporary home's `.local/state` is still absent after
## the launch. That is the arm that can FAIL without harming anyone: if the
## isolation regressed, the write it catches lands in a throwaway home rather
## than the developer's. The developer's real directory is only READ — its
## listing, sizes, modification times and contents before and after — and a
## difference fails the case by name.
##
## ## No mocks
##
## The compiled `codetracer-tui` on the real `calc` recording in a real PTY
## (TermAssert + libvterm), writing real files.

import std/[monotimes, options, os, strutils, tempfiles, times, unittest,
            algorithm]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../../test_support/state_isolation

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 10

const
  TuiDocument = "tui-layout.json"
  Cols = 120
  Rows = 40

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc underDir(path, root: string): bool =
  let p = normalizedPath(absolutePath(path))
  let r = normalizedPath(absolutePath(root))
  p == r or p.startsWith(r & DirSep)

proc snapshot(dir: string): string =
  ## Every entry under `dir` with its size, modification time and (for a
  ## file) its bytes — READ ONLY. "" when the directory does not exist.
  if not dirExists(dir):
    return ""
  var lines: seq[string] = @[]
  for path in walkDirRec(dir, yieldFilter = {pcFile, pcLinkToFile, pcDir,
                                             pcLinkToDir}):
    let info = getFileInfo(path, followSymlink = false)
    var line = path & " " & $info.size & " " & $info.lastWriteTime.toUnixFloat
    if info.kind == pcFile:
      line.add " " & readFile(path)
    lines.add line
  lines.sort()
  lines.join("\n")

suite "Tests never touch the user's per-user state":

  test "this process was isolated before any suite code ran":
    let home = userStateHome()
    let stateHome = getEnv("XDG_STATE_HOME")
    let layoutDir = getEnv("CODETRACER_TUI_LAYOUT_DIR")
    checkpoint("XDG_STATE_HOME=" & stateHome & " CODETRACER_TUI_LAYOUT_DIR=" &
               layoutDir & " user state home=" & home)
    ck stateHome.len > 0 and not stateHome.underDir(home)
    ck layoutDir.len > 0 and not layoutDir.underDir(home)
    # And `CODETRACER_HOME`, which relocates EVERY per-user location (trace
    # index, recordings, config, caches; common/ct_home), is a scratch one.
    let ctHome = getEnv("CODETRACER_HOME")
    checkpoint("CODETRACER_HOME=" & ctHome)
    ck codetracerHomeIsTestScratch(ctHome)

  test "the shipped binary, spawned with the inherited environment, writes only the private directory":
    ck fileExists(tuiBinary())
    let resolved = resolveFixture("calc")
    ck resolved.outcome == foRecorded
    let realDir = userStateHome() / "codetracer"
    let before = snapshot(realDir)
    let privateDir = getEnv("CODETRACER_TUI_LAYOUT_DIR")
    removeFile(privateDir / TuiDocument)
    let fakeHome = createTempDir("ct-isolation-home-", "")
    # NO state directory is named here: the child inherits this process's.
    # `HOME` is a throwaway, so a regression writes there, not into the
    # developer's home.
    var sess = newTuiTest(tuiBinary(), @[resolved.tracePath])
      .width(Cols).height(Rows)
      .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("HOME", fakeHome)
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    sess.send(":dock bottom\r")
    let deadline = getMonoTime() + initDuration(seconds = 20)
    while not fileExists(privateDir / TuiDocument) and
        getMonoTime() < deadline:
      discard sess.drainOutput(40)
    ck fileExists(privateDir / TuiDocument)
    sess.send(":quit\r")
    ck sess.waitExit(initDuration(seconds = 30)) == some(0)
    sess.close()
    ck readFile(privateDir / TuiDocument).contains("\"docked\"")
    # The throwaway home gained no state directory at all.
    ck not dirExists(fakeHome / ".local" / "state")
    # The developer's real directory is exactly as it was, byte for byte.
    let after = snapshot(realDir)
    if before != after:
      checkpoint("the user's state directory CHANGED during this case: " &
                 realDir)
    ck before == after
    removeDir(fakeHome)
    removeFile(privateDir / TuiDocument)

  test "assertion count":
    check countedAssertions == ExpectedAssertions
