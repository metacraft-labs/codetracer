## gpui/visual_replay_leaf.nim — PLAT-59. The GPUI window's **Visual Replay**
## panes — Video Player, Pixel History, Shader Debug — drawn natively from the
## session's `VisualReplayPanesVM` (the model the desktop's panes and the
## terminal's draw).
##
## Visual-Replay.md, in the desktop's order and words:
##
##   * **Video Player** — the frame (its PIXELS, handed to the shim's `img`
##     element, `setImageRgba`), fitted to the stage with its aspect kept;
##     the pixel picker's loupe over it (11 x 11 source pixels at 8x, the
##     centre ringed, the readout under it); the transport row (the
##     controls, the rate badge, the buffering mark, the error); the frame
##     scrubber over the recording's frames with its scene marks; and, nested
##     under it, the draw-call scrubber over the shown frame's draw calls.
##   * **Pixel History** — the picked pixel, then one row per draw call that
##     wrote it: `Draw 9  GEID 902  Passed`, the three colour swatches, the
##     four tests. A row's press navigates (`activateHistoryEntry`).
##   * **Shader Debug** — the fragment, the stage and step with the four step
##     buttons, the source with the step's line marked, the instruction, the
##     variables and the registers.
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-visual-*`).

import std/[math, options, strutils]

import isonim_gpui/renderer
import isonim/core/[signals, computation]

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
from ../viewmodel/viewmodels/table_overflow import nil
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GVisualPanes* = object
    ## The window's own state for the three panes: a held scrubber, the
    ## history's reading position, the loupe's cursor.
    scrubbing*: bool
    scrubAxis*: ScrubAxis
    historyTop*: int
    loupe*: Option[tuple[x, y: int]]
      ## The source pixel under the pointer while the picker is on.

  VideoLayout* = object
    body*: PxRect
    title*: PxRect
    stage*: PxRect
      ## Where the frame may go.
    image*: PxRect
      ## The frame, fitted into the stage (aspect kept, never enlarged past
      ## an integer zoom of the framebuffer).
    transport*: PxRect
    buttons*: seq[tuple[action: VideoPlayerAction, rect: PxRect]]
    frameTrack*: PxRect
    drawTrack*: PxRect
      ## w = 0 when the frame has one draw call or the player did not say.

  HistoryLayout* = object
    body*: PxRect
    list*: PxRect
    rows*: int

  ShaderLayout* = object
    body*: PxRect
    toolbar*: PxRect
    buttons*: seq[tuple[button: string, rect: PxRect]]

  GVisualHitKind* = enum
    gvNone, gvButton, gvFrameTrack, gvDrawTrack, gvImage, gvHistoryRow,
    gvShaderButton

  GVisualHit* = object
    kind*: GVisualHitKind
    action*: VideoPlayerAction
    position*: int
      ## gvFrameTrack: the frame; gvDrawTrack: the draw call within the frame.
    x*, y*: int
      ## gvImage: the source pixel.
    index*: int
      ## gvHistoryRow: the row.
    button*: string
      ## gvShaderButton: `First` / `Back` / `Step` / `Last`.

const
  VisualRowPx* = 22
  VisualHeaderPx* = 26
  VisualTrackPx* = 18
  VisualButtonGapPx = 6
  SwatchPx = 14
  LoupeGrid* = 11
    ## Visual-Replay.md § Loupe Specification: an 11 x 11 neighbourhood…
  LoupeZoom* = 8
    ## …at 8x source pixels.
  VideoPlayerAttribute* = "data-ct-visual-frame"
    ## On the Video Player pane: the frame shown and the count, `3/60`.
  VisualImageAttribute* = "data-ct-visual-image"
    ## On the frame's `img`: the image's size, `256x256`.
  HistoryRowAttribute* = "data-ct-visual-history-index"
  ShaderButtonAttribute* = "data-ct-visual-shader-button"
  VisualTextColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  VisualCaptionColour* = "#8b949e"
  VisualErrorColour* = DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
  VisualPassColour* = "#3fb950"
  VisualSelectedGround* = DesignTokenHex[dtEditorThemeSelection][dmDark]
  VisualCurrentGround* = DesignTokenHex[dtEditorThemeExecutionLine][dmDark]
  VisualButtonGround = DesignTokenHex[dtColorsUiSurfaceInputDefault][dmDark]
  VisualTrackGround = "#30363d"
  VisualThumbColour = "#58a6ff"
  VisualMarkColour = "#d29922"
  VisualPickerRing* = "#58a6ff"
    ## Picker mode's "blue ring around frame canvas" (§ Status Indicators).
  ShaderButtons* = ["First", "Back", "Step", "Last"]

proc pxOf(text: string): int =
  int(float(table_overflow.runeMeasure(text)) * EditorColumnPx)

func inner(body: PxRect): PxRect =
  PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
         w: max(0, body.w - 2 * ChromePaddingPx),
         h: max(0, body.h - 2 * ChromePaddingPx))

# ---------------------------------------------------------------------------
# Video Player
# ---------------------------------------------------------------------------

func fitImage*(stage: PxRect; width, height: int): PxRect =
  ## The frame in the stage: the largest integer zoom of the framebuffer that
  ## fits (1:1 at least when it fits at all — every source pixel a whole
  ## block of window pixels), else scaled down with its aspect kept; centred.
  if width <= 0 or height <= 0 or stage.w <= 0 or stage.h <= 0:
    return PxRect(x: stage.x, y: stage.y)
  var w, h: int
  let zoom = min(stage.w div width, stage.h div height)
  if zoom >= 1:
    w = width * zoom
    h = height * zoom
  else:
    let s = min(stage.w / width, stage.h / height)
    w = max(1, int(float(width) * s))
    h = max(1, int(float(height) * s))
  PxRect(x: stage.x + (stage.w - w) div 2, y: stage.y + (stage.h - h) div 2,
         w: w, h: h)

proc videoLayout*(panes: VisualReplayPanesVM; body: PxRect): VideoLayout =
  result.body = body
  let a = inner(body)
  result.title = PxRect(x: a.x, y: a.y, w: a.w, h: VisualHeaderPx)
  let draws = panes.frame.frameDrawCount.val
  let tracks = VisualTrackPx + (if draws > 1: VisualTrackPx + 4 else: 0)
  let bottom = a.y + a.h
  if draws > 1:
    result.drawTrack = PxRect(x: a.x, y: bottom - VisualTrackPx, w: a.w,
                              h: VisualTrackPx)
  result.frameTrack = PxRect(x: a.x, y: bottom - tracks, w: a.w,
                             h: VisualTrackPx)
  result.transport = PxRect(x: a.x, y: result.frameTrack.y - 4 - VisualRowPx,
                            w: a.w, h: VisualRowPx)
  var x = a.x
  let playing = panes.player.playState.val == Playing
  for action in VideoTransportOrder:
    let label = videoTransportLabel(action, playing)
    let w = pxOf(label) + 14
    if x + w > a.x + a.w:
      break
    result.buttons.add (action, PxRect(x: x, y: result.transport.y, w: w,
                                       h: VisualRowPx))
    x += w + VisualButtonGapPx
  let stageTop = result.title.y + result.title.h + 4
  result.stage = PxRect(x: a.x, y: stageTop, w: a.w,
                        h: max(0, result.transport.y - 4 - stageTop))
  let pic = panes.frame.picture.val
  result.image = fitImage(result.stage, pic.width, pic.height)

func trackPosition(track: PxRect; count, x: int): int =
  if count <= 1 or track.w <= 1: 0
  else:
    let local = max(0, min(x - track.x, track.w - 1))
    int(round(float(local) / float(track.w - 1) * float(count - 1)))

func trackX(track: PxRect; count, position: int): int =
  if count <= 1 or track.w <= 1: track.x
  else: track.x + int(round(float(max(0, min(position, count - 1))) /
                            float(count - 1) * float(track.w - 1)))

proc textRun(r: GpuiRenderer; text, colour: string;
             widthPx = -1): GpuiElement =
  result = r.createElement("span")
  r.setStyle(result, "color", colour)
  r.setStyle(result, "white-space", "pre")
  r.setStyle(result, "flex-shrink", "0")
  if widthPx >= 0:
    r.setStyle(result, "width", $widthPx & "px")
    r.setStyle(result, "overflow", "hidden")
  r.appendChild(result, r.createTextNode(text))

proc box(r: GpuiRenderer; rect: PxRect; origin: PxRect;
         ground = ""): GpuiElement =
  ## An absolutely placed block at `rect` (window pixels) inside a pane whose
  ## origin is `origin`.
  result = r.createElement("div")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $(rect.x - origin.x) & "px")
  r.setStyle(result, "top", $(rect.y - origin.y) & "px")
  r.setStyle(result, "width", $rect.w & "px")
  r.setStyle(result, "height", $rect.h & "px")
  if ground.len > 0:
    r.setStyle(result, "background", ground)

proc clearPane(r: GpuiRenderer; pane: GpuiElement) =
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")

proc hex2(v: int): string = toHex(max(0, min(255, v)), 2).toLowerAscii

proc pixelHex*(pic: FramePicture; x, y: int): string =
  ## `#rrggbb` of source pixel `(x, y)`, transparent black outside the frame
  ## (§ Loupe Specification: "transparent black for out-of-bounds samples").
  if x < 0 or y < 0 or x >= pic.width or y >= pic.height:
    return "#000000"
  let i = (y * pic.width + x) * 4
  "#" & hex2(ord(pic.pixels[i])) & hex2(ord(pic.pixels[i + 1])) &
    hex2(ord(pic.pixels[i + 2]))

