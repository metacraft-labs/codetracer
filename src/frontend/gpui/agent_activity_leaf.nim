## gpui/agent_activity_leaf.nim — PLAT-54. The GPUI window's **Agent
## Activity** pane, drawn natively from the desktop's own `AgentActivityVM`
## through the shared feed (`viewmodels/agent_activity_feed`, the rows the
## terminal's pane draws too).
##
## What the desktop's panel draws, in its order and words: a review's session
## notice, then the session — the user's turns, the agent's turns (their
## header, text, tool-call groups and the promoted final text), each `ct test`
## run as a summary card that opens to its tests and their recordings, each
## evidence handoff as a card that opens its review — then the prompt, its
## Send (or, while the agent works, Stop), and beside it the desktop's `+`,
## the "add context" menu (DeepReview-GUI.md §2.2.7), whose attachments are
## rows at the end of the feed. Rows wrap to the pane and have a
## fixed pitch, so a press and the drawing go through the same layout
## (`agentLayout`); the list scrolls (the wheel), its scrollbar is the shared
## scrubber over the WHOLE session (`list_scrubber`), and rows that arrive
## while the agent works keep the reader where they were (`FeedScroll`).
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-agent-*`).

import isonim_gpui/renderer

import codetracer_embed
import ./window_geometry
import ./chrome
import ./list_scrubber
import ./design_font_metrics
import ../viewmodel/viewmodels/agent_activity_feed
import ../styles/generated/design_tokens

export agent_activity_feed

type
  GAgentPane* = object
    ## The window's own state for the pane: where the reader is, and a held
    ## scrubber thumb.
    scroll*: FeedScroll
    dragging*: bool

  AgentLayout* = object
    body*: PxRect
    list*: PxRect
      ## The lines' area (the scrubber's column off when they overflow).
    prompt*: PxRect
    control*: PxRect
      ## Send / Stop, at the prompt's right edge.
    add*: PxRect
      ## The `+` ("add context"), just left of Send / Stop; empty when the
      ## pane is too narrow for it.
    rows*: int
      ## How many lines fit.
    overflow*: bool
    lines*: seq[AgentFeedLine]
    top*: int

  GAgentHitKind* = enum
    gaNone, gaRow, gaButton, gaPrompt, gaControl, gaTrack, gaThumb,
    gaAddContext

  GAgentHit* = object
    kind*: GAgentHitKind
    row*: int
    button*: int
    fraction*: float

const
  AgentRowPx* = 20
  AgentPromptPx* = 28
  AgentTextPx* = 13.0
  AgentControlPx* = 56
  AgentAddPx* = 28
    ## The `+` button's width (the desktop's 28 px `.agent-add-context-button`).
  AgentAddLabel* = "+"
  AgentAttribute* = "data-ct-agent"
  AgentLineAttribute* = "data-ct-agent-line"
    ## A painted line: its row's kind.
  AgentButtonAttribute* = "data-ct-agent-button"
  AgentTextColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  AgentMutedColour = DesignTokenHex[dtColorsUiTextPrimaryBodySubtle][dmDark]
  AgentHeadingColour = DesignTokenHex[dtColorsUiTextPrimaryHeadings][dmDark]
  AgentFieldGround = DesignTokenHex[dtColorsUiSurfaceInputDefault][dmDark]
  AgentSuccessColour = DesignTokenHex[dtColorsUiIconSuccessPrimary][dmDark]
  AgentErrorColour = DesignTokenHex[dtColorsUiIconErrorPrimary][dmDark]
  AgentInfoColour = DesignTokenHex[dtColorsUiIconInformationPrimary][dmDark]
  AgentCodeColour = DesignTokenHex[dtColorsUiIconInformationPrimary][dmDark]
  AgentSendLabel* = "Send"
  AgentStopLabel* = "Stop"
  AgentPromptMark = "› "

proc pxMeasure*(text: string): int =
  ## The pane's text measured as the window sets it.
  groteskTextPx(text, AgentTextPx)

proc agentLayout*(body: PxRect; rows: openArray[AgentFeedRow];
                  scroll: FeedScroll): AgentLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off), its
  ## lines wrapped to the width, and the view's top settled from `scroll`.
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  result.prompt = PxRect(x: inner.x, y: inner.y + max(0, inner.h - AgentPromptPx),
                         w: inner.w, h: min(inner.h, AgentPromptPx))
  result.control = PxRect(x: result.prompt.x + max(0, result.prompt.w -
                                                   AgentControlPx),
                          y: result.prompt.y + 2, w: min(result.prompt.w,
                                                         AgentControlPx - 4),
                          h: max(0, result.prompt.h - 4))
  if result.prompt.w > AgentControlPx + AgentAddPx + 40:
    result.add = PxRect(x: result.control.x - AgentAddPx + 4,
                        y: result.control.y,
                        w: AgentAddPx - 4, h: result.control.h)
  let listH = max(0, inner.h - AgentPromptPx - 2)
  result.rows = max(0, listH div AgentRowPx)
  let marked = markedRows(rows)
  var lines = wrapFeed(marked, max(1, inner.w), pxMeasure)
  result.overflow = lines.len > result.rows
  let w = if result.overflow: max(1, inner.w - ListTrackPx - 2) else: inner.w
  if result.overflow:
    lines = wrapFeed(marked, w, pxMeasure)
  result.list = PxRect(x: inner.x, y: inner.y, w: w,
                       h: result.rows * AgentRowPx)
  var s = scroll
  s.settle(marked, lines, result.rows)
  result.top = s.top
  result.lines = lines

proc listBody(lay: AgentLayout): PxRect =
  ## The rectangle the scrubber's track is placed in: the lines' rows, at
  ## the pane's right edge.
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc scrubberOf*(lay: AgentLayout): ScrubberModel =
  scrubberModel(lay.lines.len, lay.top, lay.rows)

proc colourOf(s: AgentFeedSpan): string =
  case s.style
  of fsPlain, fsBold, fsItalic, fsBoldItalic, fsStrike: AgentTextColour
  of fsCode: AgentCodeColour
  of fsMuted: AgentMutedColour
  of fsHeading, fsButton: AgentHeadingColour
  of fsError, fsRemoved: AgentErrorColour
  of fsAdded: AgentSuccessColour

proc stateColour*(state: string): string =
  ## A row's state mark — the desktop's card / dot modifier colour.
  case state
  of "done", "passed", "ready": AgentSuccessColour
  of "failed", "errored", "unavailable": AgentErrorColour
  of "running", "reading": AgentInfoColour
  else: AgentMutedColour

proc spanElement(r: GpuiRenderer; s: AgentFeedSpan; colour: string): GpuiElement =
  result = r.createElement("span")
  r.setStyle(result, "color", colour)
  r.setStyle(result, "white-space", "pre")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "font-size", $int(AgentTextPx) & "px")
  if s.style in {fsBold, fsBoldItalic, fsHeading, fsButton}:
    r.setStyle(result, "font-weight", "bold")
  if s.style in {fsItalic, fsBoldItalic}:
    r.setStyle(result, "font-style", "italic")
  if s.button > 0:
    r.setAttribute(result, AgentButtonAttribute, $(s.button - 1))
    r.setStyle(result, "background", AgentFieldGround)
    r.setStyle(result, "rounded", "3px")
  r.appendChild(result, r.createTextNode(s.text))

proc drawAgentActivity*(r: GpuiRenderer; pane: GpuiElement;
                        rows: seq[AgentFeedRow]; prompt: string;
                        placeholder, working: bool; st: GAgentPane;
                        body: PxRect): bool =
  ## Draw the pane into `pane` (its children replaced), its body at `body` in
  ## window pixels. False when there is nothing to draw into.
  if pane.isNil or body.w <= 0:
    return false
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  let lay = agentLayout(body, rows, st.scroll)
  let marked = markedRows(rows)
  r.setAttribute(pane, AgentAttribute, $rows.len)
  r.setAttribute(pane, "data-ct-agent-top", $lay.top)
  r.setAttribute(pane, "data-ct-agent-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-agent-total", $lay.lines.len)
  r.setAttribute(pane, "data-ct-agent-working", $working)
  let list = r.createElement("div")
  r.setStyle(list, "display", "flex")
  r.setStyle(list, "flex-direction", "column")
  r.setStyle(list, "height", $lay.list.h & "px")
  r.setStyle(list, "flex-shrink", "0")
  for k in 0 ..< lay.rows:
    let i = lay.top + k
    if i >= lay.lines.len:
      break
    let line = lay.lines[i]
    let row = marked[line.row]
    let el = r.createElement("div")
    for (key, v) in [("display", "flex"), ("white-space", "nowrap"),
                     ("overflow", "hidden"), ("flex-shrink", "0"),
                     ("items", "center")]:
      r.setStyle(el, key, v)
    r.setStyle(el, "height", $AgentRowPx & "px")
    r.setStyle(el, "width", $lay.list.w & "px")
    r.setAttribute(el, AgentLineAttribute, $row.kind)
    r.setAttribute(el, "data-ct-agent-key", row.key)
    r.setAttribute(el, "data-ct-agent-part", $line.part)
    if row.state.len > 0:
      r.setAttribute(el, "data-ct-agent-state", row.state)
    var text = ""
    for si, s in line.spans:
      let colour =
        if line.part == 0 and s.text == row.markOf() and si <= 1:
          stateColour(row.state)
        else: colourOf(s)
      r.appendChild(el, spanElement(r, s, colour))
      text.add s.text
    r.setAttribute(el, "data-ct-agent-text", text)
    r.appendChild(list, el)
  r.appendChild(pane, list)
  # The prompt: the field, and Send / Stop at its right edge.
  let bar = r.createElement("div")
  for (k, v) in [("display", "flex"), ("flex-shrink", "0"), ("items", "center"),
                 ("gap", "4px")]:
    r.setStyle(bar, k, v)
  r.setStyle(bar, "height", $lay.prompt.h & "px")
  r.setStyle(bar, "margin-top", "2px")
  let field = r.createElement("div")
  r.setAttribute(field, "data-ct-agent-prompt", prompt)
  let fieldW = lay.prompt.w - AgentControlPx -
               (if lay.add.w > 0: AgentAddPx else: 0)
  r.setStyle(field, "width", $max(0, fieldW) & "px")
  r.setStyle(field, "height", $max(0, lay.prompt.h - 4) & "px")
  r.setStyle(field, "background", AgentFieldGround)
  r.setStyle(field, "rounded", "3px")
  r.setStyle(field, "padding-left", "6px")
  r.setStyle(field, "display", "flex")
  r.setStyle(field, "items", "center")
  r.setStyle(field, "overflow", "hidden")
  let caption = r.createElement("span")
  r.setStyle(caption, "color", if placeholder: AgentMutedColour
                               else: AgentTextColour)
  r.setStyle(caption, "white-space", "nowrap")
  r.appendChild(caption, r.createTextNode(AgentPromptMark & prompt))
  r.appendChild(field, caption)
  r.appendChild(bar, field)
  if lay.add.w > 0:
    let add = r.createElement("div")
    r.setAttribute(add, "data-ct-agent-add", AgentAddLabel)
    r.setStyle(add, "width", $lay.add.w & "px")
    r.setStyle(add, "height", $lay.add.h & "px")
    r.setStyle(add, "display", "flex")
    r.setStyle(add, "items", "center")
    r.setStyle(add, "justify", "center")
    r.setStyle(add, "rounded", "3px")
    r.setStyle(add, "background", AgentFieldGround)
    r.setStyle(add, "color", AgentHeadingColour)
    r.appendChild(add, r.createTextNode(AgentAddLabel))
    r.appendChild(bar, add)
  let control = r.createElement("div")
  let label = if working: AgentStopLabel else: AgentSendLabel
  r.setAttribute(control, "data-ct-agent-control", label)
  r.setStyle(control, "width", $lay.control.w & "px")
  r.setStyle(control, "height", $lay.control.h & "px")
  r.setStyle(control, "display", "flex")
  r.setStyle(control, "items", "center")
  r.setStyle(control, "justify", "center")
  r.setStyle(control, "rounded", "3px")
  r.setStyle(control, "background", AgentFieldGround)
  r.setStyle(control, "color", AgentHeadingColour)
  r.appendChild(control, r.createTextNode(label))
  r.appendChild(bar, control)
  r.appendChild(pane, bar)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody, lay.scrubberOf(), "agent")
  true

proc agentHitAt*(rows: openArray[AgentFeedRow]; st: GAgentPane; body: PxRect;
                 x, y: int): GAgentHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GAgentHit(kind: gaNone, row: -1, button: -1)
  if not body.contains(x, y):
    return
  let lay = agentLayout(body, rows, st.scroll)
  if lay.control.contains(x, y):
    return GAgentHit(kind: gaControl, row: -1, button: -1)
  if lay.add.w > 0 and lay.add.contains(x, y):
    return GAgentHit(kind: gaAddContext, row: -1, button: -1)
  if lay.prompt.contains(x, y):
    return GAgentHit(kind: gaPrompt, row: -1, button: -1)
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, lay.scrubberOf(), x, y)
    if hit.onTrack:
      return GAgentHit(kind: (if hit.onThumb: gaThumb else: gaTrack),
                       row: -1, button: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return
  let i = lay.top + (y - lay.list.y) div AgentRowPx
  if i < 0 or i >= lay.lines.len:
    return
  let line = lay.lines[i]
  var at = lay.list.x
  for s in line.spans:
    let w = pxMeasure(s.text)
    if s.button > 0 and x >= at and x < at + w:
      return GAgentHit(kind: gaButton, row: line.row, button: s.button - 1)
    at += w
  result = GAgentHit(kind: gaRow, row: line.row, button: -1)

proc scrollTo*(st: var GAgentPane; rows: openArray[AgentFeedRow];
               body: PxRect; top: int) =
  let lay = agentLayout(body, rows, st.scroll)
  st.scroll.scrollTo(top, markedRows(rows), lay.lines, lay.rows)

proc scrollBy*(st: var GAgentPane; rows: openArray[AgentFeedRow];
               body: PxRect; delta: int) =
  let lay = agentLayout(body, rows, st.scroll)
  st.scroll.scrollTo(lay.top + delta, markedRows(rows), lay.lines, lay.rows)

proc scrubAgent*(st: var GAgentPane; rows: openArray[AgentFeedRow];
                 body: PxRect; y: int; dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let lay = agentLayout(body, rows, st.scroll)
  if not lay.overflow:
    return
  let track = listTrackRect(lay.listBody)
  let sm = lay.scrubberOf()
  st.scroll.scrollTo(sm.scrubTop(trackFractionAt(y - track.y, track.h),
                                 dragging), markedRows(rows), lay.lines,
                     lay.rows)
