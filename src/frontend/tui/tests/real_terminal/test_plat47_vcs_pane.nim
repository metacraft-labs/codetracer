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
## ## AND IN EDIT MODE, WHERE THE PANE COULD NOT BE SHOWN AT ALL
##
## `codetracer-tui --edit <repo>` (`main.editInteractive`, what `ct edit
## --ui=tui` hands off to) draws Edit mode's arrangement — the FILES stack
## holds Files and VCS — and keeps a `VcsSource` on the project refreshed, and
## until codetracer-pm issue 2026-10-21 ("the terminal's Edit mode keeps a VCS
## pane up to date that the user cannot show") the user had no way to choose
## the VCS tab: that loop enabled no layout binding, and `handleToken` routes a
## mouse report to the layout only when one is enabled. The third case below is
## that issue's real-PTY check, on the same repository with no recording at
## all. It asserts, from the screen:
##
##   * FRAME 0 IS EDIT MODE'S ARRANGEMENT, unchanged by the binding the fix
##     enables: the `[EDIT]` indicator, the Files list (the project's files,
##     `unchanged.txt` among them), the Files and VCS tabs on the stack's
##     strip, the Build pane, and none of Debug mode's panes;
##   * a real click on ` VCS ` shows the pane — the desktop's rows under
##     `WORKING TREE (3)` — and the Files list gives way to it. Against a build
##     without the binding the click is dropped and the case fails waiting for
##     `WORKING TREE`, which is the issue's own measurement;
##   * THE TERMINAL'S REMEMBERED ARRANGEMENT IS NOT EDIT MODE'S TO READ OR
##     WRITE. That document is the replay loop's Debug arrangement and is not
##     keyed by mode (`views/shell.switchTo` on §4b's second tier), so the edit
##     loop binds none. A document planted in the state directory is neither
##     restored (no saved-layout message, Edit's arrangement on screen) nor
##     rewritten by the click or the quit: its bytes are what was planted;
##   * AFTER A ROUND TRIP (`Ctrl+F5` twice) the VCS pane is still in front and
##     the Files and VCS tabs still answer a click (Mode-Transitions.md §4.6).
##
## The fourth case is the same reachability on the other route into Edit
## mode: the replay loop toggled into it with `Ctrl+F5`, where the click used
## to be hit-tested against Debug mode's tree while Edit's was drawn.
##
## No mocks: a real git repository, the real binary on a real recording (or,
## in Edit mode, a real project) in a real PTY (TermAssert + libvterm).

