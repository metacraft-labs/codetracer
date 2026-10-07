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
## Everything through the product's own entry points (`handleToken` with the
## bytes a terminal sends, `applyOutcome` as the shipped loop runs it,
## `shellScreenOf` for the frame). No mocks: the state directory is a scratch
## one (`CODETRACER_TUI_LAYOUT_DIR`), the engine and the recording are real.

import std/[os, strutils, unicode, unittest]

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
import ../app/layout/profile
import ../host/tui_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 50

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
    ck rt.app.listScrub.active
    var motions = 0
    for r in sc.trackTop .. sc.trackTop + sc.trackRows - 1:
      s.send(rt, sgr(0, r, sc.trackCol, motion = true))
      inc motions
      tops.add rt.app.eventLog.scrollTop
    s.send(rt, sgr(0, sc.trackTop + sc.trackRows - 1, sc.trackCol,
                   release = true))
    ck not rt.app.listScrub.active
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
    ck rt.app.listScrub.active and rt.app.listScrub.pane == paneCalltrace
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

echo "CHECKS ", countedAssertions
