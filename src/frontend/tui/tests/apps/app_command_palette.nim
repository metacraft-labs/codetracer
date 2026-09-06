## app_command_palette.nim — CTUI-10 snapshot app: the fuzzy command palette,
## as a screen.
##
## One component tree, exported so the Tier-1 half of the cross-tier suite
## composites the SAME proc in process that this binary composites in a pty.
##
## ## WHY THIS APP EXISTS, AND IT IS A RULE RATHER THAN A CHOICE
##
## `docs/tui-testing.md`: *"A new pane needs exactly one cross-tier equivalence
## test. Not zero, and not one per assertion."* CTUI-10 adds one new pane — the
## palette overlay — and this is its case. Before it passes, every Tier-1
## golden the palette records is a screenshot of a model; after it passes, they
## are evidence.
##
## `command_line.nim`'s prompt is NOT a new pane: it renders into §3.3.6's
## bottommost region, whose cross-tier grounding is CTUI-3's `app_shell.nim`
## case, and a second equality run over the same rendering path would prove
## nothing the first did not.
##
## ## PURE FUNCTION OF THE GEOMETRY, WHICH IS WHAT MAKES THE COMPARISON MEAN
## ## ANYTHING
##
## The index is §4.3's own `const` table and the query is a `const`, so the
## tree depends on nothing but `cols` and `rows`. `runDualSnap` mounts this
## proc in the test process AND runs this binary in a pty; if the tree depended
## on a file, a clock or an environment variable the two would be two different
## programs and their agreement would say nothing about the renderer.
##
## The palette is drawn OPEN with a query that matches several commands, so the
## screen carries every visual distinction the pane has: the title rule, the
## prompt, the selected row's reverse-video background, the accented match
## columns, and unmatched rows beneath.

import isonim_tui

import ../../app/commands/interpreter
import ../../app/views/command_palette
import ../../app/views/header
import ../../app/views/styled_row

const
  PaletteQuery* = "re"
    ## Matches §4.3's three `reverse-*` commands and several others, so the
    ## painted screen has more than one row and more than one accented column.
  PaletteTop* = 1
  PaletteRows* = 10

proc paletteModel*(): PaletteModel =
  ## §4.3's table as an open palette. A `proc` rather than a `let`, so two
  ## processes build it the same way rather than sharing a module-level value
  ## whose initialisation order they could differ on.
  var entries: seq[PaletteEntry] = @[]
  for spec in Spec43Commands:
    entries.add commandEntry(spec.name, spec.summary, spec.argument)
  result = initPaletteModel(entries)
  discard result.open()
  discard result.setQuery(PaletteQuery)

proc paint*(g: var StyledGrid; cols, rows: int) =
  if cols <= 0 or rows <= 0:
    return
  var title = "CTUI-10 PALETTE "
  title.add repeatGlyph("─", max(0, cols - textCells(title)))
  g.paint(0, 0, fitCells(title, cols))
  paint(g, paletteModel(), PaletteTop, 0, cols, min(PaletteRows, rows - 1))

proc rowsFor*(cols, rows: int): seq[string] =
  var g = newStyledGrid(cols, rows)
  paint(g, cols, rows)
  result = @[]
  for row in 0 ..< rows:
    result.add g.rowText(row)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  var g = newStyledGrid(cols, rows)
  paint(g, cols, rows)
  var out2: seq[StyledRow] = @[]
  for row in 0 ..< rows:
    out2.add g.rowSpans(row)
  styledRowsTree(r, out2)

when isMainModule:
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(buildTree, commandLineParams()))
