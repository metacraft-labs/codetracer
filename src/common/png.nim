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

# ---------------------------------------------------------------------------
# Decoding (PLAT-14: the cell tiers draw an ENCODED image)
# ---------------------------------------------------------------------------
#
# The cell tiers (`terminal_graphics/cell_render`) consume pixels, and a frame
# or a value can arrive as a PNG; tier 0's protocols decode in the terminal,
# the cell tiers and Sixel need the pixels here. This is a complete PNG reader
# for what RFC 2083 allows: every colour type (grey, RGB, palette with `tRNS`,
# grey+alpha, RGBA), every legal bit depth (1, 2, 4, 8, 16 — 16-bit samples
# keep their high byte), the five filters, Adam7 interlacing, and a full
# DEFLATE inflater (stored, fixed and dynamic Huffman blocks), with the chunk
# CRCs and the zlib Adler-32 checked. Anything else is refused by name rather
# than drawn as a different picture.

type
  PngDecodeError* = object of CatchableError

  DecodedPng* = object
    width*, height*: int
    rgba*: seq[uint8]
      ## RGBA8888, row-major, no padding — `encodePng`'s input shape.

proc fail(msg: string) {.noreturn.} =
  raise newException(PngDecodeError, "png: " & msg)

type BitReader = object
  data: seq[uint8]
  pos: int        # byte
  bit: int        # bit within the byte, LSB first

proc bits(r: var BitReader; n: int): int =
  for i in 0 ..< n:
    if r.pos >= r.data.len:
      fail("the compressed stream ends early")
    if (int(r.data[r.pos]) shr r.bit and 1) != 0:
      result = result or (1 shl i)
    inc r.bit
    if r.bit == 8:
      r.bit = 0
      inc r.pos

type Huffman = object
  counts: array[16, int]
  symbols: seq[int]

proc huffman(lengths: openArray[int]): Huffman =
  for l in lengths: inc result.counts[l]
  result.counts[0] = 0
  var offs: array[16, int]
  for l in 1 ..< 16: offs[l] = offs[l - 1] + result.counts[l - 1]
  result.symbols = newSeq[int](lengths.len)
  for sym, l in lengths:
    if l > 0:
      result.symbols[offs[l]] = sym
      inc offs[l]

proc decodeSym(r: var BitReader; h: Huffman): int =
  ## Canonical Huffman, one bit at a time (RFC 1951 §3.2.2).
  var code = 0
  var first = 0
  var index = 0
  for l in 1 ..< 16:
    code = code or r.bits(1)
    let count = h.counts[l]
    if code - count < first:
      return h.symbols[index + (code - first)]
    index += count
    first = (first + count) shl 1
    code = code shl 1
  fail("an invalid Huffman code")

const
  LenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43,
             51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4,
              4, 4, 5, 5, 5, 5, 0]
  DistBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257,
              385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
              16385, 24577]
  DistExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9,
               10, 10, 11, 11, 12, 12, 13, 13]
  CodeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14,
                     1, 15]

proc inflateBlock(r: var BitReader; output: var seq[uint8];
                  lit, dist: Huffman) =
  while true:
    let sym = r.decodeSym(lit)
    if sym < 256:
      output.add uint8(sym)
    elif sym == 256:
      return
    else:
      let li = sym - 257
      if li >= LenBase.len: fail("an invalid length code")
      let length = LenBase[li] + r.bits(LenExtra[li])
      let di = r.decodeSym(dist)
      if di >= DistBase.len: fail("an invalid distance code")
      let d = DistBase[di] + r.bits(DistExtra[di])
      if d > output.len: fail("a distance before the start of the output")
      let start = output.len - d
      for k in 0 ..< length:
        output.add output[start + k]

