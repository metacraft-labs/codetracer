## test_build_tasks_tui.nim — Tier 1: **build tasks, the task picker, the
## `:build` commands, the Build Output pane's reveal and a build's diagnostics
## in the Edit pane, on the terminal**, driven through the product's runtime
## over REAL builds of a real project.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.6 (build tasks), §3.8
## (auto-reveal, auto-dismiss), §3.9 (editor integration), §3.11
## (`Ctrl+Shift+B`), §3.12 (the omnibox commands), §5.2 (the project's task
## file).
##
##   * THE PICKER: `Ctrl+Shift+B` opens the omnibox on `:build: ` listing the
##     project's tasks (`.codetracer/build.yaml`, read from disk), the default
##     first, then the pane's words; `Enter` builds the default task — the real
##     `gcc` — into the pane;
##   * THE COMMANDS typed into the omnibox: `:build: <task>`, `:build`, an
##     unknown task named, `problemMatcher: none`, `:build: stop` cancelling a
##     running task, `:build: history` opening the pane's picker,
##     `:build: clear`, and the file's mistakes said when the picker opens;
##   * THE REVEAL with Build Output DOCKED to the bottom edge: a build reveals
##     it; a failed build reveals Problems; a clean success puts it back
##     two seconds later; a press in it keeps it;
##   * THE EDIT PANE'S MARKS after the failing build, `src/main.c` open: each
##     diagnostic's span underlined in its severity's colour, the most severe
##     icon in the gutter's pointer field, the messages on the pointer's hover
##     (`?1003` motion and the hover clock); a passing build clears them.
##
## No mocks: the real `gcc` on a real project, the product's runtime, runner
## (`host/build_runner`, the one the shipped loop starts) and hosts, wired as
## `main.nim`'s Edit loop wires them (`wireEditServices`).

import std/[os, strutils, monotimes, times, unittest]

import codetracer_embed

import ../app/runtime
import ../app/tui_app
import ../app/build_session
import ../app/edit_binding
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/edit_pane
import ../app/views/build_output
import ../host/problems_source
import ../host/build_output_source
import ../host/build_runner
from ../host/edit_host import readProjectFile, TuiHostError
import ../../viewmodel/tests/unit/build_fixtures/plat56_c_build
import ../../headless_app/layout_model
import ../../headless_app/layout_interaction

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 73

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 40
  BuildBudgetMs = 120_000
  CleanCommand = "gcc -fdiagnostics-color=always -c src/ok.c -o /dev/null"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc sgr(button, row, col: int; pressed: bool): string =
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc press(rt: TuiRuntime; row, col: int; button = 0) =
  discard rt.handleToken(sgr(button, row, col, true), 0)
  discard rt.handleToken(sgr(button, row, col, false), 0)

type
  BuildBox = ref object
    b: RunningBuild

  Session = object
    rt: TuiRuntime
    problems: ProblemsSource
    src: BuildOutputSource
    held: BuildBox
    project: string

proc taskFile(): string =
  "tasks:\n" &
  "  pass:\n    command: \"" & Plat56PassCommand & "\"\n    default: true\n" &
  "  fail:\n    command: \"" & Plat56FailCommand & "\"\n" &
  "  slow:\n    command: \"sleep 30\"\n" &
  "  quiet:\n    command: \"" & Plat56FailCommand & "\"\n" &
  "    problemMatcher: none\n" &
  "  clean:\n    command: \"" & CleanCommand & "\"\n"

proc open(project: string): Session =
  ## An Edit-mode window over `project`, wired as `main.nim`'s Edit loop wires
  ## it: the project reader, the runner (free commands and tasks), the
  ## Problems and Build Output sources.
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
  rt.editServices.projectDir = proc(): string = project
  rt.editServices.startTask = proc(cmd, dir, task,
                                   matcher: string): BuildStartResult =
    held.b = startBuild(bkBuild, cmd, (if dir.len > 0: dir else: project),
                        nowMonoMs())
    held.b.session.taskName = task
    held.b.session.problemMatcher = matcher
    rt.app.build = held.b.session
    BuildStartResult(ok: held.b.session.verdict == bvRunning)
  let opener = proc(path: string; line, col: int): string =
    rt.openWorkingFileAt(path, line, col)
  let problems = newProblemsSource(rt, opener)
  let src = newBuildOutputSource(rt, problems, opener,
    proc(command, noun: string): string =
      let started = rt.editServices.startBuild(bkBuild, command)
      if started.ok: "" else: started.message)
  Session(rt: rt, problems: problems, src: src, held: held, project: project)

proc tick(s: Session) =
  if not s.held.b.isNil:
    discard pollBuild(s.held.b, nowMonoMs())
  discard s.problems.tick(s.rt, nowMonoMs())
  discard s.src.tick(s.rt)

proc omnibox(s: Session; line: string) =
  discard s.rt.handleToken("\x10", 0)
  for ch in line:
    discard s.rt.handleToken($ch, 0)
  discard s.rt.handleToken("\r", 0)

