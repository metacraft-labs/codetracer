## gpui/agent_harbor/ah_gaze_mark.nim — CTF-P2c step 4. The GPUI status
## line's gaze mark, over `GazeStatusVM` (nim-agents-isonim-viewmodels),
## drawn as the web's `isonim_agent_harbor_gaze_mark_view` draws it
## (`agent_harbor_gaze_mark.styl`), from the same words
## (`agent_harbor_gaze_words`): while gaze is tracked the eye (`◉`) and
## `Gaze` in the caption role; while paused the eye struck through (`⊘`)
## and `Gaze paused`; when off, nothing.
##
## The story draws it where the web story does: in the window's status line
## (32px, `StatusBarPx`, the window frame's ground as the web status bar's,
## the language and the encoding at its start), at the start of its
## right-hand zone, 12px in from the edge, under the control center as L7
## shows it. A press on it is routed: it carries `gaze.toggle-pause` and
## reports the press to the host's `GazePress`.
##
## Facts (`data-ah-*`): `markFacts` on the host, `gaze-mark` on the mark.

import std/[math, strutils]

import isonim/core/computation
import ../../viewmodel/views/agent_harbor_gaze_words
import ../../viewmodel/input/element_press
import ./ah_theme
import ../../../common/pointer_shape
import ../../styles/generated/design_tokens

export agent_harbor_gaze_words

const
  StatusBarPx* = 32
    ## The status line itself: the web's `STATUS_BAR_CONTENT_HEIGHT` (2rem,
    ## status_bar.styl), measured 32px in the web captures. (It was drawn at
    ## the mark's 24px; GPUI review of 2026-11-24.)
  MarkGapPx* = 4         ## between the eye and the words (0.25rem)
  EdgePx* = 12           ## the mark's margin from the right-hand zone's end
  EyePx* = 12            ## the eye's box: `.ah-gaze-glyph`'s 0.75rem
  StatusTextPx* = BodyPx
    ## The status bar's text: `STATUS_BAR_TEXT_SIZE` (0.875rem, 14px) in
    ## `status_bar.styl`, which the web's mark inherits ("at the bar's own
    ## size"), not the caption's 12px.
  MarkLinePx* = 21
    ## The mark's height: one line of the bar's text, 14px at the browser's
    ## `line-height: normal` for the face, 1.5 (the web's `.ah-gaze-mark` is
    ## 21px tall, centred in the status bar, `StatusBarPx`).

type
  GazePress* = proc(operation: string)
    ## A host's route for a press on the mark: the operation it carries.

proc markWidthPx*(vm: GazeStatusVM): int =
  ## The mark's width, as the web lays it out: the eye (12px), the gap, the
  ## words at the status bar's size, kerned as a browser and GPUI's shaper
  ## set them, rounded up so the last glyph is never clipped.
  EyePx + MarkGapPx + int(ceil(textWidth(vm.text, StatusTextPx)))

proc drawGazeMark*(r: GpuiRenderer; p: AhPalette; vm: GazeStatusVM;
                   press: GazePress = nil): GpuiElement =
  ## The mark (nil when it is not shown).
  if not vm.shown: return nil
  result = r.box(pairs = [("height", $MarkLinePx & "px"), ("items", "center"),
                          ("gap", $MarkGapPx & "px"), ("flex-shrink", "0"),
                          ("width", $vm.markWidthPx & "px")])
  r.tag(result, "gaze-mark", $vm.state.val)
  r.tag(result, "tooltip", vm.tooltip)
  r.tag(result, "accessible-name", vm.text)
  let glyph = r.text(vm.glyphOf, EyePx, p.textCaption, shrink = false,
                     pairs = [("width", $EyePx & "px")])
  r.tag(glyph, "glyph", vm.glyphOf)
  r.appendChild(result, glyph)
  r.appendChild(result, r.text(vm.text, StatusTextPx, p.textCaption, shrink = false))
  r.setAttribute(result, OperationAttribute, GazeTogglePauseOperation)
  r.setStyle(result, "cursor", pointerShapeOf(HitTarget(kind: hkControl)).cssName)
  if press != nil:
    r.addEventListener(result, "mousedown", proc(ev: GpuiEvent) =  # ir1-gate: hit test
      press(GazeTogglePauseOperation))

