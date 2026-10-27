## test_plat51_scrubbers.nim — PLAT-51 deliverable 2 on the terminal: the
## Event Log's and the Call Trace's scrollbars are SCRUBBERS over the pane's
## whole population (Scrollbar-Scrubbers.md), over a REAL session (Tier 1: the
## runtime and the shell in process, a real `replay-server`, a real
## recording).
##
## The recordings are the corpus's two longest lists: `noir_space_ship`'s 70
## events (the terminal's event page is 40 rows, the pane shows fewer) and
## `call_pages`'s 602 calls (more than the desktop's own 500-row window; the
## terminal holds the rows on screen plus a buffer). For each pane:
##
##   * the track spans the WHOLE population: its total is the engine's
##     (`ct/event-load`'s `total`, `totalCallsCount`), not the loaded rows;
##   * a press at the track's END shows the LAST row of the whole population;
##     at its start, the first (a mutation that maps the track onto the
##     loaded window, or pages by one screen, fails here);
##   * a drag from top to bottom moves the view monotonically and issues a
##     BOUNDED number of window fetches (at most one per motion event);
##   * the current-position mark is on the row of the debugger's event / call;
##   * none of it moves the debugger — and a row click still does.
##
## M71 (codetracer#838) adds the panes whose whole content is IN HAND — the
## State pane (an open value history included), the Files tree and the VCS
## pane. Scrollbar-Scrubbers.md §2 gives them "an ordinary scrollbar", with
## the §3 click rule "so that every scrollbar behaves alike", drawn as §4's
## terminal track (the rightmost column, eighth-block thumb); CodeTracer-TUI.md
## §4.4 has the wheel scroll "the pane beneath the pointer ... without
## requiring pane focus". For each of the three:
##
##   * painted by its own `paint*` proc over a model that overflows the area,
##     the pane's last column is a track whose thumb moves with `scrollTop`;
##     over one that fits, there is no track and the last column is content;
##   * a wheel over it (it NOT focused) scrolls it, in a real session;
##   * a press on its track's end / start shows the last / first row, a press
##     in the middle centres the row at that fraction, and a held thumb drags.
##
## The State pane's population is the real `call_pages` recording's, with the
## value history of `total` (one entry per loop round) open under its row —
## the reporter's case. The Files and VCS cases need more rows than the
## recording's tree or any repository at hand gives, so: the VCS pane is the
## product's own `VcsSource` over a scratch git repository with two hundred
## untracked files (real git, no fake facade); the Files pane is handed a
## `FileTreeModel` VALUE of two hundred entries — the same plain value
## `fileTreeModelOf` builds from a recording's tree. Nothing the painter or the
## router reads is stubbed: the pane paints a value and the runtime routes to
## it, and neither reads a ViewModel.
##
## Everything through the product's own entry points (`handleToken` with the
## bytes a terminal sends, `applyOutcome` as the shipped loop runs it,
## `shellScreenOf` for the frame). No mocks: the state directory is a scratch
## one (`CODETRACER_TUI_LAYOUT_DIR`), the engine and the recording are real.

import std/[os, osproc, strutils, tables, tempfiles, unicode, unittest]

import headless_session
import viewmodels/scrollbar_scrubber
import headless_app/layout_model

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/roles
import ../app/views/shell
import ../app/views/styled_row
import ../app/views/scrubber_track
import ../app/views/variables
import ../app/views/file_tree
import ../app/views/vcs_pane
import ../app/views/tree_node
import ../app/layout/profile
import ../host/tui_session
import ../host/vcs_source
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 122
  ## +72: M71 (#838), the State, Files and VCS panes' scrollbars and wheel.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 48
  ListEvents = 70         ## `noir_space_ship`'s log

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use (the repo's .python-recorder-venv, or " &
               "$CODETRACER_PYTHON_INTERPRETER).",
    blockedOn: "")

proc newRuntime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard result.enableLayoutBinding()

proc sgr(code, row, col: int; release = false; motion = false): string =
  "\x1b[<" & $(code + (if motion: 32 else: 0)) & ";" & $(col + 1) & ";" &
    $(row + 1) & (if release: "m" else: "M")

