## terminal_graphics/emit.nim — PLAT-14. THE BYTES THAT REACH THE PTY.
##
## Everything in this package above this module produces a MODEL: a tier, a
## fit, a grid of coloured glyphs. This module is the only place that turns one
## into a byte string, and it is therefore the only place a test has to assert
## against in order to be asserting the effect rather than the report.
##
## ## ONE UNIT, NAMED ONCE: BYTES WRITTEN TO THE PTY
##
## This campaign has now paid three times for a bound whose unit was not the
## unit its measurement used, and image data is where that is easiest to do:
## the encoded size of a PNG, the pixel count it decodes to, the number of
## cells it occupies and the number of bytes an escape sequence carrying it
## costs are four different numbers, and only the last one is what a link
## transmits. So:
##
##   * `EmittedImage.bytes` IS the string handed to the driver. Nothing
##     downstream reformats it.
##   * `EmittedImage.emittedBytes` is `bytes.len` — the same string's length,
##     computed after the string exists, never estimated from the source.
##   * `MaxLinkImageBytes` is a bound on THAT number and on no other.
##
## Base64 alone inflates by 4/3 and the chunk framing adds ~20 bytes per 4 KiB,
## so a source payload comfortably under the bound routinely emits over it.
## `emit_test.nim` carries that case explicitly — a payload whose source length
## is under the budget and whose emitted length is over it, refused — because
## an implementation that compared the source length would pass every test
## written against a small image.
##
## ## WHY THIS MODULE HAS NO SIBLING-REPO IMPORTS
##
## `nim_termctl/image.nim` already emits Kitty and iTerm2 sequences and is the
## natural thing to call. It is deliberately not called here, for two reasons
## that are about the boundary rather than about the code:
##
##   * `src/common/` is compiled by the `vm-unit-js` lane under `nim js`, and
##     `nim_termctl/image` imports `std/os`.
##   * `emitKittyChunked` bakes `a=T` into the control block and has no `c=` /
##     `r=` cell-extent keys and no way to transmit WITHOUT displaying — and
##     §3's "Kitty's image placement identifiers exist for exactly this and must
##     be used rather than re-uploading" needs `a=p`, which it cannot express.
##
## **The duplication is answered by an assertion rather than by a comment.**
## `src/frontend/tui/tests/test_image_emission.nim` builds the same payload
## through both and asserts the two byte strings are IDENTICAL for the case
## they both express (`a=T`, no cell extents), so a divergence in the chunk
## boundary, the base64 alphabet or the framing reddens a lane instead of
## producing two pictures. That is §14's rule applied to an unavoidable second
## implementation: one of them is graded against the other.

import std/[base64, strutils]

import ./tiers
import ./cell_render
import ./raster

import nim_termctl/sixel
  # The Sixel encoder (`encodeSixel`): pure Nim, no I/O — unlike
  # `nim_termctl/image`, which this module deliberately does not import (see
  # the header).

type
  ColourWriting* = enum
    ## How much colour the emission may spend. Mapped from
    ## `app/theme/capabilities.ColorDepth` by the front-end; spelled separately
    ## here because `src/common/` may not import the TUI.
    cwNone       ## no SGR colour at all — `TERM=dumb`, `--no-color`
    cwAnsi256
    cwTrueColor

  EmittedImage* = object
    bytes*: string
      ## EXACTLY what is written to the terminal. Not a summary, not a
      ## rendering of it.
    tier*: ImageTier
    protocol*: ImageProtocol
      ## `ipNone` for every cell tier.
    placementReused*: bool
      ## Whether this emission RE-PLACED an image the terminal already holds
      ## instead of re-transmitting it — §3's requirement that "a scrub must
      ## not re-transmit an unchanged image".
    imageId*: uint32
      ## The Kitty image id the payload was stored under, or 0.
    wrappedForMultiplexer*: bool

  EmitError* = object of CatchableError

  ProtocolPlacement* = enum
    ## WHERE a tier-0 image goes, which decides the keys around the payload.
    ppAtCursor
      ## At the cursor, as the protocol's defaults have it: Kitty answers
      ## `OK`, moves the cursor past the image and names no placement; iTerm2
      ## sizes the image itself. The shape `nim_termctl` emits, kept
      ## byte-identical to it (see the header).
    ppReservedCells
      ## Over a rectangle of cells a PANE reserved and keeps repainting
      ## around — the Video Player's frame (`host/frame_image.nim`). Kitty
      ## names the placement (`p=`) so a re-placement replaces it, keeps the
      ## cursor where it was (`C=1`, so an image on the last rows cannot
      ## scroll the screen) and stays quiet (`q=2`, so no `OK` reaches the
      ## keymap); iTerm2 is sized to the cells (`width=` / `height=`,
      ## `preserveAspectRatio=0`); and under tmux each escape is wrapped on its
      ## own (`tmuxPassthroughEach`).

