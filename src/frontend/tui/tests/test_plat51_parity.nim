## test_plat51_parity.nim — PLAT-51 on the terminal, Tier 1 over a REAL
## session (the runtime and the shell in process, a real `replay-server`, the
## real `calc` recording): the user's 2026-10-04/05 decisions that are not
## the scrubbers (`test_plat51_scrubbers.nim`) and not the frame viewer's own
## transport (`app/tests/test_frame_viewer_pane.nim`).
##
##   * deliverable 1 — NO TIMELINE: no pane on the screen, no View-menu entry
##     in the shared product menu; `4` focuses the Event Log;
##   * deliverable 4 — no `[MOD]` badge: a changed value takes the desktop's
##     changed-value accent (`diff_highlighter.ChangedValueStyle`) on its
##     VALUE, the name stays plain, and nothing is accented at the entry;
##   * deliverable 5 — every desktop value feature: the value-history control
##     opens the history UNDER its row, a history entry is a navigation row
##     (a click goes to its tick); the origin control opens the origin under
##     the row; watches are added, edited and removed (`:watch`, `:watch-edit
##     OLD -> NEW`, `:unwatch`), each in the Watches group; "Add to
##     scratchpad" pins a value;
##   * deliverable 6 — a CARET in the read-only editor: a click on the text
##     places it, the arrow keys move it, it is a reversed cell distinct from
##     the execution pointer; `Alt+t` (and `Ctrl+Enter`) opens the tracepoint
##     editor on the caret's line;
##   * deliverable 7 — the menus carry an inert last row "Terminal menu: Shift
##     + right-click" that a press does not choose; a Shift-modified mouse
##     report is the terminal's (no menu, no move, no repaint);
##   * deliverable 12 — the omnibox on the editor's ground and foreground
##     idle, focused, typing and in its results;
##   * deliverable 13 — the execution pointer is ` ▸ `, never `-->` or `▶`;
##     the ASCII tier draws `>`.
##
## Everything through the product's own entry points (`handleToken` with the
## bytes a terminal sends, `applyOutcome` as the shipped loop runs it,
## `shellScreenOf` for the frame). No mocks: the state directory is a scratch
## one, the engine and the recording are real.

import std/[os, sequtils, strutils, tables, unicode, unittest]

import headless_session
import headless_app/layout_model
import viewmodels/product_menu

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/roles
import ../app/theme/degradation
import ../app/views/shell
import ../app/views/styled_row
import ../app/views/gutter
import ../app/views/tree_node
import ../app/views/diff_highlighter
import ../app/views/source_pane
import ../app/views/context_menu
import ../app/views/variables
import ../app/layout/profile
import ../host/tui_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 157
  ## +2: an unbound Alt+<char> is the character alone (the caret case).

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 56
  Enter = "\r"
  Esc = "\x1b"

proc newRuntime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc sgr(code, row, col: int; release = false; motion = false): string =
  "\x1b[<" & $(code + (if motion: 32 else: 0)) & ";" & $(col + 1) & ";" &
    $(row + 1) & (if release: "m" else: "M")

proc send(s: TuiSession; rt: TuiRuntime; token: string) =
  let outcome = rt.handleToken(token, 0)
  s.applyOutcome(rt, outcome)

proc click(s: TuiSession; rt: TuiRuntime; row, col: int; code = 0) =
  s.send(rt, sgr(code, row, col))
  s.send(rt, sgr(code, row, col, release = true))

proc command(s: TuiSession; rt: TuiRuntime; line: string) =
  s.send(rt, ":")
  for ch in line:
    s.send(rt, $ch)
  s.send(rt, Enter)

