## gpui/agent_harbor/ah_gaze_mark.nim — CTF-P2c step 4. The GPUI status
## line's gaze mark, over `GazeStatusVM` (nim-agents-isonim-viewmodels),
## drawn as the web's `isonim_agent_harbor_gaze_mark_view` draws it
## (`agent_harbor_gaze_mark.styl`), from the same words
## (`agent_harbor_gaze_words`): while gaze is tracked the eye (`◉`) and
## `Gaze` in the caption role; while paused the eye struck through (`⊘`)
## and `Gaze paused`; when off, nothing.
##
## The story draws it where the web story does: in the window's status line
## (24px, the panel's ground, the language and the encoding at its start), at
## the start of its right-hand zone, 12px in from the edge. A press on it is
## routed: it carries `gaze.toggle-pause` and reports the press to the
## host's `GazePress`.
##
## Facts (`data-ah-*`): `markFacts` on the host, `gaze-mark` on the mark.

import isonim/core/computation
import ../../viewmodel/views/agent_harbor_gaze_words
import ../../viewmodel/input/element_press
import ./ah_theme
import ../../../common/pointer_shape
import ../../styles/generated/design_tokens

export agent_harbor_gaze_words

const
  StatusLinePx* = 24     ## CONTROL_HEIGHT_SM, the status bar's line
  MarkGapPx* = 4         ## between the eye and the words (0.25rem)
  EdgePx* = 12           ## the mark's margin from the right-hand zone's end

type
  GazePress* = proc(operation: string)
    ## A host's route for a press on the mark: the operation it carries.

proc markWidthPx*(vm: GazeStatusVM): int =
  ## The mark's width: the eye (14px), the gap, the words.
  14 + MarkGapPx + textPx(vm.text, CaptionPx)

proc drawGazeMark*(r: GpuiRenderer; p: AhPalette; vm: GazeStatusVM;
                   press: GazePress = nil): GpuiElement =
  ## The mark (nil when it is not shown).
  if not vm.shown: return nil
  result = r.box(pairs = [("height", $StatusLinePx & "px"), ("items", "center"),
                          ("gap", $MarkGapPx & "px"), ("flex-shrink", "0"),
                          ("width", $vm.markWidthPx & "px")])
  r.tag(result, "gaze-mark", $vm.state.val)
  r.tag(result, "tooltip", vm.tooltip)
  r.tag(result, "accessible-name", vm.text)
  let glyph = r.text(vm.glyphOf, CaptionPx + 2, p.textCaption, shrink = false,
                     pairs = [("width", "14px")])
  r.tag(glyph, "glyph", vm.glyphOf)
  r.appendChild(result, glyph)
  r.appendChild(result, r.text(vm.text, CaptionPx, p.textCaption, shrink = false))
  r.setAttribute(result, OperationAttribute, GazeTogglePauseOperation)
  r.setStyle(result, "cursor", pointerShapeOf(HitTarget(kind: hkControl)).cssName)
  if press != nil:
    r.addEventListener(result, "mousedown", proc(ev: GpuiEvent) =  # ir1-gate: hit test
      press(GazeTogglePauseOperation))

proc drawGazeStory*(r: GpuiRenderer; host: GpuiElement; vm: GazeStatusVM;
                    p: AhPalette; widthPx, heightPx: int; items: string;
                    press: GazePress = nil) =
  ## The story's window: an empty working area over the status line, the
  ## mark at the start of its right-hand zone.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", $heightPx & "px"),
                  ("background", DesignTokenHex[dtColorsUiSurfaceBaseCanvas][p.mode])])
  r.tag(host, "surface", GazeSurface)
  for (k, v) in vm.markFacts: r.tag(host, k, v)
  let work = r.box(pairs = [("flex-grow", "1")])
  r.appendChild(host, work)
  let line = r.box(pairs = [("height", $StatusLinePx & "px"), ("items", "center"),
                            ("padding-left", "8px"), ("padding-right", $EdgePx & "px"),
                            ("background", p.panel), ("flex-shrink", "0")])
  r.tag(line, "status-line", "")
  r.appendChild(line, r.text(items, CaptionPx, p.textCaption, shrink = false))
  r.appendChild(line, r.box(pairs = [("flex-grow", "1")]))
  let mark = r.drawGazeMark(p, vm, press)
  if mark != nil: r.appendChild(line, mark)
  r.appendChild(host, line)

proc mountGazeStory*(r: GpuiRenderer; host: GpuiElement; vm: GazeStatusVM;
                     p: AhPalette; widthPx, heightPx: int; items: string;
                     press: GazePress = nil) =
  ## Draws the story, and again whenever the mark's state moves.
  createRenderEffect proc() =
    discard vm.state.val
    drawGazeStory(r, host, vm, p, widthPx, heightPx, items, press)
