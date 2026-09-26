import streams, std/[os, strutils]
import zip/zipfiles

# ---------------------------------------------------------------------------
# Store-only (ZIP_CM_STORE) writer
# ---------------------------------------------------------------------------

const
  Zip32Max = 0xFFFF_FFFF'i64
  StoreChunk = 1 shl 20

proc makeCrcTable(): array[256, uint32] =
  for n in 0 .. 255:
    var c = uint32(n)
    for _ in 0 .. 7:
      c = if (c and 1'u32) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
    result[n] = c

const CrcTable = makeCrcTable()

proc crcUpdate(crc: uint32; buf: openArray[char]; len: int): uint32 =
  result = crc
  for i in 0 ..< len:
    result = CrcTable[int((result xor uint32(ord(buf[i]))) and 0xFF'u32)] xor
             (result shr 8)

proc fileCrc32(path: string): uint32 =
  var f = open(path, fmRead)
  defer: f.close()
  var buf = newString(StoreChunk)
  var crc = 0xFFFF_FFFF'u32
  while true:
    let n = f.readBuffer(addr buf[0], StoreChunk)
    if n <= 0: break
    crc = crcUpdate(crc, buf, n)
  crc xor 0xFFFF_FFFF'u32

proc put16(s: var string; v: int) =
  s.add char(v and 0xFF)
  s.add char((v shr 8) and 0xFF)

proc put32(s: var string; v: int64) =
  for i in 0 .. 3: s.add char(int((v shr (8 * i)) and 0xFF))

proc put64(s: var string; v: int64) =
  for i in 0 .. 7: s.add char(int((v shr (8 * i)) and 0xFF))

proc writeStoredZip*(source, output: string;
                     onProgress: proc(progressPercent: int) = nil;
                     zip64At = Zip32Max) =
  ## Every regular file under `source`, stored uncompressed under its path
  ## relative to `source` (`/`-separated), in `walkDirRec` order.
  ##
  ## `zip64At` is the size/offset at which an entry, and the archive's end
  ## records, switch to their ZIP64 form. It is `Zip32Max` (the format's own
  ## limit) for every production caller; it is a parameter so `zip_test.nim`
  ## can drive the ZIP64 layout with small files instead of 4 GiB fixtures.
  ## Writing ZIP64 records below the limit is legal: a reader takes the
  ## 0xFFFFFFFF sentinels as "see the extra field".
  type Entry = object
    name: string
    size, offset: int64
    crc: uint32
  var files: seq[string] = @[]
  var totalSize: int64 = 0
  for file in walkDirRec(source):
    files.add file
    totalSize += getFileSize(file)

  var outF: File
  if not outF.open(output, fmWrite):
    raise newException(IOError, "Failed to open ZIP: " & output)
  defer: outF.close()

  var entries: seq[Entry] = @[]
  var offset: int64 = 0
  var written: int64 = 0
  var lastPercentSent = 0
  var buf = newString(StoreChunk)
  for file in files:
    let name = file.relativePath(source).replace('\\', '/')
    let size = getFileSize(file)
    let crc = fileCrc32(file)
    let big = size >= zip64At
    var h = ""
    h.put32 0x04034b50
    h.put16(if big: 45 else: 20)          # version needed
    h.put16 0x0800                        # flags: UTF-8 name
    h.put16 0                             # method: stored
    h.put16 0; h.put16 0x21               # mod time / date (1980-01-01)
    h.put32 int64(crc)
    h.put32(if big: Zip32Max else: size)  # compressed size
    h.put32(if big: Zip32Max else: size)  # uncompressed size
    h.put16 name.len
    h.put16(if big: 20 else: 0)
    h.add name
    if big:
      h.put16 0x0001; h.put16 16
      h.put64 size; h.put64 size
    outF.write h
    var inF = open(file, fmRead)
    while true:
      let n = inF.readBuffer(addr buf[0], StoreChunk)
      if n <= 0: break
      if outF.writeBuffer(addr buf[0], n) != n:
        inF.close()
        raise newException(IOError, "short write to ZIP: " & output)
    inF.close()
    entries.add Entry(name: name, size: size, offset: offset, crc: crc)
    offset += int64(h.len) + size
    written += size
    if onProgress != nil and totalSize > 0:
      let percent = int(written * 100 div totalSize)
      if percent > lastPercentSent:
        onProgress(percent)
        lastPercentSent = percent

  let cdStart = offset
  var cd = ""
  for e in entries:
    let bigSize = e.size >= zip64At
    let bigOff = e.offset >= zip64At
    var extra = ""
    if bigSize: extra.put64 e.size; extra.put64 e.size
    if bigOff: extra.put64 e.offset
    cd.put32 0x02014b50
    cd.put16 0x031E                       # made by: Unix, 3.0
    cd.put16(if extra.len > 0: 45 else: 20)
    cd.put16 0x0800
    cd.put16 0
    cd.put16 0; cd.put16 0x21
    cd.put32 int64(e.crc)
    cd.put32(if bigSize: Zip32Max else: e.size)
    cd.put32(if bigSize: Zip32Max else: e.size)
    cd.put16 e.name.len
    cd.put16(if extra.len > 0: extra.len + 4 else: 0)
    cd.put16 0                            # comment length
    cd.put16 0                            # disk number
    cd.put16 0                            # internal attributes
    cd.put32 int64(0o100644) shl 16       # external: regular file, 0644
    cd.put32(if bigOff: Zip32Max else: e.offset)
    cd.add e.name
    if extra.len > 0:
      cd.put16 0x0001; cd.put16 extra.len
      cd.add extra
  outF.write cd
  let cdSize = int64(cd.len)
  var tail = ""
  let zip64 = entries.len >= 0xFFFF or cdStart >= zip64At or cdSize >= zip64At
  if zip64:
    let eocd64At = cdStart + cdSize
    tail.put32 0x06064b50
    tail.put64 44
    tail.put16 45; tail.put16 45
    tail.put32 0; tail.put32 0
    tail.put64 entries.len; tail.put64 entries.len
    tail.put64 cdSize; tail.put64 cdStart
    tail.put32 0x07064b50
    tail.put32 0; tail.put64 eocd64At; tail.put32 1
  tail.put32 0x06054b50
  tail.put16 0; tail.put16 0
  tail.put16(if zip64: 0xFFFF else: entries.len)
  tail.put16(if zip64: 0xFFFF else: entries.len)
  tail.put32(if zip64: Zip32Max else: cdSize)
  tail.put32(if zip64: Zip32Max else: cdStart)
  tail.put16 0
  outF.write tail
  if onProgress != nil and lastPercentSent < 100:
    onProgress(100)

proc zipFolder*(source, output: string,
                onProgress: proc(progressPercent: int) = nil,
                storeOnly: bool = false) =
  ## Zip the contents of `source` into the archive at `output`.
  ##
  ## When `storeOnly` is true, files are stored without compression
  ## (ZIP_CM_STORE / ``zip -0``). This is useful for CTFS .ct files that
  ## are already internally compressed — wrapping them in a deflate zip
  ## would waste CPU on redundant compression with negligible size
  ## reduction.
  ##
  ## The store-only path is written HERE, not by libzip: the bundled
  ## `zip/zipfiles` exposes no per-file compression setting, and the
  ## alternative this used to take -- shelling out to an external ``zip -0``
  ## -- made `ct` depend on a binary that neither the dev shell nor the
  ## packaged app provides (`zip -0 failed (exit 127): zip: command not
  ## found`). A stored entry is a header, the bytes and a CRC-32, so the
  ## writer is small; it emits ZIP64 records when a size or offset needs
  ## them, as `zip` did.
  if storeOnly:
    writeStoredZip(source, output, onProgress)
    return

  var zip: ZipArchive

  var totalSize: int64 = 0
  var totalWritten: int64 = 0
  var lastPercentSent = 0
  for file in walkDirRec(source):
    totalSize += getFileSize(file)

  for file in walkDirRec(source):
    totalWritten += getFileSize(file)
    if not zip.open(output, fmReadWrite):
      raise newException(IOError, "Failed to open ZIP: " & source)

    let relPath = file.relativePath(source)
    let fileStream = newFileStream(file, fmRead)
    zip.addFile(relPath, fileStream)
    zip.close()
    fileStream.close()

    if onProgress != nil:
      let percent = int(totalWritten * 100 div totalSize)
      if percent > lastPercentSent:
        onProgress(percent)
        lastPercentSent = percent

proc unzipIntoFolder*(zipPath, targetDir: string) {.raises: [IOError, OSError, Exception].} =
  var zip: ZipArchive
  if not zip.open(zipPath, fmRead):
    raise newException(IOError, "Failed to open ZIP: " & zipPath)

  createDir(targetDir)
  zip.extractAll(targetDir)

  zip.close()
