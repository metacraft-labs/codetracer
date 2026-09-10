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

# ---------------------------------------------------------------------------
# meta.dat schema version
# ---------------------------------------------------------------------------

const
  RecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  Program = "/workspace/project/src/main.c"
  Workdir = "/workspace/project"
  RecorderId = "ct-test/1.0"
  SrcPaths = @["/workspace/project/src/main.c",
               "/workspace/project/src/util.c"]

proc buildMetaDat(version: uint16, extFlags: uint32 = 0,
                  withExtWord = false): string =
  ## A complete ``meta.dat`` body stamped with an explicit version.
  ##
  ## The version is a parameter because the interesting fixture is the
  ## one no current writer produces: bytes that are correct in every
  ## other respect and differ only in the schema stamp. That single field
  ## is the only thing in a container that tells the superseded
  ## ``global_position_index`` packing apart from the current one, so it
  ## has to be the only thing that varies here.
  ##
  ## GDH-M2 added ``withExtWord``: schema version 5 inserts a
  ## ``[4] flags_ext u32 LE`` word after the u16 flags. It is a SEPARATE
  ## parameter from ``version`` on purpose — the two can disagree, and a
  ## fixture that stamps 5 without the word is exactly what a writer that
  ## bumped the version and forgot the payload would emit. Being able to
  ## build that shape is what lets the suite below assert the reader
  ## refuses it instead of reading the recording id's length prefix as a
  ## flag word.
  result.add "CTMD"
  result.putU16Le(version)
  result.putU16Le(0)  # flags — no optional blocks
  if withExtWord:
    result.putU32Le(extFlags)
  result.putVarString(RecordingId)
  result.putVarString(Program)
  result.putLeb128(0)  # args
  result.putVarString(Workdir)
  result.putVarString(RecorderId)
  result.putLeb128(uint64(SrcPaths.len))
  for p in SrcPaths:
    result.putVarString(p)

proc writeContainerWithMetaDat(root: string, name: string, version: uint16,
                               extFlags: uint32 = 0,
                               withExtWord = false): string =
  result = root / name
  writeMinimalCtfs(result, @[("meta.dat",
    buildMetaDat(version, extFlags, withExtWord))])

