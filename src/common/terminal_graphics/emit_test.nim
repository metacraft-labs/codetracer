## emit_test.nim — PLAT-14. THE BYTES, asserted as bytes.
##
## `CodeTracer-TUI-Graphics.md` §3 and §7. Every claim this milestone makes
## about what a terminal is told is a claim about a byte string, and this file
## asserts the byte strings — not a status, not a flag, not a count of
## emissions.
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is none. The payloads are byte sequences, the emitter is the product's
## own, and the expected strings below are WRITTEN OUT rather than produced by
## calling the function under test — `QUJD` is base64 for the three bytes
## `A B C`, computed by hand, so the encoder is compared with the standard
## rather than with itself. Where a payload is too long to write out (the
## chunking case, the link-budget case) the check is a DECODE, which is the
## inverse function and not the same one.
##
## ## THE UNIT IS BYTES WRITTEN TO THE PTY, AND ONE CASE EXISTS ONLY TO SAY SO
##
## "a payload under the budget whose EMISSION is over it" is the case that
## separates a bound on the right quantity from a bound on a quantity that
## correlates with it. Base64 inflates 4/3 and the chunk framing adds more, so
## a 200,000-byte image emits over 266,000 bytes — under a 262,144-byte budget
## by one measure and over it by the one that matters. Both numbers are
## asserted in that case, beside each other, so a reader can see which one the
## decision used.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)

import std/[base64, strutils, unittest]

import ../terminal_graphics

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const ExpectedAssertions = 72
  ## Written from a run. See the final case.

