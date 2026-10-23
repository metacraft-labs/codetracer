## test_plat47_vcs_focus_refresh.nim — PLAT-47 deliverable 4, Tier 2. **The
## terminal's VCS pane re-reads its repository when the terminal window
## regains focus, as the desktop's panel does when its window does.**
##
## The desktop's VCS panel refreshes on two triggers (VCS-Panel.md's
## auto-refresh, `ui/vcs.nim` `startFileWatching`): every `refreshIntervalMs`
## (5 s) and on the window's `focus` event, so returning to CodeTracer after
## committing in another program shows the commit at once. The terminal had
## only the first (codetracer-pm issue 2026-09-30, "the terminal's and GPUI's
## VCS panes do not refresh when their window regains focus"): it requested no
## focus reporting, and nothing in its loop answered `CSI I`. This suite is
## that issue's real-PTY check, on `test_plat47_vcs_pane.nim`'s arrangement:
## the shipped `codetracer-tui` opens the `calc` recording with its working
## directory inside a real git repository (`scripts/plat47-vcs-fixture.sh`) —
## the directory the desktop's VCS panel reads for a replay is the process's
## own — and the VCS tab is chosen with a real mouse click. Then:
##
##   * the binary ASKS for focus reporting: `CSI ? 1004 h` is in the bytes it
##     wrote, and `CSI ? 1004 l` is in them after it quit;
##   * a file created in the repository appears in the VCS pane when the
##     terminal reports the focus gain (`CSI I`), WELL BEFORE THE INTERVAL
##     COULD HAVE RE-READ IT. The interval's phase is pinned first — a file is
##     created and the pane is waited on WITHOUT any focus report, so the
##     interval's own re-read is observed and the next one is known to be
##     `VcsIntervalMs` away — and then the second file must appear within
##     `FocusBudgetMs` of the `CSI I`, which is less than half the interval.
##     Against a binary without the focus trigger the second file appears only
##     at the next interval, ~5 s after the first, and the case fails on that
##     budget;
##   * neither report is a key: the debugger's status (`tick: …` and the
##     run state on the top bar) is what it was before them;
##   * A SIGNAL GIVES THE MODE BACK TOO. A binary killed by `SIGTERM` exits
##     through `nim-termctl`'s async-signal-safe restore, not through
##     `TerminalDriver.stop`, and still writes `CSI ? 1004 l` after its last
##     `CSI ? 1004 h`. A terminal left in mode 1004 prints `^[[I` / `^[[O`
##     into the user's shell on every window switch, so this is the exit path
##     whose omission the user would see. It holds only while the driver asks
##     for the mode through `enableFocusReporting`, the call that tells the
##     signal handler the mode is on; writing the bytes directly would pass
##     the quit-key case above and fail this one.
##
## THE EDIT-MODE LOOP (`main.editInteractive`) answers `dekFocus` with the same
## `VcsSource.refreshOnFocus` call, and the third case drives it: the shipped
## binary opens the repository with `--edit` (no recording), the VCS tab is
## chosen with a real click, and the same interval-pinned budget applies. Until
## codetracer-pm issue 2026-10-21 ("the terminal's Edit mode keeps a VCS pane
## up to date that the user cannot show") this path could not be tested at
## all: that loop enabled no layout binding, so the click was dropped and the
## pane was never on screen to read. In Edit mode the focus reports must not
## be TEXT either — the editor has the keyboard there, so a report mistaken
## for keys would be typed into the open buffer: the buffer's tab carries no
## dirty marker after them, and no `[I` / `[O` reached the screen.
##
## No mocks: a real git repository changed by another program, the real
## binary on a real recording in a real PTY (TermAssert + libvterm). The
## focus reports are the bytes a terminal writes when its window gains and
## loses focus — libvterm has no window to focus, so the suite writes them as
## the terminal would (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html,
## "FocusIn/FocusOut").

