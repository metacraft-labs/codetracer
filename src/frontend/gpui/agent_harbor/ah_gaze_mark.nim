## gpui/agent_harbor/ah_gaze_mark.nim — CTF-P2c step 4. The GPUI status
## line's gaze mark, over `GazeStatusVM` (nim-agents-isonim-viewmodels),
## drawn as the web's `isonim_agent_harbor_gaze_mark_view` draws it
## (`agent_harbor_gaze_mark.styl`), from the same words
## (`agent_harbor_gaze_words`): while gaze is tracked the eye (`◉`) and
## `Gaze` in the caption role; while paused the eye struck through (`⊘`)
## and `Gaze paused`; when off, nothing.
##
## The story draws it where the web story does: in the window's status line
## (24px, the window frame's ground as the web status bar's, the language and
## the encoding at its start), at
## the start of its right-hand zone, 12px in from the edge, under the control
## center as L7 shows it. A press on it is
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
  StatusLinePx* = 24     ## CONTROL_HEIGHT_SM: the gaze mark's own line
  StatusBarPx* = 32
    ## The status line itself: the web's `STATUS_BAR_CONTENT_HEIGHT` (2rem,
    ## status_bar.styl), measured 32px in the web captures. (It was drawn at
    ## the mark's 24px; GPUI review of 2026-11-24.)
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

proc drawStatusLine(r: GpuiRenderer; line: GpuiElement; vm: GazeStatusVM;
                    p: AhPalette; items: string; press: GazePress) =
  ## The status line's parts: the items at its start, the mark at the start
  ## of its right-hand zone.
  r.clearChildren(line)
  r.appendChild(line, r.text(items, CaptionPx, p.textCaption, shrink = false))
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
