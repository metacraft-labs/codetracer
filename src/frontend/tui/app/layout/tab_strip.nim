## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. Nothing here touches a terminal: this module is integer
## arithmetic over a list of titles.
##
## app/layout/tab_strip.nim — PLAT-6. WHERE TAB `i` SITS on a stack's first
## row, as ONE answer that the painter and the hit-test both read.
##
## ## Why this is its own module rather than a helper in `views/shell.nim`
##
## PLAT-6's medium-specific obligation is a hit-test in BOTH directions: a
## cell has to resolve to a tab, and a tab has to resolve back to the cells a
## renderer highlights. Before this module, `tabRow` in `app/views/shell.nim`
## was the only thing that knew a stack's tab strip is `[Variables] Timeline
## Tracepoints ───`, and it knew it by BUILDING THE STRING — the column of tab
## `i` existed only as a side effect of concatenation.
##
## A hit-test written against that would have been a second copy of the same
## arithmetic in a second FILE, and the two would have agreed until the first
## time either changed. So the arithmetic moved here and became a value
## (`TabSpan`), which is what the hit-test reads.
##
## **STATED EXACTLY, BECAUSE THE DIFFERENCE MATTERS. `tabRow` NOW CALLS
## `tabSpans`.** PLAT-6 landed it as a second traversal that merely SHARED
## `tabLabel` and `TabGapCells`, so "which tab is at column 34" had one answer
## by ASSERTION rather than by construction; the follow-up that note named is
## taken here. The painter walks the span table and fills to each span's
## `startCol` — it computes no gap of its own and no cursor of its own — so a
## painted column and a hit-tested column cannot come apart, whatever either
## quantity is changed to.
##
## **AND THAT MOVES WHERE THE EVIDENCE HAS TO COME FROM, which is the whole
## cost of a one-table design.** An agreement asserted between two traversals
## catches a defect introduced on either side; an agreement CONSTRUCTED from
## one table is blind to a defect IN that table, exactly as the two directions
## of `binding.pointerAt` / `binding.cellsFor` are blind to a change in the
## `edgeBandCells` they share. So `app/tests/test_layout_binding.nim` carries
## both halves:
##
##   * the column-by-column walk of a REAL PAINTED strip against the hit-test,
##     which still fails if the painter stops following the table (the harness
##     arm that gives it its own gap back);
##   * an ABSOLUTE oracle — §3.1's label rule, written out a second time in the
##     test and calling nothing in this module — which is what fails when the
##     shared table itself is wrong (the harness arm that widens
##     `TabGapCells`). A differential check between two readers of one table
##     cannot see that, and saying so is cheaper than discovering it.
##
## `app/views/shell.nim` imports and RE-EXPORTS this module, so every CTUI-3
## call site — and every golden written against the strings `tabRow` produces —
## resolves unchanged and paints byte-identical rows.
##
## ## The label rule, stated once
##
## §3.1's Compact drawing shows `[Variables] Timeline Tracepoints`: the active
## tab is bracketed and the inactive ones are space-padded, so EVERY label is
## `title.len + 2` cells wide whichever one is active and the strip does not
## reflow when a tab is activated. One space separates neighbouring labels.
## That constancy is not cosmetic — it is what makes a drop caret computed on
## one frame land on the same column on the next.

import ../views/header
import ../views/styled_row

type
  TabSpan* = object
    ## One label's extent on the strip, in cells RELATIVE to the strip's own
    ## first column. A renderer adds its rectangle's origin; a hit-test
    ## subtracts it. No absolute coordinate lives here, so the same span serves
    ## a pane wherever the projection put it.
    index*: int
      ## Which child of the stack. An INDEX INTO THE MODEL, the way
      ## `layout_model` counts `stack.children`.
    startCol*: int
    width*: int
      ## `textCells` of the label, including its two framing cells.

const
  PaneRuleGlyph* = "─"
    ## What fills the rest of a title or tab row. One cell wide (U+2500), so
    ## the row's cell count is its rune count. CTUI-3 declared this in
    ## `app/views/shell.nim`; it moved here with `tabRow`, and `shell.nim`
    ## re-exports it so `app/views/borders.nim`'s comment and every existing
    ## reference still resolve.

  TabGapCells* = 1
    ## One cell between neighbouring labels. Named rather than spelled `" "` at
    ## three sites, because the hit-test has to know which side of the gap a
    ## column falls on and a literal cannot be asked.

  ActiveTabOpen* = "["
  ActiveTabClose* = "]"
    ## §3.1's brackets around the active tab.

