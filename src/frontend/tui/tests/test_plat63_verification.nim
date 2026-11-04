## test_plat63_verification.nim — PLAT-63, Tier 1: **the terminal's
## Verification pane**, painted from its value and driven through the
## product's runtime over REAL Verno runs of real Noir packages.
##
## Spec: codetracer-pm `spec/Planned-Features/Verification-Payload-
## Contract-v1.md` §5, §7, §9; `milestones/Verno-CodeTracer-Integration.
## milestones.org` VN-M3, VN-M5.
##
##   * THE PAINTER at every width from 30 to 160 cells: the status on the
##     left, the Run control on the right while it fits; the command line;
##     each kind's heading over its findings, the kind in its tone's colour,
##     the title and the message; the selected line on the selection
##     surface; the scrollbar exactly when the list overflows — and every
##     part hit-tested by the arithmetic that drew it;
##   * THE RUNTIME OVER A REAL RUN (`host/verification_source`, the window's
##     `VerificationVM` filled by `viewmodel/host/native_verification_host`):
##     View › Verification opens the pane in an Edit-mode window over the
##     `typeerr` package; the Run control runs the package's own `.vscode/
##     tasks.json` Verno action through the runner the shipped loop uses,
##     polled until it settles; the pane lists the run's findings BY KIND —
##     EQUAL to the lines the desktop's view draws over the same ViewModel
##     (its headless tree); a press on a finding opens ITS file at ITS line
##     and column in the editor (K64); a right press opens the shared row
##     menu, whose Copy Location copies the location (K65); the list keys
##     move the cursor and Enter is the press; a short pane draws the list's
##     scrollbar;
##   * THE COUNTEREXAMPLE over the `verus_post_failure` package's real
##     solver run: the offers listed first, a press on one opens its
##     counterexample in the pane — the provenance banner, the positions
##     summary, the steps — a press on the step with no source position
##     says so and opens nothing, a press on the violation opens
##     `src/main.nr` at line 7; a finding whose file is not in the package
##     says so;
##   * THE VOCABULARY'S VIEW of the same ViewModel (`verificationPaneView`).
##
## THE ONE STAND-IN, AND WHY IT IS NOT A MOCK: the `verno` on PATH replays a
## recorded real run (`fixtures/plat63_verno_projects`, whose header says
## exactly what it replays and the one edit it makes). Every part of the
## product downstream of the process is real: the task file, the launch and
## poll, the classifier, the report's discovery, decoding and staleness rule,
## the pane, the editor the findings open in (`EditSession`, its file read by
## the shipped `edit_host.readProjectFile`).

import std/[os, options, strutils, monotimes, tables, times, unittest]

import isonim/testing/mock_dom
import codetracer_embed

import ../app/runtime
import ../app/tui_app
import ../app/edit_binding
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/verification_pane
import ../host/verification_source
import ../../viewmodel/viewmodels/project_actions
from ../host/edit_host import readProjectFile, TuiHostError
import ./fixtures/plat63_verno_projects
import ../../viewmodel/views/isonim_verification_view
import ../../../common/view_vocabulary
from ../../view_vocabulary/pane_views import verificationPaneView,
  VerificationColumns, PaneAcceptedExceptions, PaneVocabularyPanes

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 69

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 40
  RunBudgetMs = 60_000

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

proc settledVM(output, payload, root: string): VerificationVM =
  ## A finished run of `root`'s Verno action, its recorded output and
  ## report through the real classifier and decoder (no process).
  result = createVerificationVM()
  result.start(ProjectAction(id: "tasks:" & VernoTaskLabel,
                             label: VernoTaskLabel, command: "verno",
                             args: @VernoArgs), projectRoot = root)
  let started = decodeVerificationPayload(payload).payload.startedAtUnixMs
  result.finish(output, some(1), payloadText = payload,
                runStartedAtUnixMs = started)

# ---------------------------------------------------------------------------
# The painter
# ---------------------------------------------------------------------------

proc sampleModel(): VerificationPaneModel =
  let vm = settledVM(TypeErrOutput, TypeErrPayload, "/work/typeerr")
  vm.offerRun(VernoTaskLabel)
  vm.selectLine("finding:1")
  paneModelOf(vm, createCounterexampleSessionVM())

