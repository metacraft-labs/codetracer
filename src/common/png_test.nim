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
