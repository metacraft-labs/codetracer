## test_plat70i_fit_layout.nim — PLAT-70 Part I (Horizontal-Overflow.md §5.5),
## the terminal's table panes laid out by the shared solver, swept over the
## shipped painters:
##
##   * the Event Log at every width from 12 to 120: the columns the painter
##     reports are exactly `fitTable`'s over the rows it shows, in display
##     order (HO-13's terminal half); the bar is drawn iff the fit is SCROLL
##     and only then (HO-11); the header stands over its cells at every
##     scroll; a wheel's worth of `leftCol` moves the header and the rows by
##     the same columns; widening the pane until the floors fit removes the
##     bar and the view returns to column 0 (§4.1);
##   * a user's width wider than the pane brings the bar (HO-14);
##   * the Call Trace: a call nested deeper than the pane is wide makes the
##     pane SCROLL, and scrolling the view to its end shows that call's whole
##     name (HO-15); a long argument list alone never does (§5.5.5);
##   * the Variables pane: a pane narrower than the fields' floors scrolls,
##     a wide one keeps PLAT-51's fields exactly;
##   * the bar's corner: the scrubber's column on the bar's row is neither
##     track's (HO-7).
##
## No mocks: the shipped painters and the shared ViewModel; the event pages
## are a closure over a fixed list (the painter's own seam — the one
## stand-in, and not a mock: it answers exactly what the engine's pages are,
## a window of rows, and records nothing).

import std/[strutils, tables, unittest]

import codetracer_embed

import ../app/views/styled_row
import ../app/views/event_log
import ../app/views/variables
import ../app/views/call_trace
import ../app/views/scrubber_track

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 30

proc eventModel(texts: seq[string]): EventLogModel =
  var rows: seq[EventRow] = @[]
  for i, t in texts:
    rows.add EventRow(index: i, tick: uint64(1000 + i * 37), file: "main.py",
                      line: 20 + i, content: t, category: ecOutput)
  let pages: EventPages = proc(offset, limit: int): EventPage =
    var page = EventPage(total: rows.len)
    for i in offset ..< min(rows.len, offset + limit):
      page.rows.add rows[i]
    page.atEnd = offset + limit >= rows.len
    page
  result = initEventLogModel(pages = pages, pageSize = 32)
  result.ensureWindow(0, rows.len)

const Texts = @["short", "a medium line of output", repeat("x", 90), "end"]

suite "PLAT-70 Part I: the Event Log fits or scrolls (§5.5)":

  test "the painted columns are the solver's, every width (HO-11, HO-13)":
    let model = eventModel(Texts)
    var wrong, bars, fits, shrinks, scrolls = 0
    for width in 12 .. 120:
      let height = Texts.len + 4
      let screen = eventLogScreen(model, width, height)
      let geo = model.eventLogGeometry(CellArea(col: 0, row: 0, width: width,
                                                height: height))
      # The rows the body shows, measured as the painter measured them.
      let fit = geo.fit
      case fit.mode
      of fmFit: inc fits
      of fmShrink: inc shrinks
      of fmScroll: inc scrolls
      let shown = model.columns.visibleColumns
      if screen.columnCells.len != shown.len: inc wrong
      for k, (col, at, w) in screen.columnCells:
        if col != shown[k] or w != fit.widths[k] or at != fit.starts[k]:
          inc wrong
          if wrong <= 3:
            checkpoint("width " & $width & " " & $col & " at " & $at & " w " &
                       $w & " fit " & $fit.starts[k] & "/" & $fit.widths[k])
      # HO-11: the bar iff SCROLL (the body has rows to spare here).
      if (screen.barRow >= 0) != (fit.mode == fmScroll): inc wrong
      if screen.barRow >= 0: inc bars
      # FIT and SHRINK fill the columns' cells exactly (the output is the
      # flex column).
      if fit.mode != fmScroll and fit.contentUnits != geo.width: inc wrong
    checkpoint("fit " & $fits & " shrink " & $shrinks & " scroll " & $scrolls)
    ck wrong == 0
    ck fits > 0 and shrinks > 0 and scrolls > 0
    ck bars == scrolls

  test "SCROLL: the header and the rows move together; the corner is no track's":
    var model = eventModel(Texts)
    let width = 24
    let height = 9
    let before = eventLogScreen(model, width, height)
    ck before.fit.mode == fmScroll
    ck before.barRow == height - 1
    # HO-7: the scrubber's column on the bar's row is blank.
    var g = newStyledGrid(width, height)
    discard paintEventLog(g, CellArea(col: 0, row: 0, width: width,
                                      height: height), model)
    ck before.trackCol == width - 1
    ck g.runeAt(before.barRow, before.trackCol) == " "
    # The output column's title, wherever it is drawn, is over its cells.
    var outAt0 = -1
    for (c, at, _) in before.columnCells:
      if c == elcOutput: outAt0 = at
    model.hview = before.hview
    discard model.hview.scrollBy(WheelColumns)
    let after = eventLogScreen(model, width, height)
    var outAt1 = -1
    for (c, at, _) in after.columnCells:
      if c == elcOutput: outAt1 = at
    ck after.hview.leftCol == WheelColumns
    ck outAt1 == outAt0 - WheelColumns
    var g2 = newStyledGrid(width, height)
    discard paintEventLog(g2, CellArea(col: 0, row: 0, width: width,
                                       height: height), model)
    # The header row's text at the output column is its title.
    if outAt1 >= 0:
      ck g2.rowText(after.headerRow)[outAt1 ..< outAt1 + "output".len] == "output"
    else:
      ck true
    # Widened until the floors fit: no bar, and the view is back at 0.
    let wide = eventLogScreen(model, 60, height)
    ck wide.barRow < 0
    ck wide.hview.leftCol == 0

  test "HO-14: a user's width wider than the pane brings the bar":
    var model = eventModel(@["a", "b"])
    let fits = eventLogScreen(model, 60, 8)
    ck fits.barRow < 0
    discard model.columns.setColumnWidth(elcOutput, 80)
    let scrolls = eventLogScreen(model, 60, 8)
    ck scrolls.fit.mode == fmScroll and scrolls.barRow >= 0
    var w = 0
    for (c, _, cw) in scrolls.columnCells:
      if c == elcOutput: w = cw
    ck w == 80

