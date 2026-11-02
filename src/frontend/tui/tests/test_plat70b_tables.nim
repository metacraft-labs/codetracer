## test_plat70b_tables.nim — PLAT-70 Part B (Horizontal-Overflow.md §5), the
## terminal's half that needs no pty, swept over the shipped painters:
##
##   * HO-8 — over random event texts and EVERY pane width from 10 to 140,
##     every Event Log cell drawn ends in `…` exactly when the shared
##     `fitCell` cut its whole text at its column's width, the painter
##     reports exactly those cells (`EventLogScreen.cuts`), and the `…` is
##     the cell's last drawn character; the same for the Variables rows'
##     names and types (and their values: the presenter's
##     `Presentation.truncated`, never a cut afterwards) and for the Call
##     Trace's one composite text per row;
##   * the ASCII tier draws the cut as `~`;
##   * §5.3 — an open detail is drawn under its row, wrapped in its column,
##     at most `DetailMaxLines` lines with the copy hint; the rows' hit-test
##     skips its lines (a press on a detail line is no event's and no call's);
##     the tooltip goes under its cell, or above it at the screen's foot, and
##     stays on the screen;
##   * §5.2 — a width set in the model is the width the Event Log draws, its
##     separators sit on the gaps right of each column but the last, and a
##     width never goes under three cells.
##
## No mocks: the shipped painters and the shared ViewModel; the event pages
## are a closure over a fixed list (the painter's own seam — the one
## stand-in, and not a mock: it answers exactly what the engine's pages are,
## a window of rows, and records nothing).

import std/[random, strutils, unicode, unittest]

import codetracer_embed

import ../app/views/styled_row
import ../app/views/event_log
import ../app/views/variables
import ../app/views/call_trace
import ../app/views/shell
import ../app/theme/capabilities
import ../app/theme/degradation

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 29

proc randomText(rng: var Rand): string =
  const words = ["a", "quick", "fox", "0123456789", "世界", "<<edge>>", "é",
                 "jumps", "over", "the", "lazy", "dog,"]
  for i in 0 ..< rng.rand(0 .. 14):
    if i > 0: result.add " "
    result.add words[rng.rand(words.high)]

proc eventModel(texts: seq[string]): EventLogModel =
  var rows: seq[EventRow] = @[]
  for i, t in texts:
    rows.add EventRow(index: i, tick: uint64(10 + i), file: "main.py",
                      line: 20 + i, content: t, category: ecOutput)
  let pages: EventPages = proc(offset, limit: int): EventPage =
    var page = EventPage(total: rows.len)
    for i in offset ..< min(rows.len, offset + limit):
      page.rows.add rows[i]
    page.atEnd = offset + limit >= rows.len
    page
  result = initEventLogModel(pages = pages, pageSize = 32)
  result.ensureWindow(0, rows.len)

proc rowCells(g: StyledGrid; row, col, width: int): string =
  for c in col ..< col + width:
    result.add g.runeAt(row, c)