const
  Abc = [0x41'u8, 0x42'u8, 0x43'u8]
    ## The bytes `A B C`. Base64: `QUJD`, computed by hand — 0x41,0x42,0x43 is
    ## 010000 010100 001001 000011, which is 16, 20, 9, 3, which is Q U J D.
  AbcBase64 = "QUJD"
  Red = Rgb(r: 255, g: 0, b: 0)
  Blue = Rgb(r: 0, g: 0, b: 255)

proc bandsImage(top, bottom: Rgb): RgbaImage =
  var px = newSeq[byte](2 * 2 * 4)
  for y in 0 ..< 2:
    let c = if y == 0: top else: bottom
    for x in 0 ..< 2:
      let i = (y * 2 + x) * 4
      px[i] = c.r
      px[i + 1] = c.g
      px[i + 2] = c.b
      px[i + 3] = 255'u8
  initRgbaImage(2, 2, px)

const OneCell = CellFit(cols: 1, rows: 1, aspect: DefaultCellAspect,
                        sourceWidth: 2, sourceHeight: 2, corrected: false)

suite "PLAT-14: the tier-0 escape sequences, byte for byte":

  test "a Kitty transmission is the documented APC, written out":
    ckEq kittyTransmit(Abc, 7),
         "\x1b_Ga=T,f=100,i=7,m=0;" & AbcBase64 & "\x1b\\"
    # WITH cell extents, which is the half `nim_termctl.emitKittyChunked`
    # cannot express and the reason this emitter exists beside it.
    ckEq kittyTransmit(Abc, 7, cols = 10, rows = 5),
         "\x1b_Ga=T,f=100,i=7,c=10,r=5,m=0;" & AbcBase64 & "\x1b\\"
    # An id of 0 means "let the terminal choose", which cannot be placed later,
    # so the key is omitted rather than written as `i=0`.
    ckEq kittyTransmit(Abc, 0), "\x1b_Ga=T,f=100,m=0;" & AbcBase64 & "\x1b\\"
    # An empty payload is refused: a zero-byte image is not a picture, and a
    # terminal handed `;` with nothing after it is handed a malformed APC.
    var refused = false
    try:
      discard kittyTransmit([], 1)
    except EmitError as e:
      refused = e.msg.contains("empty payload")
    ck refused

  test "a payload over one chunk is split at exactly the documented size":
    # 4096 base64 characters per chunk. 6144 source bytes are 8192 base64
    # characters, which is exactly two full chunks — the boundary case, where
    # an off-by-one produces a third chunk carrying nothing.
    var payload = newSeq[byte](6144)
    for i in 0 ..< payload.len: payload[i] = byte(i mod 251)
    let bytes = kittyTransmit(payload, 3)
    var chunks = 0
    var recovered = ""
    var pos = 0
    while true:
      let start = bytes.find("\x1b_G", pos)
      if start < 0: break
      let semi = bytes.find(';', start)
      let stop = bytes.find("\x1b\\", semi)
      let control = bytes[start + 3 ..< semi]
      recovered.add bytes[semi + 1 ..< stop]
      if chunks == 0:
        ck control.startsWith("a=T,f=100,i=3")
        ck control.endsWith("m=1")
      else:
        ckEq control, "m=0"
      # NO CHUNK MAY EXCEED THE DOCUMENTED SIZE, asserted per chunk. The chunk
      # COUNT cannot see this: 8192 base64 characters split at 4097 is still
      # two chunks, and the decode below still recovers the payload — so an
      # off-by-one that violates Kitty's 4096-byte limit passes both. A
      # mutation adding 1 to the boundary survived a 15-case suite until this
      # line existed.
      ck stop - semi - 1 <= KittyChunkBytes
      inc chunks
      pos = stop + 2
    ckEq chunks, 2
    # …and the FIRST chunk is exactly full, which is what makes two chunks the
    # right answer rather than an accident of a smaller split.
    let firstSemi = bytes.find(';')
    ckEq bytes.find("\x1b\\", firstSemi) - firstSemi - 1, KittyChunkBytes
    # THE INVERSE FUNCTION, not the same one: the chunks decode back to the
    # payload, so the split lost nothing and reordered nothing.
    ckEq recovered.len, 8192
    let decoded = base64.decode(recovered)
    ckEq decoded.len, payload.len
    var identical = true
    for i in 0 ..< payload.len:
      if byte(decoded[i]) != payload[i]: identical = false
    ck identical

  test "a placement re-displays without the payload, in under 64 bytes":
    let place = kittyPlace(7, 1, cols = 10, rows = 5)
    ckEq place, "\x1b_Ga=p,i=7,p=1,c=10,r=5\x1b\\"
    ck place.len < 64
    # THE POINT OF §3'S PLACEMENT RULE, as a byte assertion: the payload is not
    # in it. A "placement" that re-uploaded would contain the base64.
    ck not place.contains(AbcBase64)
    ckEq kittyPlace(7, 1), "\x1b_Ga=p,i=7,p=1\x1b\\"
    # Id 0 cannot be placed — there is nothing to refer to.
    var refused = false
    try:
      discard kittyPlace(0, 1)
    except EmitError as e:
      refused = e.msg.contains("non-zero image id")
    ck refused

  test "an iTerm2 inline image is the documented OSC, written out":
    ckEq iterm2Inline(Abc),
         "\x1b]1337;File=inline=1;size=3:" & AbcBase64 & "\x07"
    ckEq kittyDelete(7), "\x1b_Ga=d,i=7\x1b\\"

  test "tmux passthrough doubles every ESC, and only ESC":
    let inner = kittyPlace(7, 1)
    let wrapped = tmuxPassthrough(inner)
    ck wrapped.startsWith("\x1bPtmux;")
    ck wrapped.endsWith("\x1b\\")
    # EVERY escape in the payload is doubled — an escape that was wrapped but
    # not doubled is delivered truncated at the first `ESC \`, which is §3's
    # "garbage on the user's screen".
    ckEq wrapped, "\x1bPtmux;" & inner.replace("\x1b", "\x1b\x1b") & "\x1b\\"
    # …and a payload with no ESC in it is carried unchanged between the
    # brackets, which is the falsifying twin: a wrapper that doubled
    # indiscriminately would fail here.
    ckEq tmuxPassthrough("hello"), "\x1bPtmux;hello\x1b\\"

suite "PLAT-14: the cell-tier bytes":

  test "one half-block cell is one SGR pair and one glyph":
    let grid = renderCells(bandsImage(Red, Blue), itHalfBlock, OneCell)
    ckEq emitCellGrid(grid, cwTrueColor),
         "\x1b[38;2;255;0;0m\x1b[48;2;0;0;255m▀\x1b[0m"
    # The 256-colour rung is a different string, not a silently identical one.
    ckEq emitCellGrid(grid, cwAnsi256), "\x1b[38;5;196m\x1b[48;5;21m▀\x1b[0m"
    # …and with no colour at all there is no escape byte in the output.
    ckEq emitCellGrid(grid, cwNone), "▀"
    ck not emitCellGrid(grid, cwNone).contains("\x1b")

  test "SGR is emitted on change only, so a flat region costs one glyph each":
    var px = newSeq[byte](8 * 2 * 4)
    for i in 0 ..< 8 * 2:
      px[i * 4] = 10'u8
      px[i * 4 + 1] = 20'u8
      px[i * 4 + 2] = 30'u8
      px[i * 4 + 3] = 255'u8
    let flat = initRgbaImage(8, 2, px)
    let fit = CellFit(cols: 4, rows: 1, aspect: DefaultCellAspect,
                      sourceWidth: 8, sourceHeight: 2, corrected: false)
    let grid = renderCells(flat, itHalfBlock, fit)
    let bytes = emitCellGrid(grid, cwTrueColor)
    # FOUR SPACES, not four full blocks, and that is the documented tie-break:
    # a uniform cell has zero error for every mask, and the lowest mask is the
    # empty glyph — one byte instead of three, with the colour carried by the
    # background (see `cell_render.bestTripleFor`).
    ckEq bytes, "\x1b[38;2;10;20;30m\x1b[48;2;10;20;30m    \x1b[0m"
    ckEq bytes.count("\x1b[38;2;"), 1
    ckEq bytes.count("\x1b[48;2;"), 1

  test "an ASCII cell carries a foreground and NO background at all":
    # §2.5's ramp puts the picture in the GLYPH, so `renderCells` leaves an
    # ASCII cell's background at the zero `Rgb` — "no opinion", not "black".
    # An emitter that wrote it would paint a black rectangle over the user's
    # own terminal background at every cell, which is a DIFFERENT picture and
    # not a coarser one. The suppression is one clause in `emitCellGrid` and
    # this case is its only evidence.
    let ramp = renderCells(bandsImage(Red, Blue), itAscii, OneCell)
    let asciiBytes = emitCellGrid(ramp, cwTrueColor)
    ck asciiBytes.contains("\x1b[38;2;")
    ck not asciiBytes.contains("\x1b[48;2;")
    ck not asciiBytes.contains("\x1b[48;")
    # THE POSITIVE TWIN, same emitter, same picture, same predicate: a
    # half-block rendering DOES carry a background, so the absence above is
    # about the tier rather than about an emitter that has stopped writing
    # backgrounds — Verification-Harness-Traps §4a.
    let blocks = renderCells(bandsImage(Red, Blue), itHalfBlock, OneCell)
    let blockBytes = emitCellGrid(blocks, cwTrueColor)
    ck blockBytes.contains("\x1b[48;2;")
    ck asciiBytes != blockBytes
    # …and at the 256-colour rung too, so what is suppressed is the BACKGROUND
    # and not one SGR spelling of it.
    ck not emitCellGrid(ramp, cwAnsi256).contains("\x1b[48;")
    ck emitCellGrid(blocks, cwAnsi256).contains("\x1b[48;5;")

  test "positioned rows carry an absolute cursor move and no CR/LF":
    let grid = renderCells(bandsImage(Red, Blue), itHalfBlock,
                           CellFit(cols: 1, rows: 1, aspect: DefaultCellAspect,
                                   sourceWidth: 2, sourceHeight: 2))
    let positioned = emitCellGrid(grid, cwNone, originRow = 4, originCol = 9)
    ckEq positioned, "\x1b[4;9H▀"
    ck not positioned.contains("\r\n")
    # UNPOSITIONED, the rows are separated by CR+LF and the first carries no
    # move — the two modes are genuinely different strings.
    ck not emitCellGrid(grid, cwNone).contains("\x1b[")

suite "PLAT-14 §3: the scrub does not re-transmit":

  test "the second emission of one image carries no payload at all":
    let first = emitProtocolImage(ipKitty, Abc, imageId = 9, placementId = 1,
                                  cols = 4, rows = 2, alreadyUploaded = false)
    ck first.bytes.contains(AbcBase64)
    ck not first.placementReused
    ckEq first.tier, itProtocol
    ckEq first.protocol, ipKitty

    let second = emitProtocolImage(ipKitty, Abc, imageId = 9, placementId = 1,
                                   cols = 4, rows = 2, alreadyUploaded = true)
    ck second.placementReused
    # THE CLAIM, AS BYTES: the payload is not in the second emission, and the
    # second emission is shorter than the first. Both, because "shorter" alone
    # is satisfied by a smaller re-upload.
    ck not second.bytes.contains(AbcBase64)
    ck second.emittedBytes < first.emittedBytes
    ckEq second.bytes, "\x1b_Ga=p,i=9,p=1,c=4,r=2\x1b\\"

  test "iTerm2 CANNOT reuse, and reports the re-transmission":
    # A property of the protocol rather than of this code — iTerm2 inline
    # images have no addressable registry. Asserted so the difference between
    # the two protocols is a fact in the suite rather than an inference from a
    # missing branch.
    let again = emitProtocolImage(ipITerm2, Abc, imageId = 9, placementId = 1,
                                  cols = 4, rows = 2, alreadyUploaded = true)
    ck not again.placementReused
    ck again.bytes.contains(AbcBase64)

  test "a tmux-wrapped emission is the same picture inside a DCS":
    let wrapped = emitProtocolImage(ipKitty, Abc, imageId = 9, placementId = 1,
                                    cols = 0, rows = 0,
                                    alreadyUploaded = false,
                                    wrapForTmux = true)
    ck wrapped.wrappedForMultiplexer
    ckEq wrapped.bytes, tmuxPassthrough(kittyTransmit(Abc, 9))
    let bare = emitProtocolImage(ipKitty, Abc, imageId = 9, placementId = 1,
                                 cols = 0, rows = 0, alreadyUploaded = false)
    ck not bare.wrappedForMultiplexer
    ck bare.bytes != wrapped.bytes

  test "the two protocols this build cannot emit RAISE rather than emitting":
    var sixel = false
    try:
      discard emitProtocolImage(ipSixel, Abc, 1, 1, 0, 0, false)
    except EmitError as e:
      sixel = e.msg.contains("quantiser")
    ck sixel
    var none = false
    try:
      discard emitProtocolImage(ipNone, Abc, 1, 1, 0, 0, false)
    except EmitError as e:
      none = e.msg.contains("emitCellImage")
    ck none

suite "PLAT-14 §3: the link budget is a bound on EMITTED BYTES":

  test "a payload under the budget whose EMISSION is over it is refused":
    # THE CASE THAT SEPARATES THE TWO QUANTITIES. 200,000 source bytes are
    # under a 262,144-byte budget; their emission is not. Both numbers are
    # asserted here, beside each other.
    var payload = newSeq[byte](200_000)
    for i in 0 ..< payload.len: payload[i] = byte(i mod 251)
    ck payload.len < MaxLinkImageBytes
    let emission = emitProtocolImage(ipKitty, payload, 4, 1, 0, 0, false)
    ck emission.emittedBytes > MaxLinkImageBytes
    ck not emission.fitsLinkBudget()
    # …and the measurement IS the string's length, not an estimate of it.
    ckEq emission.emittedBytes, emission.bytes.len
    # THE POSITIVE TWIN: a small image fits, so the refusal is about the size
    # and not about `fitsLinkBudget` always saying no.
    ck emitProtocolImage(ipKitty, Abc, 4, 1, 0, 0, false).fitsLinkBudget()
    # …and a placement of the SAME large image fits easily, which is why §3's
    # placement rule is what makes a scrub affordable rather than the budget.
    let scrub = emitProtocolImage(ipKitty, payload, 4, 1, 0, 0, true)
    ck scrub.fitsLinkBudget()
    ck scrub.emittedBytes < 64

suite "PLAT-14 §3: the escape scanner can see what it is asked to refuse":

  test "containsGraphicsEscape finds a graphics escape, and only one":
    # Verification-Harness-Traps §7a: a "must not contain" check is satisfied
    # by a scanner that finds nothing. The POSITIVE control comes first and
    # uses the same predicate the negative one does.
    ck containsGraphicsEscape(kittyTransmit(Abc, 1))
    ck containsGraphicsEscape(iterm2Inline(Abc))
    ck containsGraphicsEscape(tmuxPassthrough("x"))
    let cells = emitCellGrid(
      renderCells(bandsImage(Red, Blue), itHalfBlock, OneCell), cwTrueColor)
    ck not containsGraphicsEscape(cells)
    ck cells.contains("\x1b[")
    ck not containsGraphicsEscape("plain text with no escapes")

suite "PLAT-14: the tally":

  test "every assertion in this file ran":
    echo "CHECKS: " & $countedAssertions
    ckEq countedAssertions, ExpectedAssertions
