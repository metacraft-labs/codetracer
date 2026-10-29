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
const ExpectedAssertions = 138

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

  test "the ▶ is the glyph table's run control on every tier":
    # The ViewModel's `RunButtonLabel` is the extended spelling; the painter
    # draws the terminal's own (CodeTracer-TUI-Terminal-Adaptation.md §6.3),
    # so a basic or ASCII terminal never gets a `▶` it may not have.
    ck RunLabel == RunButtonLabel
    let area = CellArea(col: 0, row: 0, width: 80, height: 6)
    for (profile, want) in [(GlyphProfile(tier: tierExtended), "▶"),
                            (GlyphProfile(tier: tierBasic), "►"),
                            (GlyphProfile(tier: tierAscii), ">"),
                            (GlyphProfile(tier: tierExtended,
                                          ambiguousWide: true), "▸")]:
      var m = sampleModel()
      m.run.label = RunButtonLabel
      var g = newStyledGrid(80, 6)
      g.glyphs = profile
      let s = paintTestResults(g, area, m)
      checkpoint($profile.tier & " ambiguousWide=" & $profile.ambiguousWide)
      ck g.runeAt(0, s.runCol) == want
      # A press on the drawn cell is still the run control.
      ck m.testsTargetAt(s, area, area.row, s.runCol).kind == tpRun

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
      openFolder = proc(testId, recordingId, folder: string;
                        policy: TraceOpenPolicy): string =
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
    ck rt.app.tests.rows[1].open.title.endsWith(
      "Press ⟳ to record it again first. " & OpensInNewTabText)
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
    # THE WINDOW CLOSES DURING A RUN (`stop`): the run's whole process group
    # ends AT ONCE — not when the suite would have finished — and the run
    # settles, ended by the signal the window sent.
    let (_, s6) = rt.testsPaneScreen()
    let third = rt.press(area.row, s6.runCol)
    ck src.applyClick(rt, third.paneClick)
    let group = src.host.job.pid
    let t0 = getMonoTime()
    src.host.stop()
    let stopMs = (getMonoTime() - t0).inMilliseconds
    checkpoint("stop took " & $stopMs & " ms")
    src.publish(rt)
    var ended = false
    for line in rt.app.tests.lines:
      if line.kind == tlFailure and line.text.contains("ended by signal 15"):
        ended = true
    # Attribute missing termination to the signal, before checking its speed
    # or the group's reaping. Without either stop signal (mutation N7), the
    # suite can finish naturally or waitForExit can kill the direct child;
    # neither is the SIGTERM the window should have sent. Which timing or
    # group check also fails depends on how quickly the real suite finishes.
    ck ended
    ck stopMs < 1000
    # No process of the group is left (allowing an orphan's reaping).
    var left = true
    for _ in 0 ..< 25:
      if posix.kill(Pid(-group), 0) != 0:
        left = false
        break
      sleep(20)
    ck not left
    # A HOST WITH NO `ct` refuses with a sentence and settles at once.
    let bare = newTestsSource(
      projectRoot = proc(): string = project,
      ctBinary = proc(): string = "",
      resolveFolder = proc(id: string): string = "",
      openFolder = proc(testId, recordingId, folder: string;
                        policy: TraceOpenPolicy): string = "")
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
      openFolder = proc(testId, recordingId, folder: string;
                        policy: TraceOpenPolicy): string = "")
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

