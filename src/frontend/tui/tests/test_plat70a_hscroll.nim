## test_plat70a_hscroll.nim — PLAT-70 Part A (Horizontal-Overflow.md §4), the
## terminal's half that needs no pty:
##
##   * HO-6 — the decoder, on the exact SGR bytes: buttons 66 / 67 are
##     `mbWheelLeft` / `mbWheelRight` (they used to be read as the vertical
##     wheel), 64 / 65 stay up / down, and the Shift bit is carried;
##   * HO-7 — over EVERY pane size from 2 x 2 to 400 x 200, the Terminal
##     Output's vertical track and its horizontal bar never share a cell, and
##     the corner cell belongs to neither; painted, the corner is blank;
##   * HO-2 — the source gate: no front-end module divides a pointer by a
##     horizontal bar's extent itself (the model's `trackFractionAt` does it),
##     with a planted violation the same scanner must catch;
##   * §4.6 — the `‹` / `›` markers drawn on exactly the rows cut by the view,
##     `<` / `>` on the ASCII tier, and nothing when the setting is off;
##   * the setting itself — `overflow-markers` parsed from `:set`, from
##     `--overflow-markers=`, remembered, defaulting ON in the terminal and OFF
##     in GPUI, and the palette's **View: Toggle Overflow Markers**;
##   * §4.1 — the editor's view columns are the cells the grid draws: a tab
##     is ONE (the model's tab stops would make a tabbed line's bar promise
##     columns no row draws);
##   * §4.7 — on the ASCII tier the bar is `#` on `-`, every thumb cell `#`
##     whatever eighth block drew it (`▏` alone degrades to a divider's `|`).
##
## No mocks: the shipped decoder, painters, model and source tree.

import std/[os, strutils, unicode, unittest]

import codetracer_embed

import ../app/input/mouse
import ../app/views/styled_row
import ../app/views/scrubber_track
import ../app/views/edit_pane
import ../app/views/terminal_output_pane
import ../app/views/borders
import ../app/theme/capabilities
import ../app/theme/degradation
import host/layout_preferences
import viewmodels/omnibar_sources

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 66

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc decoded(bytes: string): MouseEvent =
  let (ok, ev) = decodeMouse(bytes)
  doAssert ok, "not a mouse report: " & bytes.escape
  ev

