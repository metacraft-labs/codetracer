## test_plat56_build_output_pty.nim — PLAT-56, Tier 3: **the shipped
## `codetracer-tui` draws the Build Output pane on a real terminal** after a
## real coloured `gcc` build, and the screen is the desktop's.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.13, §3.5, §3.10.
##
## The binary in Edit mode over the PLAT-56 project in a real pty (read by
## libvterm), `:build` of the failing coloured build typed into the omnibox:
##
##   * the pane's verdict in the desktop's words ("build failed (exit code
##     1)") and the status line's build indicator ("✗ Build failed: 2 errors,
##     1 warning"), as the desktop's capture
##     (`src/tests/visual/answers/plat56-build-output.electron.json`) read
##     them;
##   * the lines as the compiler wrote them, IN ITS COLOURS: the `error: ` of
##     the first error drawn in the desktop's red (`ansi_up`'s palette,
##     #bb0000) — the colour the desktop's span carries;
##   * a right-click on a line opens nothing (the desktop's is measured
##     empty);
##   * a press on the first error's line opens `src/main.c` at line 5 in the
##     editor (K35), as the desktop's press opened it.
##
## No mocks: the binary, the real `gcc`, a real project, a real pty.

import std/[json, monotimes, os, strutils, times, unittest]
from std/unicode import runeLen, Rune, `$`

import term_assert
import nim_libvterm

import ../../../viewmodel/tests/unit/build_fixtures/plat56_c_build
import ./lifecycle_support
import ../../app/theme/colour_math

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 10

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 220
  Rows = 50
  AnswersFile = "src/tests/visual/answers/plat56-build-output.electron.json"
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

proc findRow(s: Snapshot; needle: string; fromBottom = false): (int, int) =
  for k in 0 ..< Rows:
    let r = if fromBottom: Rows - 1 - k else: k
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

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

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int; button = 0) =
  sess.mouse(button, row, col)
  sess.mouse(button, row, col, release = true)

proc omnibox(sess: var TuiTestSession; line: string) =
  sess.send("\x10")  # Ctrl+P
  sleep(200)
  sess.send(line)
  sleep(150)
  sess.send("\r")

proc fgHex(c: Cell): string =
  if c.fg.kind == ckRgb: hexOf((c.fg.r.int, c.fg.g.int, c.fg.b.int)) else: ""

let answers = parseJson(readFile(lifecycle_support.repoRoot() / AnswersFile))

suite "PLAT-56: the Build Output pane on a real terminal":

  test "a real coloured build: the verdict, the colours, a press":
    let project = writePlat56Project("ct-plat56-pty-")
    let state = getTempDir() / ("plat56-pty-" & $getCurrentProcessId())
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
    sess.omnibox(":build " & Plat56FailCommand)
    let failing = answers["failing"]
    let (vr, vc) = sess.waitFor(failing["header"].getStr, BuildBudgetMs)
    ck vr >= 0
    # THE STATUS LINE'S INDICATOR, the desktop's words.
    let (sr, _) = sess.waitFor(failing["status"].getStr)
    ck sr == Rows - 1
    var s = sess.snap()
    ck s.text(Rows - 1).contains(failing["statusIcon"].getStr & " " &
                                 failing["status"].getStr)
    # THE FIRST ERROR'S LINE, its `error: ` in the desktop's span colour.
    let (er, ec) = s.findRow("src/main.c:5:17: error:")
    ck er > vr
    if er > vr:
      let errCol = ec + "src/main.c:5:17: ".len
      let want = failing["lines"][1]["runs"][2]
      ck want["text"].getStr == "error: "
      ck s[er][errCol].fgHex == "#bb0000"
      ck want["style"].getStr.startsWith("color:rgb(187,0,0)")
    # A RIGHT-CLICK ON A LINE opens nothing — the desktop's
    # `lineContextMenu`.
    ck failing["lineContextMenu"].len == 0
    let quiet = sess.snap()
    sess.press(er, ec + 2, button = 2)
    sleep(400)
    let afterRight = sess.snap()
    var same = true
    for row in vr .. er + 1:
      if afterRight.text(row) != quiet.text(row): same = false
    ck same
    # A PRESS ON IT opens src/main.c at line 5 (K35), as the desktop's did.
    sess.press(er, ec + 2)
    discard sess.waitFor("opened src/main.c:5:17")
    ck failing["press"]["opened"]["line"].getInt == 5
    discard vc
    sess.send("\x11")  # Ctrl+Q
    discard sess.waitExit(initDuration(seconds = 10))
    sess.terminate()
    sess.close()
    removeDir(state)
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