proc loupeReadout*(pic: FramePicture; x, y, frame: int): string =
  ## The loupe's footer: `RGBA 0.9400 0.7100 0.1300 1.0000  x=412 y=287
  ## frame 142` (four decimals, source pixels, the frame).
  if x < 0 or y < 0 or x >= pic.width or y >= pic.height:
    return "x=" & $x & "  y=" & $y & "  frame " & $frame
  let i = (y * pic.width + x) * 4
  proc ch(k: int): string = formatFloat(float(ord(pic.pixels[i + k])) / 255.0,
                                        ffDecimal, 4)
  "RGBA " & ch(0) & " " & ch(1) & " " & ch(2) & " " & ch(3) & "  x=" & $x &
    "  y=" & $y & "  frame " & $frame

const VisualImageQuadsAttribute* = "data-ct-visual-image-quads"
  ## The colours at the centres of the image's four quarters, read from the
  ## very bytes handed to the renderer: top left, top right, bottom left,
  ## bottom right. A plan can check WHICH picture the window was given, the
  ## right way up, on a host with no way to read a window's pixels; what the
  ## window then shows is the `plat59` window capture's record.

func quadSamples(pic: FramePicture): string =
  const Hex = "0123456789abcdef"
  for (fx, fy) in [(1, 1), (3, 1), (1, 3), (3, 3)]:
    let at = (pic.height * fy div 4 * pic.width + pic.width * fx div 4) * 4
    if result.len > 0: result.add ','
    result.add '#'
    if at + 2 < pic.pixels.len:
      for c in 0 .. 2:
        let v = ord(pic.pixels[at + c])
        result.add Hex[v shr 4]
        result.add Hex[v and 15]

