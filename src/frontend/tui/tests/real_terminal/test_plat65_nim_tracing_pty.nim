## test_plat65_nim_tracing_pty.nim — Nim's compile-time tracing on the
## shipped terminal binary, in a real pty: each of the four actions, by its
## chord and by the editor's menu, opens a NEW SESSION TAB on a recording
## whose first stop is inside the traced construct.
##
## Spec: codetracer-pm `spec/Planned-Features/Nim-Compile-Time-Tracing-
## Milestones.md` (M6, M9–M11); `spec/GUI/Multi-Window-Tab-Management.md`
## "Which tab a replay opens in".
##
## The shipped `codetracer-tui` over a real recording of the project
## (`fixtures/plat65_nim_project`: `nim e --trace build.nims`), in the project
## folder, its bytes parsed by libvterm (TermAssert):
##
##   * EVAL — `Ctrl+K T E` with the caret in `build.nims` (placed by a press)
##     traces the script with `nim e --trace`: a new tab, stopped in
##     `build.nims`;
##   * STATIC BLOCK — `Ctrl+F5` to Edit mode, `tracing.nim` opened from the
##     omnibox, a press on the `static:` block's body, `Ctrl+K T S`: a new
##     tab, stopped inside the block;
##   * CONSTANT — a right-click on the `const` section's `cubes` entry in
##     that recording's editor, **Trace Constant Initializer** chosen: a new
##     tab, stopped in the initializer or the `compute` it calls;
##   * MACRO — a press on `twice:` and `Ctrl+K T M`: a new tab, stopped in
##     the macro's body;
##   * each new tab is ADDED to the strip — the tabs before it stay;
##   * WITH NO NIMSUGGEST the static action starts nothing and says why, and
##     with no compiler the evaluation does; on an ordinary `proc` line the
##     static action is refused before anything runs, and says why.
##
## No mocks: the compiler, nimsuggest, replay-server, the binary, the pty and
## the terminal are the real ones. Prerequisites missing →
## `MISSING-PREREQ SKIP:` naming them.

import std/[monotimes, options, os, strutils, times, unittest]
from std/unicode import runeLen, Rune, `$`

import term_assert

import ../fixtures/plat65_nim_project
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 23

var countedAssertions = 0
var skipped = false

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  TraceBudgetMs = 120_000
  CtrlK = "\x0b"
  CtrlF5 = "\x1b[15;5~"

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

proc statusLine(sess: var TuiTestSession): string =
  sess.snap().text(Rows - 1)

proc stopLine(sess: var TuiTestSession; file: string): int =
  ## The line the editor's execution pointer (`▸`) is on, when the editor
  ## shows `file`; -1 otherwise.
  let s = sess.snap()
  if s.findRow(file)[0] < 0:
    return -1
  for r in 1 ..< Rows - 1:
    let line = s.text(r)
    let at = line.find("▸")
    if at < 0: continue
    var i = at - 1
    while i >= 0 and line[i] == ' ': dec i
    var digits = ""
    while i >= 0 and line[i].isDigit:
      digits.insert($line[i], 0)
      dec i
    if digits.len > 0:
      return parseInt(digits)
  -1

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int; button = 0) =
  sess.mouse(button, row, col)
  sess.mouse(button, row, col, release = true)

proc pressLine(sess: var TuiTestSession; code: string; button = 0) =
  ## A press on the editor's line whose text is `code`, on its first
  ## character.
  let (r, c) = sess.waitFor(code)
  sess.press(r, c + 1, button)
  sleep(200)

proc chord(sess: var TuiTestSession; letter: string) =
  ## `Ctrl+K T <letter>`.
  sess.send(CtrlK)
  sleep(150)
  sess.send("t")
  sleep(150)
  sess.send(letter)

proc tabCount(sess: var TuiTestSession; stems: openArray[string]): int =
  ## How many of the session strip's tabs (the top row's `<title> ×`
  ## entries) name one of `stems` — a trace's folder is
  ## `<file>-<action>-<stamp>`, the starting recording's `start`.
  let top = sess.snap().text(0)
  let strip = top[0 ..< max(0, top.find("[ct]"))]
  checkpoint("strip: " & strip)
  checkpoint("status: " & sess.snap().text(Rows - 1))
  for part in strip.split("×"):
    let words = part.strip.splitWhitespace()
    if words.len == 0: continue
    for stem in stems:
      if words[^1].startsWith(stem):
        inc result
        break

proc stripScrolled(sess: var TuiTestSession): bool =
  ## Whether the session strip is scrolled past tabs before the ones shown.
  let top = sess.snap().text(0)
  top[0 ..< max(0, top.find("[ct]"))].contains("‹")