suite "CTFS meta.dat version gate":
  test "the accepted version is the one with the corrected line encode":
    ## Literals, not the constants under test: an assertion written as
    ## `SupportedMetaDatVersion == SupportedMetaDatVersion` is an
    ## equation nothing can fail.
    check SupportedMetaDatVersion == 4'u16
    check LastShiftedGlobalIndexVersion == 3'u16
    check SupportedMetaDatVersion > LastShiftedGlobalIndexVersion

  test "a current container is read, a superseded one is refused":
    let root = getTempDir() / "ctfs-metadat-version-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    # Both fixtures are byte-identical apart from the version stamp.
    let currentBytes = buildMetaDat(SupportedMetaDatVersion)
    let supersededBytes = buildMetaDat(LastShiftedGlobalIndexVersion)
    check currentBytes.len == supersededBytes.len
    check currentBytes[6 .. ^1] == supersededBytes[6 .. ^1]

    let currentCt = writeContainerWithMetaDat(root, "current.ct",
                                              SupportedMetaDatVersion)
    let parsed = readCtfsMetaDat(currentCt)
    check parsed.recordingId == RecordingId
    check parsed.program == Program
    check parsed.workdir == Workdir
    check parsed.paths == SrcPaths

    let supersededCt = writeContainerWithMetaDat(root, "superseded.ct",
                                                 LastShiftedGlobalIndexVersion)
    var refused = false
    var message = ""
    try:
      discard readCtfsMetaDat(supersededCt)
    except ValueError as e:
      refused = true
      message = e.msg
    check refused
    # Refused by name: the message has to say which version it rejected
    # and why, or the operator is left with a trace that "just fails".
    check message.contains("unsupported version 3")
    check message.contains("global_position_index")
    check message.contains("one line high")

  test "a version past the accepted one is refused without the encode claim":
    ## GDH-M2 moved the ceiling: version 5 is now ACCEPTED (it is the
    ## extended-flags schema), so the "one past the top" fixture is 6.
    ## The version is derived from the constants rather than written as a
    ## literal `6`, because the whole point of this case is that it keeps
    ## naming whatever the first UNSUPPORTED version is — a literal here
    ## would silently become a supported version the next time the
    ## ceiling moves, and the case would then assert nothing.
    let root = getTempDir() / "ctfs-metadat-future-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let firstUnsupported = MetaDatVersionExtendedFlags + 1
    check firstUnsupported > SupportedMetaDatVersion
    check firstUnsupported > MetaDatVersionExtendedFlags

    let futureCt = writeContainerWithMetaDat(root, "future.ct",
                                             firstUnsupported)
    var message = ""
    try:
      discard readCtfsMetaDat(futureCt)
    except ValueError as e:
      message = e.msg
    check message.contains("unsupported version " & $firstUnsupported)
    # A version past the correction does not carry shifted addresses, so
    # diagnosing it as such would be a guess dressed as a fact.
    check not message.contains("one line high")

  test "the extended-flags schema is read, and its flag word is validated":
    ## GDH-M2's fifth reader. `parseCtfsMetaDat` gained a version-5 branch
    ## that steps the body offset past a `[4] flags_ext u32 LE` word; until
    ## this case, nothing in the workspace exercised it here. All three
    ## fixtures differ from the accepted one by the header alone, so a
    ## failure is about the version handling and not about the body.
    let root = getTempDir() / "ctfs-metadat-ext-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    # 1. A well-formed v5 container is READ, and its body is read from
    #    offset 12. The paths are the witness: if the reader had taken the
    #    body from a fixed 8 it would have consumed the ext word as the
    #    recording id's length prefix and never reached them.
    let v5Ct = writeContainerWithMetaDat(root, "v5.ct",
      MetaDatVersionExtendedFlags, FlagExtHasSourceReload, withExtWord = true)
    let parsed = readCtfsMetaDat(v5Ct)
    check parsed.recordingId == RecordingId
    check parsed.program == Program
    check parsed.workdir == Workdir
    check parsed.paths == SrcPaths

    # 2. A v5 header carrying an extended bit this reader does not know
    #    must be REFUSED, not ignored — the same strict-rejection contract
    #    the u16's known-bits mask enforces.
    let unknownBit = not KnownExtFlags
    check unknownBit != 0'u32  # or the fixture below is not a fixture
    let badExtCt = writeContainerWithMetaDat(root, "badext.ct",
      MetaDatVersionExtendedFlags, unknownBit, withExtWord = true)
    var extMessage = ""
    try:
      discard readCtfsMetaDat(badExtCt)
    except ValueError as e:
      extMessage = e.msg
    check extMessage.contains("unknown extended flag")

    # 3. A header STAMPED 5 but carrying no ext word — what a writer that
    #    bumped the version and forgot the payload emits. It must be
    #    refused rather than read, and this is the case that would have
    #    caught the reader silently decoding the recording id's length
    #    prefix as a flag word.
    let noWordCt = writeContainerWithMetaDat(root, "nowword.ct",
      MetaDatVersionExtendedFlags)
    var noWordRefused = false
    try:
      discard readCtfsMetaDat(noWordCt)
    except ValueError:
      noWordRefused = true
    check noWordRefused

    # 4. A v5 header with a present but ALL-ZERO extended word — a
    #    container that spent a schema version on nothing, which is what a
    #    writer that bumped the version unconditionally emits. The
    #    canonical reader (`meta_dat.nim`) refuses it by name and this one
    #    must AGREE: if the two disagree about what a valid v5 container
    #    is, then "which reader opened it" becomes part of the format.
    let zeroExtCt = writeContainerWithMetaDat(root, "zeroext.ct",
      MetaDatVersionExtendedFlags, 0'u32, withExtWord = true)
    var zeroExtMessage = ""
    try:
      discard readCtfsMetaDat(zeroExtCt)
    except ValueError as e:
      zeroExtMessage = e.msg
    check zeroExtMessage.contains("all-zero flags_ext")
