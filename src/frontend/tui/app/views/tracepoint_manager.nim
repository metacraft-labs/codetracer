## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/tracepoint_manager.nim — CTUI-8. §3.3.5's POST-HOC TRACEPOINTS: the
## dialog that composes one, the list of the ones this session has, and the
## request value a host turns into a wire call.
##
## ## POST-HOC TRACEPOINTS ARE REAL HERE, AND THE MEASUREMENT MATTERS
##
## "Post-hoc" is the whole point: a tracepoint added AFTER the recording, run
## over the whole of it, answering with the values at every step that matched.
## Measured against a real `replay-server` on `calc` on 2026-09-06, both surfaces
## exist and they are different:
##
##   1. **`ct/run-tracepoints` is the post-hoc one.** It sweeps the recording and
##      answers `ct/tracepoint-results`, whose `Stop` rows carry `rrTicks`, the
##      `path`/`line`, and the EVALUATED `locals` — `left = 2` at tick 33 and
##      `left = 6` at tick 63 for `log(left)` on `main.py:31`. Ticks are what put
##      a `◆` on `app/views/timeline_bar.nim`'s track, so this is the surface the
##      marks come from.
##
##      **It answers with NO DAP RESPONSE.** `Handler::run_tracepoints`
##      (`src/db-backend/src/dap_handler.rs`) sends `ct/updated-trace` and
##      `ct/tracepoint-results` and never calls `respond_dap`, so a client that
##      waits for the reply waits for ever — measured, as a hang, before it was
##      read in the source. `headless_session.runTracepoints` therefore sends
##      without expecting a response and synchronises on the EVENT. Recorded
##      here because it is exactly the shape
##      `codetracer-specs/Testing/Verification-Harness-Traps.md` §3 is about: the
##      symptom is a timeout and the cause is not a slow backend.
##
##   2. **The DAP LOGPOINT is the live one**, and it is not a substitute.
##      `setBreakpoints` with a `logMessage` verifies the line and emits one
##      `output` event per matched step during `continue` — nine of them for the
##      same line on `calc`. The `output` event carries `line`, `column` and
##      `source.path` and **no tick at all** (measured: the body's keys are
##      exactly `category`, `column`, `line`, `output`, `source`). So a logpoint
##      can put a mark in a SOURCE GUTTER, which is what CTUI-5's `gmTracepoint`
##      already does, and cannot put one on a TIMELINE.
##
## Both are composed from one `TracepointDraft`, because to a user they are one
## tracepoint; which surface a host uses decides what it gets back, and
## `verifiedRequest` / `sweepRequest` are the two values that say so.
##
## ## A PURE FUNCTION OF A VALUE
##
## `TracepointManagerModel` in, `TracepointManagerScreen` out, plus `applyKey`
## which returns a new model and an action. No session, no backend, no I/O.

import std/[strutils]

import isonim_tui

import ../layout/profile
import ./styled_row
import ./timeline_bar

export styled_row, profile

type
  TracepointState* = enum
    ## Where one tracepoint is in its life. The distinction that matters is
    ## `tpsDraft` vs everything else: a draft has been typed and not yet shown
    ## to the engine, so a dialog that rendered the two alike would let a
    ## tracepoint that the engine REFUSED look like one that fires.
    tpsDraft
    tpsVerified
    tpsRejected

  TracepointDraft* = object
    ## What the user typed. The only mutable part of a tracepoint.
    path*: string
    line*: int
    column*: int
      ## 1-based, or 0 for the legacy line-only logpoint that fires on every
      ## step recorded on the line. `dap_types`'s `SourceBreakpoint.column` is
      ## optional and the engine's M10 arm reads exactly this distinction.
    expression*: string
      ## What the tracepoint evaluates and logs. Sent as `logMessage` on the
      ## DAP logpoint arm and as `Tracepoint.expression` on the sweep arm.
    enabled*: bool

  TracepointHit* = object
    ## One `Stop` from a `ct/tracepoint-results` sweep, as the dialog and the
    ## scrubber need it.
    tick*: uint64
    path*: string
    line*: int
    values*: seq[(string, string)]
      ## The locals the expression named, already rendered. A `seq` of pairs
      ## rather than a `Table` because the ORDER the engine answered in is what
      ## a reader compares against the expression.

  TracepointEntry* = object
    ## One tracepoint this session has.
    id*: int
    draft*: TracepointDraft
    state*: TracepointState
    boundLine*: int
      ## The line the ENGINE bound it to, which need not be the line asked for.
      ## 0 until an engine has answered.
    boundColumn*: int
    hits*: seq[TracepointHit]
    note*: string
      ## Why it was rejected, or what the engine said.

  TracepointField* = enum
    tfLine
    tfColumn
    tfExpression

  TracepointManagerModel* = object
    ## Everything the dialog shows.
    open*: bool
    entries*: seq[TracepointEntry]
    selected*: int
      ## Index into `entries`, or -1 when the draft row is selected.
    editing*: bool
    field*: TracepointField
    draft*: TracepointDraft
    nextId*: int
    note*: string

  TracepointAction* = enum
    tmaNone
    tmaOpened
    tmaClosed
    tmaMoved
    tmaEditBegan
    tmaEdited
    tmaEditCancelled
    tmaSubmitted
      ## The draft is complete and the host should send it. THE ONE ACTION THAT
      ## REACHES A BACKEND, and it reaches it through the caller.
    tmaToggled
    tmaDeleted
    tmaRejected

  TracepointRequest* = object
    ## The value a host turns into a wire call. Both arms read the same fields;
    ## see this module's header for what each surface answers with.
    path*: string
    line*: int
    column*: int
    expression*: string

  TracepointManagerScreen* = object
    rows*: seq[StyledRow]
    area*: CellArea
    bodyHeight*: int
    entryRows*: int
    hitRows*: int
    draftRow*: int
      ## SCREEN row of the editable draft line, or -1.
    selectedRow*: int
    markColumn*: int
      ## Screen column of the `◆` field's first cell.

