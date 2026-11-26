## gpui/agent_harbor/ah_changes_inbox_parts.nim — CTF-P3. The parts the GPUI
## views of the Changes panel (`ah_changes_panel.nim`) and the Inbox
## (`ah_inbox_panel.nim`) are both drawn with.
##
## The web views draw these parts with the classes of
## `styles/components/agent_harbor_changes.styl` (the state roles, the state
## word, the chips, the text fields, the selects, the group heads, a diff's
## hunks) and the shared button classes (`button.styl`
## `ct-button-sm-primary`, `-secondary`). Each helper here draws one of them
## at the stylesheet's sizes, in pixels against its 16px root, with the
## colours resolved from the same roles
## (`viewmodel/views/agent_harbor_changes_inbox_palette.nim`).
##
## The words are never decided here: every helper takes the text it draws
## from its caller, which takes it from the viewmodels or from
## `viewmodel/views/agent_harbor_changes_inbox_words.nim`.
##
## Every part a reader of the render plan looks for carries its
## `data-ah-*` fact (`ah_theme.tag`), and every fact that names a text names
## the text the element draws.
##
## **Presses are routed** (Input-Routing-And-Keymaps.md §5.1). A pressable
## part carries its operation (`data-ct-operation`, the words module's
## `changes.*` / `inbox.*` press operations) and the procedure that performs
## it on that part (`pressable`). Its press-down listener only reports the
## press to the panel's route (`PanelPress`), which resolves it through the
## host's router over the pointer keymap — a user's row for the press first,
## else the operation the part carries — and runs the part's procedure, or
## the other operation a user's row named. The views hold no press handler.

import ../../../common/pointer_shape
import ../../../common/key_names
import std/[math, strutils]

import nim_agents_isonim_viewmodels/agent_harbor/changes_vm
from ../../viewmodel/views/agent_harbor_changes_code import vcsHunkRow, hunkHeader,
  lineMarker, VCSDiffLineRow, diffLineText
from ../../viewmodel/views/agent_harbor_changes_inbox_words import NoHunksText
import ../../viewmodel/views/agent_harbor_changes_inbox_palette
import ../../viewmodel/input/element_press
import ../../viewmodel/keymap/[base_keymaps, context_keys, editing_keymap, keymap_router,
                               scope_path, user_keymap]
import ../chrome
import ./ah_theme
from ./ah_session_activity import wrappedRows

export ah_theme, agent_harbor_changes_inbox_palette

const
  LabelPx* = 12            ## type-ui-size-label-md
  CaptionSmPx* = 10        ## type-ui-size-caption-sm
  BodyLinePx* = 24         ## type-ui-lineheight-body-md
  ShortLinePx* = 16        ## type-ui-lineheight-body-sm / -caption-md / -label-md
  StateDotPx* = 7          ## AH_STATE_DOT, 0.4375rem
  ItemMarkPx* = 8          ## AH_ITEM_MARK, 0.5rem
  ChipPx* = 18             ## `.ah-chip`: 1.125rem high
  ButtonPadPx* = 7.5       ## `[class*="ct-button-sm-"]`: 0 0.625em at 12px
  ButtonRadiusPx* = 6      ## `button`: 0.5em at 12px
  SelectPadPx* = 6         ## `.ah-changes-select`: 0 0.375rem
  SelectGapPx* = 4         ## `.ah-dropdown-trigger`: 0.25rem between the value and its arrow
  DropdownArrow* = "\xE2\x96\xBE"
    ## ▾ after a dropdown's value (`agent_harbor_dropdown_view.DropdownArrow`).
  CheckboxPx* = 16         ## `.ct-checkmark`: the design system's 16px checkbox
  CheckboxRadiusPx* = 4    ## its corners at 16px
  CheckGlyph* = "\xE2\x9C\x93"
    ## ✓ the checkbox's mark (the design system's check path, drawn as a
    ## glyph: a GPUI window draws no SVG mask).
  TogglePadPx* = 8         ## `.ah-composer-toggle`: 0 0.5rem
  TextFieldRowsPx* = 62    ## a three-row `.ah-text-field`: 3 × 16 + 2 × 6 + 2 × 1
  MonoAdvance* = 0.612
    ## Space Mono Regular's advance, a fixed 0.612em per character: 612 of
    ## its 1000 units per em for every glyph that advances (`hmtx`, read
    ## from the design system's
    ## `SpaceGrotesk_Complete/Fonts/Space_Mono/SpaceMono-Regular.ttf`;
    ## https://fonts.google.com/specimen/Space+Mono, a monospaced face).
    ## It was 0.6, which under-measured a line by 0.168px a character at
    ## 14px: a 61-character line of program text cut to fit before its
    ## location drew 10px past where it was measured to end, and ran into
    ## the location.
  MonoBoldAdvance* = 0.612
    ## Space Mono Bold's advance: also 612 units per em
    ## (`SpaceMono-Bold.ttf`), so a bold run (the query's match in a line of
    ## program text) sets exactly as wide as the regular one.

