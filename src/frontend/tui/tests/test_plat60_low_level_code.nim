## test_plat60_low_level_code.nim — PLAT-60, Tier 1. **The Low Level Code
## pane on the terminal: opened beside the source, the listing the engine
## answers, the execution pointer, the cross-reference both ways, a press, the
## row menu, the sync toggle, stepping and the scrollbar — on a real session.**
##
## A real `replay-server` on the real `noir_space_ship` recording (the Noir
## producer's), opened by the terminal's own `openTuiSession`, driven through
## its own token handler (`handleToken` → `applyOutcome`) and painted by its
## own `shellScreen`:
##
##   * the pane is in NO layout until `Alt+1` (the desktop's `aLowLevel1`,
##     `view.low-level-code`) opens it BESIDE THE SOURCE — the editor's region
##     split, the listing after it on the same rows — and only then is the
##     listing asked for (`LowLevelCodeVM.shown`);
##   * the listing is the ENGINE's: the rows the pane holds are the answer
##     `ct/load-asm-function` gives for the stop's function, asked again here
##     over the raw channel — every instruction's offset (`StepId(…)`) and
##     source line, under its source line;
##   * the execution pointer (`▸`, `grExecPointer`) is on the instruction of
##     the line the debugger is at;
##   * SOURCE → INSTRUCTIONS: a press on a source line in the editor marks the
##     instructions generated from it; INSTRUCTION → SOURCE: the listing's
##     cursor (Down) puts the editor's cross-reference on its source line,
##     drawn on the hover ground;
##   * a press on an instruction moves the debugger to its source line — the
##     engine's move (`ct/source-line-jump`), read back from the store;
##   * a right press opens the shared menu (`LowLevelMenuLabels`), whose Copy
##     Instruction copies the row;
##   * the header's `sync on` turns source syncing off: the notice says so
##     and the cross-reference goes;
##   * the header says a step goes by line — no engine here offers
##     instruction granularity — and a step pressed in the listing moves the
##     debugger by line;
##   * in a short pane the listing's scrollbar is drawn;
##   * GPUI's vocabulary view (`pane_views.lowLevelCodePaneView`) over the same
##     ViewModel lists the same rows.
##
## No mocks: a real recording, a real `replay-server`, the terminal's real
## runtime, host and painters.

import std/[json, os, strutils, unicode, unittest]

import isonim/core/[signals]

import headless_session
import headless_app/layout_model
import view_vocabulary/pane_views
import ../../../common/view_vocabulary

import ../app/runtime
import codetracer_embed
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/roles
import ../app/views/shell
import ../app/views/styled_row
import ../app/views/source_pane
import ../app/views/low_level_code_pane
import ../host/tui_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as the suite's RUNTIME assertion count.
const ExpectedAssertions = 78

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 56
  AltOne = "\x1b1"
  Down = "\x1b[B"

proc newRuntime(rows = Rows): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, Cols, rows)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc sgr(code, row, col: int; release = false): string =
  "\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
    (if release: "m" else: "M")

proc send(s: TuiSession; rt: TuiRuntime; token: string) =
  let outcome = rt.handleToken(token, 0)
  s.applyOutcome(rt, outcome)

proc click(s: TuiSession; rt: TuiRuntime; row, col: int; code = 0) =
  s.send(rt, sgr(code, row, col))
  s.send(rt, sgr(code, row, col, release = true))

