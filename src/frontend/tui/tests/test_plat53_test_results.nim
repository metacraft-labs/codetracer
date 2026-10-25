## test_plat53_test_results.nim — PLAT-53, Tier 1: **the terminal's Test
## Results pane**, painted from its value and driven through the product's
## runtime over the REAL host on a real project.
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §8 (§5 for the settle).
##
##   * THE PAINTER at every width from 24 to 160 cells: the headline and the
##     ▶ (dimmed when it cannot run); each row's mark, name, location,
##     duration and `⟳` / `⏵`, the name and the location sharing the room
##     18 : 10 and cut with `…`; a message under its row, indented and
##     wrapped in the error colour; the failure, absence and empty lines; the
##     scrollbar exactly when the list overflows — and every part hit-tested
##     by the arithmetic that drew it;
##   * THE RUNTIME OVER THE REAL HOST (`host/test_results_source`, which
##     installs `desktop_test_host` over `viewmodel/host/native_test_host`'s
##     producers): the catalog of a real Noir crate read from its directory;
##     the ▶, pressed with exact SGR bytes on the cell it was drawn in, runs
##     the real `ct test run` and the pane paints the runner's verdicts (one
##     ✓, one ✗ with its message); a press on a row selects it, Up / Down /
##     Home / End move the selection, the wheel scrolls; a disabled control
##     says why on the status line and runs nothing; the failing test's `⏵`
##     runs the real `ct record-test`, and the recording it made is handed to
##     the window to open in a new tab, a real trace folder; `⏵` again opens
##     the SAME recording and runs nothing;
##   * §5 — A RUN KILLED MID-WAY SETTLES: `ct test run` killed with SIGKILL
##     (its whole process group) leaves no "running…", says it was ended by a
##     signal, and the ▶ is live again; a host with no `ct` refuses with a
##     sentence and settles at once.
##
## No mocks: the real `ct`, `ct-test` and `nargo` on a real crate, the
## product's runtime and host. THE ONE STAND-IN is the window's
## `openFolder` seam — in the shipped terminal `app.recordingOpener`, which
## starts a replay session in a new tab (that half is the pty suite's,
## `real_terminal/test_plat53_test_results_pty.nim`). Here it is a closure that
## records the folder it is handed, and the suite then checks that folder is a
## real recording (`traceFolderProblem`): it captures, it does not pretend.

import std/[os, posix, strutils, monotimes, tempfiles, times, unittest]

import codetracer_embed

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/test_results_pane
import ../host/test_results_source
import ../../viewmodel/host/native_test_host   # `running`, the job's pid
from ../host/native_host import recordingFolderOf, traceFolderProblem
import ./fixtures/fixture_provider
import ./fixtures/plat53_noir_project
import ../../../common/view_vocabulary
from ../../view_vocabulary/pane_views import testResultsPaneView,
  TestResultsColumns

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 90

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 20
  RunBudgetMs = 300_000

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc sgr(button, row, col: int; pressed: bool): string =
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc ctrl(text: string; enabled = true): TestsPaneControl =
  TestsPaneControl(label: text, enabled: enabled, title: "t " & text)

proc paneRow(name, state: string; tone: TestsTone; where = "src/main.nr:5";
             duration = "12ms"; open = "⏵"): TestsPaneRow =
  TestsPaneRow(testId: "id/" & name, selector: name, state: state, tone: tone,
               mark: (case tone
                      of ttoPassed: "✓"
                      of ttoFailed: "✗"
                      of ttoNotRun: "·"
                      of ttoOther: "…"),
               name: name, where: where, duration: duration,
               refresh: ctrl("⟳"), open: ctrl(open))

proc sampleModel(): TestResultsPaneModel =
  result = TestResultsPaneModel(loaded: true, headline: "1 passed, 1 failed",
                                run: ctrl(RunLabel), selected: -1)
  result.rows = @[
    paneRow("test_passes_with_a_rather_long_name", "passed", ttoPassed),
    paneRow("test_fails", "failed", ttoFailed, where = "src/main.nr:10",
            open = "⏺⏵")]
  result.lines = @[
    TestsPaneLine(kind: tlRow, row: 0),
    TestsPaneLine(kind: tlRow, row: 1),
    TestsPaneLine(kind: tlMessage, row: 1,
                  text: "Failed to solve program: 'Cannot satisfy constraint'"),
    TestsPaneLine(kind: tlFailure, row: -1, text: "a run-level diagnostic"),
    TestsPaneLine(kind: tlAbsence, row: -1, text: "why it cannot run")]