proc inflate(data: seq[uint8]): seq[uint8] =
  ## RFC 1950 (the zlib wrapper) around RFC 1951 (DEFLATE).
  if data.len < 6: fail("the zlib stream is too short")
  let cmf = int(data[0])
  let flg = int(data[1])
  if (cmf and 0x0F) != 8: fail("the zlib stream is not deflate")
  if (cmf * 256 + flg) mod 31 != 0: fail("the zlib header check fails")
  if (flg and 0x20) != 0: fail("a zlib preset dictionary is not allowed in PNG")
  var r = BitReader(data: data, pos: 2, bit: 0)
  var fixedLit, fixedDist: Huffman
  var built = false
  while true:
    let final = r.bits(1)
    let kind = r.bits(2)
    case kind
    of 0:
      if r.bit != 0:
        r.bit = 0
        inc r.pos
      if r.pos + 4 > data.len: fail("a stored block's header is cut off")
      let len = int(data[r.pos]) or int(data[r.pos + 1]) shl 8
      let nlen = int(data[r.pos + 2]) or int(data[r.pos + 3]) shl 8
      if (len xor 0xFFFF) != nlen: fail("a stored block's length check fails")
      r.pos += 4
      if r.pos + len > data.len: fail("a stored block is cut off")
      for k in 0 ..< len: result.add data[r.pos + k]
      r.pos += len
    of 1:
      if not built:
        var l: array[288, int]
        for i in 0 .. 143: l[i] = 8
        for i in 144 .. 255: l[i] = 9
        for i in 256 .. 279: l[i] = 7
        for i in 280 .. 287: l[i] = 8
        fixedLit = huffman(l)
        var d: array[30, int]
        for i in 0 ..< 30: d[i] = 5
        fixedDist = huffman(d)
        built = true
      r.inflateBlock(result, fixedLit, fixedDist)
    of 2:
      let hlit = r.bits(5) + 257
      let hdist = r.bits(5) + 1
      let hclen = r.bits(4) + 4
      var cl: array[19, int]
      for i in 0 ..< hclen: cl[CodeLengthOrder[i]] = r.bits(3)
      let clh = huffman(cl)
      var lengths = newSeq[int](hlit + hdist)
      var i = 0
      while i < hlit + hdist:
        let sym = r.decodeSym(clh)
        if sym < 16:
          lengths[i] = sym
          inc i
        else:
          var rep = 0
          var val = 0
          case sym
          of 16:
            if i == 0: fail("a repeat with nothing to repeat")
            val = lengths[i - 1]
            rep = 3 + r.bits(2)
          of 17: rep = 3 + r.bits(3)
          else: rep = 11 + r.bits(7)
          if i + rep > lengths.len: fail("code lengths overrun")
          for _ in 0 ..< rep:
            lengths[i] = val
            inc i
      r.inflateBlock(result, huffman(lengths[0 ..< hlit]),
                     huffman(lengths[hlit .. ^1]))
    else:
      fail("a reserved block type")
    if final == 1:
      break
  if r.bit != 0: inc r.pos
  if r.pos + 4 > data.len: fail("the Adler-32 check is missing")
  let want = uint32(data[r.pos]) shl 24 or uint32(data[r.pos + 1]) shl 16 or
             uint32(data[r.pos + 2]) shl 8 or uint32(data[r.pos + 3])
  if adler32(result) != want: fail("the Adler-32 check fails")

proc be32(s: openArray[uint8]; at: int): int =
  int(s[at]) shl 24 or int(s[at + 1]) shl 16 or int(s[at + 2]) shl 8 or
    int(s[at + 3])

proc paeth(a, b, c: int): int =
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a elif pb <= pc: b else: c