proc tabLabel*(title: string; active: bool): string =
  ## What tab `i` reads as. Two framing cells in both states — see the module
  ## header on why an active tab must not be wider than an inactive one.
  if active: ActiveTabOpen & title & ActiveTabClose else: " " & title & " "

proc tabSpans*(tabs: seq[string]; active: int): seq[TabSpan] =
  ## Where each label sits, left to right.
  ##
  ## Computed for EVERY tab regardless of the strip's width, and clipped by the
  ## caller: a span that starts past the right edge is still the truthful
  ## answer to "where would tab 4 be", and `tabSpanAt` below is what decides
  ## whether a given column reaches it.
  result = @[]
  var cursor = 0
  for i, t in tabs:
    if i > 0:
      cursor += TabGapCells
    let w = textCells(tabLabel(t, i == active))
    result.add TabSpan(index: i, startCol: cursor, width: w)
    cursor += w

proc tabStripCells*(tabs: seq[string]; active: int): int =
  ## How many cells the labels occupy in total, gaps included. The boundary
  ## between "over a tab" and "over the filler rule" — and therefore between
  ## §4.2's `dzTabStrip` and `dzCentre`.
  let spans = tabSpans(tabs, active)
  if spans.len == 0: 0 else: spans[^1].startCol + spans[^1].width

proc tabSpanAt*(tabs: seq[string]; active, col: int): int =
  ## Which tab the RELATIVE column `col` is over, or -1 for a gap, for the
  ## filler past the last label, or for a column outside the strip.
  ##
  ## -1 rather than a nearest-tab guess: a gap cell is genuinely not over a
  ## tab, and a hit-test that rounded would make the strip's two halves behave
  ## differently for no reason a user could see.
  if col < 0:
    return -1
  for span in tabSpans(tabs, active):
    if col >= span.startCol and col < span.startCol + span.width:
      return span.index
  -1

proc tabSlotCaret*(tabs: seq[string]; active, slot: int): int =
  ## The RELATIVE column a drop caret is drawn at for insertion `slot`.
  ##
  ## `slot` is counted the way `lcMoveTab`'s index is: `0` is before the first
  ## tab, `tabs.len` is after the last. So the caret sits on the first cell of
  ## tab `slot`, and one cell past the end of the last label for the final
  ## slot. Clamped, so an out-of-range slot draws at an end rather than
  ## nowhere.
  let spans = tabSpans(tabs, active)
  if spans.len == 0:
    return 0
  if slot <= 0:
    return spans[0].startCol
  if slot >= spans.len:
    return spans[^1].startCol + spans[^1].width
  spans[slot].startCol

proc tabRow*(tabs: seq[string]; active, width: int): string =
  ## `[Variables] Timeline Tracepoints ─────` — a stack's first row.
  ##
  ## CTUI-3 wrote this in `app/views/shell.nim` and PLAT-6 moved it here beside
  ## `tabSpans` — the table the hit-test reads. **IT IS ASSEMBLED FROM THAT
  ## TABLE.** The loop below owns no gap and no cursor of its own: it advances
  ## to the column `tabSpans` put each label at, so the painted strip is a
  ## rendering of the same values `tabSpanAt` and `tabSlotCaret` answer from.
  ## The two cannot disagree, which is a stronger statement than "they are
  ## asserted to agree" and is why the module header now says what the test has
  ## to do instead.
  ##
  ## Byte-identical to the traversal it replaces, and not by inspection:
  ## `tabSpans` places span 0 at column 0 and every later span exactly
  ## `TabGapCells` past the previous one's end, so filling to `startCol`
  ## produces the same single space the old `repeat(' ', TabGapCells)` did.
  ## CTUI-3's goldens and `tests/real_terminal/test_real_shell_geometry.nim`
  ## are what hold that to be true rather than this sentence.
  ##
  ## The active tab is bracketed, which is exactly what §3.1's Compact drawing
  ## shows. This row is the ONLY on-screen consequence of `LayoutNode.activate`,
  ## so `test_layout_profiles.nim` asserts it moves when `activate` is called.
  if width <= 0:
    return ""
  var line = ""
  var cursor = 0
  for span in tabSpans(tabs, active):
    while cursor < span.startCol:
      line.add ' '
      inc cursor
    line.add tabLabel(tabs[span.index], span.index == active)
    cursor = span.startCol + span.width
  if textCells(line) + 1 <= width:
    line.add " "
    # `repeatGlyph` rather than `while textCells(line) < width: line.add …` —
    # see `styled_row.repeatGlyph` for why the obvious spelling is quadratic.
    line.add repeatGlyph(PaneRuleGlyph, width - textCells(line))
  fitCells(line, width)