import std/[monotimes, options, os, osproc, posix, strutils, tempfiles,
            times, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 28

const
  Cols = 200
  Rows = 50
    ## `test_plat47_vcs_pane.nim`'s geometry: the FILES stack's strip on the
    ## body's first row.
  VcsIntervalMs = 5000
    ## `vcs_vm.VCSRefreshIntervalMs` — the desktop's `refreshIntervalMs`.
  IntervalBudgetMs = 3 * VcsIntervalMs
    ## How long the pinning step may wait for the interval's own re-read:
    ## three intervals of slack for a loaded host.
  FocusBudgetMs = 2000
    ## How long after `CSI I` the new row must be on screen. Less than half
    ## the interval, so only the focus trigger can meet it; generous against
    ## a loaded host, where the focus re-read itself is one `git status`.
  FocusIn = "\e[I"
  FocusOut = "\e[O"

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc waitFor(sess: var TuiTestSession; needle: string;
             timeoutMs = 30000): string =
  ## Drain until the screen contains `needle`; raise naming what it held.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(20)
    result = sess.screenContents()
    if result.contains(needle):
      return
    if not sess.isAlive:
      break
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared within " & $timeoutMs & " ms; screen:\n" &
    result)

proc statusOf(screen: string): string =
  ## The top bar's debugger status — `tick: <n> [<state>]` — which any key a
  ## focus report were mistaken for (a step, a continue) would move.
  let lines = screen.splitLines()
  if lines.len == 0:
    return ""
  let at = lines[0].find("tick:")
  if at < 0: "" else: strutils.strip(lines[0][at .. ^1])

proc fixtureRepo(): string =
  result = createTempDir("plat47-vcs-focus-tui-", "") / "repo"
  let (output, code) = execCmdEx("bash " &
    quoteShell(lifecycle_support.repoRoot() / "scripts" / "plat47-vcs-fixture.sh") &
    " " & quoteShell(result))
  if code != 0:
    checkpoint(output)
  doAssert code == 0

