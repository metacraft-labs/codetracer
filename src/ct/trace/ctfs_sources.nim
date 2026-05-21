import std/[json, os, strutils, sequtils]

import source_paths

type
  CtfsMetaDat* = object
    ## Subset of the v3 ``meta.dat`` payload that the Nim importer
    ## consumes.  Mirrors the fields used to populate the trace index.
    ## M-REC-1.5 made this the canonical metadata source — legacy
    ## ``trace_metadata.json`` and ``trace_db_metadata.json`` sidecars
    ## are no longer accepted.
    recordingId*: string
    program*: string
    workdir*: string
    args*: seq[string]
    paths*: seq[string]

const
  CtfsMagic = [byte 0xC0, 0xDE, 0x72, 0xAC, 0xE2]
  Base40Alphabet = "\0" & "0123456789abcdefghijklmnopqrstuvwxyz./-"

type
  CtfsEntry = object
    name: string
    size: uint64
    mapBlock: uint64

  CtfsReader = object
    data: string
    blockSize: uint32
    entries: seq[CtfsEntry]

proc readU16Le(data: string, offset: int): uint16 =
  if offset + 2 > data.len:
    raise newException(ValueError, "short read")
  uint16(data[offset].ord) or (uint16(data[offset + 1].ord) shl 8)

proc readU32Le(data: string, offset: int): uint32 =
  if offset + 4 > data.len:
    raise newException(ValueError, "short read")
  uint32(data[offset].ord) or
    (uint32(data[offset + 1].ord) shl 8) or
    (uint32(data[offset + 2].ord) shl 16) or
    (uint32(data[offset + 3].ord) shl 24)

proc readU64Le(data: string, offset: int): uint64 =
  if offset + 8 > data.len:
    raise newException(ValueError, "short read")
  for i in 0 ..< 8:
    result = result or (uint64(data[offset + i].ord) shl (8 * i))

proc base40Decode(encoded: uint64): string =
  var value = encoded
  while value > 0:
    let index = int(value mod 40)
    value = value div 40
    if index == 0:
      break
    result.add(Base40Alphabet[index])

proc openCtfs(path: string): CtfsReader =
  result.data = readFile(path)
  if result.data.len < 16:
    raise newException(ValueError, "CTFS file too short")
  for i, b in CtfsMagic:
    if byte(result.data[i].ord) != b:
      raise newException(ValueError, "invalid CTFS magic")
  let version = result.data[5].ord
  if version notin {2, 3, 4}:
    raise newException(ValueError, "unsupported CTFS version")
  result.blockSize = readU32Le(result.data, 8)
  if result.blockSize notin [uint32 1024, 2048, 4096]:
    raise newException(ValueError, "invalid CTFS block size")
  let maxEntries = int(readU32Le(result.data, 12))
  var offset = 16
  for _ in 0 ..< maxEntries:
    let size = readU64Le(result.data, offset)
    let mapBlock = readU64Le(result.data, offset + 8)
    let encodedName = readU64Le(result.data, offset + 16)
    if size != 0 or mapBlock != 0 or encodedName != 0:
      result.entries.add CtfsEntry(
        name: base40Decode(encodedName),
        size: size,
        mapBlock: mapBlock)
    offset += 24

proc findEntry(reader: CtfsReader, name: string): CtfsEntry =
  for entry in reader.entries:
    if entry.name == name:
      return entry
  raise newException(ValueError, "CTFS file not found: " & name)

proc readBlockPtr(reader: CtfsReader, blockNum: uint64, index: int): uint64 =
  let offset = int(blockNum * uint64(reader.blockSize)) + index * 8
  readU64Le(reader.data, offset)

proc levelCapacity(usable: uint64, level: uint32): uint64 =
  result = 1
  for _ in 0 ..< level:
    result = result * usable