proc open(path: string; rows = Rows): (TuiRuntime, TuiSession) =
  let rt = newRuntime(rows)
  let s = openTuiSession(path, viewportHeight = rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  rt.app.lowLevelAct = proc(act: LowLevelAct): LowLevelActResult =
    s.lowLevelAct(rt, act)
  (rt, s)

proc areaOf(rt: TuiRuntime; kind: PaneKind): CellArea =
  let screen = rt.shellScreenOf()
  for region in screen.geometry.projection.regions:
    if region.pane == kind:
      let frame = paneFrame(region.area, screen.geometry.body)
      return CellArea(col: region.area.col, row: region.area.row,
                      width: frame.box.width, height: frame.box.height)
  CellArea()

proc styleAt(rt: TuiRuntime; row, col: int): CellStyle =
  let screen = rt.shellScreenOf()
  var c = 0
  for span in screen.styledRows[row]:
    let w = span.text.runeLen
    if col >= c and col < c + w:
      return span.style
    c += w
  CellStyle()

const AnswersFile = "src/tests/visual/answers/plat60-low-level-code.electron.json"
  ## The desktop's Low Level Code view on this recording, captured from the
  ## real Electron app (`just plat60-capture-electron`).

proc desktopAnswers(): JsonNode =
  var dir = currentSourcePath().parentDir
  while not fileExists(dir / AnswersFile) and dir.parentDir != dir:
    dir = dir.parentDir
  parseJson(readFile(dir / AnswersFile))

proc asDesktopRows(m: LowLevelPaneModel): seq[string] =
  ## The pane's rows in the capture's spelling: a source line's number and
  ## mark; an instruction's offset, text, source line and marks.
  for r in m.rows:
    case r.kind
    of lpSource:
      result.add "source " & $r.line & " active=" & $r.active
    of lpInstruction:
      result.add "instruction " & r.offset & " " & r.instruction & " " &
                 r.crossRef & " active=" & $r.active & " executing=" &
                 $r.executing

proc desktopRows(listing: JsonNode): seq[string] =
  for r in listing.getElems:
    if r["kind"].getStr == "source":
      result.add "source " & $r["line"].getInt & " active=" & $r["active"].getBool
    else:
      result.add "instruction " & r["offset"].getStr & " " & r["name"].getStr &
                 " " & r["source"].getStr & " active=" & $r["active"].getBool &
                 " executing=" & $r["executing"].getBool

proc debuggerLine(s: TuiSession): int =
  s.session.session.store.debugger.val.location.line

proc listingRowOf(rt: TuiRuntime; row: int): int =
  ## The screen row the listing draws display row `row` on, -1 when hidden.
  let (area, screen) = rt.lowLevelPaneScreen()
  discard area
  let k = row - screen.top
  if k < 0 or k >= screen.listRows: -1 else: screen.listTop + k

proc sourceScreenRow(rt: TuiRuntime; line: int): tuple[row, col: int] =
  ## Where the editor draws source line `line` (its code's first cell).
  let a = rt.areaOf(paneEditor)
  for r in a.row + 1 ..< a.row + a.height:
    for c in a.col ..< a.col + a.width:
      let t = rt.app.source.sourceClickTargetAt(a, r, c)
      if t.line == line and not t.onGutter and t.column > 0:
        return (r, c)
  (-1, -1)

suite "PLAT-60: the Low Level Code pane on the terminal, on a real session":

  let rec = resolveFixture("noir_space_ship")

  test "Alt+1 opens it beside the source, with the engine's listing":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    let b = rt.app.layoutBinding
    # In no default layout, and nothing asked while it is not shown.
    ck not b.layout.tree.contains(paneLowLevelCode)
    ck not s.session.session.lowLevelCodeVM.shown.val
    ck rt.app.lowLevel.rows.len == 0
    s.send(rt, AltOne)
    ck b.layout.tree.contains(paneLowLevelCode)
    let ed = rt.areaOf(paneEditor)
    let ll = rt.areaOf(paneLowLevelCode)
    checkpoint("editor " & $ed & " listing " & $ll)
    # BESIDE the source: on the editor's rows, to its right.
    ck ll.width > 0
    ck ll.row == ed.row
    ck ll.col >= ed.col + ed.width
    ck s.session.session.lowLevelCodeVM.shown.val
    let (focused, pane) = rt.focus.focusedPane()
    ck focused and pane == paneLowLevelCode
    # THE ENGINE'S LISTING, asked again over the raw channel.
    let fn = s.session.session.store.asmFunction
    let answer = s.session.sendRawDapRequest("ct/load-asm-function", %*{
      "path": fn.path, "name": fn.name, "key": fn.key, "forceReload": false})
    discard s.session.drainEvents()
    let engine = answer{"body", "instructions"}.getElems
    checkpoint("engine: " & $answer)
    ck engine.len > 1
    var held: seq[LowLevelPaneRow] = @[]
    for r in rt.app.lowLevel.rows:
      if r.kind == lpInstruction: held.add r
    ck held.len == engine.len
    for i in 0 ..< min(held.len, engine.len):
      let e = engine[i]
      let offset = e{"offset"}.getInt
      ck held[i].offset == (if offset < 0: "<no step id>"
                            else: "StepId(" & $offset & ")")
      ck held[i].crossRef == e{"highLevelPath"}.getStr & ":" &
                             $e{"highLevelLine"}.getInt
    # THE DESKTOP'S LISTING, row for row, marks included.
    let desk = desktopAnswers()
    checkpoint("desktop: " & $desk["listing"])
    ck rt.app.lowLevel.asDesktopRows == desktopRows(desk["listing"])
    ck s.debuggerLine == desk["start"]["line"].getInt
    # Each run of instructions after its source line.
    var lastLine = -1
    for r in rt.app.lowLevel.rows:
      if r.kind == lpSource: lastLine = r.line
      else: ck r.crossRef.endsWith(":" & $lastLine)
    # THE EXECUTION POINTER on the debugger's line, drawn with its glyph.
    let at = rt.app.lowLevel.executionRow
    ck at >= 0
    ck rt.app.lowLevel.rows[at].crossRef.endsWith(":" & $s.debuggerLine)
    let screenRow = rt.listingRowOf(at)
    ck screenRow >= 0
    let text = rt.shellScreenOf().rows[screenRow].runeSubStr(ll.col, ll.width)
    checkpoint("pointer row: " & text)
    ck text.startsWith("▸")
    ck text.contains(rt.app.lowLevel.rows[at].offset)
    ck rt.styleAt(screenRow, ll.col + 3).surface == srSurfaceCurrentLine
    # The header: the sync toggle and what a step does.
    let header = rt.shellScreenOf().rows[ll.row + 1].runeSubStr(ll.col,
                                                               ll.width)
    ck header.contains("sync on")
    ck header.contains(SteppingByLineText)
    # GPUI's view of the same ViewModel lists the same instructions.
    let view = lowLevelCodePaneView(s.session.session.lowLevelCodeVM)
    var offsets: seq[string] = @[]
    for n in walk(view.root):
      if n.kind == pkTable:
        for row in n.rows:
          if row[1].startsWith("StepId(") or row[1] == "<no step id>":
            offsets.add row[1]
    var mine: seq[string] = @[]
    for r in held: mine.add r.offset
    ck offsets == mine

  test "the cross-reference both ways, a press, the menu, sync, a step":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    s.send(rt, AltOne)
    let ll = rt.areaOf(paneLowLevelCode)
    var lines: seq[int] = @[]
    for r in rt.app.lowLevel.rows:
      if r.kind == lpSource: lines.add r.line
    ck lines.len >= 2
    let here = s.debuggerLine
    var other = -1
    for l in lines:
      if l != here: other = l
    ck other > 0
    # SOURCE → INSTRUCTIONS: the caret placed on `other` in the editor.
    let (srow, scol) = rt.sourceScreenRow(other)
    ck srow >= 0
    s.click(rt, srow, scol)
    discard rt.shellScreenOf()
    ck rt.app.lowLevel.linkedRow >= 0
    var linked = 0
    for r in rt.app.lowLevel.rows:
      if r.linked and r.kind == lpInstruction:
        inc linked
        ck r.crossRef.endsWith(":" & $other)
    ck linked >= 1
    let lrow = rt.listingRowOf(rt.app.lowLevel.linkedRow)
    ck lrow >= 0
    ck rt.styleAt(lrow, ll.col + 3).surface == srSurfaceActiveRow
    # INSTRUCTION → SOURCE: the listing's cursor (focus it, then Down) puts
    # the editor's cross-reference on the selected instruction's line.
    s.send(rt, AltOne)
    s.send(rt, Down)
    let sel = rt.app.lowLevel.selectedRow
    ck sel >= 0
    let selLine = parseInt(rt.app.lowLevel.rows[sel].crossRef.rsplit(':')[^1])
    ck rt.app.lowLevel.crossRefLine == selLine
    let screen = rt.shellScreenOf()
    discard screen
    let (crow, ccol) = rt.sourceScreenRow(selLine)
    ck crow >= 0
    ck rt.styleAt(crow, ccol).surface in {srSurfaceActiveRow,
                                          srSurfaceSelection}
    # A RIGHT PRESS: the shared menu; Copy Instruction copies the row.
    var target = -1
    for i, r in rt.app.lowLevel.rows:
      if r.kind == lpInstruction and r.crossRef.endsWith(":" & $other):
        target = i
    ck target >= 0
    let trow = rt.listingRowOf(target)
    ck trow >= 0
    s.click(rt, trow, ll.col + 4, 2)
    ck rt.app.contextMenu.open
    var want: seq[string] = @[]
    for l in LowLevelMenuLabels: want.add l
    ck rt.app.contextMenu.menu.labels == want
    var deskMenu: seq[string] = @[]
    for e in desktopAnswers()["rowMenu"]: deskMenu.add e["label"].getStr
    ck rt.app.contextMenu.menu.labels == deskMenu
    let area = rt.shellScreenOf().contextMenuArea
    let copyRow = area.row + 1 + want.find("Copy Instruction")
    s.click(rt, copyRow, area.col + 3)
    ck not rt.app.contextMenu.open
    ck rt.app.clipboard.contains(rt.app.lowLevel.rows[target].offset)
    # A PRESS on that instruction: the debugger goes to its source line.
    let before = s.debuggerLine
    s.click(rt, rt.listingRowOf(target), ll.col + 4)
    checkpoint("moved from " & $before & " to " & $s.debuggerLine)
    ck s.debuggerLine == other
    # As the desktop's click on the same instruction: the same line and step,
    # and the listing it then shows.
    let desk = desktopAnswers()
    ck other == desk["click"]["targetLine"].getInt
    ck s.debuggerLine == desk["click"]["after"]["line"].getInt
    ck s.session.getCurrentRRTicks() ==
       uint64(desk["click"]["after"]["ticks"].getInt)
    ck rt.app.lowLevel.asDesktopRows == desktopRows(desk["listingAfter"])
    let at = rt.app.lowLevel.executionRow
    ck at >= 0
    ck rt.app.lowLevel.rows[at].crossRef.endsWith(":" & $other)
    # SYNC OFF from the header: said, and the cross-reference goes.
    s.click(rt, ll.row + 1, ll.col + 2)
    ck not rt.app.lowLevel.syncOn
    ck rt.app.lowLevel.notice == "source syncing is off"
    ck rt.app.lowLevel.crossRefLine == 0
    for r in rt.app.lowLevel.rows: ck not r.linked
    s.click(rt, ll.row + 1, ll.col + 2)
    ck rt.app.lowLevel.syncOn
    # A STEP in the listing goes by line: no engine offers instruction
    # granularity, and the header said so.
    ck rt.app.lowLevel.stepping == SteppingByLineText
    s.send(rt, AltOne)
    let ticks = s.session.getCurrentRRTicks()
    s.send(rt, "\x1b[21~")   # F10, step over
    ck s.session.getCurrentRRTicks() != ticks

  test "a short pane draws the listing's scrollbar":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath, rows = 11)
    defer: s.close()
    s.send(rt, AltOne)
    let (_, screen) = rt.lowLevelPaneScreen()
    checkpoint("rows " & $rt.app.lowLevel.rows.len & " list " &
               $screen.listRows)
    # Eight rows (four source lines, four instructions) in fewer list rows.
    ck rt.app.lowLevel.rows.len > screen.listRows
    ck screen.listRows > 0
    ck screen.trackCol >= 0
    # Scrolled by the wheel, the listing's first row moves.
    let (area, _) = rt.lowLevelPaneScreen()
    s.send(rt, sgr(65, area.row + 2, area.col + 2))
    let (_, after) = rt.lowLevelPaneScreen()
    ck after.top > screen.top

suite "PLAT-60 suite self-check":
  test "low_level_code_assertion_count_is_measured":
    checkpoint("assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
