## test_plat70b_table_overflow.nim — PLAT-70 Part B (Horizontal-Overflow.md
## §5), the SHARED decisions every front-end draws its table panes from
## (`viewmodels/table_overflow`, the Event Log's column widths in
## `event_log_vm`, the operations and their rows), swept rather than sampled:
##
##   * §5.1 / HO-8's half that is a property of the decision — a cell is
##     `truncated` iff its one-line text is wider than its column, its drawn
##     text never exceeds the column, ends in `…` iff truncated, and never
##     splits a wide glyph — over random texts (ASCII, wide glyphs, newlines)
##     and every column from 0 to 40 cells;
##   * §5.3's detail and tooltip — wrapped inside the column, never wider;
##     capped at `DetailMaxLines = min(10, half the body)` with the copy hint
##     (`… <n> more lines — Ctrl+C copies the value`) as the last line, the
##     count exact; one row open at a time, again closes it;
##   * the hover clock — only a truncated cell starts it; shown at 500 ms and
##     not at 499; leaving the cell, a key and another cell end it;
##   * §5.2 — the Event Log's widths: the 3-cell minimum, `resize-column`
##     from the drawn width, the remembered document round-tripping, a
##     malformed document refused by name, other tables' entries kept apart;
##     `table.resize-column`'s argument;
##   * §5.3's rows, per base, through the one router: CUA `Ctrl+K Ctrl+I`,
##     Emacs `Ctrl+H .`, Vim and Kakoune `Shift+K` — in the table panes, and
##     not in the editor.
##
## No mocks: pure values and the shipped router. Runs on the C and the JS
## backends.

import std/[random, strutils, unicode, unittest]

import ../../viewmodels/table_overflow
import ../../../../common/value_presentation/value_model
import ../../viewmodels/event_log_vm
import ../../viewmodels/omnibar_sources
import ../../keymap/[keymap_router, operation_catalogue, context_keys, scope_path,
                    base_keymaps]
import ../../editing_core

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 142

func wideMeasure(s: string): int {.gcsafe, raises: [].} =
  ## A terminal's measure for this suite's alphabet: CJK two cells, the rest
  ## one — written out here rather than calling the terminal's.
  for r in s.runes:
    result += (if int(r) >= 0x4E00 and int(r) <= 0x9FFF: 2 else: 1)

proc randomText(rng: var Rand): string =
  const pieces = ["a", "b", "z", " ", "0", "_", "世", "界", "…", "\n", "é"]
  for _ in 0 ..< rng.rand(0 .. 30):
    result.add pieces[rng.rand(pieces.high)]