const
  ItemSeparator* = " \xE2\x94\x82 "
    ## How the stories' items name the bar between two readouts
    ## (`GazeStoryStatusItems`, `Noir │ UTF-8`); GPUI draws the bar itself.
  ItemsInsetPx* = 2
    ## The readouts' `#file-info-status` margin-left (0.6em of the bar's
    ## 16px, 9.6px), less the line's 8px padding.
  ItemGapPx* = 10
    ## `#file-info-status`'s gap, 0.6em of the bar's 16px (9.6px), on each
    ## side of the bar between two readouts.
  SeparatorPx* = 16
    ## `.separate-bar`: 1em tall at the bar's 16px, a hairline wide.

proc statusItemInk*(p: AhPalette): string =
  ## The readouts' ink: the web status bar's own text colour
  ## (`#status-base`'s `colors-ui-text-primary-label-subtle`, status_bar.styl,
  ## the quietest token that clears 4.5:1 on the bar in Dark).
  DesignTokenHex[dtColorsUiTextPrimaryLabelSubtle][p.mode]

proc drawStatusItems(r: GpuiRenderer; p: AhPalette; items: string): GpuiElement =
  ## The readouts at the status line's start, as the web's `#file-info-status`
  ## lays them out: each at the bar's text size (`STATUS_BAR_TEXT_SIZE`,
  ## 14px) in the bar's own text colour, a `.separate-bar` hairline in the
  ## divider role between two, 0.6em clear on each side.
  result = r.box(pairs = [("items", "center"), ("gap", $ItemGapPx & "px"),
                          ("margin-left", $ItemsInsetPx & "px"), ("flex-shrink", "0")])
  r.tag(result, "status-items", items)
  let parts = items.split(ItemSeparator)
  for i, part in parts:
    if i > 0:
      let bar = r.box(pairs = [("width", "1px"), ("height", $SeparatorPx & "px"),
                               ("flex-shrink", "0"),
                               ("background", DesignTokenHex[dtColorsUiDividerPrimary][p.mode])])
      r.tag(bar, "status-separator", "true")
      r.appendChild(result, bar)
    let t = r.text(part, StatusTextPx, p.statusItemInk, shrink = false)
    r.tag(t, "status-item", part)
    r.appendChild(result, t)

proc drawStatusLine(r: GpuiRenderer; line: GpuiElement; vm: GazeStatusVM;
                    p: AhPalette; items: string; press: GazePress) =
  ## The status line's parts: the items at its start, the mark at the start
  ## of its right-hand zone.
  r.clearChildren(line)
  r.appendChild(line, r.drawStatusItems(p, items))
  r.appendChild(line, r.box(pairs = [("flex-grow", "1")]))
  let mark = r.drawGazeMark(p, vm, press)
  if mark != nil: r.appendChild(line, mark)

proc mountGazeStory*(r: GpuiRenderer; host: GpuiElement; vm: GazeStatusVM;
                     p: AhPalette; widthPx, heightPx: int; items: string;
                     press: GazePress = nil; above: GpuiElement = nil) =
  ## The story's window: `above` (the control center as L7 shows it, which
  ## draws itself; nil: an empty working area) over the status line, the
  ## mark at the start of its right-hand zone. The status line and the
  ## story's facts are drawn again whenever the mark's state moves.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", $heightPx & "px"),
                  ("background", DesignTokenHex[dtColorsUiSurfaceBaseCanvas][p.mode])])
  r.tag(host, "surface", GazeSurface)
  let work = if above.isNil: r.box(pairs = [("flex-grow", "1")]) else: above
  r.appendChild(host, work)
  let line = r.box(pairs = [("height", $StatusBarPx & "px"), ("items", "center"),
                            ("padding-left", "8px"), ("padding-right", $EdgePx & "px"),
                            ("background", p.ground), ("flex-shrink", "0")])
  r.tag(line, "status-line", "true")
  r.appendChild(host, line)
  createRenderEffect proc() =
    discard vm.state.val
    for (k, v) in vm.markFacts: r.tag(host, k, v)
    drawStatusLine(r, line, vm, p, items, press)
