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
## (`tui/agent_harbor/ah_tui_results.nim`), except a row's selection, which
## is `result-selected` here (see `rowBlock`).

import std/strutils
import nim_agents_isonim_viewmodels/agent_harbor/result_commands_vm
import ../../viewmodel/views/agent_harbor_results_words
from ../../viewmodel/views/cut_text_rules import cutAroundMatch
import ./ah_theme
import ./ah_composer
from ./ah_session_activity import wrappedRows, wrappedLines
from ./ah_changes_inbox_parts import mono, monoTextPx
from ../../viewmodel/input/element_press import OperationAttribute

export result_commands_vm, agent_harbor_results_words, ah_theme

type
  Block = object
    heightPx: int
    el: GpuiElement
    tailPx: int
      ## The part of `heightPx` at its foot that shows nothing (a row's
      ## bottom padding and the leading under its last line's glyphs): it may
      ## stand under `More below ↓` when the body is full, as the web's rows
      ## scroll under that sticky line.

const
  # The sheet's lines are the composer's (`LinePx`, 24px): every part of
  # the results inherits the sheet's line-height, at the body size and at the
  # caption size alike, except a row's second line and the header, which
  # set the caption's own 16px (`agent_harbor_results.styl`).
  RowPadPx = 5         ## a row's padding above and below (0.3125rem)
  SecondLinePx = 16    ## a row's second line (`.ah-results-second`)
  SecondGapPx = 2      ## above a row's second line (margin-top: 0.125rem)
  UnderGapPx = 2       ## between a narrow row's title and the line under it
  GroupTopPx = 4       ## the first group's padding-top (0.25rem)
  GroupHeadPadPx = 4   ## under a group's head (padding-bottom: 0.25rem)
  GroupGapPx = 4 + 1 + 8
    ## Between groups: 0.25rem, the hairline, 0.5rem (`& + .ah-results-group`).
  MoreLinePx = 1 + 4 + LinePx + 4
    ## `More below ↓`: the composer's (its hairline, a line padded 0.25rem).
  BodyRoleLinePx = 20
    ## The body role's own line (`type-ui-lineheight-body-md`): the 14px
    ## title's glyphs stand within it, centred on the row's longer line.
  EndPx = 8
    ## The body's last part's bottom margin: a group's, the notice's and the
    ## empty providers' line's 0.5rem.
  RowGapPx* = 8
    ## Between a row's parts (`.ah-results-row-line`'s `gap: 0.5rem`).
  CodeMarginPx* = 8
    ## A line of program text's own `margin-right: 0.5rem`
    ## (`.ah-results-title-code`), kept at its right whatever stands there.
  RowEdgesPx* = 2 + 2
    ## What a row's line is narrower than the sheet less its padding: the
    ## sheet's two hairlines and the row's own 1px margins
    ## (`.ah-results-row`'s `margin: 0 0.0625rem`).
  CodeGapPx* = RowGapPx + CodeMarginPx
    ## Between a line of program text and where it is, 16px: the row's gap
    ## and the code title's margin, which the web keeps whatever the cut
    ## leaves. The drawn line once ran within 5px of `src/shield.nr:11`:
    ## the cut kept this room, but measured the line at 0.6em a character
    ## where Space Mono draws 0.612em (`MonoAdvance`).

proc mixedLinePx(): int = LinePx + 1
  ## A line holding the 14px title beside 12px words (what a row is, where
  ## it is, its tag; the notice's hint): the browser aligns the two sizes'
  ## baselines on the 24px line, and the line box is a pixel taller.

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