const
  # THE KEY CONSTANTS ARE PREFIXED, and that is not cosmetic. `app/views/shell.nim`
  # re-exports this module beside `call_stack`, `variables`, `event_log` and
  # `timeline_bar`, and `app/timeline_binding.nim` re-exports it beside
  # `input/timeline_keys`. A bare `KeyDown` here made `call_stack_keys.KeyDown`
  # ambiguous in every suite that imports the shell — caught by
  # `tests/test_call_stack_navigation.nim` refusing to compile.
  TracepointDialogTitle* = "TRACEPOINTS"
  DialogBorder* = "─"

  MarkFieldCells* = 2
  StateFieldCells* = 4
  MaxExpressionCells* = 40

  TracepointKeyOpen* = "T"
  TracepointKeyClose* = "\x1b"
  TracepointKeyDown* = "j"
  TracepointKeyUp* = "k"
  TracepointKeyEdit* = "e"
  TracepointKeyNextField* = "\t"
  TracepointKeySubmit* = "\r"
  TracepointKeySubmitLf* = "\n"
  TracepointKeyToggle* = " "
  TracepointKeyDelete* = "d"
  TracepointKeyBackspace* = "\x7f"

  TitleStyle* = CellStyle(fg: "white", bold: true)
  TitleDetailStyle* = CellStyle(fg: "bright_black")
  RuleStyle* = CellStyle(fg: "bright_black")
  TracepointMarkStyle* = timeline_bar.MarkStyle
    ## THE SAME YELLOW `◆` THE SCRUBBER PAINTS. One fact, one glyph, one colour,
    ## on two panes — a dialog that chose its own would let a reader believe the
    ## diamond on the track and the diamond in the list were different things.
  DraftStyle* = CellStyle(fg: "bright_black", italic: true)
  VerifiedStyle* = CellStyle(fg: "green")
  RejectedStyle* = CellStyle(fg: "red", bold: true)
  DisabledStyle* = CellStyle(fg: "bright_black")
  ExpressionStyle* = CellStyle(fg: "white")
  HitStyle* = CellStyle(fg: "cyan")
  EditingBackground* = "blue"
  SelectedBackground* = "bright_black"
  EmptyText* = "no tracepoints — press e to add one"
  EmptyStyle* = CellStyle(fg: "bright_black", italic: true)

proc initTracepointDraft*(path = ""; line = 0; column = 0; expression = "";
                          enabled = true): TracepointDraft =
  TracepointDraft(path: path, line: line, column: column,
                  expression: expression, enabled: enabled)

proc initTracepointManagerModel*(open = false;
                                 entries: seq[TracepointEntry] = @[];
                                 draft = initTracepointDraft();
                                 note = ""): TracepointManagerModel =
  TracepointManagerModel(
    open: open, entries: entries, selected: (if entries.len > 0: 0 else: -1),
    editing: false, field: tfExpression, draft: draft,
    nextId: entries.len, note: note)

proc isEmpty*(model: TracepointManagerModel): bool =
  not model.open

