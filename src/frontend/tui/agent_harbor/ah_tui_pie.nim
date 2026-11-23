## tui/agent_harbor/ah_tui_pie.nim — the progress pie's story in the
## terminal, `Pie Indicator: Every State`, on the grid
## `stories/agent_harbor_pie_stories` states, in cells (`cellsOf`; a row is
## 16 px): a head naming the columns, then a band per ground, each a title
## and a row per role. Each pie is one cell (`ah_tui_canvas.pie`): its glyph
## by quarters in the wedge's ink for the band's ground.
##
## Under the bands, the terminal's own part of the story: the glyph tiers
## (`PieStoryTiers`), one row of the running state's pies drawn in each, and
## what the screen-reader mode says in place of a glyph, for one known and
## one unknown share, so every fallback can be reviewed.

import ./ah_tui_canvas
import ../../stories/agent_harbor_pie_stories
from ../app/views/glyph_table import GlyphProfile, tierExtended, tierBasic, tierAscii

export agent_harbor_pie_stories

const
  PieStoryTiers* = [("extended", GlyphProfile(tier: tierExtended)),
                    ("basic", GlyphProfile(tier: tierBasic)),
                    ("ascii", GlyphProfile(tier: tierAscii))]
    ## The glyph tiers the story shows (`pieGlyph`): the quarters and ◌;
    ## WGL4's ○ ½ ● ?; ASCII's `o + * ?`.
  PieStoryReaderColumns* = [1, 5]
    ## The columns whose words the story spells out: 16 % and unknown.
  PieStoryPieCells* = [17, 20, 24, 28, 34, 41]
    ## Each column's pie, in cells from the story's left edge (a cell is
    ## 8 px). Its head is centred on that cell (`pieHeadSpan`); the cells
    ## put every two neighbouring heads at least a cell (8 px, the GUI hosts'
    ## least gap) apart, and `84%`/`100%` and `100%`/`unknown` two. A 45-cell
    ## sidebar has no room for two cells between every pair: the six heads
    ## take 22 cells of the 29 the state words and the inset leave, and
    ## their centring takes more.
  PieStoryHeadGapCells* = 1
    ## The least number of empty cells between two columns' heads.

proc pieHeadSpan*(column: int): (int, int) =
  ## The cells, from the story's left edge, a column's head (`PieStoryColumns`)
  ## takes, first and last: centred on its pie's cell, an even-width head
  ## one cell further left than right.
  let w = PieStoryColumns[column].len
  let first = PieStoryPieCells[column] - w div 2
  (first, first + w - 1)

proc drawPieStory*(c: var AhCanvas; fixture: string; top, left, width, height: int) =
  ## The story in the rectangle at (`top`, `left`), `width` × `height` cells.
  c.area("pie-story", top, left, width, height, c.p.ground)
  let view = c.node(nil, top, left, width, height, [("surface", PieStorySurface)])
  # A cell is 8px, so the web's two 8px insets (the story's and the band's)
  # are one cell here. The grid in cells: the state words (15, the longest
  # `running/working`) after the inset, then each column's pie at
  # `PieStoryPieCells` with its head centred over it; the last head,
  # `unknown`, ends in the 45th cell, the brief's sidebar.
  let inset = 1
  let labelCells = 15
  proc columnAt(i: int): int = left + PieStoryPieCells[i]
  var row = top
  let head = c.node(view, row, left, width, 1, [("pie-head", "")])
  for i, name in PieStoryColumns:
    let (first, last) = pieHeadSpan(i)
    discard c.text(head, row, left + first, last - first + 1, name,
                   c.p.readableInk(c.p.ground))
  inc row
  for band in pieStoryBands(fixture, c.p.mode):
    let ground = c.p.pieGroundColour(band.ground)
    let bandRows = 1 + band.rows.len
    # The web's 4px between bands is one row of the story's ground here, so
    # two bands on grounds a mode resolves alike (Dark's active tab and
    # selected row) stay two areas.
    inc row
    if row + bandRows > top + height: break
    # A band on the story's own ground (the window's) is no area of its own:
    # an area is told from its neighbours by its ground.
    if ground != c.p.ground:
      c.area("pie-band-" & $band.ground, row, left, width, bandRows, ground)
    let b = c.node(view, row, left, width, bandRows, [("pie-ground", $band.ground)])
    let ink = c.p.readableInk(ground)
    discard c.text(b, row, left + inset, width - 2 * inset, band.bandTitle,
                   ink, bold = true)
    inc row
    for r in band.rows:
      let line = c.node(b, row, left, width, 1, [("pie-row", $r.role)])
      discard c.text(line, row, left + inset, labelCells, r.word, ink)
      for i, pie in r.pies:
        discard c.pie(line, row, columnAt(i), pie, ground)
      inc row
  # The glyph tiers and the screen reader's words, on the story's ground.
  let running = pieStoryRows()[1]
  let needed = 2 + PieStoryTiers.len + PieStoryReaderColumns.len
  inc row
  if row + needed <= top + height:
    let ink = c.p.readableInk(c.p.ground)
    let tiers = c.node(view, row, left, width, needed, [("pie-tiers", "")])
    discard c.text(tiers, row, left + inset, width - 2 * inset,
                   "Glyph tiers, " & running.word, ink, bold = true)
    inc row
    for (name, profile) in PieStoryTiers:
      let line = c.node(tiers, row, left, width, 1, [("pie-tier", name)])
      discard c.text(line, row, left + inset, labelCells, name, ink)
      for i, pie in running.pies:
        discard c.pie(line, row, columnAt(i), pie, c.p.ground, profile)
      inc row
    inc row
    for i in PieStoryReaderColumns:
      let words = running.pies[i].pieText(GlyphProfile(tier: tierAscii, quiet: true))
      let line = c.node(tiers, row, left, width, 1, [("pie-reader", PieStoryColumns[i])])
      discard c.text(line, row, left + inset, width - 2 * inset,
                     "reader: " & words, ink, fact = "pie-words")
      inc row
