## gpui/agent_harbor/ah_composer.nim — CTF-P2c (P2c-G). The GPUI omnibox
## composer: the caption bar's omnibox field in agent mode (`/ai …`) and the
## composer's sheet dropped under it, over `OmniboxComposerVM`
## (nim-agents-isonim-viewmodels), drawn as the web's
## `isonim_agent_harbor_composer_view` draws it (`agent_harbor_composer.styl`)
## from the same words (`agent_harbor_composer_words`, which renders
## nothing), in the same places.
##
## The sheet is the omnibox's results surface: the window's ground, a
## hairline border, `min(640px, window − 16px)` wide (`sheetWidthFor`) and
## centred under the field, 6px below the caption bar. Top to bottom: the
## header (pinned), the body (the whole instruction, what was sent, `Recent`
## or `In view` with its chips and the add-context menu, the three
## destinations, the launch or initiative form, the stop message), and the
## send line (pinned, under a hairline).
##
## GPUI's layout does not scroll a box or measure an overflow, so the body is
## laid out here, section by section, at the heights the stylesheet gives
## them (`Block.heightPx`; text wrapped by the face's kerned widths,
## `wrappedRows`): the sheet is as tall as its content, or the window less
## its inset, and a body that holds more ends in the quiet `More below ↓`
## line; an open schedule is brought into view (the web's
## `scrollOpenScheduleIntoView`), whole sections at a time.
##
## A destination row at laptop width: the title column (116px, the label
## role in capitals, tracked), what the destination is (cut by the views'
## one rule), the state word and the row's actions; the reason and the
## delivery under the label. Below 30rem (`isNarrow`) the title and the
## state word share a line and the rest each take one. The row the bar
## marks carries a 2px inset bar in the action border role, never a fill.
##
## Presses are routed (Input-Routing-And-Keymaps.md §5.1), as on the web:
## each element a press acts on carries its operation (`data-ct-operation`,
## `agent_harbor_composer_words`) and its target (`data-ah-target`), and its
## press-down listener only reports both to the host's `ComposerPress` (the
## hit test), which resolves it through its router and runs it
## (`runComposerPress`). Every element also names its action
## (`data-ah-action`).
##
## Facts (`data-ah-*`) are the terminal's (`tui/agent_harbor/ah_tui_composer.nim`).

import std/strutils
import nim_agents_isonim_viewmodels/agent_harbor/omnibox_composer_vm
import ../../viewmodel/views/agent_harbor_composer_words
import ./ah_theme
from ./ah_session_activity import wrappedRows
from ../../viewmodel/input/element_press import OperationAttribute

export omnibox_composer_vm, agent_harbor_composer_words, ah_theme

const
  CaptionBarPx* = 34      ## `--caption-bar-height` (2.125rem)
  FieldHeightPx* = 28     ## COMMAND_INPUT_HEIGHT
  TriggerGapPx* = 6       ## DROPDOWN_TRIGGER_GAP
  SheetRadiusPx* = 6      ## DROPDOWN_RADIUS
  PadPx* = 12             ## AH_COMPOSER_PAD
  TitleColPx* = 116       ## a row's title column (7.25rem)
  ColumnGapPx* = 8
  BodyLinePx* = 20
  ChipGapPx* = 6
  ActionAttribute = "data-ah-action"
  TargetAttribute = "data-ah-target"

type
  Block = object
    ## A section of the body at the height the stylesheet gives it.
    heightPx: int
    schedule: bool       ## holds the open schedule's end
    el: GpuiElement

  Layout = object
    widthPx: int         ## the sheet's inner width
    narrow: bool
    press: ComposerPress ## where a press is reported (nil: nowhere)

proc tokenHexOf(token: DesignToken; mode: DesignMode): string =
  ## A design-system role the palette does not carry, in `mode`.
  DesignTokenHex[token][mode]

proc warningInk(p: AhPalette): string =
  if p.mode == dmDark: p.textWarning
  else: tokenHexOf(dtColorsUiTextWarningPrimaryHover, p.mode)

proc roleInk(p: AhPalette; role: string): string =
  case role
  of "error": p.textError
  of "warning": warningInk(p)
  of "body", "label": p.textBody
  else: p.textCaption

proc acts(r: GpuiRenderer; el: GpuiElement; action, target: string;
          press: ComposerPress = nil) =
  ## The action a press on `el` names (`data-ah-action`), and, for an
  ## element a press acts on, the operation it carries (`data-ct-operation`)
  ## and its target (`data-ah-target`): its press-down listener only reports
  ## both to the host's `press`, which resolves it through its router and
  ## runs it (`runComposerPress`). Nothing here decides what a press does.
  r.setAttribute(el, ActionAttribute, action)
  r.setAttribute(el, TargetAttribute, target)
  r.tag(el, "action", action)
  let operation = operationOfAction(action)
  if operation.len == 0: return
  r.setAttribute(el, OperationAttribute, operation)
  if press != nil:
    r.addEventListener(el, "mousedown", proc(ev: GpuiEvent) =  # ir1-gate: hit test
      press(operation, target))

