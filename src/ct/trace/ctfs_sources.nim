import std/[json, os, sets, strutils, sequtils]

import source_paths

const
  LastShiftedGlobalIndexVersion* = 3'u16
    ## The highest ``meta.dat`` schema version whose writer packed a
    ## line-only ``global_position_index`` as ``prefix_sums[file_id] +
    ## line``.
    ##
    ## Named rather than spelled ``3`` at the comparison site so the bound
    ## and the refusal it drives move together: a later version that
    ## changed the packing again would raise it, and a reader comparing
    ## against a stale literal would answer such a container instead of
    ## refusing it.

  SupportedMetaDatVersion* = 4'u16
    ## The one ``meta.dat`` schema version this reader accepts.
    ##
    ## **One version, and it has to be one.** The tempting alternative —
    ## accept ``{3, 4}``, since v4 changed no field of the header this
    ## module decodes — reintroduces the exact defect the bump exists to
    ## close. v3 and v4 differ not in the bytes of ``meta.dat`` but in
    ## what the rest of the container's step addresses MEAN: a v3 writer
    ## packed a line-only ``global_position_index`` as
    ## ``prefix_sums[file_id] + line``, and v4 packs
    ## ``prefix_sums[file_id] + (line - 1)``, the exact inverse of the
    ## ``line = q + 1`` decode. Both land INSIDE the trace's own address
    ## space, so accepting a v3 container fails nowhere: every step
    ## resolves to a real file and a real line, each one exactly one line
    ## above where it was recorded.
    ##
    ## The ``paths`` list this module returns is the file table those
    ## addresses are indexed against, and it is what the importer writes
    ## into the trace folder's ``paths.json``. Answering a v3 container
    ## here therefore hands the frontend the file table for an address
    ## space the backend is about to read one line high — or, since the
    ## backend refuses v3 outright, a half-imported trace. Nothing else in
    ## the container distinguishes the two encodes: ``recorder_id`` names
    ## the producer, not its address packing, and the same recorders span
    ## the change.
    ##
    ## Mirrors ``SUPPORTED_VERSIONS`` in
    ## ``src/db-backend/src/ctfs_trace_reader/meta_dat.rs`` and
    ## ``SUPPORTED_META_DAT_VERSIONS`` in
    ## ``src/backend-manager/src/meta_dat.rs``, both ``&[4]``.
    ##
    ## A back-compat shim is not merely unimplemented, it is not
    ## constructible: subtracting one from every address would correct a
    ## trace whose writer used the old packing, and the version is
    ## precisely what would have said that it did. Pre-1.0, v3 containers
    ## are re-recorded rather than read.

type
  CtfsMetaDat* = object
    ## Subset of the ``meta.dat`` payload that the Nim importer
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
  # The CTFS *container* version, at offset 5 of the ``.ct`` file. It is a
  # different number from the ``meta.dat`` schema version that
  # ``parseCtfsMetaDat`` gates on, and the two move independently.
  #
  # A set is right here where a singleton is right there. This byte
  # describes the block-and-mapping layout that locates internal files;
  # every version in the set addresses blocks identically, so reading a v2
  # container yields the same bytes a v4 one would. It says nothing about
  # what those bytes MEAN — in particular nothing about how a step's
  # ``global_position_index`` is packed — so it cannot stand in for the
  # ``meta.dat`` gate, and widening it does not widen that one.
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

proc metaDatFlagWord(reader: CtfsReader): uint16 =
  ## The ``meta.dat`` flag word, or 0 when the container has no readable
  ## one.
  ##
  ## Reads the fixed header directly — magic, then the two flag bytes at
  ## offset 6 — rather than going through ``parseCtfsMetaDat``, because
  ## the flag word's position is fixed by the header across every schema
  ## version while that parser accepts one specific version. The caller
  ## needs one bit that selects a ``paths.dat`` record layout, and a
  ## version this parser has not been taught about must not turn into a
  ## silently mis-framed path list.
  const Magic: array[4, byte] = [byte 0x43, 0x54, 0x4D, 0x44]
  var data: string
  try:
    data = reader.readCtfsFile("meta.dat")
  except CatchableError:
    return 0
  if data.len < 8:
    return 0
  for i in 0 ..< 4:
    if byte(data[i].ord) != Magic[i]:
      return 0
  uint16(data[6].ord) or (uint16(data[7].ord) shl 8)

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
  ##   * ``paths.dat`` — the record bytes, concatenated. Which SHAPE a
  ##     record is in is decided by ``meta.dat``, never by inspecting the
  ##     bytes (the shapes' byte spaces overlap):
  ##       * bare UTF-8 path bytes — the default;
  ##       * ``path_len + path_bytes + line_count`` when bit 14
  ##         (``FLAG_HAS_LINE_COUNT_TABLE``) is set;
  ##       * ``path_len + path_bytes + line_count + line_lengths`` when
  ##         bit 4 (``FLAG_HAS_COLUMN_AWARE_STEPS``) is set.
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
  # Bits 4 and 14 each frame the record; they are mutually exclusive, and
  # a writer that sets both is rejected upstream. Both put the path bytes
  # behind a varint length, so one branch strips the framing for either.
  const FlagHasColumnAwareSteps: uint16 = 0x10
  const FlagHasLineCountTable: uint16 = 0x4000
  let flags = reader.metaDatFlagWord()
  let framed = (flags and (FlagHasColumnAwareSteps or FlagHasLineCountTable)) != 0
  for i in 0 ..< offsetCount - 1:
    let startOff = int(offsets[i])
    let endOff = int(offsets[i + 1])
    if startOff > endOff or endOff > datBytes.len:
      raise newException(ValueError, "CTFS paths.dat offset out of range")
    if endOff > startOff:
      if framed:
        # `path_len` varint, then exactly that many path bytes. The
        # trailing `line_count` (and, for bit 4, the per-line table) sizes
        # the file's slot in the position space and is not part of the
        # path; appending the whole record here is what put a length
        # prefix and a binary tail inside every path string.
        var pos = startOff
        var pathLen: uint64 = 0
        var shift: uint32 = 0
        var ok = false
        while pos < endOff:
          let b = byte(datBytes[pos].ord)
          pos += 1
          if shift >= 64:
            break
          pathLen = pathLen or (uint64(b and 0x7f) shl shift)
          if (b and 0x80) == 0:
            ok = true
            break
          shift += 7
        if not ok or pos + int(pathLen) > endOff:
          raise newException(ValueError,
            "CTFS paths.dat record " & $i & ": path_len " & $pathLen &
            " extends past the record. meta.dat flags 0x" & toHex(flags, 4) &
            " declare a framed record layout")
        result.add datBytes[pos ..< pos + int(pathLen)]
      else:
        result.add datBytes[startOff ..< endOff]

