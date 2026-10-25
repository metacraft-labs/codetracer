## NOT-A-TEST-LANE-FILE: this is the terminal's Test Results PANE — production
## frontend code named after the test results it draws, which is why its
## basename matches the guard's `test_*` name arm. It imports no `unittest`
## and declares no `suite`/`test` block. It is asserted by
## `src/frontend/tui/tests/test_plat53_test_results.nim` (the `tui` lane) and
## `src/frontend/tui/tests/real_terminal/test_plat53_test_results_pty.nim`
## (`tui-real-terminal`).

## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/test_results_source.paneModelOf` turns the shared
## `TestResultsVM` into the model below).
##
## app/views/test_results_pane.nim — PLAT-53. **THE TEST RESULTS PANE, drawn.**
##
## The desktop's pane (`viewmodel/views/isonim_test_results_view.nim`) draws a
## headline beside the ▶, then one row per test — its mark, name, location,
## duration and the `⟳` / `⏵` controls — with a failed test's message under
## it, then the failure block, the absence line and the empty state. This pane
## draws the same parts in the same order with the same words, every one of
## which is the ViewModel's (`Test-Results-Pane.md` §8.4):
##
##     1 passed, 1 failed                                         ▶
##     ✓ test_passes          src/main.nr:5               12ms ⟳ ⏵
##     ✗ test_fails           src/main.nr:10              10ms ⟳ ⏺⏵
##       Failed assertion
##
## The columns are `table_fit.testResultsFit`: the name and the location share
## the room 1.8 : 1 as the desktop's `fr` tracks do, a cut cell ends in `…`
## (`table_overflow.fitCell`), the duration is never cut. Everything below the
## header is ONE list of rows (a message, a failure line, the absence and the
## empty state wrapped to the pane), so a press and the drawing are one
## layout, and the rightmost column is its scrollbar when it overflows
## (Scrollbar-Scrubbers.md: a list's bar moves the VIEW).

import std/strutils

import codetracer_embed

from ../formatters/type_formatters import terminalMeasure
import ../layout/profile
import ../layout/project
import ./styled_row
import ./scrubber_track

export styled_row, profile, scrubber_track

type
  TestsTone* = enum
    ## How a row's mark is coloured (the desktop's `.passed` / `.failed` /
    ## `.errored` / `.not-run` rules in `ns9_panes.styl`).
    ttoOther      ## running, skipped, cancelled: the ordinary text colour
    ttoPassed     ## the success colour
    ttoFailed     ## failed or errored: the error colour
    ttoNotRun     ## the whole row muted (`opacity: 0.7`)

  TestsPaneControl* = object
    ## One control — the ▶, a row's `⟳` or `⏵` — as the ViewModel decides it.
    label*: string
    enabled*: bool
    title*: string
      ## What it does, or why it does nothing (the ViewModel's title).
    mode*: string
      ## `⏵`: its `OpenButtonMode` (`open-existing`, `record-and-open`, …).

  TestsPaneRow* = object
    testId*, selector*: string
    state*: string
      ## The row's `TestResultsRowState` (`passed`, `not-run`, …).
    tone*: TestsTone
    mark*, name*, where*, duration*: string
    recordingId*: string
    refresh*, open*: TestsPaneControl

  TestsPaneLineKind* = enum
    tlRow, tlMessage, tlFailure, tlAbsence, tlEmpty

  TestsPaneLine* = object
    ## One entry of the list below the header (`TestResultsVM.displayRows`).
    kind*: TestsPaneLineKind
    row*: int
      ## tlRow / tlMessage: the index into `rows`; -1 otherwise.
    text*: string

  TestResultsPaneModel* = object
    loaded*: bool
      ## Whether a host supplied the pane at all.
    headline*: string
    run*: TestsPaneControl
    rows*: seq[TestsPaneRow]
    lines*: seq[TestsPaneLine]
    selected*: int
      ## The selected row's index into `rows`, -1 for none.
    scrollTop*: int
      ## The first list row shown (of the WRAPPED list).

  TestsPaneTargetKind* = enum
    tpNone, tpRun, tpRow, tpRefresh, tpOpen, tpTrack, tpText

  TestsPaneTarget* = object
    kind*: TestsPaneTargetKind
    row*: int
      ## tpRow / tpRefresh / tpOpen: the index into `rows`.

  TestsPaneScreen* = object
    listTop*, listRows*: int
      ## The rows the list occupies.
    trackCol*: int
      ## The scrollbar's column, -1 when the list fits.
    runCol*: int
      ## Where the ▶ was drawn (row `area.row`), -1 when it did not fit.
    fit*: TableFit
      ## The columns, as drawn.
    tableLeft*: int
      ## The table's first column.
    wrapped*: seq[TestsPaneLine]
      ## The list as painted: each text line wrapped to the pane.
    painted*: seq[string]
      ## Every painted list row's text, in order (for the suites).