const
  MaxLinkImageBytes* = 262_144
    ## The most EMITTED BYTES one tier-0 image may cost on a link this build
    ## considers constrained (an SSH session — see
    ## `app/theme/image_capability.nim`).
    ##
    ## THE UNIT IS THE ONE IN THIS MODULE'S HEADER: the length of the escape
    ## sequence, measured after it is built. Not the source payload, not the
    ## pixel count, not the cells occupied.
    ##
    ## WHY 256 KiB. §3's constraint is stated as a rate problem — "an image
    ## redrawn on every scrub step at tier 0 can be megabytes" — and the
    ## placement-identifier rule below removes the *per step* half of it: after
    ## the first emission a scrub costs a placement escape of well under a
    ## hundred bytes. What is left is the one-off cost of the first frame, and
    ## 256 KiB is ~0.2 s on a 10 Mbit/s link, which is the order of a frame the
    ## user asked for. Above it, a cell tier is both smaller and immediate.
    ##
    ## IT IS A CEILING AND NOT A TARGET. Nothing is padded to reach it, and a
    ## rendering that costs less is not improved by the difference.

  KittyChunkBytes* = 4096
    ## Kitty's documented maximum base64 payload per APC chunk. Identical to
    ## `nim_termctl.kittyChunkBytes`, and the test named in this module's header
    ## is what keeps the two equal.

  ApcPrefix* = "\x1b_G"
  StringTerminator* = "\x1b\\"
  TmuxPassthroughOpen* = "\x1bPtmux;"

func tmuxPassthrough*(payload: string): string =
  ## §3: tmux "requires explicit passthrough for Kitty and Sixel".
  ##
  ## `DCS tmux ; <payload with every ESC doubled> ST`, per tmux(1)'s
  ## `allow-passthrough`. The doubling is the whole of the encoding and it is
  ## why this is a function rather than a concatenation at the call site: an
  ## escape that was wrapped but not doubled is delivered to the outer terminal
  ## truncated at the first `ESC \`, which is the "garbage on the user's
  ## screen" outcome §3 names as worse than a low-fidelity picture.
  var inner = ""
  for ch in payload:
    if ch == '\x1b':
      inner.add "\x1b\x1b"
    else:
      inner.add ch
  TmuxPassthroughOpen & inner & StringTerminator

func tmuxPassthroughEach*(body: string): string =
  ## `tmuxPassthrough` applied to EACH graphics escape in `body` — every Kitty
  ## APC (`ESC _ G … ESC \`) and iTerm2 OSC 1337 (`ESC ] 1337 ; … BEL`) — with
  ## everything between them (cursor moves, saves and restores) left outside.
  ##
  ## One passthrough per escape rather than one around the lot: a chunked
  ## transmission is many APCs, and a cursor move inside a passthrough would
  ## move the OUTER terminal's cursor rather than the pane's.
  var i = 0
  while i < body.len:
    let apc = body.find(ApcPrefix, i)
    let osc = body.find("\x1b]1337;", i)
    var start = -1
    if apc >= 0 and (osc < 0 or apc < osc): start = apc
    elif osc >= 0: start = osc
    if start < 0:
      result.add body[i .. ^1]
      break
    result.add body[i ..< start]
    let stop =
      if start == apc: body.find(StringTerminator, start) + StringTerminator.len
      else: body.find('\x07', start) + 1
    result.add tmuxPassthrough(body[start ..< stop])
    i = stop