type
  PanelPress* = proc(operation: string; run: proc()) {.closure.}
    ## A panel's route for a press on one of its parts: the part carries
    ## `operation`, and `run` is the procedure that performs it there.

var drawingPress: PanelPress
  ## The route of the panel being drawn (`drawingWith`), which `pressable`
  ## hands to the listeners it adds. Drawing is synchronous, so each draw's
  ## parts take their own panel's route.

proc panelPresses*(scope: string; keymap = UserKeymap();
                   other: proc(operation: string): bool = nil): PanelPress =
  ## **THE ROUTE FOR A PRESS ON A PANEL IN `scope`** (`ChangesPanelScope`,
  ## `InboxPanelScope`): resolved by GPUI's router — the base keymap with
  ## `keymap`'s rows over it — at the panel's scope; a press that resolves to
  ## the operation the part carries runs the part's procedure, one a user's
  ## row resolves to another operation runs that through `other` (the
  ## panel's key operations, `runChangesOperation` / `runInboxOperation`),
  ## and one that resolves to nothing (a `-` row) runs nothing.
  let router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feGpui, platform: hostPlatform(),
                                                   keyProtocol: kpNative), user = keymap)
  let resolve = routerResolver(router, SessionFacts())
  let path = @[element(ekWindow, "window"), pane(scope)]
  result = proc(operation: string; run: proc()) =
    let outcome = resolveElementPress(resolve, path, ButtonElementKind, operation, {},
                                      "Click")
    if outcome.operation.len == 0: return
    if outcome.operation == operation: run()
    elif other != nil: discard other(outcome.operation)

template drawingWith*(press: PanelPress; body: untyped) =
  ## Draws `body` with `press` as its parts' route.
  let outerPress = drawingPress
  drawingPress = press
  try:
    body
  finally:
    drawingPress = outerPress

proc pressable*(r: GpuiRenderer; el: GpuiElement; operation: string; run: proc()) =
  ## `el` carries `operation` and `run` performs it there. Its press-down
  ## listener is the hit test (GPUI delivers a press to the element under
  ## it): it reports the press to the route of the panel being drawn, which
  ## decides what the press runs. Without a route or a procedure, the part
  ## takes no press.
  if run.isNil: return
  r.setAttribute(el, OperationAttribute, operation)
  let route = drawingPress
  if route.isNil: return
  r.addEventListener(el, "mousedown", proc(ev: GpuiEvent) =  # ir1-gate: hit test
    route(operation, run))

proc taggedButtons(el: GpuiElement; into: var seq[GpuiElement]) =
  ## Every element under `el` (itself included) carrying `data-ah-button`.
  if getAttribute(el, "data-ah-button").len > 0: into.add el
  for i in 0 ..< childCount(el): taggedButtons(nthChild(el, i), into)

proc routedErrorBlock*(r: GpuiRenderer; p: AhPalette; title, message, operation: string;
                       retry: proc()): GpuiElement =
  ## The panels' load failure (`ah_theme.errorBlock`), its Retry carrying
  ## `operation`, performed by `retry` (`pressable`).
  result = r.errorBlock(p, title, message, nil)
  var buttons: seq[GpuiElement]
  taggedButtons(result, buttons)
  for b in buttons: r.pressable(b, operation, retry)