proc drawVideoPlayer*(r: GpuiRenderer; pane: GpuiElement;
                      panes: VisualReplayPanesVM; st: GVisualPanes;
                      body: PxRect): bool =
  ## Draw the Video Player into `pane` (its children replaced), its body at
  ## `body` in window pixels. False when there is nothing to draw it from.
  if pane.isNil or panes.isNil or body.w <= 0:
    return false
  clearPane(r, pane)
  let lay = videoLayout(panes, body)
  let f = panes.frame
  let p = panes.player
  let frameAt = p.scrubPosition(scrubFrame)
  let count = f.frameCount.val
  r.setAttribute(pane, VideoPlayerAttribute, $frameAt & "/" & $count)
  r.setAttribute(pane, "data-ct-visual-play-state",
                 (if p.playState.val == Playing: "playing" else: "paused"))
  r.setAttribute(pane, "data-ct-visual-picker",
                 (if p.pickerState.val == PickerActive: "on" else: "off"))
  # The title: which frame, which draw call, the size.
  var title = p.frameLabel()
  let draws = f.frameDrawCount.val
  let drawWords = p.drawLabel()
  if drawWords.len > 0:
    title.add "  " & drawWords
  if f.frameWidth.val > 0:
    title.add "  " & $f.frameWidth.val & "x" & $f.frameHeight.val
  let t = box(r, lay.title, body)
  r.appendChild(t, textRun(r, title, VisualTextColour))
  r.setAttribute(t, "data-ct-visual-title", title)
  r.appendChild(pane, t)
  # The stage: the frame, or what is missing.
  let pic = f.picture.val
  if pic.pixels.len > 0 and lay.image.w > 0:
    let frameBox = box(r, lay.image, body)
    if p.pickerState.val == PickerActive:
      r.setStyle(frameBox, "border-width", "1px")
      r.setStyle(frameBox, "border-color", VisualPickerRing)
    let image = r.createElement("img")
    r.setStyle(image, "width", $lay.image.w & "px")
    r.setStyle(image, "height", $lay.image.h & "px")
    r.setAttribute(image, VisualImageAttribute,
                   $pic.width & "x" & $pic.height)
    r.setAttribute(image, "data-ct-visual-image-frame", $pic.frame)
    r.setAttribute(image, VisualImageQuadsAttribute, quadSamples(pic))
    discard r.setImageRgba(image, pic.pixels, pic.width, pic.height)
    r.appendChild(frameBox, image)
    r.appendChild(pane, frameBox)
  else:
    let why =
      if panes.playerError.val.len > 0: panes.playerError.val
      elif f.error.val.len > 0: f.error.val
      elif f.loading.val: "Loading frame …"
      else: "No frame yet"
    let msg = box(r, PxRect(x: lay.stage.x, y: lay.stage.y, w: lay.stage.w,
                            h: VisualRowPx), body)
    r.appendChild(msg, textRun(r, why,
      (if panes.playerError.val.len > 0 or f.error.val.len > 0:
         VisualErrorColour else: VisualCaptionColour)))
    r.setAttribute(msg, "data-ct-visual-status", why)
    r.appendChild(pane, msg)
  # The loupe, while the picker is on and the pointer is over the frame.
  if p.pickerState.val == PickerActive and st.loupe.isSome and
     pic.pixels.len > 0:
    let (cx, cy) = st.loupe.get
    let side = LoupeGrid * LoupeZoom
    let lx = min(lay.stage.x + lay.stage.w - side, lay.image.x + lay.image.w)
    let loupe = box(r, PxRect(x: max(lay.stage.x, lx), y: lay.stage.y,
                              w: side, h: side + VisualRowPx), body)
    r.setAttribute(loupe, "data-ct-visual-loupe", $cx & "," & $cy)
    let half = LoupeGrid div 2
    for gy in 0 ..< LoupeGrid:
      for gx in 0 ..< LoupeGrid:
        let cell = r.createElement("div")
        r.setStyle(cell, "position", "absolute")
        r.setStyle(cell, "left", $(gx * LoupeZoom) & "px")
        r.setStyle(cell, "top", $(gy * LoupeZoom) & "px")
        r.setStyle(cell, "width", $LoupeZoom & "px")
        r.setStyle(cell, "height", $LoupeZoom & "px")
        r.setStyle(cell, "background",
                   pic.pixelHex(cx - half + gx, cy - half + gy))
        if gx == half and gy == half:
          r.setStyle(cell, "border-width", "1px")
          r.setStyle(cell, "border-color", "#ffffff")
          r.setAttribute(cell, "data-ct-visual-loupe-centre",
                         pic.pixelHex(cx, cy))
        r.appendChild(loupe, cell)
    let readout = r.createElement("div")
    r.setStyle(readout, "position", "absolute")
    r.setStyle(readout, "left", "0px")
    r.setStyle(readout, "top", $side & "px")
    let text = loupeReadout(pic, cx, cy, f.currentFrame.val)
    r.appendChild(readout, textRun(r, text, VisualTextColour))
    r.setAttribute(readout, "data-ct-visual-readout", text)
    r.appendChild(loupe, readout)
    r.appendChild(pane, loupe)
  # The transport.
  let playing = p.playState.val == Playing
  for (action, rect) in lay.buttons:
    let b = box(r, rect, body, VisualButtonGround)
    let label = videoTransportLabel(action, playing)
    if action == VpaTogglePicker and p.pickerState.val == PickerActive:
      r.setStyle(b, "background", VisualSelectedGround)
    r.setAttribute(b, "data-ct-visual-control", $action)
    r.appendChild(b, textRun(r, label, VisualTextColour))
    r.appendChild(pane, b)
  let lastX = if lay.buttons.len > 0: lay.buttons[^1].rect.x +
                lay.buttons[^1].rect.w + 12
              else: lay.transport.x
  let status = videoTransportStatus(playing, p.direction.val == Reverse,
    p.rate.val.rateNumber, p.bufferingDegraded.val, f.loading.val,
    panes.playerError.val)
  let s = box(r, PxRect(x: lastX, y: lay.transport.y,
                        w: max(0, lay.transport.x + lay.transport.w - lastX),
                        h: VisualRowPx), body)
  r.appendChild(s, textRun(r, status,
    (if panes.playerError.val.len > 0: VisualErrorColour
     else: VisualCaptionColour)))
  r.setAttribute(s, "data-ct-visual-status", status)
  r.appendChild(pane, s)
  # The frame scrubber: the track, the scene marks, the thumb.
  proc track(rect: PxRect; n, at: int; marks: seq[int]; name: string) =
    let tr = box(r, rect, body, VisualTrackGround)
    r.setAttribute(tr, "data-ct-visual-track", name)
    r.setAttribute(tr, "data-ct-visual-track-at", $at & "/" & $n)
    r.appendChild(pane, tr)
    for m in marks:
      if m < 0 or m >= n: continue
      let mx = trackX(rect, n, m)
      let mk = box(r, PxRect(x: mx, y: rect.y, w: 2, h: rect.h), body,
                   VisualMarkColour)
      r.setAttribute(mk, "data-ct-visual-scene-mark", $m)
      r.appendChild(pane, mk)
    let tx = trackX(rect, n, at)
    let thumb = box(r, PxRect(x: max(rect.x, tx - 3), y: rect.y, w: 6,
                              h: rect.h), body, VisualThumbColour)
    r.setAttribute(thumb, "data-ct-visual-thumb", name)
    r.appendChild(pane, thumb)
  if count > 0:
    track(lay.frameTrack, count, frameAt, f.clearFrames.val, "frame")
  if lay.drawTrack.w > 0:
    track(lay.drawTrack, draws, max(0, p.scrubPosition(scrubDraw)), @[],
          "draw")
  true