func kittyControl(keys: seq[string]): string =
  keys.join(",")

func kittyTransmit*(payload: openArray[byte]; imageId: uint32;
                    cols = 0; rows = 0; placementId = 0'u32;
                    holdCursor = false; quiet = false): string =
  ## `a=T` — transmit AND display, chunked at `KittyChunkBytes` of base64.
  ##
  ## With `cols == 0` and `rows == 0` and none of the placement keys the
  ## result is byte-identical to `nim_termctl.emitKittyChunked`; see this
  ## module's header for the assertion that keeps it so. `placementId`,
  ## `holdCursor` (`C=1`) and `quiet` (`q=2`, on every chunk) are
  ## `ppReservedCells`' keys.
  if payload.len == 0:
    raise newException(EmitError, "kitty transmit: empty payload")
  let b64 = base64.encode(payload)
  var buf = ""
  var pos = 0
  while pos < b64.len:
    let chunkEnd = min(pos + KittyChunkBytes, b64.len)
    let isLast = chunkEnd >= b64.len
    let more = if isLast: 0 else: 1
    var ctrl: seq[string] = @[]
    if pos == 0:
      ctrl.add "a=T"
      ctrl.add "f=100"
      if imageId != 0: ctrl.add "i=" & $imageId
      if placementId != 0: ctrl.add "p=" & $placementId
      if cols > 0: ctrl.add "c=" & $cols
      if rows > 0: ctrl.add "r=" & $rows
      if holdCursor: ctrl.add "C=1"
      ctrl.add "m=" & $more
    else:
      ctrl.add "m=" & $more
    if quiet: ctrl.add "q=2"
    buf.add ApcPrefix
    buf.add kittyControl(ctrl)
    buf.add ";"
    buf.add b64[pos ..< chunkEnd]
    buf.add StringTerminator
    pos = chunkEnd
  buf

func kittyPlace*(imageId: uint32; placementId: uint32;
                 cols = 0; rows = 0; holdCursor = false;
                 quiet = false): string =
  ## `a=p` — display an image the terminal ALREADY HOLDS, by id.
  ##
  ## §3: *"a scrub must not re-transmit an unchanged image. Kitty's image
  ## placement identifiers exist for exactly this and must be used rather than
  ## re-uploading."* This is that escape, and its length is bounded by the
  ## decimal widths of two 32-bit ids and two extents — under 64 bytes for
  ## every value it can take — which is what makes the scrub claim a claim
  ## about BYTES rather than about an intention.
  if imageId == 0:
    raise newException(EmitError,
      "kitty placement needs a non-zero image id; id 0 is 'let the terminal " &
      "choose', which cannot be referred to later")
  var ctrl: seq[string] = @["a=p", "i=" & $imageId, "p=" & $placementId]
  if cols > 0: ctrl.add "c=" & $cols
  if rows > 0: ctrl.add "r=" & $rows
  if holdCursor: ctrl.add "C=1"
  if quiet: ctrl.add "q=2"
  ApcPrefix & kittyControl(ctrl) & StringTerminator

func kittyDelete*(imageId: uint32; quiet = false): string =
  ## Take down every placement of image `imageId`, keeping its data, so a
  ## later `a=p` can show it again without a re-upload.
  ##
  ## `d=i` IS REQUIRED. Without a `d` key Kitty's delete defaults to `d=a` —
  ## every placement on the screen — and ignores `i=`, so the bare
  ## `a=d,i=<id>` this function used to write would also have taken down the
  ## controls' pictures (`host/control_icons.nim`).
  ApcPrefix & "a=d,d=i,i=" & $imageId & (if quiet: ",q=2" else: "") &
    StringTerminator

