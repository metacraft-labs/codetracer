## common/raw_inflate.nim — RAW DEFLATE (RFC 1951), decoded in pure Nim.
##
## A compiled Noir program's `debug_symbols` is base64 of raw deflate of JSON
## (`Generated-Code-Listing.md` GCL-D7), and it is what says which source line
## each opcode came from. Three hosts need to read it: the terminal and the GPUI
## window (whose closure has no compression library, and a shared-library
## dependency on one would be a load-time failure for every other pane), and the
## desktop's renderer (the JavaScript backend, with no `zlib` of its own). One
## decoder compiled for both backends is therefore the whole of the transport;
## nothing here knows what the bytes mean.
##
## The decoder is the canonical-Huffman walk of the RFC's §3.2 (the shape zlib's
## `puff.c` documents): a table of how many codes have each length, and the
## symbols in code order. It trades speed for size, which is the right trade for
## a few kilobytes of debug symbols read once per measurement.
##
## REFUSES RATHER THAN GUESSES. Truncated input, a reserved block type, an
## over-subscribed code, or a distance reaching before the start of the output
## is a stated reason, never a partial result — a caller placing opcodes on
## source lines must not place them from half of a map.

const
  DefaultMaxInflatedBytes* = 128 * 1024 * 1024
    ## The most a caller receives by default. A deflate stream can expand about
    ## a thousand times, so a malformed artefact must not be able to ask for
    ## memory by being read.
  MaxCodeBits = 15
  LengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35,
                43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
                 4, 4, 4, 4, 5, 5, 5, 5, 0]
  DistanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193,
                  12289, 16385, 24577]
  DistanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
                   9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  CodeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14,
                     1, 15]

type
  InflateResult* = object
    ok*: bool
    bytes*: string
      ## The decoded bytes; "" unless `ok`.
    reason*: string
      ## Why the stream was refused; "" when `ok`.

  Huffman = object
    counts: array[MaxCodeBits + 1, int]
      ## How many codes have each length.
    symbols: seq[int]
      ## The symbols, in code order.

  Reader = object
    input: string
    at: int
      ## The next input byte.
    bits: int
      ## Bits read from the input and not consumed, low bit first.
    held: int
      ## How many of them there are.

  InflateFault = object of CatchableError

proc fault(reason: string) {.noreturn.} =
  raise newException(InflateFault, reason)

proc take(r: var Reader; count: int): int =
  ## The next `count` bits (at most 16), low bit first (RFC 1951 §3.1.1).
  while r.held < count:
    if r.at >= r.input.len:
      fault("the stream ends inside a block")
    r.bits = r.bits or (ord(r.input[r.at]) shl r.held)
    inc r.at
    r.held += 8
  result = r.bits and ((1 shl count) - 1)
  r.bits = r.bits shr count
  r.held -= count

proc buildHuffman(lengths: openArray[int]): Huffman =
  ## The decoding table for one code (RFC 1951 §3.2.2). A code using more of
  ## the code space than exists cannot be decoded, and is refused.
  for length in lengths:
    inc result.counts[length]
  var left = 1
  for bits in 1 .. MaxCodeBits:
    left = left * 2 - result.counts[bits]
    if left < 0:
      fault("a Huffman code is over-subscribed")
  var offsets: array[MaxCodeBits + 2, int]
  for bits in 1 .. MaxCodeBits:
    offsets[bits + 1] = offsets[bits] + result.counts[bits]
  result.symbols = newSeq[int](lengths.len)
  for symbol, length in lengths:
    if length != 0:
      result.symbols[offsets[length]] = symbol
      inc offsets[length]

proc decodeSymbol(r: var Reader; h: Huffman): int =
  ## One symbol, by walking the code a bit at a time: codes of each length are
  ## consecutive, so `code - first` indexes that length's run of symbols.
  var code, first, index = 0
  for bits in 1 .. MaxCodeBits:
    code = code or r.take(1)
    let count = h.counts[bits]
    if code - count < first:
      return h.symbols[index + (code - first)]
    index += count
    first = (first + count) * 2
    code = code * 2
  fault("a Huffman code has no symbol")

proc copyStored(r: var Reader; output: var string; limit: int) =
  ## A stored block (RFC 1951 §3.2.4): the rest of the byte is padding, then a
  ## length, its complement and the bytes.
  r.bits = 0
  r.held = 0
  if r.at + 4 > r.input.len:
    fault("the stream ends inside a block")
  let length = ord(r.input[r.at]) or (ord(r.input[r.at + 1]) shl 8)
  let complement = ord(r.input[r.at + 2]) or (ord(r.input[r.at + 3]) shl 8)
  r.at += 4
  if length != ((not complement) and 0xFFFF):
    fault("a stored block's length does not match its complement")
  if r.at + length > r.input.len:
    fault("the stream ends inside a block")
  if output.len + length > limit:
    fault("the stream expands past the limit")
  for i in 0 ..< length:
    output.add r.input[r.at + i]
  r.at += length

