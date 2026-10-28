## test_plat56_build_output.nim — PLAT-56, Tier 1: **the terminal's Build
## Output pane**, painted from its value and driven through the product's
## runtime over REAL builds of a real project.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.13 (the pane on every
## front-end), §3.5 (ANSI colour), §3.7 (build history), §3.10 (the status
## bar).
##
##   * THE PAINTER at every width from 30 to 160 cells: the verdict on the
##     left in its colour, the controls on the right while they fit (each
##     hit-tested where it was drawn); each line in its compiler's colours
##     (the literal colour of an SGR run, its weight), stderr in the error
##     colour and italic, a located line in its severity's colour; the
##     scrollbar exactly when the output overflows; the empty state; the
##     history picker open;
##   * THE RUNTIME OVER REAL BUILDS (`host/build_output_source`, the window's
##     `BuildVM` fed by `host/build_problems` from the runner the shipped loop
##     uses): `:build` of a FAILING coloured `gcc` build typed into the
##     omnibox of an Edit-mode session over the PLAT-56 project — the pane's
##     lines are the compiler's (its recorded transcript read by the shared
##     reader: the same compiler still writes it), each line's text and runs
##     EQUAL to the desktop's for the same output
##     (`src/tests/visual/answers/plat56-build-output.electron.json`), the
##     verdict and the status line's indicator the desktop's words; a press on
##     a located line opens ITS file at ITS line and column (K35); a PASSING
##     build after it: its verdict, the first build in the history, shown
##     again from the picker; Run builds the shown command again; Clear; the
##     status line's indicator pressed reveals the pane;
##   * THE VOCABULARY'S VIEW of the same ViewModel (`buildOutputPaneView`):
##     the verdict, the history and the lines, and the pane no longer an
##     accepted exception.
##
## No mocks: the real `gcc` on a real project, the product's runtime, runner
## and hosts. The editor a line opens in is the product's `EditSession`, its
## file read by the shipped `edit_host.readProjectFile`.

import std/[json, os, strutils, monotimes, times, unittest]

import codetracer_embed

import ../app/runtime
import ../app/tui_app
import ../app/build_session
import ../app/edit_binding
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/build_output
import ../host/problems_source
import ../host/build_output_source
import ../host/build_runner
from ../host/edit_host import readProjectFile, TuiHostError
import ../../viewmodel/tests/unit/build_fixtures/plat56_c_build
import ../../../common/view_vocabulary
from ../../view_vocabulary/pane_views import buildOutputPaneView,
  PaneAcceptedExceptions, PaneVocabularyPanes

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 70

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 40
  BuildBudgetMs = 120_000
  AnswersFile = currentSourcePath().parentDir() / ".." / ".." / ".." /
                "tests" / "visual" / "answers" /
                "plat56-build-output.electron.json"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc sgr(button, row, col: int; pressed: bool): string =
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc press(rt: TuiRuntime; row, col: int; button = 0): RuntimeOutcome =
  result = rt.handleToken(sgr(button, row, col, true), 0)
  let release = rt.handleToken(sgr(button, row, col, false), 0)
  if result.paneClick.kind == pcNone:
    result = release

proc failedVM(): BuildVM =
  ## The ViewModel after the failing build's recorded output.
  var vm: BuildVM
  createRoot proc(dispose: proc()) =
    vm = createBuildVM(nil)
  vm.beginBuild(Plat56FailCommand, 1000.0)
  for raw in Plat56FailTranscript:
    discard vm.feedOutput(raw, isStdout = false)
  vm.finishBuild(1, 1400.0)
  vm