proc videoHitAt*(panes: VisualReplayPanesVM; body: PxRect;
                 x, y: int): GVisualHit =
  ## What a press at window pixel `(x, y)` in the Video Player is on.
  if panes.isNil or not body.contains(x, y):
    return GVisualHit(kind: gvNone)
  let lay = videoLayout(panes, body)
  for (action, rect) in lay.buttons:
    if rect.contains(x, y):
      return GVisualHit(kind: gvButton, action: action)
  if lay.frameTrack.contains(x, y):
    return GVisualHit(kind: gvFrameTrack, position:
      trackPosition(lay.frameTrack, panes.frame.frameCount.val, x))
  if lay.drawTrack.contains(x, y):
    return GVisualHit(kind: gvDrawTrack, position:
      trackPosition(lay.drawTrack, panes.frame.frameDrawCount.val, x))
  let pic = panes.frame.picture.val
  if lay.image.contains(x, y) and pic.width > 0:
    let sx = min(pic.width - 1, (x - lay.image.x) * pic.width div lay.image.w)
    let sy = min(pic.height - 1,
                 (y - lay.image.y) * pic.height div lay.image.h)
    return GVisualHit(kind: gvImage, x: sx, y: sy)
  GVisualHit(kind: gvNone)

proc scrubAt*(panes: VisualReplayPanesVM; body: PxRect; axis: ScrubAxis;
              x: int): int =
  ## The position a held scrubber's pointer at window x names.
  let lay = videoLayout(panes, body)
  case axis
  of scrubFrame: trackPosition(lay.frameTrack, panes.frame.frameCount.val, x)
  of scrubDraw: trackPosition(lay.drawTrack, panes.frame.frameDrawCount.val, x)

