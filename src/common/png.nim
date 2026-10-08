## png.nim — a dependency-free PNG encoder for RGBA8888 buffers.
##
## ## Why this exists
##
## PLAT-35's capture loop needs an image file a human — or a review
## sub-agent — can open, at a named path, produced by the product's own
## process. The GPUI front-end's pixel path
## (`isonim-gpui`'s `gpui_render_to_pixels`) hands back a raw
## RGBA8888 buffer and nothing else, and this repository links no image
## library on the Nim side: there is no `nimPNG`, no `pixie`, and the only
## PNG code anywhere in the tree before this module was a dimension READER
## inside `src/tests/gui/tests/visual/visual-alignment-capture.spec.ts`
## (TypeScript, and a reader). A capture that wrote a PPM would need a
## conversion step in every consumer, and a capture that shelled out to
## `python3 -c 'import zlib'` would make the product's own output depend on
## a tool the product does not ship.
##
## So the encoder is here, it is pure Nim, and it is in `src/common/`
## because nothing about it is GPUI's: any front-end, any test lane and any
## tool with a pixel buffer can call it.
##
## ## What it implements, and what it deliberately does not
##
## PNG (RFC 2083) with:
##
##   * colour type 6 (truecolour with alpha), bit depth 8 — the shape
##     `gpui_render_to_pixels` returns, so no conversion happens on the way
##     in and a channel cannot be permuted by accident;
##   * per-row filtering: `None` (0) for the first row and `Up` (2) for
##     every row after it. `Up` is what makes a screenshot compress: a
##     debugger surface is mostly vertically uniform — pane backgrounds,
##     gutters, the editor's ground — so the filtered rows are long runs of
##     zero bytes;
##   * DEFLATE (RFC 1951) with **fixed Huffman codes** and run-length
##     matching at distance 1 only.
##
## **The compressor is deliberately the simplest thing that is still a real
## compressor, and the reason is a verification one rather than an
## aesthetic one.** A stored-block (BTYPE=00) stream is four lines of code
## and produces a *valid* PNG, so it is the obvious choice — and a
## 1920x1080 capture then weighs 8.3 MB, which is past the point where an
## image is reliably viewable by the reviewer the capture exists for. A
## full LZ77 with a hash chain and dynamic Huffman tables would compress
## better and is a far larger surface to get wrong. Distance-1 RLE over the
## `Up` filter captures almost all of the available ratio on this input
## class for about eighty lines, and every piece of it is exercised by
## `src/common/png_test.nim` against a decoder that is not this module
## (Python's `zlib`, via the test's own round trip).
##
## ## What a caller must know
##
## `encodePng` raises nothing and allocates one `string`; it is pure over
## its arguments, so it is testable without a filesystem. `writePng` is the
## thin I/O wrapper and answers with a message rather than raising, which
## is the shape `codetracer-gpui`'s other `--*-out` paths already use.

import std/strutils

const
  PngSignature = "\x89PNG\r\n\x1A\n"
    ## RFC 2083 §3.1. The high bit catches a 7-bit transport, `\r\n` and
    ## `\n` catch a newline translation in either direction, and `\x1A`
    ## stops a DOS `type` mid-file.

# ---------------------------------------------------------------------------
# CRC-32 (RFC 2083 §15) and Adler-32 (RFC 1950 §9)
# ---------------------------------------------------------------------------