proc endThatFits*(text: string; sizePx, availPx: int): string =
  ## The longest end of `text` that the face sets within `availPx`: what an
  ## input scrolled to its end shows (no "…": the start is scrolled out of
  ## view, not cut).
  if textWidth(text, sizePx) <= float(availPx): return text
  var start = 0
  while start < text.len:
    inc start
    while start < text.len and (ord(text[start]) and 0xC0) == 0x80: inc start
    if textWidth(text[start .. ^1], sizePx) <= float(availPx): return text[start .. ^1]
  ""

proc linesOf(text: string; sizePx, availPx: int): int =
  if text.len == 0: 0 else: wrappedRows(text, sizePx, max(1, availPx))

proc wrapText(r: GpuiRenderer; s: string; sizePx, lineHeightPx: int; colour: string;
              bold = false): GpuiElement =
  ## Prose that wraps, never cut (`white-space: pre-wrap`).
  r.text(s, sizePx, colour, bold = bold, shrink = false,
         pairs = [("white-space", "pre-wrap"), ("line-height", $lineHeightPx & "px"),
                  ("flex-shrink", "1"), ("min-width", "0px")])

proc spaced(r: GpuiRenderer; el: GpuiElement; heightPx: int;
            top = 0; bottom = 0): Block =
  ## `el` as a block of the body: padded to the sheet's sides, `heightPx`
  ## tall with its own top and bottom padding.
  r.styles(el, [("padding-left", $PadPx & "px"), ("padding-right", $PadPx & "px"),
                ("padding-top", $top & "px"), ("padding-bottom", $bottom & "px"),
                ("height", $heightPx & "px"), ("flex-shrink", "0")])
  Block(heightPx: heightPx, el: el)

proc chip(r: GpuiRenderer; p: AhPalette; label, fg: string; border = "";
          bg = ""; bold = false; dashed = false): (GpuiElement, int) =
  ## A small control sized to its words: 24px, 8px each side, a hairline.
  let el = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("padding-left", "8px"), ("padding-right", "8px"),
                          ("flex-shrink", "0"), ("rounded", $ControlRadiusPx & "px"),
                          ("border-width", "1px"),
                          ("border-color", if border.len > 0: border else: p.borderSecondary)])
  if dashed: r.setStyle(el, "border-style", "dashed")
  if bg.len > 0: r.setStyle(el, "background", bg)
  r.appendChild(el, r.text(label, CaptionPx, fg, bold = bold))
  (el, textPx(label, CaptionPx) + 18)

proc sectionLabel(r: GpuiRenderer; p: AhPalette; label: string): GpuiElement =
  result = r.tracked(r.text(label.toUpperAscii, CaptionPx, p.textLabel, bold = true,
                            shrink = false))
  r.tag(result, "section", label)

# ---------------------------------------------------------------------------
# The body's sections
# ---------------------------------------------------------------------------

proc recentBlocks(r: GpuiRenderer; p: AhPalette; vm: OmniboxComposerVM;
                  lay: Layout): seq[Block] =
  let recent = vm.recent
  if recent.len == 0: return
  let head = r.box()
  r.appendChild(head, r.sectionLabel(p, RecentLabel))
  result.add r.spaced(head, 4 + CaptionLinePx + 4, top = 4, bottom = 4)
  for i, rec in recent:
    let row = r.box(column = true, pairs = [("justify", "center")])
    r.tag(row, "recent", $i)
    r.acts(row, "recall", $i, lay.press)
    let t = r.text(rec.text, BodyPx, p.textBody)
    r.tag(t, "recent-text", rec.text)
    r.appendChild(row, t)
    let l = r.text(rec.line, CaptionPx, if rec.failed: p.textError else: p.textCaption)
    r.tag(l, "recent-line", rec.line)
    r.appendChild(row, l)
    result.add r.spaced(row, 6 + BodyLinePx + CaptionLinePx + 6, top = 6, bottom = 6)