proc navigateToDataBlock(reader: CtfsReader, mappingBlock: uint64, level: uint32,
    indexWithinLevel, usable: uint64): uint64 =
  if level == 1:
    result = readBlockPtr(reader, mappingBlock, int(indexWithinLevel))
    if result == 0:
      raise newException(ValueError, "null CTFS data block pointer")
    return

  let subCapacity = levelCapacity(usable, level - 1)
  let entryIndex = indexWithinLevel div subCapacity
  let subIndex = indexWithinLevel mod subCapacity
  let childBlock = readBlockPtr(reader, mappingBlock, int(entryIndex))
  if childBlock == 0:
    raise newException(ValueError, "null CTFS mapping block pointer")
  navigateToDataBlock(reader, childBlock, level - 1, subIndex, usable)

proc resolveBlock(reader: CtfsReader, entry: CtfsEntry, blockIndex: uint64): uint64 =
  let usable = uint64(reader.blockSize div 8) - 1
  var index = blockIndex
  var currentLevelBlock = entry.mapBlock
  var level = uint32 1

  while true:
    let capacity = levelCapacity(usable, level)
    if index < capacity:
      break
    index -= capacity
    inc level
    if level > 5:
      raise newException(ValueError, "CTFS block index exceeds mapping depth")
    currentLevelBlock = readBlockPtr(reader, currentLevelBlock, int(usable))
    if currentLevelBlock == 0:
      raise newException(ValueError, "null CTFS chain pointer")

  navigateToDataBlock(reader, currentLevelBlock, level, index, usable)

proc readCtfsFile(reader: CtfsReader, name: string): string =
  let entry = reader.findEntry(name)
  if entry.size == 0:
    return ""

  let blockSize = int(reader.blockSize)
  let numBlocks = int((entry.size + uint64(blockSize) - 1) div uint64(blockSize))
  var remaining = int(entry.size)
  for blockIndex in 0 ..< numBlocks:
    let dataBlock = reader.resolveBlock(entry, uint64(blockIndex))
    let offset = int(dataBlock * uint64(blockSize))
    let bytesToRead = min(blockSize, remaining)
    if offset + bytesToRead > reader.data.len:
      raise newException(ValueError, "CTFS data block outside file")
    result.add reader.data[offset ..< offset + bytesToRead]
    remaining -= bytesToRead

proc readLeb128(data: string, offset: var int): uint64 =
  var shift = 0
  while offset < data.len:
    let b = data[offset].ord
    inc offset
    result = result or (uint64(b and 0x7f) shl shift)
    if (b and 0x80) == 0:
      return
    shift += 7
    if shift >= 64:
      raise newException(ValueError, "LEB128 overflow")
  raise newException(ValueError, "truncated LEB128")

proc readVarString(data: string, offset: var int): string =
  let length = int(readLeb128(data, offset))
  if offset + length > data.len:
    raise newException(ValueError, "truncated string")
  result = data[offset ..< offset + length]
  offset += length

proc safePayloadPath(realPath: string): string =
  let rel = stripTracePathRoot(realPath)
  if rel.len == 0 or rel.split(DirSep).anyIt(it == ".."):
    return realPath.extractFilename
  rel

proc extractFilemapSources(reader: CtfsReader, outputFolder: string): seq[string] =
  let filemap = reader.readCtfsFile("filemap.bin")
  if filemap.len == 0:
    return @[]
  if filemap.len < 8 or filemap[0 ..< 4] != "FMAP":
    raise newException(ValueError, "invalid CTFS filemap")

  let version = readU16Le(filemap, 4)
  if version == 0 or version > 1:
    raise newException(ValueError, "unsupported CTFS filemap version")
  let entryCount = int(readU16Le(filemap, 6))
  var offset = 8

  for _ in 0 ..< entryCount:
    let ctfsName = base40Decode(readU64Le(filemap, offset))
    offset += 8
    if offset + 3 > filemap.len:
      raise newException(ValueError, "truncated CTFS filemap entry")
    let entryType = filemap[offset].ord
    offset += 1
    offset += 1 # flags
    let buildIdLength = filemap[offset].ord
    offset += 1 + buildIdLength
    if offset > filemap.len:
      raise newException(ValueError, "truncated CTFS filemap build id")
    let realPath = readVarString(filemap, offset)

    if entryType == 1:
      offset += 8
      if offset > filemap.len:
        raise newException(ValueError, "truncated CTFS debug symbol entry")
    elif entryType == 2:
      discard readVarString(filemap, offset)
      result.add realPath
      let sourceBytes = reader.readCtfsFile(ctfsName)
      let outputPath = outputFolder / "files" / safePayloadPath(realPath)
      createDir(outputPath.parentDir)
      writeFile(outputPath, sourceBytes)