suite "Test-Results-Pane.md §9: the destination, the hover, a maximized pane":

  test "Ctrl inverts the destination; Enter and the palette use the setting":
    # No `ct` is run: a recording is remembered on a row, so `⏵` opens it
    # (open-existing) and the opener — the capturing seam — records the
    # destination each press asked for.
    let state = createTempDir("ct-plat53-state-", "")
    let lanesState = getEnv("CODETRACER_TUI_LAYOUT_DIR")
    putEnv("CODETRACER_TUI_LAYOUT_DIR", state)
    let project = writePlat53Project()
    let app = newTuiApp()
    app.projectRoot = project
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    discard rt.enableLayoutBinding()
    var asked: seq[TraceOpenPolicy] = @[]
    let src = newTestsSource(
      projectRoot = proc(): string = app.projectRoot,
      ctBinary = proc(): string = ctBin,
      resolveFolder = proc(id: string): string = "/recordings/" & id,
      openFolder = proc(testId, recordingId, folder: string;
                        policy: TraceOpenPolicy): string =
        asked.add policy
        "")
    src.refresh(rt)
    # A replay tab is current, so "this tab" is a destination at all.
    ck src.setTabs(1, replaceable = true, shown = true)
    rt.showTestsTab()
    src.vm.rememberRecording(rt.app.tests.rows[1].testId, "rec-1", "t")
    src.publish(rt)
    ck rt.app.tests.rows[1].open.title.endsWith(
      "Opens in a new tab; Ctrl+click opens it in this tab.")
    let (area, s) = rt.testsPaneScreen()
    let row = s.listTop + s.listRowOf(1)
    let col = area.col + s.fit.starts[4] + 2
    # Plain: the setting (a new tab). Ctrl (SGR bit 16): inverted.
    let plain = rt.press(row, col)
    ck plain.paneClick.kind == pcTestsOpen and plain.paneClick.behaviour == ""
    ck src.applyClick(rt, plain.paneClick)
    let ctrl = rt.press(row, col, button = 16)
    ck ctrl.paneClick.kind == pcTestsOpen and
       ctrl.paneClick.behaviour == TestsRedirectBehaviour
    ck src.applyClick(rt, ctrl.paneClick)
    ck asked == @[topNewTab, topCurrentTab]
    ck not src.vm.redirectHeld.val   # held for that one press only
    # THE PALETTE'S COMMAND writes the workspace's setting …
    var outcome = RuntimeOutcome()
    rt.runMenuAction(replayOpenCommandTarget(topCurrentTab), outcome)
    ck outcome.paneClick.kind == pcTestsOpenIn
    ck src.applyClick(rt, outcome.paneClick)
    ck rt.app.notification == replayOpenSetNote(project, topCurrentTab)
    ck replayOpenFor(readFile(state / ReplayOpenFileName), project) ==
       topCurrentTab
    ck rt.app.tests.rows[1].open.title.endsWith(
      "Opens in this tab, ending its session; Ctrl+click opens a new tab.")
    # … which Enter on the selected row then uses, and Ctrl inverts back.
    discard rt.press(row, area.col + 4)
    let enter = rt.handleToken("\r", 0)
    ck src.applyClick(rt, enter.paneClick)
    let back = rt.press(row, col, button = 16)
    ck src.applyClick(rt, back.paneClick)
    ck asked == @[topNewTab, topCurrentTab, topCurrentTab, topNewTab]
    # A NEW HOST over the same workspace reads it back (the document).
    let again = newTestsSource(
      projectRoot = proc(): string = project,
      ctBinary = proc(): string = ctBin,
      resolveFolder = proc(id: string): string = "",
      openFolder = proc(testId, recordingId, folder: string;
                        policy: TraceOpenPolicy): string = "")
    again.refresh(rt)
    ck again.vm.openSetting.val == topCurrentTab
    again.close()
    src.close()
    if lanesState.len > 0: putEnv("CODETRACER_TUI_LAYOUT_DIR", lanesState)
    else: delEnv("CODETRACER_TUI_LAYOUT_DIR")
    removeDir(state)
    removeDir(project)

  test "hovering a control puts its title on the status line; leaving restores":
    let project = writePlat53Project()
    let app = newTuiApp()
    app.projectRoot = project
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    discard rt.enableLayoutBinding()
    let src = newTestsSource(
      projectRoot = proc(): string = app.projectRoot,
      ctBinary = proc(): string = ctBin,
      resolveFolder = proc(id: string): string = "",
      openFolder = proc(testId, recordingId, folder: string;
                        policy: TraceOpenPolicy): string = "")
    src.refresh(rt)
    rt.showTestsTab()
    rt.app.notification = "what the line said"
    let (area, s) = rt.testsPaneScreen()
    let row = s.listTop + s.listRowOf(1)
    let openCol = area.col + s.fit.starts[4] + 2
    proc statusLine(): string = rt.shellScreenOf().rows[^1]
    # `?1003` motion with no button (SGR 35) over the failing test's `⏵`.
    let moved = rt.handleToken(sgr(35, row, openCol, true), 0)
    ck moved.repaint
    let title = rt.app.tests.rows[1].open.title
    ck rt.app.testsHover == title
    ck statusLine().contains(title[0 ..< 30])
    # Over `⟳`, then the ▶: their titles.
    discard rt.handleToken(sgr(35, row, openCol - 2, true), 0)
    ck rt.app.testsHover == rt.app.tests.rows[1].refresh.title
    discard rt.handleToken(sgr(35, area.row, s.runCol, true), 0)
    ck rt.app.testsHover == rt.app.tests.run.title
    ck statusLine().contains(rt.app.tests.run.title[0 ..< 20])
    # Off every control: the line says what it said before.
    discard rt.handleToken(sgr(35, row, area.col + 4, true), 0)
    ck rt.app.testsHover == ""
    ck statusLine().contains("what the line said")
    ck rt.app.notification == "what the line said"
    src.close()
    removeDir(project)

  test "a maximized Test Results answers its presses where it is drawn":
    let project = writePlat53Project()
    let app = newTuiApp()
    app.projectRoot = project
    let rt = newTuiRuntime(app, caps(), Cols, 50)
    discard rt.enableLayoutBinding()
    rt.refreshMenuForKeymap()
    let src = newTestsSource(
      projectRoot = proc(): string = app.projectRoot,
      ctBinary = proc(): string = ctBin,
      resolveFolder = proc(id: string): string = "",
      openFolder = proc(testId, recordingId, folder: string;
                        policy: TraceOpenPolicy): string = "")
    src.refresh(rt)
    rt.showTestsTab()
    # The tab's menu → "Maximise container", as a user chooses it.
    let (tr, tc) = rt.findOnScreen("Tests")
    discard rt.press(tr, tc + 1, button = 2)
    ck rt.app.contextMenu.open
    let labels = rt.app.contextMenu.menu.labels
    let at = labels.find("Maximise container")
    ck at >= 0
    let menuArea = rt.shellScreenOf().contextMenuArea
    discard rt.press(menuArea.row + 1 + at, menuArea.col + 3)
    ck rt.maximize.active and rt.maximize.pane == paneTestResults
    # The pane is drawn over the whole body now; its ▶ is at the right edge.
    let (area, s) = rt.testsPaneScreen()
    ck area.width > Cols div 2
    ck s.runCol > Cols div 2
    ck cellSlice(rt.screenRows()[area.row], s.runCol, s.runCol + 1) == RunLabel
    let run = rt.press(area.row, s.runCol)
    ck run.paneClick.kind == pcTestsRun
    # A row press selects that row — in the maximized pane.
    discard rt.press(s.listTop + s.listRowOf(1), area.col + 4)
    ck rt.app.tests.selected == 1
    # And its `⏵` is a press on that test.
    let open = rt.press(s.listTop + s.listRowOf(1),
                        area.col + s.fit.starts[4] + 2)
    ck open.paneClick.kind == pcTestsOpen and
       open.paneClick.text == rt.app.tests.rows[1].testId
    src.close()
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions

removeDir(certificates)
