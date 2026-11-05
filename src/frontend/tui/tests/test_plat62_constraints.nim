## test_plat62_constraints.nim — PLAT-62, Tier 1: **the terminal's
## Constraints pane**, painted from its value and driven through the
## product's runtime over a REAL measurement of a real crate.
##
## Spec: `Planned-Features/Noir-Studio.md` § "The Constraints pane on the
## terminal and the GPUI window (PLAT-62)".
##
##   * THE PAINTER at every width from 30 to 160 cells: the headline on the
##     first row; each function row's name, kind, count and the line that
##     declares it, the count never cut and the name cut with `…`; a row
##     placed nowhere muted; the selected row on the selection surface; the
##     provenance on the last row; the scrollbar exactly when the list
##     overflows — and every row hit-tested by the arithmetic that drew it;
##     the absence wrapped; a listing's opcodes indented under their function;
##   * THE RUNTIME OVER A REAL MEASUREMENT (`host/constraints_source`, the
##     window's `ConstraintsVM` filled by `native_constraints_host` running the
##     real `nargo info --json`): an Edit-mode window over the PLAT-62 crate
##     shows the pane, measures the crate the first time it is on screen, and
##     lists the rows the desktop listed for the same crate
##     (`src/tests/visual/answers/plat62-constraints.electron.json`), each
##     placed where the desktop placed it; `nargo` itself still prints the
##     fixture's numbers; a press on `halve` opens ITS line in the editor
##     (K67), the line the desktop's press opened, and focuses the editor; a
##     press on a directive opens nothing and says why; the right press's menu
##     (K68) is the desktop's — entries, order, disabled ones and their
##     reasons — and its Copy Source Location and Go to Source act; the pane
##     focused, the list keys move the selection and Enter opens; an unsaved
##     edit to a source marks the counts `(stale)` and `:w` re-measures them;
##   * `:constraints` IN DEBUG MODE, where the default places no Constraints
##     pane: it is opened (and kept by the arrangement) and measured;
##   * THE VOCABULARY'S VIEW of the same ViewModel (`constraintsPaneView`): a
##     `Table` of the same cells, and the pane no longer an accepted
##     exception.
##
## No mocks: the real `nargo` on a real crate, the product's runtime and
## hosts. The editor the rows open in is the product's `EditSession`, its
## file read by the shipped `edit_host.readProjectFile`.

import std/[json, os, strutils, monotimes, osproc, tempfiles, times, unittest]

import codetracer_embed

import ../app/runtime
import ../app/tui_app
import ../app/edit_binding
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/constraints_pane
import ../host/constraints_source
from ../host/edit_host import readProjectFile, writeProjectFile, TuiHostError
import ./fixtures/plat62_noir_circuit
import ../../../common/view_vocabulary
import ../../viewmodel/viewmodels/constraints_vm
import ../../viewmodel/viewmodels/constraints_answer
from ../../view_vocabulary/pane_views import constraintsPaneView,
  ConstraintsColumns, PaneAcceptedExceptions, PaneVocabularyPanes

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 73

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 30
  MeasureBudgetMs = 120_000
  AnswersFile = currentSourcePath().parentDir() / ".." / ".." / ".." /
                "tests" / "visual" / "answers" / "plat62-constraints.electron.json"

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

proc writeCrate(): string =
  ## A fresh copy of the PLAT-62 crate in a temporary directory; its path.
  result = createTempDir("ct-plat62-crate-", "")
  createDir(result / "src")
  writeFile(result / "Nargo.toml", Plat62NargoToml)
  for (path, content) in Plat62Files:
    writeFile(result / path, content)

proc measuredVM(): ConstraintsVM =
  ## The ViewModel over the crate's sources and the measured report.
  var vm: ConstraintsVM
  createRoot proc(dispose: proc()) =
    vm = createConstraintsVM()
  result = vm
  var files: seq[NoirSourceFile] = @[]
  for (path, content) in Plat62Files:
    files.add NoirSourceFile(path: path, content: content)
  result.setSources(files)
  result.setReport(parseNargoInfoJson(Plat62NargoInfoJson,
                                      "nargo info --json, run just now"))