proc charCount(s: string): int =
  ## The characters of `s` (UTF-8 continuation bytes not counted).
  for c in s:
    if (ord(c) and 0xC0) != 0x80: inc result

proc monoTextPx*(text: string; sizePx: int; bold = false): int =
  ## How wide Space Mono sets `text` at `sizePx`: one advance per character,
  ## the Bold face's when `bold`.
  int(ceil(float(text.charCount) * float(sizePx) *
           (if bold: MonoBoldAdvance else: MonoAdvance)))

proc mono*(r: GpuiRenderer; el: GpuiElement): GpuiElement =
  ## `el` set in Space Mono (`.ah-mono`). Returns `el`.
  r.setStyle(el, "font-family", MonoFontFamily)
  el

proc wrapping*(r: GpuiRenderer; s: string; sizePx, linePx: int; colour: string;
               bold = false): GpuiElement =
  ## Prose that wraps at its box's width (`white-space: pre-wrap;
  ## word-break: break-word`), on `linePx` lines.
  r.text(s, sizePx, colour, bold = bold, shrink = false,
         pairs = [("white-space", "normal"), ("line-height", $linePx & "px"),
                  ("flex-shrink", "1"), ("min-width", "0px")])

proc stateWord*(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks;
                text, role: string; pushEnd = true; maxPx = 0): GpuiElement =
  ## A state word with a dot in its colour (`.ah-state-word`): the 7px dot,
  ## 5px, the word at the caption size on a 16px line in the role's text
  ## colour; pushed to its line's end (`margin-left: auto`) unless told not.
  ## At most `maxPx` wide when given (`max-width: 100%` of its line), the
  ## word cut with "…" beyond it.
  result = r.box(pairs = [("gap", "5px"), ("items", "center"), ("flex-shrink", "0"),
                          ("height", $ShortLinePx & "px"), ("min-width", "0px")])
  if maxPx > 0: r.setStyle(result, "max-width", $maxPx & "px")
  if pushEnd: r.setStyle(result, "margin-left", "auto")
  r.tag(result, "state-word", text)
  r.tag(result, "role", role)
  r.appendChild(result, r.mark(p.roleDot(role), StateDotPx))
  let ink = p.roleInk(ink, role)
  let words = r.text(text, CaptionPx, ink, pairs = [("line-height", $ShortLinePx & "px")])
  r.tag(words, "ink", ink)
  r.appendChild(result, words)

proc stateWordPx*(text: string): int =
  ## A state word's width: its dot, the gap, its text.
  StateDotPx + 5 + textPx(text, CaptionPx)

proc chip*(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks;
           text, role, kind: string): GpuiElement =
  ## A chip (`.ah-chip`): the word on the raised ground, 18px high, 6px in,
  ## rounded 4px, at the caption size in its role's colour.
  result = r.box(pairs = [("height", $ChipPx & "px"), ("items", "center"),
                          ("padding-left", "6px"), ("padding-right", "6px"),
                          ("rounded", "4px"), ("background", p.secondary),
                          ("flex-shrink", "0")])
  r.tag(result, "chip", kind)
  r.tag(result, "chip-text", text)
  r.appendChild(result, r.text(text, CaptionPx, p.roleInk(ink, role), shrink = false))

proc chipPx*(text: string): int = textPx(text, CaptionPx) + 12