suite "PLAT-70 Part B: the cut cell (§5.1)":

  test "HO-8's decision: truncated iff the line does not fit, swept":
    var rng = initRand(70_2)
    var violations = 0
    var cutSeen, wholeSeen = 0
    for _ in 0 ..< 600:
      let full = rng.randomText()
      let line = oneLine(full)
      for cells in 0 .. 40:
        let c = fitCell(full, cells, wideMeasure)
        let fits = wideMeasure(line) <= cells
        if c.full != full: inc violations
        if c.truncated == fits and line.len > 0: inc violations
        if c.truncated:
          inc cutSeen
          if cells > 0 and not c.text.endsWith(Ellipsis): inc violations
          if wideMeasure(c.text) > max(1, cells): inc violations
          # The kept part is a prefix of the line: no glyph split, none
          # invented.
          if cells > 1 and not line.startsWith(
               c.text[0 ..< c.text.len - Ellipsis.len]): inc violations
        else:
          inc wholeSeen
          if c.text != line: inc violations
    ck violations == 0
    ck cutSeen > 1000
    ck wholeSeen > 1000

  test "a wide glyph is never split: the ellipsis moves one cell left":
    let c = fitCell("ab世界", 4, wideMeasure)   # a b 世 = 4 cells, 界 cut
    ck c.truncated
    ck c.text == "ab" & Ellipsis               # 世 would leave no room
    ck wideMeasure(c.text) == 3
    let fits = fitCell("ab世", 4, wideMeasure)
    ck not fits.truncated
    ck fits.text == "ab世"

  test "one line: newlines and runs of space collapse":
    ck oneLine("a\n  b\tc") == "a b c"
    let c = fitCell("x\ny", 10)
    ck c.text == "x y"
    ck not c.truncated
    ck c.full == "x\ny"

  test "a value cell is the presenter's answer, carried as it is":
    let c = presentedCell("[1, 2, …", "[1, 2, 3, 4]", true)
    ck c.truncated and c.text == "[1, 2, …" and c.full == "[1, 2, 3, 4]"

  test "the cut cells are hit-tested where they were drawn":
    let cuts = @[CutCell(row: 3, col: 10, width: 5, ellipsisCol: 14,
                         key: "a", column: "value", full: "abcdefgh")]
    ck cuts.cutCellAt(3, 10) == 0
    ck cuts.cutCellAt(3, 14) == 0
    ck cuts.cutCellAt(3, 15) == -1
    ck cuts.cutCellAt(4, 12) == -1
    ck cuts.ellipsisAt(3, 14) == 0
    ck cuts.ellipsisAt(3, 13) == -1
    let px = @[CutCell(row: 0, col: 100, width: 80, ellipsisCol: 170,
                       ellipsisWidth: 10)]
    ck px.ellipsisAt(0, 179) == 0
    ck px.ellipsisAt(0, 180) == -1

suite "PLAT-70 Part B: the full text (§5.3)":

  test "wrapped inside its column, never wider, nothing lost":
    var rng = initRand(70_3)
    var violations = 0
    for _ in 0 ..< 300:
      let text = rng.randomText()
      for cells in 1 .. 25:
        let lines = wrapCells(text, cells, wideMeasure)
        var rejoined = ""
        for l in lines:
          if wideMeasure(l) > max(cells, 2): inc violations
          rejoined.add l
        # Only the spaces a break replaced, and the newlines, are gone.
        if rejoined.replace(" ", "") != text.replace(" ", "").replace("\n", ""):
          inc violations
    ck violations == 0

  test "DetailMaxLines is min(10, half the body), at least one":
    ck detailMaxLines(40) == 10
    ck detailMaxLines(20) == 10
    ck detailMaxLines(19) == 9
    ck detailMaxLines(6) == 3
    ck detailMaxLines(1) == 1
    ck detailMaxLines(0) == 1

  test "the detail is capped, the hint the last line, the count exact":
    var text = ""
    for i in 1 .. 21:
      text.add "line " & $i & "\n"
    text.add "line 22"
    let v = detailView(text, 60, 30, "Ctrl+C")
    ck v.capped
    ck v.lines.len == 10
    ck v.lines[0] == "line 1"
    ck v.lines[8] == "line 9"
    ck v.hiddenLines == 22 - 9
    ck v.lines[9] == "… 13 more lines — Ctrl+C copies the value"
    let half = detailView(text, 60, 8, "y")
    ck half.lines.len == 4
    ck half.lines[3] == "… 19 more lines — y copies the value"
    let short = detailView("one line", 60, 30, "Ctrl+C")
    ck not short.capped
    ck short.lines == @["one line"]
    ck copyHint(1, "") == "… 1 more line — Copy (the palette) copies the value"

  test "the 7269-character value fills at most DetailMaxLines":
    let big = repeat("x", 7269)
    let v = detailView(big, 50, 40, "Ctrl+C")
    ck v.lines.len == 10
    ck v.hiddenLines == 7269 div 50 + 1 - 9
    let t = tooltipView(big, 200, 40, "Ctrl+C")
    ck t.lines.len == 10
    ck t.lines[0].len == 80              # §5.3: wraps at min(80, window)
    ck tooltipColumns(40) == 40
    ck tooltipColumns(300) == 80

  test "the whole value is the presenter's, never cut to a width":
    # `tableFullBudget` has no cell bound: a long value comes back whole.
    let long = repeat("abcdefghij", 300)
    let whole = fullValueText(scalar(pvkString, long), "")
    ck whole.contains(long)
    ck fullValueText(nil, "fallback") == "fallback"

  test "one row open at a time; again closes it":
    var d = DetailToggle()
    ck d.toggleDetail("variables", "a.b")
    ck d.isOpen("variables", "a.b")
    ck d.toggleDetail("variables", "c")
    ck not d.isOpen("variables", "a.b")
    ck d.isOpen("variables", "c")
    ck not d.toggleDetail("variables", "c")
    ck not d.isOpenIn("variables")
    ck d.toggleDetail("event-log", "7", "location")
    ck d.toggleDetail("event-log", "7", "output")   # another column: switch
    ck d.column == "output"
    ck not d.toggleDetail("event-log", "7", "output")  # again: closed
    ck not d.isOpenIn("event-log")

