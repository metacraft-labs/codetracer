## Unit tests for ``ctfs_sources``: ct's own CTFS container and ``meta.dat``
## reader, and the source materialization built on it.
##
## Most fixtures are hand-built containers (``writeMinimalCtfs``), because a
## refusal case needs bytes no correct writer produces.  The suite "the pinned
## writer's container" instead records through the canonical Nim writer
## (``codetracer-trace-format-nim``'s ``MultiStreamTraceWriter``, the sibling
## checkout on ct's Nim path), so the reader is also tested against a container
## it did not shape itself.  Nothing here is mocked: every case reads a real
## file through the real reader.

import std/[os, posix, strutils, unittest]

import results
from codetracer_ctfs/types import nil
from codetracer_trace_writer/multi_stream_writer import
  initMultiStreamWriter, registerPath, registerStep, close, closeCtfs

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

const
  TestBlockSize = 1024
  TestMaxEntries = 8
  CtfsDirect = 1'u64 shl 63

proc putPtr(data: var string, blk, slot: int, value: uint64) =
  for i in 0 ..< 8:
    data[blk * TestBlockSize + slot * 8 + i] = char((value shr (8 * i)) and 0xff)

proc writeMinimalCtfs(path: string, files: seq[(string, string)]) =
  ## A version 5 container (``ctfs-container.md`` §2): an empty member owns
  ## no block, a member of at most one block is that block with its
  ## ``MapBlock`` tagged, and a larger one has a level-1 mapping block
  ## claimed before its data blocks.
  doAssert files.len <= TestMaxEntries
  var data = newString(TestBlockSize)
  for i in 0 ..< data.len: data[i] = '\0'
  var header = ""
  header.add "\xC0\xDE\x72\xAC\xE2"
  header.add char(5)
  header.add char(0)
  header.add char(0)
  header.putU32Le(TestBlockSize)
  header.putU32Le(TestMaxEntries)
  var root = header
  proc alloc(data: var string): int =
    result = data.len div TestBlockSize
    data.setLen(data.len + TestBlockSize)
    for i in result * TestBlockSize ..< data.len: data[i] = '\0'
  for file in files:
    let bytes = file[1]
    var mapBlock = 0'u64
    if bytes.len == 0:
      mapBlock = 0
    elif bytes.len <= TestBlockSize:
      let blk = alloc(data)
      for i, c in bytes: data[blk * TestBlockSize + i] = c
      mapBlock = CtfsDirect or uint64(blk)
    else:
      let mapping = alloc(data)
      var slot = 0
      var pos = 0
      while pos < bytes.len:
        let blk = alloc(data)
        let n = min(TestBlockSize, bytes.len - pos)
        for i in 0 ..< n: data[blk * TestBlockSize + i] = bytes[pos + i]
        data.putPtr(mapping, slot, uint64(blk))
        inc slot
        pos += n
      mapBlock = uint64(mapping)
    root.writeEntry(uint64(bytes.len), mapBlock, file[0])
  for i, c in root: data[i] = c
  writeFile(path, data)

proc patchEntry(path: string, slot: int, size, mapBlock: uint64) =
  var data = readFile(path)
  var entry = ""
  entry.putU64Le(size)
  entry.putU64Le(mapBlock)
  for i, c in entry: data[16 + slot * 24 + i] = c
  writeFile(path, data)