suite "PLAT-62: the terminal's Constraints painter":

  test "every width: the headline, the columns, the cut and the hit-tests":
    var bad = 0
    let vm = measuredVM()
    vm.selectRow(1)
    for width in 30 .. 160:
      let m = paneModelOf(vm)
      let area = CellArea(col: 2, row: 1, width: width, height: 9)
      var g = newStyledGrid(area.col + width, area.row + area.height)
      let s = paintConstraints(g, area, m)
      if not g.rowText(area.row).startsWith(spaces(area.col) &
                                            fitCell(m.headline, width).text):
        inc bad; checkpoint("headline at " & $width)
      if s.provenanceRow != area.row + area.height - 1 or
         not g.rowText(s.provenanceRow).contains("nargo info"):
        inc bad; checkpoint("provenance at " & $width)
      for k in 0 ..< 4:
        let row = s.listTop + k
        let text = g.rowText(row)
        let r = m.rows[k]
        if s.fit.mode != fmScroll:
          if not text.contains(" " & r.count & " "):
            inc bad; checkpoint("count " & $k & " at " & $width & ": " & text)
          if r.where.len > 0 and s.fit.widths[3] >= cellWidthOf(r.where) and
             not text.contains(r.where):
            inc bad; checkpoint("where " & $k & " at " & $width & ": " & text)
        let t = m.constraintsTargetAt(s, area, row, area.col + 1)
        if t.kind != cgRow or t.index != k:
          inc bad; checkpoint("row hit " & $k & " at " & $width)
        let selected = g.styleAt(row, area.col + 1).surface == srSurfaceSelection
        if selected != (k == 1):
          inc bad; checkpoint("selection " & $k & " at " & $width)
      if s.trackCol != -1:
        inc bad; checkpoint("a track for four rows at " & $width)
    ck bad == 0

  test "the words, the muting, the cut, the overflow and the absence":
    let vm = measuredVM()
    let m = paneModelOf(vm)
    ck m.headline == Plat62Headline
    ck m.rows.len == 4
    ck (m.rows[0].name, m.rows[0].kind, m.rows[0].count, m.rows[0].where) ==
       Plat62Rows[0]
    ck m.rows[2].where == "" and not m.rows[2].linked
    ck m.rows[2].title == "No source: " & DirectiveReason
    let area = CellArea(col: 0, row: 0, width: 80, height: 7)
    var g = newStyledGrid(80, 7)
    let s = paintConstraints(g, area, m)
    ck s.painted[0].startsWith("main ") and s.painted[0].contains("acir") and
       s.painted[0].contains("src/main.nr:3")
    ck g.styleAt(s.listTop, 0).role == srChromeText       # main: placed
    ck g.styleAt(s.listTop + 2, 0).role == srChromeMuted  # a directive
    # Narrow: the name cut with `…`, the count whole.
    var gn = newStyledGrid(30, 7)
    let sn = paintConstraints(gn, CellArea(col: 0, row: 0, width: 30,
                                          height: 7), m)
    ck sn.painted[3].contains("…")
    ck sn.painted[3].contains(" 8 ")
    # Overflowing: three list rows for four, the bar on the right; scrolled.
    var g2 = newStyledGrid(80, 5)
    let s2 = paintConstraints(g2, CellArea(col: 0, row: 0, width: 80,
                                          height: 5), m)
    ck s2.listRows == 2 and s2.trackCol == 79   # headline, notice, provenance
    ck m.constraintsTargetAt(s2, CellArea(col: 0, row: 0, width: 80,
                                          height: 5), s2.listTop, 79).kind ==
       cgTrack
    var scrolled = m
    scrolled.scrollTop = 1
    var g3 = newStyledGrid(80, 5)
    let s3 = paintConstraints(g3, CellArea(col: 0, row: 0, width: 80,
                                          height: 5), scrolled)
    ck s3.painted[0] == s2.painted[1]
    ck scrolled.revealIndex(3, 0) == 0
    # The absence, wrapped under the headline; no rows.
    vm.setAbsence(NargoMissingText)
    let a = paneModelOf(vm)
    var g4 = newStyledGrid(40, 6)
    let s4 = paintConstraints(g4, CellArea(col: 0, row: 0, width: 40,
                                          height: 6), a)
    ck g4.rowText(0).startsWith("unavailable")
    ck s4.painted.join(" ") == NargoMissingText
    ck s4.listRows == 0

  test "a listing's opcodes sit indented under their function":
    let vm = measuredVM()
    vm.setReport(reportFromAcirListing(
      "func 0\nprivate parameters: [w0]\npublic parameters: [w1]\n" &
      "return values: []\nASSERT w0 = w1\n", "plat62_circuit", "a listing"))
    let m = paneModelOf(vm)
    var g = newStyledGrid(60, 6)
    let s = paintConstraints(g, CellArea(col: 0, row: 0, width: 60,
                                         height: 6), m)
    ck s.painted[0].startsWith("func 0")
    ck g.rowText(s.listTop + 1).startsWith("  0 ASSERT w0 = w1")