proc contextBlocks(r: GpuiRenderer; p: AhPalette; vm: OmniboxComposerVM;
                   lay: Layout): seq[Block] =
  let chips = vm.chips
  let addOpen = vm.addContextOpen.val
  var items: seq[FlowItem]
  let label = r.sectionLabel(p, InViewLabel)
  r.setStyle(label, "margin-right", "4px")
  items.add FlowItem(el: label, widthPx: textPx(InViewLabel.toUpperAscii, CaptionPx) + 4 +
                                         InViewLabel.len div 2)
  if chips.len == 0:
    let none = r.text(NothingInView, CaptionPx, p.textCaption, shrink = false)
    r.tag(none, "chip-none", NothingInView)
    items.add FlowItem(el: none, widthPx: textPx(NothingInView, CaptionPx))
  for ch in chips:
    let state = chipState(ch)
    let (el, w) = case state
      of "cited": r.chip(p, ch.item.label, p.textBody, border = p.borderAction,
                         bg = p.hover)
      of "uncited": r.chip(p, ch.item.label, p.textDisabled)
      of "note": r.chip(p, ch.item.label, p.textCaption, dashed = true)
      else: r.chip(p, ch.item.label, p.textCaption)
    r.tag(el, "chip", ch.item.id)
    r.tag(el, "chip-state", state)
    r.tag(el, "chip-label", ch.item.label)
    r.acts(el, "cite", ch.item.id, lay.press)
    r.setStyle(el, "max-width", $lay.widthPx & "px")
    items.add FlowItem(el: el, widthPx: min(w, lay.widthPx))
  if vm.phase == cpComposing:
    let add = r.box(pairs = [("height", $ControlPx & "px"), ("width", $ControlPx & "px"),
                             ("items", "center"), ("justify", "center"),
                             ("flex-shrink", "0"), ("rounded", $ControlRadiusPx & "px"),
                             ("border-width", "1px"), ("border-color", p.borderSecondary)])
    if addOpen: r.setStyle(add, "background", p.hover)
    r.appendChild(add, r.text("+", CaptionPx, tokenHexOf(dtColorsUiIconPrimaryDefault, p.mode),
                              shrink = false))
    r.tag(add, "add-context", $addOpen)
    r.acts(add, "add-context", "", lay.press)
    items.add FlowItem(el: add, widthPx: ControlPx)
  # Count the lines `flowLines` packs, to size the block.
  var lines = 1
  var used = 0
  for it in items:
    if used > 0 and used + ChipGapPx + it.widthPx > lay.widthPx:
      inc lines
      used = it.widthPx
    else:
      used += (if used > 0: ChipGapPx else: 0) + it.widthPx
  let col = r.box(column = true)
  r.appendChild(col, r.flowLines(items, lay.widthPx, ChipGapPx, ControlPx, ChipGapPx))
  var h = 4 + lines * ControlPx + (lines - 1) * ChipGapPx
  if addOpen:
    let menu = r.box(column = true, pairs = [("margin-top", "6px"), ("min-width", "192px"),
                                             ("width", "192px"),
                                             ("background", p.ground), ("border-width", "1px"),
                                             ("border-color", p.borderPrimary),
                                             ("rounded", $SheetRadiusPx & "px"),
                                             ("padding-top", "2px"), ("padding-bottom", "2px")])
    r.tag(menu, "context-menu", "add-context")
    for item in AddContextItems:
      let row = r.box(pairs = [("height", "28px"), ("items", "center"),
                               ("padding-left", "10px"), ("padding-right", "10px")])
      let t = r.text(item, CaptionPx, p.textBody)
      r.tag(t, "context-item", item)
      r.appendChild(row, t)
      r.acts(row, "attach", item)
      r.appendChild(menu, row)
    r.appendChild(col, menu)
    h += 6 + 4 + 2 + 28 * AddContextItems.len
  let cites = vm.citesShown
  if cites.len > 0:
    let t = r.text(cites, CaptionPx, p.textCaption, pairs = [("margin-top", "6px"),
                                                              ("line-height", "16px")])
    r.tag(t, "cites", cites)
    r.appendChild(col, t)
    h += 6 + CaptionLinePx
  h += 8
  result.add r.spaced(col, h, top = 4, bottom = 8)

proc actionButton(r: GpuiRenderer; p: AhPalette; press: ComposerPress; label, action: string;
                  target: TargetKind): (GpuiElement, int) =
  let stop = action == "stop"
  result = r.chip(p, label, if stop: p.textError else: p.textBody,
                  border = if stop: p.textError else: p.borderPrimary)
  r.tag(result[0], "button", label)
  r.acts(result[0], action, $target, press)

proc actionsOf(vm: OmniboxComposerVM; row: DestinationRow): seq[(string, string)] =
  if row.canStop:
    result.add ((if vm.stopState.val == ssStopping: "Stopping\xE2\x80\xA6" else: "Stop agent"),
                "stop")
  if row.canSendAgain: result.add (sendAgainLabel(row), "send-again")
  if row.delivered and row.delivery == dsFailed: result.add ("Retry", "retry")