proc launch(p: NimProject; nimsuggest = ""; nim = ""): TuiTestSession =
  var b = newTuiTest(tuiBinary(), @["--theme=dark", p.recording])
    .width(Cols).height(Rows).transcript()
    .workDir(p.root)
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
               "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", p.state)
    .envSet("XDG_DATA_HOME", p.state / "data")
    .envSet("XDG_CONFIG_HOME", p.state / "config")
    .envSet("CODETRACER_HOME", p.state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", p.state / "layout")
  if nimsuggest.len > 0: b = b.envSet("CODETRACER_NIMSUGGEST", nimsuggest)
  if nim.len > 0: b = b.envSet("CODETRACER_NIM", nim)
  b.carryRunMark().spawn()

proc finish(sess: var TuiTestSession) =
  sess.send("\x11")  # Ctrl+Q
  discard sess.waitExit(initDuration(seconds = 20))
  sess.terminate()
  sess.close()

proc openInEdit(sess: var TuiTestSession; file: string) =
  ## `Ctrl+F5` to Edit mode, `file` opened by a press on its Files row.
  sess.send(CtrlF5)
  discard sess.waitFor("[EDIT]")
  let s = sess.snap()
  var at = (-1, -1)
  for r in 1 ..< Rows - 1:
    let c = s.text(r).cellFind(" " & file)
    if c >= 0 and c < 20:
      at = (r, c + 1)
      break
  doAssert at[0] >= 0, "no Files row for " & file & ":\n" & s.screenText()
  sess.press(at[0], at[1] + 1)
  discard sess.waitFor("twice:")

suite "PLAT-65: Nim's compile-time tracing on a real terminal":

  test "eval, static block, constant and macro — each a new session tab":
    let missing = missingPrereq()
    if missing.len > 0:
      echo "  MISSING-PREREQ SKIP: ", missing
      skipped = true
      skip()
    else:
      let p = writeNimProject("pty")
      defer: p.removeProject()
      var sess = launch(p)
      discard sess.waitFor("build.nims:")
      # EVAL: the caret in the script, `Ctrl+K T E`.
      sess.pressLine("var total = 0")
      sess.chord("e")
      discard sess.waitFor("opened in a new session tab", TraceBudgetMs)
      ck sess.stopLine("build.nims") in BuildLines
      ck sess.tabCount(["build-eval"]) == 1
      ck sess.tabCount(["start"]) == 1

      # STATIC BLOCK: Edit mode, `tracing.nim`, a press in the block's body.
      sess.openInEdit("tracing.nim")
      sess.pressLine("acc += i")
      sess.chord("s")
      discard sess.waitFor("tracing-static-block", TraceBudgetMs)
      discard sess.waitFor("opened in a new session tab", TraceBudgetMs)
      ck sess.stopLine("tracing.nim") in StaticLines
      ck sess.tabCount(["build-eval", "start"]) == 2
      ck sess.tabCount(["tracing-static-block"]) == 1
      # The recording carries its source: the block, on the screen.
      ck sess.snap().findRow("for i in 0..<limit:")[0] >= 0

      # CONSTANT: the menu on the section's `cubes` entry.
      sess.pressLine("cubes = compute(limit)", button = 2)
      let (mr, mc) = sess.waitFor("Trace Constant Initializer")
      # The menu (not the status line, which names the last trace).
      let menuRow = sess.snap().findRow("Trace Static Block Execution")[0]
      ck menuRow < 0 or menuRow == Rows - 1
      sess.press(mr, mc + 2)
      discard sess.waitFor("tracing-constant", TraceBudgetMs)
      discard sess.waitFor("opened in a new session tab", TraceBudgetMs)
      let constStop = sess.stopLine("tracing.nim")
      checkpoint("constant stop: " & $constStop)
      ck constStop == CubesLine or constStop in ComputeLines
      # The strip scrolls once it overflows (`‹ … ›`): the tabs before the
      # new one are still there, the first behind the `‹`.
      ck sess.tabCount(["tracing-static-block", "build-eval"]) == 2
      ck sess.tabCount(["tracing-constant"]) == 1
      ck sess.stripScrolled()

      # MACRO: a press on the call, `Ctrl+K T M`.
      sess.pressLine("twice:")
      sess.chord("m")
      discard sess.waitFor("tracing-macro", TraceBudgetMs)
      discard sess.waitFor("opened in a new session tab", TraceBudgetMs)
      let macroStop = sess.stopLine("tracing.nim")
      checkpoint("macro stop: " & $macroStop)
      ck macroStop in MacroLines
      ck sess.tabCount(["tracing-constant", "tracing-static-block"]) == 2
      ck sess.stripScrolled()
      ck sess.tabCount(["tracing-macro"]) == 1
      sess.finish()

  test "on an ordinary proc line the static action is refused, and says why":
    if skipped:
      skip()
    else:
      let p = writeNimProject("pty-proc")
      defer: p.removeProject()
      var sess = launch(p)
      discard sess.waitFor("build.nims:")
      sess.openInEdit("tracing.nim")
      sess.pressLine("proc compute(n: int): int =")
      # The menu offers no static or constant entry there.
      sess.pressLine("proc compute(n: int): int =", button = 2)
      sleep(400)
      var s = sess.snap()
      ck s.findRow("Trace Static Block Execution")[0] notin 0 ..< Rows - 1
      ck s.findRow("Trace Constant Initializer")[0] notin 0 ..< Rows - 1
      sess.send("\x1b")
      sleep(300)
      sess.chord("s")
      discard sess.waitFor("is neither")
      ck sess.statusLine().contains("tracing.nim:6")
      ck sess.tabCount(["tracing-"]) == 0
      sess.finish()

  test "with no nimsuggest and no compiler, each action is inert and says why":
    if skipped:
      skip()
    else:
      let p = writeNimProject("pty-absent")
      defer: p.removeProject()
      var sess = launch(p, nimsuggest = p.root / "no-nimsuggest",
                        nim = p.root / "no-nim")
      discard sess.waitFor("build.nims:")
      sess.pressLine("var total = 0")
      sess.chord("e")
      discard sess.waitFor("no `nim` to run the script with")
      ck sess.tabCount(["build-eval"]) == 0
      sess.openInEdit("tracing.nim")
      sess.pressLine("var acc = 0")
      sess.chord("s")
      discard sess.waitFor("nimsuggest is not available")
      ck sess.tabCount(["tracing-"]) == 0
      ck sess.statusLine().contains("CODETRACER_NIMSUGGEST")
      sess.finish()

suite "PLAT-65 pty suite self-check":
  test "the assertion count is the one declared":
    if skipped:
      skip()
    else:
      checkpoint("assertions: " & $countedAssertions)
      check countedAssertions == ExpectedAssertions
