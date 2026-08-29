## Archive export — Noir-Studio.md §6.2, "the launch form of *your work leaves
## with you*".
##
## §6.2's table has two rows. The **archive** carries the working tree and
## "needs nothing beyond the store"; the **git repository** carries history and
## needs the engine NS5 is sequenced for. This module is the first row, and it
## is the whole of NS2's obligation there.
##
## ## Why `tar` and not `zip`
##
## Because the second row is coming. §6.2 is explicit that the git export must
## be "an export rather than a conversion" — the repository already exists in
## the store and the download writes it out unchanged. A `.tar` extends to that
## without changing format: `.git/objects` are already-compressed loose objects
## that a zip's deflate would re-compress for nothing, and tar preserves the
## exact bytes and the exact paths, which is what "byte-for-byte" in NS5's
## `e2e_export_round_trips_through_real_git` will mean.
##
## The immediate reason is smaller and just as real: a tar writer is a hundred
## lines of header arithmetic with no compressor, so it is host-free, works on
## both backends, and needs no dependency. A zip writer needs CRC-32 and
## deflate to be useful.
##
## ## What "ustar" buys, and the one limit it imposes
##
## The POSIX ustar header splits a path into a 155-byte prefix and a 100-byte
## name, so paths up to 255 bytes are expressible. Longer ones need GNU or PAX
## extensions, and rather than emit a header that some extractors silently
## truncate, `buildArchive` **refuses** and names the file. A silently truncated
## path in an export is precisely the "anything unrecoverable is named rather
## than silently dropped" failure `e2e_project_survives_reload_and_crash`
## forbids.

import std/algorithm

type
  ArchiveEntry* = object
    path*: string
      ## Relative, `/`-separated, no leading slash.
    content*: seq[byte]
    modifiedMs*: int64

  ArchiveResult* = object
    ok*: bool
    bytes*: seq[byte]
    rejected*: seq[string]
      ## Paths that could not be expressed. Non-empty means `ok` is false: a
      ## partial archive presented as a complete one is the shape of failure
      ## this whole area exists to prevent.
    reason*: string

proc join(items: seq[string]; separator: string): string =
  for i, item in items:
    if i > 0: result.add separator
    result.add item

const
  blockSize = 512
  nameFieldLen = 100
  prefixFieldLen = 155

proc writeOctal(header: var array[blockSize, byte]; offset, width: int;
                value: int64) =
  ## ustar numeric fields are zero-padded octal, NUL-terminated, so the digits
  ## occupy `width - 1` bytes.
  var digits = ""
  var v = value
  if v <= 0:
    digits = "0"
  else:
    while v > 0:
      digits.add chr(ord('0') + (v mod 8).int)
      v = v div 8
  var text = ""
  for i in countdown(digits.len - 1, 0): text.add digits[i]
  while text.len < width - 1:
    text = "0" & text
  for i in 0 ..< width - 1:
    header[offset + i] = text[i].byte
  header[offset + width - 1] = 0