proc parseCtfsMetaDat(data: string): CtfsMetaDat   # forward decl — used by materializeCtfsSources' meta.paths fallback below

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
  # NOTE: two different files are called ``paths.json`` in this proc. The one
  # written to ``outputFolder`` is the SIDECAR the frontend reads to build the
  # filesystem jstree, and it stays. The container-INTERNAL ``paths.json`` that
  # used to be read here first is the retired legacy metadata sidecar, and is
  # gone — recorded paths come from ``paths.dat`` or ``meta.dat`` below.
  # A recorded container carries its source paths in the binary
  # ``paths.dat`` + ``paths.off`` interning table. Decode it so the frontend
  # gets a ``paths.json`` sidecar and the bundled ``files/`` payload is
  # materialised below.
  if not result:
    try:
      let interningPaths = extractInterningTablePaths(reader)
      if interningPaths.len > 0:
        paths = interningPaths
        writeFile(outputFolder / "paths.json", $(%paths))
        result = true
    except CatchableError as e:
      echo "ct host: warning: failed to decode CTFS paths.dat: ", e.msg

  # M-REC-1.5/M4a: mirror ``meta.dat``'s ``paths`` field into the sidecar so
  # the importer derives a usable jstree root from the recorded source paths
  # instead of leaving an empty list. This used to be conditional on the
  # container-internal ``paths.json`` having been empty; that file is retired,
  # so ``meta.dat`` is now simply where recorded ``--source`` paths come from.
  #
  # Any sibling sidecar already present in ``outputFolder`` (e.g.
  # ``trace_paths.json`` written by the local manifest importer to
  # surface request-details JSON files alongside the recorded source)
  # is merged in — without the merge ``normalizeImportedTracePaths``
  # would silently drop the sidecar because it prefers ``paths.json``
  # whenever it exists.
  block:
    try:
      let metaPaths = parseCtfsMetaDat(reader.readCtfsFile("meta.dat")).paths
      var merged: seq[string] = @[]
      var seen = initHashSet[string]()
      # Sidecar entries first so the manifest importer's intent
      # (e.g. inventory-response.json) wins ordering for any later
      # `paths.json[0]` consumer that picks the first entry.
      for sidecarName in ["paths.json", "trace_paths.json"]:
        let sidecarPath = outputFolder / sidecarName
        if fileExists(sidecarPath):
          try:
            let sidecarJson = parseJson(readFile(sidecarPath))
            if sidecarJson.kind == JArray:
              for node in sidecarJson:
                if node.kind == JString:
                  let p = node.getStr()
                  if p.len > 0 and p notin seen:
                    merged.add p
                    seen.incl p
          except CatchableError:
            discard
      for path in metaPaths:
        if path.len > 0 and path notin seen:
          merged.add path
          seen.incl path
      if merged.len > 0:
        paths = merged
        writeFile(outputFolder / "paths.json", $(%paths))
        result = true
    except CatchableError as e:
      echo "ct host: warning: failed to decode meta.dat paths fallback: ", e.msg

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
  ## Parse the ``meta.dat`` payload at ``SupportedMetaDatVersion``.  Only
  ## the fields the importer consumes are decoded; the remainder of the
  ## block is left untouched.
  ##
  ## Wire format reference:
  ## ``codetracer-trace-format-nim/src/codetracer_trace_writer/meta_dat.nim``
  ## (the canonical Nim writer).  This is a tightly-scoped reader
  ## sufficient for M-REC-1.5; if more fields ever need surfacing here,
  ## consider promoting the body to the shared trace-format-nim package.
  const Magic: array[4, byte] = [byte 0x43, 0x54, 0x4D, 0x44]
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
  if version != SupportedMetaDatVersion:
    let detail =
      if version <= LastShiftedGlobalIndexVersion:
        " — its step addresses use the superseded global_position_index " &
        "packing (prefix_sums[file_id] + line), which the current decode " &
        "reads one line high; re-record the trace"
      else:
        " — this reader predates that version"
    raise newException(ValueError,
      "meta.dat: unsupported version " & $version &
      " (expected " & $SupportedMetaDatVersion & ")" & detail)
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
