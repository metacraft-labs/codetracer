## test_build_tasks_pty.nim — Tier 3: **the shipped `codetracer-tui` runs a
## project's build task from `Ctrl+Shift+B`, and marks the build's
## diagnostics in its editor**, on a real terminal.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.6, §3.9, §3.11, §3.12.
##
## The binary in Edit mode over the PLAT-56 project in a real pty (read by
## libvterm), the project carrying a `.codetracer/build.yaml` whose default
## task is the failing coloured `gcc` build:
##
##   * `Ctrl+Shift+B` opens the task picker — the default task first — and
##     `Enter` builds it: the pane says "build failed (exit code 1)";
##   * `src/main.c` opened (`:e`): the warning's word `unused` is underlined
##     in the warning colour, its line's gutter shows `⚠`, the error line's
##     `●`;
##   * the pointer resting on `undefined_name` shows the compiler's messages;
##   * `:build: pass` builds the passing task, and the marks are gone.
##
## No mocks: the binary, the real `gcc`, a real project, a real pty.

import std/[monotimes, os, strutils, times, unittest]
from std/unicode import runeLen, Rune, `$`

import term_assert
import nim_libvterm

import ../../../viewmodel/tests/unit/build_fixtures/plat56_c_build
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 9

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  BuildBudgetMs = 120_000

type Snapshot = seq[seq[Cell]]

proc snap(sess: var TuiTestSession): Snapshot =
  discard sess.drainOutput(80)
  for r in 0 ..< Rows:
    var row: seq[Cell] = @[]
    for c in 0 ..< Cols:
      row.add sess.cellAt(r, c)
    result.add row

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add(if int(c.rune) == 0: " " else: $c.rune)

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc findRow(s: Snapshot; needle: string): (int, int) =
  for r in 0 ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc gutterHas(s: Snapshot; row, codeCol: int; glyph: string): bool =
  ## Whether the editor's gutter (the eight cells before the code) shows
  ## `glyph` on `row`.
  for c in max(0, codeCol - 8) ..< codeCol:
    if $s[row][c].rune == glyph: return true
  false

proc screenText(s: Snapshot): string =
  for r in 0 ..< Rows:
    result.add s.text(r) & "\n"

proc waitFor(sess: var TuiTestSession; needle: string;
             timeoutMs = 60000): (int, int) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last: Snapshot
  while getMonoTime() < deadline:
    last = sess.snap()
    let at = last.findRow(needle)
    if at[0] >= 0: return at
    sleep(50)
  raise newException(AssertionFailedError, "never showed '" & needle &
                     "'; screen:\n" & last.screenText())

proc omnibox(sess: var TuiTestSession; line: string) =
  sess.send("\x10")  # Ctrl+P
  sleep(200)
  sess.send(line)
  sleep(150)
  sess.send("\r")

suite "build tasks and the editor's marks on a real terminal":

  test "Ctrl+Shift+B builds the default task; the editor marks its diagnostics":
    let project = writePlat56Project("ct-build-tasks-pty-")
    createDir(project / ".codetracer")
    writeFile(project / ".codetracer" / "build.yaml",
              "tasks:\n  fail:\n    command: \"" & Plat56FailCommand &
              "\"\n    default: true\n  pass:\n    command: \"" &
              Plat56PassCommand & "\"\n")
    let state = getTempDir() / ("build-tasks-pty-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", "--edit", project])
      .width(Cols).height(Rows).transcript()
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
    # THE PICKER: `Ctrl+Shift+B` (CSI u), the default task first.
    sess.send("\x1b[98;6u")
    discard sess.waitFor("build tasks: Enter runs fail")
    let (pr, _) = sess.waitFor(Plat56FailCommand)
    ck pr >= 0
    sess.send("\r")
    let (vr, _) = sess.waitFor("build failed (exit code 1)", BuildBudgetMs)
    ck vr >= 0
    # THE EDITOR'S MARKS in src/main.c.
    sess.omnibox(":e src/main.c")
    let (ur, uc) = sess.waitFor("int unused = 1;")
    var s = sess.snap()
    let wordCol = uc + "int ".len
    ck s[ur][wordCol].underline != usNone
    ck s[ur][wordCol - 1].underline == usNone
    ck s.gutterHas(ur, uc - 4, "⚠")
    let (er, ec) = s.findRow("return undefined_name;")
    ck er >= 0 and s.gutterHas(er, ec - 4, "●")
    # THE HOVER: the pointer rests on `undefined_name`.
    let hoverCol = ec + "return ".len + 2
    sess.send("\x1b[<35;" & $(hoverCol + 1) & ";" & $(er + 1) & "M")
    let (tr, _) = sess.waitFor("undeclared (first use in this function)")
    ck tr != er
    # A PASSING BUILD clears them.
    sess.omnibox(":build: pass")
    discard sess.waitFor("build succeeded", BuildBudgetMs)
    sleep(300)
    s = sess.snap()
    let (ur2, uc2) = s.findRow("int unused = 1;")
    ck ur2 >= 0 and s[ur2][uc2 + "int ".len].underline == usNone
    let (er2, ec2) = s.findRow("return undefined_name;")
    ck er2 >= 0 and not s.gutterHas(er2, ec2 - 4, "●")
    sess.send("\x11")  # Ctrl+Q
    discard sess.waitExit(initDuration(seconds = 10))
    sess.terminate()
    sess.close()
    removeDir(state)
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
