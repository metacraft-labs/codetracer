## test_plat55_problems_pty.nim — PLAT-55, Tier 2: **the terminal's Problems
## pane in a real terminal**, measured against the desktop.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.3; `Planned-Features/
## Edit-Mode-Toolbar.md` §11 (EMT-D21, D22).
##
## The shipped `codetracer-tui --edit <crate>` in a real pty, its bytes parsed
## by libvterm (TermAssert), over the PLAT-55 Noir crate:
##
##   * `:build nargo compile` typed into the omnibox runs the real `nargo`;
##     the build fails and the footer's PROBLEMS label is there to dock;
##   * `F8` (`problems.next`, Edit mode) reveals the docked pane and opens the
##     next error in the editor, announcing it on the status line;
##   * THE ROWS on the screen, row for row the desktop's
##     (`src/tests/visual/answers/plat55-problems.electron.json`): icon, path,
##     location and message, in the desktop's order, each icon in its
##     severity's THEME role (the error / warning tokens; the desktop's dark
##     panel uses literal colours outside the tokens, checkpointed beside);
##   * a RIGHT-CLICK on a row opens nothing (the desktop's `rowContextMenu`);
##   * a PRESS on the warning's row opens `src/util.nr` at line 2 in the
##     editor (K35) — the line's text is on the screen beside its gutter
##     number.
##
## No mocks: the binary, the real `nargo`, a real crate, a real pty.

import std/[json, monotimes, os, strutils, times, unittest]
from std/unicode import runeLen, Rune, `$`

import term_assert
import nim_libvterm

import ../fixtures/plat55_noir_build
import ./lifecycle_support
import ../../app/theme/colour_math
import ../../app/theme/palette

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 12

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  AnswersFile = "src/tests/visual/answers/plat55-problems.electron.json"
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

proc cssHex(rgb: string): string =
  let inner = rgb.strip().replace("rgb(", "").replace(")", "")
  let parts = inner.split(",")
  if parts.len < 3: return ""
  hexOf((parseInt(parts[0].strip), parseInt(parts[1].strip),
         parseInt(parts[2].strip)))

let answers = parseJson(readFile(lifecycle_support.repoRoot() / AnswersFile))

suite "PLAT-55: the Problems pane on a real terminal":

  test "a real build; F8; the desktop's rows; a right-click; a press":
    let project = writePlat55Project("ct-plat55-pty-")
    let state = getTempDir() / ("plat55-pty-" & $getCurrentProcessId())
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
    # THE FOOTER docks PROBLEMS in Edit mode, as the desktop's does.
    ck sess.snap().findRow("PROBLEMS", fromBottom = true)[0] == Rows - 1

    # THE BUILD — the real `nargo`.
    sess.omnibox(":build " & Plat55BuildCommand)
    discard sess.waitFor("build FAILED", BuildBudgetMs)

    # F8: the next error (from the one the failed build highlighted), opened
    # and announced; the docked pane revealed.
    sess.send("\x1b[19~")
    discard sess.waitFor("error 2 of 2")
    let (hr, _) = sess.waitFor("Total: 3")
    var s = sess.snap()

    # THE ROWS, row for row the desktop's.
    let after = answers["after"]
    var matched = 0
    var colours = 0
    var r = hr + 1
    for row in after["rows"]:
      let line = s.text(r).strip()
      let want = [row["icon"].getStr, row["path"].getStr,
                  row["location"].getStr, row["message"].getStr]
      if line.startsWith(want[0]) and line.contains(want[1] & " " & want[2]) and
         line.endsWith(want[3]):
        inc matched
      else:
        checkpoint("row " & $r & ": '" & line & "' wanted " & $want)
      let iconCol = s.text(r).cellFind(want[0])
      let got = s[r][iconCol].fgHex
      # The terminal draws severity in its THEME's roles (the error and the
      # warning tokens), which follow the theme and the palette tier; the
      # desktop's dark panel uses literal colours outside the design tokens
      # (`problems.styl`: #f85149 / #d29922), recorded here for the reader.
      let role = if row["severity"].getStr == "error": srChromeError
                 else: srChromeNotification
      checkpoint("icon " & want[0] & " colour " & got & " (theme role " &
                 RoleColourTable[dmDark][role].fgRgb & ", desktop " &
                 cssHex(row["iconColor"].getStr) & ")")
      if got == RoleColourTable[dmDark][role].fgRgb: inc colours
      inc r
    ck matched == after["rows"].len
    ck colours == after["rows"].len
    ck s.text(hr).contains(after["counts"][0].getStr) and
       s.text(hr).contains(after["counts"][1].getStr)
    for b in after["buttons"]:
      ck s.text(hr).contains(b["label"].getStr)

    # A RIGHT-CLICK ON A ROW opens nothing — the desktop's `rowContextMenu`.
    ck answers["rowContextMenu"].len == 0
    let quiet = sess.snap()
    sess.press(hr + 1, 4, button = 2)
    sleep(400)
    let afterRight = sess.snap()
    var same = true
    for row in hr .. hr + 3:
      if afterRight.text(row) != quiet.text(row): same = false
    ck same

    # A PRESS ON THE WARNING'S ROW opens src/util.nr at line 2 (K35).
    sess.press(hr + 1, 4)
    discard sess.waitFor("opened src/util.nr:2:9")
    s = sess.snap()
    let (lr, _) = s.findRow("let unused = 1;")
    ck lr >= 0
    if lr >= 0:
      # The gutter's number just left of the line's text.
      let line = s.text(lr)
      let at = line.find("let unused = 1;")
      ck line[0 ..< at].strip().endsWith(" 2") or
         line[0 ..< at].splitWhitespace()[^1] == "2"

    sess.send("\x11")  # Ctrl+Q
    discard sess.waitExit(initDuration(seconds = 10))
    sess.terminate()
    sess.close()
    removeDir(state)
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