suite "PLAT-53: the terminal's Test Results painter":

  test "every width: the header, the columns, the cut and the hit-tests":
    var bad = 0
    for width in 24 .. 160:
      let m = sampleModel()
      let area = CellArea(col: 2, row: 1, width: width, height: 12)
      var g = newStyledGrid(area.col + width, area.row + area.height)
      let s = paintTestResults(g, area, m)
      let header = g.rowText(area.row)
      # The ▶ at the right edge, the headline left of it.
      if s.runCol < 0 or not header.contains(RunLabel) or
         not header.startsWith(spaces(area.col) & "1 passed"):
        inc bad; checkpoint("header at " & $width & ": " & header)
      # The two flexible columns share 18 : 10 (±1 for the integer share).
      let f = s.fit
      if f.mode != fmScroll:
        let shared = f.widths[1] + f.widths[2]
        let want = shared * 18 div 28
        if abs(f.widths[1] - want) > 1:
          inc bad; checkpoint("share at " & $width & ": " & $f.widths)
      # Row 0's name is whole or ends in `…`.
      let row0 = g.rowText(s.listTop)
      if not (row0.contains("test_passes_with_a_rather_long_name") or
              row0.contains("…")):
        inc bad; checkpoint("cut at " & $width & ": " & row0)
      # Every control hit-tests as drawn.
      let a = area.col + f.starts[4]
      if f.mode != fmScroll and a + 3 < area.col + area.width:
        let r1 = s.listTop + 1
        if m.testsTargetAt(s, area, r1, a).kind != tpRefresh or
           m.testsTargetAt(s, area, r1, a + 2).kind != tpOpen or
           m.testsTargetAt(s, area, r1, area.col + 3).kind != tpRow or
           m.testsTargetAt(s, area, s.listTop + 2, area.col + 4).kind != tpRow:
          inc bad; checkpoint("hits at " & $width)
      if m.testsTargetAt(s, area, area.row, s.runCol).kind != tpRun:
        inc bad; checkpoint("run hit at " & $width)
    ck bad == 0

  test "the message is indented and in the error colour; the marks coloured":
    let m = sampleModel()
    let area = CellArea(col: 0, row: 0, width: 100, height: 12)
    var g = newStyledGrid(100, 12)
    let s = paintTestResults(g, area, m)
    let message = g.rowText(s.listTop + 2)
    ck message.startsWith("  Failed to solve program")
    ck g.styleAt(s.listTop + 2, 2).role == srChromeError
    ck g.styleAt(s.listTop, 0).role == srChromeSuccess   # ✓
    ck g.styleAt(s.listTop + 1, 0).role == srChromeError # ✗
    ck g.rowText(s.listTop + 3).startsWith("a run-level diagnostic")
    ck g.styleAt(s.listTop + 3, 0).role == srChromeError
    ck g.rowText(s.listTop + 4).startsWith("why it cannot run")
    ck g.styleAt(s.listTop + 4, 0).role == srChromeMuted
    ck s.trackCol == -1                     # five lines fit in eleven
    ck s.painted.len == 5
    ck s.painted[1].contains("⟳ ⏺⏵")

  test "a long message wraps; the list overflows into a scrollbar":
    var m = sampleModel()
    m.lines[2].text = repeat("constraint ", 30)
    let area = CellArea(col: 0, row: 0, width: 60, height: 5)
    var g = newStyledGrid(60, 5)
    let s = paintTestResults(g, area, m)
    ck s.wrapped.len > m.lines.len
    ck s.trackCol == 59
    ck m.testsTargetAt(s, area, s.listTop, 59).kind == tpTrack
    var scrolled = m
    scrolled.scrollTop = 2
    var g2 = newStyledGrid(60, 5)
    let s2 = paintTestResults(g2, area, scrolled)
    ck s2.painted[0] == s.painted[2]

  test "a disabled ▶ is dimmed, never hidden":
    var m = sampleModel()
    m.run.enabled = false
    let area = CellArea(col: 0, row: 0, width: 80, height: 6)
    var g = newStyledGrid(80, 6)
    let s = paintTestResults(g, area, m)
    ck g.runeAt(0, s.runCol) == RunLabel
    ck g.styleAt(0, s.runCol).dim