proc actionButton*(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; label: string;
                   primary: bool; operation: string; onClick: proc();
                   disabled = false): GpuiElement =
  ## A form's button at the label size (`ct-button-sm-primary` / `-secondary`
  ## with `.ah-card-action`): 24px high, 7.5px in, rounded 6px; the primary
  ## filled in the action role with its text on it, the secondary outlined
  ## in a half-pixel primary border on the ground, its text body-subtle. A
  ## disabled one keeps its shape, its text in the disabled colour (on the
  ## action fill, the on-action text at half strength) and does nothing. An
  ## enabled one carries `operation`, performed by `onClick` (`pressable`).
  let pad = formatFloat(ButtonPadPx, ffDecimal, 1) & "px"
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("justify", "center"), ("padding-left", pad),
                          ("padding-right", pad), ("flex-shrink", "0"),
                          ("rounded", $ButtonRadiusPx & "px"),
                          ("cursor", cursorOf(if disabled: hkNone else: hkControl))])
  let fg =
    if primary:
      r.setStyle(result, "background", p.action)
      if disabled: p.onAction & "80" else: p.onAction
    else:
      r.styles(result, [("background", p.ground), ("border-width", "0.5px"),
                        ("border-color", if disabled: ink.borderDisabled else: p.borderPrimary)])
      if disabled: p.textDisabled else: p.textBodySubtle
  r.appendChild(result, r.text(label, LabelPx, fg, shrink = false))
  r.tag(result, "button", label)
  r.tag(result, "primary", $primary)
  r.tag(result, "disabled", $disabled)
  if not disabled: r.pressable(result, operation, onClick)

proc actionButtonPx*(label: string): int =
  int(ceil(2 * ButtonPadPx)) + textPx(label, LabelPx)

proc selectBoxPx*(shownPx: int): int =
  ## A closed dropdown's width for the text width of the value it shows:
  ## its 1px border and 6px padding each side, the value, the gap, the arrow.
  shownPx + 2 * SelectPadPx + 2 + SelectGapPx + textPx(DropdownArrow, LabelPx)

proc selectBox*(r: GpuiRenderer; p: AhPalette; shown: string; choices: seq[string];
                fact: string): GpuiElement =
  ## The design system's dropdown, closed (`agent_harbor_dropdown_view`,
  ## `.ah-dropdown-trigger.ah-changes-select`): 24px high, 6px in, a 1px
  ## border in the control border role, rounded 6px, on the secondary
  ## surface, the value it shows at the label size, whole, then the arrow.
  ## It is as wide as that value (the trigger is a button sized by its
  ## content), and where its row is narrower it shrinks and cuts the value
  ## with "…" rather than run past the row's edge. A GPUI window draws no
  ## dropped menu, so the dropdown draws its closed state, which is what
  ## every story shows; `choices` are the menu's rows, named for a reader.
  let shownPx = textPx(shown, LabelPx)
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("gap", $SelectGapPx & "px"),
                          ("padding-left", $SelectPadPx & "px"),
                          ("padding-right", $SelectPadPx & "px"),
                          ("border-width", "1px"), ("border-color", p.borderSecondary),
                          ("rounded", $ControlRadiusPx & "px"),
                          ("background", p.secondary), ("flex-shrink", "1"),
                          ("min-width", "0px"),
                          ("max-width", $selectBoxPx(shownPx) & "px"),
                          ("cursor", cursorOf(hkControl))])
  r.tag(result, fact, shown)
  r.tag(result, "select-width", $selectBoxPx(shownPx))
  r.tag(result, "menu-choices", $choices.len)
  let value = r.text(shown, LabelPx, p.textLabel, pairs = [("min-width", "0px")])
  r.tag(value, "select-value", shown)
  r.appendChild(result, value)
  r.appendChild(result, r.text(DropdownArrow, LabelPx, p.textLabel, shrink = false))

proc checkbox*(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks;
               checked, disabled: bool): GpuiElement =
  ## The design system's checkbox (`.ct-checkmark`, `checkmark.styl`): 16px,
  ## rounded 4px, a 1px border in border/primary inside it, filled
  ## surface/primary/default; checked, its check in icon/primary/default;
  ## disabled, the disabled fill with no border and the mark dimmed.
  result = r.box(pairs = [("width", $CheckboxPx & "px"), ("height", $CheckboxPx & "px"),
                          ("rounded", $CheckboxRadiusPx & "px"),
                          ("items", "center"), ("justify", "center"),
                          ("background", if disabled: ink.disabledSurface else: p.ground),
                          ("flex-shrink", "0")])
  if not disabled: r.styles(result, [("border-width", "1px"), ("border-color", p.borderPrimary)])
  r.tag(result, "control", "checkbox")
  if checked:
    r.appendChild(result, r.text(CheckGlyph, LabelPx,
                                 if disabled: p.textDisabled else: p.iconDefault,
                                 shrink = false, pairs = [("line-height", $CheckboxPx & "px")]))