proc decodePng*(data: openArray[uint8]): DecodedPng =
  ## A PNG file's pixels, as RGBA8888. Raises `PngDecodeError` naming what
  ## is wrong with a file it cannot read.
  if data.len < 8 or (block:
      var bad = false
      for i in 0 ..< 8:
        if data[i] != uint8(ord(PngSignature[i])): bad = true
      bad):
    fail("not a PNG (the signature is missing)")
  var pos = 8
  var width, height, depth, colorType, interlace = -1
  var idat: seq[uint8] = @[]
  var palette: seq[array[4, uint8]] = @[]
  var transGrey = -1
  var transRgb = [-1, -1, -1]
  var sawEnd = false
  while pos + 12 <= data.len:
    let len = be32(data, pos)
    if len < 0 or pos + 12 + len > data.len: fail("a chunk runs past the file")
    var kind = ""
    for i in 0 ..< 4: kind.add char(data[pos + 4 + i])
    var crcInput = newString(4 + len)
    for i in 0 ..< 4 + len: crcInput[i] = char(data[pos + 4 + i])
    if crc32(crcInput) != uint32(be32(data, pos + 8 + len)):
      fail("chunk " & kind & "'s CRC does not match")
    let body = pos + 8
    case kind
    of "IHDR":
      width = be32(data, body)
      height = be32(data, body + 4)
      depth = int(data[body + 8])
      colorType = int(data[body + 9])
      if data[body + 10] != 0 or data[body + 11] != 0:
        fail("an unknown compression or filter method")
      interlace = int(data[body + 12])
    of "PLTE":
      for i in 0 ..< len div 3:
        palette.add [data[body + i * 3], data[body + i * 3 + 1],
                     data[body + i * 3 + 2], 255'u8]
    of "tRNS":
      case colorType
      of 3:
        for i in 0 ..< min(len, palette.len): palette[i][3] = data[body + i]
      of 0: transGrey = int(data[body]) shl 8 or int(data[body + 1])
      of 2:
        for k in 0 .. 2:
          transRgb[k] = int(data[body + k * 2]) shl 8 or int(data[body + k * 2 + 1])
      else: discard
    of "IDAT":
      for i in 0 ..< len: idat.add data[body + i]
    of "IEND":
      sawEnd = true
      break
    else:
      # An unknown CRITICAL chunk (upper-case first letter) changes how the
      # image is read; an ancillary one does not.
      if kind[0] in {'A' .. 'Z'}: fail("an unknown critical chunk " & kind)
    pos += 12 + len
  if width < 0: fail("no IHDR")
  if not sawEnd: fail("no IEND")
  if width <= 0 or height <= 0: fail("a zero extent")
  let channels = case colorType
    of 0: 1
    of 2: 3
    of 3: 1
    of 4: 2
    of 6: 4
    else: fail("colour type " & $colorType & " is not a PNG colour type")
  let legal = case colorType
    of 0: depth in [1, 2, 4, 8, 16]
    of 3: depth in [1, 2, 4, 8]
    else: depth in [8, 16]
  if not legal: fail("bit depth " & $depth & " with colour type " & $colorType)
  if colorType == 3 and palette.len == 0: fail("a palette image with no PLTE")
  if interlace notin [0, 1]: fail("interlace method " & $interlace)
  let raw = inflate(idat)
  let bitsPerPixel = channels * depth
  let bpp = max(1, bitsPerPixel div 8)
  var img = DecodedPng(width: width, height: height,
                       rgba: newSeq[uint8](width * height * 4))
  var at = 0
  proc pass(x0, y0, dx, dy: int) =
    let pw = (width - x0 + dx - 1) div dx
    let ph = (height - y0 + dy - 1) div dy
    if pw <= 0 or ph <= 0: return
    let stride = (pw * bitsPerPixel + 7) div 8
    var prev = newSeq[uint8](stride)
    var line = newSeq[uint8](stride)
    for row in 0 ..< ph:
      if at + 1 + stride > raw.len: fail("the image data is cut off")
      let filter = int(raw[at])
      for i in 0 ..< stride: line[i] = raw[at + 1 + i]
      at += 1 + stride
      for i in 0 ..< stride:
        let a = if i >= bpp: int(line[i - bpp]) else: 0
        let b = int(prev[i])
        let c = if i >= bpp: int(prev[i - bpp]) else: 0
        let v = case filter
          of 0: 0
          of 1: a
          of 2: b
          of 3: (a + b) div 2
          of 4: paeth(a, b, c)
          else: fail("filter type " & $filter)
        line[i] = uint8((int(line[i]) + v) and 0xFF)
      for col in 0 ..< pw:
        proc sample(ch: int): int =
          if depth == 8: int(line[col * channels + ch])
          elif depth == 16: int(line[(col * channels + ch) * 2]) shl 8 or
                            int(line[(col * channels + ch) * 2 + 1])
          else:
            let bit = (col * channels + ch) * depth
            (int(line[bit div 8]) shr (8 - depth - bit mod 8)) and
              ((1 shl depth) - 1)
        proc to8(v: int): uint8 =
          if depth == 16: uint8(v shr 8)
          elif depth == 8: uint8(v)
          else: uint8(v * 255 div ((1 shl depth) - 1))
        var px: array[4, uint8]
        case colorType
        of 0:
          let g = sample(0)
          px = [to8(g), to8(g), to8(g), (if g == transGrey: 0'u8 else: 255'u8)]
        of 2:
          let r = sample(0)
          let g = sample(1)
          let bl = sample(2)
          let transparent = r == transRgb[0] and g == transRgb[1] and
                            bl == transRgb[2]
          px = [to8(r), to8(g), to8(bl), (if transparent: 0'u8 else: 255'u8)]
        of 3:
          let i = sample(0)
          if i >= palette.len: fail("a palette index past the palette")
          px = palette[i]
        of 4:
          let g = to8(sample(0))
          px = [g, g, g, to8(sample(1))]
        else:
          px = [to8(sample(0)), to8(sample(1)), to8(sample(2)), to8(sample(3))]
        let x = x0 + col * dx
        let y = y0 + row * dy
        let o = (y * width + x) * 4
        for k in 0 .. 3: img.rgba[o + k] = px[k]
      swap(prev, line)
  if interlace == 0:
    pass(0, 0, 1, 1)
  else:
    for (x0, y0, dx, dy) in [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8),
                             (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2),
                             (0, 1, 1, 2)]:
      pass(x0, y0, dx, dy)
  img

proc decodePng*(data: string): DecodedPng =
  decodePng(data.toOpenArrayByte(0, data.len - 1))