proc extractInterningTablePaths(reader: CtfsReader): seq[string] =
  ## Decode the CTFS v4 interning-table path list (``paths.dat`` +
  ## ``paths.off``) written by the current trace writer
  ## (``codetracer-trace-format-nim``'s ``InterningTable`` /
  ## ``VariableRecordTable``).
  ##
  ## Layout:
  ##   * ``paths.off`` — a FixedRecordTable of ``N+1`` little-endian u64
  ##     cumulative byte offsets into ``paths.dat`` (offset[0] is always
  ##     0; offset[i+1] - offset[i] is the length of record ``i``).
  ##   * ``paths.dat`` — the raw UTF-8 path bytes, concatenated.
  ##
  ## Returns an empty seq when the container predates the v4 format
  ## (no ``paths.dat``); the caller falls back to ``paths.json``.
  result = @[]
  var datBytes, offBytes: string
  try:
    datBytes = reader.readCtfsFile("paths.dat")
    offBytes = reader.readCtfsFile("paths.off")
  except CatchableError:
    return @[]
  if offBytes.len < 16 or offBytes.len mod 8 != 0:
    # Need at least two offsets (the leading 0 plus one record end) to
    # describe a single path.
    return @[]
  let offsetCount = offBytes.len div 8
  var offsets = newSeq[uint64](offsetCount)
  for i in 0 ..< offsetCount:
    offsets[i] = readU64Le(offBytes, i * 8)
  for i in 0 ..< offsetCount - 1:
    let startOff = int(offsets[i])
    let endOff = int(offsets[i + 1])
    if startOff > endOff or endOff > datBytes.len:
      raise newException(ValueError, "CTFS paths.dat offset out of range")
    if endOff > startOff:
      result.add datBytes[startOff ..< endOff]

proc materializeCtfsSources*(ctFilePath, outputFolder: string): bool =
  ## Extract source metadata from a CTFS .ct file into the runtime
  ## trace-folder layout consumed by the current frontend: a sibling
  ## ``paths.json`` (M-REC-1.5: previously named ``trace_paths.json``)
  ## plus a ``files/`` subdirectory.  The CTFS container itself is the
  ## source of truth for both — this proc just unpacks it so the
  ## existing frontend wiring keeps working without a full FFI reader.
  var reader: CtfsReader
  try:
    reader = openCtfs(ctFilePath)
  except CatchableError:
    return false

  var paths: seq[string] = @[]
  try:
    let pathsJson = reader.readCtfsFile("paths.json")
    if pathsJson.len > 0:
      writeFile(outputFolder / "paths.json", pathsJson)
      for pathNode in parseJson(pathsJson):
        if pathNode.kind == JString:
          paths.add pathNode.getStr()
      result = true
  except CatchableError:
    discard

  # CTFS v4 containers replace the legacy JSON ``paths.json`` internal
  # file with the binary ``paths.dat`` + ``paths.off`` interning table.
  # When the JSON form is absent, decode the binary table so the
  # frontend still gets a ``paths.json`` sidecar and the bundled
  # ``files/`` payload is materialised below.
  if not result:
    try:
      let interningPaths = extractInterningTablePaths(reader)
      if interningPaths.len > 0:
        paths = interningPaths
        writeFile(outputFolder / "paths.json", $(%paths))
        result = true
    except CatchableError as e:
      echo "ct host: warning: failed to decode CTFS paths.dat: ", e.msg

  try:
    let filemapPaths = extractFilemapSources(reader, outputFolder)
    if filemapPaths.len > 0:
      paths = concat(paths, filemapPaths)
      writeFile(outputFolder / "paths.json", $(%paths))
      result = true
  except CatchableError as e:
    echo "ct host: warning: failed to extract CTFS portable sources: ", e.msg