suite "PLAT-70 Part B: hover (§5.3)":

  test "only a truncated cell starts the clock; 500 ms, not 499":
    var h = HoverClock()
    ck not h.pointerOver("variables", "x", "value", "full", false, 0)
    ck h.dueMs == -1
    ck not h.pointerOver("variables", "x", "value", "full", true, 1000)
    ck h.dueMs == 1500
    ck not h.tick(1499)
    ck not h.shown
    ck h.tick(1500)
    ck h.shown and h.full == "full"
    ck h.dueMs == -1
    # Moving within the same cell keeps it.
    ck not h.pointerOver("variables", "x", "value", "full", true, 1700)
    ck h.shown
    # Leaving it hides it (the answer: a shown tooltip changed).
    ck h.pointerOver("", "", "", "", false, 1800)
    ck not h.shown
    # Another cell restarts the clock.
    discard h.pointerOver("event-log", "3", "output", "o", true, 2000)
    discard h.tick(2500)
    ck h.pointerOver("event-log", "4", "output", "p", true, 2600)
    ck not h.shown and h.dueMs == 3100
    discard h.tick(3100)
    ck h.dismiss()
    ck not h.dismiss()

suite "PLAT-70 Part B: the Event Log's column widths (§5.2)":

  test "the model owns them; never under 3 cells":
    var c = defaultEventLogColumns()
    ck c.columnWidthOr(elcLocation, 18) == 18
    ck c.setColumnWidth(elcLocation, 30)
    ck c.columnWidthOr(elcLocation, 18) == 30
    ck c.focused == elcLocation
    ck not c.setColumnWidth(elcLocation, 30)
    ck c.setColumnWidth(elcTick, 1)
    ck c.widths[elcTick] == MinColumnCells
    ck c.resizeColumn(elcOutput, 4, 40)
    ck c.widths[elcOutput] == 44
    ck c.focused == elcOutput
    ck c.resizeColumn(elcOutput, -100, 40)
    ck c.widths[elcOutput] == MinColumnCells

  test "the remembered document round-trips and is refused by name":
    var c = defaultEventLogColumns()
    discard c.setColumnWidth(elcLocation, 30)
    discard c.setColumnWidth(elcIndex, 6)
    let doc = encodeColumnWidths(c.columnWidthEntries &
                                 @[(table: "other", column: "x", cells: 9)])
    ck doc == "event-log.#=6\nevent-log.location=30\nother.x=9\n"
    let back = decodeColumnWidths(doc)
    ck back.ok
    ck back.entries.len == 3
    let applied = defaultEventLogColumns().withColumnWidths(back.entries)
    ck applied.widths[elcLocation] == 30
    ck applied.widths[elcIndex] == 6
    ck applied.widths[elcTick] == 0
    ck applied.order == defaultEventLogColumns().order
    for bad in ["event-log.output", "nodot=4", "event-log.output=x",
                "event-log.output=2"]:
      let refused = decodeColumnWidths(bad)
      ck not refused.ok
      ck bad in refused.message
    ck decodeColumnWidths("").ok
    ck decodeColumnWidths("# a comment\n\n").entries.len == 0
    ck cellsOfPx(24) == 3 and pxOfCells(3) == 24

  test "table.resize-column's argument and `:column-width`":
    ck parseColumnResize("+2") == (true, "", 2)
    ck parseColumnResize("-3") == (true, "", -3)
    ck parseColumnResize("output,+4") == (true, "output", 4)
    ck parseColumnResize("location, -1") == (true, "location", -1)
    ck not parseColumnResize("0").ok
    ck not parseColumnResize("wide").ok
    ck argumentProblem("table.resize-column", "+2") == ""
    ck argumentProblem("table.resize-column", "x").len > 0
    ck argumentProblem("list.show-detail", "") == ""
    let line = parseColumnWidthLine(["column-width", "location", "30"])
    ck line.ok and line.column == elcLocation and line.cells == 30
    ck not parseColumnWidthLine(["column-width", "nope", "3"]).ok
    ck not parseColumnWidthLine(["column-width", "tick"]).ok
    var labels: seq[string] = @[]
    for e in tableCommands():
      labels.add e.label
      ck parseOperationCommand(e.target).ok
    ck labels == @["Show Detail", "Widen Column", "Narrow Column"]
    ck parseOperationCommand(tableCommands()[1].target).operation ==
       "table.resize-column(+2)"
    # The target every front-end resizes: the named column, else the
    # focused one; a bad argument or column refused with its reason.
    var cols = defaultEventLogColumns()
    discard cols.setColumnWidth(elcKind, 9)
    let focusedTarget = cols.columnResizeTarget("+2")
    ck focusedTarget.ok and focusedTarget.col == elcKind and
       focusedTarget.delta == 2
    let named = cols.columnResizeTarget("location,-1")
    ck named.ok and named.col == elcLocation and named.delta == -1
    ck "no event log column" in cols.columnResizeTarget("nope,+1").message
    ck not cols.columnResizeTarget("x").ok
    # The document written back: this table's widths replaced, the others
    # kept.
    let merged = mergeColumnWidths(
      [(table: "event-log", column: "#", cells: 6),
       (table: "other", column: "a", cells: 4)],
      "event-log", [(table: "event-log", column: "kind", cells: 7)])
    ck merged == @[(table: "other", column: "a", cells: 4),
                   (table: "event-log", column: "kind", cells: 7)]