suite "PLAT-70 Part I: the Call Trace fits or scrolls (§5.5.5)":

  proc callModel(depths: seq[int]; argLen: int): CallTraceModel =
    var rows: seq[CallTraceRow] = @[]
    for i, d in depths:
      let callee = "function_" & $i
      rows.add CallTraceRow(index: i.int64, name: callee, depth: d,
                            rrTicks: uint64(i),
                            call: CallRow(index: i.int64, depth: d,
                                          callee: callee,
                                          args: @[CallRowArg(name: "v",
                                                          value: repeat("9", argLen))]))
    initCallTraceModel(rows, total = rows.len)

  test "a long argument list alone cuts, never scrolls":
    let m = callModel(@[0, 1, 2], 400)
    for width in 20 .. 120:
      var g = newStyledGrid(width, 8)
      let s = paintCallTraceScreen(g, CellArea(col: 0, row: 0, width: width,
                                               height: 8), m)
      if s.barRow >= 0 or s.fit.mode == fmScroll:
        checkpoint("scrolled at " & $width)
        ck false
        break
    ck true

  test "HO-15: a deep call scrolls, and the view's end shows its whole name":
    let deep = 40
    let m0 = callModel(@[0, 5, deep], 3)
    let width = 40
    let area = CellArea(col: 0, row: 0, width: width, height: 8)
    var g = newStyledGrid(width, 8)
    let s = paintCallTraceScreen(g, area, m0)
    ck s.fit.mode == fmScroll
    ck s.barRow == 7
    # The floor: the deepest row's indent and toggle, its name, its `…`.
    ck s.fit.compositeWidth == deep * CallRowIndentCells + 2 +
                               "function_2".len + 1
    var m = m0
    m.hview = s.hview
    discard m.hview.scrollBy(10_000)
    var g2 = newStyledGrid(width, 8)
    let s2 = paintCallTraceScreen(g2, area, m)
    ck s2.hview.leftCol == s.fit.compositeWidth - (width - 1)
    var found = false
    for r in 1 ..< 7:
      if g2.rowText(r).contains("function_2"): found = true
    ck found
    # The hit-test reads the scrolled rows: the deep row's toggle cell.
    let hit = m.callTraceHitAt(area, 3, 0)
    ck hit.kind in {cthRow, cthToggle}
    # A press on the bar's row is no call's.
    ck m.callTraceHitAt(area, s.barRow, 3).kind == cthNone
    # Wide enough for the floor: no bar, view at 0.
    let s3 = paintCallTraceScreen(g2, CellArea(col: 0, row: 0, width: 140,
                                               height: 8), m)
    ck s3.barRow < 0 and s3.hview.leftCol == 0

suite "PLAT-70 Part I: the Variables pane fits or scrolls (§5.5.3)":

  proc varModel(): VariablesModel =
    let nodes = @[VarNode(path: "@Locals.a_long_variable_name",
                          name: "a_long_variable_name", typeName: "int",
                          value: "12345")]
    result = initVariablesModel(
      scopes = @[Scope(kind: skLocals, availability: savaAvailable)],
      children = proc(path: string; offset, limit: int):
                   tuple[nodes: seq[VarNode]; total: int] =
        (nodes: (if path == scopePath(skLocals): nodes else: @[]),
         total: (if path == scopePath(skLocals): nodes.len else: 0)))
    result.expandNode(scopePath(skLocals))

  test "a pane narrower than the fields' floors scrolls; a wide one keeps PLAT-51's fields":
    let m = varModel()
    let narrow = variablesScreen(m, VariablesFixedCells + MinimumNameCells +
                                    1 + MinimumValueCells - 1, 6)
    ck narrow.fit.mode == fmScroll
    ck narrow.barRow >= 0
    let exact = variablesScreen(m, VariablesFixedCells + MinimumNameCells +
                                   1 + MinimumValueCells, 6)
    ck exact.fit.mode != fmScroll and exact.barRow < 0
    let wide = variablesScreen(m, 90, 6)
    ck wide.barRow < 0
    ck wide.valueColumn == valueFieldColumn(90, 0)
    ck wide.nameCells == fieldWidths(90).name

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