suite "PLAT-56: the terminal's Build Output painter":

  test "every width: the verdict, the controls, the colours, the hit-tests":
    let m = paneModelOf(failedVM())
    var bad = 0
    for width in 30 .. 160:
      let area = CellArea(col: 2, row: 1, width: width, height: 10)
      var g = newStyledGrid(area.col + width, area.row + area.height)
      let s = paintBuildOutput(g, area, m)
      let header = g.rowText(area.row)
      if width >= cellWidthOf(m.headline) and
         not header[area.col .. ^1].startsWith(m.headline):
        inc bad; checkpoint("verdict at " & $width & ": " & header)
      if g.styleAt(area.row, area.col).role != statusStyle(bsFailed).role:
        inc bad; checkpoint("verdict colour at " & $width)
      if s.controls.len > 0:
        if s.controls.len != 4:
          inc bad; checkpoint("controls at " & $width)
        for c in s.controls:
          let t = m.buildTargetAt(s, area, s.controlsRow, c.col)
          if t.kind != btControl or t.control != c.control:
            inc bad; checkpoint("control hit " & $c.control & " at " & $width)
      elif width >= 31:
        inc bad; checkpoint("no controls at " & $width)
      if s.controls.len > 0 and s.controlsRow == area.row and
         s.controls[0].col < area.col + cellWidthOf(m.headline) + 1:
        inc bad; checkpoint("controls over the verdict at " & $width)
      # Line 1 (the first error) in its severity's colour where the compiler
      # set none, its `error: ` run in the compiler's red, bold.
      let row = s.listTop + 1 - s.first
      if row >= s.listTop and row < s.listTop + s.listRows:
        let t = m.buildTargetAt(s, area, row, area.col + 1)
        if t.kind != btLine or t.index != 1:
          inc bad; checkpoint("line hit at " & $width)
        let errCol = area.col + "src/main.c:5:17: ".len
        if errCol < area.col + width - 1:
          let st = g.styleAt(row, errCol)
          if st.fg != "#bb0000" or not st.bold:
            inc bad; checkpoint("error run at " & $width & ": " & $st)
          if g.styleAt(row, area.col + 16).role != srChromeError:
            inc bad; checkpoint("located colour at " & $width)
      if s.trackCol != area.col + width - 1:
        inc bad; checkpoint("no scrollbar at " & $width)
    ck bad == 0

  test "stderr italic in the error colour, stdout plain, the empty state":
    createRoot proc(dispose: proc()) =
      let vm = createBuildVM(nil)
      let area = CellArea(col: 0, row: 0, width: 80, height: 8)
      var g0 = newStyledGrid(80, 8)
      let s0 = paintBuildOutput(g0, area, paneModelOf(vm))
      ck g0.rowText(1).startsWith(BuildIdleText)
      ck s0.renderedLines == 0
      vm.beginBuild("make", 1.0)
      discard vm.feedOutput("compiling", isStdout = true)
      discard vm.feedOutput("warning-ish chatter", isStdout = false)
      var g = newStyledGrid(80, 8)
      let s = paintBuildOutput(g, area, paneModelOf(vm))
      ck g.rowText(0).startsWith("running make")
      ck s.painted == @["compiling", "warning-ish chatter"]
      ck g.styleAt(s.listTop, 0).role == srChromeText
      ck not g.styleAt(s.listTop, 0).italic
      ck g.styleAt(s.listTop + 1, 0).role == srChromeError
      ck g.styleAt(s.listTop + 1, 0).italic
      dispose()

  test "the history picker, open":
    createRoot proc(dispose: proc()) =
      let vm = failedVM()
      vm.beginBuild(Plat56PassCommand, 2000.0)
      for raw in Plat56PassTranscript:
        discard vm.feedOutput(raw, false)
      vm.finishBuild(0, 2200.0)
      var m = paneModelOf(vm, historyOpen = true)
      ck m.history.len == 2
      let area = CellArea(col: 0, row: 0, width: 120, height: 12)
      var g = newStyledGrid(120, 12)
      let s = paintBuildOutput(g, area, m)
      ck s.controls.len == 5 and s.controls[0].control == bcHistory
      ck s.menuRows == 2
      ck g.rowText(s.menuTop).contains(BuildLatestLabel)
      ck g.rowText(s.menuTop + 1).contains("#1 " & Plat56FailCommand)
      let t = m.buildTargetAt(s, area, s.menuTop + 1, 4)
      ck t.kind == btHistoryItem and t.index == 1
      dispose()

  test "the History control and the shown build's mark come from the glyph table":
    # CodeTracer-TUI-Terminal-Adaptation.md §6.3: `grDropdown` and
    # `grCurrentEntry`, so a basic or ASCII terminal never gets a `▾` or a
    # `●` it may not have. The control keeps its width on every tier, so the
    # hit-test still finds it where it was drawn.
    createRoot proc(dispose: proc()) =
      let vm = failedVM()
      vm.beginBuild(Plat56PassCommand, 2000.0)
      for raw in Plat56PassTranscript:
        discard vm.feedOutput(raw, false)
      vm.finishBuild(0, 2200.0)
      let m = paneModelOf(vm, historyOpen = true)
      let area = CellArea(col: 0, row: 0, width: 120, height: 12)
      for (profile, arrow, mark) in [
          (GlyphProfile(tier: tierExtended), "▾", "●"),
          (GlyphProfile(tier: tierBasic), "▼", "●"),
          (GlyphProfile(tier: tierAscii), "v", "*")]:
        var g = newStyledGrid(120, 12)
        g.glyphs = profile
        let s = paintBuildOutput(g, area, m)
        checkpoint($profile.tier)
        let h = s.controls[0]
        ck h.control == bcHistory and
           g.rowText(area.row).contains("History " & arrow)
        ck g.rowText(s.menuTop).startsWith(mark & " ")
      dispose()

