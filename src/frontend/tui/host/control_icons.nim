## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header for the full rule.
##
## host/control_icons.nim — PLAT-48 deliverable 4, the `graphics` rendering:
## THE DESKTOP'S OWN DEBUGGER MARKS, DRAWN AS PICTURES IN THE TERMINAL.
##
## The desktop draws its toolbar marks as inline SVG
## (`viewmodel/views/debug_control_marks.ControlMarks`). Here those SAME path
## strings are rasterised (`common/terminal_graphics/path_raster`) and sent
## to a terminal that was measured to draw pictures — the kitty graphics
## protocol, the one tier-0 protocol this build can emit (sixel has no
## encoder: `image_capability.prSixelHasNoEncoder`). The top bar reserves the
## cells (`views/top_bar`: two per control, blank); this module places a
## picture over them.
##
## ## The bytes, and why they are this shape
##
##   * RAW RGBA (`f=32`, `s=`/`v=` the pixel size), chunked at kitty's 4096
##     base64 bytes — no PNG encoder is needed, and an icon is 4 KiB;
##   * `q=2` on EVERY command, so the terminal sends no `OK` back: a reply
##     arriving after the start-up reply window would reach the keymap as the
##     letters of `Gi=…;OK`;
##   * each image is TRANSMITTED ONCE (`a=t`) per ink, then PLACED (`a=p`)
##     with `c=2,r=1` — the terminal scales it into the two cells — and
##     `C=1`, so placing does not move the cursor;
##   * a frame whose controls did not move re-sends nothing: the placements
##     persist on the terminal, and repainting the cells beneath does not
##     remove them. When they move, the old placements are deleted by image
##     id (`a=d,d=i`, which keeps the image data) and placed again.
##
## Everything here is a string builder over values; `main.nim` writes the
## result after a frame.

import std/[base64, sets, strutils]

import ../../viewmodel/views/debug_control_marks
import ../../../common/terminal_graphics/[raster, path_raster]
import ../app/views/top_bar
import ../../viewmodel/viewmodels/transport_icons

const
  IconPixels = 32
    ## Each mark is rasterised at 32x32 and scaled by the terminal into its
    ## two cells.
  IconImageIdBase* = 4800'u32
    ## Image ids: `IconImageIdBase + 10 * ink + controlIndex`. Fixed rather
    ## than allocated, so a test can find a control's image by its id.
  KittyChunk = 4096

type
  IconInk* = enum
    iiEnabled = 0
    iiDisabled = 1

  ControlIconState* = object
    ## What this terminal already holds.
    transmitted*: HashSet[uint32]
    placedSignature*: string
    inks*: array[IconInk, string]
      ## The `#rrggbb` each image was drawn in; a theme switch changes them,
      ## and the images are then drawn and sent again.

func iconImageId*(ink: IconInk; controlIndex: int): uint32 =
  IconImageIdBase + 10'u32 * uint32(ord(ink)) + uint32(controlIndex)

proc shapesOf*(m: ControlMark): seq[MarkShape] =
  ## A desktop mark's paths as the rasteriser's shapes: the SAME `d` strings,
  ## filled or stroked, at the mark's stroke width and caps.
  for s in m.shapes:
    var w = 1.0
    if s.strokeWidth.len > 0:
      try:
        w = parseFloat(s.strokeWidth)
      except ValueError:
        w = 1.0
    result.add MarkShape(d: s.d, stroked: s.stroked, strokeWidth: w,
                         roundCaps: s.linecap == "round")

proc markImage*(controlId: string; ink: Rgb; pixels = IconPixels): RgbaImage =
  ## The desktop's mark for a control, `pixels` square, in `ink` on a
  ## TRANSPARENT ground (the cell's own background shows through).
  let m = markFor(controlId)
  rasterizeShapes(m.shapesOf(), m.viewBox, pixels, pixels, ink,
                  rgb(0, 0, 0), groundAlpha = 0)

