## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header for the full rule.
##
## host/frame_image.nim — PLAT-59. THE VIDEO PLAYER'S FRAME AT TIER 0: the
## frame's pixels TRANSMITTED to a terminal that draws pictures, over the cells
## the pane reserved (`FrameViewerScreen.protocolRect`).
##
## CodeTracer-TUI-Graphics.md §4's callout said the pane could not paint a
## tier-0 frame because "nothing in this build sends a tier-0 payload for this
## pane" — a missing PRODUCER. The Video Player now holds the frame's pixels
## (`VisualReplayPanesVM`, from the player), so this module is the sender, on
## `host/control_icons`' terms:
##
##   * **Kitty**: the RGBA pixels as they are (`f=32`, `s=`/`v=` the pixel
##     size), transmitted ONCE per frame under one image id (`a=t`; a new frame
##     replaces the old one's data), then PLACED (`a=p`) with `c=`/`r=` the
##     reserved cells — the terminal scales it into them — and `C=1`, so the
##     cursor does not move; `q=2` on every command, so no `OK` comes back to
##     reach the keymap. A frame that did not move re-sends nothing: the
##     placement persists while the cells beneath are repainted. When the
##     rectangle goes (the pane hidden, the picker's magnifier open) the
##     placement is deleted by id (`a=d,d=i`).
##   * **iTerm2**: the frame as a PNG (`common/png`), inline at the reserved
##     cells' first cell, sized in cells (`width=` / `height=`,
##     `preserveAspectRatio=0`). iTerm2 has no placement registry (`emit.nim`'s
##     `iterm2Inline`), so a changed frame or rectangle re-sends the image; an
##     unchanged one sends nothing.
##
## The cursor is saved and restored around every placement. Everything here is
## a string builder over values; `main.nim` writes the result after a frame.

import std/[base64, strutils]

import ../../../common/png
import ../../../common/terminal_graphics/tiers
import ../app/layout/cells
import ../app/views/frame_viewer

const
  FrameImageId* = 4900'u32
    ## The frame's image id on a Kitty terminal: fixed, so a test can find
    ## the frame by it, and clear of `control_icons`' ids (4800 and up, ten
    ## per ink).
  KittyChunk = 4096

type
  FrameImageState* = object
    ## What this terminal holds of the frame.
    key*: string
      ## The raster transmitted (`FrameViewerModel.rasterKey`), "" for none.
    placed*: CellArea
      ## Where it is placed; empty when it is not.
    protocol*: ImageProtocol

func isEmptyArea(a: CellArea): bool = a.width <= 0 or a.height <= 0

proc tmuxWrap(body: string): string =
  ## Each graphics sequence through tmux's passthrough (`control_icons`' rule:
  ## the cursor moves stay outside it) — Kitty's APCs and iTerm2's OSC 1337.
  var i = 0
  while i < body.len:
    let apc = body.find("\x1b_G", i)
    let osc = body.find("\x1b]1337;", i)
    var start = -1
    if apc >= 0 and (osc < 0 or apc < osc): start = apc
    elif osc >= 0: start = osc
    if start < 0:
      result.add body[i .. ^1]
      break
    result.add body[i ..< start]
    let stop =
      if start == apc: body.find("\x1b\\", start) + 2
      else: body.find("\x07", start) + 1
    var inner = ""
    for ch in body[start ..< stop]:
      inner.add(if ch == '\x1b': "\x1b\x1b" else: $ch)
    result.add "\x1bPtmux;" & inner & "\x1b\\"
    i = stop

proc kittyTransmitFrame(pixels: openArray[byte]; width, height: int): string =
  ## `a=t` (store, do not display), raw RGBA, quiet, chunked.
  let b64 = base64.encode(pixels)
  var pos = 0
  while pos < b64.len:
    let stop = min(pos + KittyChunk, b64.len)
    let more = if stop < b64.len: 1 else: 0
    if pos == 0:
      result.add "\x1b_Ga=t,f=32,s=" & $width & ",v=" & $height & ",i=" &
                 $FrameImageId & ",q=2,m=" & $more & ";" & b64[pos ..< stop] &
                 "\x1b\\"
    else:
      result.add "\x1b_Gm=" & $more & ",q=2;" & b64[pos ..< stop] & "\x1b\\"
    pos = stop

func kittyPlaceFrame(rect: CellArea): string =
  "\x1b[" & $(rect.row + 1) & ";" & $(rect.col + 1) & "H" &
    "\x1b_Ga=p,i=" & $FrameImageId & ",p=1,c=" & $rect.width & ",r=" &
    $rect.height & ",C=1,q=2\x1b\\"

func kittyDeleteFrame(): string =
  "\x1b_Ga=d,d=i,i=" & $FrameImageId & ",q=2\x1b\\"

proc iterm2Frame(model: FrameViewerModel; rect: CellArea): string =
  let encoded = encodePng(model.raster.width, model.raster.height,
                          model.raster.pixels)
  "\x1b[" & $(rect.row + 1) & ";" & $(rect.col + 1) & "H" &
    "\x1b]1337;File=inline=1;size=" & $encoded.len & ";width=" &
    $rect.width & ";height=" & $rect.height & ";preserveAspectRatio=0:" &
    base64.encode(encoded) & "\x07"

proc frameImageBytes*(state: var FrameImageState; rect: CellArea;
                      model: FrameViewerModel): string =
  ## The bytes that put the Video Player's frame over `rect` (the pane's
  ## `protocolRect`) — "" when nothing changed since the last call. An empty
  ## `rect` takes a placed frame down.
  let protocol = model.capability.protocol
  if rect.isEmptyArea or not model.hasRaster or
     protocol notin {ipKitty, ipITerm2}:
    if not state.placed.isEmptyArea and state.protocol == ipKitty:
      result = kittyDeleteFrame()
    state.placed = CellArea()
    if protocol != ipKitty:
      state.key = ""
    return
  if model.rasterKey == state.key and rect == state.placed and
     protocol == state.protocol:
    return
  var body = ""
  case protocol
  of ipKitty:
    if not state.placed.isEmptyArea:
      body.add kittyDeleteFrame()
    if model.rasterKey != state.key or state.protocol != ipKitty:
      body.add kittyTransmitFrame(model.raster.pixels, model.raster.width,
                                  model.raster.height)
    body.add kittyPlaceFrame(rect)
  of ipITerm2:
    body.add iterm2Frame(model, rect)
  else: discard
  state.key = model.rasterKey
  state.placed = rect
  state.protocol = protocol
  if model.capability.wrapForMultiplexer:
    body = tmuxWrap(body)
  "\x1b7" & body & "\x1b8"