# ---------------------------------------------------------------------------
# The runtime over real builds
# ---------------------------------------------------------------------------

type
  BuildBox = ref object
    b: RunningBuild

  Session = object
    rt: TuiRuntime
    problems: ProblemsSource
    src: BuildOutputSource
    held: BuildBox
    project: string

proc open(project: string): Session =
  ## An Edit-mode window over `project`, wired as `main.nim`'s edit loop
  ## wires it: the project reader, the build runner, the Problems and Build
  ## Output sources.
  let app = newTuiApp()
  app.projectRoot = project
  app.modes = initModeRegister(pmEdit)
  let rt = newTuiRuntime(app, caps(), Cols, Rows)
  discard rt.enableLayoutBinding()
  let held = BuildBox()
  rt.editServices.readFile = proc(relative: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readProjectFile(project, relative))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  rt.editServices.startBuild = proc(kind: BuildKind;
                                    cmd: string): BuildStartResult =
    held.b = startBuild(kind, cmd, project, nowMonoMs())
    rt.app.build = held.b.session
    BuildStartResult(ok: held.b.session.verdict == bvRunning,
                     message: $kind & " started: " & cmd)
  let opener = proc(path: string; line, col: int): string =
    rt.openWorkingFileAt(path, line, col)
  let problems = newProblemsSource(rt, opener)
  let src = newBuildOutputSource(rt, problems, opener,
    proc(command, noun: string): string =
      let started = rt.editServices.startBuild(bkBuild, command)
      if started.ok: "" else: started.message)
  Session(rt: rt, problems: problems, src: src, held: held, project: project)

proc omnibox(s: Session; line: string) =
  discard s.rt.handleToken("\x10", 0)
  for ch in line:
    discard s.rt.handleToken($ch, 0)
  discard s.rt.handleToken("\r", 0)

proc settle(s: var Session): BuildVerdict =
  ## The loop's ticks until the build settles: the runner polled, the panes
  ## following.
  let deadline = getMonoTime() + initDuration(milliseconds = BuildBudgetMs)
  while s.held.b.session.verdict == bvRunning and getMonoTime() < deadline:
    discard pollBuild(s.held.b, nowMonoMs())
    discard s.problems.tick(s.rt, nowMonoMs())
    discard s.src.tick(s.rt)
    sleep(20)
  discard pollBuild(s.held.b, nowMonoMs())
  discard s.problems.tick(s.rt, nowMonoMs())
  discard s.src.tick(s.rt)
  s.held.b.session.verdict

proc build(s: var Session; command: string): BuildVerdict =
  s.held.b = nil
  s.omnibox(":build " & command)
  doAssert not s.held.b.isNil, "`:build` did not start a build: " &
    s.rt.app.notification
  s.settle()

proc desktop(): JsonNode =
  doAssert fileExists(AnswersFile), "the desktop's capture is missing: " &
    AnswersFile & " (run `just plat56-capture-electron`)"
  parseFile(AnswersFile)

