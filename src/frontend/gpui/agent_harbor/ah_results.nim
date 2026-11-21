## gpui/agent_harbor/ah_results.nim — CTF-P2c step 2. The GPUI omnibox
## result commands and search: the caption bar's omnibox field holding
## `/s …`, `/ah…` or an instruction ending in a sigil, and under it the rows
## the command answered, grouped by provider, over `ResultCommandsVM`
## (nim-agents-isonim-viewmodels), drawn as the web's
## `isonim_agent_harbor_results_view` draws it (`agent_harbor_results.styl`)
## from the same words (`agent_harbor_results_words`), in the same places.
##
## The sheet is the composer's (`ah_composer`): the window's ground, a
## hairline border, `sheetWidthFor` wide and centred under the field, which
## has the sheet's edges (P2c study D36). Top to bottom: the header
## (pinned), then the body: `← All providers` with one group alone, the line
## in place of the rows, and each group -- its title and state, its rows
## (the title with the query's match in bold, what it is, where it is and a
## quiet tag at the right; a command's description under it), `+N more`. A
## hairline between groups. The selected row is on the editor's selection
## ground (`colors-editor-surface-select`) with an inset bar (D63).
##
## A rich row draws its text form (OMNI-AREQ4, D45): GPUI cannot render
## HTML. GPUI's layout does not scroll a box, so the body is laid out here
## row by row at the stylesheet's heights, and one that holds more ends in
## the quiet `More below ↓` line.
##
## Presses are routed (Input-Routing-And-Keymaps.md §5.1, D48): each element
## a press acts on carries its operation (`data-ct-operation`) and its
## target (`data-ah-target`), and its press-down listener only reports both
## to the host's `ResultsPress`. Facts (`data-ah-*`) are the terminal's
## (`tui/agent_harbor/ah_tui_results.nim`).

import std/strutils
import nim_agents_isonim_viewmodels/agent_harbor/result_commands_vm
import ../../viewmodel/views/agent_harbor_results_words
from ../../viewmodel/views/cut_text_rules import cutAroundMatch
import ./ah_theme
import ./ah_composer
from ./ah_session_activity import wrappedRows
from ../../viewmodel/input/element_press import OperationAttribute

export result_commands_vm, agent_harbor_results_words, ah_theme

type
  Block = object
    heightPx: int
    el: GpuiElement

const
  RowPx = 26           ## a row: 5px, a 16px line, 5px
  SecondLinePx = 16
  GroupHeadPx = 4 + CaptionLinePx + 4
  GroupGapPx = 8 + 1   ## the gap and the hairline between groups
  MoreLinePx = 4 + CaptionLinePx + 4 + 1

proc pressable(r: GpuiRenderer; el: GpuiElement; operation, target: string;
               press: ResultsPress) =
  r.setAttribute(el, OperationAttribute, operation)
  r.setAttribute(el, "data-ah-target", target)
  r.tag(el, "operation", operation)
  if press != nil:
    r.addEventListener(el, "mousedown", proc(ev: GpuiEvent) =  # ir1-gate: hit test
      press(operation, target))

proc padded(r: GpuiRenderer; el: GpuiElement; heightPx: int): Block =
  r.styles(el, [("padding-left", $PadPx & "px"), ("padding-right", $PadPx & "px"),
                ("height", $heightPx & "px"), ("flex-shrink", "0")])
  Block(heightPx: heightPx, el: el)

proc titleEl(r: GpuiRenderer; p: AhPalette; row: ResultRow; query: string;
             availPx: int): GpuiElement =
  ## The title, its query's matches in bold. Where the whole title fits, its
  ## parts are drawn side by side; where it does not, one text cut by the
  ## views' rule (one weight: the cut is one string, as the web's).
  if textPx(row.title, BodyPx) <= availPx and matchSpans(row.title, query).len > 0:
    result = r.box(pairs = [("flex-shrink", "0"), ("items", "baseline")])
    for part in titleParts(row, query):
      r.appendChild(result, r.text(part.text, BodyPx, p.textBody, bold = part.matched,
                                   shrink = false))
  else:
    result = r.text(row.title, BodyPx, p.textBody,
                    pairs = [("min-width", "0px"), ("flex-shrink", "1")])
  r.tag(result, "title", row.title)

