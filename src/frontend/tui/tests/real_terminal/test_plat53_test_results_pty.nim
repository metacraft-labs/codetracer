## test_plat53_test_results_pty.nim — PLAT-53, Tier 2. **The Test Results
## pane on a real terminal, measured against the desktop.**
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §8.
##
## The shipped `codetracer-tui` on a recording, started in the PLAT-53 Noir
## crate's directory (the window's project, §8.2), driven as a user drives it
## — exact SGR mouse bytes on the cells the pane was drawn in — and read back
## off the screen through libvterm. The reference is the REAL Electron app's
## pane over the same crate (`src/tests/visual/answers/
## plat53-test-results.electron.json`, `just plat53-capture-electron`):
##
##   * BEFORE A RUN (the pane widened by a divider drag): the headline, and
##     per row the mark, the name, the location and the `⏵` glyph equal to the
##     desktop's, in its order;
##   * a right-click on a row opens nothing — the desktop opens no menu there;
##   * THE ▶ runs the real `ct test run`: the headline, each row's mark, name
##     and location equal to the desktop's after its run, a duration on each,
##     the failed row's message under it line for line, and the passed mark,
##     the failed mark and the message in the desktop's computed colours;
##   * THE FAILING TEST'S `⏵` records it (the real `ct record-test`) and opens
##     the recording in a NEW SESSION TAB: the strip gains a tab and the
##     debugger shows the Noir test's source;
##   * §5: `ct test run` KILLED MID-WAY (SIGKILL to its process group) settles
##     — the pane says the run was ended by a signal and nothing is left
##     "running…";
##   * the terminal QUIT DURING A RUN leaves no `ct test run` behind.
##
## No mocks: the real binary, a real recording made by the Python recorder, a
## real `replay-server`, the real `ct`, `ct-test` and `nargo` on a real crate,
## a real pty (TermAssert + libvterm), the real Electron app's answers.

import std/[json, monotimes, os, posix, strutils, times, unittest]
from std/unicode import runeLen, Rune, `$`

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ../fixtures/plat53_noir_project
import ./lifecycle_support
import ../../app/theme/colour_math

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 38

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  AnswersFile = "src/tests/visual/answers/plat53-test-results.electron.json"
  RunBudgetMs = 300_000

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

proc paneText(s: Snapshot; r: int): string =
  ## Row `r` of the Test Results pane: from the left edge to its divider
  ## (the first `▏` on the row), so the panes right of it are not read.
  for c in s[r]:
    let ch = if int(c.rune) == 0: " " else: $c.rune
    if ch == "▏": break
    result.add ch

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

proc fgHex(c: Cell): string =
  if c.fg.kind == ckRgb: hexOf((c.fg.r.int, c.fg.g.int, c.fg.b.int)) else: ""

proc cssHex(rgb: string): string =
  ## `rgb(r, g, b)` (a computed style) as `#rrggbb`.
  let inner = rgb.strip().replace("rgb(", "").replace(")", "")
  let parts = inner.split(",")
  if parts.len < 3: return ""
  hexOf((parseInt(parts[0].strip), parseInt(parts[1].strip),
         parseInt(parts[2].strip)))

proc testsTabAt(s: Snapshot): (int, int) =
  ## The "Tests" tab of the Files stack.
  for r in 0 ..< Rows:
    let t = s.text(r)
    if t.contains(" Files ") and t.contains(" Tests"):
      return (r, t.cellFind(" Tests") + 2)
  (-1, -1)

proc runCtTestPids(project: string): seq[int] =
  ## Every live process whose command line is `… test run --workspace
  ## <project> …` — the suite run this window started.
  for kind, path in walkDir("/proc"):
    let name = path.extractFilename
    if name.len == 0 or not name[0].isDigit: continue
    var cmd = ""
    try: cmd = readFile(path / "cmdline")
    except CatchableError: continue
    let argv = cmd.split('\0')
    let at = argv.find("--workspace")
    if at > 1 and argv[at - 2] == "test" and argv[at - 1] == "run" and
       at + 1 < argv.len and argv[at + 1] == project:
      result.add parseInt(name)

