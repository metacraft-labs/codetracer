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