# ---------------------------------------------------------------------------
# Pixel History
# ---------------------------------------------------------------------------

proc historyLayout*(panes: VisualReplayPanesVM; body: PxRect): HistoryLayout =
  result.body = body
  let a = inner(body)
  var top = a.y + VisualHeaderPx
  if panes.history.loading.val: top += VisualRowPx
  if panes.history.error.val.len > 0: top += VisualRowPx
  let detail = panes.history.selectedEntry.val.isSome
  let bottom = a.y + a.h - (if detail: VisualRowPx else: 0)
  result.rows = max(0, (bottom - top) div VisualRowPx)
  result.list = PxRect(x: a.x, y: top, w: a.w, h: result.rows * VisualRowPx)

proc visibleHistoryTop*(st: GVisualPanes; total, rows: int): int =
  max(0, min(st.historyTop, total - max(1, rows)))

proc swatchHex(c: VisualReplayPixelColor): string =
  "#" & hex2(colorByte(c.r)) & hex2(colorByte(c.g)) & hex2(colorByte(c.b))

proc drawPixelHistory*(r: GpuiRenderer; pane: GpuiElement;
                       panes: VisualReplayPanesVM; st: GVisualPanes;
                       body: PxRect): bool =
  if pane.isNil or panes.isNil or body.w <= 0:
    return false
  clearPane(r, pane)
  let h = panes.history
  let lay = historyLayout(panes, body)
  let a = inner(body)
  r.setAttribute(pane, "data-ct-visual-history", $h.entries.val.len)
  var y = a.y
  let header = box(r, PxRect(x: a.x, y: y, w: a.w, h: VisualHeaderPx), body)
  r.appendChild(header, textRun(r, PixelHistoryHeading & "  " & h.pixelText(),
                                VisualTextColour))
  r.setAttribute(header, "data-ct-visual-pixel", h.pixelText())
  r.appendChild(pane, header)
  y += VisualHeaderPx
  for (shown, text, colour) in [
      (h.loading.val, PixelHistoryLoadingText, VisualCaptionColour),
      (h.error.val.len > 0, h.error.val, VisualErrorColour)]:
    if shown:
      let line = box(r, PxRect(x: a.x, y: y, w: a.w, h: VisualRowPx), body)
      r.appendChild(line, textRun(r, text, colour))
      r.appendChild(pane, line)
      y += VisualRowPx
  if h.showsEmptyHint():
    let line = box(r, PxRect(x: a.x, y: lay.list.y, w: a.w, h: VisualRowPx),
                   body)
    r.appendChild(line, textRun(r, PixelHistoryEmptyText, VisualCaptionColour))
    r.setAttribute(line, "data-ct-visual-empty", PixelHistoryEmptyText)
    r.appendChild(pane, line)
  let entries = h.entries.val
  let top = st.visibleHistoryTop(entries.len, lay.rows)
  for k in 0 ..< lay.rows:
    let i = top + k
    if i >= entries.len: break
    let e = entries[i]
    let rowRect = PxRect(x: a.x, y: lay.list.y + k * VisualRowPx, w: a.w,
                         h: VisualRowPx)
    let selected = h.selectedEntry.val.isSome and h.selectedEntry.val.get == i
    let row = box(r, rowRect, body, (if selected: VisualSelectedGround else: ""))
    r.setStyle(row, "display", "flex")
    r.setStyle(row, "items", "center")
    r.setStyle(row, "gap", "8px")
    r.setAttribute(row, HistoryRowAttribute, $i)
    r.setAttribute(row, "data-ct-visual-draw", $e.drawCallIndex)
    r.setAttribute(row, "data-ct-visual-geid", $e.geid)
    r.appendChild(row, textRun(r, drawText(e), VisualTextColour))
    r.appendChild(row, textRun(r, geidText(e), VisualCaptionColour))
    r.appendChild(row, textRun(r, passText(e),
      (if e.passed: VisualPassColour else: VisualErrorColour)))
    for (name, c) in [("pre", e.preColor), ("shader", e.shaderOutput),
                      ("post", e.postColor)]:
      let sw = r.createElement("div")
      r.setStyle(sw, "width", $SwatchPx & "px")
      r.setStyle(sw, "height", $SwatchPx & "px")
      r.setStyle(sw, "flex-shrink", "0")
      r.setStyle(sw, "background", swatchHex(c))
      r.setAttribute(sw, "data-ct-visual-swatch-" & name, swatchHex(c))
      r.appendChild(row, sw)
    r.appendChild(row, textRun(r, testsText(e), VisualCaptionColour))
    r.appendChild(pane, row)
  if h.selectedEntry.val.isSome and h.selectedEntry.val.get < entries.len:
    let e = entries[h.selectedEntry.val.get]
    let detail = box(r, PxRect(x: a.x, y: a.y + a.h - VisualRowPx, w: a.w,
                               h: VisualRowPx), body)
    let text = "Pre " & colorText(e.preColor) & "  Shader " &
               colorText(e.shaderOutput) & "  Post " & colorText(e.postColor)
    r.appendChild(detail, textRun(r, text, VisualCaptionColour))
    r.setAttribute(detail, "data-ct-visual-detail", text)
    r.appendChild(pane, detail)
  true