proc decodeVarintFromString(data: string, pos: var int): uint64 =
  ## Decode a single LEB128 unsigned varint at ``pos`` in ``data``.
  result = 0
  var shift = 0
  while pos < data.len:
    let b = data[pos].ord
    inc pos
    result = result or (uint64(b and 0x7f) shl shift)
    if (b and 0x80) == 0:
      return
    shift += 7
    if shift >= 64:
      raise newException(ValueError, "meta.dat varint overflow")
  raise newException(ValueError, "meta.dat truncated varint")

proc readVarStringFromMetaDat(data: string, pos: var int): string =
  let len = int(decodeVarintFromString(data, pos))
  if pos + len > data.len:
    raise newException(ValueError, "meta.dat truncated string")
  result = data[pos ..< pos + len]
  pos += len

proc parseCtfsMetaDat(data: string): CtfsMetaDat =
  ## Parse the v3 ``meta.dat`` payload.  Only the fields the importer
  ## consumes are decoded; the remainder of the block is left untouched.
  ##
  ## Wire format reference:
  ## ``codetracer-trace-format-nim/src/codetracer_trace_writer/meta_dat.nim``
  ## (the canonical Nim writer).  This is a tightly-scoped reader
  ## sufficient for M-REC-1.5; if more fields ever need surfacing here,
  ## consider promoting the body to the shared trace-format-nim package.
  const Magic: array[4, byte] = [byte 0x43, 0x54, 0x4D, 0x44]
  const Version: uint16 = 3
  const FlagHasMcrFields: uint16 = 1
  const FlagHasReplayLaunchFields: uint16 = 2
  const FlagHasLayoutSnapshot: uint16 = 4
  const FlagHasTraceFilterProvenance: uint16 = 8

  if data.len < 8:
    raise newException(ValueError, "meta.dat too short")
  for i in 0 ..< 4:
    if byte(data[i].ord) != Magic[i]:
      raise newException(ValueError, "meta.dat: bad magic")
  let version = uint16(data[4].ord) or (uint16(data[5].ord) shl 8)
  if version != Version:
    raise newException(ValueError,
      "meta.dat: unsupported version " & $version &
      " (M-REC-1.5 retired v1/v2; expected " & $Version & ")")
  let flags = uint16(data[6].ord) or (uint16(data[7].ord) shl 8)

  var pos = 8
  let recordingId = readVarStringFromMetaDat(data, pos)
  if recordingId.len != 36:
    raise newException(ValueError,
      "meta.dat: invalid recording_id (length " & $recordingId.len & ")")

  let program = readVarStringFromMetaDat(data, pos)
  let argsCount = int(decodeVarintFromString(data, pos))
  var args = newSeqOfCap[string](argsCount)
  for _ in 0 ..< argsCount:
    args.add readVarStringFromMetaDat(data, pos)
  let workdir = readVarStringFromMetaDat(data, pos)
  discard readVarStringFromMetaDat(data, pos)  # recorder_id (unused here)
  let pathsCount = int(decodeVarintFromString(data, pos))
  var paths = newSeqOfCap[string](pathsCount)
  for _ in 0 ..< pathsCount:
    paths.add readVarStringFromMetaDat(data, pos)

  # The MCR/replay-launch/layout-snapshot/trace-filter blocks are skipped:
  # callers in ct/host don't need them.  We still keep this proc resilient
  # by short-circuiting once the required fields are decoded.
  discard flags
  discard FlagHasMcrFields
  discard FlagHasReplayLaunchFields
  discard FlagHasLayoutSnapshot
  discard FlagHasTraceFilterProvenance

  CtfsMetaDat(
    recordingId: recordingId,
    program: program,
    workdir: workdir,
    args: args,
    paths: paths,
  )

proc readCtfsMetaDat*(ctFilePath: string): CtfsMetaDat =
  ## Read and parse the canonical ``meta.dat`` from a CTFS ``.ct`` file.
  ## Raises ``ValueError`` if the file cannot be opened, the internal
  ## ``meta.dat`` entry is absent, or the payload fails to parse.
  let reader = openCtfs(ctFilePath)
  let data = reader.readCtfsFile("meta.dat")
  if data.len == 0:
    raise newException(ValueError,
      "meta.dat missing or empty in " & ctFilePath)
  parseCtfsMetaDat(data)