suite "PLAT-63: the terminal's Verification painter":

  test "every width: the header, the lines, the tones and the hit-tests":
    var bad = 0
    for width in 30 .. 160:
      let m = sampleModel()
      let area = CellArea(col: 2, row: 1, width: width, height: 10)
      var g = newStyledGrid(area.col + width, area.row + area.height)
      let s = paintVerification(g, area, m)
      let header = g.rowText(area.row)
      if not header.startsWith(spaces(area.col) & m.status[0 ..< 3]):
        inc bad; checkpoint("status at " & $width & ": " & header)
      if s.runCells > 0:
        if s.runCol + s.runCells != area.col + width:
          inc bad; checkpoint("run control at " & $width)
        let t = m.verificationTargetAt(s, area, area.row, s.runCol)
        if t.kind != vtRun:
          inc bad; checkpoint("run hit at " & $width)
      elif width >= 60:
        inc bad; checkpoint("no run control at " & $width)
      if s.headerRows != 2 or not g.rowText(area.row + 1).contains("verno"):
        inc bad; checkpoint("command at " & $width)
      # Line by line: the note, the group, the two findings.
      for k, line in m.lines:
        let row = s.listTop + k
        let t = m.verificationTargetAt(s, area, row, area.col + 3)
        if t.kind != vtLine or t.line != k or t.key != line.key:
          inc bad; checkpoint("line hit " & $k & " at " & $width)
        if line.kind == vlFinding:
          let role = g.styleAt(row, area.col + VerificationIndentCells).role
          if role != kindStyle(line.findingKind).role:
            inc bad; checkpoint("tone " & $k & " at " & $width)
          let selected = g.styleAt(row, area.col + 1).surface ==
                         VerificationSelectedSurface
          if selected != (line.key == m.selectedKey):
            inc bad; checkpoint("selection " & $k & " at " & $width)
    ck bad == 0

  test "the words, as the shared model has them":
    let m = sampleModel()
    let area = CellArea(col: 0, row: 0, width: 140, height: 10)
    var g = newStyledGrid(140, 10)
    let s = paintVerification(g, area, m)
    ck m.status.startsWith("failed before reaching the prover")
    ck m.command == VernoCommandLine
    ck g.rowText(0).endsWith("▶ " & VernoTaskLabel)
    ck s.painted.len == 4
    ck s.painted[0] == "Nothing was proved or disproved about this program."
    ck s.painted[1] == "pipeline error (2)"
    ck s.painted[2] == "  pipeline error  typeerr/src/main.nr:2  " &
                       "Expected type Field, found type u32"
    ck s.painted[3].contains("typeerr/src/main.nr:1")
    ck g.styleAt(s.listTop + 2, 2).role == VerificationOtherKindStyle.role
    ck s.trackCol == -1

  test "short: the scrollbar, scrolled, and a press on it":
    var m = sampleModel()
    let area = CellArea(col: 0, row: 0, width: 100, height: 4)
    var g = newStyledGrid(100, 4)
    let s = paintVerification(g, area, m)
    ck s.listRows == 2 and s.trackCol == 99
    ck m.verificationTargetAt(s, area, s.listTop, 99).kind == vtTrack
    m.scrollTop = 2
    var g2 = newStyledGrid(100, 4)
    let s2 = paintVerification(g2, area, m)
    ck s2.painted[0] == s.painted[0].replace(s.painted[0], s2.painted[0]) and
       s2.painted[0].contains("typeerr/src/main.nr:2")
    ck m.revealLine(2, 0) == 0 and m.revealLine(2, 3) == 2

# ---------------------------------------------------------------------------
# The runtime over a real run
# ---------------------------------------------------------------------------

type
  Session = object
    rt: TuiRuntime
    src: VerificationSource
    project: string

proc open(run: VernoRun): Session =
  ## An Edit-mode window over `run.root`, wired as `main.nim`'s edit loop
  ## wires it: the project reader, the Verification source.
  withVernoOnPath(run)
  let app = newTuiApp()
  app.projectRoot = run.root
  app.modes = initModeRegister(pmEdit)
  let rt = newTuiRuntime(app, caps(), Cols, Rows)
  discard rt.enableLayoutBinding()
  let project = run.root
  rt.editServices.readFile = proc(relative: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readProjectFile(project, relative))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  let src = newVerificationSource(rt, proc(): string = app.projectRoot,
    proc(path: string; line, col: int): string =
      rt.openWorkingFileAt(path, line, col))
  Session(rt: rt, src: src, project: run.root)

proc showPane(s: Session) =
  var outcome: RuntimeOutcome
  s.rt.runMenuAction("aVerification", outcome)

proc screenOf(s: Session): seq[string] = s.rt.shellScreenOf().rows

proc findOnScreen(s: Session; needle: string): (int, int) =
  let rows = s.screenOf()
  for r, line in rows:
    let c = line.find(needle)
    if c >= 0:
      return (r, cellWidthOf(line[0 ..< c]))
  (-1, -1)