proc crcTable(): array[256, uint32] =
  for n in 0 ..< 256:
    var c = uint32(n)
    for _ in 0 ..< 8:
      c = if (c and 1'u32) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
    result[n] = c

let CrcTable = crcTable()

proc crc32(data: openArray[char]): uint32 =
  ## The PNG chunk CRC: over the chunk TYPE and the chunk DATA, never over
  ## the length field. Getting that wrong produces a file every decoder
  ## rejects, which is at least loud.
  var c = 0xFFFFFFFF'u32
  for ch in data:
    c = CrcTable[int((c xor uint32(ord(ch))) and 0xFF'u32)] xor (c shr 8)
  c xor 0xFFFFFFFF'u32

proc adler32(data: openArray[uint8]): uint32 =
  ## The zlib stream check, over the UNCOMPRESSED bytes — i.e. over the
  ## filtered scanlines, not over the caller's pixels.
  var a = 1'u32
  var b = 0'u32
  for byteValue in data:
    a = (a + uint32(byteValue)) mod 65521'u32
    b = (b + a) mod 65521'u32
  (b shl 16) or a

# ---------------------------------------------------------------------------
# The DEFLATE bit writer
# ---------------------------------------------------------------------------

type
  BitWriter = object
    ## DEFLATE packs bits into bytes starting at the LEAST significant bit
    ## (RFC 1951 §3.1.1), while a Huffman code is written with its MOST
    ## significant bit first (§3.1.1 again, and it is the one rule
    ## everybody who writes a deflater by hand gets wrong once). The two
    ## `put*` procs below are therefore separate and named for the
    ## distinction rather than sharing one parametrised helper.
    buf: string
    acc: uint32
    bits: int

proc putBitsLsb(w: var BitWriter; value: uint32; count: int) =
  ## `count` bits of `value`, least significant first. Extra bits of a
  ## length or distance code are written this way.
  var v = value
  for _ in 0 ..< count:
    w.acc = w.acc or ((v and 1'u32) shl uint32(w.bits))
    v = v shr 1
    inc w.bits
    if w.bits == 8:
      w.buf.add char(w.acc and 0xFF'u32)
      w.acc = 0
      w.bits = 0

proc putCodeMsb(w: var BitWriter; code: uint32; count: int) =
  ## A Huffman code: `count` bits of `code`, most significant first.
  for i in countdown(count - 1, 0):
    w.putBitsLsb((code shr uint32(i)) and 1'u32, 1)

proc flushToByte(w: var BitWriter) =
  if w.bits > 0:
    w.buf.add char(w.acc and 0xFF'u32)
    w.acc = 0
    w.bits = 0

# --- the fixed Huffman code tables (RFC 1951 §3.2.6) -----------------------

proc putLiteral(w: var BitWriter; lit: int) =
  ## Literal/length alphabet, fixed codes:
  ##   0-143   → 8 bits, 0b00110000 + lit
  ##   144-255 → 9 bits, 0b110010000 + (lit - 144)
  ##   256-279 → 7 bits, 0b0000000  + (lit - 256)
  ##   280-287 → 8 bits, 0b11000000 + (lit - 280)
  if lit <= 143:
    w.putCodeMsb(uint32(0x30 + lit), 8)
  elif lit <= 255:
    w.putCodeMsb(uint32(0x190 + (lit - 144)), 9)
  elif lit <= 279:
    w.putCodeMsb(uint32(lit - 256), 7)
  else:
    w.putCodeMsb(uint32(0xC0 + (lit - 280)), 8)

const
  LengthBase: array[29, int] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
    67, 83, 99, 115, 131, 163, 195, 227, 258]
    ## RFC 1951 §3.2.5, codes 257..285.
  LengthExtra: array[29, int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0]
  MinMatch = 3
  MaxMatch = 258
  EndOfBlock = 256

proc putMatchDistanceOne(w: var BitWriter; length: int) =
  ## A back-reference of `length` bytes at distance 1 — the run-length
  ## encoding of a repeated byte. Distance code 0 covers distance 1 exactly
  ## and carries no extra bits, which is why the only distance this
  ## compressor emits needs no distance table at all.
  var idx = LengthBase.high
  while idx > 0 and LengthBase[idx] > length:
    dec idx
  w.putLiteral(257 + idx)
  if LengthExtra[idx] > 0:
    w.putBitsLsb(uint32(length - LengthBase[idx]), LengthExtra[idx])
  # Distance code 0, five fixed bits (RFC 1951 §3.2.6: distance codes are a
  # flat 5-bit alphabet in the fixed tree).
  w.putCodeMsb(0'u32, 5)

proc deflateFixedRle(data: openArray[uint8]): string =
  ## One fixed-Huffman block over `data`, with distance-1 matches for runs.
  var w = BitWriter(buf: newStringOfCap(data.len div 2 + 64))
  # BFINAL = 1, BTYPE = 01 (fixed Huffman). Three bits, LSB first.
  w.putBitsLsb(1'u32, 1)
  w.putBitsLsb(1'u32, 2)
  var i = 0
  while i < data.len:
    # How far the byte at `i` repeats. A match at distance 1 may only cover
    # the bytes AFTER the first one, so a run of n identical bytes is one
    # literal plus a match of n-1 — and a match shorter than three bytes is
    # not expressible, so a run of three or less stays literal.
    var runEnd = i + 1
    while runEnd < data.len and data[runEnd] == data[i] and
          runEnd - i - 1 < MaxMatch:
      inc runEnd
    let repeat = runEnd - i - 1
    w.putLiteral(int(data[i]))
    if repeat >= MinMatch:
      w.putMatchDistanceOne(repeat)
      i = runEnd
    else:
      inc i
  w.putLiteral(EndOfBlock)
  w.flushToByte()
  w.buf

proc zlibStream(data: openArray[uint8]): string =
  ## RFC 1950: a two-byte header, the deflate data, and a big-endian
  ## Adler-32. CMF 0x78 is "deflate, 32 KiB window"; FLG 0x01 makes
  ## `0x7801 mod 31 == 0`, which is the header's own check.
  result = "\x78\x01"
  result.add deflateFixedRle(data)
  let sum = adler32(data)
  for shift in [24, 16, 8, 0]:
    result.add char((sum shr uint32(shift)) and 0xFF'u32)

# ---------------------------------------------------------------------------
# Chunks
# ---------------------------------------------------------------------------

proc beU32(value: uint32): string =
  result = newStringOfCap(4)
  for shift in [24, 16, 8, 0]:
    result.add char((value shr uint32(shift)) and 0xFF'u32)

proc chunk(kind: string; data: string): string =
  ## One PNG chunk: length, type, data, CRC over type+data.
  doAssert kind.len == 4, "a PNG chunk type is four bytes: " & kind
  result = beU32(uint32(data.len))
  result.add kind
  result.add data
  result.add beU32(crc32(kind & data))

# ---------------------------------------------------------------------------
# The public surface
# ---------------------------------------------------------------------------

const RgbaChannels* = 4

proc filteredScanlines*(width, height: int;
                        rgba: openArray[uint8]): seq[uint8] =
  ## The PNG image data before compression: one filter-type byte per row,
  ## then the row's bytes. Row 0 is filter `None`, every later row is
  ## filter `Up` (current minus the row above, per byte, modulo 256).
  ##
  ## Exposed rather than private because it is the half worth asserting
  ## directly: a filter that is applied in the wrong direction still
  ## produces a decodable PNG, of a different picture.
  let stride = width * RgbaChannels
  result = newSeqOfCap[uint8](height * (stride + 1))
  for y in 0 ..< height:
    result.add(if y == 0: 0'u8 else: 2'u8)
    let base = y * stride
    if y == 0:
      for x in 0 ..< stride:
        result.add rgba[base + x]
    else:
      let above = base - stride
      for x in 0 ..< stride:
        result.add uint8((int(rgba[base + x]) - int(rgba[above + x])) and 0xFF)

proc encodePng*(width, height: int; rgba: openArray[uint8]): string =
  ## An 8-bit RGBA PNG of `rgba`, which must hold `width * height * 4`
  ## bytes in row-major order with no padding.
  ##
  ## The size precondition is an `doAssert` rather than a silent truncation
  ## or a zero-fill: a caller that hands over a short buffer has a bug one
  ## layer up, and an encoder that padded it would turn that bug into a
  ## picture with a black band at the bottom — which is exactly the kind of
  ## plausible-looking artefact a visual review cannot attribute.
  doAssert width > 0 and height > 0,
    "a PNG needs a positive extent, got " & $width & "x" & $height
  doAssert rgba.len == width * height * RgbaChannels,
    "encodePng: " & $width & "x" & $height & " needs " &
    $(width * height * RgbaChannels) & " bytes, got " & $rgba.len
  var ihdr = beU32(uint32(width))
  ihdr.add beU32(uint32(height))
  ihdr.add char(8)   # bit depth
  ihdr.add char(6)   # colour type 6: truecolour with alpha
  ihdr.add char(0)   # compression method: deflate
  ihdr.add char(0)   # filter method 0 (the five adaptive filters)
  ihdr.add char(0)   # no interlace
  result = PngSignature
  result.add chunk("IHDR", ihdr)
  result.add chunk("IDAT", zlibStream(filteredScanlines(width, height, rgba)))
  result.add chunk("IEND", "")

proc writePng*(path: string; width, height: int;
               rgba: openArray[uint8]): string =
  ## Write `rgba` to `path` as a PNG. Answers "" on success and the
  ## diagnosis otherwise, so a caller with an exit code to choose does not
  ## have to wrap this in a `try`.
  try:
    writeFile(path, encodePng(width, height, rgba))
    ""
  except CatchableError as e:
    "could not write " & path & ": " & e.msg.splitLines()[0]