proc rightParts(r: GpuiRenderer; p: AhPalette; into: GpuiElement; row: ResultRow;
                tag, ink: string) =
  ## Where the row is (a path, cut in its middle) and its tag.
  if row.location.len > 0:
    let l = r.pathText(row.location, CaptionPx, ink)
    r.styles(l, [("min-width", "0px"), ("flex-shrink", "0")])
    r.tag(l, "location", row.location)
    r.appendChild(into, l)
  if tag.len > 0:
    let t = r.text(tag, CaptionPx, ink, shrink = false)
    r.tag(t, "tag", tag)
    r.appendChild(into, t)

proc rowBlock(r: GpuiRenderer; p: AhPalette; vm: ResultCommandsVM; g: ShownGroup;
              index: int; query: string; widthPx: int; narrow: bool;
              press: ResultsPress): Block =
  ## One row, as the web lays it out: at laptop width the title (giving way
  ## first), what it is, and where it is with its tag at the right; at
  ## sidebar width what it is and where on a line under the title; under
  ## both a command's description, or `Opened outside CodeTracer`.
  let row = g.rows[index]
  let selected = vm.isSelected(g, index)
  let detail = vm.rowDetail(row)
  let second = vm.rowSecondLine(row)
  let tag = vm.rowTagText(row)
  let underTitle = narrow and (detail.len > 0 or row.location.len > 0 or tag.len > 0)
  let secondLines = if second.len > 0: max(1, wrappedRows(second, CaptionPx, widthPx)) else: 0
  # A line of the program's text is one line, cut around the match that
  # put it in the list, which stays whole (`cutAroundMatch`, P2c study D62).
  let code = row.kind == rkLine
  let rightPx0 = if narrow: 0
                 else: min((if row.location.len > 0: textPx(row.location, CaptionPx) + 8 else: 0) +
                           (if tag.len > 0: textPx(tag, CaptionPx) + 8 else: 0), widthPx * 45 div 100)
  let h = RowPx + (if underTitle: SecondLinePx else: 0) + SecondLinePx * secondLines
  let el = r.box(column = true, pairs = [("justify", "center"), ("margin-left", "1px"),
                                         ("margin-right", "1px")])
  # The editor's selection ground (`colors-editor-surface-select`, the
  # Calltrace's and the editor's lists'), with the inset bar in the action
  # border role down its left edge (P2c study D63); its quieter words take
  # the label role in Light (the caption is about 4:1 on it).
  if selected:
    r.styles(el, [("background", DesignTokenHex[dtColorsEditorSurfaceSelect][p.mode]),
                  ("position", "relative")])
    r.appendChild(el, r.insetBar(p.borderAction, 2))
    r.tag(el, "selected-ground", DesignTokenHex[dtColorsEditorSurfaceSelect][p.mode])
  let quiet = if selected and p.mode == dmLight: p.textLabel else: p.textCaption
  r.tag(el, "row", row.title)
  r.tag(el, "selected", $selected)
  r.tag(el, "kind", $row.kind)
  r.pressable(el, ResultsOpenOperation, $(g.first + index), press)
  let line = r.box(pairs = [("items", "baseline"), ("gap", "8px"), ("min-width", "0px")])
  if code:
    let (ms, me) = matchedSpan(row, query)
    let measure = proc(text: string): int = textPx(text, BodyPx)
    let shown = cutAroundMatch(row.title, ms, me, max(1, widthPx - rightPx0 - 8), measure,
                               measure(Ellipsis))
    # The match bold where the cut drew it (D62), the rest in the body role.
    let t = r.box(pairs = [("min-width", "0px"), ("flex-grow", "1"), ("items", "baseline")])
    # Every match in view bold (D62), the rest in the body role.
    let mt = if me > ms: row.title[ms ..< me] else: ""
    var from0 = 0
    for (s0, n0) in spansIn(shown, mt):
      if s0 > from0:
        r.appendChild(t, r.text(shown[from0 ..< s0], BodyPx, p.textBody, shrink = false))
      let m = r.text(shown[s0 ..< s0 + n0], BodyPx, p.textBody, bold = true, shrink = false)
      r.tag(m, "match", shown[s0 ..< s0 + n0])
      r.appendChild(t, m)
      from0 = s0 + n0
    if from0 < shown.len:
      r.appendChild(t, r.text(shown[from0 .. ^1], BodyPx, p.textBody, shrink = false))
    # The title as drawn (the cover suite holds it to the drawing), and
    # the same as `title-shown` for the follow-up suite.
    r.tag(t, "title", shown)
    r.tag(t, "title-shown", shown)
    r.appendChild(line, t)
    if not narrow: r.rightParts(p, line, row, tag, quiet)
  elif not narrow:
    var rightPx = 0
    if row.location.len > 0: rightPx += textPx(row.location, CaptionPx) + 8
    if tag.len > 0: rightPx += textPx(tag, CaptionPx) + 8
    rightPx = min(rightPx, widthPx * 45 div 100)
    let detailPx = if detail.len > 0: min(textPx(detail, CaptionPx), widthPx div 2) + 8 else: 0
    r.appendChild(line, r.titleEl(p, row, query, max(48, widthPx - rightPx - detailPx)))
    if detail.len > 0:
      let d = r.text(detail, CaptionPx, quiet, pairs = [("min-width", "32px"),
                                                        ("flex-shrink", "0")])
      r.tag(d, "detail", detail)
      r.appendChild(line, d)
    r.appendChild(line, r.box(pairs = [("flex-grow", "1"), ("min-width", "0px")]))
    r.rightParts(p, line, row, tag, quiet)
  elif not code:
    r.appendChild(line, r.titleEl(p, row, query, widthPx))
  r.appendChild(el, line)
  if underTitle:
    let u = r.box(pairs = [("gap", "8px"), ("min-width", "0px"), ("items", "baseline")])
    if detail.len > 0:
      let d = r.text(detail, CaptionPx, quiet, pairs = [("min-width", "0px")])
      r.tag(d, "detail", detail)
      r.appendChild(u, d)
    r.appendChild(u, r.box(pairs = [("flex-grow", "1"), ("min-width", "0px")]))
    r.rightParts(p, u, row, tag, quiet)
    r.appendChild(el, u)
  if second.len > 0:
    let s = r.text(second, CaptionPx, quiet, shrink = false,
                   pairs = [("white-space", "pre-wrap"), ("line-height", $SecondLinePx & "px"),
                            ("min-width", "0px"), ("flex-shrink", "1")])
    r.tag(s, "second", second)
    r.appendChild(el, s)
  r.padded(el, h)