proc rowBlock(r: GpuiRenderer; p: AhPalette; vm: OmniboxComposerVM; lay: Layout;
              row: DestinationRow): Block =
  let marked = vm.rowMarked(row)
  let unavailable = vm.rowUnavailable(row)
  let label = vm.rowLabel(row)
  let reason = vm.rowReason(row)
  let word = stateWord(row)
  let role = stateRole(row)
  let delivery = deliveryText(row)
  let dRole = deliveryRole(row)
  let actions = actionsOf(vm, row)
  let narrow = lay.narrow
  let textPxAvail = if narrow: lay.widthPx else: lay.widthPx - TitleColPx - ColumnGapPx
  let el = r.box(column = true, pairs = [("position", "relative")])
  r.tag(el, "dest", $row.target)
  r.tag(el, "marked", $marked)
  r.tag(el, "unavailable", $unavailable)
  if marked: r.appendChild(el, r.insetBar(p.borderAction, 2))
  let titleInk = if unavailable: p.textDisabled else: p.textLabel
  let labelInk = if unavailable: p.textDisabled else: p.textBody
  let first = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                             ("gap", $ColumnGapPx & "px")])
  let title = r.tracked(r.text(row.title.toUpperAscii, CaptionPx, titleInk, bold = true,
                               shrink = narrow))
  r.tag(title, "dest-title", row.title.toUpperAscii)
  if narrow: r.setStyle(title, "flex-grow", "1")
  else: r.styles(title, [("width", $TitleColPx & "px"), ("min-width", $TitleColPx & "px")])
  r.appendChild(first, title)
  proc labelEl(): GpuiElement =
    result = r.text(label, BodyPx, labelInk,
                    pairs = [("flex-grow", "1"), ("min-width", "0px")])
    if unavailable: r.setStyle(result, "font-style", "italic")
    r.tag(result, "label", label)
  if not narrow: r.appendChild(first, labelEl())
  if word.len > 0:
    let wordInk = case role
                  of "quiet": p.textCaption
                  of "error": p.textError
                  else: p.textBody
    let w = r.text(word, CaptionPx, wordInk, bold = role != "quiet", shrink = false)
    r.tag(w, "state", word)
    r.appendChild(first, w)
  var h = 6 + ControlPx + 6
  proc actionsRow(into: GpuiElement) =
    for (labelText, action) in actions:
      let (b, _) = r.actionButton(p, lay.press, labelText, action, row.target)
      r.appendChild(into, b)
  if not narrow and actions.len > 0:
    let a = r.box(pairs = [("gap", "6px"), ("flex-shrink", "0")])
    actionsRow(a)
    r.appendChild(first, a)
  r.appendChild(el, first)
  let under = if narrow: 0 else: TitleColPx + ColumnGapPx
  if narrow:
    let l = r.box(pairs = [("height", $BodyLinePx & "px"), ("items", "center")])
    r.appendChild(l, labelEl())
    r.appendChild(el, l)
    h += BodyLinePx
  if reason.len > 0:
    let t = r.wrapText(reason, CaptionPx, 16, p.textCaption)
    r.styles(t, [("margin-top", "2px"), ("margin-left", $under & "px")])
    r.tag(t, "detail", reason)
    r.appendChild(el, t)
    h += 2 + 16 * linesOf(reason, CaptionPx, textPxAvail)
  if delivery.len > 0:
    let t = r.wrapText(delivery, CaptionPx, 16, roleInk(p, dRole))
    r.styles(t, [("margin-top", "2px"), ("margin-left", $under & "px")])
    r.tag(t, "delivery", delivery)
    r.appendChild(el, t)
    h += 2 + 16 * linesOf(delivery, CaptionPx, textPxAvail)
  if narrow and actions.len > 0:
    let a = r.box(pairs = [("gap", "6px"), ("margin-top", "4px"),
                           ("height", $ControlPx & "px")])
    actionsRow(a)
    r.appendChild(el, a)
    h += 4 + ControlPx
  result = r.spaced(el, h, top = 6, bottom = 6)

proc fieldEl(r: GpuiRenderer; p: AhPalette; label, value, problem: string;
             widthPx: int; placeholder = ""): (GpuiElement, int) =
  ## A field: its label over its value drawn as the app's input field, and
  ## its problem under it.
  let el = r.box(column = true, pairs = [("gap", "3px"), ("width", $widthPx & "px"),
                                         ("min-width", "0px"), ("flex-shrink", "0")])
  r.tag(el, "field-label", label)
  let l = r.text(label, CaptionPx, p.textLabel, shrink = false)
  r.tag(l, "field-name", label)
  r.appendChild(el, l)
  let v = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                         ("padding-left", "8px"), ("padding-right", "8px"),
                         ("rounded", $ControlRadiusPx & "px"), ("border-width", "1px"),
                         ("border-color", if problem.len > 0: p.textError else: p.borderPrimary),
                         ("background", p.ground)])
  let shown = if value.len > 0: value else: placeholder
  let t = r.text(shown, BodyPx, if value.len > 0: p.textBody else: p.textCaption)
  r.tag(t, "value", shown)
  r.appendChild(v, t)
  r.appendChild(el, v)
  var h = CaptionLinePx + 3 + ControlPx
  if problem.len > 0:
    let pr = r.wrapText(problem, CaptionPx, 16, p.textError)
    r.tag(pr, "problem", problem)
    r.appendChild(el, pr)
    h += 3 + 16 * linesOf(problem, CaptionPx, widthPx)
  (el, h)

