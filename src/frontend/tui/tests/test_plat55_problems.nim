## test_plat55_problems.nim — PLAT-55, Tier 1: **the terminal's Problems
## pane**, painted from its value and driven through the product's runtime
## over a REAL build of a real crate.
##
## Spec: `Planned-Features/Build-Output-Pane.md` §3.3, §3.9;
## `Planned-Features/Edit-Mode-Toolbar.md` §11 (EMT-D20, D21, D22, A36).
##
##   * THE PAINTER at every width from 24 to 160 cells: the counts on the
##     left, the four buttons on the right while they fit (the active one
##     marked); each row's icon in its severity's colour, path, location and
##     message, the location never cut and the path and message cut with `…`;
##     file headers when grouping; the empty state; the selected row on the
##     selection surface; the scrollbar exactly when the list overflows — and
##     every part hit-tested by the arithmetic that drew it;
##   * THE RUNTIME OVER A REAL BUILD (`host/problems_source`, the window's
##     `ErrorsVM` fed by `host/build_problems` from the runner the shipped
##     loop uses): `:build nargo compile` typed into the omnibox of an Edit-
##     mode session over the PLAT-55 crate; the pane lists the rows the
##     compiler reported — EQUAL to the rows the desktop listed for the same
##     build (`src/tests/visual/answers/plat55-problems.electron.json`), its
##     first error highlighted and nothing opened (EMT-D21); `F8` reveals the
##     docked pane without focusing it and steps to the next error, opening
##     its file at its line, wrapping and announcing; a press on a row opens
##     ITS file at ITS line in the editor and focuses the editor (K35); the
##     filter and Group by File buttons pressed on the cells they were drawn
##     in; the pane docked open from its footer label and pressed takes the
##     list keys (Up / Down / Home / End move, Enter opens); a row whose
##     file is gone says so and stays listed (EMT-D20); a build that passes
##     clears the list (EMT-D22.7);
##   * THE VOCABULARY'S VIEW of the same ViewModel (`problemsPaneView`): a
##     `Table` of the same cells, and the pane no longer an accepted
##     exception.
##
## No mocks: the real `nargo` on a real crate, the product's runtime, runner
## and hosts. The editor the rows open in is the product's `EditSession`, its
## file read by the shipped `edit_host.readProjectFile`.

import std/[json, os, strutils, monotimes, times, unittest]

import codetracer_embed

import ../app/runtime
import ../app/tui_app
import ../app/build_session
import ../app/edit_binding
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/problems_pane
import ../host/problems_source
import ../host/build_runner
from ../host/edit_host import readProjectFile, TuiHostError
import ./fixtures/plat55_noir_build
import ../../../common/view_vocabulary
from ../../view_vocabulary/pane_views import problemsPaneView,
  ProblemsColumns, PaneAcceptedExceptions, PaneVocabularyPanes

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 64

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 30
  BuildBudgetMs = 120_000
  AnswersFile = currentSourcePath().parentDir() / ".." / ".." / ".." /
                "tests" / "visual" / "answers" / "plat55-problems.electron.json"

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

proc sampleModel(): ProblemsPaneModel =
  ## The pane's value over the crate's rows — through the ViewModel and
  ## `paneModelOf`, as the host fills it.
  var vm: ErrorsVM
  createRoot proc(dispose: proc()) =
    vm = createErrorsVM(nil)
  var rows: seq[BuildProblemLine] = @[]
  for e in Plat55Expected:
    rows.add BuildProblemLine(
      severity: (if e.severity == "error": blsError else: blsWarning),
      path: e.path, line: e.line, col: e.col, message: e.message)
  vm.setProblems(rows)
  vm.selectProblemIndex(1)
  paneModelOf(vm)