proc send(s: TuiSession; rt: TuiRuntime; token: string) =
  let outcome = rt.handleToken(token, 0)
  s.applyOutcome(rt, outcome)

proc click(s: TuiSession; rt: TuiRuntime; row, col: int) =
  s.send(rt, sgr(0, row, col))
  s.send(rt, sgr(0, row, col, release = true))

proc open(path: string): (TuiRuntime, TuiSession) =
  let rt = newRuntime()
  let s = openTuiSession(path, viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  (rt, s)

proc areaOf(rt: TuiRuntime; kind: PaneKind): CellArea =
  ## The pane's rectangle from its strip's row, its box's width and height —
  ## exactly what `shell.paintPane` hands the pane's painter (`under`).
  let screen = rt.shellScreenOf()
  for region in screen.geometry.projection.regions:
    if region.pane == kind:
      let frame = paneFrame(region.area, screen.geometry.body)
      return CellArea(col: region.area.col, row: region.area.row,
                      width: frame.box.width, height: frame.box.height)
  CellArea()

proc eventScreen(rt: TuiRuntime): EventLogScreen =
  let a = rt.areaOf(paneEventLog)
  var g = newStyledGrid(Cols, Rows)
  paintEventLog(g, a, rt.app.eventLog)

proc paneText(rt: TuiRuntime; kind: PaneKind): string =
  let a = rt.areaOf(kind)
  let rows = rt.shellScreenOf().rows
  for r in a.row + 1 ..< a.row + a.height:
    if r < rows.len:
      result.add rows[r].runeSubStr(a.col, max(0, a.width - 1)) & "\n"

proc styleAt(rt: TuiRuntime; row, col: int): CellStyle =
  let screen = rt.shellScreenOf()
  var c = 0
  for span in screen.styledRows[row]:
    let w = span.text.runeLen
    if col >= c and col < c + w:
      return span.style
    c += w
  CellStyle()

let rec = resolveFixture("noir_space_ship")
let pages = resolveFixture(pythonSpec("call_pages"))


suite "PLAT-51: the Event Log's scrollbar is a scrubber over the whole log":

  test "the track spans every event; its end shows the LAST event, its start the first":
    require rec.outcome == foRecorded
    putEnv("CODETRACER_TUI_LAYOUT_DIR", getTempDir() / "plat51-scrub-state")
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    let sc = rt.eventScreen()
    checkpoint("track col " & $sc.trackCol & " rows " & $sc.trackRows)
    ck sc.trackCol >= 0
    ck sc.trackRows > 3
    ck sc.trackRows < ListEvents
    # The population is the ENGINE'S count of the whole log, not the rows held.
    ck rt.app.eventLog.knownTotal == ListEvents
    ck rt.app.eventLog.heldRows < ListEvents
    let sm = rt.app.eventLog.scrubberOf(sc.trackRows)
    ck sm.total == ListEvents and sm.totalKnown
    let tick = s.session.getCurrentRRTicks()
    # A press at the END of the track: the last event of the whole log.
    s.click(rt, sc.trackTop + sc.trackRows - 1, sc.trackCol)
    ck rt.app.eventLog.scrollTop == ListEvents - sc.trackRows
    let (lastHeld, lastRow) = rt.app.eventLog.rowAt(ListEvents - 1)
    ck lastHeld
    ck lastRow.index == ListEvents - 1
    ck rt.paneText(paneEventLog).contains(" " & $(ListEvents - 1) & " ")
    # A press at its START: the first.
    s.click(rt, sc.trackTop, sc.trackCol)
    let (firstHeld, firstRow) = rt.app.eventLog.rowAt(0)
    ck firstHeld and firstRow.index == 0
    ck rt.app.eventLog.scrollTop == 0
    # A press in the MIDDLE jumps (centres the row at that fraction) rather
    # than paging by one screen.
    let mid = sc.trackRows div 2
    s.click(rt, sc.trackTop + mid, sc.trackCol)
    let want = sm.clickAt(trackFractionAt(mid, sc.trackRows))
    checkpoint("middle press top " & $rt.app.eventLog.scrollTop & " want " & $want)
    ck rt.app.eventLog.scrollTop == want
    ck want != sc.trackRows
    # None of it moved the debugger.
    ck s.session.getCurrentRRTicks() == tick

  test "a drag from top to bottom: the view follows, with a bounded number of fetches":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    let sc = rt.eventScreen()
    let tick = s.session.getCurrentRRTicks()
    let before = rt.app.listScrubFetches
    var tops: seq[int] = @[]
    # The thumb is at the top: a press on it starts a drag.
    s.send(rt, sgr(0, sc.trackTop, sc.trackCol))
    ck rt.scrollbars.grab.active
    var motions = 0
    for r in sc.trackTop .. sc.trackTop + sc.trackRows - 1:
      s.send(rt, sgr(0, r, sc.trackCol, motion = true))
      inc motions
      tops.add rt.app.eventLog.scrollTop
    s.send(rt, sgr(0, sc.trackTop + sc.trackRows - 1, sc.trackCol,
                   release = true))
    ck not rt.scrollbars.grab.active
    var mono = true
    for i in 1 ..< tops.len:
      if tops[i] < tops[i - 1]: mono = false
    ck mono
    ck tops[^1] == ListEvents - sc.trackRows
    ck rt.app.eventLog.rowAt(ListEvents - 1)[0]
    let fetches = rt.app.listScrubFetches - before
    checkpoint("fetches " & $fetches & " for " & $motions & " motions")
    # BOUNDED: at most one fetch per motion (page-granular, so far fewer),
    # and the log's pages are 40 rows: the whole drag cannot ask for more
    # than the pages it crossed.
    ck fetches > 0
    ck fetches <= motions
    ck fetches <= (ListEvents div 40) + 1
    # The pages far from the view were released: memory stays bounded.
    ck rt.app.eventLog.heldRows <= 3 * 40
    ck s.session.getCurrentRRTicks() == tick

  test "the current-position mark is on the debugger's event; a row click moves the debugger":
    require rec.outcome == foRecorded
    let (rt, s) = open(rec.tracePath)
    defer: s.close()
    var sc = rt.eventScreen()
    # Click the third event row: the debugger goes there (K24).
    let row = sc.trackTop + 2
    let clicked = rt.app.eventLog.scrollTop + 2
    s.click(rt, row, sc.trackCol - 10)
    let after = s.session.getCurrentRRTicks()
    checkpoint("current row " & $rt.app.eventLog.current & " clicked " & $clicked)
    ck rt.app.eventLog.current == clicked
    sc = rt.eventScreen()
    let sm = rt.app.eventLog.scrubberOf(sc.trackRows)
    let markRow = sm.currentMarkRow(sc.trackTop, sc.trackRows)
    ck markRow >= sc.trackTop
    ck rt.styleAt(markRow, sc.trackCol).role == srScrubberMark
    # Scrub to the end: the debugger stays where the click put it, and the
    # mark stays on its row (near the top of the track).
    s.click(rt, sc.trackTop + sc.trackRows - 1, sc.trackCol)
    ck s.session.getCurrentRRTicks() == after
    ck rt.app.eventLog.current == clicked
    ck rt.styleAt(markRow, sc.trackCol).role == srScrubberMark
    # The wheel scrolls by rows (it is not a scrubber gesture).
    s.click(rt, sc.trackTop, sc.trackCol)
    s.send(rt, sgr(65, sc.trackTop + 1, sc.trackCol - 10))
    ck rt.app.eventLog.scrollTop == 3

suite "PLAT-51: the Call Trace's scrollbar is a scrubber over the whole trace":

  test "its end shows the LAST call of the whole trace; the debugger does not move":
    require pages.outcome == foRecorded
    let (rt, s) = open(pages.tracePath)
    defer: s.close()
    let a = rt.areaOf(paneCalltrace)
    let body = a.height - 1
    let total = rt.app.callTrace.total
    checkpoint("calls " & $total & " loaded " & $rt.app.callTrace.rows.len &
               " body " & $body)
    ck total > 600
    ck rt.app.callTrace.rows.len < total
    ck a.tracked
    let trackCol = a.col + a.width - 1
    let tick = s.session.getCurrentRRTicks()
    s.click(rt, a.row + body, trackCol)
    let m = rt.app.callTrace
    # (The total is re-read: the engine re-counts the trace at the expansion
    # the section it loaded left it in.)
    ck m.visibleTop(body) == m.total - body
    # The section around the view was loaded: the last call's row is drawn.
    let (loaded, last) = m.rowAt(m.total - 1)
    ck loaded
    checkpoint("last call " & last.name)
    ck rt.paneText(paneCalltrace).contains(last.name & " #")
    s.click(rt, a.row + 1, trackCol)
    ck rt.app.callTrace.visibleTop(body) == 0
    ck s.session.getCurrentRRTicks() == tick

  test "a drag moves the view monotonically with bounded section loads; the mark is the debugger's call":
    require pages.outcome == foRecorded
    let (rt, s) = open(pages.tracePath)
    defer: s.close()
    # Into the loop, so the current call is deep in the trace.
    for _ in 0 ..< 30:
      s.send(rt, "s")
    let tick = s.session.getCurrentRRTicks()
    let a = rt.areaOf(paneCalltrace)
    let body = a.height - 1
    let trackCol = a.col + a.width - 1
    let total = rt.app.callTrace.total
    let current = rt.app.callTrace.currentTraceIndex
    checkpoint("current call " & $current)
    ck current > 0
    let sm = rt.app.callTrace.scrubberOf(body)
    let markRow = sm.currentMarkRow(a.row + 1, body)
    ck markRow > a.row
    ck rt.styleAt(markRow, trackCol).role == srScrubberMark
    # Drag the thumb from where it is to the bottom of the track.
    let thumb = sm.thumbSpan(body * 8, 8)
    let startRow = a.row + 1 + thumb.start div 8
    s.send(rt, sgr(0, startRow, trackCol))
    ck rt.scrollbars.grab.active and rt.scrollbars.grab.pane == paneCalltrace
    let loadsBefore = rt.app.listScrubFetches
    var tops: seq[int] = @[]
    var motions = 0
    for r in startRow .. a.row + body:
      s.send(rt, sgr(0, r, trackCol, motion = true))
      inc motions
      tops.add rt.app.callTrace.visibleTop(body)
    s.send(rt, sgr(0, a.row + body, trackCol, release = true))
    var mono = true
    for i in 1 ..< tops.len:
      if tops[i] < tops[i - 1]: mono = false
    ck mono
    ck tops[^1] == rt.app.callTrace.total - body
    ck motions <= body
    # BOUNDED section loads: at most one per motion (a view already held asks
    # for nothing).
    let loads = rt.app.listScrubFetches - loadsBefore
    checkpoint("section loads " & $loads & " for " & $motions & " motions")
    ck loads > 0 and loads <= motions + 1
    # The debugger did not move, and the mark is still its call.
    ck s.session.getCurrentRRTicks() == tick
    ck rt.app.callTrace.currentTraceIndex == current

# ---------------------------------------------------------------------------
# M71 (codetracer#838): the State, Files and VCS panes — whole content in
# hand — keep an ordinary scrollbar (Scrollbar-Scrubbers.md §2), drawn as the
# terminal's track (§4) and pressed by the §3 rule, and the wheel scrolls
# each without focusing it (CodeTracer-TUI.md §4.4).
# ---------------------------------------------------------------------------

const
  WheelUp = 64
  WheelDown = 65
  InHandRows = 200
    ## Files entries / untracked VCS files: several times what any pane at
    ## `Rows` shows, so the thumb is short and a press mid-track is on the
    ## track, not the thumb.

proc isThumbStyle(st: CellStyle): bool =
  ## A cell of a scrollbar's thumb (PLAT-70 Part H: `srScrollbarThumb*`).
  st.role.isScrollbarThumbRole

proc onABar(bars: seq[BarSpot]; row, col: int): bool =
  for b in bars:
    if b.contains(row, col): return true

proc trackCells(g: StyledGrid; col, top, rows: int): int =
  ## How many of column `col`'s rows `top ..< top + rows` are a scrollbar's
  ## cells — the bars the painter recorded (PLAT-70 Part H: with the default
  ## options a track cell is the pane's own blank ground, so the cells are
  ## read from the bar, not from a glyph).
  for r in top ..< top + rows:
    if g.bars.onABar(r, col): inc result

proc thumbRows(g: StyledGrid; col, top, rows: int): seq[int] =
  ## The rows of column `col` the thumb covers (any part of), top to bottom.
  for r in top ..< top + rows:
    if g.styleAt(r, col).isThumbStyle: result.add r

proc cellOf(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc rowIn(rt: TuiRuntime; kind: PaneKind; needle: string): int =
  ## The first body row of pane `kind` whose text holds `needle`, or -1.
  let a = rt.areaOf(kind)
  let rows = rt.shellScreenOf().rows
  for r in a.row + 1 ..< a.row + a.height:
    if r < rows.len and rows[r].runeSubStr(a.col, a.width).contains(needle):
      return r
  -1

proc openTotalHistory(rt: TuiRuntime; s: TuiSession): seq[HistoryEntry] =
  ## Step into `call_pages`' `main` until its local `total` is listed, then
  ## open `total`'s value history under its row with the row's history
  ## control — the reporter's case (one entry per loop round).
  var row = -1
  for _ in 0 ..< 80:
    row = rt.rowIn(paneState, "total")
    if row > 0:
      break
    s.send(rt, "s")
  checkpoint("`total` on screen row " & $row)
  if row <= 0:
    return @[]
  let a = rt.areaOf(paneState)
  let line = rt.shellScreenOf().rows[row].runeSubStr(a.col, a.width)
  let ctl = line.cellOf(HistoryControlGlyph)
  if ctl < 0:
    return @[]
  s.click(rt, row, a.col + ctl)
  for _, entries in rt.app.openHistories:
    result = entries

proc wideEntries(): seq[FileTreeEntry] =
  ## `InHandRows` files of a recording's tree, the first named wider than
  ## any pane, so whatever the pane's last column holds on its row is either
  ## that name or the track.
  for i in 0 ..< InHandRows:
    let name = (if i == 0: repeat("x", 300) else: "module_" & $i & ".py")
    result.add FileTreeEntry(text: name, depth: 0, isFolder: false,
                             path: "src/" & name)

proc wideVcs(): VcsPaneModel =
  ## A VCS pane value of `2 + InHandRows + 2` rows: the branch, the working
  ## tree's caption, its files (the first wider than any pane), the commits'
  ## caption and one commit.
  result = VcsPaneModel(loaded: true, isRepo: true, branch: "m71",
                        workingTreeTitle: "Working tree", cleanText: "clean",
                        expandedCommit: -1)
  for i in 0 ..< InHandRows:
    result.files.add VcsFileLine(
      status: "?", path: (if i == 0: repeat("x", 300) else: "f" & $i & ".txt"))
  result.commits.add VcsCommitLine(hash: "496ddf7", subject: "the last row")

proc vcsRows(m: VcsPaneModel): int =
  ## The pane's rows, counted from what it lists (the layout above).
  (if m.branch.len > 0: 1 else: 0) + 1 + max(1, m.files.len) +
    (if m.commits.len > 0: 1 + m.commits.len else: 0)

proc makeVcsRepo(): string =
  ## A real git repository: one commit (`README`), then `InHandRows`
  ## untracked files — so the working tree lists that many rows.
  result = createTempDir("m71-vcs-", "") / "repo"
  createDir(result)
  writeFile(result / "README", "m71\n")
  let q = quoteShell(result)
  let (output, code) = execCmdEx(
    "git -C " & q & " -c init.defaultBranch=m71 init -q && " &
    "git -C " & q & " -c user.name=m71 -c user.email=m71@invalid " &
    "-c commit.gpgsign=false add README && " &
    "git -C " & q & " -c user.name=m71 -c user.email=m71@invalid " &
    "-c commit.gpgsign=false commit -q -m m71")
  if code != 0:
    checkpoint(output)
  for i in 0 ..< InHandRows:
    writeFile(result / ("untracked_" & align($i, 2, '0') & ".txt"), $i & "\n")

proc showVcsTab(s: TuiSession; rt: TuiRuntime): bool =
  ## Press the VCS tab of the Files / VCS stack, so the VCS pane is shown.
  for region in rt.shellScreenOf().geometry.projection.regions:
    for k, title in region.tabs:
      if title.toUpperAscii.contains("VCS"):
        let spans = tabSpans(region.tabs, region.activeTab)
        s.click(rt, region.area.row,
                region.area.col + spans[k].startCol + spans[k].width div 2)
        return true
  false

proc focusedPaneOf(rt: TuiRuntime): (bool, PaneKind) =
  rt.focus.focusedPane()

proc checkTrackPresses(s: TuiSession; rt: TuiRuntime; pane: PaneKind;
                       total: int; topOf: proc(): int) =
  ## §3 on pane `pane`'s track — its last column, one cell, beside the body
  ## rows: a press at the END shows the last row, at the START the first, in
  ## the MIDDLE centres the row at that fraction; the held thumb drags.
  let a = rt.areaOf(pane)
  let col = a.col + a.width - 1
  let top = a.row + 1
  let body = a.height - 1
  checkpoint($pane & ": " & $total & " rows over a body of " & $body)
  ck total > body
  # The shell's frame draws the track down that column, every body row.
  var drawn = 0
  let bars = rt.shellScreenOf().bars
  for r in top ..< top + body:
    if bars.onABar(r, col): inc drawn
  ck drawn == body
  s.click(rt, top + body - 1, col)
  ck topOf() == total - body
  s.click(rt, top, col)
  ck topOf() == 0
  let mid = body div 2
  let sm = scrubberModel(total, 0, body)
  ck sm.verticalScrubberHit(top, body, top + mid).kind == shTrack
  let want = sm.clickAt(trackFractionAt(mid, body))
  s.click(rt, top + mid, col)
  checkpoint($pane & ": middle press top " & $topOf() & " want " & $want)
  ck want > 0
  ck topOf() == want
  # The thumb, at the top again, held and dragged to the bottom.
  s.click(rt, top, col)
  s.send(rt, sgr(0, top, col))
  ck rt.scrollbars.grab.active and rt.scrollbars.grab.pane == pane
  for r in top .. top + body - 1:
    s.send(rt, sgr(0, r, col, motion = true))
  s.send(rt, sgr(0, top + body - 1, col, release = true))
  ck not rt.scrollbars.grab.active
  ck topOf() == total - body

suite "M71 (#838): the State, Files and VCS panes draw a scrollbar when they overflow":

  test "State: an open value history overflows the pane, and the thumb follows scrollTop":
    require pages.outcome == foRecorded
    let (rt, s) = open(pages.tracePath)
    defer: s.close()
    let hist = rt.openTotalHistory(s)
    checkpoint("history of `total`: " & $hist.len & " entries")
    ck hist.len > 100
    let opened = rt.app.variables
    var closed = opened
    closed.histories = initTable[string, seq[HistoryEntry]]()
    let closedRows = closed.paneRows().len
    let openRows = opened.paneRows().len
    # The history's entries are rows of the pane's population.
    ck openRows == closedRows + hist.len
    # An area the pane fits in with the history closed: no track, and the
    # last column is the rows' own.
    const W = 72
    let h = closedRows + 2
    let area = CellArea(col: 0, row: 0, width: W, height: h)
    var fits = newStyledGrid(W, h)
    discard paintVariables(fits, area, closed)
    ck fits.trackCells(W - 1, 1, h - 1) == 0
    # Exactly full — a body row for every row, none spare — is not an
    # overflow either.
    var full = newStyledGrid(W, closedRows + 1)
    discard paintVariables(full, CellArea(col: 0, row: 0, width: W,
                                          height: closedRows + 1), closed)
    ck full.trackCells(W - 1, 1, closedRows) == 0
    # The same area with the history open: the last column is a track down
    # every body row, the thumb at its top.
    var over = newStyledGrid(W, h)
    discard paintVariables(over, area, opened)
    ck over.trackCells(W - 1, 1, h - 1) == h - 1
    let atTop = over.thumbRows(W - 1, 1, h - 1)
    checkpoint("thumb rows at the top: " & $atTop)
    ck atTop.len > 0 and atTop[0] == 1
    # Scrolled to the end, the thumb ends on the last body row.
    var scrolled = opened
    scrolled.scrollTop = openRows
    var atEnd = newStyledGrid(W, h)
    discard paintVariables(atEnd, area, scrolled)
    let low = atEnd.thumbRows(W - 1, 1, h - 1)
    checkpoint("thumb rows at the end: " & $low)
    ck low.len > 0 and low[^1] == h - 1 and low[0] > atTop[0]

  test "Files: an overflowing tree paints a track whose thumb follows scrollTop; one that fits keeps its last column":
    const W = 40
    let model = initFileTreeModel(wideEntries())
    # Fits: every entry has a body row; the first's name runs to the last
    # column, which is its text, not a track.
    let tall = InHandRows + 3
    var fits = newStyledGrid(W, tall)
    discard paintFileTree(fits, CellArea(col: 0, row: 0, width: W,
                                         height: tall), model)
    ck fits.trackCells(W - 1, 1, tall - 1) == 0
    ck fits.runeAt(1, W - 1) == "x"
    # Exactly full: still no track.
    var full = newStyledGrid(W, InHandRows + 1)
    discard paintFileTree(full, CellArea(col: 0, row: 0, width: W,
                                         height: InHandRows + 1), model)
    ck full.trackCells(W - 1, 1, InHandRows) == 0
    # Overflows: the last column is the track, the name stops a cell short.
    const h = 12
    let area = CellArea(col: 0, row: 0, width: W, height: h)
    var over = newStyledGrid(W, h)
    discard paintFileTree(over, area, model)
    ck over.trackCells(W - 1, 1, h - 1) == h - 1
    ck over.runeAt(1, W - 2) == "x"
    let atTop = over.thumbRows(W - 1, 1, h - 1)
    ck atTop.len > 0 and atTop[0] == 1
    var scrolled = model
    scrolled.scrollTop = InHandRows
    var atEnd = newStyledGrid(W, h)
    discard paintFileTree(atEnd, area, scrolled)
    let low = atEnd.thumbRows(W - 1, 1, h - 1)
    checkpoint("files thumb " & $atTop & " -> " & $low)
    ck low.len > 0 and low[^1] == h - 1 and low[0] > atTop[0]
    # The last entry is on the last body row.
    ck atEnd.rowText(h - 1).contains("module_" & $(InHandRows - 1) & ".py")
    # Edit mode's flat list (`files`) scrolls the same way.
    var paths: seq[string] = @[]
    for e in wideEntries(): paths.add e.path
    var flat = newStyledGrid(W, h)
    discard paintFileTree(flat, area, initFileTreeModel(files = paths))
    ck flat.trackCells(W - 1, 1, h - 1) == h - 1

  test "VCS: an overflowing pane paints a track whose thumb follows scrollTop; one that fits keeps its last column":
    const W = 40
    let model = wideVcs()
    let total = model.vcsRows
    # Fits (the VCS pane has no heading: every row of its area is a body
    # row): no track; the first file's path runs to the last column.
    let tall = total + 2
    var fits = newStyledGrid(W, tall)
    discard paintVcsPane(fits, CellArea(col: 0, row: 0, width: W,
                                        height: tall), model)
    ck fits.trackCells(W - 1, 0, tall) == 0
    ck fits.runeAt(2, W - 1) == "x"
    # Exactly full: still no track.
    var full = newStyledGrid(W, total)
    discard paintVcsPane(full, CellArea(col: 0, row: 0, width: W,
                                        height: total), model)
    ck full.trackCells(W - 1, 0, total) == 0
    const h = 12
    let area = CellArea(col: 0, row: 0, width: W, height: h)
    var over = newStyledGrid(W, h)
    discard paintVcsPane(over, area, model)
    ck over.trackCells(W - 1, 0, h) == h
    ck over.runeAt(2, W - 2) == "x"
    let atTop = over.thumbRows(W - 1, 0, h)
    ck atTop.len > 0 and atTop[0] == 0
    var scrolled = model
    scrolled.scrollTop = total
    var atEnd = newStyledGrid(W, h)
    discard paintVcsPane(atEnd, area, scrolled)
    let low = atEnd.thumbRows(W - 1, 0, h)
    checkpoint("vcs thumb " & $atTop & " -> " & $low)
    ck low.len > 0 and low[^1] == h - 1 and low[0] > atTop[0]
    # The last row — the commit — is on the area's last row.
    ck atEnd.rowText(h - 1).contains("the last row")

suite "M71 (#838): the wheel and the track move the State, Files and VCS panes":

  test "a wheel over each pane scrolls it without focusing it first":
    require pages.outcome == foRecorded
    putEnv("CODETRACER_TUI_LAYOUT_DIR", getTempDir() / "m71-scrub-state")
    let (rt, s) = open(pages.tracePath)
    defer: s.close()
    ck rt.openTotalHistory(s).len > 100
    # Focus elsewhere: a press in the editor's text.
    let ed = rt.areaOf(paneEditor)
    s.click(rt, ed.row + 2, ed.col + ed.width div 2)
    let (hadFocus, focused) = rt.focusedPaneOf()
    checkpoint("focused " & $focused)
    ck hadFocus and focused != paneState
    # State: the wheel down, then up.
    let st = rt.areaOf(paneState)
    ck rt.app.variables.scrollTop == 0
    s.send(rt, sgr(WheelDown, st.row + 2, st.col + 4))
    ck rt.app.variables.scrollTop == CallTraceWheelRows
    s.send(rt, sgr(WheelUp, st.row + 2, st.col + 4))
    ck rt.app.variables.scrollTop == 0
    # Files.
    rt.app.fileTree = initFileTreeModel(wideEntries())
    let fa = rt.areaOf(paneFileTree)
    ck fa.height > 1
    s.send(rt, sgr(WheelDown, fa.row + 2, fa.col + 4))
    ck rt.app.fileTree.scrollTop == CallTraceWheelRows
    s.send(rt, sgr(WheelUp, fa.row + 2, fa.col + 4))
    ck rt.app.fileTree.scrollTop == 0
    # VCS: the product's source over a real repository, its tab shown.
    let repo = makeVcsRepo()
    defer: removeDir(repo.parentDir)
    let vcs = newVcsSource(repo)
    defer: vcs.close()
    vcs.refresh(rt)
    ck rt.app.vcs.files.len == InHandRows
    ck s.showVcsTab(rt)
    let va = rt.areaOf(paneVcs)
    ck va.height > 1
    s.send(rt, sgr(WheelDown, va.row + 2, va.col + 4))
    ck rt.app.vcs.scrollTop == CallTraceWheelRows
    # The pane's periodic re-read keeps the reader's place.
    vcs.refresh(rt)
    ck rt.app.vcs.scrollTop == CallTraceWheelRows
    s.send(rt, sgr(WheelUp, va.row + 2, va.col + 4))
    ck rt.app.vcs.scrollTop == 0

  test "a press on each pane's track jumps the view; its held thumb drags; the debugger stays":
    require pages.outcome == foRecorded
    let (rt, s) = open(pages.tracePath)
    defer: s.close()
    ck rt.openTotalHistory(s).len > 100
    let tick = s.session.getCurrentRRTicks()
    s.checkTrackPresses(rt, paneState, rt.app.variables.paneRows().len,
                        proc(): int = rt.app.variables.scrollTop)
    ck s.session.getCurrentRRTicks() == tick
    rt.app.fileTree = initFileTreeModel(wideEntries())
    s.checkTrackPresses(rt, paneFileTree, InHandRows,
                        proc(): int = rt.app.fileTree.scrollTop)
    let repo = makeVcsRepo()
    defer: removeDir(repo.parentDir)
    let vcs = newVcsSource(repo)
    defer: vcs.close()
    vcs.refresh(rt)
    ck s.showVcsTab(rt)
    s.checkTrackPresses(rt, paneVcs, rt.app.vcs.vcsRows,
                        proc(): int = rt.app.vcs.scrollTop)
    ck s.session.getCurrentRRTicks() == tick

suite "PLAT-51 / M71 scrubbers: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