proc choiceEl(r: GpuiRenderer; p: AhPalette; label: string; options, chosen: seq[string];
              widthPx: int; problem = ""; several = false): (GpuiElement, int) =
  ## A choice among a few options: a row of toggles, the chosen ones in the
  ## action border (`✓` before each when several may be).
  let el = r.box(column = true, pairs = [("gap", "3px"), ("width", $widthPx & "px")])
  r.tag(el, "field-label", label)
  let l = r.text(label, CaptionPx, p.textLabel, shrink = false)
  r.tag(l, "field-name", label)
  r.appendChild(el, l)
  var items: seq[FlowItem]
  var lines = 1
  var used = 0
  for o in options:
    let on = o in chosen
    let shown = if several and on: "\xE2\x9C\x93 " & o else: o
    let (c, w) = r.chip(p, shown, if on: p.textBody else: p.textLabel,
                        border = if on: p.borderAction else: p.borderSecondary)
    r.tag(c, "toggle", o)
    r.tag(c, "chosen", $on)
    r.acts(c, "choose-option", o)
    items.add FlowItem(el: c, widthPx: w)
    if used > 0 and used + 4 + w > widthPx:
      inc lines
      used = w
    else: used += (if used > 0: 4 else: 0) + w
  r.appendChild(el, r.flowLines(items, widthPx, 4, ControlPx, 4))
  var h = CaptionLinePx + 3 + lines * ControlPx + (lines - 1) * 4
  if problem.len > 0:
    let pr = r.wrapText(problem, CaptionPx, 16, p.textError)
    r.tag(pr, "problem", problem)
    r.appendChild(el, pr)
    h += 3 + 16 * linesOf(problem, CaptionPx, widthPx)
  (el, h)

proc gridOf(r: GpuiRenderer; fields: seq[((GpuiElement, int), bool)];
            narrow: bool): (GpuiElement, int) =
  ## Fields two to a line (a wide one alone), one per line when narrow,
  ## 8px between lines and 12px between columns (`.ah-composer-form-grid`).
  let col = r.box(column = true, pairs = [("gap", "8px")])
  var h = 0
  var i = 0
  var lines = 0
  while i < fields.len:
    let ((a, ah), wide) = fields[i]
    let line = r.box(pairs = [("gap", "12px"), ("items", "start")])
    r.appendChild(line, a)
    var lh = ah
    if not (narrow or wide or i + 1 >= fields.len or fields[i + 1][1]):
      let (b, bh) = fields[i + 1][0]
      r.appendChild(line, b)
      lh = max(ah, bh)
      i += 2
    else: inc i
    r.setStyle(line, "height", $lh & "px")
    r.appendChild(col, line)
    h += lh
    inc lines
  h += max(0, lines - 1) * 8
  (col, h)