import std/[json, monotimes, options, os, osproc, strutils, tempfiles, times,
            unicode, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 38

const
  Cols = 200
  Rows = 50
  Capture = "src/tests/visual/answers/plat47-vcs.electron.json"
  RefreshBudgetMs = 15000
    ## The pane refreshes every 5 s (the desktop's `refreshIntervalMs`); three
    ## intervals of slack for a loaded host.
  CtrlF5 = "\x1b[15;5~"
    ## The product-mode toggle: `CSI 15 ; 5 ~` (F5 with Ctrl).
    ## https://invisible-island.net/xterm/ctlseqs/ctlseqs.html

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
  ## strip row (PLAT-50: `▏`, `shell.DividerGlyph`, in the strip's ground).
  var i = 0
  for r in strip.runes:
    if r == "▏".runeAt(0):
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
      # Its OWN state directory: clicking the VCS tab is a layout change the
      # binary remembers on quit, and a document left in the lane's shared
      # directory would be restored by every later suite of the lane.
      .envSet("CODETRACER_TUI_LAYOUT_DIR",
              getEnv("CODETRACER_TUI_LAYOUT_DIR") / "vcs-pane")
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
      if text.startsWith("on ") and text.contains(desk["branch"].getStr):
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
      .envSet("CODETRACER_TUI_LAYOUT_DIR",
              getEnv("CODETRACER_TUI_LAYOUT_DIR") / "vcs-pane-outside")
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

  test "in Edit mode the VCS tab is chosen with a click, as in a replay":
    # codetracer-pm issue 2026-10-21. `--edit` opens the repository as a
    # PROJECT: no recording, no `replay-server`, so this case needs neither.
    let repo = fixtureRepo()
    # A PLANTED DOCUMENT, deliberately unreadable as a layout: an edit loop
    # that restored it would quarantine it and say so on the status line, and
    # one that wrote through would replace these bytes.
    let stateDir = getEnv("CODETRACER_TUI_LAYOUT_DIR") / "vcs-pane-edit"
    createDir(stateDir)
    let document = stateDir / "tui-layout.json"
    const Planted = "not a layout: the replay loop's document, left alone\n"
    writeFile(document, Planted)
    var sess = newTuiTest(tuiBinary(), @["--edit", repo])
      .width(Cols).height(Rows)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", stateDir)
      .spawn()
    # FRAME 0: Edit mode's arrangement, with the Files list in front.
    let first = sess.waitFor("unchanged.txt")
    checkpoint("frame 0:\n" & first)
    ck first.contains("[EDIT]")
    let strip = sess.regionText(1, 0, Cols, 1)
    ck strip.contains(" Files ")
    let at = strip.find(" VCS ")
    ck at >= 0
    ck first.contains(" Build & Run ")
    ck not first.contains("CALL STACK")
    ck not first.contains("WORKING TREE")
    # Not restored: an unreadable document read at startup is announced.
    ck not first.contains("saved layout")

    # THE CLICK, on the VCS tab of the FILES stack.
    sess.sendMouseClick(1, at + 2)
    let screen = sess.waitFor("WORKING TREE (3)")
    checkpoint("after the click:\n" & screen)
    let width = paneWidth(strip)
    var paneRows: seq[string] = @[]
    var branchSeen = false
    for row in 2 ..< Rows:
      let text = strutils.strip(sess.regionText(row, 0, width, 1),
                                leading = false)
      if text.startsWith("on ") and text.contains("plat47-vcs"):
        branchSeen = true
      if text.startsWith("COMMITS"):
        break
      if text.len > 3 and text[0] == ' ' and text[2] == ' ' and
          text[1] in {'M', 'A', 'D', 'R', 'C', 'U', '?'}:
        paneRows.add $text[1] & " " & text[3 .. ^1]
    checkpoint("edit-mode VCS rows: " & $paneRows)
    ck branchSeen
    ck paneRows == @["A added.txt", "M notes.txt", "? scratch.txt"]
    # The Files list gave way to the pane: the untouched file is listed by the
    # file tree only, so it is gone with it.
    ck not screen.contains("unchanged.txt")
    ck screen.contains("[EDIT]")

    # AND AFTER A ROUND TRIP (Mode-Transitions.md §4.6, "a switch carries the
    # gestures with it"): Ctrl+F5 to Debug and back restores the arrangement
    # left — the VCS pane in front — and the tabs still answer a click. Before
    # the toggle swapped the binding's arrangement, the round trip left the
    # frame drawing a snapshot of the tree, so the Files click below changed
    # what a click hits and not what the screen shows.
    sess.send(CtrlF5)
    discard sess.waitFor("[DEBUG]")
    sess.send(CtrlF5)
    let back = sess.waitFor("[EDIT]")
    ck back.contains("WORKING TREE (3)")
    let backStrip = sess.regionText(1, 0, Cols, 1)
    let filesAt = backStrip.find(" Files ")
    ck filesAt >= 0
    sess.sendMouseClick(1, filesAt + 2)
    ck sess.waitFor("unchanged.txt").contains("unchanged.txt")
    sess.sendMouseClick(1, backStrip.find(" VCS ") + 2)
    ck sess.waitFor("WORKING TREE (3)").contains("? scratch.txt")

    # Ctrl+Q, the CUA base's quit (`:` is text in an Edit-mode buffer).
    sess.send("\x11")
    ck sess.waitExit(initDuration(seconds = 30)) == some(0)
    # NEITHER THE CLICK NOR THE QUIT TOUCHED THE TERMINAL'S DOCUMENT.
    ck fileExists(document)
    ck readFile(document) == Planted
    sess.close()
    removeDir(repo.parentDir)

  test "in a replay toggled into Edit mode, a click on VCS shows the pane":
    # The replay loop's `Ctrl+F5` onto Edit mode draws Edit's arrangement;
    # its VCS tab must answer a click on the cells it is drawn on. Before the
    # toggle swapped the binding's arrangement the click was hit-tested
    # against Debug's tree and the frame did not move.
    let resolved = resolveFixture("calc")
    ck resolved.outcome == foRecorded
    let repo = fixtureRepo()
    var sess = newTuiTest(tuiBinary(), @[resolved.tracePath])
      .width(Cols).height(Rows).workDir(repo)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("CODETRACER_TUI_LAYOUT_DIR",
              getEnv("CODETRACER_TUI_LAYOUT_DIR") / "vcs-pane-toggled")
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    sess.send(CtrlF5)
    let edit = sess.waitFor("[EDIT]")
    ck not edit.contains("WORKING TREE")
    let strip = sess.regionText(1, 0, Cols, 1)
    let at = strip.find(" VCS ")
    ck at >= 0
    sess.sendMouseClick(1, at + 2)
    ck sess.waitFor("WORKING TREE (3)").contains("? scratch.txt")
    sess.send("\x11")
    ck sess.waitExit(initDuration(seconds = 30)) == some(0)
    sess.close()
    removeDir(repo.parentDir)

  test "assertion count":
    check countedAssertions == ExpectedAssertions
