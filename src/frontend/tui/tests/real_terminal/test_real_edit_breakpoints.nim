## PLAT-28 Tier 2 — a breakpoint set while editing, then the file edited above
## it and on it, through the SHIPPED terminal binary on a real pty.
##
## Run:
##   nim c -r <tui-real-terminal lane flags> \
##     src/frontend/tui/tests/real_terminal/test_real_edit_breakpoints.nim
##
## PLAT-28's real-stack box: *"Breakpoints set on a real file, then the file
## edited above them, with the resulting line numbers asserted."* The file is
## a real file in a real project directory; `F9` places the breakpoint, Vim's
## `O` opens a line above it and `dd` deletes its line, all typed as the bytes
## a terminal sends; the line numbers are READ OFF THE SCREEN — the gutter row
## carrying `●` and the line number printed beside it — never out of the
## process.
##
## NO MOCKS: a real pty, the shipped binary, a real project directory and a
## real state directory (`CODETRACER_TUI_LAYOUT_DIR`, PLAT-6's hook) holding
## the keymap preference `vim`.

import std/[monotimes, os, strutils, times, unittest]

import term_assert

import ./lifecycle_support

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 120
  Rows = 30
  FrameTimeoutMs = 20000
  ProjectFile = "doc.py"
  Text = "def first():\n    pass\ndef second():\n    return 2\ndef third():\n    return 3\n"
  BreakpointGlyph = "●"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  Esc = "\x1b"
  F9 = "\x1b[20~"

proc spawnEditor(name: string): (TuiTestSession, string) =
  let root = lifecycle_support.repoRoot() / "test-logs" / "plat28-edit-bp" / name
  removeDir(root)
  createDir(root / "project")
  createDir(root / "state")
  writeFile(root / "project" / ProjectFile, Text)
  writeFile(root / "state" / "keymap", "vim\n")
  let sess = newTuiTest(tuiBinary(), @["--edit", root / "project"])
    .width(Cols).height(Rows)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", "xterm-256color")
    .envSet("LANG", "en_US.UTF-8")
    .envSet(StateDirEnvVar, root / "state")
    .spawn()
  (sess, root)

proc waitFor(sess: var TuiTestSession; needle: string): string =
  let deadline = getMonoTime() + initDuration(milliseconds = FrameTimeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = sess.screenContents()
    if last.contains(needle):
      return last
    if not sess.isAlive:
      raise newException(AssertionDefect,
        "the binary exited before '" & needle & "' appeared; screen:\n" & last)
  raise newException(AssertionDefect,
    "'" & needle & "' never appeared within " & $FrameTimeoutMs & " ms; screen:\n" & last)

proc key(sess: var TuiTestSession; bytes: string) =
  ## One key's bytes. A lone ESC waits long enough that the next byte cannot
  ## be read as the rest of an escape sequence.
  sess.send(bytes)
  discard sess.drainOutput(if bytes == Esc: 250 else: 40)

proc markedLines(screen, fileText: string): seq[int] =
  ## The line numbers the GUTTER marks with `●`. The edit pane draws a row as
  ## `● 4     def second():` — the mark, the line number, then the text — so
  ## each row carrying the glyph yields the number printed after it AND the
  ## file line whose text follows, and the two must agree: a gutter whose
  ## number and text disagreed would pass either reading alone.
  let lines = fileText.splitLines()
  for row in screen.splitLines():
    let g = row.find(BreakpointGlyph)
    if g < 0: continue
    let rest = row[g + BreakpointGlyph.len .. ^1]
    let words = rest.splitWhitespace()
    var number = -1
    if words.len > 0:
      try: number = parseInt(words[0])
      except ValueError: discard
    let body = if words.len > 1: rest[rest.find(words[1]) .. ^1].strip()
               else: ""
    let byText = if number >= 1 and number <= lines.len and
                    lines[number - 1].strip() == body: number
                 else: -1
    result.add byText

proc quit(sess: var TuiTestSession) =
  sess.key(Esc)
  sess.key("\t")
  sess.key(":q\r")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.close()

suite "PLAT-28 Tier 2: a breakpoint follows its line, on a real pty":

  test "F9 on `def second():`, `O` above it, then `dd` on it":
    var (sess, _) = spawnEditor("follow")
    var current = Text
    try:
      discard sess.waitFor("EDIT " & ProjectFile)
      sess.key("j")
      sess.key("j")                    # line 3, `def second():`
      sess.key(F9)
      let placed = sess.waitFor("breakpoint at " & ProjectFile & ":3")
      checkpoint(placed)
      ck markedLines(placed, current) == @[3]

      # `O` on line 1 opens a line ABOVE the whole file: the breakpoint's
      # line moves to 4 and keeps its text.
      sess.key("g")
      sess.key("g")
      sess.key("O")
      for ch in "# new":
        sess.key($ch)
      sess.key(Esc)
      current = "# new\n" & Text
      let moved = sess.waitFor("# new")
      checkpoint(moved)
      ck markedLines(moved, current) == @[4]

      # `dd` ON the breakpoint's line removes it, and the line that takes its
      # place — `    return 2` — is not marked.
      sess.key("j")
      sess.key("j")
      sess.key("j")                    # line 4
      sess.key("d")
      sess.key("d")
      current = "# new\ndef first():\n    pass\n    return 2\ndef third():\n    return 3\n"
      discard sess.drainOutput(300)
      let deleted = sess.screenContents()
      checkpoint(deleted)
      ck not deleted.contains("def second():")
      ck markedLines(deleted, current).len == 0
    finally:
      sess.quit()

suite "PLAT-28 Tier 2 edit breakpoints — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