proc isComplete*(draft: TracepointDraft): bool =
  ## Whether the draft can be sent. A tracepoint with no expression is a
  ## BREAKPOINT — `headless_session.addColumnTracepoint` asserts exactly that —
  ## and one with no line has nowhere to bind, so both are refused HERE rather
  ## than by an engine that would answer `success: false` and leave the dialog
  ## looking as if it had worked.
  draft.path.len > 0 and draft.line > 0 and draft.expression.strip().len > 0

proc requestFor*(draft: TracepointDraft): TracepointRequest =
  TracepointRequest(path: draft.path, line: draft.line, column: draft.column,
                    expression: draft.expression)

proc verifiedRequest*(model: TracepointManagerModel): TracepointRequest =
  ## The draft as a DAP-logpoint request. See the header: this arm verifies the
  ## line and fires during `continue` with no tick.
  requestFor(model.draft)

proc sweepRequest*(model: TracepointManagerModel): TracepointRequest =
  ## The draft as a `ct/run-tracepoints` request. Same four fields; the
  ## difference is entirely in what the engine answers.
  requestFor(model.draft)

proc marksFrom*(entries: openArray[TracepointEntry]): seq[TimelineMark] =
  ## Every hit of every ENABLED tracepoint, as a scrubber mark.
  ##
  ## Disabled tracepoints keep their hits — turning one off and on again must
  ## not cost another sweep — and contribute no diamond, which is what
  ## "disabled" means on a timeline.
  result = @[]
  for entry in entries:
    if not entry.draft.enabled:
      continue
    for hit in entry.hits:
      result.add TimelineMark(tick: hit.tick, kind: tmkTracepoint,
                              label: entry.draft.expression)

proc hitCount*(model: TracepointManagerModel): int =
  for entry in model.entries:
    result += entry.hits.len

proc entryStateStyle(entry: TracepointEntry): CellStyle =
  if not entry.draft.enabled: DisabledStyle
  else:
    case entry.state
    of tpsDraft: DraftStyle
    of tpsVerified: VerifiedStyle
    of tpsRejected: RejectedStyle

proc entryStateLabel(entry: TracepointEntry): string =
  ## Four cells, so the field is a COLUMN a Tier-2 case can read at a fixed
  ## offset.
  if not entry.draft.enabled: "off "
  else:
    case entry.state
    of tpsDraft: "new "
    of tpsVerified: "ok  "
    of tpsRejected: "bad "

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

proc fieldBuffer(model: TracepointManagerModel): string =
  case model.field
  of tfLine: (if model.draft.line > 0: $model.draft.line else: "")
  of tfColumn: (if model.draft.column > 0: $model.draft.column else: "")
  of tfExpression: model.draft.expression

proc parsedOrZero(text: string): int =
  ## A digit buffer as a number. `0` for an empty or unparsable one — the edit
  ## keys reject a non-digit before it reaches the buffer, so the `except` arm
  ## is reachable only through an overflow, and a line number that overflowed
  ## `int` is not a line the pane can bind.
  if text.len == 0:
    return 0
  try:
    parseInt(text)
  except ValueError:
    0

proc setFieldBuffer(model: var TracepointManagerModel; text: string) =
  case model.field
  of tfLine: model.draft.line = parsedOrZero(text)
  of tfColumn: model.draft.column = parsedOrZero(text)
  of tfExpression: model.draft.expression = text

proc applyEditKey(model: var TracepointManagerModel;
                  token: string): TracepointAction =
  if token == TracepointKeySubmit or token == TracepointKeySubmitLf:
    if not model.draft.isComplete():
      model.note = "a tracepoint needs a line and an expression"
      return tmaRejected
    model.editing = false
    model.note = ""
    return tmaSubmitted
  if token == TracepointKeyClose:
    model.editing = false
    return tmaEditCancelled
  if token == TracepointKeyNextField:
    model.field =
      case model.field
      of tfLine: tfColumn
      of tfColumn: tfExpression
      of tfExpression: tfLine
    return tmaEdited
  if token == TracepointKeyBackspace:
    var buffer = model.fieldBuffer()
    if buffer.len > 0:
      buffer.setLen(buffer.len - 1)
      model.setFieldBuffer(buffer)
    return tmaEdited
  if token.len == 1 and token[0].ord >= 32 and token[0].ord < 127:
    if model.field in {tfLine, tfColumn} and token[0] notin Digits:
      # A line number is a number. Rejecting here rather than at submit time is
      # what makes the refusal visible while the user is still typing.
      return tmaRejected
    model.setFieldBuffer(model.fieldBuffer() & token)
    return tmaEdited
  tmaNone

