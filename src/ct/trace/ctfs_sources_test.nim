import std/[os, strutils, unittest]

import ctfs_sources

const Base40Alphabet = "\0" & "0123456789abcdefghijklmnopqrstuvwxyz./-"

proc putU16Le(buf: var string, value: uint16) =
  buf.add char(value and 0xff)
  buf.add char((value shr 8) and 0xff)

proc putU32Le(buf: var string, value: uint32) =
  for i in 0 ..< 4:
    buf.add char((value shr (8 * i)) and 0xff)

proc putU64Le(buf: var string, value: uint64) =
  for i in 0 ..< 8:
    buf.add char((value shr (8 * i)) and 0xff)

proc putLeb128(buf: var string, value: uint64) =
  var remaining = value
  while true:
    var b = byte(remaining and 0x7f)
    remaining = remaining shr 7
    if remaining != 0:
      b = b or 0x80
    buf.add char(b)
    if remaining == 0:
      break

proc putVarString(buf: var string, value: string) =
  buf.putLeb128(uint64(value.len))
  buf.add value

proc base40Encode(name: string): uint64 =
  var multiplier = uint64 1
  for c in name:
    let index = Base40Alphabet.find(c)
    doAssert index >= 0
    result += uint64(index) * multiplier
    multiplier *= 40

proc writeEntry(root: var string, size, mapBlock: uint64, name: string) =
  root.putU64Le(size)
  root.putU64Le(mapBlock)
  root.putU64Le(base40Encode(name))

proc paddedBlock(data: string, blockSize: int): string =
  result = data
  result.setLen(blockSize)

proc writeMinimalCtfs(path: string, files: seq[(string, string)]) =
  const BlockSize = 1024
  const MaxEntries = 8
  var root = ""
  root.add "\xC0\xDE\x72\xAC\xE2"
  root.add char(3)
  root.add char(0)
  root.add char(0)
  root.putU32Le(BlockSize)
  root.putU32Le(MaxEntries)

  for i, file in files:
    let mapBlock = uint64(1 + i * 2)
    root.writeEntry(uint64(file[1].len), mapBlock, file[0])
  for _ in files.len ..< MaxEntries:
    root.writeEntry(0, 0, "")
  root.setLen(BlockSize)

  var data = root
  for i, file in files:
    let dataBlock = uint64(2 + i * 2)
    var mapping = ""
    mapping.putU64Le(dataBlock)
    mapping.setLen(BlockSize)
    data.add mapping
    data.add paddedBlock(file[1], BlockSize)
  writeFile(path, data)

proc buildFilemap(): string =
  result.add "FMAP"
  result.putU16Le(1)
  result.putU16Le(1)
  result.putU64Le(base40Encode("s/0001"))
  result.add char(2) # source file
  result.add char(0) # flags
  result.add char(0) # build id length
  result.putVarString("/workspace/project/src/main.c")
  result.putVarString("/workspace/project")

suite "CTFS source materialization":
  test "extracts paths and portable source files":
    let root = getTempDir() / "ctfs-sources-test-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let ctPath = root / "trace.ct"
    let outDir = root / "out"
    createDir(outDir)
    writeMinimalCtfs(ctPath, @[
      ("paths.json", "[\"/workspace/project/src/main.c\"]"),
      ("filemap.bin", buildFilemap()),
      ("s/0001", "int main(void) { return 0; }\n")
    ])

    check materializeCtfsSources(ctPath, outDir)
    check readFile(outDir / "paths.json").contains("/workspace/project/src/main.c")
    check readFile(outDir / "files" / "workspace/project/src/main.c") ==
      "int main(void) { return 0; }\n"

  test "strips the record framing when meta.dat declares a line-count table":
    ## `paths.dat` records are bare path bytes by default, but `meta.dat`
    ## bit 14 (FLAG_HAS_LINE_COUNT_TABLE) frames each one as
    ## `path_len + path_bytes + line_count` so the container states how
    ## large each file is. Reading such a record whole puts the length
    ## prefix and the trailing count inside the path string, and the
    ## frontend then shows a source file under a name no filesystem has.
    ##
    ## Which shape a record is in comes from `meta.dat`, never from the
    ## bytes: the shapes' byte spaces overlap, so a bare path whose first
    ## byte happens to equal its own remaining length also decodes as a
    ## framed record.
    let root = getTempDir() / "ctfs-line-count-test-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    const PathA = "/workspace/project/src/main.c"
    const PathB = "/workspace/project/src/util.c"
    const CountA = 42'u64
    const CountB = 17'u64

    proc framedRecord(path: string, lineCount: uint64): string =
      result.putLeb128(uint64(path.len))
      result.add path
      result.putLeb128(lineCount)

    proc pathsTable(records: seq[string]): (string, string) =
      var dat = ""
      var off = ""
      off.putU64Le(0)
      for r in records:
        dat.add r
        off.putU64Le(uint64(dat.len))
      (dat, off)

    proc metaDatWithFlags(flags: uint16): string =
      # Only the fixed header is needed: `extractInterningTablePaths`
      # reads the flag word at offset 6 and nothing else. The body is
      # deliberately absent so this fixture cannot accidentally be
      # answered by the `meta.dat`-paths fallback instead.
      result.add "CTMD"
      result.putU16Le(4)
      result.putU16Le(flags)

    let (dat, off) = pathsTable(@[
      framedRecord(PathA, CountA), framedRecord(PathB, CountB)])

    block declared:
      let ctPath = root / "declared.ct"
      let outDir = root / "declared-out"
      createDir(outDir)
      writeMinimalCtfs(ctPath, @[
        ("meta.dat", metaDatWithFlags(0x4000'u16)),
        ("paths.dat", dat),
        ("paths.off", off)])

      check materializeCtfsSources(ctPath, outDir)
      let got = readFile(outDir / "paths.json")
      check got.contains("\"" & PathA & "\"")
      check got.contains("\"" & PathB & "\"")
      # And the framing must NOT be in there: a record read whole ends in
      # the count byte, so the path would not be followed by a closing
      # quote.
      check not got.contains(PathA & "\\u")
      check not got.contains(PathB & "\\u")

    block undeclared:
      ## The mutation control. The same records with bit 14 CLEAR are
      ## read whole, so the paths come back with their framing attached.
      ## If clearing the bit changed nothing the bit would be decorative
      ## and the block above would prove nothing about it.
      let ctPath = root / "undeclared.ct"
      let outDir = root / "undeclared-out"
      createDir(outDir)
      writeMinimalCtfs(ctPath, @[
        ("meta.dat", metaDatWithFlags(0'u16)),
        ("paths.dat", dat),
        ("paths.off", off)])

      check materializeCtfsSources(ctPath, outDir)
      let got = readFile(outDir / "paths.json")
      check not got.contains("\"" & PathA & "\"")