proc toggleChip*(r: GpuiRenderer; p: AhPalette; label: string; on, disabled: bool): GpuiElement =
  ## One option of a single choice: the omnibox composer's toggle
  ## (`.ah-composer-toggle`, the VCS panel's mode toggles): 24px high, 8px
  ## in, a 1px border (the action border when chosen, the secondary
  ## otherwise), rounded 6px on no ground of its own, its label at the label
  ## size in the body colour when chosen, the label colour otherwise.
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("padding-left", $TogglePadPx & "px"),
                          ("padding-right", $TogglePadPx & "px"),
                          ("border-width", "1px"),
                          ("border-color", if on: p.borderAction else: p.borderSecondary),
                          ("rounded", $ControlRadiusPx & "px"), ("flex-shrink", "0"),
                          ("cursor", cursorOf(if disabled: hkNone else: hkControl))])
  r.tag(result, "control", "toggle")
  let words = r.text(label, LabelPx, if disabled: p.textDisabled
                                     elif on: p.textBody else: p.textLabel, shrink = false)
  r.tag(words, "choice-label", label)
  r.appendChild(result, words)

proc toggleChipPx*(label: string): int = textPx(label, LabelPx) + 2 * TogglePadPx + 2

proc textField*(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; typed,
                placeholder: string; disabled: bool; rows = 3): GpuiElement =
  ## A form's text field (`.ah-text-field`): the whole width, 6px by 8px in,
  ## a 1px border in the control border role, rounded 6px, on the input
  ## surface (disabled: the disabled surface and border), the typed text at
  ## the body size on 16px lines, or the placeholder in the subtle label
  ## colour. Three rows high, as its `textarea` is.
  let height = rows * ShortLinePx + 14
  result = r.box(column = true, pairs = [("height", $height & "px"),
                                         ("padding-top", "6px"), ("padding-bottom", "6px"),
                                         ("padding-left", "8px"), ("padding-right", "8px"),
                                         ("border-width", "1px"),
                                         ("border-color", if disabled: ink.borderDisabled
                                                          else: p.borderSecondary),
                                         ("rounded", "6px"), ("flex-shrink", "0"),
                                         ("background", if disabled: ink.disabledSurface
                                                        else: ink.inputSurface)])
  r.tag(result, "input", if typed.len > 0: typed else: placeholder)
  r.tag(result, "typed", $(typed.len > 0))
  let colour = if disabled: p.textDisabled
               elif typed.len > 0: p.textBody else: ink.placeholder
  r.appendChild(result, r.wrapping(if typed.len > 0: typed else: placeholder, BodyPx,
                                   ShortLinePx, colour))