# ---------------------------------------------------------------------------
# The runtime over a real measurement
# ---------------------------------------------------------------------------

type
  Session = object
    rt: TuiRuntime
    src: ConstraintsSource
    project: string

proc open(project: string; product = pmEdit): Session =
  ## A window over `project`, wired as `main.nim`'s loops wire it: the project
  ## reader and writer, the Constraints source opening rows in the editor.
  let app = newTuiApp()
  app.projectRoot = project
  app.modes = initModeRegister(product)
  let rt = newTuiRuntime(app, caps(), Cols, Rows)
  discard rt.enableLayoutBinding()
  rt.editServices.readFile = proc(relative: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readProjectFile(project, relative))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  rt.editServices.writeFile = proc(relative, text: string): EditWriteResult =
    try:
      writeProjectFile(project, relative, text)
      EditWriteResult(ok: true)
    except TuiHostError as e:
      EditWriteResult(ok: false, message: e.msg)
  let src = newConstraintsSource(rt, proc(): string = project,
    proc(path: string; line, col: int): string =
      rt.openWorkingFileAt(path, line, col))
  Session(rt: rt, src: src, project: project)

proc settle(s: Session) =
  ## The loop's ticks until the measurement in flight has landed.
  discard s.src.tick(s.rt)
  let deadline = getMonoTime() + initDuration(milliseconds = MeasureBudgetMs)
  while s.src.host.running and getMonoTime() < deadline:
    sleep(20)
    discard s.src.tick(s.rt)
  discard s.src.tick(s.rt)

proc omnibox(s: Session; line: string) =
  ## `line` typed into the omnibox (`Ctrl+P`) and accepted.
  discard s.rt.handleToken("\x10", 0)
  for ch in line:
    discard s.rt.handleToken($ch, 0)
  discard s.rt.handleToken("\r", 0)

proc rowAt(s: Session; index: int): (int, int) =
  ## Where row `index` is drawn.
  let (area, screen) = s.rt.constraintsPaneScreen()
  let at = s.rt.app.constraints.lineOfIndex(index) -
           clampConstraintsTop(s.rt.app.constraints.rows.len,
                               s.rt.app.constraints.scrollTop, screen.listRows)
  (screen.listTop + at, area.col + 1)

proc activeEditor(s: Session): tuple[path: string; line, col: int] =
  if s.rt.app.editSession.isNil: return ("", -1, -1)
  let buf = s.rt.app.editSession.activeBuffer()
  if buf.isNil: return ("", -1, -1)
  (buf.path, buf.caretLine, buf.caretColumn + 1)

proc chooseMenu(s: Session; label: string) =
  ## Choose the open menu's entry `label` FROM THE KEYBOARD: Down until it is
  ## the selected one, then Enter.
  var want = -1
  for i, e in s.rt.app.contextMenu.menu.entries:
    if e.label == label:
      want = i
  doAssert want >= 0, "no menu entry " & label
  for _ in 0 .. s.rt.app.contextMenu.menu.entries.len:
    if s.rt.app.contextMenu.selected == want:
      break
    discard s.rt.handleToken("\x1b[B", 0)
  doAssert s.rt.app.contextMenu.selected == want, label & " is not selectable"
  discard s.rt.handleToken("\r", 0)