proc kittyTransmitRgba*(img: RgbaImage; id: uint32): string =
  ## `a=t` (store, do not display), raw RGBA, quiet, chunked.
  let b64 = base64.encode(img.pixels)
  var pos = 0
  while pos < b64.len:
    let stop = min(pos + KittyChunk, b64.len)
    let more = if stop < b64.len: 1 else: 0
    if pos == 0:
      result.add "\x1b_Ga=t,f=32,s=" & $img.width & ",v=" & $img.height &
                 ",i=" & $id & ",q=2,m=" & $more & ";" & b64[pos ..< stop] &
                 "\x1b\\"
    else:
      result.add "\x1b_Gm=" & $more & ",q=2;" & b64[pos ..< stop] & "\x1b\\"
    pos = stop

proc kittyPlaceAt*(id: uint32; row, col: int): string =
  ## Move to the cell (1-based on the wire) and place image `id` over two
  ## cells, one row, without moving the cursor.
  "\x1b[" & $(row + 1) & ";" & $(col + 1) & "H" &
    "\x1b_Ga=p,i=" & $id & ",p=1,c=2,r=1,C=1,q=2\x1b\\"

proc kittyDeletePlacements*(id: uint32): string =
  "\x1b_Ga=d,d=i,i=" & $id & ",q=2\x1b\\"

proc controlIconBytes*(state: var ControlIconState; lay: TopBarLayout;
                       enabled: seq[bool]; inkEnabled, inkDisabled: string;
                       wrapForTmux = false): string =
  ## The bytes that make the terminal show the top bar's controls as the
  ## desktop's marks, given where the layout put them — "" when nothing
  ## changed since the last call, or when the controls are not drawn as
  ## pictures. Saves and restores the cursor around the placements.
  if lay.effectiveIcons != imGraphics:
    if state.placedSignature.len > 0:
      # Leaving `graphics`: take every placed picture down.
      for id in state.transmitted:
        result.add kittyDeletePlacements(id)
      state.placedSignature = ""
    return
  let inks = [iiEnabled: inkEnabled, iiDisabled: inkDisabled]
  if inks != state.inks:
    state.transmitted.clear()
    state.inks = inks
    state.placedSignature = ""
  var signature = ""
  var placements: seq[(uint32, int, int)] = @[]
  for s in lay.segments:
    if s.part != tpControl:
      continue
    let on = s.index < enabled.len and enabled[s.index]
    let id = iconImageId(if on: iiEnabled else: iiDisabled, s.index)
    placements.add (id, 0, s.col)
    signature.add $id & "@" & $s.col & ";"
  if signature == state.placedSignature:
    return
  var body = ""
  for id in state.transmitted:
    body.add kittyDeletePlacements(id)
  for (id, row, col) in placements:
    if id notin state.transmitted:
      let ink = if id >= iconImageId(iiDisabled, 0): iiDisabled else: iiEnabled
      let controlIndex = int(id - iconImageId(ink, 0))
      let img = markImage(TransportControls[controlIndex].id,
                          parseHexRgb(inks[ink]))
      body.add kittyTransmitRgba(img, id)
      state.transmitted.incl id
    body.add kittyPlaceAt(id, row, col)
  state.placedSignature = signature
  if wrapForTmux:
    # Each APC through tmux's passthrough, the cursor moves outside it.
    var wrapped = ""
    var i = 0
    while i < body.len:
      let apc = body.find("\x1b_G", i)
      if apc < 0:
        wrapped.add body[i .. ^1]
        break
      wrapped.add body[i ..< apc]
      let stop = body.find("\x1b\\", apc) + 2
      var inner = ""
      for ch in body[apc ..< stop]:
        inner.add(if ch == '\x1b': "\x1b\x1b" else: $ch)
      wrapped.add "\x1bPtmux;" & inner & "\x1b\\"
      i = stop
    body = wrapped
  "\x1b7" & body & "\x1b8"