# ---------------------------------------------------------------------------
# The runtime over the real host
# ---------------------------------------------------------------------------

proc screenRows(rt: TuiRuntime): seq[string] =
  rt.shellScreenOf().rows

proc findOnScreen(rt: TuiRuntime; needle: string): (int, int) =
  for r, line in rt.screenRows():
    let c = line.find(needle)
    if c >= 0:
      return (r, cellWidthOf(line[0 ..< c]))
  (-1, -1)

proc press(rt: TuiRuntime; row, col: int; button = 0): RuntimeOutcome =
  ## A press and its release; the outcome that carried the click.
  result = rt.handleToken(sgr(button, row, col, true), 0)
  let release = rt.handleToken(sgr(button, row, col, false), 0)
  if result.paneClick.kind == pcNone:
    result = release

proc settle(rt: TuiRuntime; src: TestsSource): bool =
  ## Tick the host as the loop does until the run in flight has settled.
  let deadline = getMonoTime() + initDuration(milliseconds = RunBudgetMs)
  while src.host.running and getMonoTime() < deadline:
    discard src.tick(rt)
    sleep(50)
  discard src.tick(rt)
  not src.host.running

proc paneText(rt: TuiRuntime): seq[string] =
  ## The pane's list rows as the runtime's last frame painted them.
  rt.testsPaneScreen().screen.painted

proc showTestsTab(rt: TuiRuntime) =
  ## A press on the "Tests" tab of the Files stack, where the shared default
  ## places the pane.
  let (r, c) = rt.findOnScreen("Tests")
  doAssert r >= 0, "no Tests tab on screen:\n" & rt.screenRows().join("\n")
  discard rt.press(r, c + 1)

let ctBin = fixture_provider.findCtBinary()
let certificates = createTempDir("ct-plat53-certs-", "")
putEnv("TEST_CERTIFICATES_DIR", certificates)