proc codeLinePx*(shown, match: string): int =
  ## How wide a line of program text draws: Space Mono at the body size, every
  ## place `match` stands in it (`spansIn`, the runs drawn bold) at the Bold
  ## face's advance and the rest at the Regular's, each run measured as the
  ## text it is drawn as.
  var at = 0
  for (s0, n0) in (if match.len > 0: spansIn(shown, match) else: newSeq[(int, int)]()):
    if s0 > at: result += monoTextPx(shown[at ..< s0], BodyPx)
    result += monoTextPx(shown[s0 ..< s0 + n0], BodyPx, bold = true)
    at = s0 + n0
  if at < shown.len: result += monoTextPx(shown[at .. ^1], BodyPx)

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
  # What stands right of a wide row's line of program text: where it is and
  # its tag, each with the row's gap before it.
  let rightPx0 = if narrow: 0
                 else: min((if row.location.len > 0: textPx(row.location, CaptionPx) + RowGapPx else: 0) +
                           (if tag.len > 0: textPx(tag, CaptionPx) + RowGapPx else: 0), widthPx * 45 div 100)
  # The row's line: the title on the sheet's 24px line, a pixel taller
  # where 12px words share it (`mixedLinePx`); a narrow row's title alone,
  # and what and where it is on a 24px line of their own under it, 2px down.
  let mixed = not narrow and (detail.len > 0 or row.location.len > 0 or tag.len > 0)
  let linePx = if mixed: mixedLinePx() else: LinePx
  let h = 2 * RowPadPx + linePx + (if underTitle: UnderGapPx + LinePx else: 0) +
          (if secondLines > 0: SecondGapPx + SecondLinePx * secondLines else: 0)
  let el = r.box(column = true, pairs = [("justify", "start"), ("margin-left", "1px"),
                                         ("margin-right", "1px"),
                                         ("padding-top", $RowPadPx & "px")])
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
  # Its own fact, not `selected`: the layout record's `selected-row` region
  # is the fleet's and the Initiatives panel's selected row
  # (`agent-harbor-regions.json`, `data-ah-selected`), which the web's result
  # rows never match, so a result row carrying it was "drawn only on gpui".
  r.tag(el, "result-selected", $selected)
  r.tag(el, "kind", $row.kind)
  r.pressable(el, ResultsOpenOperation, $(g.first + index), press)
  let line = r.box(pairs = [("items", "center"), ("gap", $RowGapPx & "px"), ("min-width", "0px"),
                            ("height", $linePx & "px"), ("flex-shrink", "0")])
  if code:
    let (ms, me) = matchedSpan(row, query)
    let mt = if me > ms: row.title[ms ..< me] else: ""
    # Set in the code face (Space Mono, `.ah-results-title-code`), as the
    # editor and the Changes panel set code (brief: "a line of the program's
    # text is set in the code face"), so it is cut by Space Mono's advances,
    # each match in view at the Bold face's (`codeLinePx`).
    let measure = proc(text: string): int = codeLinePx(text, mt)
    # Its room ends `CodeGapPx` before where it is: the row's gap is in
    # `rightPx0`, and the title's own margin is drawn on its box. The line
    # is `RowEdgesPx` narrower than `widthPx`, which the cut once took whole.
    let roomPx = widthPx - RowEdgesPx - rightPx0 - CodeMarginPx
    let shown = cutAroundMatch(row.title, ms, me, max(1, roomPx), measure,
                               monoTextPx(Ellipsis, BodyPx))
    let t = r.box(pairs = [("min-width", "0px"), ("flex-grow", "1"), ("items", "baseline"),
                           ("margin-right", $CodeMarginPx & "px")])
    r.tag(t, "face", "code")
    # Every match in view bold (D62), the rest in the body role.
    var from0 = 0
    for (s0, n0) in spansIn(shown, mt):
      if s0 > from0:
        r.appendChild(t, r.mono(r.text(shown[from0 ..< s0], BodyPx, p.textBody, shrink = false)))
      let m = r.mono(r.text(shown[s0 ..< s0 + n0], BodyPx, p.textBody, bold = true,
                            shrink = false))
      r.tag(m, "match", shown[s0 ..< s0 + n0])
      r.appendChild(t, m)
      from0 = s0 + n0
    if from0 < shown.len:
      r.appendChild(t, r.mono(r.text(shown[from0 .. ^1], BodyPx, p.textBody, shrink = false)))
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
    let u = r.box(pairs = [("gap", "8px"), ("min-width", "0px"), ("items", "center"),
                           ("height", $LinePx & "px"), ("margin-top", $UnderGapPx & "px"),
                           ("flex-shrink", "0")])
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
                            ("margin-top", $SecondGapPx & "px"),
                            ("min-width", "0px"), ("flex-shrink", "1")])
    r.tag(s, "second", second)
    r.appendChild(el, s)
  result = r.padded(el, h)
  # Under its last line's glyphs: the row's padding and that line's leading
  # below its type's own line (none under a second line, set on its type's
  # 16px; 4px under the caption words of a narrow row's 24px line; 2px under
  # a wide row's title, 14px on 20px in a 25px line).
  let lastLead = if secondLines > 0: 0
                 elif underTitle: (LinePx - CaptionLinePx) div 2
                 else: (linePx - BodyRoleLinePx) div 2
  result.tailPx = RowPadPx + lastLead