proc copyCodes(r: var Reader; literals, distances: Huffman;
               output: var string; limit: int) =
  ## A compressed block's symbols, up to its end-of-block (RFC 1951 §3.2.3).
  while true:
    let symbol = r.decodeSymbol(literals)
    if symbol < 256:
      if output.len >= limit:
        fault("the stream expands past the limit")
      output.add char(symbol)
    elif symbol == 256:
      return
    else:
      let lengthCode = symbol - 257
      if lengthCode >= LengthBase.len:
        fault("a block names a length that does not exist")
      let length = LengthBase[lengthCode] + r.take(LengthExtra[lengthCode])
      let distanceCode = r.decodeSymbol(distances)
      if distanceCode >= DistanceBase.len:
        fault("a block names a distance that does not exist")
      let distance = DistanceBase[distanceCode] +
                     r.take(DistanceExtra[distanceCode])
      if distance > output.len:
        fault("a block reaches before the start of the output")
      if output.len + length > limit:
        fault("the stream expands past the limit")
      # Byte by byte: a distance shorter than the length repeats what this very
      # copy just wrote, and that is how deflate spells a run.
      var from0 = output.len - distance
      for _ in 0 ..< length:
        output.add output[from0]
        inc from0

proc fixedCodes(): (Huffman, Huffman) =
  ## The fixed codes of RFC 1951 §3.2.6.
  var lengths = newSeq[int](288)
  for symbol in 0 .. 143: lengths[symbol] = 8
  for symbol in 144 .. 255: lengths[symbol] = 9
  for symbol in 256 .. 279: lengths[symbol] = 7
  for symbol in 280 .. 287: lengths[symbol] = 8
  var distances = newSeq[int](30)
  for symbol in 0 ..< distances.len: distances[symbol] = 5
  (buildHuffman(lengths), buildHuffman(distances))

proc dynamicCodes(r: var Reader): (Huffman, Huffman) =
  ## A block's own codes, themselves Huffman-coded (RFC 1951 §3.2.7).
  let literalCount = r.take(5) + 257
  let distanceCount = r.take(5) + 1
  let lengthCodeCount = r.take(4) + 4
  if literalCount > 286 or distanceCount > 30:
    fault("a block declares more codes than exist")
  var codeLengths = newSeq[int](19)
  for i in 0 ..< lengthCodeCount:
    codeLengths[CodeLengthOrder[i]] = r.take(3)
  let lengthCode = buildHuffman(codeLengths)
  var lengths = newSeq[int](literalCount + distanceCount)
  var i = 0
  while i < lengths.len:
    let symbol = r.decodeSymbol(lengthCode)
    if symbol < 16:
      lengths[i] = symbol
      inc i
      continue
    var previous = 0
    var times = 0
    case symbol
    of 16:
      if i == 0:
        fault("a block repeats a code length before there is one")
      previous = lengths[i - 1]
      times = 3 + r.take(2)
    of 17: times = 3 + r.take(3)
    else: times = 11 + r.take(7)
    if i + times > lengths.len:
      fault("a block repeats past its code lengths")
    for _ in 0 ..< times:
      lengths[i] = previous
      inc i
  if lengths[256] == 0:
    fault("a block has no end-of-block code")
  (buildHuffman(lengths[0 ..< literalCount]),
   buildHuffman(lengths[literalCount .. ^1]))

proc inflateRaw*(input: string;
                 limit = DefaultMaxInflatedBytes): InflateResult =
  ## `input` decoded as one raw deflate stream (no zlib or gzip wrapper), or the
  ## reason it could not be. Trailing bytes after the last block are ignored, as
  ## every decoder does.
  var r = Reader(input: input)
  var output = ""
  try:
    while true:
      let final = r.take(1) == 1
      # Read once, before the `case`: the JavaScript backend evaluates a `case`
      # selector that is a call more than once.
      let blockType = r.take(2)
      case blockType
      of 0:
        r.copyStored(output, limit)
      of 1:
        let (literals, distances) = fixedCodes()
        r.copyCodes(literals, distances, output, limit)
      of 2:
        let (literals, distances) = r.dynamicCodes()
        r.copyCodes(literals, distances, output, limit)
      else:
        fault("a block has the reserved type")
      if final:
        break
  except InflateFault as e:
    return InflateResult(ok: false, reason: e.msg)
  InflateResult(ok: true, bytes: output)
