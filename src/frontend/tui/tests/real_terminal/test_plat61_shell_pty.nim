## test_plat61_shell_pty.nim — the Shell pane on a real terminal.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.
##
## The shipped `codetracer-tui` on the `calc` fixture, driven as a user drives
## it and read back off the screen through libvterm:
##
##   * `:shell` (through the omnibox) shows the SHELL pane, its shell running
##     at the pane's size, its prompt on screen;
##   * keys typed reach the shell; a recorded build run in it (a script that
##     writes a Python program and `ct record`s it) prints its output, and the
##     recording's lines carry the gutter — `●` on the first, `│` on the next;
##   * a click on the `●` opens the recording in a NEW session tab, named
##     after its folder (`rec-build`), and that tab's header shows the
##     recording's own program.
##
## No mocks: the real binary, a real `replay-server`, a real bash on the
## pane's pty, a real `ct record` with the pinned recorder, a real outer pty
## (TermAssert + libvterm).

import std/[monotimes, os, strutils, times, unittest]
from std/unicode import runeLen

import term_assert

import ./lifecycle_support
import ../fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 8

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 60
  CtrlP = "\x10"
  Enter = "\r"

proc rowOf(sess: var TuiTestSession; row: int): string =
  discard sess.drainOutput(40)
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc screen(sess: var TuiTestSession): seq[string] =
  discard sess.drainOutput(60)
  for r in 0 ..< Rows:
    result.add sess.rowOf(r)

proc waitScreen(sess: var TuiTestSession; ok: proc(s: seq[string]): bool;
                what: string; timeoutMs = 120000): seq[string] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    if ok(result):
      return
    sleep(100)
  raise newException(AssertionFailedError,
    what & " never appeared; screen:\n" & result.join("\n"))

proc press(sess: var TuiTestSession; row, col: int; button = 0) =
  sess.send("\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) & "m")

proc omnibox(sess: var TuiTestSession; line: string) =
  sess.send(CtrlP)
  sleep(150)
  sess.send(line)
  sleep(100)
  sess.send(Enter)

proc rowWith(s: seq[string]; text: string): int =
  for r, line in s:
    if text in line: return r
  -1

proc anyLine(s: seq[string]; text: string): bool = s.rowWith(text) >= 0

suite "PLAT-61 on a real terminal: the Shell pane":

  test "a recorded build in the pane's shell; a click opens its recording in a new tab":
    let fixture = resolveFixture("calc")
    if fixture.outcome != foRecorded:
      echo missingPrereqMessage(fixture.spec, fixture.detail)
      fail()
      return
    let ct = fixture_provider.findCtBinary()
    doAssert ct.len > 0, "`ct` is not built (just build-once)"
    let base = getTempDir() / ("plat61-pty-" & $getCurrentProcessId())
    removeDir(base)
    let project = base / "project"
    createDir(project)
    writeFile(project / "build.sh", """#!/bin/sh
cd "$(dirname "$0")"
echo "building prog.py"
printf 'def add(a, b):\n    return a + b\nprint("sum", add(2, 3))\nprint("done")\n' > prog.py
rm -rf rec-build
ct record -o rec-build prog.py
""")
    setFilePermissions(project / "build.sh",
                       {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(base / "shellrc", "PS1='$ '\n")
    let state = base / "state"
    createDir(state / "ct-home")
    writeFile(state / "ct-home" / ".codetracer-test-home", "")
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", fixture.tracePath])
      .width(Cols).height(Rows).transcript()
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("XDG_STATE_HOME", state)
      .envSet("CODETRACER_HOME", state / "ct-home")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
      .envSet("CODETRACER_SHELL_COMMAND",
              "bash --noprofile --rcfile " & base / "shellrc" & " -i")
      .envSet("PATH", ct.parentDir & PathSep & getEnv("PATH"))
      .spawn()
    settleOnDebugger(sess, Cols, Rows)

    # `:shell`: the pane, its shell, its prompt.
    sess.omnibox(":shell")
    var s = sess.waitScreen(proc(s: seq[string]): bool =
      s.anyLine("SHELL  running"), "the SHELL pane running")
    ck s.anyLine("SHELL  running")

    # The recorded build, typed into the shell.
    sess.send("cd " & project & Enter)
    sleep(300)
    sess.send("printf '\\033[H\\033[2J\\033[3J'" & Enter)
    sleep(300)
    sess.send("./build.sh" & Enter)
    s = sess.waitScreen(proc(s: seq[string]): bool =
      s.anyLine("recordingId:") and s.anyLine("1 recording"),
      "the recorded build")
    let built = s.rowWith("building prog.py")
    let first = s.rowWith("● sum 5")
    ck built > 0 and first == built + 1
    ck s[first + 1].contains("│ done")
    ck s[first + 2].contains("recordingId:") and
       not s[first + 2].contains("│")
    ck s.anyLine("SHELL  running — 1 recording")

    # A click on the `●`: a new session tab, the recording's.
    let at = s[first].find("● sum 5")
    ck at >= 0
    let col = s[first][0 ..< max(0, at)].runeLen   # a cell per character
    sess.press(first, col)
    s = sess.waitScreen(proc(s: seq[string]): bool =
      s[0 .. 2].anyLine("rec-build"), "the recording's tab")
    ck s[0 .. 2].anyLine("rec-build")
    s = sess.waitScreen(proc(s: seq[string]): bool =
      s.anyLine("prog.py"), "the opened recording's program")
    ck s.anyLine("prog.py")

    # Ctrl+Q, the CUA base's quit — after the prefix, in case the shell has
    # the keys.
    sess.send("\x1d")
    sess.send("\x11")
    discard sess.waitExit(initDuration(seconds = 10))
    sess.terminate()
    sess.close()
    removeDir(base)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