proc pressRun(s: Session) =
  let (area, screen) = s.rt.verificationPaneScreen()
  doAssert screen.runCells > 0, "no Run control is drawn in " & $area
  discard s.rt.press(area.row, screen.runCol + 1)

proc settle(s: Session): bool =
  ## The loop's ticks until the run settles.
  let deadline = getMonoTime() + initDuration(milliseconds = RunBudgetMs)
  while s.src.running and getMonoTime() < deadline:
    discard s.src.tick(s.rt)
    sleep(20)
  discard s.src.tick(s.rt)
  not s.src.running

proc pressLine(s: Session; index: int; button = 0): RuntimeOutcome =
  ## A press on list line `index` (scrolled into view first).
  var (area, screen) = s.rt.verificationPaneScreen()
  if index < screen.top or index >= screen.top + screen.listRows:
    s.rt.app.verification.scrollTop = index
    (area, screen) = s.rt.verificationPaneScreen()
  s.rt.press(screen.listTop + index - screen.top, area.col + 4, button)

proc activeEditor(s: Session): tuple[path: string; line, col: int] =
  if s.rt.app.editSession.isNil: return ("", -1, -1)
  let buf = s.rt.app.editSession.activeBuffer()
  if buf.isNil: return ("", -1, -1)
  (buf.path, buf.caretLine, buf.caretColumn + 1)

proc desktopLines(s: Session): seq[string] =
  ## The desktop's view over the same ViewModel: its group headings and
  ## rows, in its order (the IsoNim tree the desktop mounts, drawn
  ## headlessly).
  var renderer: MockRenderer
  let tree = renderVerificationPanelLive[MockRenderer, MockNode](renderer,
    s.src.host.vm, s.src.host.session)
  var acc: seq[string] = @[]
  proc walk(n: MockNode) =
    if n.isNil: return
    if "data-ct-verification-group-heading" in n.attributes:
      acc.add "group " & textContent(n)
    elif "data-ct-verification-row" in n.attributes:
      var parts: seq[string] = @[]
      for c in n.children:
        let cls = c.attributes.getOrDefault("class")
        if cls in ["ct-verification-row-kind", "ct-verification-row-title",
                   "ct-verification-row-message"]:
          parts.add textContent(c)
      acc.add "row " & n.attributes["data-ct-verification-key"] & " " &
              parts.join(" | ") & " @ " &
              n.attributes["data-ct-verification-location"]
      return
    for c in n.children: walk(c)
  walk(tree)
  acc

proc paneLines(s: Session): seq[string] =
  ## The terminal's pane, in the same words.
  for line in s.rt.app.verification.lines:
    case line.kind
    of vlGroup: result.add "group " & line.text
    of vlFinding:
      result.add "row " & line.key & " " & line.kindLabel & " | " &
                 line.title & " | " & line.message & " @ " & line.location
    else: discard