proc paneLines(s: Session): seq[string] =
  ## Each line as `class|text|run styles` — the desktop capture's shape.
  for line in s.rt.app.buildPane.output:
    var cls = ""
    if line.located:
      cls = case line.severity
            of blsError: "build-line-error"
            of blsWarning: "build-line-warning"
            of blsInfo: "build-line-info"
            of blsNone: "build-output-line"
    elif line.isStdout: cls = "build-stdout"
    else: cls = "build-stderr"
    var styles: seq[string] = @[]
    for run in line.runs:
      styles.add cssOf(run.style)
    result.add cls & "|" & line.text & "|" & styles.join(";;")

proc desktopLines(phase: JsonNode): seq[string] =
  for l in phase["lines"]:
    var styles: seq[string] = @[]
    for st in l["runs"]:
      styles.add st["style"].getStr
    result.add l["class"].getStr & "|" & l["text"].getStr & "|" &
               styles.join(";;")

proc activeEditor(s: Session): tuple[path: string; line, col: int] =
  if s.rt.app.editSession.isNil: return ("", -1, -1)
  let buf = s.rt.app.editSession.activeBuffer()
  if buf.isNil: return ("", -1, -1)
  (buf.path, buf.caretLine, buf.caretColumn + 1)

proc lineRow(s: Session; index: int): (int, int) =
  ## Where output line `index` is drawn (scrolled into view first).
  s.rt.app.buildPane.scrollTop = index
  let (area, _, screen) = s.rt.buildPaneScreen()
  (screen.listTop + index - screen.first, area.col + 2)