suite "PLAT-70 Part A: the terminal's horizontal scroll, in process":

  test "HO-6: SGR 66 / 67 are the horizontal wheel, on the exact bytes":
    let left = decoded("\x1b[<66;12;5M")
    ck left.button == mbWheelLeft
    ck left.kind == mekPress
    ck left.row == 4 and left.col == 11
    let right = decoded("\x1b[<67;12;5M")
    ck right.button == mbWheelRight
    # The vertical wheel is unchanged …
    ck decoded("\x1b[<64;12;5M").button == mbWheelUp
    ck decoded("\x1b[<65;12;5M").button == mbWheelDown
    # … and Shift (bit 4) is carried: 68 / 69 are Shift + wheel-up / -down,
    # which the runtime reads as a horizontal wheel (§4.3).
    let shiftUp = decoded("\x1b[<68;3;3M")
    ck shiftUp.button == mbWheelUp and shiftUp.shift
    let shiftDown = decoded("\x1b[<69;3;3M")
    ck shiftDown.button == mbWheelDown and shiftDown.shift
    let shiftLeft = decoded("\x1b[<70;3;3M")
    ck shiftLeft.button == mbWheelLeft and shiftLeft.shift
    # Not a click: neither horizontal button is a left press.
    ck left.button != mbLeft and right.button != mbLeft

  test "HO-7: the two tracks never share a cell, at every pane size":
    var m = TerminalOutputPaneModel(loaded: true, follow: true,
                                    currentLine: -1, shownWrite: -1)
    m.lines = @[TerminalLine(fragments: @[TerminalEventFragment(
      text: repeat('w', 900), eventIndex: 0)])]
    m.hview = HorizontalView(contentCols: 900)
    var sizes, barred, disjoint, cornerFree = 0
    for w in 2 .. 400:
      for h in 2 .. 200:
        inc sizes
        let area = CellArea(col: 0, row: 0, width: w, height: h)
        let geo = terminalPaneGeometry(m, area)
        if geo.barRow < 0:
          continue
        inc barred
        # The vertical track's cells: its column, the content rows. The
        # bar's: its row, the text columns.
        let trackRows = geo.contentTop ..< geo.contentTop + geo.contentRows
        let barCols = geo.textCol ..< geo.textCol + geo.textWidth
        if geo.barRow notin trackRows and geo.trackCol notin barCols:
          inc disjoint
        # The corner is inside the pane and is neither's.
        if geo.trackCol >= 0 and geo.barRow < h and
           geo.barRow notin trackRows and geo.trackCol notin barCols:
          inc cornerFree
    ck sizes == 399 * 199
    ck barred > 70_000
    ck disjoint == barred
    ck cornerFree == barred
    # Painted: the corner cell is blank, the vertical bar ends in the cell
    # above it and the horizontal bar in the cell left of it (PLAT-70 Part
    # H: read from the bars the painter recorded, since with the default
    # options a bar's track cells are the pane's own blank ground).
    for (w, h) in [(60, 12), (31, 5), (200, 50)]:
      var g = newStyledGrid(w, h)
      let area = CellArea(col: 0, row: 0, width: w, height: h)
      discard paintTerminalOutput(g, area, m)
      let geo = terminalPaneGeometry(m, area)
      let corner = g.rowText(geo.barRow).runeSubStr(geo.trackCol, 1)
      ck corner == " "
      var v, hz = -1
      for b in g.bars:
        if b.axis == axVertical: v = b.at + b.cells - 1
        else: hz = b.at + b.cells - 1
        ck not b.contains(geo.barRow, geo.trackCol)
      ck v == geo.barRow - 1
      ck hz == geo.trackCol - 1
    # And a pane whose lines fit draws no bar at all (HO-1).
    var fits = m
    fits.hview = HorizontalView(contentCols: 10)
    ck terminalPaneGeometry(fits, CellArea(width: 60, height: 12)).barRow == -1

  test "HO-2: no front-end divides a pointer by a bar's extent itself":
    proc violations(lines: openArray[string]): seq[string] =
      ## A line that names a horizontal bar and DIVIDES: the arithmetic
      ## `trackFractionAt` owns, done by hand.
      for raw in lines:
        let line = raw.strip
        if line.startsWith("#") or line.len == 0: continue
        let lower = line.toLowerAscii
        if not (lower.contains("hbar") or lower.contains("editorbar") or
                lower.contains("horizontalbar") or lower.contains("barrect")):
          continue
        var code = line
        let comment = code.find(" #")
        if comment >= 0: code = code[0 ..< comment]
        if code.replace("//", "").contains('/'):
          result.add raw
    # The planted control: the hand-written division this gate exists for.
    ck violations(["  let f = float(x - lay.hbar.x) / float(lay.hbar.w)"]).len == 1
    ck violations(["  let f = trackFractionAt(x - lay.hbar.x, lay.hbar.w)"]).len == 0
    var scanned = 0
    var found: seq[string] = @[]
    for dir in ["src/frontend/tui/app", "src/frontend/gpui",
                "src/frontend/viewmodel/views", "src/frontend/ui"]:
      for f in walkDirRec(repo / dir):
        if not f.endsWith(".nim") or "/tests/" in f: continue
        inc scanned
        for v in violations(readFile(f).splitLines):
          found.add f.relativePath(repo) & ": " & v.strip
    checkpoint("front-end modules scanned: " & $scanned)
    for v in found: checkpoint("HAND-WRITTEN BAR ARITHMETIC: " & v)
    ck scanned > 200
    ck found.len == 0
    # And every front-end's bar reaches the model's fraction.
    for f in ["src/frontend/tui/app/views/scrubber_track.nim",
              "src/frontend/gpui/terminal_output_leaf.nim",
              "src/frontend/gpui/main.nim",
              "src/frontend/viewmodel/views/list_scrubber_dom.nim"]:
      checkpoint("calls trackFractionAt: " & f)
      ck readFile(repo / f).contains("trackFractionAt(")

  test "§4.6: the markers, on exactly the cut rows; ASCII; off":
    let long = repeat('L', 80)
    var model = initEditPaneModel(path = "m.txt",
                                  lines = @[long, "short", ""],
                                  viewportTop = 1, caretLine = 0)
    model.hview = HorizontalView(leftCol: 5, contentCols: 80)
    model.overflowMarkers = true
    let area = CellArea(col: 0, row: 0, width: 40, height: 6)
    var g = newStyledGrid(40, 6)
    let screen = paintEditPane(g, area, model)
    let code = screen.gutterWidth
    let codeW = 40 - code
    let row1 = g.rowText(1).runeSubStr(code, codeW)
    ck row1.runeSubStr(0, 1) == PrecedesGlyph          # continues left
    ck row1.runeSubStr(codeW - 1, 1) == ExtendsGlyph   # and right
    # "short" lies wholly left of the view: its text continues left of it,
    # so the first column says so — and nothing continues right.
    let row2 = g.rowText(2).runeSubStr(code, codeW)
    ck row2.runeSubStr(0, 1) == PrecedesGlyph
    ck row2.runeSubStr(codeW - 1, 1) == " "
    let row3 = g.rowText(3).runeSubStr(code, codeW)
    ck row3.strip.len == 0             # the empty line: no marker
    # The bar is on the last row (§4.7).
    ck screen.barRow == 5
    # ASCII tier: `<` and `>`.
    ck asciiFor(PrecedesGlyph) == "<"
    ck asciiFor(ExtendsGlyph) == ">"
    # Off: no marker.
    model.overflowMarkers = false
    var g2 = newStyledGrid(40, 6)
    discard paintEditPane(g2, area, model)
    let off1 = g2.rowText(1).runeSubStr(code, codeW)
    ck off1 == long.runeSubStr(5, codeW)

  test "§4.1: the editor's columns are the cells the grid draws (a tab is one)":
    for line in ["\tif x:\t# a tab", "ab\t世界\tz", "plain ascii", "\t\t\t",
                 "x" & repeat('\t', 40)]:
      checkpoint(line.escape)
      var d = initEditingDocument("t.py", line & "\na\n")
      ck d.contentCols == cellWidthOf(line)
    # The caret's view column too: after the line's three tabs, three cells.
    var d = initEditingDocument("t.py", "\t\t\tx\n")
    d.moveCaretTo(0, 3)
    ck d.caretViewColumn == cellWidthOf("\t\t\t")

  test "§4.7: the ASCII bar is `#` on `-`, whatever eighths drew the thumb":
    let ascii = TerminalCapabilities(colors: cdMonochrome, borders: bmAscii,
                                     mouse: true, mode: dmDark,
                                     palette: pkDesign, theme: utDark)
    # A thumb 16 eighths long starting one eighth into its first cell: that
    # cell is the track's `▏` reversed onto the thumb's ground, then a full
    # block, then the thumb's own `▏` one eighth into the third cell.
    let cells = thumbCells(ThumbSpan(start: 1, length: 16), 4, vertical = false)
    var row: StyledRow = @[]
    for c in cells:
      row.add StyledSpan(text: c.glyph, style: styleOf(c.kind))
    ck cells[0].glyph == "▏" and cells[2].glyph == "▏"
    # PLAT-71 (Terminal-Adaptation §6.4): on the ASCII profile the slider is
    # DRAWN from the table's ASCII column — whole cells, a cell is thumb when
    # the thumb covers its centre — rather than rewritten after it was drawn
    # in eighths. The thumb covers the centres of the first two cells.
    let asciiCells = thumbCells(ThumbSpan(start: 1, length: 16), 4,
                                vertical = false, glyphs = glyphProfileOf(ascii))
    var asciiRow: StyledRow = @[]
    for c in asciiCells:
      asciiRow.add StyledSpan(text: c.glyph, style: styleOf(c.kind))
    let degraded = degradeRow(asciiRow, ascii)
    var text = ""
    for span in degraded: text.add span.text
    ck text == "##--"
    ck asciiFor("▏") == "|"            # what the glyph table alone would draw
    let sl = parseSetLine(":set overflow-markers off")
    ck sl.isSet and sl.ok
    ck sl.setting == lsOverflowMarkers and not sl.on
    let flag = parseSettingFlag("--overflow-markers=on")
    ck flag.isFlag and flag.ok and flag.setting == lsOverflowMarkers
    ck flag.value == soOn
    ck productDefaults(lpTerminal).overflowMarkers
    ck not productDefaults(lpGpui).overflowMarkers
    var s = productDefaults(lpTerminal)
    s.assign(lsOverflowMarkers, false)
    let back = decodeLayoutSettings(encodeLayoutSettings(s),
                                    productDefaults(lpTerminal))
    ck back.ok and not back.settings.overflowMarkers
    # A file that never mentions it keeps each front-end's default.
    ck decodeLayoutSettings("focus-highlight=on\n",
                            productDefaults(lpGpui)).settings.overflowMarkers ==
       false
    # The palette's entry, by the specification's name.
    var toggle = 0
    for e in layoutSettingCommands():
      if e.label == ToggleOverflowMarkersLabel:
        inc toggle
        ck parseSettingToggleTarget(e.target) == (true, lsOverflowMarkers)
    ck toggle == 1

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