suite "PLAT-55: the terminal's Problems painter":

  test "every width: the header, the columns, the cut and the hit-tests":
    var bad = 0
    for width in 24 .. 160:
      let m = sampleModel()
      let area = CellArea(col: 2, row: 1, width: width, height: 8)
      var g = newStyledGrid(area.col + width, area.row + area.height)
      let s = paintProblems(g, area, m)
      let header = g.rowText(area.row)
      if not header.startsWith(spaces(area.col) & m.errorBadge):
        inc bad; checkpoint("counts at " & $width & ": " & header)
      # The buttons, when drawn, are the four in order, at the right edge.
      if s.buttons.len > 0:
        if s.buttons.len != 4 or
           s.buttons[^1].col + s.buttons[^1].width != area.col + width:
          inc bad; checkpoint("buttons at " & $width)
        for i, b in s.buttons:
          let t = m.problemsTargetAt(s, area, area.row, b.col)
          let want = if i < 3: pbFilter else: pbGroup
          if t.kind != want or (i < 3 and t.index != i):
            inc bad; checkpoint("button hit " & $i & " at " & $width)
      elif width >= 60:
        inc bad; checkpoint("no buttons at " & $width)
      # Each row: its icon first, its location whole, its hit its index.
      for k in 0 ..< 3:
        let row = s.listTop + k
        let text = g.rowText(row)
        if not text.contains(m.rows[k].icon):
          inc bad; checkpoint("icon " & $k & " at " & $width)
        if s.fit.mode != fmScroll and not text.contains(m.rows[k].location):
          inc bad; checkpoint("location " & $k & " at " & $width & ": " & text)
        let t = m.problemsTargetAt(s, area, row, area.col + 2)
        if t.kind != pbRow or t.index != m.rows[k].index:
          inc bad; checkpoint("row hit " & $k & " at " & $width)
        if g.styleAt(row, area.col).role != toneStyle(m.rows[k].tone).role:
          inc bad; checkpoint("tone " & $k & " at " & $width)
      if s.fit.mode != fmScroll and
         s.fit.widths[2] < cellWidthOf(m.rows[0].location):
        inc bad; checkpoint("location cut at " & $width)
    ck bad == 0

  test "the words, the colours, the selection, the cut":
    let m = sampleModel()
    let area = CellArea(col: 0, row: 0, width: 120, height: 6)
    var g = newStyledGrid(120, 6)
    let s = paintProblems(g, area, m)
    ck m.errorBadge == "● 2" and m.warningBadge == "⚠ 1" and
       m.totalBadge == "Total: 3"
    ck m.filters == @["All", "Errors", "Warnings"]
    ck m.groupLabel == "Group by File"
    ck g.rowText(0).contains("● 2  ⚠ 1  Total: 3")
    ck s.painted.len == 3
    ck s.painted[0].contains("src/util.nr") and s.painted[0].contains("2:9") and
       s.painted[0].contains("unused variable unused")
    ck g.styleAt(s.listTop, 0).role == srChromeNotification   # ⚠
    ck g.styleAt(s.listTop + 1, 0).role == srChromeError      # ●
    ck g.styleAt(s.listTop + 1, 10).surface == srSurfaceSelection   # selected
    ck g.styleAt(s.listTop, 10).surface != srSurfaceSelection
    ck s.trackCol == -1
    # Narrow: the message and the path cut with `…`, the location whole.
    var gn = newStyledGrid(40, 6)
    let sn = paintProblems(gn, CellArea(col: 0, row: 0, width: 40, height: 6), m)
    ck sn.painted[1].contains("3:22")
    ck sn.painted[1].contains("…")

  test "grouped, empty, overflowing":
    var m = sampleModel()
    m.lines = @[ProblemsPaneLine(kind: plFileHeader, row: -1,
                                 text: "src/util.nr (2)"),
                ProblemsPaneLine(kind: plRow, row: 0),
                ProblemsPaneLine(kind: plRow, row: 1),
                ProblemsPaneLine(kind: plFileHeader, row: -1,
                                 text: "src/main.nr (1)"),
                ProblemsPaneLine(kind: plRow, row: 2)]
    let area = CellArea(col: 0, row: 0, width: 100, height: 4)
    var g = newStyledGrid(100, 4)
    let s = paintProblems(g, area, m)
    ck s.painted[0] == "src/util.nr (2)"
    ck m.problemsTargetAt(s, area, s.listTop, 3).kind == pbHeader
    ck s.trackCol == 99                         # five lines in three rows
    ck m.problemsTargetAt(s, area, s.listTop, 99).kind == pbTrack
    var scrolled = m
    scrolled.scrollTop = 2
    var g2 = newStyledGrid(100, 4)
    let s2 = paintProblems(g2, area, scrolled)
    ck s2.painted[0] == s.painted[2]
    var empty = m
    empty.rows = @[]
    empty.lines = @[ProblemsPaneLine(kind: plEmpty, row: -1,
                                     text: "No problems detected.")]
    var g3 = newStyledGrid(100, 4)
    let s3 = paintProblems(g3, area, empty)
    ck s3.painted == @["No problems detected."]

# ---------------------------------------------------------------------------
# The runtime over a real build
# ---------------------------------------------------------------------------

type
  BuildBox = ref object
    b: RunningBuild

  Session = object
    rt: TuiRuntime
    src: ProblemsSource
    held: BuildBox
      ## The runner's handle `:build` started (`main.nim`'s `state.running`).
    project: string

proc open(project: string): Session =
  ## An Edit-mode window over `project`, wired as `main.nim`'s edit loop
  ## wires it: the project reader, the build runner, the Problems source.
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
  let src = newProblemsSource(rt, proc(path: string; line, col: int): string =
    rt.openWorkingFileAt(path, line, col))
  Session(rt: rt, src: src, held: held, project: project)