proc formBlocks(r: GpuiRenderer; p: AhPalette; vm: OmniboxComposerVM;
                lay: Layout): seq[Block] =
  let w = lay.widthPx
  let narrow = lay.narrow
  let colW = if narrow: w else: (w - 12) div 2
  let head = r.box(column = true, pairs = [("border-top-width", "1px"),
                                           ("border-color", p.borderSecondary)])
  r.tag(head, "form", $vm.intent)
  let title = r.text(vm.formTitle, CaptionPx, p.textCaption)
  r.tag(title, "form-title", vm.formTitle)
  r.appendChild(head, title)
  let open = vm.optionsOpen.val
  result.add r.spaced(head, 1 + 8 + CaptionLinePx + 6, top = 8, bottom = 6)
  r.setStyle(head, "margin-top", "4px")
  result[^1].heightPx += 4
  if not open: return
  let problems = vm.problems
  var fields: seq[((GpuiElement, int), bool)]
  if vm.intent == riLaunchTask:
    let o = vm.launch
    fields.add (r.fieldEl(p, "Repository", o.repository, problemOf(problems, "repository"),
                          colW, "Choose a repository"), false)
    fields.add (r.fieldEl(p, "Branch", o.branch, "", colW, "default branch"), false)
    fields.add (r.choiceEl(p, "Agents", vm.agentChoices, o.agents, w,
                           problemOf(problems, "agents"), several = true), true)
    var runOn: seq[string]
    for v in RunOn: runOn.add $v
    fields.add (r.choiceEl(p, "Runs on", runOn, @[$o.runOn], w), true)
    if o.runOn == roExecutor:
      fields.add (r.fieldEl(p, "Executor", o.executor, problemOf(problems, "executor"),
                            colW, "Choose an executor"), false)
    fields.add (r.fieldEl(p, "Session name", o.sessionName, "", colW,
                          "named by the server"), o.runOn != roExecutor)
    var openIn: seq[string]
    for v in OpenIn: openIn.add $v
    fields.add (r.choiceEl(p, "Opens in", openIn, @[$o.openIn], w), true)
    let (grid, gh) = r.gridOf(fields, narrow)
    result.add r.spaced(grid, gh + 8, bottom = 8)
    # The schedule's head line, and its fields when open.
    let sopen = vm.scheduleOpen.val
    let (summary, problem) = vm.scheduleSummary
    let sh = r.box(pairs = [("height", "20px"), ("items", "center"), ("gap", "6px")])
    r.tag(sh, "schedule", $sopen)
    r.acts(sh, "schedule", "")
    r.appendChild(sh, r.text(if sopen: "\xE2\x96\xBE" else: "\xE2\x96\xB8", CaptionPx,
                             tokenHexOf(dtColorsUiIconPrimaryDefault, p.mode), shrink = false))
    let sl = r.text(ScheduleLabel, CaptionPx, p.textLabel, shrink = false)
    r.tag(sl, "field-name", ScheduleLabel)
    r.appendChild(sh, sl)
    let ss = r.text(summary, CaptionPx, if problem: p.textError else: p.textCaption)
    r.tag(ss, "schedule-summary", summary)
    r.appendChild(sh, ss)
    result.add r.spaced(sh, 20 + 8, bottom = 8)
    result[^1].schedule = not sopen
    if sopen:
      let s = o.schedule
      var sched: seq[((GpuiElement, int), bool)]
      sched.add (r.fieldEl(p, "Cron", s.cron, problemOf(problems, "cron"), colW,
                           "minute hour day month weekday"), false)
      sched.add (r.fieldEl(p, "Time zone", s.timezone, problemOf(problems, "timezone"),
                           colW, "UTC"), false)
      sched.add (r.fieldEl(p, "Jitter", $s.jitterSeconds & " s",
                           problemOf(problems, "jitter"), colW), true)
      var conc, mis: seq[string]
      for v in Concurrency: conc.add $v
      for v in Misfire: mis.add $v
      sched.add (r.choiceEl(p, "Concurrency", conc, @[$s.concurrency], w), true)
      sched.add (r.choiceEl(p, "Misfire", mis, @[$s.misfire], w), true)
      let (g2, h2) = r.gridOf(sched, narrow)
      result.add r.spaced(g2, h2 + 8, bottom = 8)
      result[^1].schedule = true
  else:
    let f = vm.initiative
    fields.add (r.fieldEl(p, "Goal", f.goal, problemOf(problems, "goal"), w,
                          "What the initiative is for"), true)
    var modes: seq[string]
    for v in IterationMode: modes.add $v
    fields.add (r.choiceEl(p, "Iterations", modes, @[$f.iteration], w), true)
    if f.iteration == imCount:
      fields.add (r.fieldEl(p, "Number of iterations", $f.iterations,
                            problemOf(problems, "iterations"), colW), true)
    fields.add (r.fieldEl(p, "Plan file", vm.planPreview, problemOf(problems, "plan"), w), true)
    fields.add (r.fieldEl(p, "Related specs", f.relatedSpecs.join(", "), "", w, "none"), true)
    let (grid, gh) = r.gridOf(fields, narrow)
    result.add r.spaced(grid, gh + 8, bottom = 8)

proc bodyBlocks(r: GpuiRenderer; p: AhPalette; vm: OmniboxComposerVM;
                lay: Layout): seq[Block] =
  let w = lay.widthPx
  let whole = vm.instructionBlock
  if whole.len > 0 and vm.phase == cpComposing:
    let t = r.wrapText(whole, BodyPx, BodyLinePx, p.textBody)
    r.tag(t, "instruction", whole)
    result.add r.spaced(t, 4 + BodyLinePx * linesOf(whole, BodyPx, w) + 8, top = 4, bottom = 8)
  # What was sent, and where it went (no line while every delivery failed:
  # the header and the row say it, D37).
  let (sentText, sent) = vm.sentBlock
  if sentText.len > 0:
    let col = r.box(column = true, pairs = [("gap", "2px")])
    let t = r.wrapText(sentText, BodyPx, BodyLinePx, p.textBody)
    r.tag(t, "sent-text", sentText)
    r.appendChild(col, t)
    var h = BodyLinePx * linesOf(sentText, BodyPx, w)
    if sent.len > 0:
      let l = r.wrapText(sent, CaptionPx, 16, p.textCaption)
      r.tag(l, "sent-line", sent)
      r.appendChild(col, l)
      h += 2 + 16 * linesOf(sent, CaptionPx, w)
    result.add r.spaced(col, h + 8, bottom = 8)
  if vm.isEmptyField:
    result.add r.recentBlocks(p, vm, lay)
    return
  result.add r.contextBlocks(p, vm, lay)
  # The destinations, under a hairline.
  let rule = r.box(pairs = [("border-top-width", "1px"), ("border-color", p.borderSecondary)])
  result.add Block(heightPx: 1 + 4, el: rule)
  r.styles(rule, [("height", "5px"), ("flex-shrink", "0")])
  let rows = vm.rows
  for i, row in rows:
    var b = r.rowBlock(p, vm, lay, row)
    if i > 0:
      r.setStyle(b.el, "margin-top", "4px")
      b.heightPx += 4
    result.add b
  if vm.showsForm: result.add r.formBlocks(p, vm, lay)
  let stopMessage = vm.stopMessage.val
  if stopMessage.len > 0:
    let t = r.wrapText(stopMessage, CaptionPx, 16,
                       if vm.stopState.val == ssFailed: p.textError else: p.textCaption)
    r.tag(t, "stopped", stopMessage)
    result.add r.spaced(t, 6 + 16 * linesOf(stopMessage, CaptionPx, w), top = 6)

