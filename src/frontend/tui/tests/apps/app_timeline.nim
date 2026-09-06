## app_timeline.nim — CTUI-8 snapshot app: the scrubber, the event log and the
## post-hoc tracepoint dialog.
##
## One component tree, exported so the Tier-1 half of
## `tests/real_terminal/test_real_timeline.nim` composites the SAME proc in
## process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime, the frame barrier and the
## input framing.
##
## ## WHY THE DATA IS A CONSTANT AND NOT A FIXTURE
##
## A snapshot app is a BINARY spawned in a pty; it cannot open a `.ct` container
## because `app/`'s facade withholds `headless_session` and `dual_snap` compiles
## this file with the Tier-1 flags. Same arrangement as CTUI-5's
## `app_source_pane.nim`, CTUI-6's `app_call_stack.nim` and CTUI-7's
## `app_variables.nim`, for the same reason: what a real recording establishes is
## asserted at Tier 1, where a session exists; what a TERMINAL does with a
## painted screen is asserted here.
##
## THE CONSTANT IS `noir_space_ship`'S OWN SHAPE, measured on 2026-09-06 through
## a real `replay-server`: 1314 as the last tick, the first six recorded call
## boundaries `@[0, 9, 18, 22, 43, 59]` with their depths, and the first four
## recorded events with their ticks and their text. So the screen a terminal
## parses is the screen a real recording produces, and the numbers are traceable
## to a measurement rather than invented to look plausible.
##
## ## THE SCREEN CARRIES ALL FIVE GLYPHS AT ONCE
##
## `[`, `]`, `▲`, `◆` and `█` are all on the bar, at cells the model's own
## arithmetic decides, because the Tier-2 case asserts each one's COLOUR
## absolutely and a screen with four of them could not.
##
## ## IT IS DRIVEN BY A REAL MOUSE
##
## `handleInput` decodes SGR-1006 through `app/input/timeline_keys` and moves
## the needle to the clicked ratio. That is §4.4's contract, it is untestable in
## process, and it is why this app has an input handler at all.
##
## ## THE TIER-1 HALF MUST NOT DRIVE INPUT
##
## `buildTree` reads `currentTick`, which the CHILD's input handler mutates.
## `runDualSnap`'s Tier-1 half runs in the test process and must therefore see
## the pristine `InitialTick` — which it does, because no suite calls
## `handleInput` in process. A test that did would compare a driven Tier-1
## screen against an undriven Tier-2 one, which is the "two different programs"
## failure `dual_snap.newestSourceTime`'s header is about.

import isonim_tui

import ../../app/input/timeline_keys
import ../../app/views/event_log
import ../../app/views/timeline_bar
import ../../app/views/tracepoint_manager

const
  MaxTick* = 1314'u64
    ## `noir_space_ship`'s `maxRRTicks`, measured through `ct/event-load`.
  InitialTick* = 320'u64
    ## A tick the Tier-1 suites really seek to on that recording.
  SamplePath* = "/opt/ctui8/noir_space_ship/src/shield.nr"
  MainPath* = "/opt/ctui8/noir_space_ship/src/main.nr"

  BarRows* = TimelineBarRows
  DialogWidth* = 60
  DialogHeight* = 9

  TracepointExpression* = "log(damage)"
  TracepointLine* = 58

proc sampleSpans*(): seq[TimelineSpan] =
  ## The first six recorded calls of `noir_space_ship`, with the ticks and
  ## depths `ct/load-calltrace-section` really answered.
  @[
    TimelineSpan(startTick: 0'u64, endTick: 8'u64, depth: 0, name: "main"),
    TimelineSpan(startTick: 9'u64, endTick: 17'u64, depth: 1,
                 name: "iterate_asteroids"),
    TimelineSpan(startTick: 18'u64, endTick: 21'u64, depth: 2,
                 name: "calculate_damage"),
    TimelineSpan(startTick: 22'u64, endTick: 42'u64, depth: 3,
                 name: "calculate_remaining_shield_pct"),
    TimelineSpan(startTick: 43'u64, endTick: 58'u64, depth: 2,
                 name: "calculate_shield_regeneration"),
    TimelineSpan(startTick: 59'u64, endTick: 79'u64, depth: 2,
                 name: "status_report"),
  ]

proc sampleHits*(): seq[TracepointHit] =
  ## Two post-hoc tracepoint hits, in the shape `ct/tracepoint-results` answers:
  ## a tick and the locals the expression named.
  @[
    TracepointHit(tick: 71'u64, path: SamplePath, line: TracepointLine,
                  values: @[("damage", "100")]),
    TracepointHit(tick: 900'u64, path: SamplePath, line: TracepointLine,
                  values: @[("damage", "2000")]),
  ]

proc sampleEntries*(): seq[TracepointEntry] =
  @[
    TracepointEntry(
      id: 0,
      draft: initTracepointDraft(path = SamplePath, line = TracepointLine,
                                 column = 0,
                                 expression = TracepointExpression,
                                 enabled = true),
      state: tpsVerified, boundLine: TracepointLine, boundColumn: 0,
      hits: sampleHits()),
  ]

proc sampleMarks*(): seq[TimelineMark] =
  ## The diamonds, DERIVED from the tracepoint entries rather than written
  ## twice, so the dialog and the bar cannot disagree about where they are.
  marksFrom(sampleEntries())

