## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/tui_session.agentModelOf` turns the shared
## `AgentActivityVM` into the model below, through `agent_activity_feed`).
##
## app/views/agent_activity_pane.nim — PLAT-54. **THE AGENT ACTIVITY PANE.**
##
## The desktop's AGENT ACTIVITY panel (`viewmodel/views/
## isonim_agent_activity_view.nim`) draws the agent session's own content —
## what the agent said, ran and produced — and below it the prompt. This pane
## draws the same rows (`agent_activity_feed.agentFeed`, which walks the
## desktop's ViewModel in the desktop's order with the desktop's words), one
## per line or wrapped to the pane, and the prompt on its last row:
##
##     ▾ Thought for 3s
##       Looking at the parser.
##       ● grep -n parse src/
##     ▌ Collected review evidence  4 files · a1b2c3d4…  [Open review]
##       /tmp/evidence/iteration-1.json
##       ct review collect … -o /tmp/evidence/iteration-1.json
##     ▌ ▸ ct test record --json-events  1 passed, 1 failed · 95ms
##     › Ask for a change, or type a follow-up…                    [Send]
##
## A press on a row runs the row's action (expand a turn, a run, a test, a
## tool group), on a `[button]` the button's (open a recording, in this tab or
## a new one; open a review); the prompt row opens the omnibox on `/ai `
## (the terminal's field is the omnibox, as Find in Files' is); the rightmost
## column is the scrollbar scrubber over the WHOLE session when it overflows
## (Scrollbar-Scrubbers.md: a list scrubber moves the VIEW). Rows that arrive
## while the agent works keep the reader where they were
## (`agent_activity_feed.FeedScroll`).

import codetracer_embed   # `agent_activity_feed`'s rows, behind the facade

import ../layout/profile
import ../layout/project
import ./header
import ./styled_row
import ./scrubber_track

export styled_row, profile, scrubber_track

type
  AgentPaneModel* = object
    loaded*: bool
      ## Whether a session supplied the pane at all.
    rows*: seq[AgentFeedRow]
    prompt*: string
      ## What the prompt row shows: the typed prompt, or the placeholder.
    promptIsPlaceholder*: bool
    working*: bool
      ## The agent is at work: the prompt's control is Stop, not Send.
    scroll*: FeedScroll
      ## The reader's position, kept across re-derived rows.

  AgentPaneTargetKind* = enum
    atNone, atRow, atButton, atPrompt, atSend, atStop, atTrack

  AgentPaneTarget* = object
    kind*: AgentPaneTargetKind
    row*: int
      ## atRow / atButton: the feed row.
    button*: int
      ## atButton: the row's button.

  AgentPaneScreen* = object
    listTop*, listRows*: int
    width*: int
      ## The lines' width (the scrubber column off when it overflows).
    trackCol*: int
      ## The scrubber's column, -1 when the session fits.
    top*: int
      ## The first line shown.
    lines*: seq[AgentFeedLine]
    promptRow*: int
    controlCol*: int
      ## Where `[Send]` / `[Stop]` starts on the prompt row.
    painted*: seq[string]
      ## Every painted line's text, in order (for the suites).

const
  AgentSendLabel* = "[Send]"
  AgentStopLabel* = "[Stop]"
  AgentPromptMark* = canonical(grOverflowRight) & " "
    ## The prompt row's mark as the extended tier draws it; the painter draws
    ## the terminal's own (`grOverflowRight`, `>` on ASCII).
  AgentOmnibarPrefix* = AgentOmnibarQuery
    ## The omnibox's agent mode, the desktop's (`agent_activity_feed`).
  AgentTextStyle = CellStyle(role: srChromeText)
  AgentMutedStyle = CellStyle(role: srChromeMuted)
  AgentHeadingStyle = CellStyle(role: srChromeTitle, bold: true)
  AgentCodeStyle = CellStyle(role: srChromeAccent)
  AgentErrorStyle = CellStyle(role: srChromeError)
  AgentAddedStyle = CellStyle(role: srChromeSuccess)
  AgentButtonStyle = CellStyle(role: srChromeAccent, bold: true)
  AgentPromptStyle = CellStyle(role: srChromeText, surface: srSurfaceInput)
  AgentPlaceholderStyle = CellStyle(role: srChromeMuted, surface: srSurfaceInput,
                                    italic: true)
  AgentControlStyle = CellStyle(role: srChromeAccent, surface: srSurfaceInput,
                                bold: true)

proc styleOf*(s: AgentFeedSpan): CellStyle =
  case s.style
  of fsPlain: AgentTextStyle
  of fsCode: AgentCodeStyle
  of fsBold: CellStyle(role: srChromeText, bold: true)
  of fsItalic: CellStyle(role: srChromeText, italic: true)
  of fsBoldItalic: CellStyle(role: srChromeText, bold: true, italic: true)
  of fsStrike: CellStyle(role: srChromeText, dim: true)
  of fsMuted: AgentMutedStyle
  of fsHeading: AgentHeadingStyle
  of fsError: AgentErrorStyle
  of fsAdded: AgentAddedStyle
  of fsRemoved: AgentErrorStyle
  of fsButton: AgentButtonStyle