func iterm2Inline*(payload: openArray[byte]; cols = 0; rows = 0): string =
  ## iTerm2's `OSC 1337 ; File=inline=1`. Byte-identical to
  ## `nim_termctl.emitITerm2Inline` with no extent; same assertion, same
  ## reason. With `cols` and `rows` the image is sized to that many cells and
  ## stretched to fill them (`preserveAspectRatio=0`) — `ppReservedCells`.
  ##
  ## THERE IS NO PLACEMENT ID IN THIS PROTOCOL. iTerm2 inline images are a
  ## stream of bytes at the cursor with no addressable registry, so every draw
  ## re-transmits and `EmittedImage.placementReused` is false for every iTerm2
  ## emission there will ever be. That is a property of the protocol rather
  ## than of this code, it is why §3's bandwidth rule bites harder on iTerm2
  ## than on Kitty, and `emit_test.nim` asserts it rather than leaving a reader
  ## to infer it from the absence of a branch.
  var keys = "File=inline=1;size=" & $payload.len
  if cols > 0 and rows > 0:
    keys.add ";width=" & $cols & ";height=" & $rows & ";preserveAspectRatio=0"
  "\x1b]1337;" & keys & ":" & base64.encode(payload) & "\x07"

func sgrColour(c: Rgb; foreground: bool; writing: ColourWriting): string =
  case writing
  of cwNone: ""
  of cwTrueColor:
    (if foreground: "\x1b[38;2;" else: "\x1b[48;2;") &
      $int(c.r) & ";" & $int(c.g) & ";" & $int(c.b) & "m"
  of cwAnsi256:
    # The 6x6x6 cube. The 24-step grey ramp is deliberately not used: a cell
    # rendering's two colours are means of a photograph's pixels and land on
    # the cube's grey diagonal anyway, and a second quantiser choosing between
    # cube and ramp per colour is a second decision that would have to agree
    # with the error metric that picked the colour in the first place.
    let r6 = int(c.r) * 5 div 255
    let g6 = int(c.g) * 5 div 255
    let b6 = int(c.b) * 5 div 255
    (if foreground: "\x1b[38;5;" else: "\x1b[48;5;") &
      $(16 + 36 * r6 + 6 * g6 + b6) & "m"

func emitCellGrid*(grid: CellGrid; writing: ColourWriting;
                   originRow = 0; originCol = 0): string =
  ## A rendered grid as the bytes a terminal draws it from.
  ##
  ## ## SGR IS EMITTED ON CHANGE ONLY
  ##
  ## A cell whose foreground and background match the previous cell's costs one
  ## glyph. That is not an optimisation for its own sake: §3's bandwidth
  ## constraint applies to cell tiers as well, and a flat region of an image is
  ## exactly where a naive emitter spends twenty bytes per cell saying the same
  ## thing. The state is reset at the end of EVERY ROW rather than carried
  ## across the cursor move, because a row that inherited the previous row's
  ## background would paint it into the gap when the terminal wraps.
  ##
  ## `originRow`/`originCol` are 1-based when positive; 0 means "wherever the
  ## cursor is", and then rows are separated by CR+LF.
  var buf = ""
  var haveFg = false
  var haveBg = false
  var lastFg = Rgb()
  var lastBg = Rgb()
  for row in 0 ..< grid.rows:
    if originRow > 0 and originCol > 0:
      buf.add "\x1b[" & $(originRow + row) & ";" & $originCol & "H"
    elif row > 0:
      buf.add "\r\n"
    haveFg = false
    haveBg = false
    for col in 0 ..< grid.cols:
      let cell = grid.cellAt(col, row)
      if writing != cwNone:
        if not haveFg or cell.fg != lastFg:
          buf.add sgrColour(cell.fg, true, writing)
          lastFg = cell.fg
          haveFg = true
        # THE ASCII TIER CARRIES NO BACKGROUND, and the suppression is here
        # rather than in `cell_render` because it is a fact about the BYTES.
        # §2.5's ramp puts the whole picture in the GLYPH — `renderCells` leaves
        # an ASCII cell's `bg` at the zero `Rgb`, which is not "black the image
        # asked for", it is "no opinion". Emitting it would paint a black
        # rectangle over whatever the user's terminal background is, at every
        # cell, which is a DIFFERENT picture and not a coarser one — precisely
        # what §2.5 forbids for the tier that exists for `TERM=dumb` and CI
        # logs. `emit_test.nim`'s ASCII case asserts the absence with a
        # half-block emission of the same picture beside it as the positive
        # twin, so "no background" is distinguishable from "this emitter has
        # stopped writing backgrounds".
        if grid.tier != itAscii and (not haveBg or cell.bg != lastBg):
          buf.add sgrColour(cell.bg, false, writing)
          lastBg = cell.bg
          haveBg = true
      buf.add cell.glyph
    if writing != cwNone:
      buf.add "\x1b[0m"
  buf