suite "PLAT-53: the terminal's Test Results pane over the real host":

  test "catalog, ▶, verdicts, selection, a recording opened, kill, refusal":
    doAssert ctBin.len > 0, "prerequisite missing: ct (build it, or set CT_BIN)"
    let project = writePlat53Project()
    let app = newTuiApp()
    app.projectRoot = project
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    discard rt.enableLayoutBinding()
    var opened: seq[string] = @[]
    let src = newTestsSource(
      projectRoot = proc(): string = app.projectRoot,
      ctBinary = proc(): string = ctBin,
      resolveFolder = proc(id: string): string = recordingFolderOf(id),
      openFolder = proc(folder: string): string =
        opened.add folder
        "")
    src.refresh(rt)
    rt.showTestsTab()
    # THE CATALOG, read from the crate's directory.
    ck rt.app.tests.headline == "2 tests, not run yet"
    var names: seq[string] = @[]
    for r in rt.app.tests.rows: names.add r.name
    ck names == @[Plat53Passing, Plat53Failing]
    ck rt.app.tests.rows[0].where == "src/main.nr:" & $Plat53PassingLine
    ck rt.app.tests.rows[1].where == "src/main.nr:" & $Plat53FailingLine
    ck rt.app.tests.rows[0].mark == "·"
    ck rt.app.tests.rows[0].duration == ""
    ck rt.app.tests.rows[1].open.label == "⏺⏵"   # nothing to open: records
    ck rt.app.tests.rows[1].open.mode == "record-and-open"
    let shown = rt.paneText()
    ck shown.len == 2 and shown[0].contains(Plat53Passing)
    # THE ▶, pressed on the cell it was drawn in.
    let (area, screen) = rt.testsPaneScreen()
    ck screen.runCol >= 0
    ck cellSlice(rt.screenRows()[area.row], screen.runCol, screen.runCol + 1) == RunLabel
    let pressed = rt.press(area.row, screen.runCol)
    ck pressed.paneClick.kind == pcTestsRun
    ck src.applyClick(rt, pressed.paneClick)
    ck src.host.running
    ck rt.app.tests.headline == "running…"
    ck not rt.app.tests.run.enabled
    # A DISABLED CONTROL SAYS WHY and runs nothing: ⟳ while the suite runs.
    let (_, s1) = rt.testsPaneScreen()
    let refreshCol = area.col + s1.fit.starts[4]
    let busy = rt.press(s1.listTop, refreshCol)
    ck busy.paneClick.kind == pcNone
    ck rt.app.notification == "A test run is already in progress"
    ck rt.settle(src)
    # THE RUNNER'S VERDICTS.
    ck rt.app.tests.headline.startsWith("1 passed, 1 failed")   # "· 1.2s"
    ck rt.app.tests.rows[0].state == "passed" and
       rt.app.tests.rows[0].mark == "✓"
    ck rt.app.tests.rows[1].state == "failed" and
       rt.app.tests.rows[1].mark == "✗"
    ck rt.app.tests.rows[1].duration.endsWith("ms") or
       rt.app.tests.rows[1].duration.endsWith("s")
    # THE VOCABULARY'S VIEW of the same ViewModel (what a medium without a
    # native pane draws, and the GPUI leaf plan's tree): a `Table` of the
    # same cells.
    var table: ViewNode = nil
    for n in walk(testResultsPaneView(src.vm).root):
      if n.kind == pkTable: table = n
    ck not table.isNil and table.columns == TestResultsColumns
    ck not table.isNil and table.rows.len == 2 and
       table.rows[0][0 .. 2] == @["✓", Plat53Passing,
                                 "src/main.nr:" & $Plat53PassingLine] and
       table.rows[1][0 .. 2] == @["✗", Plat53Failing,
                                 "src/main.nr:" & $Plat53FailingLine] and
       table.rows[1][3] == rt.app.tests.rows[1].duration
    let after = rt.paneText()
    ck after.len > 3
    # The failure's message, under its row (wrapped to the narrow pane).
    ck after[2 .. ^1].join(" ").splitWhitespace().join(" ").contains(
      "Failed to solve program")
    ck rt.app.tests.run.enabled
    # SELECTION: a press on a row; the keys move it (the pane focused by the
    # press).
    let (_, s2) = rt.testsPaneScreen()
    discard rt.press(s2.listTop, area.col + 4)
    ck rt.app.tests.selected == 0
    discard rt.handleToken("\x1b[B", 0)    # Down
    ck rt.app.tests.selected == 1
    discard rt.handleToken("\x1b[H", 0)    # Home
    ck rt.app.tests.selected == 0
    discard rt.handleToken("\x1b[F", 0)    # End
    ck rt.app.tests.selected == 1
    # THE WHEEL scrolls the list — which overflows the pane here (two rows
    # and the failure's eight message lines).
    ck s2.wrapped.len > s2.listRows
    discard rt.handleToken(sgr(65, s2.listTop, area.col + 4, true), 0)
    ck rt.app.tests.scrollTop > 0
    discard rt.handleToken(sgr(64, s2.listTop, area.col + 4, true), 0)
    discard rt.handleToken(sgr(64, s2.listTop, area.col + 4, true), 0)
    ck rt.app.tests.scrollTop == 0
    # THE FAILING TEST'S ⏵ — record-and-open: the real `ct record-test`.
    let (_, s3) = rt.testsPaneScreen()
    let failRow = s3.listTop + s3.listRowOf(1)
    let openCol = area.col + s3.fit.starts[4] + 2
    let o = rt.press(failRow, openCol)
    ck o.paneClick.kind == pcTestsOpen and o.paneClick.text == rt.app.tests.rows[1].testId
    ck src.applyClick(rt, o.paneClick)
    ck src.host.running
    ck rt.settle(src)
    ck opened.len == 1
    ck opened.len == 1 and traceFolderProblem(opened[0]) == ""
    let recording = rt.app.tests.rows[1].recordingId
    ck recording.len > 0
    ck opened.len == 1 and opened[0].contains(recording)
    ck rt.app.tests.rows[1].open.label == "⏵"
    ck rt.app.tests.rows[1].open.mode == "open-existing"
    ck rt.app.tests.rows[1].open.title.endsWith("Press ⟳ to record it again first.")
    # §4.2: a recording is not a verdict — the record run began a run (the
    # last verdicts cleared, as on the desktop) and reported none.
    ck rt.app.tests.headline == "2 tests, not run yet"
    ck rt.app.notification.contains("in a new tab")
    # ⏵ AGAIN opens the SAME recording and runs nothing. (Re-aimed: the list
    # no longer overflows, so the columns took back the scrollbar's cell.)
    let (_, s5) = rt.testsPaneScreen()
    let o2 = rt.press(s5.listTop + s5.listRowOf(1),
                      area.col + s5.fit.starts[4] + 2)
    ck src.applyClick(rt, o2.paneClick)
    ck not src.host.running
    ck opened.len == 2 and opened[1] == opened[0]
    ck rt.app.tests.rows[1].recordingId == recording
    # Enter on the selected row is its ⏵.
    discard rt.press(failRow, area.col + 4)
    let enter = rt.handleToken("\r", 0)
    ck enter.paneClick.kind == pcTestsOpen
    # §5: A RUN KILLED MID-WAY SETTLES.
    let (_, s4) = rt.testsPaneScreen()
    let again = rt.press(area.row, s4.runCol)
    ck src.applyClick(rt, again.paneClick)
    ck src.host.running
    let pid = src.host.job.pid
    sleep(200)
    discard posix.kill(Pid(-pid), SIGKILL)
    ck rt.settle(src)
    ck rt.app.tests.headline != "running…"
    var said = false
    for line in rt.app.tests.lines:
      if line.kind == tlFailure and line.text.contains("ended by signal 9"):
        said = true
    ck said
    ck rt.app.tests.run.enabled
    # A HOST WITH NO `ct` refuses with a sentence and settles at once.
    let bare = newTestsSource(
      projectRoot = proc(): string = project,
      ctBinary = proc(): string = "",
      resolveFolder = proc(id: string): string = "",
      openFolder = proc(folder: string): string = "")
    bare.refresh(rt)
    ck bare.applyClick(rt, PaneClickRequest(kind: pcTestsRun))
    ck not bare.host.running
    ck rt.app.tests.headline == "run failed, no tests ran"
    var refused = false
    for line in rt.app.tests.lines:
      if line.kind == tlFailure and line.text == "no ct found to run the tests with; set CT_BIN":
        refused = true
    ck refused
    bare.close()
    src.close()
    removeDir(project)

  test "a folder that is not a crate says so, and the ▶ says why":
    let plain = createTempDir("ct-plat53-plain-", "")
    let app = newTuiApp()
    app.projectRoot = plain
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    let src = newTestsSource(
      projectRoot = proc(): string = app.projectRoot,
      ctBinary = proc(): string = ctBin,
      resolveFolder = proc(id: string): string = "",
      openFolder = proc(folder: string): string = "")
    src.refresh(rt)
    ck rt.app.tests.headline == "no tests found"
    ck not rt.app.tests.run.enabled
    ck rt.app.tests.run.title.startsWith("This project has no Nargo.toml")
    ck rt.app.tests.lines.len == 2
    ck rt.app.tests.lines[0].kind == tlAbsence
    ck rt.app.tests.lines[1].kind == tlEmpty
    # RE-ROOTED (a welcome tab's folder): the pane follows on the next tick.
    let project = writePlat53Project()
    app.projectRoot = project
    ck src.tick(rt)
    ck rt.app.tests.rows.len == 2
    ck rt.app.tests.run.enabled
    src.close()
    removeDir(plain)
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions

removeDir(certificates)
