## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header for the full rule.
##
## host/frame_image.nim — THE VIDEO PLAYER'S FRAME AT TIER 0: the frame's
## pixels TRANSMITTED to a terminal that draws pictures, over the cells the
## pane reserved (`FrameViewerScreen.protocolRect`).
##
## ## EVERY BYTE IS `terminal_graphics/emit.nim`'s
##
## This module decides WHEN something is sent — what the terminal already
## holds, and what changed since — and `emit.emitProtocolImage` decides WHAT
## the bytes are, at `ppReservedCells`. So the frame goes out through the same
## emitter, the same placement ids and the same link budget the image path was
## graded on, rather than a second copy of the escapes beside it:
##
##   * the frame is encoded ONCE as a PNG (`common/png`) and that payload is
##     what both protocols carry — Kitty's `f=100`, iTerm2's `File=inline` —
##     so `EmittedImage.emittedBytes` is the cost of the frame on the wire for
##     either;
##   * **Kitty**: a new frame is transmitted and displayed in one command
##     (`a=T`) under one image id and placement id (`FrameImageId`, `p=1`),
##     with `c=`/`r=` the reserved cells — the terminal scales it into them —
##     `C=1` and `q=2`. A frame that did not move re-sends NOTHING (the
##     placement persists while the cells beneath are repainted), and a moved
##     rectangle with the same frame is re-PLACED (`a=p`), not re-uploaded —
##     §3's scrub rule. When the rectangle goes (the pane hidden, the picker's
##     magnifier open) the placement is deleted by id (`a=d,d=i`);
##   * **iTerm2**: the PNG inline at the reserved cells' first cell, sized in
##     cells. iTerm2 has no placement registry, so a changed frame or
##     rectangle re-sends the image; an unchanged one sends nothing;
##   * **over SSH** a frame whose emission is larger than the link budget
##     (`ImageCapability.linkBudget`, in emitted bytes) is NOT sent — unless
##     `--image-tier=protocol` pinned tier 0, which `demoteForPayload` honours:
##     `FrameImageState.refusedBytes` carries the emission's size and the
##     caller demotes the capability through that same function, so the pane
##     draws the frame as cells instead of reserving blank ones;
##   * under tmux each escape goes through the passthrough on its own
##     (`emit.tmuxPassthroughEach`); the cursor moves stay outside it.
##
## The cursor is saved and restored around every placement. Everything here is
## a string builder over values; `main.nim` writes the result after a frame.

import ../../../common/png
import ../../../common/terminal_graphics/[emit, tiers]
import ../app/layout/cells
import ../app/views/frame_viewer

const
  FrameImageId* = 4900'u32
    ## The frame's image id on a Kitty terminal: fixed, so a test can find
    ## the frame by it, and clear of `control_icons`' ids (4800 and up, ten
    ## per ink).
  FramePlacementId* = 1'u32

type
  FrameImageState* = object
    ## What this terminal holds of the frame.
    key*: string
      ## The raster transmitted (`FrameViewerModel.rasterKey`), "" for none.
    placed*: CellArea
      ## Where it is placed; empty when it is not.
    protocol*: ImageProtocol
    refusedBytes*: int
      ## The emitted size of the last frame the link budget refused, 0 when
      ## the last frame was sent (or nothing was asked). The caller demotes the
      ## capability on it.

func isEmptyArea(a: CellArea): bool = a.width <= 0 or a.height <= 0

func cursorTo(rect: CellArea): string =
  "\x1b[" & $(rect.row + 1) & ";" & $(rect.col + 1) & "H"

proc framePayload(model: FrameViewerModel): string =
  encodePng(model.raster.width, model.raster.height, model.raster.pixels)

proc frameImageBytes*(state: var FrameImageState; rect: CellArea;
                      model: FrameViewerModel): string =
  ## The bytes that put the Video Player's frame over `rect` (the pane's
  ## `protocolRect`) — "" when nothing changed since the last call, or when
  ## the link budget refused the frame (`state.refusedBytes`). An empty
  ## `rect` takes a placed frame down.
  let cap = model.capability
  let protocol = cap.protocol
  state.refusedBytes = 0
  if rect.isEmptyArea or not model.hasRaster or
     protocol notin {ipKitty, ipITerm2}:
    if not state.placed.isEmptyArea and state.protocol == ipKitty:
      result = kittyDelete(FrameImageId, quiet = true)
      if cap.wrapForMultiplexer:
        result = tmuxPassthroughEach(result)
    state.placed = CellArea()
    if protocol != ipKitty:
      state.key = ""
    return
  if model.rasterKey == state.key and rect == state.placed and
     protocol == state.protocol:
    return
  let uploaded = protocol == ipKitty and state.protocol == ipKitty and
                 model.rasterKey == state.key
  let payload = if uploaded: "" else: framePayload(model)
  let emission = emitProtocolImage(
    protocol, payload.toOpenArrayByte(0, payload.len - 1), FrameImageId,
    FramePlacementId, rect.width, rect.height, alreadyUploaded = uploaded,
    wrapForTmux = cap.wrapForMultiplexer, placement = ppReservedCells)
  if demoteForPayload(cap, emission.emittedBytes).tier != itProtocol:
    # §3: the link is constrained and this frame costs more than it allows —
    # asked through `demoteForPayload` itself, so the decision here and the
    # caller's demotion are one predicate (a pinned `--image-tier=protocol`
    # is never demoted, and is sent). Nothing is sent and nothing is
    # recorded as held; the caller demotes the capability and the pane draws
    # the frame as cells.
    state.refusedBytes = emission.emittedBytes
    return
  var body = ""
  if protocol == ipKitty and not state.placed.isEmptyArea and
     state.protocol == ipKitty:
    body.add kittyDelete(FrameImageId, quiet = true)
    if cap.wrapForMultiplexer:
      body = tmuxPassthroughEach(body)
  body.add cursorTo(rect)
  body.add emission.bytes
  state.key = model.rasterKey
  state.placed = rect
  state.protocol = protocol
  "\x1b7" & body & "\x1b8"
