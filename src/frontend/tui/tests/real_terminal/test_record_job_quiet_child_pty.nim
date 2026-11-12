## test_record_job_quiet_child_pty.nim — Tier 2: the window keeps answering
## while a welcome tab's `ct record` is quiet.
##
## The welcome tab's *Record new trace* runs `ct record` in the background and
## the terminal polls it from the loop that reads input
## (`host/native_host.pollRecordJob`). That poll used `osproc.hasData`, a
## `select` with no timeout on POSIX: while the recorded program printed
## nothing, the poll did not return, so the loop read no input and painted
## nothing until the program wrote again or exited
## (codetracer-pm `issues/2026-11-08-the-native-record-job-poll-blocks-the-window-on-a-quiet-child.md`).
## `test_native_record_job_poll.nim` holds the poll itself to returning at
## once; this suite holds the WINDOW to it, on the shipped binary.
##
## The recorded program is a real Python program that announces it is about
## to go quiet (by creating a file, not by printing, so the pipe stays empty)
## and then sleeps. While it sleeps the suite opens the File menu with the
## bytes a terminal sends (`Alt+F`) and requires the menu on the screen well
## before the program wakes. Afterwards the recording still opens in the tab,
## so the non-blocking poll lost nothing.
##
## No mocks: the shipped `codetracer-tui`, a real `ct record` (`CT_BIN`, else
## this checkout's debug build — the one `just build-once` puts there), the
## real Python recorder, a real `replay-server`, a real pty.

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 5

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  QuietSeconds = 15
    ## How long the recorded program sleeps without writing anything.
  AnswerWithinMs = 4000
    ## The menu must be on the screen this soon after `Alt+F`: well inside
    ## the quiet stretch, and generous for a loaded host.

proc ctUnderTest(): string =
  ## `CT_BIN` when the environment names one, else this checkout's debug
  ## build; pinned into the child's `CT_BIN`, so the `ct` this suite checks is
  ## the one the terminal runs.
  let named = getEnv("CT_BIN", "")
  if named.len > 0: named
  else: lifecycle_support.repoRoot() / "src" / "build-debug" / "bin" / "ct"

proc rowText(sess: var TuiTestSession; r: int): string =
  for c in 0 ..< Cols:
    let cell = sess.cellAt(r, c)
    result.add(if int(cell.rune) == 0: " " else: $cell.rune)

proc findOnScreen(sess: var TuiTestSession; needle: string): (int, int) =
  discard sess.drainOutput(40)
  for r in 0 ..< Rows:
    let line = sess.rowText(r)
    let at = line.find(needle)
    if at >= 0:
      return (r, line[0 ..< at].runeLen)
  (-1, -1)

proc waitFor(sess: var TuiTestSession; needle: string; timeoutMs = 20000):
    (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let at = sess.findOnScreen(needle)
    if at[0] >= 0:
      return at
    sleep(40)
  raise newException(AssertionFailedError, "never showed '" & needle & "'")

proc click(sess: var TuiTestSession; row, col: int) =
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m")

suite "a quiet ct record does not freeze the terminal":

  test "the File menu opens while the recorded program is silent":
    let ct = ctUnderTest()
    checkpoint("ct under test: " & ct)
    if not fileExists(ct):
      checkpoint("prerequisite missing: " & ct &
                 " (just build-once, or CT_BIN); the terminal is not run " &
                 "against any other ct")
    ck fileExists(ct)
    if fileExists(ct):
      let dir = getTempDir() / ("record-quiet-pty-" & $getCurrentProcessId())
      removeDir(dir)
      createDir(dir / "program")
      defer: removeDir(dir)
      let quietMarker = dir / "quiet-now"
      let program = dir / "program" / "napper.py"
      writeFile(program,
        "import time\n" &
        "def nap(seconds):\n" &
        "    open(" & escape(quietMarker) & ", 'w').close()\n" &
        "    time.sleep(seconds)\n" &
        "    return seconds\n\n" &
        "nap(" & $QuietSeconds & ")\n")
      let calc = resolveFixture("calc")
      require calc.outcome == foRecorded
      var sess = newTuiTest(tuiBinary(), @["--theme=dark", calc.tracePath])
        .width(Cols).height(Rows).transcript()
        .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                   "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
        .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
        .envSet("COLORTERM", "truecolor")
        .envSet("XDG_STATE_HOME", dir / "xdg")
        .envSet("CODETRACER_HOME", dir / "ct-home")
        .envSet("CODETRACER_TUI_LAYOUT_DIR", dir)
        .envSet("CT_BIN", ct)
        .spawn()
      settleOnDebugger(sess, Cols, Rows)
      let plus = sess.rowText(0).find(" + ")
      ck plus > 0
      sess.click(0, sess.rowText(0)[0 ..< plus].runeLen + 1)
      discard sess.waitFor("Welcome to CodeTracer")
      let (rr, rc) = sess.waitFor(" Record new trace ")
      sess.click(rr, rc + 2)
      discard sess.waitFor("Program to record")
      sess.send(program)
      sess.send("\r")
      # The program is under the recorder and has stopped writing.
      let started = getMonoTime()
      while not fileExists(quietMarker) and
            (getMonoTime() - started).inSeconds < 240:
        sleep(50)
      require fileExists(quietMarker)
      let quietSince = getMonoTime()
      discard sess.drainOutput(40)
      check sess.findOnScreen(" New Trace Tab ")[0] < 0
      sess.send("\x1bf")
      var answeredMs = -1
      let asked = getMonoTime()
      while (getMonoTime() - asked).inMilliseconds < QuietSeconds * 1000:
        if sess.findOnScreen(" New Trace Tab ")[0] >= 0:
          answeredMs = int((getMonoTime() - asked).inMilliseconds)
          break
        sleep(20)
      let stillQuiet = (getMonoTime() - quietSince).inSeconds < QuietSeconds
      let measured = "File menu answered after " & $answeredMs & " ms; " &
                     "program still asleep: " & $stillQuiet
      checkpoint(measured)
      echo "  # " & measured
      ck answeredMs >= 0 and answeredMs < AnswerWithinMs
      ck stillQuiet
      sess.send("\x1b")
      # The quiet stretch ends and the recording opens in the tab: the poll
      # that returned at once still saw the whole run through.
      let opening = getMonoTime()
      while (getMonoTime() - opening).inSeconds < 240:
        discard sess.drainOutput(40)
        if sess.rowText(0).contains("napper") and
           sess.findOnScreen("Welcome to CodeTracer")[0] < 0:
          break
        sleep(100)
      checkpoint("top bar: " & sess.rowText(0))
      ck sess.rowText(0).contains("napper")
      sess.send(":quit\r")
      discard sess.waitExit(initDuration(seconds = 15))
      sess.terminate()
      sess.close()

suite "quiet record job real terminal: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