proc groupHead*(r: GpuiRenderer; p: AhPalette; name: string; count: int;
                fact = "changes-group"): GpuiElement =
  ## A group's head (`.ah-changes-group-head`, the progress panel's status
  ## head): 6px above and 4px below, 8px in, the name in uppercase at the
  ## label size, semibold and spaced, in the label colour, its count 6px
  ## after it in the caption colour, on the panel's 24px line, over a
  ## hairline: 35px in all.
  result = r.box(pairs = [("items", "center"), ("padding-top", "6px"),
                          ("padding-bottom", "4px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                          ("height", "35px"), ("min-width", "0px")])
  r.rule(result, p.borderSecondary)
  r.tag(result, fact, name)
  r.tag(result, "group-head", "true")
  let n = r.tracked(r.text(name.toUpperAscii, LabelPx, p.textLabel, bold = true,
                           pairs = [("line-height", $ShortLinePx & "px")]))
  r.appendChild(result, n)
  r.appendChild(result, r.text("(" & $count & ")", LabelPx, p.textCaption, shrink = false,
                               pairs = [("margin-left", "6px"),
                                        ("line-height", $ShortLinePx & "px")]))

proc sectionLabel*(r: GpuiRenderer; p: AhPalette; name: string): GpuiElement =
  ## A small-caps label (`.ah-card-meta-label`, `.ah-item-section-name`,
  ## `.ah-details-label`): uppercase at the label size, semibold, spaced, in
  ## the label colour.
  r.tracked(r.text(name.toUpperAscii, LabelPx, p.textLabel, bold = true, shrink = false,
                   pairs = [("line-height", $ShortLinePx & "px")]))

proc hunks*(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks;
            hunks: seq[DiffHunk]): GpuiElement =
  ## A diff's hunks (`.ah-hunks`) in Space Mono at the caption size on 16px
  ## lines: each hunk's header (`@@ -a,b +c,d @@` and git's section) in the
  ## information colour, 2px above and below, then each line with its
  ## marker, added lines green, removed red, unchanged in the label colour.
  ## The lines go through the VCS panel's hunk value
  ## (`agent_harbor_changes_code.vcsHunkRow`), as the web view's do.
  result = r.box(column = true, pairs = [("min-width", "0px"), ("overflow", "hidden"),
                                         ("flex-shrink", "0")])
  var count = 0
  if hunks.len == 0:
    r.appendChild(result, r.text(NoHunksText, CaptionPx, p.textCaption,
                                 pairs = [("line-height", $ShortLinePx & "px")]))
  for hunk in hunks:
    let row = vcsHunkRow(hunk)
    let header = hunkHeader(row) & (if hunk.section.len > 0: " " & hunk.section else: "")
    let head = r.mono(r.text(header, CaptionPx, ink.textInfo, shrink = false,
                             pairs = [("line-height", $ShortLinePx & "px"),
                                      ("padding-top", "2px"), ("padding-bottom", "2px")]))
    r.tag(head, "hunk-head", header)
    r.appendChild(result, head)
    for line in row.lines:
      let colour = case line.lineType
        of "added": p.textSuccess
        of "removed": p.textError
        else: p.textLabel
      let l = r.box(pairs = [("height", $ShortLinePx & "px"), ("flex-shrink", "0")])
      r.tag(l, "hunk-line", line.lineType)
      r.appendChild(l, r.mono(r.text(lineMarker(line), CaptionPx, colour, shrink = false,
                                     pairs = [("width", $monoTextPx("x", CaptionPx) & "px"),
                                              ("line-height", $ShortLinePx & "px")])))
      r.appendChild(l, r.mono(r.text(diffLineText(line), CaptionPx, colour, shrink = false,
                                     pairs = [("line-height", $ShortLinePx & "px")])))
      r.appendChild(result, l)
      inc count
  r.tag(result, "hunks", $count)

const FlowHeightAttribute = "data-flow-height"
  ## On an item of `flowLinesFit`: its height on its line, in pixels.

proc flowLinesFit*(r: GpuiRenderer; items: seq[FlowItem]; heights: seq[int];
                   availPx, gapPx, rowGapPx: int): GpuiElement =
  ## A row that wraps as the web's `flex-wrap: wrap; align-items: center` row
  ## does (`ah_theme.flowLines` packs the lines), each line as high as its
  ## tallest item: `heights[i]` is item `i`'s height (a 16px caption line, an
  ## 18px chip, a 24px control or a text on the panel's own 24px line).
  ## Each item carries its height as an attribute while the lines are
  ## packed, because the tree hands back a fresh handle for a node, so the
  ## lines' children are read back by what they carry, not by identity.
  var tallest = 0
  for k, item in items:
    tallest = max(tallest, heights[k])
    r.setAttribute(item.el, FlowHeightAttribute, $heights[k])
  result = r.flowLines(items, availPx, gapPx, tallest, rowGapPx)
  for i in 0 ..< childCount(result):
    let line = nthChild(result, i)
    var lineHeight = 0
    for j in 0 ..< childCount(line):
      let h = getAttribute(nthChild(line, j), FlowHeightAttribute)
      if h.len > 0: lineHeight = max(lineHeight, parseInt(h))
    if lineHeight > 0: r.setStyle(line, "height", $lineHeight & "px")

proc flowFitHeightPx*(items: seq[FlowItem]; heights: seq[int]; availPx, gapPx,
                      rowGapPx: int): int =
  ## The height `flowLinesFit` gives the same items: each line as high as its
  ## tallest item, `rowGapPx` between lines. Measured from the same widths,
  ## so a view that scrolls by hand (`scrollWindow`) lays it out as drawn.
  if items.len == 0: return 0
  let starts = flowLineStarts(items, availPx, gapPx)
  var line = 0
  for k in 0 ..< items.len:
    if k > 0 and starts[k]:
      result += line + rowGapPx
      line = 0
    line = max(line, heights[k])
  result += line

proc textRows*(text: string; sizePx, availPx: int): int =
  ## How many lines wrapping prose takes at `availPx` (0 for no text), at
  ## the face's kerned widths, as the window wraps it.
  if text.len == 0: 0 else: wrappedRows(text, sizePx, max(1, availPx), faceGlyphs = true)

proc fillWidth*(r: GpuiRenderer; el: GpuiElement) =
  ## `el` takes the free width of its row and may shrink below its content.
  r.styles(el, [("flex-grow", "1"), ("flex-shrink", "1"), ("min-width", "0px")])

# ---------------------------------------------------------------------------
# Scrolling by hand
# ---------------------------------------------------------------------------
#
# GPUI's layout does not scroll a box or measure an overflow, so a P3 region
# that holds more than it shows is scrolled the way the shim's own test
# scrolls a list (isonim-gpui `rust/gpui-nim-shim/tests/scrolled_rows_take_clicks.rs`)
# and the omnibox composer scrolls its sheet (`ah_composer.drawComposer`):
# its parts are laid out here at the heights the stylesheet gives them, the
# column that holds them is pulled up by the region's first pixel shown
# (`margin-top`) under a box that clips at the region's foot. The host keeps
# each region's first pixel between draws (`P3Scroll`, as the terminal's
# `AhP3State` keeps its first row); what the keyboard is on (the keyboard's
# card or file, the item on screen) is brought into view when it changes:
# the least move that shows its top, or, for the item on screen, to the
# region's top, as the web's `keepKeyboardItemInView` and the terminal's
# `drawScrolled` do.

type
  ScrollPart* = object
    ## One part of a scrolling region, in order: its element, its height as
    ## laid out, and the fact value that names it as what the keyboard is on
    ## ("" for none).
    el*: GpuiElement
    heightPx*: int
    key*: string

  P3Scroll* = ref object
    ## What a GPUI host keeps between draws of a Changes or Inbox story that
    ## no viewmodel holds: each region's first pixel shown and the item kept
    ## in view at its last draw, and each region as last drawn.
    tops: seq[(string, int)]
    seen: seq[(string, string)]
    regions*: seq[P3ScrollRegion]

  P3ScrollRegion* = object
    ## A region as last drawn: its key, how tall it shows and holds, its
    ## first pixel shown.
    key*: string
    viewPx*, contentPx*, topPx*: int

proc topOf(s: P3Scroll; key: string): int =
  if s.isNil: return 0
  for (k, v) in s.tops:
    if k == key: return v

proc setTop(s: P3Scroll; key: string; top: int) =
  if s.isNil: return
  for i in 0 ..< s.tops.len:
    if s.tops[i][0] == key:
      s.tops[i][1] = top
      return
  s.tops.add (key, top)

proc beginDraw*(s: P3Scroll) =
  ## A draw starts: no region drawn yet.
  if not s.isNil: s.regions.setLen(0)

proc regionOf*(s: P3Scroll; key: string): P3ScrollRegion =
  if s.isNil: return
  for r in s.regions:
    if r.key == key: return r

proc scrollBy*(s: P3Scroll; key: string; deltaPx: int): bool =
  ## Moves region `key`'s window `deltaPx` (negative: up), within its content
  ## as the last draw laid it out; true when it moved. The host redraws.
  let r = s.regionOf(key)
  if r.key.len == 0: return false
  let top = clamp(r.topPx + deltaPx, 0, max(0, r.contentPx - r.viewPx))
  if top == r.topPx: return false
  s.setTop(key, top)
  true

proc pagePxOf*(s: P3Scroll; key: string): int =
  ## A page of region `key`: its height less a line kept for context (the
  ## panel's 24px line), as the terminal keeps a row.
  max(1, s.regionOf(key).viewPx - BodyLinePx)

proc keptTop*(top, viewPx, contentPx, at, heightPx: int; keepAtTop: bool): int =
  ## The region's first pixel once the part at `at` (`heightPx` high) is in
  ## view: unchanged when it already is; else the least move that shows its
  ## top (the whole of it when it fits), or, with `keepAtTop`, its top at
  ## the region's top. Kept within the content.
  result = top
  let bottom = at + heightPx
  let outside = at < top or bottom > top + viewPx
  if keepAtTop and outside: result = at
  elif at < top: result = at
  elif bottom > top + viewPx: result = top + min(bottom - (top + viewPx), at - top)
  result = clamp(result, 0, max(0, contentPx - viewPx))

proc scrollWindow*(r: GpuiRenderer; s: P3Scroll; key: string; parts: seq[ScrollPart];
                   viewPx: int; keepKey: string; keepAtTop = false;
                   groupCount = 0; groupFact = ""; groupValue = ""): GpuiElement =
  ## Region `key`, `viewPx` high: `parts` in a column pulled up by the
  ## region's first pixel shown, clipped at its foot. The first pixel is the
  ## host's (`s`; 0 without one), kept within the content and moved to show
  ## the part named `keepKey` when that changed since the last draw
  ## (`keptTop`). Each part carries where it lies in the content
  ## (`scroll-y`, `scroll-h`) and its name (`scroll-key`), and the region what
  ## it shows (`scroll-region`, `scroll-top`, `scroll-view`,
  ## `scroll-content`), so a reader of the drawing can tell what is in view.
  ## The first `groupCount` parts are held in a box of their own tagged
  ## `groupFact` = `groupValue` (the web's list element inside its scrolling
  ## region: the inbox's rows above the page under them).
  var content = 0
  var starts: seq[int]
  for part in parts:
    starts.add content
    content += part.heightPx
  var top = clamp(s.topOf(key), 0, max(0, content - viewPx))
  var last = ""
  var known = false
  if not s.isNil:
    for (k, v) in s.seen:
      if k == key:
        last = v
        known = true
  if keepKey.len > 0 and (not known or keepKey != last):
    for i, part in parts:
      if part.key == keepKey:
        top = keptTop(top, viewPx, content, starts[i], part.heightPx, keepAtTop)
        break
  if not s.isNil:
    var found = false
    for i in 0 ..< s.seen.len:
      if s.seen[i][0] == key:
        s.seen[i][1] = keepKey
        found = true
    if not found: s.seen.add (key, keepKey)
    s.setTop(key, top)
    s.regions.add P3ScrollRegion(key: key, viewPx: viewPx, contentPx: content, topPx: top)
  result = r.box(column = true, pairs = [("height", $viewPx & "px"), ("flex-shrink", "0"),
                                         ("min-height", "0px"), ("overflow", "hidden")])
  r.tag(result, "scroll-region", key)
  r.tag(result, "scroll-top", $top)
  r.tag(result, "scroll-view", $viewPx)
  r.tag(result, "scroll-content", $content)
  let column = r.box(column = true, pairs = [("flex-shrink", "0"), ("min-width", "0px")])
  if top != 0: r.setStyle(column, "margin-top", $(-top) & "px")
  var group: GpuiElement = nil
  if groupCount > 0:
    group = r.box(column = true, pairs = [("flex-shrink", "0"), ("min-width", "0px")])
    if groupFact.len > 0: r.tag(group, groupFact, groupValue)
    r.appendChild(column, group)
  for i, part in parts:
    r.setAttribute(part.el, "data-ah-scroll-y", $starts[i])
    r.setAttribute(part.el, "data-ah-scroll-h", $part.heightPx)
    if part.key.len > 0: r.setAttribute(part.el, "data-ah-scroll-key", part.key)
    r.appendChild(if i < groupCount: group else: column, part.el)
  r.appendChild(result, column)