proc bodyBlocks(r: GpuiRenderer; p: AhPalette; vm: ResultCommandsVM; widthPx: int;
                narrow: bool; press: ResultsPress): seq[Block] =
  if vm.alone.val.len > 0:
    let b = r.box(pairs = [("items", "center")])
    let t = r.text(AllProviders, CaptionPx, p.textCaption, shrink = false)
    r.appendChild(b, t)
    r.tag(b, "back", AllProviders)
    r.pressable(b, ResultsAllOperation, "", press)
    result.add r.padded(b, 4 + CaptionLinePx + 6)
  let n = vm.notice
  if n.text.len > 0:
    let b = r.box(column = true, pairs = [("padding-top", "8px")])
    let lines = max(1, wrappedRows(n.text, BodyPx, widthPx))
    let t = r.text(n.text, BodyPx, if n.role == "error": p.textError else: p.textBody,
                   shrink = false, pairs = [("white-space", "pre-wrap"),
                                            ("line-height", "20px"), ("min-width", "0px"),
                                            ("flex-shrink", "1")])
    r.tag(b, "notice-line", n.text)
    r.tag(b, "notice-role", n.role)
    r.appendChild(b, t)
    var h = 8 + 20 * lines + 12
    if n.hint.len > 0:
      let hint = r.text(n.hint, CaptionPx, p.textCaption, shrink = false)
      r.tag(hint, "notice-hint", n.hint)
      r.appendChild(b, hint)
      h += CaptionLinePx
    result.add r.padded(b, h)
  let query = vm.queryText
  let groups = vm.groups
  for gi in 0 ..< groups.len:
    let g = groups[gi]
    if gi > 0:
      let gap = r.box(column = true, pairs = [("height", $GroupGapPx & "px"),
                                              ("flex-shrink", "0"), ("justify", "center")])
      let rule = r.box(pairs = [("height", "1px"), ("background", p.borderSecondary)])
      r.appendChild(gap, rule)
      result.add Block(heightPx: GroupGapPx, el: gap)
    let titleText = g.group.title.toUpperAscii
    let state = stateWord(g.group)
    let failed = stateRole(g.group) == "error"
    # A failure's reason that does not fit beside the title wraps on lines
    # of its own under it (the web's and the terminal's rule).
    let beside = textPx(titleText, CaptionPx) + 12 + textPx(state, CaptionPx) <= widthPx
    let head = r.box(column = not beside,
                     pairs = (if beside: @[("items", "center"), ("justify", "between"),
                                           ("gap", "12px")]
                              else: @[("justify", "center")]))
    let title = r.tracked(r.text(titleText, CaptionPx, p.textLabel, bold = true))
    r.appendChild(head, title)
    let st = if beside or not failed:
               r.text(state, CaptionPx, if failed: p.textError else: p.textCaption)
             else:
               r.text(state, CaptionPx, p.textError, shrink = false,
                      pairs = [("white-space", "pre-wrap"), ("line-height", $CaptionLinePx & "px"),
                               ("min-width", "0px"), ("flex-shrink", "1")])
    r.appendChild(head, st)
    r.tag(head, "group", g.group.id)
    r.tag(head, "group-state", $g.group.state)
    r.tag(head, "state", state)
    let stateLines = if beside: 0 else: max(1, wrappedRows(state, CaptionPx, widthPx))
    result.add r.padded(head, GroupHeadPx + CaptionLinePx * stateLines)
    for i in 0 ..< g.rows.len:
      result.add r.rowBlock(p, vm, g, i, query, widthPx, narrow, press)
    let more = moreLabel(g)
    if more.len > 0:
      let m = r.box(pairs = [("items", "center")])
      r.appendChild(m, r.text(more, CaptionPx, p.textLabel, shrink = false))
      r.tag(m, "more", more)
      r.pressable(m, ResultsMoreOperation, g.group.id, press)
      result.add r.padded(m, 4 + CaptionLinePx + 4)
  # The providers that answered with nothing: one quiet line after the
  # groups, in place of a group each (P2c study D60).
  let empty = emptyProvidersLine(vm)
  if empty.len > 0:
    # Set apart from the last group as a group is: the gap and its hairline.
    let gap = r.box(column = true, pairs = [("height", $GroupGapPx & "px"),
                                            ("flex-shrink", "0"), ("justify", "center")])
    r.appendChild(gap, r.box(pairs = [("height", "1px"), ("background", p.borderSecondary)]))
    result.add Block(heightPx: GroupGapPx, el: gap)
    let b = r.box(column = true, pairs = [("padding-top", "6px")])
    let lines = max(1, wrappedRows(empty, CaptionPx, widthPx))
    r.appendChild(b, r.text(empty, CaptionPx, p.textCaption, shrink = false,
                            pairs = [("white-space", "pre-wrap"),
                                     ("line-height", $CaptionLinePx & "px"),
                                     ("min-width", "0px"), ("flex-shrink", "1")]))
    r.tag(b, "empty-providers", empty)
    result.add r.padded(b, 6 + CaptionLinePx * lines + 4)