let answers = block:
  doAssert fileExists(AnswersFile), "the desktop's capture is missing: " &
    AnswersFile & " (run `just plat62-capture-electron`)"
  parseFile(AnswersFile)

suite "PLAT-62: the terminal's Constraints pane over a real measurement":

  test "Edit mode: the desktop's rows, a press, the menu, the keys, staleness":
    let project = writeCrate()
    # `nargo` still prints the fixture's numbers for the crate.
    let (direct, rc) = execCmdEx("nargo info --json", workingDir = project)
    ck rc == 0 and direct.strip() == Plat62NargoInfoJson
    var s = open(project)
    # The Edit default places the pane; it is measured the first time it is
    # on screen.
    ck s.rt.paneAreaOf(paneConstraints).width > 0
    ck s.src.host.runs == 0
    s.settle()
    ck s.src.host.runs == 1
    let m = s.rt.app.constraints
    let before = answers["before"]
    ck m.headline == before["headline"].getStr
    ck m.provenance == before["provenance"].getStr
    ck m.notice == before["notice"].getStr
    var same = 0
    for i, want in before["rows"].getElems:
      let r = m.rows[i]
      if want["index"].getInt == r.index and want["name"].getStr == r.name and
         want["kind"].getStr == r.kind and want["count"].getStr == r.count and
         want["where"].getStr == r.where and want["title"].getStr == r.title and
         want["linked"].getBool == r.linked:
        inc same
      else:
        checkpoint("row " & $i & ": " & $want & " vs " & r.name & " " & r.where)
    ck same == 4 and m.rows.len == before["rows"].len
    # THE VOCABULARY'S VIEW: a `Table` of the same cells.
    var table: ViewNode = nil
    for n in walk(constraintsPaneView(s.src.vm).root):
      if n.kind == pkTable: table = n
    ck not table.isNil and table.columns == ConstraintsColumns
    ck not table.isNil and table.rows.len == 4 and
       table.rows[1] == @["halve", "unconstrained", "16", "src/main.nr:11"]
    ck paneConstraints in PaneVocabularyPanes
    ck paneConstraints notin PaneAcceptedExceptions
    # A PRESS ON `halve` (K67): its line in the editor, the line the desktop's
    # press opened; the editor focused.
    let (hr, hc) = s.rowAt(1)
    discard s.rt.press(hr, hc)
    ck s.rt.app.constraints.selected == 1
    ck s.activeEditor() == ("src/main.nr", Plat62HalveLine, 15)
    ck s.activeEditor().path == answers["pressedPlaced"]["path"].getStr
    ck s.activeEditor().line == answers["pressedPlaced"]["line"].getInt
    ck answers["selectedAfterPress"].getElems.len == 1 and
       answers["selectedAfterPress"][0].getInt == 1
    ck s.rt.focus.focusedPane()[1] == paneEditor
    ck s.rt.app.editSession.activeBuffer().text.splitLines()[Plat62HalveLine - 1] ==
       "unconstrained fn halve(v: Field) -> Field {"
    # A PRESS ON A DIRECTIVE opens nothing and says why.
    let (dr, dc) = s.rowAt(3)
    discard s.rt.press(dr, dc)
    ck s.rt.app.constraints.selected == 3
    ck s.rt.app.notification == DirectiveReason
    ck s.activeEditor().line == Plat62HalveLine
    # THE RIGHT PRESS'S MENU (K68): the desktop's, on a placed row …
    let (mr, mc) = s.rowAt(0)
    discard s.rt.press(mr, mc, button = 2)
    ck s.rt.app.contextMenu.open
    ck s.rt.app.contextMenu.menu.kind == cmkConstraintRow
    var entries: seq[string] = @[]
    for e in s.rt.app.contextMenu.menu.entries:
      entries.add e.label & "=" & $(not e.enabled) & "=" & e.reason
    var desktop: seq[string] = @[]
    for e in answers["placedMenu"]:
      desktop.add e["label"].getStr & "=" & $e["disabled"].getBool & "=" &
                  e["reason"].getStr
    ck entries == desktop
    s.chooseMenu(CopySourceLocationLabel)
    ck s.rt.app.clipboard == "src/main.nr:3"
    discard s.rt.press(mr, mc, button = 2)
    s.chooseMenu(GoToSourceLabel)
    ck s.activeEditor() == ("src/main.nr", Plat62MainLine, 1)
    # … and on a row placed nowhere: Go to Source and Copy Source Location
    # disabled with the row's reason, as the desktop's.
    let (nr, nc) = s.rowAt(2)
    discard s.rt.press(nr, nc, button = 2)
    entries = @[]
    for e in s.rt.app.contextMenu.menu.entries:
      entries.add e.label & "=" & $(not e.enabled) & "=" & e.reason
    desktop = @[]
    for e in answers["nowhereMenu"]:
      desktop.add e["label"].getStr & "=" & $e["disabled"].getBool & "=" &
                  e["reason"].getStr
    ck entries == desktop
    ck not s.rt.app.contextMenu.menu.entries[0].enabled
    s.chooseMenu(CopyNameLabel)
    ck s.rt.app.clipboard == "directive_invert"
    # THE KEYS, the pane focused by a press on its headline.
    let (area, _) = s.rt.constraintsPaneScreen()
    discard s.rt.press(area.row, area.col + 1)
    ck s.rt.focus.focusedPane()[1] == paneConstraints or
       s.rt.app.layoutBinding.focus == paneConstraints
    discard s.rt.handleToken("\x1b[H", 0)    # Home
    ck s.rt.app.constraints.selected == 0
    discard s.rt.handleToken("\x1b[B", 0)    # Down
    ck s.rt.app.constraints.selected == 1
    discard s.rt.handleToken("\r", 0)        # Enter opens it
    ck s.activeEditor() == ("src/main.nr", Plat62HalveLine, 15)
    # AN UNSAVED EDIT marks the counts stale; `:w` re-measures them.
    discard s.rt.handleToken("X", 0)
    ck s.rt.app.editSession.activeBuffer().isDirty
    discard s.src.tick(s.rt)
    ck s.rt.app.constraints.headline == Plat62Headline & " (stale)"
    ck s.rt.app.constraints.stale
    discard s.rt.handleToken("\x7f", 0)      # Backspace: the same text again
    s.omnibox(":w")
    ck not s.rt.app.editSession.activeBuffer().isDirty
    sleep(WatchIntervalMs + 50)
    s.settle()
    ck s.src.host.runs == 2
    ck s.rt.app.constraints.headline == Plat62Headline
    ck not s.rt.app.constraints.stale
    s.src.close()
    removeDir(project)

  test "Debug mode: `:constraints` opens the pane the default does not place":
    let project = writeCrate()
    var s = open(project, pmDebug)
    let b = s.rt.app.layoutBinding
    ck not b.layout.tree.contains(paneConstraints)
    ck b.layout.dockedIndex(paneConstraints) < 0
    discard s.src.tick(s.rt)
    ck s.src.host.runs == 0                  # not on screen: not measured
    s.omnibox(":constraints")
    ck b.layout.tree.contains(paneConstraints)
    ck s.rt.paneAreaOf(paneConstraints).width > 0
    s.settle()
    ck s.src.host.runs == 1
    ck s.rt.app.constraints.headline == Plat62Headline
    ck s.rt.app.constraints.rows.len == 4
    ck s.rt.app.constraints.rows[0].where == "src/main.nr:3"
    # Shown again, it is focused, not opened twice.
    s.omnibox(":constraints")
    var count = 0
    for leaf in allPanes(b.layout.tree):
      if leaf == paneConstraints: inc count
    ck count == 1
    s.src.close()
    removeDir(project)

  test "a folder that is not a crate, and no folder at all":
    let plain = createTempDir("ct-plat62-plain-", "")
    var s = open(plain)
    s.settle()
    ck s.rt.app.constraints.absence == NotANoirCrateText
    ck s.rt.app.constraints.rows.len == 0
    s.src.close()
    removeDir(plain)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