proc writeText(header: var array[blockSize, byte]; offset, width: int;
               text: string) =
  for i in 0 ..< width:
    header[offset + i] = (if i < text.len: text[i].byte else: 0'u8)

proc splitUstarPath(path: string): tuple[ok: bool, name, prefix: string] =
  ## ustar's split, applied at the last `/` that leaves both halves in range.
  if path.len <= nameFieldLen:
    return (true, path, "")
  var cut = -1
  for i in countdown(path.len - 1, 0):
    if path[i] == '/':
      let namePart = path.len - i - 1
      if namePart <= nameFieldLen and i <= prefixFieldLen:
        cut = i
        break
  if cut < 0:
    return (false, "", "")
  (true, path[cut + 1 .. ^1], path[0 ..< cut])

proc appendHeader(output: var seq[byte]; entry: ArchiveEntry;
                  name, prefix: string; isDirectory: bool) =
  var header: array[blockSize, byte]
  for i in 0 ..< blockSize: header[i] = 0

  writeText(header, 0, nameFieldLen, name)
  writeOctal(header, 100, 8, 0o644)             # mode
  writeOctal(header, 108, 8, 0)                 # uid
  writeOctal(header, 116, 8, 0)                 # gid
  writeOctal(header, 124, 12, entry.content.len.int64)
  writeOctal(header, 136, 12, entry.modifiedMs div 1000)
  # Checksum field starts as eight spaces, per the format's own definition.
  for i in 148 ..< 156: header[i] = ' '.byte
  header[156] = (if isDirectory: '5'.byte else: '0'.byte)
  writeText(header, 257, 6, "ustar")
  header[263] = '0'.byte
  header[264] = '0'.byte
  writeText(header, 265, 32, "codetracer")      # uname
  writeText(header, 297, 32, "codetracer")      # gname
  writeText(header, 345, prefixFieldLen, prefix)

  var checksum: int64 = 0
  for i in 0 ..< blockSize: checksum += header[i].int64
  writeOctal(header, 148, 7, checksum)
  header[154] = 0
  header[155] = ' '.byte

  for i in 0 ..< blockSize: output.add header[i]

proc padToBlock(output: var seq[byte]) =
  while output.len mod blockSize != 0:
    output.add 0'u8

proc buildArchive*(entries: seq[ArchiveEntry]): ArchiveResult =
  ## A ustar archive of `entries`, sorted by path.
  ##
  ## Sorting is not cosmetic. OPFS's directory iteration order is
  ## implementation-defined, so an unsorted archive of the same tree would
  ## differ between two runs on the same machine — and an export that is not
  ## reproducible cannot be compared, diffed or checked against a hash, which
  ## is the property NS6's content-addressed snapshot will need from the same
  ## bytes.
  var ordered = entries
  ordered.sort(proc(a, b: ArchiveEntry): int =
    if a.path < b.path: -1 elif a.path > b.path: 1 else: 0)

  var output: seq[byte] = @[]
  for entry in ordered:
    let split = splitUstarPath(entry.path)
    if not split.ok:
      result.rejected.add entry.path
      continue
    appendHeader(output, entry, split.name, split.prefix, false)
    for b in entry.content: output.add b
    padToBlock(output)

  if result.rejected.len > 0:
    result.ok = false
    result.reason =
      "these paths are too long for a tar archive and were not written, so " &
      "the export is incomplete and has not been offered: " &
      result.rejected.join(", ")
    return

  # Two zero blocks terminate the archive, then the whole thing is padded to a
  # 10 KiB record so stock `tar` reads it without a blocking-factor warning.
  for i in 0 ..< blockSize * 2: output.add 0'u8
  while output.len mod (blockSize * 20) != 0:
    output.add 0'u8

  result.ok = true
  result.bytes = output

# ---------------------------------------------------------------------------
# Reading an archive back, which is what makes the writer testable at all
# ---------------------------------------------------------------------------
#
# A writer checked only against its own expectations is a check that cannot
# fail — it agrees with itself by construction. So the suite round-trips
# through this reader, which was written from the ustar layout rather than
# from the writer, and additionally asserts the checksum the writer computed
# rather than recomputing it the same way twice.

proc readOctal(bytes: seq[byte]; offset, width: int): int64 =
  for i in 0 ..< width:
    let c = bytes[offset + i].char
    if c < '0' or c > '7': break
    result = result * 8 + (ord(c) - ord('0')).int64

proc readText(bytes: seq[byte]; offset, width: int): string =
  for i in 0 ..< width:
    let b = bytes[offset + i]
    if b == 0: break
    result.add b.char

proc archiveChecksumHolds*(bytes: seq[byte]; blockOffset: int): bool =
  ## The header's stored checksum against a freshly computed one. This is the
  ## field a hand-rolled writer gets wrong, and the field `tar` refuses on.
  if blockOffset + blockSize > bytes.len: return false
  let stored = readOctal(bytes, blockOffset + 148, 7)
  var computed: int64 = 0
  for i in 0 ..< blockSize:
    if i >= 148 and i < 156: computed += ' '.byte.int64
    else: computed += bytes[blockOffset + i].int64
  stored == computed

proc readArchive*(bytes: seq[byte]): seq[ArchiveEntry] =
  ## Entries, in file order. Stops at the first zero block, as `tar` does.
  var offset = 0
  while offset + blockSize <= bytes.len:
    if bytes[offset] == 0: break
    let name = readText(bytes, offset, nameFieldLen)
    let prefix = readText(bytes, offset + 345, prefixFieldLen)
    let size = readOctal(bytes, offset + 124, 12).int
    let modified = readOctal(bytes, offset + 136, 12) * 1000
    var entry = ArchiveEntry(
      path: (if prefix.len > 0: prefix & "/" & name else: name),
      modifiedMs: modified)
    let dataStart = offset + blockSize
    if dataStart + size > bytes.len: break
    entry.content = newSeq[byte](size)
    for i in 0 ..< size: entry.content[i] = bytes[dataStart + i]
    result.add entry
    var advance = size
    if advance mod blockSize != 0:
      advance += blockSize - (advance mod blockSize)
    offset = dataStart + advance