func emitCellImage*(grid: CellGrid; writing: ColourWriting;
                    originRow = 0; originCol = 0): EmittedImage =
  EmittedImage(bytes: emitCellGrid(grid, writing, originRow, originCol),
               tier: grid.tier, protocol: ipNone, placementReused: false,
               imageId: 0, wrappedForMultiplexer: false)

func emitProtocolImage*(protocol: ImageProtocol; payload: openArray[byte];
                        imageId: uint32; placementId: uint32;
                        cols, rows: int; alreadyUploaded: bool;
                        wrapForTmux = false;
                        placement = ppAtCursor): EmittedImage =
  ## §2.1's tier 0, and §3's placement rule.
  ##
  ## `payload` is the ENCODED image (a PNG: Kitty's `f=100`, iTerm2's
  ## `File=inline`) — both protocols decode in the terminal.
  ## `alreadyUploaded` is the caller's record that THIS terminal already holds
  ## THIS image under `imageId` — the scrub case. On Kitty it produces a
  ## placement escape and no payload at all; on iTerm2 it cannot, and the
  ## re-transmission is reported rather than hidden (see `iterm2Inline`).
  ## `placement` says where the image goes (`ProtocolPlacement`).
  let reserved = placement == ppReservedCells
  var body = ""
  var reused = false
  case protocol
  of ipKitty:
    if alreadyUploaded:
      body = kittyPlace(imageId, placementId, cols, rows,
                        holdCursor = reserved, quiet = reserved)
      reused = true
    else:
      body = kittyTransmit(payload, imageId, cols, rows,
                           placementId = (if reserved: placementId else: 0),
                           holdCursor = reserved, quiet = reserved)
  of ipITerm2:
    body = if reserved: iterm2Inline(payload, cols, rows)
           else: iterm2Inline(payload)
  of ipSixel:
    raise newException(EmitError,
      "a Sixel emission carries PIXELS, and this payload is an encoded " &
      "image: decode it (common/png.decodePng) and call emitSixelImage")
  of ipNone:
    raise newException(EmitError,
      "emitProtocolImage called with ipNone; a cell tier is emitCellImage")
  if wrapForTmux:
    body = if reserved: tmuxPassthroughEach(body) else: tmuxPassthrough(body)
  EmittedImage(bytes: body, tier: itProtocol, protocol: protocol,
               placementReused: reused, imageId: imageId,
               wrappedForMultiplexer: wrapForTmux)

const
  DefaultSixelCellPx* = (10, 20)
    ## The cell, in device pixels, a Sixel picture is sized against when the
    ## terminal did not report its own (`CSI 16 t`). Sixel draws at the
    ## terminal's pixel resolution — unlike Kitty's `c=`/`r=` and iTerm2's
    ## cell sizes, which the terminal scales into — so the picture's pixel
    ## extent has to be chosen here, and 10x20 is the commonest VT340-style
    ## cell. A terminal that reports its cell is drawn at its real size.