const
  TestsMarkCells* = 1
  TestsActionsCells* = 4
    ## `⟳`, a space, then `⏵` — two cells for `⏺⏵` / `⟳⏵`.
  TestsGapCells* = 1
  RunLabel* = "▶"
    ## The ▶ when the model names none (the host passes the ViewModel's
    ## `RunButtonLabel`).
  TestsHeadlineStyle = CellStyle(role: srChromeMuted)
  TestsRunStyle = CellStyle(role: srChromeText, bold: true)
  TestsDisabledStyle = CellStyle(role: srChromeMuted, dim: true)
  TestsActionStyle = CellStyle(role: srChromeMuted)
  TestsNameStyle = CellStyle(role: srChromeText)
  TestsMutedStyle = CellStyle(role: srChromeMuted)
  TestsErrorStyle* = CellStyle(role: srChromeError)
    ## The desktop's `colors-ui-text-error-primary`: a failed or errored
    ## mark, a message, a failure line.
  TestsSuccessStyle* = CellStyle(role: srChromeSuccess)
    ## The desktop's `colors-ui-text-success-primary`: a passed mark.
  TestsSelectedSurface = srSurfaceSelection

proc markStyle(tone: TestsTone): CellStyle =
  case tone
  of ttoPassed: TestsSuccessStyle
  of ttoFailed: TestsErrorStyle
  of ttoNotRun: TestsMutedStyle
  of ttoOther: TestsNameStyle

proc durationCells(model: TestResultsPaneModel): int =
  for r in model.rows:
    result = max(result, cellWidthOf(r.duration))

proc columnsFor*(model: TestResultsPaneModel; width: int): TableFit =
  ## The five columns in a list `width` cells wide.
  testResultsFit(TestsMarkCells, model.durationCells, TestsActionsCells,
                 width, TestsGapCells)

proc wrappedLines*(model: TestResultsPaneModel; width: int):
    seq[TestsPaneLine] =
  ## The list at `width`: a row is one line; a message is indented under its
  ## row's name (the desktop's `grid-column: 2 / -1`) and wrapped, and the
  ## failure, absence and empty lines are wrapped to the pane.
  let indent = TestsMarkCells + TestsGapCells
  for line in model.lines:
    case line.kind
    of tlRow:
      result.add line
    of tlMessage:
      for part in wrapCells(line.text, max(1, width - indent), terminalMeasure):
        result.add TestsPaneLine(kind: tlMessage, row: line.row, text: part)
    of tlFailure, tlAbsence, tlEmpty:
      for part in wrapCells(line.text, max(1, width), terminalMeasure):
        result.add TestsPaneLine(kind: line.kind, row: -1, text: part)

proc clampTestsTop*(total, top, listRows: int): int =
  clamp(top, 0, max(0, total - max(1, listRows)))

proc listGeometry*(area: CellArea): tuple[top, rows: int] =
  ## The list's rows inside `area`: below the header row.
  (area.row + 1, max(0, area.height - 1))

proc listWidth*(area: CellArea; total, listRows: int): int =
  if total > listRows: max(0, area.width - ScrubberTrackCells) else: area.width

proc paintCell(g: var StyledGrid; row, col, width: int; text: string;
               style: CellStyle): string =
  ## `text` in a column `width` cells wide, cut with `…`.
  if width <= 0:
    return ""
  let cell = fitCell(text, width, terminalMeasure)
  g.paint(row, col, cell.text, style)
  cell.text

