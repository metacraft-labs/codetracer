## The progress pie in the terminal (`tui/agent_harbor/ah_tui_canvas.nim`
## `pieGlyph`, `pieText`, `pie`; the story `ah_tui_pie.nim`): one cell whose
## glyph carries the share in quarters, by the terminal's glyph tier, in the
## wedge's ink for its ground.
##
## - The quarters' table at each boundary: 0 % ○, under 37.5 % ◔, from
##   37.5 % ◑, from 62.5 % ◕, 100 % ● (Unicode's Geometric Shapes circles,
##   https://www.unicode.org/charts/PDF/U25A0.pdf): a pie part done is never
##   ○ or ●; no known progress ◌.
## - The tiers' fallback: `basic` ○ ½ ● ? (WGL4 carries no quarter circle
##   and no ◌), `ascii` and the ambiguous-wide screen `o + * ?`; in every
##   tier none, some, all and not known are four different glyphs. The
##   screen-reader mode says the pie's words in the glyph's place.
## - A drawn pie: its glyph in the wedge's ink on its ground, its facts.
##
## No mocks: the canvas is the views' own (`StyledGrid`), the pies are the
## viewmodels' (`pieOf`), the profile is the glyph table's type.

import std/[sequtils, strutils, unittest]
import ../agent_harbor/[ah_tui_canvas, ah_tui_pie]
from ../app/views/glyph_table import GlyphProfile, tierAscii, tierBasic, tierExtended

proc pieAt(percentOf200: int): ProgressPie =
  ## A running session's pie at `percentOf200` / 2 percent (200 steps, so a
  ## boundary like 12.5 % is exact).
  pieOf(saRunning, percentOf200, 200)

suite "the glyph table, at each boundary":
  test "quarters, rounded to the nearest; part done is never none or all":
    check pieGlyph(pieAt(0)) == "○"
    check pieGlyph(pieAt(1)) == "◔"        # 0.5 %: started, not ○
    check pieGlyph(pieAt(24)) == "◔"       # 12 %
    check pieGlyph(pieAt(25)) == "◔"       # 12.5 %
    check pieGlyph(pieAt(74)) == "◔"       # 37 %
    check pieGlyph(pieAt(75)) == "◑"       # 37.5 %
    check pieGlyph(pieAt(124)) == "◑"      # 62 %
    check pieGlyph(pieAt(125)) == "◕"      # 62.5 %
    check pieGlyph(pieAt(174)) == "◕"      # 87 %
    check pieGlyph(pieAt(175)) == "◕"      # 87.5 %: not done
    check pieGlyph(pieAt(199)) == "◕"      # 99.5 %: not done
    check pieGlyph(pieAt(200)) == "●"

  test "the story's shares":
    check pieGlyph(pieOf(saRunning, 8, 50)) == "◔"    # 16 %
    check pieGlyph(pieOf(saRunning, 15, 50)) == "◔"   # 30 %, not ◑
    check pieGlyph(pieOf(saRunning, 25, 50)) == "◑"   # 50 %
    check pieGlyph(pieOf(saRunning, 42, 50)) == "◕"   # 84 %

  test "no known progress: ◌ on the extended screen, never 0 % or done":
    check pieGlyph(pieOf(saRunning, 0, 0)) == "◌"
    check pieGlyph(pieOf(saEnded, 7, 0)) == "◌"
    check pieGlyph(pieOf(saRunning, 0, 0)) != pieGlyph(pieOf(saRunning, 0, 50))
    check pieQuarter(pieOf(saEnded, 7, 0)) == 0