proc pgidOf(pid: int): int =
  ## Field 5 of `/proc/<pid>/stat`, after the parenthesised command.
  try:
    let stat = readFile("/proc/" & $pid & "/stat")
    let close = stat.rfind(')')
    let fields = stat[close + 2 .. ^1].splitWhitespace()
    parseInt(fields[2])
  except CatchableError:
    -1

let answers = parseJson(readFile(lifecycle_support.repoRoot() / AnswersFile))

suite "PLAT-53: the Test Results pane on a real terminal":

  test "rows as the desktop's; a real run; a recording in a new tab; kill; quit":
    let calc = resolveFixture(FixtureSpec(
      name: "calc", program: "test-programs/calc/main.py",
      recorder: "codetracer-python-recorder",
      probe: FixtureProbe(kind: pkPythonRecorder),
      buildHint: "Install codetracer_python_recorder into the interpreter " &
                 "`ct` will use.",
      blockedOn: ""))
    doAssert calc.outcome == foRecorded, calc.detail
    let ct = fixture_provider.findCtBinary()
    doAssert ct.len > 0, "prerequisite missing: ct (build it, or set CT_BIN)"
    let project = writePlat53Project("ct-plat53-pty-")
    let state = getTempDir() / ("plat53-pty-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", calc.tracePath])
      .width(Cols).height(Rows).transcript()
      .workDir(project)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("CT_BIN", ct)
      .envSet("XDG_STATE_HOME", state)
      .envSet("CODETRACER_HOME", state / "ct-home")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
      .envSet("TEST_CERTIFICATES_DIR", state / "certs")
      .envSet("TEST_CERTIFICATES_SYSTEM_DIR", state / "certs-system")
      .carryRunMark()
      .spawn()
    settleOnDebugger(sess, Cols, Rows)

    # Show the pane, and WIDEN it — its divider dragged right, as a user
    # drags it — so every cell the desktop shows whole is shown whole.
    var s = sess.snap()
    let (tr, tc) = s.testsTabAt()
    doAssert tr >= 0, "no Tests tab:\n" & s.screenText()
    sess.press(tr, tc)
    let (hr, _) = sess.waitFor("2 tests, not run yet")
    s = sess.snap()
    let bodyRow = hr + 6
    var divider = -1
    for c in 0 ..< Cols:
      if $s[bodyRow][c].rune == "▏":
        divider = c
        break
    doAssert divider > 0, "no divider right of the Tests pane:\n" &
                          s.screenText()
    sess.mouse(0, bodyRow, divider)
    for step in 1 .. 8:
      sess.mouse(32, bodyRow, divider + step * 10)
      sleep(30)
    sess.mouse(0, bodyRow, divider + 80, release = true)
    # The release commits the arrangement once (the status line says so);
    # read the pane only after it has been laid out at its new width.
    discard sess.waitFor("applied")
    sleep(300)
    s = sess.snap()

    # BEFORE A RUN, row for row the desktop's.
    let before = answers["before"]
    ck s.paneText(hr).strip().startsWith(before["headline"].getStr)
    ck s.paneText(hr).strip().endsWith(before["run"]["label"].getStr)   # ▶
    var r = hr + 1
    var matched = 0
    for row in before["rows"]:
      let line = s.paneText(r).strip()
      if line.startsWith(row["mark"].getStr) and
         line.contains(row["name"].getStr) and
         line.contains(row["where"].getStr) and
         line.endsWith(row["open"]["label"].getStr):
        inc matched
      else:
        checkpoint("before, row " & $r & ": '" & line & "'")
      inc r
    ck matched == before["rows"].len

    # A RIGHT-CLICK ON A ROW opens nothing — the desktop's `rowContextMenu`.
    ck answers["rowContextMenu"].len == 0
    sleep(400)
    let quiet = sess.snap()
    sess.press(hr + 1, 4, button = 2)
    sleep(400)
    let afterRight = sess.snap()
    ck afterRight.findRow("Shift + right-click")[0] < 0
    var paneSame = true
    for row in hr - 1 .. hr + 6:
      if afterRight.paneText(row) != quiet.paneText(row):
        paneSame = false
        checkpoint("right-click changed row " & $row & ": '" &
                   afterRight.paneText(row) & "'")
    ck paneSame

    # THE ▶ — the real `ct test run`.
    let runCol = s.text(hr).cellFind(before["run"]["label"].getStr)
    ck runCol > 0
    sess.press(hr, runCol)
    let (doneRow, _) = sess.waitFor("1 passed, 1 failed", RunBudgetMs)
    sleep(300)
    s = sess.snap()
    let after = answers["after"]
    ck doneRow == hr
    ck after["headline"].getStr.startsWith("1 passed, 1 failed")
    r = hr + 1
    matched = 0
    var failedRow = -1
    for row in after["rows"]:
      let line = s.paneText(r).strip()
      let hasDuration = row["duration"].getStr.len > 0 and
                        (line.contains("ms ") or line.contains("s "))
      if line.startsWith(row["mark"].getStr) and
         line.contains(row["name"].getStr) and
         line.contains(row["where"].getStr) and hasDuration and
         line.endsWith(row["open"]["label"].getStr):
        inc matched
      else:
        checkpoint("after, row " & $r & ": '" & line & "'")
      # The mark's colour is the desktop's computed one.
      let markCol = s.text(r).cellFind(row["mark"].getStr)
      ck markCol >= 0 and s[r][markCol].fgHex == cssHex(row["markColor"].getStr)
      if row["state"].getStr == "failed":
        failedRow = r
      inc r
      # The message, line for line, under its row (indented under the name).
      let message = row["message"].getStr
      if message.len > 0:
        var lines = 0
        var same = 0
        for want in message.splitLines():
          let got = s.paneText(r)
          if got.strip(leading = false) == "  " & want.strip(leading = false) or
             (want.strip().len == 0 and got.strip().len == 0):
            inc same
          else:
            checkpoint("message line " & $lines & ": '" & got & "' for '" &
                       want & "'")
          inc lines
          inc r
        ck same == lines
        let msgCol = s.text(r - lines).cellFind("Failed")
        ck msgCol >= 0 and
           s[r - lines][msgCol].fgHex == cssHex(row["messageColor"].getStr)
    ck matched == after["rows"].len
    ck failedRow > hr

    # THE FAILING TEST'S ⏵: record-and-open — a NEW SESSION TAB.
    let failLine = s.text(failedRow)
    let openCol = failLine.cellFind("⏺⏵") + 1
    ck openCol > 0
    sess.press(failedRow, openCol)
    let (noteRow, noteCol) = sess.waitFor("in a new tab", RunBudgetMs)
    s = sess.snap()
    let note = s.text(noteRow)
    let idAt = note.find("opened the recording ")
    ck idAt >= 0
    let recording = note[idAt + "opened the recording ".len .. ^1].split(' ')[0]
    ck recording.len > 8
    discard noteCol
    # THE NEW TAB IS THAT RECORDING'S SESSION: the top bar names it, and the
    # Call Trace is the Noir test's own (`test_fails`, then `main`).
    discard sess.waitFor("trace: " & recording, 60_000)
    discard sess.waitFor("test_fails #1", 60_000)
    s = sess.snap()
    # The pane — the window's — keeps the recording: the failing test's ⏵
    # now opens it (no `⏺`).
    let (fr, _) = s.findRow("· test_fails")
    ck fr > 0 and s.paneText(fr).strip().endsWith("⟳ ⏵")

    # §5: A RUN KILLED MID-WAY SETTLES. Back to the pane (this tab's layout).
    s = sess.snap()
    let (tr2, tc2) = s.testsTabAt()
    ck tr2 >= 0
    sess.press(tr2, tc2)
    let (hr2, _) = sess.waitFor("2 tests, not run yet")
    s = sess.snap()
    let runCol2 = s.text(hr2).cellFind(before["run"]["label"].getStr)
    sess.press(hr2, runCol2)
    var victims: seq[int] = @[]
    let deadline = getMonoTime() + initDuration(milliseconds = 30_000)
    while victims.len == 0 and getMonoTime() < deadline:
      victims = runCtTestPids(project)
      sleep(20)
    ck victims.len > 0
    if victims.len > 0:
      let group = pgidOf(victims[0])
      ck group > 1
      discard posix.kill(Pid(-group), SIGKILL)
    discard sess.waitFor("ended by signal 9", 60_000)
    s = sess.snap()
    ck s.paneText(hr2).strip().startsWith("run failed, no tests ran")
    ck s.findRow("running…")[0] < 0

    # QUIT DURING A RUN: nothing is left running.
    sess.press(hr2, runCol2)
    var started = false
    let d2 = getMonoTime() + initDuration(milliseconds = 30_000)
    while not started and getMonoTime() < d2:
      started = runCtTestPids(project).len > 0
      sleep(20)
    ck started
    sess.send("\x11")   # Ctrl+Q, the CUA base's quit
    discard sess.waitExit(initDuration(seconds = 20))
    var gone = false
    let d3 = getMonoTime() + initDuration(milliseconds = 10_000)
    while not gone and getMonoTime() < d3:
      gone = runCtTestPids(project).len == 0
      sleep(50)
    ck gone
    sess.terminate()
    sess.close()
    removeDir(state)
    removeDir(project)

  test "§9: a test's tab reused, Ctrl opens in this tab, hover, a maximized pane":
    # Test-Results-Pane.md §9 on the shipped terminal: a maximized pane
    # answers its ▶ where it is drawn (codetracer-pm issue
    # 2026-10-24-tui-maximized-pane-receives-no-pane-clicks); hovering a
    # control shows its title on the status line; the failing test's ⏵ opens
    # a NEW tab, ⏵ again SHOWS that tab, a re-record opened REPLACES that
    # tab's session in place (rule 4: the tab count stays); a Ctrl+press on
    # the passing test's ⏵ opens it in THIS tab (the count stays again).
    let calc = resolveFixture(FixtureSpec(
      name: "calc", program: "test-programs/calc/main.py",
      recorder: "codetracer-python-recorder",
      probe: FixtureProbe(kind: pkPythonRecorder),
      buildHint: "Install codetracer_python_recorder into the interpreter " &
                 "`ct` will use.",
      blockedOn: ""))
    doAssert calc.outcome == foRecorded, calc.detail
    let ct = fixture_provider.findCtBinary()
    doAssert ct.len > 0, "prerequisite missing: ct (build it, or set CT_BIN)"
    let project = writePlat53Project("ct-plat53-pty9-")
    let state = getTempDir() / ("plat53-pty9-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", calc.tracePath])
      .width(Cols).height(Rows).transcript()
      .workDir(project)
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("CT_BIN", ct)
      .envSet("XDG_STATE_HOME", state)
      .envSet("CODETRACER_HOME", state / "ct-home")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
      .envSet("TEST_CERTIFICATES_DIR", state / "certs")
      .envSet("TEST_CERTIFICATES_SYSTEM_DIR", state / "certs-system")
      .carryRunMark()
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    proc sessionTabs(want: int): int =
      ## How many session tabs the window holds, read off its ENGINES: each
      ## tab's session runs its own `replay-server` (this run's, by its mark),
      ## and a replaced session's is stopped (rule 2) — so this counts tabs
      ## and catches a replacement that leaked its backend, which the strip
      ## (scrolled to fit beside the omnibox) cannot show. Polled until it is
      ## `want`, for the asynchronous exit of a stopped engine.
      let deadline = getMonoTime() + initDuration(milliseconds = 15_000)
      while true:
        result = markedReplayServerPids().len
        if result == want or getMonoTime() >= deadline:
          return
        sleep(100)
    var s = sess.snap()
    let (tr, tc) = s.testsTabAt()
    doAssert tr >= 0, "no Tests tab:\n" & s.screenText()
    sess.press(tr, tc)
    discard sess.waitFor("2 tests, not run yet")
    ck sessionTabs(1) == 1

    # MAXIMIZED, through the tab's own menu, then its ▶ pressed where drawn.
    sess.press(tr, tc, button = 2)
    let (mr, mc) = sess.waitFor("Maximise container")
    sess.press(mr, mc + 2)
    let (hr, _) = sess.waitFor("2 tests, not run yet")
    s = sess.snap()
    let runCol = s.text(hr).cellFind("▶")
    ck runCol > Cols div 2          # drawn across the whole body
    sess.press(hr, runCol)
    discard sess.waitFor("1 passed, 1 failed", RunBudgetMs)
    # Back to the arrangement (the menu now offers to restore it).
    s = sess.snap()
    let (tr1, tc1) = s.testsTabAt()
    let (tr2, tc2) = if tr1 >= 0: (tr1, tc1) else: s.findRow(" Tests")
    sess.press(tr2, tc2 + 1, button = 2)
    let (nr, nc) = sess.waitFor("Minimise container")
    sess.press(nr, nc + 2)
    sleep(400)

    # HOVER: the failing test's ⏵ — its title on the status line.
    s = sess.snap()
    let (fr, _) = s.findRow("✗ test_fai")   # the row (its name may be cut)
    ck fr > 0
    let openCol = s.text(fr).cellFind("⏺⏵") + 1
    ck openCol > 0
    sess.mouse(35, fr, openCol)
    discard sess.waitFor("Record test_fails and open the recording", 10_000)
    sess.mouse(35, fr, 2)
    sleep(400)
    ck sess.snap().text(Rows - 1).find("Record test_fails and open") < 0

    proc opened(sess: var TuiTestSession; words: string;
                notFolder = ""): string =
      ## The folder of the next "opened the recording <folder><words>" note
      ## that names a folder other than `notFolder`.
      let deadline = getMonoTime() + initDuration(milliseconds = RunBudgetMs)
      var last: Snapshot
      while getMonoTime() < deadline:
        last = sess.snap()
        for r in 0 ..< Rows:
          let t = last.text(r)
          let at = t.find("opened the recording ")
          if at >= 0 and t.contains(words):
            let folder = t[at + "opened the recording ".len .. ^1].split(' ')[0]
            if folder != notFolder:
              return folder
        sleep(100)
      raise newException(AssertionFailedError, "no note '" & words &
                         "'; screen:\n" & last.screenText())
    # ⏵ — record-and-open: a NEW tab.
    sess.press(fr, openCol)
    let first = sess.opened("in a new tab")
    discard sess.waitFor("test_fails #1", 60_000)
    ck sessionTabs(2) == 2
    # ⏵ again (the pane is in this tab's arrangement too): its OWN tab.
    proc reopen(sess: var TuiTestSession; test, glyph: string; button = 0) =
      var s = sess.snap()
      var (r, _) = s.findRow(test)
      if r < 0:
        let (t1, t2) = s.testsTabAt()
        sess.press(t1, t2)
        discard sess.waitFor(test)
        s = sess.snap()
        r = s.findRow(test)[0]
      let c = s.text(r).cellFind(glyph) + (if glyph.runeLen > 1: 1 else: 0)
      doAssert c >= 0, "no " & glyph & " on " & test & ":\n" & s.screenText()
      sess.press(r, c, button)
    sess.send("\x1b")    # a key, so the status line moves on
    sess.reopen("· test_fai", "⏵")
    ck sess.opened("in its own tab") == first
    ck sessionTabs(2) == 2
    # ⟳ records it again (and stays); ⏵ then opens the NEW recording in the
    # test's own tab, replacing its session in place: still two tabs.
    sess.reopen("· test_fai", "⟳")
    sleep(500)
    discard sess.waitFor("2 tests, not run yet", RunBudgetMs)
    let deadline = getMonoTime() + initDuration(milliseconds = RunBudgetMs)
    while getMonoTime() < deadline and sess.snap().findRow("running…")[0] >= 0:
      sleep(200)
    sess.reopen("· test_fai", "⏵")
    let second = sess.opened("in its own tab", notFolder = first)
    ck second != first
    discard sess.waitFor("test_fails #1", 60_000)
    ck sessionTabs(2) == 2
    # Ctrl+press (SGR 16) on the passing test's ⏵: record-and-open IN THIS
    # TAB, which is a replay — replaced, the strip keeps two tabs.
    sess.reopen("· test_pas", "⏺⏵", button = 16)
    let third = sess.opened("in this tab", notFolder = second)
    ck third != second
    discard sess.waitFor("test_passes #1", 60_000)
    ck sessionTabs(2) == 2
    sess.send("\x11")
    discard sess.waitExit(initDuration(seconds = 20))
    sess.terminate()
    sess.close()
    removeDir(state)
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