proc hairlineGap(r: GpuiRenderer; p: AhPalette; abovePx, belowPx: int): Block =
  ## A hairline `abovePx` under the last part and `belowPx` over the next:
  ## between groups (`& + .ah-results-group`), and over the empty providers'
  ## line (`.ah-results-empty`).
  let h = abovePx + 1 + belowPx
  let gap = r.box(column = true, pairs = [("height", $h & "px"), ("flex-shrink", "0"),
                                          ("justify", "start"),
                                          ("padding-top", $abovePx & "px")])
  r.appendChild(gap, r.box(pairs = [("height", "1px"), ("background", p.borderSecondary),
                                    ("flex-shrink", "0")]))
  Block(heightPx: h, el: gap)

proc bodyBlocks(r: GpuiRenderer; p: AhPalette; vm: ResultCommandsVM; widthPx: int;
                narrow: bool; press: ResultsPress): seq[Block] =
  ## The body's parts at the heights the stylesheet gives them, every line
  ## on the sheet's 24px; the last part's bottom margin (`EndPx`) is the
  ## sheet's to add.
  if vm.alone.val.len > 0:
    # `.ah-results-back`: 0.25rem over the line, 0.375rem under it.
    let b = r.box(pairs = [("items", "center"), ("padding-top", "4px"),
                           ("padding-bottom", "6px")])
    let t = r.text(AllProviders, CaptionPx, p.textCaption, shrink = false)
    r.appendChild(b, t)
    r.tag(b, "back", AllProviders)
    r.pressable(b, ResultsAllOperation, "", press)
    result.add r.padded(b, 4 + LinePx + 6)
  let n = vm.notice
  if n.text.len > 0:
    # `.ah-results-notice`: 0.5rem over its lines, 0.75rem under them; its
    # words on the sheet's lines, the hint beside the last line where it
    # fits there (`flex-wrap: wrap`, 0.75rem apart, on one baseline), else
    # on a line of its own.
    # Each line its own one-line text, broken between words only
    # (`wrappedLines`), as the web's line breaks: GPUI's text system, left to
    # wrap the notice itself, split `GET /api/v1/input-commands` after
    # `/api/v1`, where the web carries the whole path to the next line, and
    # drew one line fewer than measured.
    let b = r.box(column = true, pairs = [("padding-top", "8px")])
    let wrapped = wrappedLines(n.text, BodyPx, widthPx)
    let lines = wrapped.len
    let ink = if n.role == "error": p.textError else: p.textBody
    let t = r.box(column = true, pairs = [("min-width", "0px"), ("flex-shrink", "0"),
                                          ("height", $(LinePx * lines) & "px")])
    for line in wrapped:
      r.appendChild(t, r.text(line, BodyPx, ink,
                              pairs = [("height", $LinePx & "px"),
                                       ("line-height", $LinePx & "px"), ("min-width", "0px")]))
    r.tag(b, "notice-line", n.text)
    r.tag(b, "notice-lines", wrapped.join("\n"))
    r.tag(b, "notice-role", n.role)
    r.appendChild(b, t)
    var h = 8 + LinePx * lines + 12
    if n.hint.len > 0:
      let hint = r.text(n.hint, CaptionPx, p.textCaption, shrink = false)
      r.tag(hint, "notice-hint", n.hint)
      r.appendChild(b, hint)
      let besideLast = lines == 1 and
        textPx(n.text, BodyPx) + 12 + textPx(n.hint, CaptionPx) <= widthPx
      h += (if besideLast: mixedLinePx() - LinePx else: LinePx)
    result.add r.padded(b, h)
  let query = vm.queryText
  let groups = vm.groups
  for gi in 0 ..< groups.len:
    let g = groups[gi]
    if gi > 0:
      result.add r.hairlineGap(p, 4, 8)
    let titleText = g.group.title.toUpperAscii
    let state = stateWord(g.group)
    let failed = stateRole(g.group) == "error"
    # A failure's reason that does not fit beside the title wraps on lines
    # of its own under it (the web's and the terminal's rule).
    let beside = textPx(titleText, CaptionPx) + 12 + textPx(state, CaptionPx) <= widthPx
    let head = r.box(column = not beside,
                     pairs = (if beside: @[("items", "center"), ("justify", "between"),
                                           ("gap", "12px")]
                              else: @[("justify", "start")]))
    let title = r.tracked(r.text(titleText, CaptionPx, p.textLabel, bold = true,
                                 pairs = [("line-height", $LinePx & "px")]))
    r.appendChild(head, title)
    let st = if beside or not failed:
               r.text(state, CaptionPx, if failed: p.textError else: p.textCaption,
                      pairs = [("line-height", $LinePx & "px")])
             else:
               r.text(state, CaptionPx, p.textError, shrink = false,
                      pairs = [("white-space", "pre-wrap"), ("line-height", $LinePx & "px"),
                               ("min-width", "0px"), ("flex-shrink", "1")])
    r.appendChild(head, st)
    r.tag(head, "group", g.group.id)
    r.tag(head, "group-state", $g.group.state)
    r.tag(head, "state", state)
    let stateLines = if beside: 0 else: max(1, wrappedRows(state, CaptionPx, widthPx))
    # The first group's 0.25rem over its head (a later one has the gap's);
    # its head's lines, and 0.25rem under them.
    let top = if gi == 0: GroupTopPx else: 0
    if top > 0: r.setStyle(head, "padding-top", $top & "px")
    result.add r.padded(head, top + LinePx * (1 + stateLines) + GroupHeadPadPx)
    for i in 0 ..< g.rows.len:
      result.add r.rowBlock(p, vm, g, i, query, widthPx, narrow, press)
    let more = moreLabel(g)
    if more.len > 0:
      # `.ah-results-more`: a line padded 0.25rem over and under.
      let m = r.box(pairs = [("items", "center")])
      r.appendChild(m, r.text(more, CaptionPx, p.textLabel, shrink = false))
      r.tag(m, "more", more)
      r.pressable(m, ResultsMoreOperation, g.group.id, press)
      result.add r.padded(m, 4 + LinePx + 4)
  # The providers that answered with nothing: one quiet line after the
  # groups, in place of a group each (P2c study D60).
  let empty = emptyProvidersLine(vm)
  if empty.len > 0:
    # `.ah-results-empty`: 0.5rem over its hairline, 0.5rem under it, its
    # lines, 0.25rem.
    result.add r.hairlineGap(p, 8, 8)
    let b = r.box(column = true)
    let lines = max(1, wrappedRows(empty, CaptionPx, widthPx))
    r.appendChild(b, r.text(empty, CaptionPx, p.textCaption, shrink = false,
                            pairs = [("white-space", "pre-wrap"),
                                     ("line-height", $LinePx & "px"),
                                     ("min-width", "0px"), ("flex-shrink", "1")]))
    r.tag(b, "empty-providers", empty)
    result.add r.padded(b, LinePx * lines + 4)

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
  r.tag(clip, "field-clip", "true")
  r.tag(ft, "field", input)
  r.appendChild(clip, ft)
  r.appendChild(field, clip)
  # The field row is what the layout record's `composer-field` region reads
  # (`agent-harbor-regions.json`), the same fact the composer's field carries:
  # without it the omnibox field is "drawn only on web".
  r.tag(field, "field-row", "true")
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
  # Up to the window less the caption bar, its inset and the trigger gap
  # (the composer's `max-height`), its two hairlines included. The body ends
  # with its last part's margin (`EndPx`); a body that holds more than that
  # room scrolls on the web, the sheet at its `max-height` and `More below ↓`
  # on the scrollport's bottom edge: here the parts that fit over that line
  # are drawn, the line at the bottom.
  let maxH = heightPx - CaptionBarPx - SheetInsetPx - DropdownTriggerGapPx
  let bodyRoom = max(16, maxH - 2 - topPx)
  var last = blocks.high
  var moreBelow = false
  var moreRoom, moreNext = 0
  var bodyPx = total + EndPx
  if bodyPx > bodyRoom:
    moreBelow = true
    # A part is drawn when what it shows ends above the line's hairline: a
    # row's bottom padding and its last line's leading may stand under the
    # line, as the web's last row does (its body scrolls under the sticky
    # `More below ↓`; `Block.tailPx`).
    # Held to the whole part, the sidebar's sheet left a row's height empty
    # above the line where the web draws one more row. That last part is drawn as tall as the room
    # over the line leaves it, so the line keeps its place.
    let roomAbove = bodyRoom - MoreLinePx
    var used = 0
    last = -1
    while last + 1 < blocks.len and
          used + blocks[last + 1].heightPx - blocks[last + 1].tailPx <= roomAbove:
      inc last
      used += blocks[last].heightPx
    if last >= 0 and used > roomAbove:
      let b = blocks[last]
      r.styles(b.el, [("height", $(b.heightPx - (used - roomAbove)) & "px"),
                      ("overflow", "hidden")])
    moreRoom = roomAbove - used
    if last + 1 < blocks.len:
      moreNext = blocks[last + 1].heightPx - blocks[last + 1].tailPx
    bodyPx = bodyRoom
  let sheetH = topPx + bodyPx + 2
  let sheet = r.box(column = true, pairs = [
    ("position", "absolute"), ("top", $SheetTopPx & "px"),
    ("left", $((widthPx - sheetW) div 2) & "px"), ("width", $sheetW & "px"),
    ("height", $sheetH & "px"), ("background", p.ground),
    ("border-width", "1px"), ("border-color", p.borderPrimary),
    ("rounded", $SheetRadiusPx & "px"), ("overflow", "hidden")])
  r.tag(sheet, "sheet", $vm.kind)
  r.tag(sheet, "hidden-below", $(blocks.high - last))
  if moreBelow:
    # The ground left above `More below ↓`'s hairline (negative: a row's
    # bottom padding under it), and what the first part not drawn shows.
    r.tag(sheet, "more-room", $moreRoom)
    r.tag(sheet, "more-next", $moreNext)
  # Where the sheet was laid out, for the layout suites (as the composer's).
  r.tag(sheet, "sheet-top", $SheetTopPx)
  r.tag(sheet, "sheet-height", $sheetH)
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
                                           ("overflow", "hidden")])
  for i in 0 .. last: r.appendChild(body, blocks[i].el)
  if moreBelow:
    r.appendChild(body, r.box(pairs = [("flex-grow", "1"), ("min-height", "0px")]))
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