suite "the tiers' fallback":
  let basic = GlyphProfile(tier: tierBasic)
  let ascii = GlyphProfile(tier: tierAscii)
  let wide = GlyphProfile(tier: tierExtended, ambiguousWide: true)
  let wideBasic = GlyphProfile(tier: tierBasic, ambiguousWide: true)
  test "basic: ○ none, ½ some, ● all, ? not known":
    check pieGlyph(pieAt(0), basic) == "○"
    for k in [1, 24, 25, 32, 100, 168, 199]:
      checkpoint $k
      check pieGlyph(pieAt(k), basic) == "½"
    check pieGlyph(pieAt(200), basic) == "●"
    # WGL4 has no ◌: unknown is `?`, never ○.
    check pieGlyph(pieOf(saIdle, 0, 0), basic) == "?"
    check pieGlyph(pieOf(saRunning, 0, 0), basic) == "?"

  test "ascii and the ambiguous-wide screen: o none, + some, * all, ? not known":
    for profile in [ascii, wide, wideBasic]:
      check pieGlyph(pieAt(0), profile) == "o"
      check pieGlyph(pieAt(1), profile) == "+"
      check pieGlyph(pieAt(32), profile) == "+"
      check pieGlyph(pieAt(199), profile) == "+"
      check pieGlyph(pieAt(200), profile) == "*"
      check pieGlyph(pieOf(saRunning, 0, 0), profile) == "?"
    for k in 0 .. 200:
      let g = pieGlyph(pieAt(k), ascii)
      check g.len == 1 and g[0].ord < 0x80

  test "every tier draws the four kinds as four glyphs":
    let tiers = [GlyphProfile(tier: tierExtended), basic, ascii, wide]
    for profile in tiers:
      checkpoint $profile
      # One glyph per kind, whatever the share within it.
      var glyphOf: array[PieCellKind, seq[string]]
      for k in 0 .. 200:
        let pie = pieAt(k)
        let g = pieGlyph(pie, profile)
        if pie.pieCellKind != pckPartial and g notin glyphOf[pie.pieCellKind]:
          glyphOf[pie.pieCellKind].add g
      glyphOf[pckUnknown].add pieGlyph(pieOf(saRunning, 0, 0), profile)
      check glyphOf[pckEmpty].len == 1 and glyphOf[pckFull].len == 1
      var partials: seq[string]
      for k in 1 .. 199:
        let g = pieGlyph(pieAt(k), profile)
        if g notin partials: partials.add g
      check glyphOf[pckEmpty][0] notin partials
      check glyphOf[pckFull][0] notin partials
      check glyphOf[pckUnknown][0] notin partials
      check glyphOf[pckEmpty][0] != glyphOf[pckFull][0]
      check glyphOf[pckUnknown][0] != glyphOf[pckEmpty][0]
      check glyphOf[pckUnknown][0] != glyphOf[pckFull][0]

  test "the four kinds, at their edges":
    check pieCellKind(pieOf(saRunning, 0, 0)) == pckUnknown
    check pieCellKind(pieOf(saRunning, 0, 50)) == pckEmpty
    check pieCellKind(pieOf(saRunning, 1, 50)) == pckPartial
    check pieCellKind(pieOf(saRunning, 49, 50)) == pckPartial
    check pieCellKind(pieOf(saRunning, 50, 50)) == pckFull
    check pieCellKind(pieOf(saRunning, 60, 50)) == pckFull
    check pieCellKind(pieOf(saEnded, 7, 0)) == pckUnknown

  test "the screen-reader mode says the words in the glyph's place":
    let quiet = GlyphProfile(tier: tierAscii, quiet: true)
    let pie = pieOf(saNeedsInput, 8, 50)
    check pieText(pie, quiet) == "needs input, 8 of 50 steps, 16%"
    check pieText(pieOf(saNeedsInput, 0, 0), quiet) == "needs input, progress unknown"
    check pieText(pie) == "◔"