proc omnibox(s: Session; line: string) =
  ## `line` typed into the omnibox (`Ctrl+P`) and accepted.
  discard s.rt.handleToken("\x10", 0)
  for ch in line:
    discard s.rt.handleToken($ch, 0)
  discard s.rt.handleToken("\r", 0)

proc build(s: var Session; command = Plat55BuildCommand): BuildVerdict =
  ## `:build <command>` through the omnibox, then the loop's ticks until it
  ## settles: the runner polled, the pane following.
  s.held.b = nil
  s.omnibox(":build " & command)
  doAssert not s.held.b.isNil, "`:build` did not start a build: " &
    s.rt.app.notification
  let deadline = getMonoTime() + initDuration(milliseconds = BuildBudgetMs)
  while s.held.b.session.verdict == bvRunning and getMonoTime() < deadline:
    discard pollBuild(s.held.b, nowMonoMs())
    discard s.src.tick(s.rt)
    sleep(20)
  discard pollBuild(s.held.b, nowMonoMs())
  discard s.src.tick(s.rt)
  s.held.b.session.verdict

proc desktopRows(): seq[string] =
  ## The desktop's rows for the same build, as `severity path:location
  ## message` (the Electron capture).
  doAssert fileExists(AnswersFile), "the desktop's capture is missing: " &
    AnswersFile & " (run `just plat55-capture-electron`)"
  for r in parseFile(AnswersFile)["after"]["rows"]:
    result.add r["severity"].getStr & " " & r["path"].getStr & ":" &
               r["location"].getStr & " " & r["message"].getStr

proc findOnScreen(s: Session; needle: string; fromBottom = false): (int, int) =
  ## Where `needle` is drawn — the first row from the top, or from the bottom
  ## (the footer strip's label, under a revealed pane's own title).
  let rows = s.rt.shellScreenOf().rows
  for k in 0 ..< rows.len:
    let r = if fromBottom: rows.high - k else: k
    let line = rows[r]
    let c = line.find(needle)
    if c >= 0:
      return (r, cellWidthOf(line[0 ..< c]))
  (-1, -1)

proc paneRows(s: Session): seq[string] =
  let m = s.rt.app.problems
  for line in m.lines:
    if line.kind == plRow:
      let r = m.rows[line.row]
      result.add (case r.tone
                  of ptError: "error"
                  of ptWarning: "warning"
                  of ptInfo: "info") & " " & r.path & ":" & r.location & " " &
                 r.message

proc activeEditor(s: Session): tuple[path: string; line, col: int] =
  if s.rt.app.editSession.isNil: return ("", -1, -1)
  let buf = s.rt.app.editSession.activeBuffer()
  if buf.isNil: return ("", -1, -1)
  (buf.path, buf.caretLine, buf.caretColumn + 1)

