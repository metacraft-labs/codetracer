## png_test.nim — the capture's container, round-tripped against a decoder
## that is not `png.nim`.
##
## ## Why this suite exists at all
##
## `src/common/png.nim` is what turns the GPUI front-end's RGBA buffer into a
## file a review sub-agent can look at. It hand-rolls DEFLATE, and a
## hand-rolled DEFLATE has a failure mode that is specifically dangerous to a
## VISUAL review: a bit-order mistake, a wrong Huffman table or a filter
## applied in the wrong direction produces a **decodable PNG of a different
## picture**. The reviewer then reports a design finding about an artefact of
## the encoder, and the next iteration is spent in the wrong file.
##
## So the assertions here are deliberately about the container and the pixels
## and not about anything aesthetic, and the decoder is **Python's `zlib` and
## a from-scratch unfilter written in the test**, i.e. not the module under
## test. A self-decode would agree with any consistent error.
##
## **`python3` is a PREREQUISITE, not an option.** If it is absent this suite
## FAILS BY NAME rather than skipping: a skip here is an untested encoder
## wearing a green tick, and every lane in this repository that reads a
## manifest already requires `python3`.

import std/[os, osproc, strutils, unittest]

import ./png

const Python = "python3"

proc pythonAvailable(): bool = findExe(Python).len > 0

proc decodeWithPython(path: string): string =
  ## Hand the file to a decoder that is not this module, and get back a
  ## one-line summary plus the inflated, UNFILTERED pixel bytes as hex.
  ##
  ## The CRC of every chunk is checked, the zlib stream is inflated by
  ## `zlib.decompress` (which validates the Adler-32 and rejects a malformed
  ## Huffman stream), and the `Up` filter is reversed independently of
  ## `png.filteredScanlines`.
  let script = """
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
if d[:8] != b"\x89PNG\r\n\x1a\n":
    print("BAD signature"); sys.exit(0)
i, idat, dims = 8, b"", None
order = []
while i < len(d):
    n = struct.unpack_from(">I", d, i)[0]
    typ = d[i+4:i+8]
    data = d[i+8:i+8+n]
    crc = struct.unpack_from(">I", d, i+8+n)[0]
    if crc != (zlib.crc32(typ + data) & 0xffffffff):
        print("BAD crc on " + typ.decode()); sys.exit(0)
    order.append(typ.decode())
    if typ == b"IHDR":
        dims = struct.unpack(">IIBBBBB", data)
    if typ == b"IDAT":
        idat += data
    i += 12 + n
if order != ["IHDR", "IDAT", "IEND"]:
    print("BAD chunks " + ",".join(order)); sys.exit(0)
w, h, depth, ctype, comp, filt, inter = dims
try:
    raw = zlib.decompress(idat)
except Exception as e:
    print("BAD inflate " + str(e)); sys.exit(0)
stride = w * 4
if len(raw) != h * (stride + 1):
    print("BAD rawlen %d" % len(raw)); sys.exit(0)
out = bytearray()
prev = bytes(stride)
for y in range(h):
    ft = raw[y * (stride + 1)]
    line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    if ft == 2:
        for x in range(stride):
            line[x] = (line[x] + prev[x]) & 0xFF
    elif ft != 0:
        print("BAD filter %d on row %d" % (ft, y)); sys.exit(0)
    out += line
    prev = bytes(line)
print("OK %d %d %d %d %d %d %d %d" % (w, h, depth, ctype, comp, filt, inter, len(idat)))
print(out.hex())
"""
  let scriptPath = getTempDir() / "codetracer-png-decode.py"
  writeFile(scriptPath, script)
  let (output, rc) = execCmdEx(Python & " " & quoteShell(scriptPath) & " " &
                               quoteShell(path))
  removeFile(scriptPath)
  if rc != 0:
    return "BAD python rc " & $rc & ": " & output.strip()
  output.strip()

