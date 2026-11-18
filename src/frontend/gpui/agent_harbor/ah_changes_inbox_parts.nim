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

import ../../../common/pointer_shape
import std/[math, strutils]

import nim_agents_isonim_viewmodels/agent_harbor/changes_vm
from ../../viewmodel/views/agent_harbor_changes_code import vcsHunkRow, hunkHeader,
  lineMarker, VCSDiffLineRow, diffLineText
from ../../viewmodel/views/agent_harbor_changes_inbox_words import NoHunksText
import ../../viewmodel/views/agent_harbor_changes_inbox_palette
import ../chrome
import ./ah_theme

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
  SelectInnerPx* = 4
    ## Chromium sets a select's value 4px further in than its padding
    ## (measured: the value at 11px from the box's left edge).
  SelectArrowPx* = 16
    ## The browser's own drop-down arrow beside the value: a select is its
    ## widest choice plus 34px wide (measured at 12px in Chromium:
    ## `Modified` 89px, `Session changes` 132px, a 268px label 302px), its
    ## padding, border and inner inset taking 18 of them.
  TextFieldRowsPx* = 62    ## a three-row `.ah-text-field`: 3 × 16 + 2 × 6 + 2 × 1
  MonoAdvance* = 0.6
    ## Space Mono's advance, a fixed 0.6em per character
    ## (https://fonts.google.com/specimen/Space+Mono, a monospaced face).

proc charCount(s: string): int =
  ## The characters of `s` (UTF-8 continuation bytes not counted).
  for c in s:
    if (ord(c) and 0xC0) != 0x80: inc result

proc monoTextPx*(text: string; sizePx: int): int =
  ## How wide Space Mono sets `text` at `sizePx`: one advance per character.
  int(ceil(float(text.charCount) * float(sizePx) * MonoAdvance))

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
                   primary: bool; onClick: proc(); disabled = false): GpuiElement =
  ## A form's button at the label size (`ct-button-sm-primary` / `-secondary`
  ## with `.ah-card-action`): 24px high, 7.5px in, rounded 6px; the primary
  ## filled in the action role with its text on it, the secondary outlined
  ## in a half-pixel primary border on the ground, its text body-subtle. A
  ## disabled one keeps its shape, its text in the disabled colour (on the
  ## action fill, the on-action text at half strength) and does nothing.
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
  if onClick != nil and not disabled: r.addEventListener(result, "click", onClick)

proc actionButtonPx*(label: string): int =
  int(ceil(2 * ButtonPadPx)) + textPx(label, LabelPx)

proc selectBoxPx*(widestPx: int): int =
  ## A closed select's width for its widest choice's text width.
  widestPx + 2 * SelectPadPx + SelectInnerPx + SelectArrowPx + 2

proc selectBox*(r: GpuiRenderer; p: AhPalette; shown: string; choices: seq[string];
                fact: string): GpuiElement =
  ## A compact select (`.ah-changes-select`): 24px high, 6px in, a 1px
  ## border in the control border role, rounded 6px, on the secondary
  ## surface, the chosen value at the label size and the drop-down arrow at
  ## its end. As the browser sizes a select, it is as wide as its widest
  ## choice. A GPUI window has no native drop-down, so the select draws its
  ## closed state, which is what every story shows.
  var widest = textPx(shown, LabelPx)
  for c in choices: widest = max(widest, textPx(c, LabelPx))
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("padding-left", $(SelectPadPx + SelectInnerPx) & "px"),
                          ("padding-right", $SelectPadPx & "px"),
                          ("border-width", "1px"), ("border-color", p.borderSecondary),
                          ("rounded", $ControlRadiusPx & "px"),
                          ("background", p.secondary), ("flex-shrink", "1"),
                          ("min-width", "0px"),
                          ("width", $selectBoxPx(widest) & "px"),
                          ("cursor", cursorOf(hkControl))])
  r.tag(result, fact, shown)
  let value = r.text(shown, LabelPx, p.textLabel, pairs = [("flex-grow", "1")])
  r.tag(value, "select-value", shown)
  r.appendChild(result, value)
  # The arrow: a chevron in the label colour, as the browser draws one.
  r.appendChild(result, r.text("\xE2\x8C\x84", LabelPx, p.textLabel, shrink = false,
                               pairs = [("margin-left", "4px")]))

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

proc fillWidth*(r: GpuiRenderer; el: GpuiElement) =
  ## `el` takes the free width of its row and may shrink below its content.
  r.styles(el, [("flex-grow", "1"), ("flex-shrink", "1"), ("min-width", "0px")])
