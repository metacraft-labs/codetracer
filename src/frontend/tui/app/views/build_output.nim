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

import ../build_session
import ../layout/profile
import ./styled_row

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

  BuildPaneScreen* = object
    rows*: seq[StyledRow]
    area*: CellArea
    renderedLines*: int

const
  BuildPaneTitle* = "BUILD"
  BuildPaneRule* = "─"
  BuildRuleStyle* = CellStyle(fg: "bright_black")
  BuildOutputStyle* = CellStyle(fg: "white")
  BuildTruncatedStyle* = CellStyle(fg: "yellow", italic: true)
  TruncatedNote* = "… earlier output dropped"

proc verdictStyle*(verdict: BuildVerdict): CellStyle =
  ## ONE COLOUR PER VERDICT, NO TWO THE SAME, on exactly the rule
  ## `status_bar.modeStyle` states: a Tier-2 case reads the cell's colour to
  ## say which verdict it is looking at, and two verdicts sharing a colour
  ## would be indistinguishable to that assertion.
  case verdict
  of bvIdle: CellStyle(fg: "bright_black", bold: true)
  of bvRunning: CellStyle(fg: "cyan", bold: true)
  of bvSucceeded: CellStyle(fg: "green", bold: true)
  of bvFailed: CellStyle(fg: "red", bold: true)
  of bvCancelled: CellStyle(fg: "yellow", bold: true)

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

proc paintBuildOutput*(g: var StyledGrid; area: CellArea;
                       model: BuildPaneModel): BuildPaneScreen =
  result = BuildPaneScreen(rows: @[], area: area, renderedLines: 0)
  if area.width <= 0 or area.height <= 0:
    return
  var parts = @[
    StyledSpan(text: BuildPaneTitle, style: verdictStyle(model.verdict)),
    StyledSpan(text: " [" & $model.verdict & "]",
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
  if used < area.width:
    g.paint(area.row, area.col + used,
            repeatGlyph(BuildPaneRule, area.width - used), BuildRuleStyle)
  result.rows.add parts

  var row = area.row + 1
  let lastRow = area.row + area.height - 1
  if model.truncated and row <= lastRow:
    g.paint(row, area.col, truncateToCells(TruncatedNote, area.width),
            BuildTruncatedStyle)
    result.rows.add @[StyledSpan(text: TruncatedNote,
                                 style: BuildTruncatedStyle)]
    inc row
  var i = model.scrollTop
  while row <= lastRow and i < model.lines.len:
    let text = truncateToCells(model.lines[i], area.width)
    g.paint(row, area.col, text, BuildOutputStyle)
    result.rows.add @[StyledSpan(text: text, style: BuildOutputStyle)]
    inc result.renderedLines
    inc row
    inc i