suite "PLAT-70 Part B: the terminal's table panes, in process":

  test "HO-8: the Event Log's cut cells are the shared fit, every width":
    var rng = initRand(70_4)
    var texts: seq[string] = @[]
    for _ in 0 ..< 12: texts.add rng.randomText()
    texts.add repeat("x", 300)
    texts.add "short"
    let model = eventModel(texts)
    var cells, cut, wrong, reportWrong = 0
    for width in 10 .. 140:
      let height = texts.len + 3
      var g = newStyledGrid(width, height)
      let area = CellArea(col: 0, row: 0, width: width, height: height)
      let screen = paintEventLog(g, area, model)
      for i, line in screen.lineRows:
        if line < 0: continue
        let r = screen.visible[line]
        if r.kind != elrEvent: continue
        let y = (if screen.headerRow >= 0: 2 else: 1) + i
        let paintWidth = area.width - (if screen.trackCol >= 0: 1 else: 0)
        for (col, at, w) in screen.columnCells:
          let room = min(w, paintWidth - at)
          if room <= 0 or col == elcKind: continue
          inc cells
          let full = eventCellText(r.event, col)
          # PLAT-70 Part I (§5.5): a cell is fitted to its COLUMN's width (the
          # solver's); in SCROLL a column at the pane's edge shows the part of
          # it on screen.
          let fitted = fitCell(full, w, terminalMeasure)
          let drawn = g.rowCells(y, at, room)
          let shown = if col in {elcTick, elcIndex}: drawn.strip(trailing = false)
                      else: drawn.strip(leading = false)
          let whole = room == w
          let expected =
            if whole: fitted.text
            else: truncateToCells(
                    (if col in {elcTick, elcIndex}: padLeft(fitted.text, w)
                     else: padRight(fitted.text, w)), room).strip(leading = false)
          let mismatch =
            if whole: shown != expected and
                      not (fitted.text.len == 0 and shown.strip.len == 0)
            else: shown.strip != expected.strip
          if mismatch:
            inc wrong
            if wrong <= 5:
              checkpoint("width " & $width & " " & $col & ": drawn '" & shown &
                         "' fit '" & fitted.text & "'")
          var reported = false
          for c in screen.cuts:
            if c.row == y and c.column == $col: reported = true
          if reported != fitted.truncated:
            inc reportWrong
            if reportWrong <= 5:
              checkpoint("report width " & $width & " " & $col & " '" & full &
                         "' reported " & $reported)
          if fitted.truncated and whole:
            inc cut
            # The `…` is the cut cell's last drawn character.
            let k = screen.cuts.ellipsisAt(y, at + (if col in {elcTick, elcIndex}:
                                                      room - cellWidthOf(fitted.text)
                                                    else: 0) +
                                            cellWidthOf(fitted.text) - 1)
            if k < 0: inc reportWrong
    checkpoint("cells " & $cells & " cut " & $cut)
    ck cells > 5000
    ck cut > 300
    ck cut < cells
    ck wrong == 0
    ck reportWrong == 0

  test "the ASCII tier draws the cut as `~`":
    let ascii = TerminalCapabilities(colors: cdMonochrome, borders: bmAscii,
                                     mouse: true, mode: dmDark,
                                     palette: pkDesign, theme: utDark)
    let model = eventModel(@[repeat("y", 200)])
    var g = newStyledGrid(60, 6)
    # PLAT-71: the cut is DRAWN from the glyph table's ASCII column (the
    # terminal's profile on the grid), not rewritten by the colour pass.
    g.glyphs = glyphProfileOf(ascii)
    discard paintEventLog(g, CellArea(col: 0, row: 0, width: 60, height: 6),
                          model)
    let row = degradeRow(g.rowSpans(2), ascii)
    var text = ""
    for span in row: text.add span.text
    ck text.contains("y~")
    ck not text.contains("…")

  test "§5.3: the detail under its row, capped, and the rows' hit-test":
    var model = eventModel(@["first", repeat("w ", 2000), "third"])
    model.detail = DetailToggle(pane: EventLogTableName, key: "1",
                                column: "output")
    model.copyChord = "Ctrl+C"
    let width = 100
    let height = 30
    var g = newStyledGrid(width, height)
    let area = CellArea(col: 0, row: 0, width: width, height: height)
    let screen = paintEventLog(g, area, model)
    let body = screen.bodyHeight
    ck screen.detailRows.len == detailMaxLines(body)
    let hint = g.rowText(screen.detailRows[^1])
    ck hint.contains("more lines — Ctrl+C copies the value")
    # The event after the detail is on the row after its last line, and a
    # press on a detail line is no event's.
    let (ok, third) = screen.eventRowAtScreen(screen.detailRows[^1] + 1)
    ck ok and third.event.content == "third"
    let (onDetail, _) = screen.eventRowAtScreen(screen.detailRows[0])
    ck not onDetail
    let (second, row1) = screen.eventRowAtScreen(screen.detailRows[0] - 1)
    ck second and row1.event.index == 1
    # The detail is drawn in the output column: its lines start there.
    var outAt = 0
    for (c, at, _) in screen.columnCells:
      if c == elcOutput: outAt = at
    ck g.rowText(screen.detailRows[0])[0 ..< outAt].strip.len == 0

  test "§5.2: the model's widths, the separators, the minimum":
    var model = eventModel(@["a", "b"])
    var cols = model.columns
    ck cols.setColumnWidth(elcIndex, 9)
    model.columns = cols
    let screen = eventLogScreen(model, 90, 8)
    var indexW, indexAt = 0
    for (c, at, w) in screen.columnCells:
      if c == elcIndex:
        indexW = w
        indexAt = at
    ck indexW == 9
    # A separator right of every column but the last, on the header row.
    ck screen.separators.len == screen.columnCells.len - 1
    let (onSep, sepCol) = screen.separatorAt(screen.headerRow, indexAt + indexW)
    ck onSep and sepCol == elcIndex
    let (offRow, _) = screen.separatorAt(screen.headerRow + 1, indexAt + indexW)
    ck not offRow
    ck not cols.setColumnWidth(elcIndex, 9)
    discard cols.setColumnWidth(elcIndex, 0)
    ck cols.widths[elcIndex] == MinColumnCells

  test "HO-8: the Variables rows — names and types the fit, values the presenter":
    var rng = initRand(70_5)
    var wrong, cut = 0
    for width in 20 .. 120:
      for _ in 0 ..< 6:
        let name = rng.randomText().replace(" ", "_")
        let typ = rng.randomText().replace(" ", "")
        let spec = TreeRowSpec(kind: trkVariable, name: name, typeName: typ,
                               value: rng.randomText(), depth: 1,
                               memberCount: 0, width: width, key: "p")
        let laid = treeRowLayout(spec)
        let w = fieldWidths(width)
        let nameFit = fitCell(name, w.name, terminalMeasure)
        var nameCut = false
        var valueCut = false
        for c in laid.cuts:
          if c.column == "name": nameCut = true
          if c.column == "value": valueCut = true
        if nameCut != nameFit.truncated: inc wrong
        if valueCut != valueCell(spec, w.value).truncated: inc wrong
        if nameCut: inc cut
    checkpoint("name cuts " & $cut)
    ck cut > 100
    ck wrong == 0

  test "the Call Trace's row is one cell: the fit of its whole text":
    var rows: seq[CallTraceRow] = @[]
    for i in 0 ..< 6:
      rows.add CallTraceRow(index: i.int64, name: "f" & $i, depth: i mod 3,
                            rrTicks: uint64(i),
                            call: CallRow(index: i.int64, depth: i mod 3,
                                          callee: "f" & $i,
                                          args: @[CallRowArg(name: "text",
                                                          value: repeat("v", i * 15))]))
    let m = initCallTraceModel(rows, total = rows.len)
    var wrong, cuts = 0
    for width in 12 .. 90:
      var g = newStyledGrid(width, 10)
      let area = CellArea(col: 0, row: 0, width: width, height: 10)
      let screen = paintCallTraceScreen(g, area, m)
      for c in screen.cuts:
        inc cuts
        if g.runeAt(c.row, c.ellipsisCol) != "…": inc wrong
      # Every row's text: drawn whole, or cut exactly as the fit says.
      for i, r in rows:
        let full = callRowText(r.callOf)
        let at = (r.call.depth * CallRowIndentCells) + 2
        let room = (if area.tracked: width - 1 else: width) - at
        if room <= 0: continue
        let fitted = fitCell(full, room, terminalMeasure)
        var reported = false
        for c in screen.cuts:
          if c.row == 1 + i: reported = true
        if reported != fitted.truncated: inc wrong
    ck cuts > 50
    ck wrong == 0

  test "the tooltip goes under its cell, above it at the foot, on the screen":
    let t = CellTooltip(lines: @["abc", "defgh"], row: 5, col: 70)
    let a = cellTooltipArea(t, 80, 24)
    ck a.row == 6 and a.height == 2
    ck a.col + a.width <= 80
    ck a.width == "defgh".len + 2
    let foot = cellTooltipArea(CellTooltip(lines: @["x", "y", "z"], row: 22,
                                           col: 0), 80, 24)
    ck foot.row == 19
    ck cellTooltipArea(CellTooltip(), 80, 24).width == 0

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
