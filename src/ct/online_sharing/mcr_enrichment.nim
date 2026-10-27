## MCR trace detection, portable enrichment, and pre-split slice detection
## for upload.
##
## Before uploading, MCR traces (stored in the CTFS container format) need
## to be enriched with binaries and debug symbols via `ct-mcr export --portable`.
## This module provides:
##
## - CTFS magic detection (5-byte header: C0 DE 72 AC E2)
## - ct-mcr binary discovery (env var, sibling, PATH)
## - Enrichment subprocess invocation
## - Pre-split slice detection (findSlicesDir, hasPreSplitSlices, countSlices)
##
## The detection intentionally avoids importing any ct_replayer or ct_recorder
## modules — those live in the codetracer-native-recorder repo. We rely solely
## on the 5-byte CTFS magic header to identify MCR traces.

import
  std/[os, osproc, strutils, strformat, memfiles, sets],
  results,
  codetracer_ctfs/zstd_bindings,
  ../trace/trace_container

# CTFS magic detection and container lookup used to be duplicated here.
# There is now a single implementation in ``trace/trace_container`` —
# the module that owns "what shape is this recording folder?" — and this
# module re-exports it so existing callers (and
# ``test_mcr_enrichment.nim``) keep their import surface.
export CtfsMagic, hasCtfsMagic, findCtFileInFolder

from codetracer_ctfs/container import MemberRun, memberRuns

# ---------------------------------------------------------------------------
# The root directory of a CTFS container
# ---------------------------------------------------------------------------
#
# Enough of the format to answer one question: which members does this
# container hold, and how big is each?  That lives entirely in block 0 — the
# 16-byte header plus the 24-byte entry array — so this reads no mapping
# blocks and walks no hierarchy.  It is deliberately NOT another transcription
# of the Section 4 mapping walk that `CTFS-Binary-Format.md` §5d is about; a
# reader that resolved data blocks here could be fooled by exactly the defects
# this check exists to catch.

const
  CtfsHeaderSize = 8
  CtfsExtHeaderSize = 8
  CtfsFileEntrySize = 24
  CtfsVersion = 5'u8
    ## The container version writers write (`ctfs-container.md` §1).
  CtfsVersionV6 = 6'u8
    ## Version 5's body behind a 24-byte header (§1a); read here for the full
    ## profile with no whole-file scheme only (§1c).
  CtfsDirect = 1'u64 shl 63
    ## Bit 63 of `MapBlock`: the rest is the member's only data block (§2).
  # \0, 0-9, a-z, ., /, -   (Section 3)
  Base40Alphabet = "\0" & "0123456789abcdefghijklmnopqrstuvwxyz./-"

type
  CtfsMember* = object
    name*: string
    size*: uint64
    mapBlock*: uint64

  CtfsRootDir = object
    members: seq[CtfsMember]
    blockSize: uint64
    fileBlocks: uint64      ## whole blocks the file actually contains
    trailingBytes: uint64   ## bytes past the last whole block
    rootBlocks: uint64      ## blocks the header + entry array occupy (§1)

proc base40Decode(value: uint64): string =
  var remaining = value
  var chars: array[12, char]
  var lastNonZero = -1
  for i in 0 ..< 12:
    let idx = int(remaining mod 40)
    remaining = remaining div 40
    chars[i] = Base40Alphabet[idx]
    if idx != 0:
      lastNonZero = i
  result = ""
  for i in 0 .. lastNonZero:
    result.add(chars[i])

proc readU64LE(data: openArray[byte], offset: int): uint64 =
  var v = 0'u64
  for i in countdown(7, 0):
    v = (v shl 8) or uint64(data[offset + i])
  v

proc readU32LE(data: openArray[byte], offset: int): uint32 =
  var v = 0'u32
  for i in countdown(3, 0):
    v = (v shl 8) or uint32(data[offset + i])
  v