proc paintTestResults*(g: var StyledGrid; area: CellArea;
                       model: TestResultsPaneModel): TestsPaneScreen =
  ## The pane into `area` (the rows below its tab strip) and nowhere else.
  result = TestsPaneScreen(trackCol: -1, runCol: -1)
  if area.width <= 0 or area.height <= 0:
    return
  # Row 0: the headline, and the ▶ at the right edge.
  let runCells = 3
  var headlineCells = area.width
  if area.width > runCells + 2:
    result.runCol = area.col + area.width - runCells + 1
    headlineCells = area.width - runCells
    g.paint(area.row, result.runCol,
            (if model.run.label.len > 0: model.run.label else: RunLabel),
            if model.run.enabled: TestsRunStyle else: TestsDisabledStyle)
  discard g.paintCell(area.row, area.col, headlineCells, model.headline,
                      TestsHeadlineStyle)
  let (top, rows) = listGeometry(area)
  result.listTop = top
  result.listRows = rows
  if rows <= 0:
    return
  # The list's width depends on whether it overflows, which depends on the
  # wrap, which depends on the width: wrap at the full width first, and again
  # without the scrollbar's column only when that overflows.
  var width = area.width
  var lines = model.wrappedLines(width)
  if lines.len > rows:
    width = max(0, area.width - ScrubberTrackCells)
    lines = model.wrappedLines(width)
    result.trackCol = area.col + area.width - ScrubberTrackCells
  result.wrapped = lines
  result.tableLeft = area.col
  let fit = model.columnsFor(width)
  result.fit = fit
  let first = clampTestsTop(lines.len, model.scrollTop, rows)
  for k in 0 ..< rows:
    let i = first + k
    if i >= lines.len:
      break
    let line = lines[i]
    let y = top + k
    case line.kind
    of tlRow:
      let r = model.rows[line.row]
      if line.row == model.selected:
        g.fillSurface(y, area.col, width, 1, TestsSelectedSurface)
      let name = if r.tone == ttoNotRun: TestsMutedStyle else: TestsNameStyle
      var text = ""
      template col(i: int): int = area.col + fit.starts[i]
      text.add g.paintCell(y, col(0), fit.widths[0], r.mark,
                           markStyle(r.tone))
      text.add " " & g.paintCell(y, col(1), fit.widths[1], r.name, name)
      text.add " " & g.paintCell(y, col(2), fit.widths[2], r.where,
                                 TestsMutedStyle)
      # The duration is right-aligned in its column, as a number reads.
      let d = r.duration
      let pad = max(0, fit.widths[3] - cellWidthOf(d))
      g.paint(y, col(3) + pad, d, TestsMutedStyle)
      text.add " " & d
      let a = col(4)
      g.paint(y, a, r.refresh.label,
              if r.refresh.enabled: TestsActionStyle else: TestsDisabledStyle)
      g.paint(y, a + 2, r.open.label,
              if r.open.enabled: TestsActionStyle else: TestsDisabledStyle)
      text.add " " & r.refresh.label & " " & r.open.label
      result.painted.add text
    of tlMessage:
      # Already wrapped to the column, and drawn AS WRITTEN — the desktop's
      # `white-space: pre-wrap` keeps a stack trace's indentation, which a
      # table cell's collapse (`fitCell`) would lose.
      let indent = TestsMarkCells + TestsGapCells
      let t = truncateToCells(line.text, max(0, width - indent))
      g.paint(y, area.col + indent, t, TestsErrorStyle)
      result.painted.add spaces(indent) & t
    of tlFailure:
      let t = truncateToCells(line.text, width)
      g.paint(y, area.col, t, TestsErrorStyle)
      result.painted.add t
    of tlAbsence, tlEmpty:
      let t = truncateToCells(line.text, width)
      g.paint(y, area.col, t, TestsMutedStyle)
      result.painted.add t
  if result.trackCol >= 0:
    g.paintVerticalScrubber(result.trackCol, top, rows,
      scrubberModel(lines.len, first, rows))

proc testsTargetAt*(model: TestResultsPaneModel; screen: TestsPaneScreen;
                    area: CellArea; row, col: int): TestsPaneTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  if area.width <= 0 or not area.contains(row, col):
    return TestsPaneTarget(kind: tpNone, row: -1)
  if row == area.row:
    if screen.runCol >= 0 and col >= screen.runCol - 1 and
       col <= screen.runCol + 1:
      return TestsPaneTarget(kind: tpRun, row: -1)
    return TestsPaneTarget(kind: tpNone, row: -1)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row >= screen.listTop and row < screen.listTop + screen.listRows:
    return TestsPaneTarget(kind: tpTrack, row: -1)
  if row < screen.listTop or row >= screen.listTop + screen.listRows:
    return TestsPaneTarget(kind: tpNone, row: -1)
  let i = clampTestsTop(screen.wrapped.len, model.scrollTop,
                         screen.listRows) + (row - screen.listTop)
  if i < 0 or i >= screen.wrapped.len:
    return TestsPaneTarget(kind: tpNone, row: -1)
  let line = screen.wrapped[i]
  case line.kind
  of tlRow:
    if screen.fit.starts.len == TestColumnNames.len:
      let a = screen.tableLeft + screen.fit.starts[4]
      if col == a:
        return TestsPaneTarget(kind: tpRefresh, row: line.row)
      if col >= a + 2 and col < a + TestsActionsCells:
        return TestsPaneTarget(kind: tpOpen, row: line.row)
    TestsPaneTarget(kind: tpRow, row: line.row)
  of tlMessage:
    TestsPaneTarget(kind: tpRow, row: line.row)
  of tlFailure, tlAbsence, tlEmpty:
    TestsPaneTarget(kind: tpText, row: -1)

proc listRowOf*(screen: TestsPaneScreen; row: int): int =
  ## The wrapped list row of test `row`, -1 when it is not listed.
  for i, line in screen.wrapped:
    if line.kind == tlRow and line.row == row:
      return i
  -1

proc revealRow*(model: TestResultsPaneModel; screen: TestsPaneScreen;
                row: int): int =
  ## The scroll top that keeps test `row` in view.
  let at = screen.listRowOf(row)
  let rows = max(1, screen.listRows)
  let top = clampTestsTop(screen.wrapped.len, model.scrollTop, rows)
  if at < 0: top
  elif at < top: at
  elif at >= top + rows: at - rows + 1
  else: top