proc sampleEvents*(): seq[EventRow] =
  ## The first four recorded events of `noir_space_ship`, byte for byte as
  ## `ct/event-load` answered them.
  @[
    EventRow(index: 0, tick: 7'u64, file: MainPath, line: 13,
             content: "Positive Test Case\n", category: ecOutput,
             kindId: KindWrite),
    EventRow(index: 1, tick: 66'u64, file: SamplePath, line: 54,
             content: "----- iteration 0 -----\n", category: ecOutput,
             kindId: KindWrite),
    EventRow(index: 2, tick: 71'u64, file: SamplePath, line: 58,
             content: "Damage: 100\n", category: ecOutput, kindId: KindWrite),
    EventRow(index: 3, tick: 76'u64, file: SamplePath, line: 61,
             content: "Regenerated 100 energy\n", category: ecOutput,
             kindId: KindWrite),
  ]

proc samplePages*(): EventPages =
  ## A seam over the constant above, with the same `(offset, limit)` contract
  ## the real `ct/event-load` seam has.
  let rows = sampleEvents()
  result = proc(offset, limit: int): EventPage =
    result = EventPage(rows: @[], atEnd: true)
    let first = max(0, offset)
    let last = min(rows.len, first + max(0, limit))
    for i in first ..< last:
      result.rows.add rows[i]
    result.atEnd = last >= rows.len

var currentTick = InitialTick
var lastCols = 80
var lastRows = 24

proc barModelFor*(tick: uint64): TimelineBarModel =
  initTimelineBarModel(
    minTick = 0'u64, maxTick = MaxTick, currentTick = tick,
    boundsKnown = true, spans = sampleSpans(), marks = sampleMarks())

proc logModelFor*(tick: uint64): EventLogModel =
  result = initEventLogModel(pages = samplePages(), pageSize = 16,
                             currentTick = tick)
  result.ensureWindow(0, 16)
  result.selected = 2

proc dialogModel*(): TracepointManagerModel =
  result = initTracepointManagerModel(open = true, entries = sampleEntries(),
                                      draft = initTracepointDraft(
                                        path = SamplePath, line = 54,
                                        expression = "log(iteration)"))
  result.selected = 0

proc barAreaFor(cols: int): CellArea =
  CellArea(col: 0, row: 0, width: cols, height: BarRows)

proc paint(g: var StyledGrid; tick: uint64;
           cols, rows: int): TimelineBarScreen =
  ## The whole screen: the scrubber on top, the event log below it, and the
  ## tracepoint dialog in the bottom-left corner.
  result = paintTimelineBar(g, barAreaFor(cols), barModelFor(tick))
  let logHeight = max(1, rows - BarRows - DialogHeight)
  discard paintEventLog(
    g, CellArea(col: 0, row: BarRows, width: cols, height: logHeight),
    logModelFor(tick))
  if rows > BarRows + logHeight:
    discard paintTracepointManager(
      g, CellArea(col: 0, row: BarRows + logHeight,
                  width: min(DialogWidth, cols),
                  height: rows - BarRows - logHeight),
      dialogModel())

proc screenFor*(tick: uint64; cols, rows: int): TimelineBarScreen =
  ## The scrubber's screen at this geometry — where the needle, the diamonds
  ## and the track are.
  var g = newStyledGrid(cols, rows)
  paint(g, tick, cols, rows)

proc logScreenFor*(cols, rows: int): EventLogScreen =
  ## The event log's own screen, at the rectangle `paint` gives it.
  var g = newStyledGrid(cols, rows)
  let logHeight = max(1, rows - BarRows - DialogHeight)
  paintEventLog(
    g, CellArea(col: 0, row: BarRows, width: cols, height: logHeight),
    logModelFor(currentTick))

proc dialogScreenFor*(cols, rows: int): TracepointManagerScreen =
  var g = newStyledGrid(cols, rows)
  let logHeight = max(1, rows - BarRows - DialogHeight)
  paintTracepointManager(
    g, CellArea(col: 0, row: BarRows + logHeight, width: min(DialogWidth, cols),
                height: max(0, rows - BarRows - logHeight)),
    dialogModel())

proc paneTextFor*(tick: uint64; cols, rows: int): seq[string] =
  ## The whole screen as plain text, one string per row — what the cross-tier
  ## case's painted-cell floor is computed from, and what a Tier-2 `regionText`
  ## read is compared against.
  var g = newStyledGrid(cols, rows)
  discard paint(g, tick, cols, rows)
  result = @[]
  for row in 0 ..< rows:
    result.add g.rowText(row)

proc treeFor*(r: TerminalRenderer; tick: uint64;
              cols, rows: int): TerminalNode =
  var g = newStyledGrid(cols, rows)
  discard paint(g, tick, cols, rows)
  var rowsOut: seq[StyledRow] = @[]
  for row in 0 ..< rows:
    rowsOut.add g.rowSpans(row)
  styledRowsTree(r, rowsOut)

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  ## The whole screen. `step` is ignored: this app is driven by real mouse
  ## reports, not by F10, and a builder that ignores its step paints the same
  ## tree however often F10 arrives.
  lastCols = cols
  lastRows = rows
  treeFor(r, currentTick, cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  ## The un-stepped shape, for `runDualSnap`'s sized overload.
  buildTree(r, cols, rows, 0)

proc handleInput*(token: string): bool =
  ## One input token from the runtime. Returns whether to repaint.
  ##
  ## CHILD-SIDE ONLY: see this module's header on why no Tier-1 half may call
  ## this.
  let screen = screenFor(currentTick, lastCols, lastRows)
  let model = barModelFor(currentTick)
  var state = initTimelineKeyState()
  let targets = initTimelineTargets(
    callBoundaries = (block:
      var ticks: seq[uint64] = @[]
      for span in sampleSpans(): ticks.add span.startTick
      ticks),
    mutations = @[],
    minTick = 0'u64, maxTick = MaxTick)
  let outcome = applyToken(state, token, screen, model, targets, currentTick)
  if outcome.action == tkaSeek:
    currentTick = outcome.tick
    return true
  false

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an unused
  # runtime with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams(),
    input = handleInput))