func scaledTo*(img: RgbaImage; width, height: int): RgbaImage =
  ## `img` resampled to `width` x `height`: each target pixel the box mean of
  ## the source rectangle it covers (at least one source pixel), so a
  ## down-scale averages and an up-scale repeats.
  var px = newSeq[byte](width * height * 4)
  for y in 0 ..< height:
    let y0 = y * img.height div height
    let y1 = max(y0 + 1, (y + 1) * img.height div height)
    for x in 0 ..< width:
      let x0 = x * img.width div width
      let x1 = max(x0 + 1, (x + 1) * img.width div width)
      let c = img.boxSample(x0, y0, x1, y1)
      let i = (y * width + x) * 4
      px[i] = c.r
      px[i + 1] = c.g
      px[i + 2] = c.b
      px[i + 3] = 255
  initRgbaImage(width, height, px)

func emitSixelImage*(img: RgbaImage; cols, rows: int;
                     cellWidthPx, cellHeightPx: int;
                     wrapForTmux = false): EmittedImage =
  ## §2.1's tier 0 on a SIXEL terminal: `img` resampled to fill `cols` x
  ## `rows` cells of `cellWidthPx` x `cellHeightPx` pixels, encoded by
  ## `nim_termctl/sixel.encodeSixel` (every colour kept up to 256; a
  ## median-cut palette, Floyd–Steinberg dithered, above that).
  ##
  ## Sixel has no placement registry: every draw re-transmits, as iTerm2's
  ## does, and `placementReused` is false for every Sixel emission.
  if cols <= 0 or rows <= 0 or cellWidthPx <= 0 or cellHeightPx <= 0:
    raise newException(EmitError, "a Sixel emission needs a positive cell " &
      "extent and cell size, got " & $cols & "x" & $rows & " cells of " &
      $cellWidthPx & "x" & $cellHeightPx & " px")
  let scaled = img.scaledTo(cols * cellWidthPx, rows * cellHeightPx)
  var body = ""
  try:
    body = encodeSixel(scaled.pixels, scaled.width, scaled.height)
  except SixelError as e:
    raise newException(EmitError, e.msg)
  if wrapForTmux:
    body = tmuxPassthrough(body)
  EmittedImage(bytes: body, tier: itProtocol, protocol: ipSixel,
               placementReused: false, imageId: 0,
               wrappedForMultiplexer: wrapForTmux)

func emittedBytes*(e: EmittedImage): int {.inline.} = e.bytes.len
  ## The measurement `MaxLinkImageBytes` bounds, and the only one. See the
  ## module header.

func fitsLinkBudget*(e: EmittedImage; budget = MaxLinkImageBytes): bool =
  ## Whether this emission is small enough for a constrained link.
  ##
  ## TAKES THE EMISSION AND NOT A LENGTH, so a caller cannot pass the source
  ## payload's size by accident — the parameter's type is what stops the
  ## wrong-unit comparison rather than a comment asking for the right one.
  e.emittedBytes <= budget

func containsGraphicsEscape*(s: string): bool =
  ## Whether a byte string carries a graphics-protocol introducer.
  ##
  ## THE SCANNER FOR §3'S "never leave escape bytes on screen" RULE, and it is
  ## a function rather than three `contains` calls at a call site for
  ## Verification-Harness-Traps §7a's reason: a "must not contain" check is
  ## satisfied by a scanner that finds nothing, so the rule and its POSITIVE
  ## CONTROL have to be the same predicate. `test_image_capability.nim` calls
  ## this on a stream that is known to carry one before it calls it on the
  ## stream that must not.
  s.contains(ApcPrefix) or s.contains("\x1b]1337") or s.contains("\x1bP")