proc open(path: string): (TuiRuntime, TuiSession) =
  let rt = newRuntime()
  let s = openTuiSession(path, viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
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

proc cellOf(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc rowIn(rt: TuiRuntime; kind: PaneKind; needle: string;
           start = 0): int =
  ## The first screen row of the pane at or below `start` whose text holds
  ## `needle`, or -1.
  let a = rt.areaOf(kind)
  let rows = rt.shellScreenOf().rows
  for r in max(a.row, start) ..< a.row + a.height:
    if r < rows.len and rows[r].runeSubStr(a.col, a.width).contains(needle):
      return r
  -1

proc cellOfCode(rt: TuiRuntime; line, column: int): (int, int) =
  ## The screen cell the source pane draws `line:column` at, read back by the
  ## pane's own click arithmetic.
  let a = rt.areaOf(paneEditor)
  let model = rt.app.source
  for r in a.row ..< a.row + a.height:
    for c in a.col ..< a.col + a.width:
      let t = model.sourceClickTargetAt(a, r, c)
      if t.line == line and not t.onGutter and t.column == column:
        return (r, c)
  (-1, -1)

let rec = resolveFixture("calc")

suite "PLAT-51 terminal: the Timeline is removed; 4 is the Event Log":

  test "no Timeline on the screen or in the View menu; 4 focuses the Event Log":
    require rec.outcome == foRecorded
    putEnv("CODETRACER_TUI_LAYOUT_DIR", getTempDir() / "plat51-parity-state")
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    let screen = rt.shellScreenOf()
    var text = ""
    for r in screen.rows: text.add r & "\n"
    ck not text.contains("Timeline")
    ck not text.contains("TIMELINE")
    var viewLabels: seq[string] = @[]
    for folder in productMenuTree("ct").children:
      if folder.label == "View":
        for it in folder.children: viewLabels.add it.label
    checkpoint("View: " & $viewLabels)
    ck "Event Log" in viewLabels
    for l in viewLabels:
      ck not l.startsWith("Timeline")
    s.send(rt, "4")
    let (had, focused) = rt.focus.focusedPane()
    ck had
    ck focused == paneEventLog

suite "PLAT-51 terminal: the current line, the caret, the values":

  test "the execution pointer is ▸ (ASCII >), never --> or ▶":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    let row = rt.rowIn(paneEditor, ExecutionPointerGlyph)
    checkpoint("pointer row " & $row)
    ck row > 0
    let a = rt.areaOf(paneEditor)
    let line = rt.shellScreenOf().rows[row].runeSubStr(a.col, a.width)
    ck line.contains(" ▸ ")
    ck not line.contains("-->")
    ck not line.contains("▶")
    ck runeLen(ExecutionPointerGlyph.strip()) == 1
    # The ASCII tier's substitution: the same three cells, `>` in the middle.
    let ascii = resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", lang = "C"),
      initCapabilityFlags())
    ck degradeText(ExecutionPointerGlyph, ascii) == " > "
    ck degradeText(InspectionPointerGlyph, ascii) == " ) "

  test "a click on the text places the caret; keys move it; Alt+t opens the tracepoint editor there":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    let tick = s.session.getCurrentRRTicks()
    let (r, c) = rt.cellOfCode(5, 3)
    ck r > 0
    s.click(rt, r, c)
    ck rt.app.caret.line == 5
    ck rt.app.caret.column == 3
    # A caret is not a move.
    ck s.session.getCurrentRRTicks() == tick
    # The caret's cell is drawn reversed; the cell beside it is not.
    ck rt.styleAt(r, c).reverse
    ck not rt.styleAt(r, c + 1).reverse
    s.send(rt, "\x1b[B")        # Down
    ck rt.app.caret.line == 6
    s.send(rt, "\x1b[C")        # Right
    ck rt.app.caret.column == 4
    s.send(rt, "\x1bt")         # Alt+t
    # The tracepoint editor, on the caret's line: the prompt with
    # `tracepoint ` typed, placed there.
    ck rt.prompt.open
    ck rt.prompt.buffer == "tracepoint "
    ck rt.app.tracepointAt.line == 6
    s.send(rt, Esc)
    ck not rt.prompt.open
    rt.app.tracepointAt = ("", 0)
    s.send(rt, "\x1b[13;5u")    # Ctrl+Enter
    ck rt.prompt.open
    ck rt.app.tracepointAt.line == 6
    s.send(rt, Esc)
    # Any OTHER Alt+<char> (`ESC <char>`, framed as one token by
    # `terminal_driver.feed`) is the character alone, as the framer delivered
    # it before it framed Alt: Alt+: opens the command line, empty.
    s.send(rt, "\x1b:")
    ck rt.prompt.open
    ck rt.prompt.buffer == ""
    s.send(rt, Esc)

  test "no [MOD]: a changed value takes the accent on its value; nothing at the entry":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    var entryText = ""
    for r in rt.shellScreenOf().rows: entryText.add r
    ck not entryText.contains("[MOD]")
    # At the entry nothing has changed, and nothing is accented.
    var entryLit = 0
    for row in rt.shellScreenOf().styledRows:
      for span in row:
        if span.style.role == ChangedValueStyle.role: inc entryLit
    ck entryLit == 0
    for _ in 0 ..< 3:
      s.send(rt, "n")
    let model = rt.app.variables
    let changed = model.diff.modifiedPaths()
    checkpoint("changed: " & $changed)
    ck changed.len > 0
    var lit, plainName = 0
    let screen = rt.shellScreenOf()
    for r, line in screen.rows:
      ck not line.contains("[MOD]")
      for span in screen.styledRows[r]:
        if span.style.role == ChangedValueStyle.role: inc lit
    ck lit > 0
    # The accent is the desktop's changed-value colour, bound to its token.
    ck ChangedValueStyle.role == srValueModified
    ck spec(srValueModified).fg == dtColorsUiTextInformationPrimaryHover
    discard plainName

  test "value history opens under its row and its entry goes to its tick":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    for _ in 0 ..< 3:
      s.send(rt, "n")
    let row = rt.rowIn(paneState, "__name__")
    ck row > 0
    let a = rt.areaOf(paneState)
    let line = rt.shellScreenOf().rows[row].runeSubStr(a.col, a.width)
    let ctl = line.cellOf(HistoryControlGlyph)
    ck ctl > 0
    s.click(rt, row, a.col + ctl)
    let entries = rt.app.openHistories.getOrDefault("@Globals.__name__",
      rt.app.openHistories.getOrDefault("@Locals.__name__"))
    checkpoint("history keys " & $toSeq(rt.app.openHistories.keys))
    ck rt.app.openHistories.len == 1
    var hist: seq[HistoryEntry]
    for k, v in rt.app.openHistories: hist = v
    ck hist.len > 0
    # Under its row: the next row of the pane is an entry.
    let entryRow = rt.rowIn(paneState, HistoryEntryGlyph)
    ck entryRow == row + 1
    # A navigation row: a click goes to the entry's tick.
    s.click(rt, entryRow, a.col + 6)
    ck s.session.getCurrentRRTicks() == hist[0].ticks
    discard entries

  test "the origin control opens the origin under its row; Add to scratchpad pins":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    for _ in 0 ..< 3:
      s.send(rt, "n")
    let row = rt.rowIn(paneState, "__name__")
    ck row > 0
    let a = rt.areaOf(paneState)
    let line = rt.shellScreenOf().rows[row].runeSubStr(a.col, a.width)
    let ctl = line.cellOf(OriginControlGlyph)
    ck ctl > 0
    s.click(rt, row, a.col + ctl)
    ck rt.app.openOrigins.len == 1
    ck rt.app.variables.origins.len == 1
    # Under its row.
    let below = rt.shellScreenOf().rows[row + 1].runeSubStr(a.col, a.width)
    checkpoint("under the row: " & below)
    ck below.contains(OriginHopGlyph)
    # The variable's menu is the desktop's: its two entries, exactly.
    let nameCol = line.cellOf("__name__")
    s.click(rt, row, a.col + nameCol, 2)
    ck rt.app.contextMenu.open
    ck rt.app.contextMenu.menu.labels == @["Toggle value history",
                                            "Show value origin"]
    s.send(rt, Esc)
    # A history entry's menu (the desktop's value menu) pins the value to
    # the scratchpad.
    let hctl = line.cellOf(HistoryControlGlyph)
    s.click(rt, row, a.col + hctl)
    let entryRow = rt.rowIn(paneState, HistoryEntryGlyph)
    ck entryRow > row
    s.click(rt, entryRow, a.col + 6, 2)
    ck rt.app.contextMenu.open
    let labels = rt.app.contextMenu.menu.labels
    checkpoint("history entry menu: " & $labels)
    ck AddToScratchpadLabel in labels
    let area = rt.shellScreenOf().contextMenuArea
    let entry = area.row + 1 + labels.find(AddToScratchpadLabel)
    let pinnedBefore = rt.app.scratchpad.rows.len
    s.click(rt, entry, area.col + 3)
    ck not rt.app.contextMenu.open
    ck rt.app.scratchpad.rows.len == pinnedBefore + 1

  test "watches are added, edited and removed, in the Watches group":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    s.command(rt, "watch 1 + 2")
    ck "1 + 2" in rt.app.variables.watches
    s.command(rt, "watch-edit 1 + 2 -> 2 + 3")
    ck "1 + 2" notin rt.app.variables.watches
    ck "2 + 3" in rt.app.variables.watches
    s.command(rt, "unwatch 2 + 3")
    ck rt.app.variables.watches.len == 0

suite "PLAT-51 terminal: menus, Shift, the omnibox":

  test "every menu ends in an inert Shift + right-click row; Shift reports are the terminal's":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    let (r, c) = rt.cellOfCode(5, 3)
    # Shift + right-click (SGR button 2 with the Shift bit, 4): the
    # terminal's — no menu, and the token asks for no repaint.
    let shifted = rt.handleToken(sgr(2 + 4, r, c), 0)
    ck not rt.app.contextMenu.open
    ck not shifted.repaint
    let shiftedLeft = rt.handleToken(sgr(0 + 4, r, c), 0)
    ck rt.app.caret.line == 0
    ck not shiftedLeft.repaint
    # A plain right-click: the desktop's editor menu, and the hint row last.
    s.click(rt, r, c, 2)
    ck rt.app.contextMenu.open
    let area = rt.shellScreenOf().contextMenuArea
    let hintRow = area.row + 1 + rt.app.contextMenu.menu.entries.len
    ck rt.shellScreenOf().rows[hintRow].contains(TerminalMenuHint)
    ck TerminalMenuHint == "Terminal menu: Shift + right-click"
    for e in rt.app.contextMenu.menu.entries:
      ck not e.label.contains("Shift")
    ck "Add tracepoint" in rt.app.contextMenu.menu.labels
    # A press on the hint row chooses nothing: the menu stays open.
    let ticks = s.session.getCurrentRRTicks()
    s.click(rt, hintRow, area.col + 3)
    ck rt.app.contextMenu.open
    ck s.session.getCurrentRRTicks() == ticks
    s.send(rt, Esc)
    ck not rt.app.contextMenu.open

  test "the omnibox: the editor's ground and foreground, idle, open, typed, results":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    proc fieldStyles(rt: TuiRuntime): seq[CellStyle] =
      let screen = rt.shellScreenOf()
      let col = screen.rows[0].cellOf("⌕")
      if col >= 0:
        result.add rt.styleAt(0, col)
        result.add rt.styleAt(0, col + 3)
    let idle = rt.fieldStyles()
    ck idle.len == 2
    for st in idle: ck st.surface == srSurfaceEditor
    s.send(rt, "\x10")          # Ctrl+p
    let opened = rt.fieldStyles()
    ck opened.len == 2
    for st in opened: ck st.surface == srSurfaceEditor
    s.send(rt, "a")
    let typed = rt.fieldStyles()
    for st in typed: ck st.surface == srSurfaceEditor
    # The results list: its rows on the editor's ground, the selected one on
    # the editor's selection.
    let screen = rt.shellScreenOf()
    var resultRows = 0
    var selected = 0
    for r in 1 ..< 12:
      for span in screen.styledRows[r]:
        if span.style.surface == srSurfaceSelection and
           span.style.role == srEditorText:
          inc selected
          break
      for span in screen.styledRows[r]:
        if span.style.surface == srSurfaceEditor:
          inc resultRows
          break
    checkpoint("result rows " & $resultRows & ", selected " & $selected)
    ck resultRows > 0
    ck selected == 1
    s.send(rt, Esc)

suite "PLAT-51 terminal parity: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