suite "PLAT-56: the terminal's Build Output pane over real builds":

  test "a real failing build, then a passing one: lines, verdicts, history":
    let project = writePlat56Project()
    var s = open(project)
    let d = desktop()
    ck s.build(Plat56FailCommand) == bvFailed
    # THE LINES: the compiler's (its recorded transcript, read by the shared
    # reader — so the real `gcc` still writes exactly it), and the desktop's
    # for the same output, class for class, text for text, run for run.
    var want: seq[string] = @[]
    var r: BuildLineReader
    for raw in Plat56FailTranscript:
      want.add r.read(raw, false).line.text
    var got: seq[string] = @[]
    for line in s.rt.app.buildPane.output:
      got.add line.text
    checkpoint(got.join("\n"))
    ck got == want
    ck s.paneLines() == desktopLines(d["failing"])
    # THE VERDICT, the desktop's words; the status line's indicator.
    ck s.rt.app.buildPane.headline == d["failing"]["header"].getStr
    ck s.rt.app.buildPane.headline == "build failed (exit code 1)"
    ck s.rt.app.buildPane.status == bsFailed
    ck s.rt.app.buildStatus == "✗ Build failed: 2 errors, 1 warning"
    ck d["failing"]["status"].getStr == "Build failed: 2 errors, 1 warning"
    let frame = s.rt.shellScreenOf()
    ck frame.rows[^1].contains(s.rt.app.buildStatus)
    # The Problems pane read the same lines: its first error highlighted.
    ck s.rt.app.problems.rows.len == 4
    ck s.rt.app.problems.selected == 0
    # A PRESS ON A LOCATED LINE opens ITS file at ITS line and column (K35),
    # as the desktop's opened it.
    let (row, col) = s.lineRow(1)
    discard s.rt.press(row, col)
    ck s.activeEditor() == ("src/main.c", 5, 17)
    ck d["failing"]["press"]["opened"]["path"].getStr == "src/main.c"
    ck d["failing"]["press"]["opened"]["line"].getInt == 5
    ck s.rt.app.notification.contains("opened src/main.c:5:17")
    # A press on a line that names no location opens nothing.
    let (row0, col0) = s.lineRow(0)
    discard s.rt.press(row0, col0)
    ck s.activeEditor() == ("src/main.c", 5, 17)
    # THE VOCABULARY'S VIEW: the verdict and the lines.
    var list: ViewNode = nil
    var verdict = ""
    for n in walk(buildOutputPaneView(s.problems.problems.build).root):
      if n.kind == pkList: list = n
      if n.kind == pkText and n.id == "buildOutput.verdict": verdict = n.text
    ck verdict.startsWith("build failed (exit code 1)")
    ck not list.isNil and list.options.len == 15
    ck not list.isNil and not list.options[1].disabled and
       list.options[0].disabled
    ck paneBuildOutput in PaneVocabularyPanes
    ck paneBuildOutput notin PaneAcceptedExceptions

    # A PASSING BUILD: its verdict, its colours; the failing one in the
    # history.
    ck s.build(Plat56PassCommand) == bvSucceeded
    ck s.paneLines() == desktopLines(d["passing"])
    ck s.rt.app.buildPane.headline == "build succeeded"
    ck s.rt.app.buildStatus.startsWith("✓ Build succeeded in ")
    ck s.rt.app.buildPane.history.len == 2
    ck s.rt.app.buildPane.history[1].startsWith("#1 " & Plat56FailCommand &
                                                " — failed (exit code 1), ")
    ck d["history"]["labels"].len == 2
    ck d["history"]["labels"][1].getStr.startsWith("#1 " & Plat56FailCommand)
    # THE PICKER, pressed where it was drawn: the failing build shown again.
    var (area, model, screen) = s.rt.buildPaneScreen()
    checkpoint("build pane " & $area & " history " & $model.history.len &
               " headline " & model.headline)
    ck screen.controls.len == 5
    discard s.rt.press(screen.controlsRow, screen.controls[0].col)  # History
    (area, model, screen) = s.rt.buildPaneScreen()
    ck screen.menuRows == 2
    discard s.rt.press(screen.menuTop + 1, area.col + 3)
    ck s.rt.app.buildPane.headline == "build failed (exit code 1)"
    ck s.rt.app.buildPane.output.len == 15
    ck s.rt.app.buildPane.historyShown == 1
    # The status line still reports the CURRENT build.
    ck s.rt.app.buildStatus.startsWith("✓ Build succeeded")
    # RUN builds the shown command again: a new failing build, shown.
    (area, model, screen) = s.rt.buildPaneScreen()
    var runCol = -1
    for c in screen.controls:
      if c.control == bcRun: runCol = c.col
    s.held.b = nil
    discard s.rt.press(screen.controlsRow, runCol)
    ck not s.held.b.isNil
    if not s.held.b.isNil:
      ck s.held.b.session.command == Plat56FailCommand
      ck s.settle() == bvFailed
    ck s.rt.app.buildPane.historyShown == 0
    ck s.rt.app.buildPane.history.len == 3
    # FOLLOW toggles auto-scroll; CLEAR empties the current build, keeps the
    # history.
    (area, model, screen) = s.rt.buildPaneScreen()
    for c in screen.controls:
      if c.control == bcFollow:
        discard s.rt.press(screen.controlsRow, c.col)
    ck not s.rt.app.buildPane.follow
    (area, model, screen) = s.rt.buildPaneScreen()
    for c in screen.controls:
      if c.control == bcClear:
        discard s.rt.press(screen.controlsRow, c.col)
    ck s.rt.app.buildPane.status == bsIdle
    ck s.rt.app.buildPane.output.len == 0
    ck s.rt.app.buildPane.history.len == 3
    ck s.rt.app.buildStatus == ""
    s.problems.close()
    removeDir(project)

  test "the status line's indicator reveals Build Output":
    let project = writePlat56Project()
    var s = open(project)
    ck s.build(Plat56PassCommand) == bvSucceeded
    # Another tab of Build Output's box in front of it.
    discard s.rt.app.layoutBinding.dispatch(cmdActivateTab(paneTestResults))
    ck s.rt.buildPaneScreen().area.width == 0
    let rows = s.rt.shellScreenOf().rows
    let at = rows[^1].find(s.rt.app.buildStatus)
    ck at >= 0
    discard s.rt.press(Rows - 1, cellWidthOf(rows[^1][0 ..< at]) + 2)
    ck s.rt.buildPaneScreen().area.width > 0
    s.problems.close()
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
