## test_real_plat45_layout.nim — PLAT-45, Tier 2. **The shipped terminal
## binary, on a real PTY: the shared default, its fold, and the layout the
## terminal remembers — its own and nobody else's.**
##
## ## What only a real terminal can say here
##
##   1. **The fold at the three sizes the old §3.2 named** (80x24, 120x40,
##      200x50), read off the SCREEN a real terminal state machine parsed: the
##      tab strips of the shared default's regions are where the arrangement
##      puts them, and the status line carries `[folded N]` exactly when the
##      terminal folded — so a user of the old compact profile sees the change
##      measured rather than asserted about a model.
##   2. **The terminal remembers its own last layout** (PLAT-45 deliverable 8),
##      across two real processes and a real file: a first run on an empty
##      state directory opens the shared default and writes nothing; `:dock
##      bottom` is written THROUGH (the file exists before the process exits);
##      a second run opens the docked arrangement; `:reset-layout` returns the
##      shared default and deletes ONLY the terminal's file — a GPUI file
##      beside it is left byte for byte.
##   3. **A corrupt document is reported and the launch goes on**: the status
##      line names the kind, the screen is the shared default, and the file is
##      left exactly as it was found.
##
## No flag is passed for any of this: since PLAT-45 the layout is the user's
## by default. Each case points the binary at a state directory of its own
## (`CODETRACER_TUI_LAYOUT_DIR`), so nothing here reads or writes the machine's
## own `~/.local/state/codetracer`.
##
## ## No mocks
##
## A compiled binary on a real recording (`calc`) in a real pty, parsed by
## libvterm through TermAssert, writing a real file under a real temporary
## directory.

import std/[json, monotimes, options, os, strutils, tempfiles, times, unittest]

import term_assert

import headless_app/layout_model

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 48

const
  FixtureName = "calc"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  TuiDocument = "tui-layout.json"
  GpuiDocument = "gpui-layout.json"
  FrameTimeoutMs = 30000

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

var tracePath = ""

proc spawnTui(stateDir: string; cols, rows: int): TuiTestSession =
  newTuiTest(tuiBinary(), @[tracePath])
    .width(cols).height(rows)
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", "xterm-256color")
    .envSet("LANG", "en_US.UTF-8")
    .envSet(StateDirEnvVar, stateDir)
    .spawn()