suite "PLAT-47 deliverable 4: the terminal's VCS pane refreshes on focus":

  test "CSI I re-reads the repository before the interval could have":
    let resolved = resolveFixture("calc")
    ck resolved.outcome == foRecorded
    let repo = fixtureRepo()
    var sess = newTuiTest(tuiBinary(), @[resolved.tracePath])
      .width(Cols).height(Rows).workDir(repo)
      .transcript()
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      # Its OWN state directory: clicking the VCS tab is a layout change the
      # binary remembers on quit.
      .envSet("CODETRACER_TUI_LAYOUT_DIR",
              getEnv("CODETRACER_TUI_LAYOUT_DIR") / "vcs-focus-pane")
      .carryRunMark()
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    # THE REQUEST: DECSET 1004, written by `terminal_driver.start`.
    ck sess.transcriptBytes().contains("\e[?1004h")
    # The FILES stack's strip is the body's first row; click its VCS tab.
    let strip = sess.regionText(1, 0, Cols, 1)
    let at = strip.find(" VCS ")
    ck at >= 0
    sess.sendMouseClick(1, at + 2)
    discard sess.waitFor("WORKING TREE (3)")

    # PIN THE INTERVAL'S PHASE: a change made with NO focus report shows up
    # only through the interval's own re-read, and once it has, the next
    # re-read by the interval is `VcsIntervalMs` away.
    writeFile(repo / "first.txt", "picked up by the interval\n")
    let before = sess.waitFor("? first.txt", IntervalBudgetMs)
    let intervalReadAt = getMonoTime()

    # The user leaves the terminal (`CSI O`), another program creates a file,
    # and the user comes back (`CSI I`).
    sess.send(FocusOut)
    writeFile(repo / "second.txt", "picked up by the focus regain\n")
    let changedAt = getMonoTime()
    sess.send(FocusIn)
    let screen = sess.waitFor("? second.txt", FocusBudgetMs)
    let afterFocus = (getMonoTime() - changedAt).inMilliseconds
    let sinceInterval = (getMonoTime() - intervalReadAt).inMilliseconds
    checkpoint("second.txt on screen " & $afterFocus & " ms after CSI I, " &
               $sinceInterval & " ms after the interval's re-read")
    ck afterFocus < FocusBudgetMs
    # The interval cannot have done it: its next re-read is still ahead.
    ck sinceInterval < VcsIntervalMs
    ck screen.contains("WORKING TREE (5)")
    # Neither report was a key: the debugger did not move.
    checkpoint("status before: '" & statusOf(before) & "' after: '" &
               statusOf(screen) & "'")
    ck statusOf(before).len > 0
    ck statusOf(screen) == statusOf(before)

    sess.send(":quit\r")
    ck sess.waitExit(initDuration(seconds = 30)) == some(0)
    # The mode was given back on the way out.
    ck sess.transcriptBytes().contains("\e[?1004l")
    sess.close()
    removeDir(repo.parentDir)

  test "SIGTERM gives focus reporting back, as the quit key does":
    let resolved = resolveFixture("calc")
    ck resolved.outcome == foRecorded
    let repo = fixtureRepo()
    var sess = newTuiTest(tuiBinary(), @[resolved.tracePath])
      .width(Cols).height(Rows).workDir(repo)
      .transcript()
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("CODETRACER_TUI_LAYOUT_DIR",
              getEnv("CODETRACER_TUI_LAYOUT_DIR") / "vcs-focus-signal")
      # THIS RUN'S MARK: `noSurvivingReplayServer` below counts only engines
      # that carry it, so without it this session's leak would pass unseen.
      .carryRunMark()
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    # On while the session is live, and not yet given back.
    let live = sess.transcriptBytes()
    ck live.contains("\e[?1004h")
    ck not live.contains("\e[?1004l")
    sess.sendSignal(SIGTERM)
    let status = sess.waitExit(initDuration(seconds = 30))
    checkpoint("SIGTERM -> exit " &
               (if status.isSome: $status.get() else: "none"))
    # Killed BY the signal (`nim-pty` reports `-WTERMSIG`), so the restore
    # ran in the handler and not on a normal return through `stop`.
    ck status == some(-int(SIGTERM))
    let bytes = sess.transcriptBytes()
    ck bytes.rfind("\e[?1004l") > bytes.rfind("\e[?1004h")
    ck sess.transcriptDroppedBytes() == 0
    ck noSurvivingReplayServer()
    sess.close()
    removeDir(repo.parentDir)

  test "in Edit mode, CSI I re-reads the project before the interval could have":
    # The edit loop's `dekFocus` arm, reached the way a user reaches it: the
    # VCS tab chosen with a click, which needs the layout binding that loop
    # now enables. No recording and no `replay-server`.
    let repo = fixtureRepo()
    var sess = newTuiTest(tuiBinary(), @["--edit", repo])
      .width(Cols).height(Rows)
      .transcript()
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("CODETRACER_TUI_LAYOUT_DIR",
              getEnv("CODETRACER_TUI_LAYOUT_DIR") / "vcs-focus-edit")
      .spawn()
    discard sess.waitFor("[EDIT]")
    ck sess.transcriptBytes().contains("\e[?1004h")
    let strip = sess.regionText(1, 0, Cols, 1)
    let at = strip.find(" VCS ")
    ck at >= 0
    sess.sendMouseClick(1, at + 2)
    discard sess.waitFor("WORKING TREE (3)")

    # PIN THE INTERVAL'S PHASE, exactly as in the replay case above.
    writeFile(repo / "first.txt", "picked up by the interval\n")
    discard sess.waitFor("? first.txt", IntervalBudgetMs)
    let intervalReadAt = getMonoTime()

    sess.send(FocusOut)
    writeFile(repo / "second.txt", "picked up by the focus regain\n")
    let changedAt = getMonoTime()
    sess.send(FocusIn)
    let screen = sess.waitFor("? second.txt", FocusBudgetMs)
    let afterFocus = (getMonoTime() - changedAt).inMilliseconds
    let sinceInterval = (getMonoTime() - intervalReadAt).inMilliseconds
    checkpoint("edit mode: second.txt on screen " & $afterFocus &
               " ms after CSI I, " & $sinceInterval &
               " ms after the interval's re-read")
    ck afterFocus < FocusBudgetMs
    ck sinceInterval < VcsIntervalMs
    ck screen.contains("WORKING TREE (5)")
    # Neither report was typed into the open buffer.
    ck screen.contains("[EDIT]")
    ck not screen.contains(".txt ●")
    ck not screen.contains("[I")
    ck not screen.contains("[O")

    # Ctrl+Q, the CUA base's quit (`:` is text in an Edit-mode buffer).
    sess.send("\x11")
    ck sess.waitExit(initDuration(seconds = 30)) == some(0)
    ck sess.transcriptBytes().contains("\e[?1004l")
    sess.close()
    removeDir(repo.parentDir)

  test "assertion count":
    check countedAssertions == ExpectedAssertions