proc hexOf(bytes: openArray[uint8]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes: result.add toHex(b)
  result = result.toLowerAscii

proc roundTrip(width, height: int; rgba: seq[uint8]): tuple[head, pixels: string] =
  let path = getTempDir() / ("codetracer-png-" & $width & "x" & $height & ".png")
  check png.writePng(path, width, height, rgba) == ""
  let decoded = decodeWithPython(path)
  removeFile(path)
  let lines = decoded.splitLines
  (lines[0], if lines.len > 1: lines[1] else: "")

suite "src/common/png.nim — the capture's container":

  test "python3 is present, because a skipped encoder test is an untested encoder":
    check pythonAvailable()

  test "a one-pixel image survives a round trip through an independent decoder":
    # The smallest case that still exercises the signature, all three
    # chunks, both CRCs, the zlib header, the Adler-32 and one literal.
    let rgba = @[0x12'u8, 0x34, 0x56, 0xFF]
    let (head, pixels) = roundTrip(1, 1, rgba)
    # **ONE ASSERTION HERE, NOT TWO, AND THE ONE THAT WENT WAS NEAR-VACUOUS.**
    # It read
    #
    #     check head == "OK 1 1 8 6 0 0 0 " & head.split(' ')[^1]
    #
    # whose right-hand side is built from `head`'s OWN LAST FIELD, so the only
    # thing the equality could ever compare was the prefix — which the line
    # below compares already. What it was reaching for is *"and no field after
    # the IDAT length"*, and that is not worth writing: the only way an extra
    # field appears is an edit to this suite's own Python decoder, so no
    # change to `png.nim` could redden it, and an assertion production cannot
    # redden is the mirror image of one the broken state satisfies. The
    # IDAT LENGTH is deliberately left unasserted — it is the encoder's own
    # compressed size, and pinning it would make every DEFLATE improvement a
    # test failure (§10.3's reason, one level out).
    check head.startsWith("OK 1 1 8 6 0 0 0 ")
    check pixels == hexOf(rgba)

  test "a flat fill survives, which is what exercises the distance-1 matches":
    # 64x8 of one colour: every row after the first filters to zeroes, so
    # the stream is almost entirely length codes. A wrong length-code base,
    # a wrong extra-bit count or a distance code written LSB-first all
    # corrupt this and nothing else in the suite would catch it.
    var rgba = newSeq[uint8](64 * 8 * 4)
    for i in 0 ..< rgba.len:
      rgba[i] = [0x1B'u8, 0x22, 0x2C, 0xFF][i mod 4]
    let (head, pixels) = roundTrip(64, 8, rgba)
    check head.startsWith("OK 64 8 8 6 0 0 0 ")
    check pixels == hexOf(rgba)

  test "a run longer than one match's maximum survives":
    # 258 is the longest expressible match, so a 400-byte run has to be
    # split. An encoder that emitted one over-long length code would
    # produce a stream `zlib.decompress` either rejects or decodes short.
    var rgba = newSeq[uint8](400 * 4)
    for i in 0 ..< rgba.len: rgba[i] = 0x7F'u8
    let (head, pixels) = roundTrip(400, 1, rgba)
    check head.startsWith("OK 400 1 8 6 0 0 0 ")
    check pixels == hexOf(rgba)

  test "nine-bit literals survive, which is the other half of the fixed table":
    # Byte values 144..255 take the NINE-bit fixed codes; 0..143 take eight.
    # An encoder that used one table for both still produces a valid-looking
    # stream for low bytes only, so a test over dark pixels alone would pass
    # on it — and a debugger surface is mostly dark bytes.
    var rgba = newSeq[uint8](32 * 4 * 4)
    for i in 0 ..< rgba.len:
      rgba[i] = uint8(144 + (i * 7) mod 112)
    let (head, pixels) = roundTrip(32, 4, rgba)
    check head.startsWith("OK 32 4 8 6 0 0 0 ")
    check pixels == hexOf(rgba)

  test "a gradient with no runs at all survives":
    # The opposite input class: no two adjacent bytes equal, so every symbol
    # is a literal and no match is emitted. Exercises the literal path at
    # length without the RLE path masking it.
    var rgba = newSeq[uint8](16 * 16 * 4)
    for i in 0 ..< rgba.len:
      rgba[i] = uint8((i * 31) mod 251)
    let (head, pixels) = roundTrip(16, 16, rgba)
    check head.startsWith("OK 16 16 8 6 0 0 0 ")
    check pixels == hexOf(rgba)

  test "the filter is Up from the second row and None on the first":
    # THE DIRECTION IS ASSERTED, not only the round trip. A filter applied
    # the other way round (previous minus current) still round-trips if the
    # decoder makes the same mistake, and this repository's decoder is
    # Python's — but the assertion below is about `filteredScanlines`
    # itself, so it holds even if both ends agreed on an error.
    let rgba = @[
      10'u8, 20, 30, 40,
      15'u8, 18, 35, 40]
    let lines = filteredScanlines(1, 2, rgba)
    check lines.len == 2 * (1 * 4 + 1)
    check lines[0] == 0'u8                      # row 0: filter None
    check lines[1 .. 4] == @[10'u8, 20, 30, 40] # row 0: verbatim
    check lines[5] == 2'u8                      # row 1: filter Up
    # 15-10 = 5, 18-20 = -2 -> 254, 35-30 = 5, 40-40 = 0
    check lines[6 .. 9] == @[5'u8, 254, 5, 0]

  test "the compressor earns its place: a flat surface is far smaller than stored":
    # The reason the encoder is not four lines of stored blocks. A
    # 320x200 flat fill is 256,000 raw bytes and 257,080 as a stored
    # stream; the assertion is that this encoder is an order of magnitude
    # under that, because a capture nobody can open is not a capture.
    var rgba = newSeq[uint8](320 * 200 * 4)
    for i in 0 ..< rgba.len:
      rgba[i] = [0x1B'u8, 0x22, 0x2C, 0xFF][i mod 4]
    let encoded = encodePng(320, 200, rgba)
    check encoded.len * 10 < 320 * 200 * 4

  test "a short buffer is refused rather than padded":
    # A pad would produce a picture with a black band, which is exactly the
    # plausible-looking artefact a visual review cannot attribute.
    expect AssertionDefect:
      discard encodePng(2, 2, @[0'u8, 0, 0, 0])

  test "a zero extent is refused":
    expect AssertionDefect:
      discard encodePng(0, 4, @[])

# ---------------------------------------------------------------------------
# The decoder, against files an INDEPENDENT encoder wrote
# ---------------------------------------------------------------------------

proc encodeWithPython(ctype, depth, interlace, level, filter: int;
                      width, height: int): seq[uint8] =
  ## A PNG written by Python's `zlib` and `struct` — not by this module — for
  ## the pixel formula `formula` below, in the requested colour type, bit
  ## depth, interlace method, zlib level (0 = stored blocks, 9 = dynamic
  ## Huffman) and scanline filter (0-4, applied to every row).
  let script = """
import struct, sys, zlib
ctype, depth, inter, level, filt, w, h = map(int, sys.argv[1:8])
maxv = (1 << depth) - 1
def px(x, y):
    # The formula, in 8-bit terms: r, g, b, a.
    return ((x * 37 + y * 11) % 256, (x * 5 + y * 53) % 256, (x * y * 7) % 256, (255 - x * 9) % 256)
def scale(v): return v * maxv // 255
palette = []
def pal_index(p):
    key = (p[0] >> 6, p[1] >> 6)  # 16 entries, folded to the depth's range
    return (key[0] * 4 + key[1]) % (1 << depth)
def sample_row(y, xs):
    bits = []
    for x in xs:
        r, g, b, a = px(x, y)
        if ctype == 0: vals = [scale(r)]
        elif ctype == 2: vals = [scale(r), scale(g), scale(b)]
        elif ctype == 3: vals = [pal_index(px(x, y))]
        elif ctype == 4: vals = [scale(r), scale(a)]
        else: vals = [scale(r), scale(g), scale(b), scale(a)]
        bits += vals
    if depth == 16:
        return b"".join(struct.pack(">H", v) for v in bits)
    if depth == 8:
        return bytes(bits)
    out, acc, n = bytearray(), 0, 0
    for v in bits:
        acc = (acc << depth) | v; n += depth
        if n == 8: out.append(acc); acc, n = 0, 0
    if n: out.append(acc << (8 - n))
    return bytes(out)
channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
bpp = max(1, channels * depth // 8)
def paeth(a, b, c):
    p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)
def filtered(lines):
    out, prev = b"", None
    for line in lines:
        prev = prev if prev is not None else bytes(len(line))
        f = bytearray()
        for i in range(len(line)):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]; c = prev[i - bpp] if i >= bpp else 0
            p = [0, a, b, (a + b) // 2, paeth(a, b, c)][filt]
            f.append((line[i] - p) & 0xFF)
        out += bytes([filt]) + bytes(f); prev = line
    return out
raw = b""
if inter == 0:
    raw = filtered([sample_row(y, range(w)) for y in range(h)])
else:
    for x0, y0, dx, dy in [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)]:
        xs = list(range(x0, w, dx)); ys = list(range(y0, h, dy))
        if xs and ys: raw += filtered([sample_row(y, xs) for y in ys])
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, inter))
if ctype == 3:
    pal = bytearray()
    for i in range(16): pal += bytes([(i // 4) * 85, (i % 4) * 85, 7])
    out += chunk(b"PLTE", bytes(pal))
out += chunk(b"tEXt", b"Comment\x00an ancillary chunk the decoder skips")
data = zlib.compress(raw, level)
out += chunk(b"IDAT", data[:len(data) // 2]) + chunk(b"IDAT", data[len(data) // 2:])
out += chunk(b"IEND", b"")
sys.stdout.write(out.hex())
"""
  let scriptPath = getTempDir() / "codetracer-png-encode.py"
  writeFile(scriptPath, script)
  let (output, rc) = execCmdEx(Python & " " & quoteShell(scriptPath) & " " &
    $ctype & " " & $depth & " " & $interlace & " " & $level & " " & $filter &
    " " & $width & " " & $height)
  removeFile(scriptPath)
  doAssert rc == 0, output
  let hex = output.strip()
  result = newSeq[uint8](hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = uint8(parseHexInt(hex[i * 2 .. i * 2 + 1]))

func expected(ctype, depth, x, y: int): array[4, int] =
  ## The formula the script draws, through the same scaling, evaluated here.
  let r = (x * 37 + y * 11) mod 256
  let g = (x * 5 + y * 53) mod 256
  let b = (x * y * 7) mod 256
  let a = (255 - x * 9 + 256 * 4) mod 256
  let maxv = (1 shl depth) - 1
  proc back(v: int): int =
    let s = v * maxv div 255
    if depth == 16: s shr 8
    elif depth == 8: s
    else: s * 255 div maxv
  case ctype
  of 0: [back(r), back(r), back(r), 255]
  of 2: [back(r), back(g), back(b), 255]
  of 3:
    let i = ((r shr 6) * 4 + (g shr 6)) mod (1 shl depth)
    [(i div 4) * 85, (i mod 4) * 85, 7, 255]
  of 4: [back(r), back(r), back(r), back(a)]
  else: [back(r), back(g), back(b), back(a)]

suite "src/common/png.nim — the decoder":

  test "every colour type and bit depth an independent encoder writes":
    if not pythonAvailable():
      skip()
    else:
      var cases = 0
      for (ctype, depth) in [(0, 1), (0, 2), (0, 4), (0, 8), (0, 16),
                             (2, 8), (2, 16), (3, 1), (3, 2), (3, 4), (3, 8),
                             (4, 8), (4, 16), (6, 8), (6, 16)]:
        let w = 13
        let h = 7
        let d = decodePng(encodeWithPython(ctype, depth, 0, 9, 1, w, h))
        check d.width == w and d.height == h
        var wrong = 0
        for y in 0 ..< h:
          for x in 0 ..< w:
            let want = expected(ctype, depth, x, y)
            for k in 0 .. 3:
              if int(d.rgba[(y * w + x) * 4 + k]) != want[k]: inc wrong
        checkpoint("type " & $ctype & " depth " & $depth & ": " & $wrong & " wrong")
        check wrong == 0
        inc cases
      check cases == 15

  test "the five filters, stored and dynamic-Huffman streams, and Adam7":
    if not pythonAvailable():
      skip()
    else:
      var cases = 0
      for filter in 0 .. 4:
        for level in [0, 9]:
          for interlace in [0, 1]:
            let w = 19
            let h = 11
            let d = decodePng(encodeWithPython(6, 8, interlace, level, filter,
                                               w, h))
            var wrong = 0
            for y in 0 ..< h:
              for x in 0 ..< w:
                let want = expected(6, 8, x, y)
                for k in 0 .. 3:
                  if int(d.rgba[(y * w + x) * 4 + k]) != want[k]: inc wrong
            checkpoint("filter " & $filter & " level " & $level &
                       " interlace " & $interlace & ": " & $wrong & " wrong")
            check wrong == 0
            inc cases
      check cases == 20

  test "this module's own encoder round-trips through the decoder":
    var rgba = newSeq[uint8](40 * 30 * 4)
    for i in 0 ..< rgba.len: rgba[i] = uint8((i * 31) mod 256)
    let d = decodePng(encodePng(40, 30, rgba))
    check d.width == 40 and d.height == 30
    check d.rgba == rgba

  test "a damaged file is refused by name, never drawn":
    let good = encodePng(4, 4, newSeq[uint8](64))
    var refusals: seq[string] = @[]
    for (label, bytes) in [
        ("signature", "x" & good[1 .. ^1]),
        ("crc", good[0 ..< 30] & char(ord(good[30]) xor 1) & good[31 .. ^1]),
        ("truncated", good[0 ..< good.len - 20])]:
      try:
        discard decodePng(bytes)
      except PngDecodeError as e:
        refusals.add label & ": " & e.msg
    checkpoint($refusals)
    check refusals.len == 3
    check refusals[0].contains("signature")
    check refusals[1].contains("CRC")