proc drawResults*(r: GpuiRenderer; host: GpuiElement; vm: ResultCommandsVM;
                  p: AhPalette; widthPx, heightPx: int; press: ResultsPress = nil) =
  ## The caption bar with the field, and the sheet under it, in `host`.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("position", "relative"), ("width", $widthPx & "px"),
                  ("height", $heightPx & "px"), ("background", p.panel),
                  ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-results")
  r.tag(host, "kind", $vm.kind)
  let sheetW = vm.sheetWidthFor(widthPx)
  # The web draws the composer's own field and sheet here
  # (`.ah-composer-input-row`, `.ah-composer-sheet`), so they sit where the
  # composer's do: the field at `FieldTopPx` on the ground with the inputs'
  # hairline, its text clipped inside its padding, the sheet at `SheetTopPx`.
  let caption = r.box(pairs = [("height", $CaptionBarPx & "px"), ("flex-shrink", "0"),
                               ("items", "start"), ("justify", "center"),
                               ("background", p.ground)])
  let field = r.box(pairs = [("width", $sheetW & "px"), ("height", $FieldHeightPx & "px"),
                             ("margin-top", $FieldTopPx & "px"),
                             ("items", "center"), ("padding-left", "12px"),
                             ("padding-right", "12px"),
                             ("rounded", $ControlRadiusPx & "px"), ("border-width", "1px"),
                             ("border-color", p.borderSecondary), ("background", p.ground)])
  let input = vm.input
  let clip = r.box(pairs = [("flex-grow", "1"), ("flex-shrink", "1"), ("min-width", "0px"),
                            ("overflow", "hidden"), ("items", "center")])
  # The end of what is typed, in the box inside the two 1px hairlines and
  # the 12px paddings (D36).
  let ft = r.text(endThatFits(input, BodyPx, sheetW - 2 - 24), BodyPx, p.textBody, shrink = false,
                  pairs = [("height", $(FieldHeightPx - 2) & "px"),
                           ("line-height", $(FieldHeightPx - 2) & "px")])
  r.tag(ft, "field", input)
  r.appendChild(clip, ft)
  r.appendChild(field, clip)
  r.appendChild(caption, field)
  r.appendChild(host, caption)
  let narrow = vm.isNarrow(widthPx)
  let innerW = sheetW - 2 * PadPx
  let header = vm.headerText
  let headerLines = max(1, wrappedRows(header, CaptionPx, innerW))
  let topPx = 8 + 16 * headerLines + 6
  let blocks = r.bodyBlocks(p, vm, innerW, narrow, press)
  var total = 0
  for b in blocks: total += b.heightPx
  # Up to the window less the caption bar and its inset (the composer's
  # `max-height`).
  let maxH = heightPx - CaptionBarPx - SheetInsetPx
  let bodyRoom = max(16, maxH - topPx - 4)
  var last = blocks.high
  var moreBelow = false
  if total > bodyRoom:
    moreBelow = true
    var used = 0
    last = -1
    while last + 1 < blocks.len and used + blocks[last + 1].heightPx <= bodyRoom - MoreLinePx:
      inc last
      used += blocks[last].heightPx
  var bodyPx = 4
  for i in 0 .. last: bodyPx += blocks[i].heightPx
  if moreBelow: bodyPx += MoreLinePx
  let sheet = r.box(column = true, pairs = [
    ("position", "absolute"), ("top", $SheetTopPx & "px"),
    ("left", $((widthPx - sheetW) div 2) & "px"), ("width", $sheetW & "px"),
    ("height", $(topPx + bodyPx) & "px"), ("background", p.ground),
    ("border-width", "1px"), ("border-color", p.borderPrimary),
    ("rounded", $SheetRadiusPx & "px"), ("overflow", "hidden")])
  r.tag(sheet, "sheet", $vm.kind)
  r.tag(sheet, "hidden-below", $(blocks.high - last))
  let headInk = case vm.headerRole
                of "body": p.textBody
                of "error": p.textError
                else: p.textCaption
  let head = r.text(header, CaptionPx, headInk,
                    shrink = false, pairs = [("white-space", "pre-wrap"), ("line-height", "16px"),
                                             ("min-width", "0px"), ("flex-shrink", "1")])
  let headBox = r.box(column = true)
  r.appendChild(headBox, head)
  r.styles(headBox, [("padding-left", $PadPx & "px"), ("padding-right", $PadPx & "px"),
                     ("padding-top", "8px"), ("padding-bottom", "6px"),
                     ("height", $topPx & "px"), ("flex-shrink", "0")])
  r.tag(headBox, "header", header)
  r.appendChild(sheet, headBox)
  let body = r.box(column = true, pairs = [("height", $bodyPx & "px"), ("flex-shrink", "0"),
                                           ("overflow", "hidden"), ("padding-bottom", "4px")])
  for i in 0 .. last: r.appendChild(body, blocks[i].el)
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
  r.appendChild(host, sheet)

proc mountResults*(r: GpuiRenderer; host: GpuiElement; vm: ResultCommandsVM;
                   p: AhPalette; widthPx, heightPx: int; press: ResultsPress = nil) =
  ## Draws the results, and again whenever what they show moves.
  createRenderEffect proc() =
    discard vm.revision.val
    discard vm.selected.val
    discard vm.alone.val
    discard vm.htmlEnabled.val
    drawResults(r, host, vm, p, widthPx, heightPx, press)