proc historyHitAt*(panes: VisualReplayPanesVM; st: GVisualPanes; body: PxRect;
                   x, y: int): GVisualHit =
  if panes.isNil or not body.contains(x, y):
    return GVisualHit(kind: gvNone)
  let lay = historyLayout(panes, body)
  if not lay.list.contains(x, y):
    return GVisualHit(kind: gvNone)
  let total = panes.history.entries.val.len
  let i = st.visibleHistoryTop(total, lay.rows) + (y - lay.list.y) div
          VisualRowPx
  if i < 0 or i >= total:
    return GVisualHit(kind: gvNone)
  GVisualHit(kind: gvHistoryRow, index: i)

proc revealHistory*(st: var GVisualPanes; panes: VisualReplayPanesVM;
                    body: PxRect; row: int) =
  let lay = historyLayout(panes, body)
  if row < 0 or lay.rows <= 0: return
  let top = st.visibleHistoryTop(panes.history.entries.val.len, lay.rows)
  if row < top: st.historyTop = row
  elif row >= top + lay.rows: st.historyTop = row - lay.rows + 1

proc scrollHistory*(st: var GVisualPanes; panes: VisualReplayPanesVM;
                    body: PxRect; delta: int) =
  let lay = historyLayout(panes, body)
  let total = panes.history.entries.val.len
  st.historyTop = max(0, min(st.visibleHistoryTop(total, lay.rows) + delta,
                             total - max(1, lay.rows)))