proc waitForScreen(sess: var TuiTestSession; needle: string): string =
  ## Drain until the screen contains `needle`; raise naming what it held.
  let deadline = getMonoTime() + initDuration(milliseconds = FrameTimeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = sess.screenContents()
    if last.contains(needle):
      return last
    if not sess.isAlive:
      raise newException(AssertionFailedError,
        "the binary exited before '" & needle & "' appeared; screen:\n" & last)
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared; screen:\n" & last)

proc quit(sess: var TuiTestSession): Option[int] =
  sess.send(":quit\r")
  result = sess.waitExit(initDuration(seconds = 30))
  sess.close()

proc freshStateDir(tag: string): string =
  createTempDir("plat45-" & tag & "-", "")

suite "PLAT-45 Tier 2: the shared default on a real terminal":

  test "the binary and the fixture exist":
    if not fileExists(tuiBinary()):
      checkpoint("missing " & tuiBinary() & " — run `just build-tui`")
    ck fileExists(tuiBinary())
    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail & " — `just test-tui` records it")
    ck resolved.outcome == foRecorded
    tracePath = resolved.tracePath

  test "the three old §3.2 sizes: the shared default, folded only at 80x24":
    # The strips are the shared default's regions, read off the screen. At
    # 80x24 the source pane's 60-cell minimum folds four regions, leaving the
    # Variables and Event Log stacks beside it (Files and the Call Stack are
    # tabs of the first, the NS9 panes of the second); the unfolded sizes
    # show every region as its own, and only the folded one says so on the
    # status line.
    for (cols, rows, folded) in [(80, 24, 4), (120, 40, 0), (200, 50, 0)]:
      let dir = freshStateDir("fold")
      var sess = spawnTui(dir, cols, rows)
      settleOnDebugger(sess, cols, rows)
      let screen = sess.screenContents()
      let status = statusRowText(sess, cols, rows)
      checkpoint($cols & "x" & $rows & " status: " & status)
      ck screen.contains("[Variables]")
      ck screen.contains("[Event Log]")
      if folded > 0:
        ck status.contains("[folded " & $folded & "]")
        # Folded regions are tabs now, not regions of their own.
        ck not screen.contains("[Files]")
        ck not screen.contains("[Call Stack]")
        ck not screen.contains("[Test Results]")
      else:
        ck not status.contains("[folded")
        ck screen.contains("[Files]")
        ck screen.contains("[Call Stack]")
        ck screen.contains("[Test Results]")
        ck screen.contains("[Constraints]")
      ck quit(sess) == some(0)
      # AN UNTOUCHED SESSION WRITES NOTHING — no gesture, no document.
      ck not fileExists(dir / TuiDocument)
      removeDir(dir)

  test "the terminal remembers ITS OWN layout, written through, and reset deletes only its file":
    let dir = freshStateDir("remember")
    # A GPUI document beside the terminal's, planted — a REAL arrangement,
    # with the Files pane docked away, so a terminal that read it would open
    # without its Files strip. The terminal must never read it, and its reset
    # must never touch it.
    let docked = apply(initLayout(sharedDefaultLayout().tree),
                       cmdDock(paneFileTree, leBottom))
    ck docked.kind == loApplied
    let gpuiBytes = pretty(saveLayout(docked.layout)) & "\n"
    writeFile(dir / GpuiDocument, gpuiBytes)
    const Cols = 120
    const Rows = 40

    var first = spawnTui(dir, Cols, Rows)
    settleOnDebugger(first, Cols, Rows)
    # THE SHARED DEFAULT, with nothing remembered.
    ck first.screenContents().contains("[Files]")
    ck not fileExists(dir / TuiDocument)
    # Focus the Files region (the first `Tab` stop) and dock it.
    first.send(":dock bottom\r")
    discard waitForScreen(first, "applied")
    # WRITTEN THROUGH: the file is there BEFORE the process exits.
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while not fileExists(dir / TuiDocument) and getMonoTime() < deadline:
      discard first.drainOutput(40)
    ck fileExists(dir / TuiDocument)
    ck quit(first) == some(0)
    let saved = readFile(dir / TuiDocument)
    ck saved.contains("\"docked\"")
    ck saved.contains("\"edge\": \"bottom\"")

    # THE SECOND PROCESS OPENS THE REMEMBERED ARRANGEMENT.
    var second = spawnTui(dir, Cols, Rows)
    settleOnDebugger(second, Cols, Rows)
    let restoredScreen = second.screenContents()
    checkpoint("restored: " & statusRowText(second, Cols, Rows))
    # The docked pane is no longer a region: its strip is gone.
    ck not restoredScreen.contains("[Files]")
    # :reset-layout — the way back — deletes the terminal's document.
    second.send(":reset-layout\r")
    discard waitForScreen(second, "[Files]")
    let gone = getMonoTime() + initDuration(seconds = 10)
    while fileExists(dir / TuiDocument) and getMonoTime() < gone:
      discard second.drainOutput(40)
    ck not fileExists(dir / TuiDocument)
    ck quit(second) == some(0)
    ck not fileExists(dir / TuiDocument)
    # AND ONLY ITS OWN: the GPUI file is byte for byte what was planted.
    ck fileExists(dir / GpuiDocument)
    ck readFile(dir / GpuiDocument) == gpuiBytes

    # A THIRD START after the reset: the shared default again.
    var third = spawnTui(dir, Cols, Rows)
    settleOnDebugger(third, Cols, Rows)
    ck third.screenContents().contains("[Files]")
    ck quit(third) == some(0)
    removeDir(dir)

  test "a corrupt document is reported on the status line, and left alone":
    let dir = freshStateDir("corrupt")
    let garbage = "{ this is not json"
    writeFile(dir / TuiDocument, garbage)
    const Cols = 160
    const Rows = 40
    var sess = spawnTui(dir, Cols, Rows)
    settleOnDebugger(sess, Cols, Rows)
    let status = statusRowText(sess, Cols, Rows)
    checkpoint("status: " & status)
    # THE USER IS TOLD, BY KIND — and the launch did not fail.
    ck status.contains("saved layout ignored (NotJson)")
    # The screen is the shared default.
    ck sess.screenContents().contains("[Files]")
    ck sess.screenContents().contains("[Test Results]")
    # A rearrangement in a quarantined session does not overwrite the file.
    sess.send(":dock bottom\r")
    discard sess.drainOutput(200)
    ck quit(sess) == some(0)
    ck readFile(dir / TuiDocument) == garbage
    removeDir(dir)

  test "assertion count":
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
