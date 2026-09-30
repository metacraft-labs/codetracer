## test_plat47_vcs_pane.nim — PLAT-47 deliverable 4, Tier 2. **The terminal's
## VCS pane shows what the desktop's VCS panel shows, on a real repository.**
##
## The repository is `scripts/plat47-vcs-fixture.sh`'s (branch `plat47-vcs`;
## `notes.txt` modified, `added.txt` added, `scratch.txt` untracked,
## `unchanged.txt` untouched). The desktop's side is
## `src/tests/visual/answers/plat47-vcs.electron.json`, the real Electron
## app's VCS panel on the same repository (`plat47-vcs-capture.spec.ts`, run
## by `just plat47-capture-electron`).
##
## The shipped `codetracer-tui` opens the `calc` recording with its working
## directory INSIDE the repository — the directory the desktop's VCS panel
## reads for a replay is the process's own — and the VCS tab of the FILES
## stack is chosen with a real mouse click. Asserted from the screen read back
## through libvterm:
##
##   * the pane names the branch the desktop names;
##   * its working-tree rows are exactly the desktop's rows — state letter and
##     path, in order — and the untouched file is not among them;
##   * the section is captioned with the desktop's words and count;
##   * the state letters are coloured apart: an added or untracked file in a
##     different colour from a modified one;
##   * a change made to the working tree while the terminal runs appears
##     after the desktop's refresh interval.
##
## No mocks: a real git repository, the real binary on a real recording in a
## real PTY (TermAssert + libvterm).

import std/[json, monotimes, options, os, osproc, strutils, tempfiles, times,
            unicode, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 15

const
  Cols = 200
  Rows = 50
  Capture = "src/tests/visual/answers/plat47-vcs.electron.json"
  RefreshBudgetMs = 15000
    ## The pane refreshes every 5 s (the desktop's `refreshIntervalMs`); three
    ## intervals of slack for a loaded host.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc waitFor(sess: var TuiTestSession; needle: string; timeoutMs = 30000): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    result = sess.screenContents()
    if result.contains(needle):
      return
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared; screen:\n" & result)

proc colorKey(c: Color): string =
  case c.kind
  of ckDefault: "default"
  of ckIndexed: "idx" & $c.idx
  of ckRgb: $c.r & "," & $c.g & "," & $c.b

proc paneWidth(strip: string): int =
  ## The FILES stack's width: the cells before the first divider on its
  ## strip row.
  var i = 0
  for r in strip.runes:
    if r == "│".runeAt(0):
      return i
    inc i
  i

proc fixtureRepo(): string =
  result = createTempDir("plat47-vcs-tui-", "") / "repo"
  let (output, code) = execCmdEx("bash " &
    quoteShell(lifecycle_support.repoRoot() / "scripts" / "plat47-vcs-fixture.sh") & " " &
    quoteShell(result))
  if code != 0:
    checkpoint(output)
  doAssert code == 0

suite "PLAT-47 deliverable 4: the terminal's VCS pane":

  test "the VCS pane lists the desktop's rows for a real repository":
    let capturePath = lifecycle_support.repoRoot() / Capture
    if not fileExists(capturePath):
      checkpoint(Capture & " is absent: run `just plat47-capture-electron`")
    ck fileExists(capturePath)
    let desk = parseJson(readFile(capturePath))
    var deskRows: seq[string] = @[]
    for r in desk["rows"]:
      deskRows.add r[0].getStr & " " & r[1].getStr
    let resolved = resolveFixture("calc")
    ck resolved.outcome == foRecorded
    let repo = fixtureRepo()
    var sess = newTuiTest(tuiBinary(), @[resolved.tracePath])
      .width(Cols).height(Rows).workDir(repo)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    # The FILES stack's strip is the body's first row; click its VCS tab.
    let strip = sess.regionText(1, 0, Cols, 1)
    let at = strip.find(" VCS ")
    ck at >= 0
    sess.sendMouseClick(1, at + 2)
    let screen = sess.waitFor("WORKING TREE (")
    # The pane's rows, read back from the screen, inside the pane only.
    let width = paneWidth(strip)
    var branchSeen = false
    var paneRows: seq[string] = @[]
    var sectionLine = ""
    var added, modified: Cell
    for row in 2 ..< Rows:
      let text = strutils.strip(sess.regionText(row, 0, width, 1),
                                leading = false)
      if text.startsWith("VCS ") and text.contains(desk["branch"].getStr):
        branchSeen = true
      if text.startsWith("WORKING TREE"):
        sectionLine = text
      if text.startsWith("COMMITS"):
        break
      if sectionLine.len > 0 and text.len > 3 and text[0] == ' ' and
          text[2] == ' ' and text[1] in {'M', 'A', 'D', 'R', 'C', 'U', '?'}:
        paneRows.add $text[1] & " " & text[3 .. ^1]
        if text[1] == 'A': added = sess.cellAt(row, 1)
        if text[1] == 'M': modified = sess.cellAt(row, 1)
    checkpoint("terminal rows: " & $paneRows & "  desktop rows: " & $deskRows)
    ck branchSeen
    ck deskRows == @["A added.txt", "M notes.txt", "? scratch.txt"]
    ck paneRows == deskRows
    ck not screen.contains("unchanged.txt")
    ck sectionLine == "WORKING TREE (" & $deskRows.len & ")"
    ck desk["header"].getStr.toUpperAscii.startsWith("WORKING TREE")
    # The letters are coloured by state: new files one colour, a
    # modification another.
    ck colorKey(added.fg) != colorKey(modified.fg)
    ck caBold in added.attrs and caBold in modified.attrs

    # A CHANGE WHILE IT RUNS: a second untracked file appears within the
    # refresh budget, as it does on the desktop.
    writeFile(repo / "later.txt", "created while the terminal runs\n")
    discard sess.waitFor("? later.txt", RefreshBudgetMs)
    ck sess.screenContents().contains("WORKING TREE (4)")
    sess.send(":quit\r")
    ck sess.waitExit(initDuration(seconds = 30)) == some(0)
    sess.close()
    removeDir(repo.parentDir)

  test "outside a repository the pane says so":
    let resolved = resolveFixture("calc")
    ck resolved.outcome == foRecorded
    let dir = createTempDir("plat47-novcs-tui-", "")
    var sess = newTuiTest(tuiBinary(), @[resolved.tracePath])
      .width(Cols).height(Rows).workDir(dir)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    let strip = sess.regionText(1, 0, Cols, 1)
    let at = strip.find(" VCS ")
    sess.sendMouseClick(1, at + 2)
    ck sess.waitFor("Not a git repository").contains("Not a git repository")
    sess.send(":quit\r")
    discard sess.waitExit(initDuration(seconds = 30))
    sess.close()
    removeDir(dir)

  test "assertion count":
    check countedAssertions == ExpectedAssertions