suite "a drawn pie":
  test "its glyph, in the wedge's ink for its ground, and its facts":
    for mode in [dmDark, dmLight]:
      var c = newAhCanvas(10, 2, ahPalette(mode))
      let ground = c.p.pieGroundColour(pgActiveTab)
      c.area("ground", 0, 0, 10, 2, ground)
      let pie = pieOf(saFailed, 25, 50)
      let n = c.pie(nil, 1, 3, pie, ground)
      check cellsText(c.grid, 1, 3, 1) == "◑"
      check styleAt(c.grid, 1, 3).fg == c.p.pieInks(prError, ground).wedge
      check styleAt(c.grid, 1, 3).bg == ground
      check n.attr("pie") == "error"
      check n.attr("pie-fraction") == "50%"
      check n.attr("pie-label") == "failed, 25 of 50 steps, 50%"

  test "Light draws all five grounds, each its own band":
    var c = newAhCanvas(45, 56, ahPalette(dmLight))
    c.drawPieStory("every-state", 0, 0, 45, 56)
    check c.root.all("pie-ground").filterIt(it.attr("pie").len == 0).len == 5
    # The rows name D2's words, cut nowhere in 45 cells.
    let rows = c.root.all("pie-row")
    check cellsText(c.grid, rows[1].row, 1, 15) == "running/working"

  test "the story draws a band per ground and a pie per role and share":
    var c = newAhCanvas(45, 56, ahPalette(dmDark))
    c.drawPieStory("every-state", 0, 0, 45, 56)
    let bands = c.root.all("pie-ground").filterIt(it.attr("pie").len == 0)
    # Dark: the active tab and the selected row share a ground, one band.
    check bands.len == 4
    check bands.mapIt(it.attr("pie-ground")) == @["window", "panel", "active-tab", "menu"]
    check cellsText(c.grid, bands[2].row, 1, 25) == "Active tab / Selected row"
    check c.root.all("pie").len == 4 * 6 * 6 + 3 * 6
    # The 84 % column of the first band's first row: ◕ in the warning ink.
    let row = bands[0].all("pie-row")[0]
    let pies = row.all("pie")
    check cellsText(c.grid, pies[3].row, pies[3].col, 1) == "◕"
    check cellsText(c.grid, pies[5].row, pies[5].col, 1) == "◌"
    # The glyph tiers, each a row of the running state's pies.
    let tiers = c.root.all("pie-tier")
    check tiers.mapIt(it.attr("pie-tier")) == @["extended", "basic", "ascii"]
    var drawn: seq[string]
    for t in tiers:
      var line = ""
      for e in t.all("pie"): line.add cellsText(c.grid, e.row, e.col, 1)
      drawn.add line
    check drawn == @["○◔◑◕●◌", "○½½½●?", "o+++*?"]
    # The screen reader's words for 16 % and unknown.
    check c.root.values("pie-words") ==
      @["reader: running, 8 of 50 steps, 16%", "reader: running, progress unknown"]

  test "each head is centred on its pie, a cell or more from the next":
    var c = newAhCanvas(45, 56, ahPalette(dmDark))
    c.drawPieStory("every-state", 0, 0, 45, 56)
    let head = c.root.all("pie-head")[0]
    let pies = c.root.all("pie-row")[0].all("pie")
    var spans: seq[(int, int)]
    for i, name in PieStoryColumns:
      checkpoint name
      # The head's words, where `pieHeadSpan` says, over the pie's cell.
      let (first, last) = pieHeadSpan(i)
      check cellsText(c.grid, head.row, first, name.len) == name
      check last - first + 1 == name.len
      check pies[i].col == PieStoryPieCells[i]
      check first <= pies[i].col and pies[i].col <= last
      # Centred: as many cells left of the pie as right, one more left for
      # an even-width head.
      check (pies[i].col - first) - (last - pies[i].col) in [0, 1]
      spans.add (first, last)
    for i in 1 ..< spans.len:
      check spans[i][0] - spans[i - 1][1] - 1 >= PieStoryHeadGapCells
    check PieStoryHeadGapCells >= 1
    # The last head ends inside the 45-cell sidebar.
    check spans[^1][1] <= 44