proc sendLine(r: GpuiRenderer; p: AhPalette; vm: OmniboxComposerVM;
              press: ComposerPress): GpuiElement =
  let sending = vm.phase == cpSending
  let canSend = vm.canSend and not sending
  let (hint, more, blocked) = vm.sendHint
  let label = vm.sendLabel
  result = r.box(pairs = [("height", $(8 + ControlPx + 8) & "px"), ("items", "center"),
                          ("justify", "end"), ("gap", "12px"), ("flex-shrink", "0"),
                          ("padding-left", $PadPx & "px"), ("padding-right", $PadPx & "px"),
                          ("border-top-width", "1px"), ("border-color", p.borderSecondary)])
  r.tag(result, "send", label)
  r.tag(result, "send-enabled", $canSend)
  r.tag(result, "send-blocked", $blocked)
  let words = r.box(pairs = [("min-width", "0px"), ("flex-shrink", "1"), ("items", "center")])
  let h = r.text(hint, CaptionPx, if blocked: p.textError else: p.textCaption)
  r.tag(h, "send-hint", hint)
  r.appendChild(words, h)
  if more.len > 0:
    let m = r.text(more, CaptionPx, p.textCaption, shrink = false)
    r.tag(m, "send-more", more)
    r.appendChild(words, m)
  r.appendChild(result, words)
  let b = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                         ("padding-left", "12px"), ("padding-right", "12px"),
                         ("flex-shrink", "0"), ("rounded", $ControlRadiusPx & "px"),
                         ("border-width", "1px")])
  if canSend:
    # CodeTracer's own primary button in both themes (P2c study D39): the
    # action fill with the on-action text, no border of another colour.
    r.styles(b, [("border-color", p.action), ("background", p.action)])
    r.appendChild(b, r.text(label, CaptionPx, p.onAction, shrink = false))
  else:
    r.setStyle(b, "border-color", p.borderSecondary)
    r.appendChild(b, r.text(label, CaptionPx, p.textDisabled, shrink = false))
  r.tag(b, "button", label)
  r.acts(b, "send", "", press)
  r.appendChild(result, b)

