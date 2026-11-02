## test_edit_find_in_files_pty.nim — **Find in Files in the terminal's Edit
## mode searches the project**, in a real terminal.
##
## Spec: `GUI/Find-And-Incremental-Search.md` §5.1 — the scope of `:grep` is
## the recording's sources, and *"In Edit mode it is the project's root."*
## Edit mode docks Find in Files in its footer (the desktop's panels), and
## until this suite the terminal answered `:grep` there with "Find in Files
## needs a recording or a project to search" (GPUI drew the pane as a
## Debug-mode placeholder; codetracer-pm issue 2026-10-27).
##
## The shipped `codetracer-tui --edit <project>` in a real pty, its bytes
## parsed by libvterm (TermAssert), over a real temporary project:
##
##   * `:grep print('main')` lists the one matching line, under its file;
##   * `F4` (`search.next-result`) opens that file from the disk in the
##     editor, at the match, and says so on the status line.
##
## No mocks: the binary, the folder, the shared search runner, a real pty.

import std/[monotimes, os, strutils, tempfiles, times, unittest]
from std/unicode import `$`

import term_assert

import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 4

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 40

proc screen(sess: var TuiTestSession): string =
  discard sess.drainOutput(80)
  for r in 0 ..< Rows:
    for c in 0 ..< Cols:
      let rune = sess.cellAt(r, c).rune
      result.add(if int(rune) == 0: " " else: $rune)
    result.add "\n"

proc waitFor(sess: var TuiTestSession; needle: string;
             timeoutMs = 30000): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    if result.contains(needle):
      return
    sleep(50)
  raise newException(AssertionFailedError, "never showed '" & needle &
                     "'; screen:\n" & result)

proc omnibox(sess: var TuiTestSession; line: string) =
  sess.send("\x10")  # Ctrl+P
  sleep(200)
  sess.send(line)
  sleep(150)
  sess.send("\r")

suite "Edit mode: Find in Files searches the project, on a real terminal":

  test "`:grep` lists the project's matching line; F4 opens it in the editor":
    let project = createTempDir("ct-edit-grep-pty-", "")
    writeFile(project / "README.md", "# readme\n")
    createDir(project / "src")
    writeFile(project / "src" / "main.py", "print('main')\n")
    writeFile(project / "src" / "util.py", "def util():\n    return 1\n")
    let state = createTempDir("ct-edit-grep-state-", "")
    var sess = newTuiTest(tuiBinary(), @["--edit", project])
      .width(Cols).height(Rows)
      .workDir(project)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("XDG_STATE_HOME", state)
      .envSet("CODETRACER_HOME", state / "ct-home")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
      .carryRunMark()
      .spawn()
    discard sess.waitFor("[EDIT]")
    sess.omnibox(":grep print('main')")
    # The pane shows the one result, under its file, and the search did not
    # refuse for want of a recording.
    let listed = sess.waitFor("1 result in 1 file")
    ck not listed.contains("needs a recording")
    ck listed.contains("main.py")
    # F4: the next result, opened from the disk.
    sess.send("\x1bOS")
    let opened = sess.waitFor("main.py:1")
    ck opened.contains("opened ")
    ck opened.contains("print('main')")
    sess.send("\x11")  # Ctrl+Q
    discard sess.waitExit(initDuration(seconds = 10))
    sess.terminate()
    sess.close()
    removeDir(project)
    removeDir(state)

suite "Edit mode Find in Files: the assertion count":
  test "the assertion count":
    check countedAssertions == ExpectedAssertions
