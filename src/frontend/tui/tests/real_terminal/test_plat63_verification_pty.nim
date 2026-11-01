## test_plat63_verification_pty.nim — PLAT-63, Tier 2: **the terminal's
## Verification pane in a real terminal**, measured against the desktop's
## view of the same run.
##
## Spec: codetracer-pm `spec/Planned-Features/Verification-Payload-
## Contract-v1.md` §5, §7; `milestones/Verno-CodeTracer-Integration.
## milestones.org` VN-M3, VN-M5.
##
## The shipped `codetracer-tui --edit <package>` in a real pty, its bytes
## parsed by libvterm (TermAssert):
##
##   * `:verify` typed into the omnibox (View › Verification's command line
##     verb) opens the pane, and its Run control names the package's declared
##     Verno action;
##   * a press on Run runs that action (the package's own `.vscode/
##     tasks.json`), and the pane lists the run's findings BY KIND — the
##     heading and the rows, word for word the lines the desktop's view
##     draws for the same run (`fixtures/plat63_verno_projects.
##     TypeErrExpectedRows`, asserted equal to the desktop's tree by
##     `test_plat63_verification.nim`);
##   * a RIGHT-CLICK on a finding opens the shared menu;
##   * a PRESS on a finding opens `src/main.nr` at the finding's line in the
##     editor, the status line saying where;
##   * over the counterexample package's run, a press on the offer opens the
##     counterexample in the pane, its provenance banner and its step with
##     no source position in words.
##
## THE ONE STAND-IN (see `fixtures/plat63_verno_projects`): the `verno` on
## the binary's PATH replays a recorded real run. The binary, its task
## reader, its runner, its classifier and decoder, the pty and the terminal
## are the product's.

import std/[monotimes, os, strutils, times, unittest]
from std/unicode import runeLen, Rune, `$`

import term_assert

import ../fixtures/plat63_verno_projects
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 15

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  RunBudgetMs = 60_000

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
  sleep(300)
  sess.send("\r")

proc launch(run: VernoRun; state: string): TuiTestSession =
  newTuiTest(tuiBinary(), @["--theme=dark", "--edit", run.root])
    .width(Cols).height(Rows).transcript()
    .workDir(run.root)
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
               "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("PATH", run.bin & ":" & getEnv("PATH"))
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_DATA_HOME", state / "data")
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .carryRunMark()
    .spawn()

proc openAndRun(sess: var TuiTestSession) =
  ## `:verify` (View › Verification) from the omnibox, then Run.
  discard sess.waitFor("[EDIT]")
  sess.omnibox(":verify")
  discard sess.waitFor("▶ " & VernoTaskLabel)
  # MAXIMIZED, through the tab's own menu, so a finding's words fit.
  let (tr, tc) = sess.snap().findRow(" Verification ")
  doAssert tr >= 0, "no Verification tab"
  sess.press(tr, tc + 2, button = 2)
  let (mr, mc) = sess.waitFor("Maximise container")
  sess.press(mr, mc + 2)
  sleep(300)
  let (rr, rc) = sess.waitFor("▶ " & VernoTaskLabel)
  sess.press(rr, rc + 2)

proc restore(sess: var TuiTestSession) =
  ## The maximised container back in the arrangement (its tab's menu), so
  ## the editor a press opened is on the screen.
  let (tr, tc) = sess.snap().findRow(" Verification ")
  doAssert tr >= 0, "no Verification tab"
  sess.press(tr, tc + 2, button = 2)
  let (mr, mc) = sess.waitFor("Minimise container")
  sess.press(mr, mc + 2)
  sleep(300)

proc finish(sess: var TuiTestSession; state: string; run: VernoRun) =
  sess.send("\x11")  # Ctrl+Q
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()
  removeDir(state)
  run.removeRun()

suite "PLAT-63: the Verification pane on a real terminal":

  test "Run, the findings by kind, a right-click, a press":
    let run = writeTypeErrRun()
    let state = getTempDir() / ("plat63-pty-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = launch(run, state)
    sess.openAndRun()
    let (hr, hc) = sess.waitFor("pipeline error (2)", RunBudgetMs)
    var s = sess.snap()
    # The status and the command line, over the list.
    ck s.findRow("failed before reaching the prover")[0] >= 0
    ck s.findRow(VernoCommandLine)[0] >= 0
    ck s.findRow("Nothing was proved or disproved about this program.")[0] >= 0
    # THE FINDINGS, under their heading, in the desktop's words and order.
    var matched = 0
    for i, r in TypeErrExpectedRows:
      let line = s.text(hr + 1 + i)
      if line.contains(r[0] & "  " & r[1] & "  " & r[2]):
        inc matched
      else:
        checkpoint("row " & $i & ": '" & line.strip & "'")
    ck matched == TypeErrExpectedRows.len
    # A RIGHT-CLICK on the first finding: the shared menu.
    sess.press(hr + 1, hc + 4, button = 2)
    discard sess.waitFor("Copy Location")
    s = sess.snap()
    ck s.findRow("Go to Source")[0] >= 0
    ck s.findRow("Copy Message")[0] >= 0
    sess.send("\x1b")
    sleep(300)
    # A PRESS on the second finding: `src/main.nr` at 1:24 in the editor.
    sess.press(hr + 2, hc + 4)
    discard sess.waitFor("opened typeerr/src/main.nr:1:24")
    sess.restore()
    discard sess.waitFor("let y: Field = x;")
    s = sess.snap()
    ck s.findRow("fn main(x: u32) -> pub u32 {")[0] >= 0
    ck s.findRow("let y: Field = x;")[0] >= 0
    sess.finish(state, run)

  test "the counterexample: the offer opens it in the pane":
    let run = writeCounterexampleRun()
    let state = getTempDir() / ("plat63-pty-cx-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = launch(run, state)
    sess.openAndRun()
    let (orow, ocol) = sess.waitFor("▸ Step through the counterexample",
                                    RunBudgetMs)
    var s = sess.snap()
    ck s.findRow("failed obligation (1)")[0] >= 0
    ck s.text(orow + 1).contains("src/main.nr:7:12")
    sess.press(orow + 1, ocol + 4)
    discard sess.waitFor("1 of 2 steps have no source position")
    s = sess.snap()
    ck s.findRow("These values come from the prover, not from a run.")[0] >= 0
    ck s.findRow("position not recorded")[0] >= 0
    let (vr, vc) = s.findRow("src/main.nr:7:12")
    ck vr >= 0
    # The violation's step opens its line.
    let (sr, sc) = s.findRow("2. violated obligation")
    ck sr >= 0
    sess.press(sr, sc + 2)
    discard sess.waitFor("opened step 2: src/main.nr:7:12")
    sess.restore()
    discard sess.waitFor("#['ensures(*state == 1)]")
    ck vc >= 0
    sess.finish(state, run)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
