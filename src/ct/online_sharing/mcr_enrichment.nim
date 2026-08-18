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
  std/[os, osproc, strutils, strformat],
  ../trace/trace_container

# CTFS magic detection and container lookup used to be duplicated here.
# There is now a single implementation in ``trace/trace_container`` —
# the module that owns "what shape is this recording folder?" — and this
# module re-exports it so existing callers (and
# ``test_mcr_enrichment.nim``) keep their import surface.
export CtfsMagic, hasCtfsMagic, findCtFileInFolder

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
  ## numbers per entry that all live in block 0.
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

  var header = newSeq[byte](FixedHeader)
  try:
    if f.readBuffer(addr header[0], FixedHeader) != FixedHeader:
      return (false, CtfsRootDir(), "short read of " & path & "'s header")
  except IOError, OSError:
    return (false, CtfsRootDir(), "cannot read " & path & "'s header")

  for i in 0 ..< CtfsMagic.len:
    if header[i] != CtfsMagic[i]:
      return (false, CtfsRootDir(), path & " does not carry the CTFS magic")

  let blockSize = uint64(readU32LE(header, 8))
  if blockSize == 0:
    return (false, CtfsRootDir(), path & " declares a zero block size")

  # The entry array cannot extend past block 0, and cannot claim more entries
  # than the file holds bytes for.
  var maxRootEntries = int(readU32LE(header, 12))
  let entriesRoom = int((blockSize - uint64(FixedHeader)) div
                        uint64(CtfsFileEntrySize))
  if maxRootEntries > entriesRoom:
    maxRootEntries = entriesRoom
  let onDiskRoom = int((totalLen - uint64(FixedHeader)) div
                       uint64(CtfsFileEntrySize))
  if maxRootEntries > onDiskRoom:
    maxRootEntries = onDiskRoom
  if maxRootEntries < 0:
    maxRootEntries = 0

  var entries = newSeq[byte](maxRootEntries * CtfsFileEntrySize)
  if entries.len > 0:
    try:
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
                     trailingBytes: totalLen mod blockSize), "")

proc exportCouldHoldItsOwnDirectory(path: string, dir: CtfsRootDir):
    tuple[ok: bool, reason: string] =
  ## A necessary condition for the export to actually contain what its root
  ## directory advertises, computed from block arithmetic alone.
  ##
  ## The member comparison below deliberately does not walk §4 — a reader that
  ## resolved data blocks could be fooled by the very defects it exists to
  ## catch.  But that leaves the comparison satisfied by an export whose
  ## directory is intact and whose *content* is not: zero every entry's mapping
  ## root, or cut a block off the tail, and every name and size still matches
  ## while not one byte is reachable.  Both were reproduced.  So the export is
  ## additionally required to be big enough, and internally consistent enough,
  ## to hold what it claims — which needs no walk and no data read:
  ##
  ##   * a container is a whole number of blocks (§5d);
  ##   * an entry with `Size > 0` has a non-null mapping root inside the file;
  ##   * and the file has at least one root block, plus one mapping block and
  ##     `ceil(Size / BlockSize)` data blocks for every non-empty member.
  ##
  ## The last is a strict lower bound — a multi-level mapping needs *more*
  ## blocks, never fewer — so it can only ever reject a container that is
  ## genuinely too small.
  if dir.trailingBytes != 0:
    return (false, path & " is " & $dir.trailingBytes &
                   " bytes past a whole block, so its tail write did not " &
                   "complete")

  var needed = 1'u64  # the root block
  for m in dir.members:
    if m.size == 0:
      continue
    if m.mapBlock == 0:
      return (false, "'" & m.name & "' declares " & $m.size &
                     " bytes but has no mapping root, so none of its " &
                     "content is reachable")
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

proc exportKeptEveryMember*(original, enriched: string):
    tuple[ok: bool, reason: string] =
  ## Does `enriched` carry every member of `original`, at the same size?
  ##
  ## A `--portable` export is only ever allowed to ADD to a recording: it
  ## bundles binaries as `b/NNNN` and debug symbols as `d/NNNN`, and it rebuilds
  ## the single `filemap.bin` provenance carrier by merging the record-side
  ## entries with the bundled images.  `filemap.bin` is therefore the one member
  ## whose size legitimately changes; nothing else may shrink, change or
  ## disappear.
  const RebuiltMember = "filemap.bin"

  let (origOk, origDir, origWhy) = readCtfsRootDir(original)
  if not origOk:
    return (false, "cannot list the original trace's members: " & origWhy)
  let (newOk, newDir, newWhy) = readCtfsRootDir(enriched)
  if not newOk:
    return (false, "cannot list the exported trace's members: " & newWhy)

  # Only the EXPORT is held to this. The original is whatever the user has —
  # possibly already damaged, which is exactly when an export must not be
  # allowed to overwrite it — and refusing to look at a damaged original would
  # turn "your recording is damaged" into "enrichment is broken".
  let holds = exportCouldHoldItsOwnDirectory(enriched, newDir)
  if not holds.ok:
    return (false, holds.reason)

  let origMembers = origDir.members
  let newMembers = newDir.members
  for m in origMembers:
    var found = false
    for n in newMembers:
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
  # every member of the input, at the same size.  See
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