proc applyKey*(model: var TracepointManagerModel;
               token: string): TracepointAction =
  ## One input token. Returns what it did.
  if token.len == 0:
    return tmaNone
  if not model.open:
    if token == TracepointKeyOpen:
      model.open = true
      return tmaOpened
    return tmaNone
  if model.editing:
    return applyEditKey(model, token)
  case token
  of TracepointKeyClose:
    model.open = false
    tmaClosed
  of TracepointKeyEdit:
    model.editing = true
    model.field = tfLine
    tmaEditBegan
  of TracepointKeyDown:
    if model.entries.len == 0:
      tmaNone
    elif model.selected >= model.entries.len - 1:
      tmaNone
    else:
      inc model.selected
      tmaMoved
  of TracepointKeyUp:
    if model.selected <= 0:
      tmaNone
    else:
      dec model.selected
      tmaMoved
  of TracepointKeyToggle:
    if model.selected < 0 or model.selected >= model.entries.len:
      tmaNone
    else:
      model.entries[model.selected].draft.enabled =
        not model.entries[model.selected].draft.enabled
      tmaToggled
  of TracepointKeyDelete:
    if model.selected < 0 or model.selected >= model.entries.len:
      tmaNone
    else:
      model.entries.delete(model.selected)
      if model.selected >= model.entries.len:
        model.selected = model.entries.len - 1
      tmaDeleted
  else:
    tmaNone

proc recordSubmission*(model: var TracepointManagerModel;
                       state: TracepointState;
                       boundLine, boundColumn: int;
                       hits: seq[TracepointHit] = @[];
                       note = ""): int =
  ## Put the submitted draft into the list with what the ENGINE answered.
  ##
  ## Returns the new entry's id. The dialog never invents `state`, `boundLine`
  ## or `hits`: a tracepoint that says `ok` says so because a `setBreakpoints`
  ## response said `verified: true`, and a `◆` on the track exists because a
  ## `ct/tracepoint-results` `Stop` carried that tick.
  let id = model.nextId
  inc model.nextId
  model.entries.add TracepointEntry(
    id: id, draft: model.draft, state: state, boundLine: boundLine,
    boundColumn: boundColumn, hits: hits, note: note)
  model.selected = model.entries.len - 1
  id

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc titleRowSpans*(model: TracepointManagerModel; width: int): StyledRow =
  result = @[]
  if width <= 0:
    return
  var parts: seq[StyledSpan] = @[]
  parts.add StyledSpan(text: TracepointDialogTitle, style: TitleStyle)
  parts.add StyledSpan(text: " " & $model.entries.len & " point(s) " &
                             $model.hitCount() & " hit(s)",
                       style: TitleDetailStyle)
  if model.note.len > 0:
    parts.add StyledSpan(text: " " & model.note, style: RejectedStyle)
  var used = 0
  for part in parts:
    if used >= width:
      break
    let fitted = truncateToCells(part.text, width - used)
    if fitted.len == 0:
      continue
    result.add StyledSpan(text: fitted, style: part.style)
    used += cellWidthOf(fitted)
  if used < width:
    result.add StyledSpan(text: " ", style: DefaultCellStyle)
    inc used
  if used < width:
    result.add StyledSpan(text: repeatGlyph(DialogBorder, width - used),
                          style: RuleStyle)

proc entryRowSpans*(model: TracepointManagerModel; index: int;
                    width: int): StyledRow =
  ## `◆ ok   main.py:31       log(left)                2 hit(s)`.
  result = @[]
  if width <= 0 or index < 0 or index >= model.entries.len:
    return
  let entry = model.entries[index]
  let selected = index == model.selected and not model.editing
  var spans: seq[StyledSpan] = @[]
  spans.add StyledSpan(text: MarkGlyph & " ",
                       style: (if entry.draft.enabled: TracepointMarkStyle
                               else: DisabledStyle))
  spans.add StyledSpan(text: entryStateLabel(entry),
                       style: entryStateStyle(entry))
  let line = if entry.boundLine > 0: entry.boundLine else: entry.draft.line
  spans.add StyledSpan(text: pathBaseName(entry.draft.path) & ":" & $line & " ",
                       style: TitleDetailStyle)
  spans.add StyledSpan(
    text: truncateToCells(entry.draft.expression, MaxExpressionCells) & " ",
    style: ExpressionStyle)
  spans.add StyledSpan(text: $entry.hits.len & " hit(s)", style: HitStyle)
  var used = 0
  for span in spans:
    if used >= width:
      break
    let fitted = truncateToCells(span.text, width - used)
    if fitted.len == 0:
      continue
    var style = span.style
    if selected and style.bg.len == 0:
      style = style.withBackground(SelectedBackground)
    result.add StyledSpan(text: fitted, style: style)
    used += cellWidthOf(fitted)
  if selected and used < width:
    result.add StyledSpan(text: repeat(' ', width - used),
                          style: CellStyle(bg: SelectedBackground))