proc settle(s: var Session): BuildVerdict =
  ## The loop's ticks until the build settles.
  let deadline = getMonoTime() + initDuration(milliseconds = BuildBudgetMs)
  while not s.held.b.isNil and s.held.b.session.verdict == bvRunning and
        getMonoTime() < deadline:
    s.tick()
    sleep(20)
  s.tick()
  if s.held.b.isNil: bvIdle else: s.held.b.session.verdict

proc run(s: var Session; line: string): BuildVerdict =
  s.held.b = nil
  s.omnibox(line)
  doAssert not s.held.b.isNil, line & " did not start a build: " &
    s.rt.app.notification
  s.settle()

proc taskName(s: Session): string = s.problems.problems.build.taskName.val

proc revealed(s: Session): string =
  ## The docked pane revealed over the arrangement now, "" for none.
  let b = s.rt.app.layoutBinding
  if b.interaction.kind == ikRevealingDock: $b.interaction.pane
  else: ""

let project = writePlat56Project("ct-build-tasks-tui-")
createDir(project / ".codetracer")
writeFile(project / ".codetracer" / "build.yaml", taskFile())

suite "build tasks on the terminal":

  test "Ctrl+Shift+B: the picker, the default first; Enter builds it":
    var s = open(project)
    s.held.b = nil
    discard s.rt.handleToken("\x1b[98;6u", 0)
    ck s.rt.app.omnibar.isOpen
    ck s.rt.app.omnibar.mode == omBuildTask
    ck s.rt.app.omnibar.resultLabels ==
      @["pass", "fail", "slow", "quiet", "clean", "stop", "clear", "history"]
    ck s.rt.app.notification == "build tasks: Enter runs pass"
    discard s.rt.handleToken("\r", 0)
    ck not s.rt.app.omnibar.isOpen
    ck not s.held.b.isNil
    ck s.settle() == bvSucceeded
    ck s.taskName == "pass"
    ck s.held.b.session.command == Plat56PassCommand
    ck s.rt.app.buildPane.headline == "build succeeded"
    # Typing in the picker narrows it; Enter runs the one chosen.
    s.held.b = nil
    discard s.rt.handleToken("\x1b[98;6u", 0)
    for ch in "fai": discard s.rt.handleToken($ch, 0)
    ck s.rt.app.omnibar.resultLabels[0] == "fail"
    discard s.rt.handleToken("\r", 0)
    ck s.settle() == bvFailed
    ck s.taskName == "fail"

  test "the omnibox commands: a task, the default, unknown, none, stop, history, clear":
    var s = open(project)
    ck s.run(":build: fail") == bvFailed
    ck s.rt.app.buildDiagnostics.len == 4
    ck s.rt.app.buildPane.headline == "build failed (exit code 1)"
    ck s.run(":build") == bvSucceeded
    ck s.taskName == "pass"
    s.omnibox(":build: nope")
    ck s.rt.app.notification == "no build task 'nope' (pass, fail, slow, quiet, clean)"
    # `problemMatcher: none`: the build's lines, no Problems row.
    ck s.run(":build: quiet") == bvFailed
    ck s.rt.app.buildPane.output.len == 15
    ck s.rt.app.buildDiagnostics.len == 0
    # A free command is still `:build <command>`.
    ck s.run(":build " & CleanCommand) == bvSucceeded
    ck s.taskName == ""
    # THE COMMAND LINE (`:`), the same grammar as the omnibox.
    s.held.b = nil
    discard s.rt.prompt.open(pkCommand)
    for ch in ":build: fail":
      discard s.rt.prompt.applyKey($ch, @[])
    discard s.rt.handleToken("\r", 0)
    ck not s.held.b.isNil
    ck s.settle() == bvFailed
    ck s.taskName == "fail"
    # STOP: a running task cancelled.
    s.held.b = nil
    s.omnibox(":build: slow")
    ck not s.held.b.isNil
    s.tick()
    ck s.held.b.session.verdict == bvRunning
    s.omnibox(":build: pass")
    ck s.rt.app.notification == BuildAlreadyRunningText
    s.omnibox(":build: stop")
    ck s.rt.app.notification.startsWith("cancelling build")
    ck s.settle() == bvCancelled
    ck s.rt.app.buildPane.headline == "build cancelled"
    s.omnibox(":build: stop")
    ck s.rt.app.notification == "nothing is running"
    # HISTORY: the pane's picker, open.
    s.omnibox(":build: history")
    ck s.rt.app.buildPane.historyOpen
    ck s.rt.app.buildPane.history.len >= 4
    # CLEAR.
    s.omnibox(":build: clear")
    ck s.rt.app.buildPane.status == bsIdle

  test "the file's mistakes, said when the picker opens; no file, no task":
    let other = writePlat56Project("ct-build-tasks-bad-")
    createDir(other / ".codetracer")
    writeFile(other / ".codetracer" / "build.yaml",
              "tasks:\n  a:\n    comand: make\n")
    var s = open(other)
    discard s.rt.handleToken("\x1b[98;6u", 0)
    ck s.rt.app.notification.startsWith(".codetracer/build.yaml:3: unknown key 'comand'")
    ck s.rt.app.omnibar.resultLabels == @["stop", "clear", "history"]
    discard s.rt.handleToken("\x1b", 0)
    removeFile(other / ".codetracer" / "build.yaml")
    s.omnibox(":build")
    ck s.rt.app.notification == NoBuildTasksText
    removeDir(other)

  test "the reveal: docked Build Output shown by a build, put away after a clean one":
    var s = open(project)
    let b = s.rt.app.layoutBinding
    discard b.dispatch(cmdDock(paneBuildOutput, leBottom))
    ck b.layout.dockedIndex(paneBuildOutput) >= 0
    ck b.layout.dockedIndex(paneProblems) >= 0
    ck s.revealed == ""
    # A build starts: revealed.
    s.held.b = nil
    s.omnibox(":build: fail")
    s.tick()
    ck s.revealed == $paneBuildOutput
    # It fails: Problems revealed.
    ck s.settle() == bvFailed
    ck s.revealed == $paneProblems
    # A clean success: Build Output revealed, and put away two seconds on.
    ck s.run(":build: clean") == bvSucceeded
    ck s.revealed == $paneBuildOutput
    sleep(500)
    s.tick()
    ck s.revealed == $paneBuildOutput
    sleep(1700)
    s.tick()
    ck s.revealed == ""
    # A success with a WARNING stays.
    ck s.run(":build: pass") == bvSucceeded
    sleep(2200)
    s.tick()
    ck s.revealed == $paneBuildOutput
    # The wheel in the revealed pane keeps it after a clean success.
    ck s.run(":build: clean") == bvSucceeded
    ck s.revealed == $paneBuildOutput
    let (area, _, _) = s.rt.buildPaneScreen()
    ck area.width > 0
    discard s.rt.handleToken(sgr(64, area.row + 2, area.col + 2, true), 0)
    s.tick()
    sleep(2200)
    s.tick()
    ck s.revealed == $paneBuildOutput

  test "the Edit pane: underlined spans, gutter icons, the hover; cleared by a new build":
    var s = open(project)
    ck s.run(":build: fail") == bvFailed
    s.omnibox(":e src/main.c")
    let m = s.rt.app.editPaneModel()
    ck m.path == "src/main.c"
    var spans: seq[string]
    for d in m.diagnostics:
      spans.add $d.line & ":" & $d.fromColumn & "-" & $d.toColumn
    ck spans == @["5:15-16", "4:8-14", "10:11-25", "10:11-25"]
    # Painted: line 4's `unused` underlined in the warning role, its gutter's
    # pointer field `⚠`; line 10's `undefined_name` in the error role, `●`.
    let area = CellArea(col: 0, row: 0, width: 80, height: 16)
    var g = newStyledGrid(80, 16)
    let screen = paintEditPane(g, area, m)
    let gw = screen.gutterWidth
    let row4 = area.row + 1 + (4 - m.viewportTop)
    let row10 = area.row + 1 + (10 - m.viewportTop)
    let pointer = area.col + 1 + gutterNumberWidth(m.lineCount) + 1 + 1
    ck g.rowText(row4)[pointer .. pointer + 2] == "⚠"
    ck g.rowText(row10).contains("●")
    let u = g.styleAt(row4, area.col + gw + 8)
    ck u.underline and u.role == srChromeNotification
    ck not g.styleAt(row4, area.col + gw + 7).underline
    ck not g.styleAt(row4, area.col + gw + 14).underline
    let e = g.styleAt(row10, area.col + gw + 11)
    ck e.underline and e.role == srChromeError
    ck g.styleAt(row10, area.col + gw + 24).underline
    ck not g.styleAt(row10, area.col + gw + 25).underline
    # THE HOVER: the pointer resting on `undefined_name` shows its messages.
    let ed = s.rt.paintedAreaOf(paneEditor)
    ck ed.width > 0
    let hoverRow = ed.row + 1 + (10 - m.viewportTop)
    let hoverCol = ed.col + paneGutterWidth(m) + 13
    discard s.rt.handleToken(sgr(35, hoverRow, hoverCol, true), 1000)
    discard s.rt.tickCellHover(1700)
    let tip = s.rt.app.cellTooltip.lines.join("\n")
    checkpoint(tip)
    ck tip.contains("error: ‘undefined_name’ undeclared")
    ck tip.contains("note: each undeclared identifier")
    # Off the span: no tooltip.
    discard s.rt.handleToken(sgr(35, hoverRow, ed.col + paneGutterWidth(m) + 2,
                                 true), 2000)
    discard s.rt.tickCellHover(2700)
    ck s.rt.app.cellTooltip.lines.len == 0
    # A NEW BUILD CLEARS THE MARKS (its diagnostics are another file's).
    ck s.run(":build: pass") == bvSucceeded
    ck s.rt.app.editPaneModel().diagnostics.len == 0

removeDir(project)

suite "the count":
  test "every assertion ran":
    checkpoint("asserted: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