suite "PLAT-55: the terminal's Problems pane over a real build":

  test "a real failing build: rows, highlight, F8, a press, buttons, keys":
    let project = writePlat55Project()
    var s = open(project)
    ck s.build() == bvFailed
    # THE ROWS, equal to the compiler's and to the desktop's.
    var want: seq[string] = @[]
    for e in Plat55Expected:
      want.add e.severity & " " & e.path & ":" & $e.line & ":" & $e.col &
               " " & e.message
    ck s.paneRows() == want
    ck s.paneRows() == desktopRows()
    ck s.rt.app.problems.errorBadge == "● 2"
    ck s.rt.app.problems.warningBadge == "⚠ 1"
    # EMT-D21: the first error highlighted, nothing opened, no focus moved —
    # the row the desktop's panel highlights for the same build.
    ck s.rt.app.problems.selected == 1
    ck parseFile(AnswersFile)["after"]["rows"][1]["selected"].getBool
    ck s.activeEditor().path == ""
    # THE VOCABULARY'S VIEW: a `Table` of the same cells.
    var table: ViewNode = nil
    for n in walk(problemsPaneView(s.src.problems.vm).root):
      if n.kind == pkTable: table = n
    ck not table.isNil and table.columns == ProblemsColumns
    ck not table.isNil and table.rows.len == 3 and
       table.rows[1] == @["●", "src/util.nr", "3:22",
                          "Expected type bool, found type Field"]
    ck paneProblems in PaneVocabularyPanes
    ck paneProblems notin PaneAcceptedExceptions
    # F8 — `problems.next` in Edit mode: the HIGHLIGHTED error, where the
    # first `next error` after a failed build lands (EMT-D21), opened at its
    # line, announced; the docked pane revealed. The second steps on.
    discard s.rt.handleToken("\x1b[19~", 0)
    ck s.rt.app.problems.selected == 1
    ck s.rt.app.problems.status == "error 1 of 2"
    ck s.activeEditor() == ("src/util.nr", 3, 22)
    discard s.rt.handleToken("\x1b[19~", 0)
    ck s.rt.app.problems.selected == 2
    ck s.rt.app.problems.status == "error 2 of 2"
    ck s.activeEditor() == ("src/main.nr", 5, 19)
    let (area, screen) = s.rt.problemsPaneScreen()
    ck area.width > 0 and screen.listRows > 0
    # F8 again wraps to the first error.
    discard s.rt.handleToken("\x1b[19~", 0)
    ck s.rt.app.problems.status == "wrapped to first error"
    ck s.activeEditor() == ("src/util.nr", 3, 22)
    # A PRESS ON THE WARNING'S ROW opens ITS file at ITS line (K35), the
    # editor focused.
    let (a1, s1) = s.rt.problemsPaneScreen()
    ck a1.width > 0
    let warnRow = s1.listTop + s.rt.app.problems.lineOfIndex(0) -
                  s.rt.app.problems.scrollTop
    discard s.rt.press(warnRow, a1.col + 4)
    ck s.rt.app.problems.selected == 0
    ck s.activeEditor() == ("src/util.nr", 2, 9)
    ck s.rt.focus.focusedPane()[1] == paneEditor
    let opened = s.rt.app.editSession.activeBuffer().text
    ck opened.lineOf(2) == "    let unused = 1;"
    # THE BUTTONS, pressed on the cells they were drawn in.
    let (a2, s2) = s.rt.problemsPaneScreen()
    ck s2.buttons.len == 4
    if s2.buttons.len == 4:
      discard s.rt.press(a2.row, s2.buttons[1].col)          # Errors
      ck s.paneRows() == want[1 .. 2]
      let (a3, s3) = s.rt.problemsPaneScreen()
      discard s.rt.press(a3.row, s3.buttons[0].col)          # All
      ck s.paneRows() == want
      let (a4, s4) = s.rt.problemsPaneScreen()
      discard s.rt.press(a4.row, s4.buttons[3].col)          # Group by File
      var headers: seq[string] = @[]
      for line in s.rt.app.problems.lines:
        if line.kind == plFileHeader: headers.add line.text
      ck headers == @["src/util.nr (2)", "src/main.nr (1)"]
      let (a5, s5) = s.rt.problemsPaneScreen()
      discard s.rt.press(a5.row, s5.buttons[3].col)
      ck s.rt.app.problems.grouped == false
    # THE KEYS, the pane focused.
    # THE KEYS: the pane docked open (a press on its footer label), then a
    # press on its header gives it the list keys (a docked pane is not in
    # the focus ring; the desktop's docked panel takes keys after a click).
    let (lr, lc) = s.findOnScreen("PROBLEMS", fromBottom = true)
    ck lr >= 0
    discard s.rt.press(lr, lc + 1)
    ck s.rt.app.layoutBinding.layout.docked[
      s.rt.app.layoutBinding.layout.dockedIndex(paneProblems)].open
    let (ak, _) = s.rt.problemsPaneScreen()
    discard s.rt.press(ak.row, ak.col + 1)     # the counts: not a control
    ck s.rt.hasDockKeys and s.rt.dockKeys == paneProblems
    discard s.rt.handleToken("\x1b[F", 0)    # End
    ck s.rt.app.problems.selected == 2
    discard s.rt.handleToken("\x1b[A", 0)    # Up
    ck s.rt.app.problems.selected == 1
    discard s.rt.handleToken("\r", 0)        # Enter opens it
    ck s.activeEditor() == ("src/util.nr", 3, 22)
    # EMT-D20: a row whose file is gone says so and stays listed.
    removeFile(project / "src" / "main.nr")
    let (a6, s6) = s.rt.problemsPaneScreen()
    let mainRow = s6.listTop + s.rt.app.problems.lineOfIndex(2) -
                  s.rt.app.problems.scrollTop
    discard s.rt.press(mainRow, a6.col + 4)
    ck s.rt.app.notification.contains("src/main.nr was not found")
    ck s.paneRows().len == 3
    ck s.activeEditor().path == "src/util.nr"
    # EMT-D22.7: a build that passes clears the list.
    writeFile(project / "src" / "main.nr",
              "fn main(x: Field, y: pub Field) {\n    assert(x != y);\n}\n")
    writeFile(project / "src" / "util.nr", "")
    ck s.build() == bvSucceeded
    ck s.paneRows().len == 0
    ck s.rt.app.problems.lines.len == 1 and
       s.rt.app.problems.lines[0].text == "No problems detected."
    ck s.rt.app.problems.selected == -1
    s.src.close()
    removeDir(project)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