proc pathsTable(paths: seq[string]): (string, string) =
  var dat = ""
  var off = ""
  off.putU64Le(0)
  for p in paths:
    dat.add p
    off.putU64Le(uint64(dat.len))
  (dat, off)

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

    proc metaDatWithFlags(flags: uint16): string =
      # Only the fixed header is needed: `extractInterningTablePaths`
      # reads the flag word at offset 6 and nothing else.
      result.add "CTMD"
      result.putU16Le(7)
      result.putU16Le(flags)
      result.putU32Le(0)

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

    block columnAwareWithConventionalTable:
      ## Bit 4 (column-aware) frames each record as Layout A:
      ## `path_len + path_bytes + line_count + line_lengths`. A record
      ## stating `line_count = 0` is the conventional table and carries no
      ## `line_lengths`, so it is one byte shorter than any record with a
      ## table. It sits between two records that have one, and each path
      ## must still be read from its own record.
      const PathC = "/workspace/project/build/firmware.bin"
      proc layoutARecord(path: string, lineLengths: seq[uint64]): string =
        result.putLeb128(uint64(path.len))
        result.add path
        result.putLeb128(uint64(lineLengths.len))
        for length in lineLengths:
          # Every length here is below 64 and each delta from the previous
          # one is non-negative, so its zigzag form is twice the delta.
          result.putLeb128(length * 2)
      let (layoutA, layoutAOff) = pathsTable(@[
        layoutARecord(PathA, @[12'u64, 3]),
        layoutARecord(PathC, @[]),
        layoutARecord(PathB, @[20'u64])])
      let ctPath = root / "column-aware.ct"
      let outDir = root / "column-aware-out"
      createDir(outDir)
      writeMinimalCtfs(ctPath, @[
        ("meta.dat", metaDatWithFlags(0x10'u16)),
        ("paths.dat", layoutA),
        ("paths.off", layoutAOff)])

      check materializeCtfsSources(ctPath, outDir)
      let got = readFile(outDir / "paths.json")
      for path in [PathA, PathC, PathB]:
        check got.contains("\"" & path & "\"")
      check not got.contains("\\u")

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
                  withPathList = false, argsCount = 0'u64): string =
  ## A complete ``meta.dat`` body stamped with an explicit version, laid out
  ## as version 7 (``internal-files.md`` §"Metadata (meta.dat)"):
  ## ``flags_ext`` always present, nothing after ``recorder_id``.
  ##
  ## ``withPathList`` appends the path list versions 3 to 5 wrote after
  ## ``recorder_id``; versions 6 and 7 have none, and a reader must not look
  ## for one.
  result.add "CTMD"
  result.putU16Le(version)
  result.putU16Le(0)  # flags — no optional blocks
  result.putU32Le(extFlags)
  result.putVarString(RecordingId)
  result.putVarString(Program)
  result.putLeb128(argsCount)  # args (none follow: a count past 0 is a lie)
  result.putVarString(Workdir)
  result.putVarString(RecorderId)
  if withPathList:
    result.putLeb128(uint64(SrcPaths.len))
    for p in SrcPaths:
      result.putVarString(p)

proc writeContainerWithMetaDat(root: string, name: string, version: uint16,
                               extFlags: uint32 = 0,
                               withPathList = false,
                               paths: seq[string] = SrcPaths): string =
  result = root / name
  var files = @[("meta.dat", buildMetaDat(version, extFlags, withPathList))]
  if paths.len > 0:
    let (dat, off) = pathsTable(paths)
    files.add ("paths.dat", dat)
    files.add ("paths.off", off)
  writeMinimalCtfs(result, files)

proc refusal(ctPath: string): string =
  try:
    discard readCtfsMetaDat(ctPath)
  except ValueError as e:
    return e.msg
  ""

suite "CTFS meta.dat version gate":
  test "an argument count past the bytes left is refused before allocating":
    ## A declared 2^60 arguments: `newSeqOfCap` of that would ask for
    ## 2^64 bytes.
    let root = getTempDir() / "ctfs-args-count-" & $getCurrentProcessId()
    createDir(root)
    defer: removeDir(root)
    let ct = root / "trace.ct"
    writeMinimalCtfs(ct, @[("meta.dat", buildMetaDat(7, argsCount = 1'u64 shl 60))])
    check refusal(ct).contains("args_count is 1152921504606846976")

  test "version 7 is the one accepted":
    ## Literals, not the constants under test: an assertion written as
    ## `SupportedMetaDatVersion == SupportedMetaDatVersion` is an
    ## equation nothing can fail.
    check SupportedMetaDatVersion == 7'u16
    check LastShiftedGlobalIndexVersion == 3'u16

  test "a current container is read, its paths from paths.dat":
    let root = getTempDir() / "ctfs-metadat-version-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let parsed = readCtfsMetaDat(writeContainerWithMetaDat(root, "current.ct", 7))
    check parsed.recordingId == RecordingId
    check parsed.program == Program
    check parsed.workdir == Workdir
    check parsed.paths == SrcPaths

    let reload = readCtfsMetaDat(writeContainerWithMetaDat(root, "reload.ct", 7,
      extFlags = FlagExtHasSourceReload))
    check reload.program == Program

  test "the paths are paths.dat's, never a list in meta.dat":
    let root = getTempDir() / "ctfs-metadat-nolist-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    # A version 7 header with no paths.dat names no source path.
    let bare = writeContainerWithMetaDat(root, "bare.ct", 7, paths = @[])
    check readCtfsMetaDat(bare).paths.len == 0
    let outDir = root / "out"
    createDir(outDir)
    discard materializeCtfsSources(bare, outDir)
    check not fileExists(outDir / "paths.json")

    # A path list after recorder_id is not read as one.
    let listed = writeContainerWithMetaDat(root, "listed.ct", 7,
      withPathList = true, paths = @["/only/from/paths.dat.c"])
    check readCtfsMetaDat(listed).paths == @["/only/from/paths.dat.c"]

  test "every other version is refused by name":
    let root = getTempDir() / "ctfs-metadat-refused-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    for version in [3'u16, 4, 5, 8]:
      let message = refusal(writeContainerWithMetaDat(root,
        "v" & $version & ".ct", version, withPathList = true))
      check message.contains("version " & $version)
      check message.contains("version 7")
    # Version 6 has version 7's layout, and is refused all the same.
    let v6 = refusal(writeContainerWithMetaDat(root, "v6.ct", 6))
    check v6.contains("version 6")
    check v6.contains("version 7")
    # Only the superseded encode is diagnosed as one.
    check refusal(writeContainerWithMetaDat(root, "v3.ct", 3)).contains("one line high")
    check not refusal(writeContainerWithMetaDat(root, "v6.ct", 6)).contains("one line high")

  test "the extended flag word is validated, and the header is 12 bytes":
    let root = getTempDir() / "ctfs-metadat-ext-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let unknownBit = not KnownExtFlags
    check unknownBit != 0'u32  # or the fixture below is not a fixture
    check refusal(writeContainerWithMetaDat(root, "badext.ct", 7,
      extFlags = unknownBit)).contains("unknown extended flag")

    let short = root / "short.ct"
    writeMinimalCtfs(short, @[("meta.dat", buildMetaDat(7)[0 ..< 11])])
    check refusal(short).len > 0

suite "CTFS container version 5":
  test "a container of another version is refused by name":
    let root = getTempDir() / "ctfs-container-version-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let ct = writeContainerWithMetaDat(root, "c.ct", 7)
    for version in [3, 4, 7]:
      var data = readFile(ct)
      data[5] = char(version)
      let patched = root / ("c" & $version & ".ct")
      writeFile(patched, data)
      let message = refusal(patched)
      check message.contains("version " & $version)
      check message.contains("5")

  test "the source materialiser raises the refusal instead of answering false":
    ## ``materializeCtfsSources`` is the IMPORT path's reader, and the
    ## refusal above must reach its callers with the field it names
    ## (``ctfs-container.md``: "A reader must name the field it is refusing
    ## on").  It used to catch ``openCtfs``'s exception and answer ``false``,
    ## which its callers cannot tell from "this container names no sources"
    ## (codetracer-pm issue
    ## ``2026-10-04-ct-importer-turns-a-container-refusal-into-false.md``).
    let root = getTempDir() / "ctfs-container-materialize-" &
      $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let ct = writeContainerWithMetaDat(root, "c.ct", 7)
    for version in [3, 4]:
      var data = readFile(ct)
      data[5] = char(version)
      let patched = root / ("c" & $version & ".ct")
      writeFile(patched, data)
      let outDir = root / ("out" & $version)
      createDir(outDir)
      var message = ""
      try:
        discard materializeCtfsSources(patched, outDir)
      except ValueError as e:
        message = e.msg
      check message.contains(
        "CTFS container version " & $version & " is not readable")
      check message.contains("Re-record the trace")
      # Nothing was unpacked from a container that was refused.
      check not fileExists(outDir / "paths.json")

    # The control: the same container at its own version still opens, so
    # the raise above is the version byte's doing and not the fixture's.
    let okOut = root / "out-ok"
    createDir(okOut)
    check materializeCtfsSources(ct, okOut)

  test "members are read in each form":
    let root = getTempDir() / "ctfs-container-forms-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    # Enough paths that paths.dat outgrows one block and is mapped, while
    # paths.off stays one direct block.
    var many: seq[string] = @[]
    for i in 0 ..< 40:
      many.add "/workspace/project/src/a_rather_long_module_name_" & $i & ".c"
    let ct = writeContainerWithMetaDat(root, "forms.ct", 7, paths = many)
    check readCtfsMetaDat(ct).paths == many

    # A member written mapped while its size is still one block -- the state
    # a live reader can observe mid-transition -- is read through its mapping.
    let transition = root / "transition.ct"
    writeMinimalCtfs(transition, @[("meta.dat", buildMetaDat(7))])
    var data = readFile(transition)
    let blk = data.len div TestBlockSize
    data.setLen(data.len + TestBlockSize)
    for i in blk * TestBlockSize ..< data.len: data[i] = '\0'
    data.putPtr(blk, 0, 1)
    writeFile(transition, data)
    patchEntry(transition, 0, uint64(buildMetaDat(7).len), uint64(blk))
    check readCtfsMetaDat(transition).program == Program

  test "a null or oversized member is refused, not read":
    let root = getTempDir() / "ctfs-container-null-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let ct = writeContainerWithMetaDat(root, "n.ct", 7, paths = @[])
    let size = uint64(buildMetaDat(7).len)
    for (s, m, what) in [(size, 0'u64, "null"), (size, CtfsDirect, "null"),
                         (5000'u64, CtfsDirect or 1, "one block")]:
      patchEntry(ct, 0, s, m)
      let message = refusal(ct)
      check message.contains("meta.dat")
      check message.contains(what)
      check not message.contains("truncat")

    # An empty member is present and empty.
    patchEntry(ct, 0, 0, 0)
    check refusal(ct).contains("missing or empty")

  test "a version 6 full container is read, and its other fields refused":
    let root = getTempDir() / "ctfs-container-v6-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    # Version 6 is version 5's body behind a 24-byte header: rebuild a v5
    # container with the entry array moved 8 bytes along.
    let v5 = writeContainerWithMetaDat(root, "v5.ct", 7)
    proc toV6(profile, compression, reserved: int): string =
      let data = readFile(v5)
      result = data[0 ..< 16] & char(profile) & char(compression) &
        "\0\0\0\0\0" & char(reserved) &
        data[16 ..< TestBlockSize - 8] & data[TestBlockSize .. ^1]
    let full = root / "full.ct"
    writeFile(full, toV6(0, 0, 0))
    var data = readFile(full)
    data[5] = char(6)
    writeFile(full, data)
    check readCtfsMetaDat(full).paths == SrcPaths
    for (p, c, r, what) in [(1, 0, 0, "profile 1"), (0, 1, 0, "compression 1"),
                            (0, 0, 4, "reserved")]:
      var bad = toV6(p, c, r)
      bad[5] = char(6)
      let path = root / "bad.ct"
      writeFile(path, bad)
      check refusal(path).contains(what)

# ---------------------------------------------------------------------------
# A container written by the pinned writer
# ---------------------------------------------------------------------------

proc captureStdout(body: proc ()): string =
  ## Everything ``body`` writes to file descriptor 1, which is where the
  ## ``ct host: warning: ...`` lines from ``materializeCtfsSources`` go
  ## (``echo``).  The descriptor itself is redirected, not Nim's ``stdout``
  ## object, so output from any layer that writes fd 1 is caught; stdout is
  ## flushed on both sides so nothing buffered before or during the call lands
  ## on the wrong side of the redirect.
  let capturePath = getTempDir() / "ctfs-sources-stdout-" &
    $getCurrentProcessId() & ".txt"
  flushFile(stdout)
  let saved = dup(1)
  doAssert saved >= 0, "dup(1) failed"
  let fd = posix.open(capturePath.cstring, O_WRONLY or O_CREAT or O_TRUNC,
    0o600.Mode)
  doAssert fd >= 0, "cannot open " & capturePath
  doAssert dup2(fd, 1) >= 0, "dup2 onto fd 1 failed"
  discard posix.close(fd)
  try:
    body()
  finally:
    flushFile(stdout)
    doAssert dup2(saved, 1) >= 0, "restoring fd 1 failed"
    discard posix.close(saved)
  result = readFile(capturePath)
  removeFile(capturePath)

suite "the pinned writer's container":
  ## The container ``codetracer-trace-format-nim``'s ``MultiStreamTraceWriter``
  ## writes for an ordinary recording: one source path, a few steps, and no
  ## ``filemap.bin`` -- only MCR writes one.  The issue
  ## ``codetracer-pm/issues/2026-10-03-ct-and-backend-manager-still-refuse-the-container-the-pinned-writer-produces.md``
  ## is what a reader tested only on its own fixtures looks like: it refused
  ## the container the writer actually produced, and then, once it read it,
  ## warned on every import that ``filemap.bin`` was missing.
  const
    WriterRecordingId = "0192f4a0-0000-7000-8000-000000000001"
    SourceText = "x = 1\ny = x + 1\nprint(y)\n"

  proc recordWithWriter(root: string): (string, string) =
    ## Records ``main.py`` through the writer's file-backed path, the one
    ## recorders use: the container streams to disk and ``closeCtfs`` writes
    ## its final root block.  Returns the ``.ct`` path and the source path.
    let ctPath = root / "trace.ct"
    let src = root / "main.py"
    writeFile(src, SourceText)
    var w = initMultiStreamWriter(ctPath, src,
      recordingId = WriterRecordingId).get()
    let pathId = w.registerPath(src).get()
    for line in 1'u64 .. 3'u64:
      w.registerStep(pathId, line, []).get()
    w.close().get()
    w.closeCtfs().get()
    (ctPath, src)

  test "is read, and materializes without a warning":
    let root = getTempDir() / "ctfs-pinned-writer-" & $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let (ctPath, src) = recordWithWriter(root)
    # The writer's own constant, so the check follows the pin rather than a
    # literal; the literal check says the pin still writes a version this
    # reader claims to read.
    let containerVersion = readFile(ctPath)[5].ord
    check containerVersion == int(types.CtfsVersion)
    check containerVersion in [SupportedCtfsVersion, CtfsVersionV6]

    let meta = readCtfsMetaDat(ctPath)
    check meta.recordingId == WriterRecordingId
    check meta.program == src
    check meta.paths == @[src]

    let outDir = root / "out"
    createDir(outDir)
    var materialized = false
    let output = captureStdout(proc () =
      materialized = materializeCtfsSources(ctPath, outDir))
    check materialized
    check readFile(outDir / "paths.json").contains("\"" & src & "\"")
    # An absent filemap.bin is the normal case for every non-MCR recording
    # (``UI-CTFS-Schema6-Source-Materialization.md``), not a failure.
    check output == ""

  test "a filemap.bin that is present but malformed is still reported":
    ## The control for the case above: the absent member is quiet because it
    ## is absent, not because filemap errors stopped being reported.  The
    ## writer's container is copied with one free entry slot turned into a
    ## one-block ``filemap.bin`` whose bytes are not a filemap.
    let root = getTempDir() / "ctfs-pinned-writer-badmap-" &
      $getCurrentProcessId()
    removeDir(root)
    createDir(root)
    defer: removeDir(root)

    let (ctPath, src) = recordWithWriter(root)
    var data = readFile(ctPath)
    let blockSize = int(data[8].ord) or (int(data[9].ord) shl 8) or
      (int(data[10].ord) shl 16) or (int(data[11].ord) shl 24)
    let entryStart = if data[5].ord == CtfsVersionV6: 24 else: 16
    # ``MaxEntries`` at offset 12; ``0`` fills the rest of block 0
    # (``ctfs-container.md`` §1).
    var maxEntries = int(data[12].ord) or (int(data[13].ord) shl 8) or
      (int(data[14].ord) shl 16) or (int(data[15].ord) shl 24)
    if maxEntries == 0:
      maxEntries = (blockSize - entryStart) div 24
    var slot = -1
    for i in 0 ..< maxEntries:
      let offset = entryStart + i * 24
      if data[offset ..< offset + 24] == repeat('\0', 24):
        slot = i
        break
    check slot >= 0  # or the fixture below is not a fixture
    const Garbage = "this is not a filemap"
    let blk = data.len div blockSize
    data.setLen(data.len + blockSize)
    for i in blk * blockSize ..< data.len: data[i] = '\0'
    for i, c in Garbage: data[blk * blockSize + i] = c
    var entry = ""
    entry.putU64Le(uint64(Garbage.len))
    entry.putU64Le(CtfsDirect or uint64(blk))
    entry.putU64Le(base40Encode("filemap.bin"))
    for i, c in entry: data[entryStart + slot * 24 + i] = c
    let badPath = root / "badmap.ct"
    writeFile(badPath, data)

    let outDir = root / "out"
    createDir(outDir)
    var materialized = false
    let output = captureStdout(proc () =
      materialized = materializeCtfsSources(badPath, outDir))
    # paths.dat still answers; the malformed filemap is reported beside it.
    check materialized
    check readFile(outDir / "paths.json").contains("\"" & src & "\"")
    check output.contains(
      "ct host: warning: failed to extract CTFS portable sources: " &
      "invalid CTFS filemap")