proc readCtfsRootDir(path: string): tuple[ok: bool, dir: CtfsRootDir,
                                         reason: string] =
  ## Read the container's root directory. `ok == false` means the file could
  ## not be understood well enough to answer, which for the caller below is
  ## itself a reason not to replace anything.
  ##
  ## Only the header and the entry array are read — never the whole file.  This
  ## runs on the `ct upload` path against the user's real recording, which is
  ## routinely gigabytes; slurping it (twice: once as a `string`, once as a
  ## `seq[byte]`) would cost several times the trace's size in RAM for four
  ## numbers per entry that all live in the root region (block 0, or the
  ## `root_blocks` it overflows into).
  var f: File
  if not f.open(path, fmRead):
    return (false, CtfsRootDir(), "cannot open " & path)
  defer: f.close()

  var totalLen: uint64
  try:
    totalLen = uint64(f.getFileSize())
  except IOError, OSError:
    return (false, CtfsRootDir(), "cannot size " & path)

  const FixedHeader = CtfsHeaderSize + CtfsExtHeaderSize
  if totalLen < uint64(FixedHeader):
    return (false, CtfsRootDir(), path & " is only " & $totalLen & " bytes")

  let headerLen = int(min(totalLen, 24'u64))
  var header = newSeq[byte](headerLen)
  try:
    if f.readBuffer(addr header[0], headerLen) != headerLen:
      return (false, CtfsRootDir(), "short read of " & path & "'s header")
  except IOError, OSError:
    return (false, CtfsRootDir(), "cannot read " & path & "'s header")

  for i in 0 ..< CtfsMagic.len:
    if header[i] != CtfsMagic[i]:
      return (false, CtfsRootDir(), path & " does not carry the CTFS magic")

  if header[5] != CtfsVersion and header[5] != CtfsVersionV6:
    return (false, CtfsRootDir(), path & " is CTFS container version " &
            $header[5] & ", and this reader reads versions " & $CtfsVersion &
            " and " & $CtfsVersionV6)
  var entryStart = FixedHeader
  if header[5] == CtfsVersionV6:
    if headerLen < 24:
      return (false, CtfsRootDir(), path & " is too short for a version 6 header")
    if header[16] != 0:
      return (false, CtfsRootDir(), path & " is a version 6 container with " &
              "profile " & $header[16] & "; this reader reads profile 0 only")
    if header[17] != 0:
      return (false, CtfsRootDir(), path & " is a version 6 container with " &
              "whole-file compression " & $header[17] &
              "; this reader reads compression 0 only")
    for i in 18 ..< 24:
      if header[i] != 0:
        return (false, CtfsRootDir(), path & " is a version 6 container " &
                "with reserved byte " & $i & " = " & $header[i])
    entryStart = 24

  let blockSize = uint64(readU32LE(header, 8))
  if blockSize == 0:
    return (false, CtfsRootDir(), path & " declares a zero block size")

  # `ctfs-container.md` §1: the entry array starts in block 0 and, when the
  # declared count does not fit there, continues into the contiguous blocks
  # after it -- `root_blocks = ceil((16 + R + MaxRootEntries * 24) /
  # BlockSize)`, R = 7 * max_shards * 6.  A recording that takes periodic
  # checkpoints declares such a region (three members per checkpoint).  This
  # used to clamp the count to block 0, which read an overflowed directory
  # SHORT without saying so: every member past entry 170 invisible to the
  # comparison below.  The count is still bounded by the bytes the file holds.
  var maxRootEntries = int(readU32LE(header, 12))
  if maxRootEntries == 0:
    # `0` fills the rest of block 0 with entries (§1, "Auto-fill").
    maxRootEntries = int((blockSize - uint64(entryStart) -
      7'u64 * uint64(header[7]) * 6'u64) div uint64(CtfsFileEntrySize))
  let rootBlocks = max(1'u64,
    (uint64(entryStart) + 7'u64 * uint64(header[7]) * 6'u64 +
     uint64(maxRootEntries) * uint64(CtfsFileEntrySize) + blockSize - 1) div
    blockSize)
  let onDiskRoom = int((totalLen - uint64(entryStart)) div
                       uint64(CtfsFileEntrySize))
  if maxRootEntries > onDiskRoom:
    maxRootEntries = onDiskRoom
  if maxRootEntries < 0:
    maxRootEntries = 0

  var entries = newSeq[byte](maxRootEntries * CtfsFileEntrySize)
  if entries.len > 0:
    try:
      f.setFilePos(int64(entryStart))
      if f.readBuffer(addr entries[0], entries.len) != entries.len:
        return (false, CtfsRootDir(),
                "short read of " & path & "'s root directory")
    except IOError, OSError:
      return (false, CtfsRootDir(),
              "cannot read " & path & "'s root directory")

  var members: seq[CtfsMember] = @[]
  for i in 0 ..< maxRootEntries:
    let off = i * CtfsFileEntrySize
    let nameEncoded = readU64LE(entries, off + 16)
    if nameEncoded == 0:
      continue
    members.add(CtfsMember(name: base40Decode(nameEncoded),
                           size: readU64LE(entries, off),
                           mapBlock: readU64LE(entries, off + 8)))
  (true, CtfsRootDir(members: members, blockSize: blockSize,
                     fileBlocks: totalLen div blockSize,
                     trailingBytes: totalLen mod blockSize,
                     rootBlocks: rootBlocks), "")

proc exportCouldHoldItsOwnDirectory(path: string, dir: CtfsRootDir):
    tuple[ok: bool, reason: string] =
  ## A necessary condition for the export to actually contain what its root
  ## directory advertises, computed from block arithmetic alone.
  ##
  ## This check deliberately does not walk §4: it stays independent of the
  ## mapping reader used to validate CAS payloads below. A member comparison
  ## alone would be satisfied by an export whose
  ## directory is intact and whose *content* is not: zero every entry's mapping
  ## root, or cut a block off the tail, and every name and size still matches
  ## while not one byte is reachable.  Both were reproduced.  So the export is
  ## additionally required to be big enough, and internally consistent enough,
  ## to hold what it claims — which needs no walk and no data read:
  ##
  ##   * a container is a whole number of blocks (§5d);
  ##   * an entry with `Size > 0` has a non-null block inside the file: its
  ##     only data block when `MapBlock` carries the direct tag (§2), and then
  ##     `Size` fits that one block; otherwise its mapping root;
  ##   * and the file has its root blocks (one, or `root_blocks` when the entry
  ##     array overflows block 0), plus, for every non-empty member, one block
  ##     if it is direct, or one mapping block and `ceil(Size / BlockSize)`
  ##     data blocks if it is mapped.
  ##
  ## The last is a strict lower bound — a multi-level mapping needs *more*
  ## blocks, never fewer — so it can only ever reject a container that is
  ## genuinely too small.
  if dir.trailingBytes != 0:
    return (false, path & " is " & $dir.trailingBytes &
                   " bytes past a whole block, so its tail write did not " &
                   "complete")

  var needed = dir.rootBlocks  # the root region
  for m in dir.members:
    if m.size == 0:
      continue
    if m.mapBlock == 0 or m.mapBlock == CtfsDirect:
      return (false, "'" & m.name & "' declares " & $m.size &
                     " bytes but its MapBlock is a null block pointer, so " &
                     "none of its content is reachable")
    if (m.mapBlock and CtfsDirect) != 0:
      let b = m.mapBlock and not CtfsDirect
      if m.size > dir.blockSize:
        return (false, "'" & m.name & "' declares " & $m.size &
                       " bytes in a single direct block, more than one " &
                       "block holds")
      if b < dir.rootBlocks:
        return (false, "'" & m.name & "' has its data block at block " &
                       $b & ", inside the " & $dir.rootBlocks &
                       "-block root directory")
      if b >= dir.fileBlocks:
        return (false, "'" & m.name & "' has its data block at block " &
                       $b & ", past the " & $dir.fileBlocks &
                       " blocks the file contains")
      needed += 1
      continue
    if m.mapBlock < dir.rootBlocks:
      return (false, "'" & m.name & "' has its mapping root at block " &
                     $m.mapBlock & ", inside the " & $dir.rootBlocks &
                     "-block root directory")
    if m.mapBlock >= dir.fileBlocks:
      return (false, "'" & m.name & "' has its mapping root at block " &
                     $m.mapBlock & ", past the " & $dir.fileBlocks &
                     " blocks the file contains")
    needed += 1 + ((m.size + dir.blockSize - 1) div dir.blockSize)

  if dir.fileBlocks < needed:
    return (false, path & " holds " & $dir.fileBlocks &
                   " blocks but its root directory needs at least " &
                   $needed & " to hold the members it lists")
  (true, "")

# A cursor over shared CTFS mapping runs. The container is mapped read-only;
# neither the trace nor a complete member is copied onto the heap.
type
  MemberCursor = object
    image: ptr UncheckedArray[byte]
    runs: seq[MemberRun]
    run, into: int

  ZstdInput {.importc: "ZSTD_inBuffer", header: "<zstd.h>", bycopy.} = object
    src: pointer
    size, pos: csize_t
  ZstdOutput {.importc: "ZSTD_outBuffer", header: "<zstd.h>", bycopy.} = object
    dst: pointer
    size, pos: csize_t

# The shared zstd module supplies linking and the frame API. This scanner
# needs the streaming API to validate arbitrary chunk sizes with fixed buffers.
proc ZSTD_initDStream(ctx: pointer): csize_t {.importc, header: "<zstd.h>".}
proc ZSTD_decompressStream(ctx: pointer, output: var ZstdOutput,
    input: var ZstdInput): csize_t {.importc, header: "<zstd.h>".}
proc ZSTD_DCtx_setParameter(ctx: pointer, param, value: cint): csize_t
    {.importc, header: "<zstd.h>".}
var zstdWindowLogMax {.importc: "ZSTD_d_windowLogMax", header: "<zstd.h>".}: cint

proc cursor(image: MemFile, dir: CtfsRootDir,
    member: CtfsMember): Result[MemberCursor, string] =
  if dir.blockSize < 16:
    return err("CTFS block cannot hold a data pointer and a chain pointer")
  if member.size > uint64(high(int)):
    return err("member is too large to address")
  let p = cast[ptr UncheckedArray[byte]](image.mem)
  let runs = ? memberRuns(p.toOpenArray(0, image.size - 1), member.name,
    member.size, member.mapBlock, uint32(dir.blockSize))
  ok(MemberCursor(image: p, runs: runs))

proc available(c: MemberCursor): int =
  if c.run < c.runs.len: c.runs[c.run].len - c.into else: 0

proc consume(c: var MemberCursor, n: int) =
  c.into += n
  if c.run < c.runs.len and c.into == c.runs[c.run].len:
    inc c.run
    c.into = 0

proc readLE(c: var MemberCursor, n: int): uint64 =
  # Callers have checked index sizes before reading these 4/8-byte words.
  for i in 0 ..< n:
    result = result or (uint64(c.image[c.runs[c.run].at + c.into]) shl (8 * i))
    c.consume(1)

proc decodedFrame(c: var MemberCursor, ctx: pointer, stored: uint64,
    chunkSize: uint64): Result[uint64, string] =
  # CCT readers size their cache slots from Frame_Content_Size. A valid zstd
  # stream without that header field is therefore not a readable CCT frame.
  var headerCursor = c
  var header: array[18, byte] # ZSTD_FRAMEHEADERSIZE_MAX
  let headerSize = int(min(uint64(header.len), stored))
  for i in 0 ..< headerSize:
    header[i] = byte(headerCursor.readLE(1))
  let declared = ZSTD_getFrameContentSize(addr header[0], csize_t(headerSize))
  if declared == ZSTD_CONTENTSIZE_UNKNOWN or declared == ZSTD_CONTENTSIZE_ERROR:
    return err("zstd frame does not declare a readable content size")
  if declared == 0 or uint64(declared) > chunkSize:
    return err("zstd frame content size is outside the index chunk size")
  if ZSTD_isError(ZSTD_initDStream(ctx)) != 0:
    return err("cannot initialise zstd decoder")
  var remaining = stored
  var decoded = 0'u64
  var buffer: array[65536, byte]
  while true:
    let n = int(min(uint64(c.available()), remaining))
    var input = ZstdInput(size: csize_t(n))
    if n > 0:
      input.src = addr c.image[c.runs[c.run].at + c.into]
    var output = ZstdOutput(dst: addr buffer[0], size: csize_t(buffer.len))
    let status = ZSTD_decompressStream(ctx, output, input)
    if ZSTD_isError(status) != 0:
      return err("invalid zstd frame")
    c.consume(int(input.pos))
    remaining -= uint64(input.pos)
    decoded += uint64(output.pos)
    if decoded > chunkSize:
      return err("zstd frame exceeds the index chunk size")
    if status == 0:
      if remaining != 0:
        return err("extra bytes after the indexed zstd frame")
      if decoded != uint64(declared):
        return err("zstd frame disagrees with its declared content size")
      return ok(decoded)
    # Input exhaustion is not frame completion: a full output buffer may
    # leave decoded bytes buffered. Drain those with an empty input span.
    if input.pos == 0 and output.pos == 0:
      return err("incomplete zstd frame")

proc casLogicalName(name: string): string =
  ## Only the page store and defined checkpoint CAS streams may be rewritten.
  if name in ["cppages.ns", "cppages.nzd", "cppages.nzi"]:
    return "cppages.ns"
  if not (name.endsWith(".cas") or name.endsWith(".czd") or name.endsWith(".czi")):
    return ""
  let stem = name[0 ..< name.len - 4]
  if stem in ["cp.prein", "cp.entry", "cp.postl"]:
    return stem & ".cas"
  if stem.len < 3 or stem.len > 7 or not stem.startsWith("cp"):
    return ""
  # Periodic ids are canonical base-36, one to five digits, with no leading 0.
  if stem.len > 3 and stem[2] == '0':
    return ""
  for c in stem[2 .. ^1]:
    if c notin {'0'..'9', 'a'..'z'}:
      return ""
  stem & ".cas"

proc decodedCasSize(image: MemFile, dir: CtfsRootDir,
    logical: string): Result[uint64, string] =
  let dot = logical.rfind('.')
  let stem = logical[0 .. dot] & logical[dot + 1] & "z"
  let names = [logical, stem & "d", stem & "i"]
  var counts: array[3, int]
  var members: array[3, CtfsMember]
  for member in dir.members:
    for i, name in names:
      if member.name == name:
        inc counts[i]
        members[i] = member
  for n in counts:
    if n > 1:
      return err("duplicate members for '" & logical & "'")
  if counts[0] != 0:
    if counts[1] != 0 or counts[2] != 0:
      return err("ambiguous raw and compressed forms of '" & logical & "'")
    discard ? cursor(image, dir, members[0])
    return ok(members[0].size)
  if counts[1] != 1 or counts[2] != 1:
    return err("missing or incomplete compressed pair for '" & logical & "'")
  var data = ? cursor(image, dir, members[1])
  var index = ? cursor(image, dir, members[2])
  let indexSize = members[2].size
  if indexSize < 4 or (indexSize - 4) mod 8 != 0:
    return err("invalid compressed index size")
  let chunkSize = index.readLE(4)
  if chunkSize == 0:
    return err("zero compressed chunk size")
  let chunks = (indexSize - 4) div 8
  if chunks == 0:
    if members[1].size != 0:
      return err("compressed data without indexed frames")
    return ok(0'u64)
  var start = index.readLE(8)
  if start != 0:
    return err("first compressed offset is not zero")
  let ctx = ZSTD_createDCtx()
  if ctx.isNil:
    return err("cannot allocate zstd decoder")
  defer: discard ZSTD_freeDCtx(ctx)
  # The streaming decoder's normal 128 MiB window ceiling is explicit here:
  # an untrusted frame header must not turn a length check into an unbounded
  # allocation. Snapshot writers normally use 1 MiB chunks.
  if ZSTD_isError(ZSTD_DCtx_setParameter(ctx, zstdWindowLogMax, 27)) != 0:
    return err("cannot bound zstd decoder window")
  var total = 0'u64
  for i in 0'u64 ..< chunks:
    let stop = if i + 1 < chunks: index.readLE(8) else: members[1].size
    if stop <= start or stop > members[1].size:
      return err("invalid compressed frame offset")
    let size = ? data.decodedFrame(ctx, stop - start, chunkSize)
    if i + 1 < chunks and size != chunkSize:
      return err("non-final zstd frame does not fill the index chunk size")
    if size > high(uint64) - total:
      return err("decoded length overflows")
    total += size
    start = stop
  ok(total)

proc exportKeptEveryMember*(original, enriched: string):
    tuple[ok: bool, reason: string] =
  ## A portable export must preserve every logical member. Most members keep
  ## their stored sizes; the rebuilt provenance carrier may change. Resolving
  ## host-cache pages may grow the decoded page store and rewrite checkpoint
  ## CAS headers in place, including changing raw/compressed representation.
  ## Compare those payloads by decoded length, validating every indexed frame.
  const RebuiltMember = "filemap.bin"

  let (origOk, origDir, origWhy) = readCtfsRootDir(original)
  if not origOk:
    return (false, "cannot list the original trace's members: " & origWhy)
  let (newOk, newDir, newWhy) = readCtfsRootDir(enriched)
  if not newOk:
    return (false, "cannot list the exported trace's members: " & newWhy)

  # Keep this independent root-directory check: a readable mapping walk is
  # insufficient evidence that an export can hold all the content it claims.
  let holds = exportCouldHoldItsOwnDirectory(enriched, newDir)
  if not holds.ok:
    return (false, holds.reason)

  var originalCas = initHashSet[string]()
  var allCas = initHashSet[string]()
  for m in origDir.members:
    let logical = casLogicalName(m.name)
    if logical.len > 0:
      originalCas.incl(logical)
      allCas.incl(logical)
      continue
    var found = false
    for n in newDir.members:
      if n.name != m.name:
        continue
      found = true
      if m.name != RebuiltMember and n.size != m.size:
        return (false, "'" & m.name & "' is " & $n.size &
                       " bytes in the export but " & $m.size &
                       " bytes in the original")
      break
    if not found:
      return (false, "'" & m.name & "' (" & $m.size &
                     " bytes) is missing from the export")
  for m in newDir.members:
    let logical = casLogicalName(m.name)
    if logical.len > 0:
      allCas.incl(logical)
  if allCas.len == 0:
    return (true, "")

  # Map only when a CAS payload needs inspection. Closing both mappings here
  # also releases Windows file handles before the caller replaces the trace.
  try:
    var origImage = memfiles.open(original, mode = fmRead)
    defer: origImage.close()
    var newImage = memfiles.open(enriched, mode = fmRead)
    defer: newImage.close()
    for logical in allCas:
      let newSize = decodedCasSize(newImage, newDir, logical)
      if newSize.isErr:
        return (false, "cannot read '" & logical & "' in the export: " & newSize.error)
      if logical notin originalCas:
        continue
      let oldSize = decodedCasSize(origImage, origDir, logical)
      if oldSize.isErr:
        return (false, "cannot read '" & logical & "' in the original: " & oldSize.error)
      if (logical == "cppages.ns" and newSize.get() < oldSize.get()) or
          (logical != "cppages.ns" and newSize.get() != oldSize.get()):
        return (false, "'" & logical & "' is " & $newSize.get() &
          " decoded bytes in the export but " & $oldSize.get() &
          " decoded bytes in the original")
  except OSError as e:
    return (false, "cannot inspect snapshot payloads: " & e.msg)
  (true, "")

proc findCtMcrBinary*(): string =
  ## Locate the ct-mcr binary. Search order:
  ##   1. $CODETRACER_CT_MCR_CMD environment variable
  ##   2. Sibling of the running ct binary (same directory)
  ##   3. Anywhere on $PATH (via `which`)
  ##
  ## Returns the absolute path, or "" if not found.
  let envCmd = getEnv("CODETRACER_CT_MCR_CMD")
  if envCmd.len > 0 and fileExists(envCmd):
    return envCmd

  let siblingPath = getAppDir() / "ct-mcr"
  if fileExists(siblingPath):
    return siblingPath

  # Fall back to PATH lookup.
  let (output, exitCode) = execCmdEx("which ct-mcr")
  if exitCode == 0:
    let resolved = output.strip()
    if resolved.len > 0 and fileExists(resolved):
      return resolved

  return ""

proc findSlicesDir*(outputFolder: string): string =
  ## Find a pre-split slices directory within the output folder.
  ##
  ## When `ct-mcr record --split` is used, the trace output contains both
  ## the original .ct file and a companion `<name>_slices/` directory with
  ## individual slice .ct files and a manifest. This proc locates that
  ## directory by looking for any `.ct` file whose name + "_slices" is an
  ## existing subdirectory containing at least one `.ct` slice.
  ##
  ## Returns the absolute path to the slices directory, or "" if not found.
  if not dirExists(outputFolder):
    return ""
  for kind, path in walkDir(outputFolder):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".ct"):
      # Derive the expected slices directory name: trace.ct → trace.ct_slices/
      let slicesDir = path & "_slices"
      if dirExists(slicesDir):
        # Verify it actually contains .ct slice files (not just an empty dir).
        var hasSlice = false
        for sKind, sPath in walkDir(slicesDir):
          if sKind in {pcFile, pcLinkToFile} and sPath.endsWith(".ct"):
            hasSlice = true
            break
        if hasSlice:
          return slicesDir
  return ""

proc hasPreSplitSlices*(outputFolder: string): bool =
  ## Check if the trace output directory contains a _slices/ subdirectory
  ## with .ct slice files. This indicates client-side splitting was done
  ## during recording (via `ct-mcr record --split`).
  findSlicesDir(outputFolder).len > 0

proc countSlices*(slicesDir: string): int =
  ## Count the number of .ct slice files in a slices directory.
  ## Returns 0 if the directory does not exist or contains no .ct files.
  if not dirExists(slicesDir):
    return 0
  for kind, path in walkDir(slicesDir):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".ct"):
      result.inc

proc enrichMcrTraceIfNeeded*(outputFolder: string, noPortable: bool = false): bool =
  ## If `outputFolder` contains an MCR trace (.ct file with CTFS magic), run
  ## `ct-mcr export --portable` to add binaries and debug symbols in-place.
  ##
  ## Returns true if enrichment was performed successfully.
  ##
  ## When `noPortable` is true, enrichment is skipped unconditionally
  ## (for users who want to upload a lightweight trace).
  ##
  ## If ct-mcr is not installed, the function prints a warning and returns
  ## false — the upload continues with the non-enriched trace.
  if noPortable:
    return false

  let ctFilePath = findCtFileInFolder(outputFolder)
  if ctFilePath.len == 0:
    # No CTFS .ct file found — not an MCR trace, nothing to enrich.
    return false

  let ctMcr = findCtMcrBinary()
  if ctMcr.len == 0:
    echo "WARNING: MCR trace detected but ct-mcr binary not found."
    echo "  The trace will be uploaded without portable binaries/symbols."
    echo "  Install ct-mcr or set CODETRACER_CT_MCR_CMD to enable enrichment."
    return false

  # Run ct-mcr export --portable in-place. The --portable flag causes ct-mcr
  # to read the .ct, resolve referenced binaries from the local system, and
  # write them back into the same .ct container.
  #
  # Usage: ct-mcr export --portable -o <output.ct> <input.ct>
  # We write to a temp file first, then replace the original to avoid
  # corrupting the trace on failure.
  let enrichedPath = ctFilePath & ".portable"
  let cmd = fmt"{ctMcr.quoteShell} export --portable -o {enrichedPath.quoteShell} {ctFilePath.quoteShell}"
  let (output, exitCode) = execCmdEx(cmd)

  if exitCode != 0:
    echo "WARNING: ct-mcr export --portable failed (exit code " & $exitCode & ")."
    echo "  Output: " & output.strip()
    echo "  The trace will be uploaded without portable binaries/symbols."
    # Clean up the partial output, if any.
    if fileExists(enrichedPath):
      try: removeFile(enrichedPath)
      except OSError: discard
    return false

  # Exit 0 is NOT "nothing was lost".
  #
  # `ct-mcr export --portable` was measured exiting 0 having silently dropped a
  # member of the input it could not read — the loss reported on one
  # `--verbose`-only line — and this proc then `moveFile`d that export over the
  # user's only copy.  The temp-file dance above does not protect against it,
  # because it is not a failure by exit code.  So before the original is
  # destroyed, check the thing that actually matters: that the export carries
  # every logical member of the input, at its permitted size. See
  # `codetracer-specs/Trace-Files/CTFS-Binary-Format.md` §5d.
  let kept = exportKeptEveryMember(ctFilePath, enrichedPath)
  if not kept.ok:
    echo "WARNING: ct-mcr export --portable exited 0 but the export is not a " &
         "superset of the recording: " & kept.reason & "."
    echo "  Keeping the original trace; it will be uploaded without portable " &
         "binaries/symbols."
    if fileExists(enrichedPath):
      try: removeFile(enrichedPath)
      except OSError: discard
    return false

  # Replace the original .ct with the enriched version.
  try:
    moveFile(enrichedPath, ctFilePath)
  except OSError as e:
    echo "WARNING: failed to replace trace with enriched version: " & e.msg
    if fileExists(enrichedPath):
      try: removeFile(enrichedPath)
      except OSError: discard
    return false

  return true