suite "PLAT-70 Part B: the detail's rows, per base (§5.3)":

  test "CUA Ctrl+K Ctrl+I, Emacs Ctrl+H ., Vim and Kakoune Shift+K":
    let delivery = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                               keyProtocol: kpKitty)
    let facts = SessionFacts(product: pmDebug, replayLoaded: true,
                             editor: EditorFacts(readOnly: true,
                                                 mode: emInsert))
    let window = element(ekWindow, "window")
    let tab = element(ekTab, "tab:1")
    proc pathOf(paneKind: string): ScopePath = @[window, tab, pane(paneKind)]
    proc run(base: BaseKeymap; paneKind: string;
             keys: varargs[string]): string =
      var r = initKeymapRouter(base, delivery)
      var t = 1_000'i64
      var res: EditingResolution
      for k in keys:
        res = r.route(facts, pathOf(paneKind), nmNormal, k, t)
        t += 10
      case res.kind
      of erOperation: res.operation
      of erPending: "pending"
      of erCharacter: "char"
      of erNothing: "nothing"
    for paneKind in ["state", "eventLog", "calltrace"]:
      ck run(bkCua, paneKind, "Ctrl+k", "Ctrl+i") == "list.show-detail"
      ck run(bkEmacs, paneKind, "Ctrl+h", ".") == "list.show-detail"
      ck run(bkVim, paneKind, "K") == "list.show-detail"
      ck run(bkKakoune, paneKind, "K") == "list.show-detail"
    # Not in the editor.
    ck run(bkCua, "editor", "Ctrl+k", "Ctrl+i") != "list.show-detail"
    ck run(bkVim, "editor", "K") != "list.show-detail"

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