proc draftRowSpans*(model: TracepointManagerModel; width: int): StyledRow =
  ## The editable line: `> line 31  col 0  expr log(left)`.
  result = @[]
  if width <= 0:
    return
  var spans: seq[StyledSpan] = @[]
  spans.add StyledSpan(text: (if model.editing: "> " else: "  "),
                       style: TitleStyle)
  for field in TracepointField:
    let label =
      case field
      of tfLine: "line "
      of tfColumn: "col "
      of tfExpression: "expr "
    let value =
      case field
      of tfLine: (if model.draft.line > 0: $model.draft.line else: "-")
      of tfColumn: (if model.draft.column > 0: $model.draft.column else: "-")
      of tfExpression: (if model.draft.expression.len > 0:
                          model.draft.expression else: "-")
    spans.add StyledSpan(text: label, style: TitleDetailStyle)
    let active = model.editing and model.field == field
    spans.add StyledSpan(
      text: value & " ",
      style: (if active: CellStyle(fg: "white", bg: EditingBackground,
                                   bold: true)
              else: ExpressionStyle))
  var used = 0
  for span in spans:
    if used >= width:
      break
    let fitted = truncateToCells(span.text, width - used)
    if fitted.len == 0:
      continue
    result.add StyledSpan(text: fitted, style: span.style)
    used += cellWidthOf(fitted)

proc paintTracepointManager*(g: var StyledGrid; area: CellArea;
                             model: TracepointManagerModel):
    TracepointManagerScreen =
  ## Paint the dialog into `area` of `g`, and report what it painted.
  result = TracepointManagerScreen(
    rows: @[], area: area, bodyHeight: 0, entryRows: 0, hitRows: 0,
    draftRow: -1, selectedRow: -1, markColumn: area.col)
  if area.width <= 0 or area.height <= 0 or not model.open:
    return

  var spanAt = area.col
  for span in titleRowSpans(model, area.width):
    g.paint(area.row, spanAt, span.text, span.style)
    spanAt += cellWidthOf(span.text)

  if area.height <= 1:
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  let bodyHeight = area.height - 1
  result.bodyHeight = bodyHeight
  var row = area.row + 1
  let lastRow = area.row + area.height - 1

  if model.entries.len == 0 and not model.editing:
    g.paint(row, area.col, truncateToCells(EmptyText, area.width), EmptyStyle)
    inc row

  for i in 0 ..< model.entries.len:
    if row > lastRow - 1:
      break
    var at = area.col
    for span in entryRowSpans(model, i, area.width):
      g.paint(row, at, span.text, span.style)
      at += cellWidthOf(span.text)
    if i == model.selected:
      result.selectedRow = row
    inc result.entryRows
    inc row
    for hit in model.entries[i].hits:
      if row > lastRow - 1:
        break
      var text = "    @" & $hit.tick
      for (name, value) in hit.values:
        text.add " " & name & "=" & value
      g.paint(row, area.col, truncateToCells(text, area.width), HitStyle)
      inc result.hitRows
      inc row

  if row <= lastRow:
    result.draftRow = row
    var at = area.col
    for span in draftRowSpans(model, area.width):
      g.paint(row, at, span.text, span.style)
      at += cellWidthOf(span.text)

  for r in area.row ..< area.row + area.height:
    result.rows.add g.rowSpansIn(r, area.col, area.width)

proc tracepointManagerScreen*(model: TracepointManagerModel;
                              width, height: int): TracepointManagerScreen =
  var g = newStyledGrid(width, height)
  let area = CellArea(col: 0, row: 0, width: width, height: height)
  result = paintTracepointManager(g, area, model)

proc tracepointManagerRows*(model: TracepointManagerModel;
                            width, height: int): seq[StyledRow] =
  tracepointManagerScreen(model, width, height).rows

proc tracepointManagerText*(model: TracepointManagerModel;
                            width, height: int): seq[string] =
  result = @[]
  for row in tracepointManagerRows(model, width, height):
    result.add rowText(row)

proc renderTracepointManagerTree*(model: TracepointManagerModel;
                                  r: TerminalRenderer;
                                  width, height: int): TerminalNode =
  styledRowsTree(r, tracepointManagerRows(model, width, height))
