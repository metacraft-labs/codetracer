## app_source_pane.nim — CTUI-5 snapshot app: the source pane.
##
## One component tree, exported so the Tier-1 half of
## `tests/real_terminal/test_real_source_pane.nim` composites the SAME proc in
## process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime, the frame barrier and the
## F10 step key.
##
## ## This is the pane's ONE cross-tier equivalence test
##
## `docs/tui-testing.md`: "a new pane needs exactly one cross-tier equivalence
## test. Not zero, and not one per assertion." This app is the source pane's,
## and everything else CTUI-5 asserts about the pane is Tier-1 work.
##
## ## THE TREE SHOWS BOTH PROVENANCES AT ONCE, AND THAT IS THE POINT
##
## CTUI-5: "A file served `savUnverified` (working-tree) must not look
## identical to one served `savVerified`." A screen carrying only one of them
## could not settle that on a real terminal — a marker and a tint are only
## evidence next to the thing they differ from. So the app paints the SAME
## source window twice, one pane above the other: the top half `gpVerified`,
## the bottom half `gpUnverified`. The Tier-2 suite then reads both line-number
## colours and both markers off a real screen with `cellAt`, and the difference
## is a fact about a terminal rather than about a style struct.
##
## ## The model is a constant, and the language is Nim on purpose
##
## `sourceModel` reads nothing and takes only the geometry and the step, so the
## same tree is painted in both tiers — the construction CTUI-2's "one
## `buildTree`, two ways" exists to guarantee.
##
## The sample is NIM rather than the fixture corpus's Python, because Nim has a
## VENDORED TREE-SITTER GRAMMAR in `build/grammars/libcodetracer_tui_grammars.a`
## and Python does not. So the colours a terminal is asked to reproduce here
## come from a real grammar walk, which is the path CTUI-5's highlighting
## deliverable is really about; the lexical fallback is asserted at Tier 1,
## where it costs nothing.
##
## ## F10 moves the execution pointer
##
## The runtime increments a step counter on `\x1b[21~` and repaints. `step`
## selects which line the pointer is on, so `sendKey("f10")` at Tier 2 is a
## real step of this pane, and the Tier-2 suite asserts the pointer row moved
## and that the row it moved to carries the accent colour a terminal shows.

import isonim_tui

import ../../app/views/source_pane

const
  SampleLines* = @[
    "## a module that exists to be highlighted",
    "",
    "import std/strutils",
    "",
    "type Greeting* = object",
    "  name*: string",
    "  count*: int",
    "",
    "proc greet*(g: Greeting): string =",
    "  ## Build the greeting.",
    "  let prefix = \"hello \"",
    "  result = prefix & g.name",
    "  for i in 0 ..< g.count:",
    "    result.add \"!\"",
    "",
    "when isMainModule:",
    "  echo greet(Greeting(name: \"world\", count: 3))"]

  SamplePath* = "/opt/ctui5/sample/greeter.nim"
  PointerLines* = [11, 12, 14]
    ## Which line the execution pointer sits on at step 0, 1 and 2. All three
    ## are inside the window and inside the pane's height at both geometries,
    ## so a step is a visible move rather than a scroll.

  SampleMarks* = @[(3, gmBreakpoint), (9, gmBreakpointDisabled),
                   (13, gmTracepoint)]
    ## One of each §3.3.2 indicator, so the Tier-2 read has all three to check
    ## and "breakpoint red" is a colour a terminal really showed.

  SampleValues* = @[Annotation(name: "prefix", value: "\"hello \""),
                    Annotation(name: "count", value: "3")]

proc sourceModel*(step: int; provenance: GutterProvenance): SourcePaneModel =
  initSourcePaneModel(
    path = SamplePath,
    revisionLabel = "",
    provenance = provenance,
    firstHeldLine = 1,
    heldLines = SampleLines,
    totalLineCount = SampleLines.len,
    viewportTop = 1,
    executionLine = PointerLines[step mod PointerLines.len],
    marks = SampleMarks,
    values = SampleValues)

proc paneHeights*(rows: int): tuple[top, bottom: int] =
  ## How the screen is split between the two provenance panes.
  ##
  ## The TOP pane takes the ceiling, so an odd number of rows leaves the
  ## verified pane one row taller rather than dropping a row on the floor —
  ## `test_real_source_pane.nim` asserts the two heights sum to `rows`.
  let top = (rows + 1) div 2
  (top: top, bottom: rows - top)

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  ## The whole screen: the verified pane above, the unverified one below.
  var g = newStyledGrid(cols, rows)
  let h = paneHeights(rows)
  discard paintSourcePane(
    g, CellArea(col: 0, row: 0, width: cols, height: h.top),
    sourceModel(step, gpVerified))
  if h.bottom > 0:
    discard paintSourcePane(
      g, CellArea(col: 0, row: h.top, width: cols, height: h.bottom),
      sourceModel(step, gpUnverified))
  var rowsOut: seq[StyledRow] = @[]
  for row in 0 ..< rows:
    rowsOut.add g.rowSpans(row)
  styledRowsTree(r, rowsOut)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  ## The un-stepped shape, for `runDualSnap`'s sized overload.
  buildTree(r, cols, rows, 0)

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an unused
  # runtime with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams()))