suite "PLAT-63: the terminal's Verification pane over a real run":

  test "a real pipeline-error run: open, Run, findings, a press, the menu":
    let run = writeTypeErrRun()
    defer: run.removeRun()
    var s = open(run)
    s.showPane()
    ck s.rt.verificationPaneScreen().area.width > 0
    ck s.rt.app.verification.loaded
    ck s.rt.app.verification.runLabel == VernoTaskLabel
    ck s.findOnScreen("▶ " & VernoTaskLabel)[0] >= 0
    s.pressRun()
    ck s.src.running or s.src.host.vm.hasReport.val
    ck s.settle()
    let vm = s.src.host.vm
    ck vm.payloadStatus.val == psAttached
    ck s.rt.app.verification.status.startsWith(
         "failed before reaching the prover")
    ck s.rt.app.verification.command == VernoCommandLine
    # THE FINDINGS, by kind, equal to the desktop's view of the same run.
    var want = @["group pipeline error (2)"]
    for i, r in TypeErrExpectedRows:
      want.add "row finding:" & $i & " " & r[0] & " | " & r[1] & " | " &
               r[2] & " @ " & r[3]
    ck s.paneLines() == want
    ck s.desktopLines() == want
    # ON THE SCREEN, line for line.
    ck s.findOnScreen("pipeline error (2)")[0] >= 0
    let (row0, _) = s.findOnScreen("pipeline error  typeerr/src/main.nr:2")
    ck row0 >= 0
    # K64: a press on the second finding opens `src/main.nr` at 1:24.
    discard s.pressLine(3)
    let ed = s.activeEditor()
    ck ed.path == "src/main.nr"
    checkpoint("editor at " & $ed)
    ck ed.line == 1 and ed.col == 24
    ck vm.selectedKey.val == "finding:1"
    ck s.rt.app.notification.contains("typeerr/src/main.nr:1:24")
    # The quoted text is the line the finding is on.
    ck lineOf(TypeErrSource, 1).find("u32 {") == 23
    # K65: a right press opens the shared menu; Copy Location copies.
    s.showPane()
    discard s.pressLine(2, button = 2)
    ck s.rt.app.contextMenu.open
    ck s.rt.app.contextMenu.menu.kind == cmkVerificationRow
    let labels = s.rt.app.contextMenu.menu.labels
    ck labels == @["Go to Source", "Copy Message", "Copy Location"]
    let menuArea = s.rt.shellScreenOf().contextMenuArea
    discard s.rt.press(menuArea.row + 1 + labels.find("Copy Location"),
                       menuArea.col + 3)
    ck not s.rt.app.contextMenu.open
    ck s.rt.app.clipboard == "typeerr/src/main.nr:2:20"
    # THE KEYS, the pane focused: Up / Home / End move, Enter is the press.
    discard s.rt.focus.focusPaneKind(paneVerification)
    discard s.rt.handleToken("\x1b[H", 0)       # Home
    ck vm.selectedKey.val == "finding:0"
    discard s.rt.handleToken("\x1b[F", 0)       # End
    ck vm.selectedKey.val == "finding:1"
    discard s.rt.handleToken("\x1b[A", 0)       # Up
    ck vm.selectedKey.val == "finding:0"
    discard s.rt.handleToken("\r", 0)           # Enter
    checkpoint("editor at " & $s.activeEditor())
    ck s.activeEditor().line == 2 and s.activeEditor().col == 20
    # THE VOCABULARY'S VIEW: a `Table` of the same cells under the heading.
    var table: ViewNode = nil
    for n in walk(verificationPaneView(vm).root):
      if n.kind == pkTable: table = n
    ck not table.isNil and table.columns == VerificationColumns
    ck not table.isNil and table.rows.len == 2 and
       table.rows[0] == @["pipeline error", "typeerr/src/main.nr:2",
                          "Expected type Field, found type u32",
                          "typeerr/src/main.nr:2:20"]
    ck paneVerification in PaneVocabularyPanes
    ck paneVerification notin PaneAcceptedExceptions
    s.src.close()

  test "the counterexample: offers, the steps, a press on each":
    let run = writeCounterexampleRun()
    defer: run.removeRun()
    var s = open(run)
    s.showPane()
    s.pressRun()
    ck s.settle()
    let vm = s.src.host.vm
    ck vm.payloadStatus.val == psAttached
    let lines = s.rt.app.verification.lines
    ck lines.len == 4
    ck lines[0].kind == vlOffer and lines[1].key == "offer:f1"
    ck s.findOnScreen("▸ " & OpenCounterexampleLabel)[0] >= 0
    # A press on the offer opens its counterexample in the pane.
    discard s.pressLine(1)
    ck s.src.host.session.isOpen.val
    let open = s.rt.app.verification.lines
    ck open.len == 9
    ck open[4].kind == vlCounterexample
    ck open[5].text == SolverDerivedProvenance
    ck s.findOnScreen("1 of 2 steps have no source position")[0] >= 0
    ck s.rt.app.verification.lines[7].location == UnknownPositionText
    # The step with no position: the walk moves, nothing opens.
    discard s.pressLine(7)
    ck s.src.host.session.currentStep.val == 0
    ck s.activeEditor().path == ""
    ck s.rt.app.notification.contains(UnknownPositionText)
    # The violation: `src/main.nr` at line 7, column 12.
    discard s.pressLine(8)
    ck s.src.host.session.currentStep.val == 1
    ck s.activeEditor().path == "src/main.nr"
    checkpoint("editor at " & $s.activeEditor())
    ck s.activeEditor().line == 7 and s.activeEditor().col == 12
    ck lineOf(VerusPostFailureSource, 7).find("*state == 1") == 11
    # The finding whose file the package does not have says so.
    s.showPane()
    discard s.pressLine(3)
    ck s.rt.app.notification.contains("is not in")
    ck s.rt.app.notification.contains("noir_verification_failing")
    s.src.close()

  test "a project that declares no Verno action offers no run, and says why":
    let base = getTempDir() / "ct-plat63-none-" & $getCurrentProcessId()
    createDir(base)
    defer: removeDir(base)
    var s = open(VernoRun(root: base, bin: base))
    s.showPane()
    ck s.rt.app.verification.runLabel == ""
    ck s.src.host.vm.runUnavailableReason.val.contains("no Verno action")
    var o: RuntimeOutcome
    discard s.rt.actOnVerification(VerificationAct(kind: vrRun), o)
    ck s.rt.app.notification.contains("no Verno action")
    s.src.close()

suite "PLAT-63 terminal verification: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
