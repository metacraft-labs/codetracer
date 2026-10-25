## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/build_output.nim — PLAT-16. Edit mode's `paneBuildOutput`.
##
## A PANE AND NOT A MODAL, which is CodeTracer-TUI-Edit-Mode.md §5's decision
## verbatim: *"Failure output belongs in a pane, not a modal. A compiler error
## list is something a user navigates while editing, which is the argument for
## `paneBuildOutput` over an overlay."*
##
## THE VERDICT IS ON THE TITLE ROW AND IN A COLOUR, both. A `regionText` read
## carries no colour, so a verdict expressed only in the palette would be
## invisible to a Tier-2 read; a verdict expressed only in words would be
## invisible to somebody skimming. `test_edit_mode_build.nim` asserts both.

import codetracer_embed

import ../build_session
import ../layout/profile
import ./styled_row
import ./scrubber_track

export styled_row, profile, build_session

type
  BuildPaneModel* = object
    ## Everything the build pane shows, as a value.
    verdict*: BuildVerdict
    headline*: string
      ## `build_session.describeVerdict`'s line, carried rather than recomputed
      ## so the pane and the status bar say the same thing.
    lines*: seq[string]
    truncated*: bool
    scrollTop*: int
    hview*: HorizontalView
      ## PLAT-70 (Horizontal-Overflow.md §4): the output's horizontal view —
      ## the pane's own (`BuildView`), its content the widest line measured
      ## so far of this build.
    overflowMarkers*: bool
      ## `view.overflow-markers` (§4.6).

  BuildView* = object
    ## PLAT-70: what the pane keeps across frames — the view, and the widest
    ## line measured so far of the build it is showing (§4.1).
    hview*: HorizontalView
    widths*: ContentWidth

  BuildPaneScreen* = object
    rows*: seq[StyledRow]
    area*: CellArea
    renderedLines*: int
    barRow*: int
      ## PLAT-70: the horizontal bar's row, -1 when the output fits.

const
  BuildOutputStyle* = CellStyle(role: srChromeText)
  BuildTruncatedStyle* = CellStyle(role: srChromeNotification, italic: true)
  TruncatedNote* = canonical(grTruncation) & " earlier output dropped"

proc verdictStyle*(verdict: BuildVerdict): CellStyle =
  ## ONE COLOUR PER VERDICT, NO TWO THE SAME, on exactly the rule
  ## `status_bar.modeStyle` states: a Tier-2 case reads the cell's colour to
  ## say which verdict it is looking at, and two verdicts sharing a colour
  ## would be indistinguishable to that assertion.
  case verdict
  of bvIdle: CellStyle(role: srBuildIdle)
  of bvRunning: CellStyle(role: srBuildRunning)
  of bvSucceeded: CellStyle(role: srBuildSucceeded)
  of bvFailed: CellStyle(role: srBuildFailed)
  of bvCancelled: CellStyle(role: srBuildCancelled)

proc initBuildPaneModel*(verdict = bvIdle; headline = "";
                         lines: seq[string] = @[]; truncated = false;
                         scrollTop = 0): BuildPaneModel =
  BuildPaneModel(verdict: verdict, headline: headline, lines: lines,
                 truncated: truncated, scrollTop: scrollTop)

proc buildPaneModelFor*(s: BuildSession): BuildPaneModel =
  if s.isNil:
    return initBuildPaneModel(headline = describeVerdict(nil))
  initBuildPaneModel(verdict = s.verdict, headline = describeVerdict(s),
                     lines = s.lines, truncated = s.truncated)

proc measureContent*(v: var BuildView; s: BuildSession) =
  ## §4.1: the widest line measured so far of THIS build — a new build (a
  ## new `BuildSession`) starts again from nothing; the same one only grows.
  let generation = if s.isNil: 0 else: cast[int](s)
  let lines = if s.isNil: @[] else: s.lines
  v.hview.setContent(v.widths.measureLines(generation, lines, cellWidthOf))

proc buildBarOf*(model: BuildPaneModel; area: CellArea):
    tuple[shown: bool; row, left, cols: int; view: HorizontalView] =
  ## PLAT-70: where `paintBuildOutput` draws the horizontal bar in `area`
  ## (the rows below the strip), and the view it is drawn over.
  var view = model.hview
  view.setViewport(area.width)
  (shown: view.overflows and area.height >= 3,
   row: area.row + area.height - 1, left: area.col, cols: area.width,
   view: view)

proc paintBuildOutput*(g: var StyledGrid; area: CellArea;
                       model: BuildPaneModel): BuildPaneScreen =
  result = BuildPaneScreen(rows: @[], area: area, renderedLines: 0,
                           barRow: -1)
  if area.width <= 0 or area.height <= 0:
    return
  # PLAT-49: NO TITLE BAR — the tab strip above the pane names it. The
  # first row is the build's VERDICT (`[idle] build: not started`), content
  # a user watches change, without a `BUILD ───` heading or rule.
  var parts = @[
    StyledSpan(text: "[" & $model.verdict & "]",
               style: verdictStyle(model.verdict))]
  if model.headline.len > 0:
    parts.add StyledSpan(text: " " & model.headline, style: BuildOutputStyle)
  var used = 0
  for span in parts:
    let fitted = truncateToCells(span.text, max(0, area.width - used))
    if fitted.len == 0:
      continue
    g.paint(area.row, area.col + used, fitted, span.style)
    used += cellWidthOf(fitted)
  result.rows.add parts

  let bar = model.buildBarOf(area)
  let view = bar.view
  var row = area.row + 1
  let lastRow = area.row + area.height - 1 - (if bar.shown: 1 else: 0)
  if model.truncated and row <= lastRow:
    let note = g.glyphText(grTruncation) & " earlier output dropped"
    g.paint(row, area.col, truncateToCells(note, area.width),
            BuildTruncatedStyle)
    result.rows.add @[StyledSpan(text: note,
                                 style: BuildTruncatedStyle)]
    inc row
  var i = model.scrollTop
  while row <= lastRow and i < model.lines.len:
    let text = cellSlice(model.lines[i], view.leftCol,
                         view.leftCol + area.width)
    g.paint(row, area.col, text, BuildOutputStyle)
    if model.overflowMarkers:
      paintOverflowMarkers(g, row, area.col, cellWidthOf(model.lines[i]), view)
    result.rows.add @[StyledSpan(text: text, style: BuildOutputStyle)]
    inc result.renderedLines
    inc row
    inc i
  if bar.shown:
    result.barRow = bar.row
    paintHorizontalBar(g, bar.row, bar.left, bar.cols, view.barModel)