# ---------------------------------------------------------------------------
# Shader Debug
# ---------------------------------------------------------------------------

proc shaderLayout*(panes: VisualReplayPanesVM; body: PxRect): ShaderLayout =
  result.body = body
  let a = inner(body)
  var y = a.y + VisualHeaderPx
  if panes.shader.loading.val: y += VisualRowPx
  if panes.shader.error.val.len > 0: y += VisualRowPx
  result.toolbar = PxRect(x: a.x, y: y, w: a.w, h: VisualRowPx)
  var x = a.x + pxOf(panes.shader.stageText() & "  " &
                     panes.shader.stepText()) + 16
  for b in ShaderButtons:
    let w = pxOf(b) + 14
    result.buttons.add (b, PxRect(x: x, y: y, w: w, h: VisualRowPx))
    x += w + VisualButtonGapPx

proc drawShaderDebug*(r: GpuiRenderer; pane: GpuiElement;
                      panes: VisualReplayPanesVM; body: PxRect): bool =
  if pane.isNil or panes.isNil or body.w <= 0:
    return false
  clearPane(r, pane)
  let sd = panes.shader
  let a = inner(body)
  var y = a.y
  let header = box(r, PxRect(x: a.x, y: y, w: a.w, h: VisualHeaderPx), body)
  r.appendChild(header, textRun(r, ShaderDebugHeading & "  " & sd.contextText(),
                                VisualTextColour))
  r.setAttribute(header, "data-ct-visual-shader-context", sd.contextText())
  r.appendChild(pane, header)
  y += VisualHeaderPx
  for (shown, text, colour) in [
      (sd.loading.val, ShaderDebugLoadingText, VisualCaptionColour),
      (sd.error.val.len > 0, sd.error.val, VisualErrorColour)]:
    if shown:
      let line = box(r, PxRect(x: a.x, y: y, w: a.w, h: VisualRowPx), body)
      r.appendChild(line, textRun(r, text, colour))
      r.appendChild(pane, line)
      y += VisualRowPx
  if sd.showsEmptyHint():
    let line = box(r, PxRect(x: a.x, y: y, w: a.w, h: VisualRowPx), body)
    r.appendChild(line, textRun(r, ShaderDebugEmptyText, VisualCaptionColour))
    r.setAttribute(line, "data-ct-visual-empty", ShaderDebugEmptyText)
    r.appendChild(pane, line)
  if sd.debugInfo.val.isNone:
    return true
  let lay = shaderLayout(panes, body)
  let tb = box(r, PxRect(x: a.x, y: lay.toolbar.y, w: a.w,
                         h: VisualRowPx), body)
  r.appendChild(tb, textRun(r, sd.stageText() & "  " & sd.stepText(),
                            VisualCaptionColour))
  r.setAttribute(tb, "data-ct-visual-step", sd.stepText())
  r.appendChild(pane, tb)
  for (b, rect) in lay.buttons:
    let btn = box(r, rect, body, VisualButtonGround)
    r.setAttribute(btn, ShaderButtonAttribute, b)
    r.appendChild(btn, textRun(r, b, VisualTextColour))
    r.appendChild(pane, btn)
  y = lay.toolbar.y + VisualRowPx + 4
  let current = sd.currentSourceLine()
  for i, line in sd.sourceLinesOf():
    if y + VisualRowPx > a.y + a.h: break
    let n = i + 1
    let row = box(r, PxRect(x: a.x, y: y, w: a.w, h: VisualRowPx), body,
                  (if n == current: VisualCurrentGround else: ""))
    r.setStyle(row, "display", "flex")
    r.setStyle(row, "gap", "8px")
    r.setAttribute(row, "data-ct-visual-shader-line", $n)
    if n == current: r.setAttribute(row, "data-ct-current", "true")
    r.appendChild(row, textRun(r, lineNumberText(n), VisualCaptionColour))
    r.appendChild(row, textRun(r, line, VisualTextColour))
    r.setAttribute(row, TextMetricAttribute, gpuiMetricFor(trEditorCode))
    r.appendChild(pane, row)
    y += VisualRowPx
  var inspector: seq[(string, string, string)] = @[]
  inspector.add ("Instruction", sd.instructionText(), "instruction")
  inspector.add ("Variables", "", "variables")
  for v in sd.variablesOf():
    inspector.add (v.name, v.valueType & "  " & v.value, "variable")
  if sd.variablesOf().len == 0:
    inspector.add ("No variables", "", "none")
  inspector.add ("Registers", "", "registers")
  for v in sd.registersOf():
    inspector.add (v.name, v.valueType & "  " & v.value, "register")
  if sd.registersOf().len == 0:
    inspector.add ("No registers", "", "none")
  for (k, v, kind) in inspector:
    if y + VisualRowPx > a.y + a.h: break
    let row = box(r, PxRect(x: a.x, y: y, w: a.w, h: VisualRowPx), body)
    r.setStyle(row, "display", "flex")
    r.setStyle(row, "gap", "8px")
    r.setAttribute(row, "data-ct-visual-shader-" & kind, k)
    r.appendChild(row, textRun(r, k, VisualCaptionColour))
    r.appendChild(row, textRun(r, v, VisualTextColour))
    r.appendChild(pane, row)
    y += VisualRowPx
  true

proc shaderHitAt*(panes: VisualReplayPanesVM; body: PxRect;
                  x, y: int): GVisualHit =
  if panes.isNil or not body.contains(x, y) or
     panes.shader.debugInfo.val.isNone:
    return GVisualHit(kind: gvNone)
  for (b, rect) in shaderLayout(panes, body).buttons:
    if rect.contains(x, y):
      return GVisualHit(kind: gvShaderButton, button: b)
  GVisualHit(kind: gvNone)