proc stateStyle*(state: string): CellStyle =
  ## The colour of a row's state mark — the desktop's card / dot modifier.
  case state
  of "done", "passed", "ready": CellStyle(role: srChromeSuccess)
  of "failed", "errored", "unavailable": CellStyle(role: srChromeError)
  of "running", "reading": CellStyle(role: srChromeInfo)
  else: AgentMutedStyle

proc cellMeasure*(text: string): int = cellWidthOf(text)

proc layoutAgent*(model: AgentPaneModel; area: CellArea): AgentPaneScreen =
  ## Where everything goes in `area` (the rows below the pane's tab strip):
  ## the lines, the scrubber column when they overflow, the prompt row — and
  ## the view's top, settled from the model's scroll over these lines.
  result = AgentPaneScreen(trackCol: -1, promptRow: -1, controlCol: -1)
  if area.width <= 0 or area.height <= 0:
    return
  result.promptRow = area.row + area.height - 1
  result.listTop = area.row
  result.listRows = max(0, area.height - 1)
  let marked = markedRows(model.rows)
  var lines = wrapFeed(marked, area.width, cellMeasure)
  result.width = area.width
  if lines.len > result.listRows and area.width > 2:
    result.width = area.width - ScrubberTrackCells
    result.trackCol = area.col + area.width - ScrubberTrackCells
    lines = wrapFeed(marked, result.width, cellMeasure)
  var scroll = model.scroll
  scroll.settle(marked, lines, result.listRows)
  result.top = scroll.top
  result.lines = lines
  let label = if model.working: AgentStopLabel else: AgentSendLabel
  if area.width > textCells(label) + 4:
    result.controlCol = area.col + area.width - textCells(label)

proc scrubberOf*(screen: AgentPaneScreen): ScrubberModel =
  scrubberModel(screen.lines.len, screen.top, screen.listRows)

proc paintAgentActivity*(g: var StyledGrid; area: CellArea;
                         model: AgentPaneModel): AgentPaneScreen =
  ## The pane into `area` and nowhere else.
  result = model.layoutAgent(area)
  if area.width <= 0 or area.height <= 0:
    return
  let marked = markedRows(model.rows)
  for k in 0 ..< result.listRows:
    let i = result.top + k
    if i >= result.lines.len:
      break
    let line = result.lines[i]
    let row = marked[line.row]
    var col = area.col
    var text = ""
    for si, s in line.spans:
      let used = col - area.col
      if used >= result.width:
        break
      let fitted = truncateToCells(s.text, result.width - used)
      if fitted.len == 0:
        continue
      let style =
        if si <= 1 and line.part == 0 and row.markOf().len > 0 and
           s.text == row.markOf(): stateStyle(row.state)
        else: styleOf(s)
      g.paint(result.listTop + k, col, fitted, style)
      text.add fitted
      col += cellWidthOf(fitted)
    result.painted.add text
  if result.trackCol >= 0:
    g.paintVerticalScrubber(result.trackCol, result.listTop, result.listRows,
                            result.scrubberOf())
  # The prompt row: the field, and its control at the right edge.
  g.fillSurface(result.promptRow, area.col, area.width, 1, srSurfaceInput)
  let mark = g.glyphText(grOverflowRight) & " "
  let field = max(0, (if result.controlCol >= 0: result.controlCol - area.col - 1
                      else: area.width) - textCells(mark))
  g.paint(result.promptRow, area.col, mark, AgentPromptStyle)
  g.paint(result.promptRow, area.col + textCells(mark),
          fitCells(model.prompt, field),
          if model.promptIsPlaceholder: AgentPlaceholderStyle
          else: AgentPromptStyle)
  if result.controlCol >= 0:
    g.paint(result.promptRow, result.controlCol,
            (if model.working: AgentStopLabel else: AgentSendLabel),
            AgentControlStyle)

proc agentTargetAt*(model: AgentPaneModel; screen: AgentPaneScreen;
                    area: CellArea; row, col: int): AgentPaneTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  if area.width <= 0 or not area.contains(row, col):
    return AgentPaneTarget(kind: atNone)
  if row == screen.promptRow:
    if screen.controlCol >= 0 and col >= screen.controlCol:
      return AgentPaneTarget(kind: (if model.working: atStop else: atSend))
    return AgentPaneTarget(kind: atPrompt)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row >= screen.listTop and row < screen.listTop + screen.listRows:
    return AgentPaneTarget(kind: atTrack)
  if row < screen.listTop or row >= screen.listTop + screen.listRows:
    return AgentPaneTarget(kind: atNone)
  let i = screen.top + (row - screen.listTop)
  if i < 0 or i >= screen.lines.len:
    return AgentPaneTarget(kind: atNone)
  let line = screen.lines[i]
  var at = area.col
  for s in line.spans:
    let w = cellWidthOf(s.text)
    if s.button > 0 and col >= at and col < at + w:
      return AgentPaneTarget(kind: atButton, row: line.row,
                             button: s.button - 1)
    at += w
  AgentPaneTarget(kind: atRow, row: line.row)