proc drawComposer*(r: GpuiRenderer; host: GpuiElement; vm: OmniboxComposerVM;
                   p: AhPalette; widthPx, heightPx: int; press: ComposerPress = nil) =
  ## The caption bar with the field, and the sheet under it, in `host`,
  ## `widthPx` × `heightPx`; a press is reported to `press` (nil: nowhere).
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("position", "relative"), ("width", $widthPx & "px"),
                  ("height", $heightPx & "px"), ("background", p.panel),
                  ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-composer")
  r.tag(host, "phase", $vm.phase)
  r.tag(host, "route", $vm.route)
  # The caption bar and its omnibox field.
  let caption = r.box(pairs = [("height", $CaptionBarPx & "px"), ("flex-shrink", "0"),
                               ("items", "center"), ("justify", "center"),
                               ("background", p.ground)])
  # While the sheet is open the field has the sheet's edges (P2c study D36):
  # `sheetWidthFor`, centred, the sheet's own.
  let fieldW = vm.sheetWidthFor(widthPx)
  let field = r.box(pairs = [("width", $fieldW & "px"), ("height", $FieldHeightPx & "px"),
                             ("items", "center"), ("padding-left", "12px"),
                             ("padding-right", "12px"), ("gap", "8px"),
                             ("rounded", $ControlRadiusPx & "px"), ("border-width", "1px"),
                             ("border-color", p.borderPrimary), ("background", p.panel)])
  let fieldText = ComposerPrefix & vm.fieldText
  # Never cut by an ellipsis (P2c D32), and its end, where the caret is, in
  # view (D36): the field shows the longest end of the text that fits, as
  # an input scrolled to its end does.
  let more0 = vm.moreLines
  let room = fieldW - 24 - (if more0.len > 0: textPx(more0, CaptionPx) + 8 else: 0)
  let ft = r.text(endThatFits(fieldText, BodyPx, room), BodyPx, p.textBody, shrink = false,
                  pairs = [("flex-grow", "1"), ("flex-shrink", "1"), ("min-width", "0px"),
                           ("overflow", "hidden")])
  r.tag(ft, "field", fieldText)
  r.appendChild(field, ft)
  let more = vm.moreLines
  if more.len > 0:
    let m = r.text(more, CaptionPx, p.textCaption, shrink = false)
    r.tag(m, "more-lines", more)
    r.appendChild(field, m)
  r.tag(field, "field-row", "true")
  r.appendChild(caption, field)
  r.appendChild(host, caption)
  # The sheet.
  let sheetW = vm.sheetWidthFor(widthPx)
  let narrow = vm.isNarrow(widthPx)
  let lay = Layout(widthPx: sheetW - 2 * PadPx, narrow: narrow, press: press)
  let header = vm.headerText
  let headerLines = linesOf(header, CaptionPx, lay.widthPx)
  let topPx = 8 + 16 * headerLines + 6
  # The send line, as the web draws it: never with nothing typed (`Recent`).
  let footerPx = if vm.showsSendLine and not vm.isEmptyField: 8 + ControlPx + 8 + 1 else: 0
  let blocks = r.bodyBlocks(p, vm, lay)
  var total = 0
  for b in blocks: total += b.heightPx
  let maxH = heightPx - CaptionBarPx - TriggerGapPx - 16
  let bodyRoom = max(16, maxH - topPx - footerPx - 1)
  const MoreLinePx = 4 + CaptionLinePx + 4 + 1
  var first = 0
  var last = blocks.high
  var moreBelow = false
  if total > bodyRoom:
    var scheduleEnd = -1
    for i, b in blocks:
      if b.schedule: scheduleEnd = i
    if scheduleEnd >= 0 and vm.scheduleOpen.val:
      last = scheduleEnd
      moreBelow = scheduleEnd < blocks.high
      let room = bodyRoom - (if moreBelow: MoreLinePx else: 0)
      var used = 0
      first = scheduleEnd + 1
      while first > 0 and used + blocks[first - 1].heightPx <= room:
        dec first
        used += blocks[first].heightPx
    else:
      moreBelow = true
      var used = 0
      last = -1
      while last + 1 < blocks.len and used + blocks[last + 1].heightPx <= bodyRoom - MoreLinePx:
        inc last
        used += blocks[last].heightPx
  var bodyPx = 0
  for i in first .. last: bodyPx += blocks[i].heightPx
  if moreBelow: bodyPx += MoreLinePx
  let sheetH = topPx + bodyPx + footerPx + 1
  let sheet = r.box(column = true, pairs = [
    ("position", "absolute"), ("top", $(CaptionBarPx + TriggerGapPx) & "px"),
    ("left", $((widthPx - sheetW) div 2) & "px"), ("width", $sheetW & "px"),
    ("height", $sheetH & "px"), ("background", p.ground),
    ("border-width", "1px"), ("border-color", p.borderPrimary),
    ("rounded", $SheetRadiusPx & "px"), ("overflow", "hidden")])
  r.tag(sheet, "sheet", $vm.phase)
  r.tag(sheet, "hidden-above", $first)
  r.tag(sheet, "hidden-below", $(blocks.high - last))
  let head = r.wrapText(header, CaptionPx, 16, roleInk(p, vm.headerRole))
  r.styles(head, [("padding-left", $PadPx & "px"), ("padding-right", $PadPx & "px"),
                  ("padding-top", "8px"), ("padding-bottom", "6px"),
                  ("height", $topPx & "px"), ("flex-shrink", "0")])
  r.tag(head, "header", header)
  r.appendChild(sheet, head)
  let body = r.box(column = true, pairs = [("height", $bodyPx & "px"), ("flex-shrink", "0"),
                                           ("overflow", "hidden")])
  for i in first .. last: r.appendChild(body, blocks[i].el)
  if moreBelow:
    let m = r.box(pairs = [("height", $MoreLinePx & "px"), ("flex-shrink", "0"),
                           ("items", "center"), ("justify", "end"),
                           ("padding-right", $PadPx & "px"),
                           ("border-top-width", "1px"), ("border-color", p.borderSecondary),
                           ("background", p.ground)])
    let t = r.text(MoreBelow, CaptionPx, p.textCaption, shrink = false)
    r.tag(t, "more-below", MoreBelow)
    r.appendChild(m, t)
    r.appendChild(body, m)
  r.appendChild(sheet, body)
  if footerPx > 0: r.appendChild(sheet, r.sendLine(p, vm, press))
  r.appendChild(host, sheet)

proc mountComposer*(r: GpuiRenderer; host: GpuiElement; vm: OmniboxComposerVM;
                    p: AhPalette; widthPx, heightPx: int; press: ComposerPress = nil) =
  ## Draws the composer, and again whenever what it shows moves.
  createRenderEffect proc() =
    discard vm.revision.val
    discard vm.optionsOpen.val
    discard vm.scheduleOpen.val
    discard vm.addContextOpen.val
    discard vm.stopState.val
    discard vm.stopMessage.val
    drawComposer(r, host, vm, p, widthPx, heightPx, press)
