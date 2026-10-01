## `ct upload` must not replace a user's recording with a lossier one.
##
## `enrichMcrTraceIfNeeded` runs `ct-mcr export --portable` into a `.portable`
## temp file and, **on exit code 0**, `moveFile`s it over the original `.ct`.
## The comment there says the temp file exists "to avoid corrupting the trace
## on failure" — but the failure this guards against is not a failure by exit
## code. `ct-mcr export --portable` was measured (see
## `codetracer-native-recorder/ct_cli/tests/test_export_portable_refuses_unreadable_members.nim`)
## exiting **0** having silently dropped a member of the input it could not
## read: a real 94 208-byte, six-member recording cut by one 4 096-byte block
## exported to a five-member container, with the loss reported on one
## `--verbose`-only line. The user's only copy was then overwritten by it.
##
## Export now refuses such an input, which closes that particular route. This
## suite pins the *other* half, which is separable and outlives any one export
## bug: the replacement decision itself must not rest on the exit code alone.
##
## # Why a stub `ct-mcr` here, and what is real
##
## The subject under test is `enrichMcrTraceIfNeeded`'s decision to overwrite
## the user's file, and the input to that decision is a pair of containers plus
## an exit code. Building and invoking the real `ct-mcr` — which lives in a
## different repo and needs its own toolchain — would make this suite depend on
## a sibling checkout to answer a question that does not involve one. So the
## exporter is a shell script driven through the module's own documented
## `CODETRACER_CT_MCR_CMD` hook, and it reproduces exactly the behaviour that
## was *measured* from the real one: write an output that is missing a member of
## the input, and exit 0.
##
## Everything the decision actually examines is real: both containers are
## written by the production CTFS writer (`codetracer_ctfs/container.nim`) onto
## a real filesystem, the discovery path is the real `findCtFileInFolder`, and
## the process really is spawned and really does exit 0.

import std/[os, osproc, strutils, unittest]
import results
import codetracer_ctfs/container
import codetracer_ctfs/base40
import mcr_enrichment

const
  BlockSize = 4096'u32
  HeaderSize = 8
  ExtHeaderSize = 8
  FileEntrySize = 24

proc readU64At(data: openArray[byte], offset: int): uint64 =
  var v = 0'u64
  for i in countdown(7, 0):
    v = (v shl 8) or uint64(data[offset + i])
  v

proc readU32At(data: openArray[byte], offset: int): uint32 =
  var v = 0'u32
  for i in countdown(3, 0):
    v = (v shl 8) or uint32(data[offset + i])
  v

proc memberNames(path: string): seq[string] =
  ## The names in the container's root directory. Block 0 only — no §4 mapping
  ## walk — so this observer cannot itself be fooled by a mapping defect.
  result = @[]
  let dataRes = readCtfsFromFile(path)
  doAssert dataRes.isOk, "failed to read " & path & ": " & dataRes.error
  let data = dataRes.get()
  let maxRootEntries = int(readU32At(data, 12))
  for i in 0 ..< maxRootEntries:
    let off = HeaderSize + ExtHeaderSize + i * FileEntrySize
    if off + FileEntrySize > data.len:
      break
    let nameEncoded = readU64At(data, off + 16)
    if nameEncoded == 0:
      continue
    result.add(base40Decode(nameEncoded))

proc writeContainer(path: string, members: openArray[(string, string)]) =
  ## Write a real container holding the given `(name, content)` members.
  var c = createCtfs(BlockSize, 32)
  for (name, content) in members:
    let fRes = c.addFile(name)
    doAssert fRes.isOk, "addFile " & name & " failed: " & fRes.error
    var f = fRes.get()
    var bytes = newSeq[byte](content.len)
    for i in 0 ..< content.len:
      bytes[i] = byte(content[i])
    let wRes = c.writeToFile(f, bytes)
    doAssert wRes.isOk, "writeToFile " & name & " failed: " & wRes.error
  let saveRes = c.writeCtfsToFile(path)
  doAssert saveRes.isOk, "writeCtfsToFile failed: " & saveRes.error

proc writeWideContainer(path: string, count: int, skip = -1) =
  ## A real container declaring `count` root entries — more than block 0's 170
  ## when `count` > 170, so its entry array continues into the blocks after
  ## block 0 (`ctfs-container.md` §1) — holding members `w0.bin` ..
  ## `w<count-1>.bin`, minus `skip`.  This is the shape of a recording that
  ## takes periodic checkpoints (three members per checkpoint).
  var c = createCtfs(BlockSize, uint32(count))
  for i in 0 ..< count:
    if i == skip: continue
    let name = "w" & $i & ".bin"
    let fRes = c.addFile(name)
    doAssert fRes.isOk, "addFile " & name & " failed: " & fRes.error
    var f = fRes.get()
    doAssert c.writeToFile(f, [byte(i and 0xFF), byte(i shr 8)]).isOk
  doAssert c.writeCtfsToFile(path).isOk

proc writeStubExporter(dir: string, body: string): string =
  ## A stand-in for `ct-mcr`, installed through the module's own
  ## `CODETRACER_CT_MCR_CMD` hook. `body` receives `$OUT` (the path the caller
  ## asked the export to be written to) and `$IN` (the input trace).
  let script = dir / "ct-mcr-stub.sh"
  writeFile(script, """#!/usr/bin/env bash
set -euo pipefail
# ct-mcr export --portable -o <output> <input>
OUT=""
IN=""
while [ $# -gt 0 ]; do
  case "$1" in
    export|--portable) shift ;;
    -o) OUT="$2"; shift 2 ;;
    *) IN="$1"; shift ;;
  esac
done
""" & body & "\n")
  when not defined(windows):
    discard execCmdEx("chmod +x " & script.quoteShell)
  script

suite "MCR Enrichment — the replacement must not rest on the exit code alone":

  setup:
    let tmpDir = getTempDir() / "test_mcr_enrich_member_check"
    removeDir(tmpDir)
    createDir(tmpDir)
    let ctPath = tmpDir / "trace.ct"
    # A recording with six members, the shape `ct-mcr record` produces.
    writeContainer(ctPath, [
      ("meta.dat", "metadata bytes"),
      ("platform.bin", "platform bytes"),
      ("recordcfg.bi", "record config"),
      ("t00000000001", "thread stream bytes"),
      ("eventlog.dat", "event log bytes"),
      ("eventlog.idx", "event log index"),
    ])
    let before = memberNames(ctPath)

  teardown:
    delEnv("CODETRACER_CT_MCR_CMD")
    removeDir(tmpDir)

  test "an export that drops a member does not replace the original":
    # Exactly what the real exporter did: copy the input minus one member, and
    # exit 0. Built here with the same production writer, so the "export" is a
    # genuine, well-formed container — it is simply missing `eventlog.idx`.
    let lossy = tmpDir / "lossy-source.ct"
    writeContainer(lossy, [
      ("meta.dat", "metadata bytes"),
      ("platform.bin", "platform bytes"),
      ("recordcfg.bi", "record config"),
      ("t00000000001", "thread stream bytes"),
      ("eventlog.dat", "event log bytes"),
    ])
    let stub = writeStubExporter(tmpDir, "cp " & lossy.quoteShell & " \"$OUT\"\nexit 0")
    putEnv("CODETRACER_CT_MCR_CMD", stub)

    let enriched = enrichMcrTraceIfNeeded(tmpDir)

    let after = memberNames(ctPath)
    check "eventlog.idx" in before
    check "eventlog.idx" in after
    check after.len == before.len
    check not enriched

  test "the temp file is not left behind when the export is rejected":
    let lossy = tmpDir / "lossy-source2.ct"
    writeContainer(lossy, [
      ("meta.dat", "metadata bytes"),
      ("eventlog.dat", "event log bytes"),
    ])
    let stub = writeStubExporter(tmpDir, "cp " & lossy.quoteShell & " \"$OUT\"\nexit 0")
    putEnv("CODETRACER_CT_MCR_CMD", stub)

    discard enrichMcrTraceIfNeeded(tmpDir)
    check not fileExists(ctPath & ".portable")

  test "an export that shortens a member does not replace the original":
    # Same names, one stream truncated: a member-count check alone would pass
    # this, and the user would still lose bytes.
    let shortened = tmpDir / "short-source.ct"
    writeContainer(shortened, [
      ("meta.dat", "metadata bytes"),
      ("platform.bin", "platform bytes"),
      ("recordcfg.bi", "record config"),
      ("t00000000001", "thread"),          # shorter than the original
      ("eventlog.dat", "event log bytes"),
      ("eventlog.idx", "event log index"),
    ])
    let stub = writeStubExporter(tmpDir, "cp " & shortened.quoteShell & " \"$OUT\"\nexit 0")
    putEnv("CODETRACER_CT_MCR_CMD", stub)

    let enriched = enrichMcrTraceIfNeeded(tmpDir)

    let contentRes = readCtfsFromFile(ctPath)
    check contentRes.isOk
    let orig = readInternalFile(contentRes.get(), "t00000000001")
    check orig.isOk
    check orig.get().len == "thread stream bytes".len
    check not enriched

  test "an export whose mapping roots are null does not replace the original":
    # The comparison reads the root directory only, and deliberately does not
    # walk §4. That leaves it satisfiable by an export whose directory is
    # perfect and whose content is entirely unreachable: zero every entry's
    # mapping root and every name and size still matches. Reproduced against
    # the earlier revision of this check, which accepted it. The block
    # arithmetic — no walk, no data read — is what refuses it.
    let hollow = tmpDir / "hollow-source.ct"
    writeContainer(hollow, [
      ("meta.dat", "metadata bytes"),
      ("platform.bin", "platform bytes"),
      ("recordcfg.bi", "record config"),
      ("t00000000001", "thread stream bytes"),
      ("eventlog.dat", "event log bytes"),
      ("eventlog.idx", "event log index"),
    ])
    var data = readCtfsFromFile(hollow).get()
    let maxRoot = int(readU32At(data, 12))
    for i in 0 ..< maxRoot:
      let off = HeaderSize + ExtHeaderSize + i * FileEntrySize
      if off + FileEntrySize > data.len: break
      if readU64At(data, off + 16) == 0: continue
      for j in 0 ..< 8:
        data[off + 8 + j] = 0
    writeFile(hollow, data)

    let stub = writeStubExporter(tmpDir, "cp " & hollow.quoteShell & " \"$OUT\"\nexit 0")
    putEnv("CODETRACER_CT_MCR_CMD", stub)

    check not enrichMcrTraceIfNeeded(tmpDir)
    let after = memberNames(ctPath)
    for n in before:
      check n in after
    let still = readInternalFile(readCtfsFromFile(ctPath).get(), "t00000000001")
    check still.isOk
    check still.get().len == "thread stream bytes".len

  test "a truncated export does not replace the original":
    # The other way a perfect directory can front for absent content: cut whole
    # blocks off the tail. Names and sizes are untouched, so the member
    # comparison alone passes it.
    let cut = tmpDir / "cut-source.ct"
    writeContainer(cut, [
      ("meta.dat", "metadata bytes"),
      ("platform.bin", "platform bytes"),
      ("recordcfg.bi", "record config"),
      ("t00000000001", "thread stream bytes"),
      ("eventlog.dat", "event log bytes"),
      ("eventlog.idx", "event log index"),
    ])
    let full = readCtfsFromFile(cut).get()
    writeFile(cut, full[0 ..< full.len - int(BlockSize)])

    let stub = writeStubExporter(tmpDir, "cp " & cut.quoteShell & " \"$OUT\"\nexit 0")
    putEnv("CODETRACER_CT_MCR_CMD", stub)

    check not enrichMcrTraceIfNeeded(tmpDir)
    check memberNames(ctPath).len == before.len

  test "a faithful export that only ADDS members does replace the original":
    # The control. This is what a real, successful `--portable` export looks
    # like: every input member preserved, plus the bundled binaries. Rejecting
    # this would make the check useless by breaking enrichment outright.
    let good = tmpDir / "good-source.ct"
    writeContainer(good, [
      ("meta.dat", "metadata bytes"),
      ("platform.bin", "platform bytes"),
      ("recordcfg.bi", "record config"),
      ("t00000000001", "thread stream bytes"),
      ("eventlog.dat", "event log bytes"),
      ("eventlog.idx", "event log index"),
      ("b/0001", "the bundled main binary"),
      ("filemap.bin", "the merged provenance carrier"),
    ])
    let stub = writeStubExporter(tmpDir, "cp " & good.quoteShell & " \"$OUT\"\nexit 0")
    putEnv("CODETRACER_CT_MCR_CMD", stub)

    let enriched = enrichMcrTraceIfNeeded(tmpDir)

    check enriched
    let after = memberNames(ctPath)
    for n in before:
      check n in after
    check "b/0001" in after
    check not fileExists(ctPath & ".portable")

  test "a non-zero exit still leaves the original alone":
    let stub = writeStubExporter(tmpDir, "echo 'boom' >&2\nexit 3")
    putEnv("CODETRACER_CT_MCR_CMD", stub)

    let enriched = enrichMcrTraceIfNeeded(tmpDir)

    check not enriched
    check memberNames(ctPath).len == before.len

suite "MCR Enrichment — a root directory larger than block 0":
  # `readCtfsRootDir` used to clamp the entry count to block 0, so a recording
  # with more than 170 members was compared on its first 170 only: an export
  # that dropped any later member was accepted and moved over the user's
  # original.  These use `exportKeptEveryMember` directly — the decision's
  # own comparison — over real overflowed containers.

  setup:
    let wideDir = getTempDir() / "test_mcr_enrich_wide_root"
    removeDir(wideDir)
    createDir(wideDir)

  teardown:
    removeDir(wideDir)

  test "an export that drops a member whose entry is past block 0 is refused":
    let original = wideDir / "orig.ct"
    let lossy = wideDir / "lossy.ct"
    writeWideContainer(original, 200)
    writeWideContainer(lossy, 200, skip = 190)
    # The control on the fixture: entry 190 really is past block 0.
    check HeaderSize + ExtHeaderSize + 190 * FileEntrySize >= int(BlockSize)
    let (ok, reason) = exportKeptEveryMember(original, lossy)
    check not ok
    check "w190.bin" in reason

  test "a faithful export of a wide recording is accepted":
    let original = wideDir / "orig2.ct"
    let faithful = wideDir / "faithful.ct"
    writeWideContainer(original, 200)
    writeWideContainer(faithful, 200)
    let (ok, reason) = exportKeptEveryMember(original, faithful)
    check ok
    check reason == ""

# ---------------------------------------------------------------------------
# Container version 5 (`ctfs-container.md` §1, §2)
# ---------------------------------------------------------------------------

const CtfsDirect = 1'u64 shl 63

proc putU64(data: var seq[byte], offset: int, value: uint64) =
  for i in 0 ..< 8:
    data[offset + i] = byte((value shr (8 * i)) and 0xFF)

proc rawContainer(path: string, blocks: int,
                  entries: openArray[(string, uint64, uint64)],
                  version = 5'u8) =
  ## A container of `blocks` blocks whose root directory holds `entries` as
  ## `(name, Size, MapBlock)`, written byte by byte from the specification.
  var data = newSeq[byte](blocks * int(BlockSize))
  for i, b in [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]:
    data[i] = b
  data[5] = version
  for i in 0 ..< 4:
    data[8 + i] = byte((BlockSize shr (8 * i)) and 0xFF)
  data[12] = 31
  for i, (name, size, mapBlock) in entries:
    let off = HeaderSize + ExtHeaderSize + i * FileEntrySize
    data.putU64(off, size)
    data.putU64(off + 8, mapBlock)
    data.putU64(off + 16, base40Encode(name))
  var s = newString(data.len)
  for i, b in data:
    s[i] = char(b)
  writeFile(path, s)

suite "MCR Enrichment — container version 5":

  setup:
    let v5Dir = getTempDir() / "test_mcr_enrich_v5"
    removeDir(v5Dir)
    createDir(v5Dir)
    let original = v5Dir / "orig.ct"
    # Three one-block members and an empty one: version 5 gives them no
    # mapping block, so the container is block 0 plus three data blocks.
    rawContainer(original, 4, [
      ("meta.dat", 10'u64, CtfsDirect or 1),
      ("platform.bin", 20'u64, CtfsDirect or 2),
      ("t00000000001", 30'u64, CtfsDirect or 3),
      ("eventlog.idx", 0'u64, 0'u64)])

  teardown:
    removeDir(v5Dir)

  test "an export of one-block members, none with a mapping block, is accepted":
    let exported = v5Dir / "export.ct"
    rawContainer(exported, 7, [
      ("meta.dat", 10'u64, CtfsDirect or 1),
      ("platform.bin", 20'u64, CtfsDirect or 2),
      ("t00000000001", 30'u64, CtfsDirect or 3),
      ("eventlog.idx", 0'u64, 0'u64),
      ("b/0001", 5000'u64, 4'u64)])  # mapped: block 4 maps data blocks 5, 6
    let (ok, reason) = exportKeptEveryMember(original, exported)
    check reason == ""
    check ok

  test "an export of another container version is refused by name":
    let exported = v5Dir / "v4.ct"
    rawContainer(exported, 4, [
      ("meta.dat", 10'u64, CtfsDirect or 1),
      ("platform.bin", 20'u64, CtfsDirect or 2),
      ("t00000000001", 30'u64, CtfsDirect or 3),
      ("eventlog.idx", 0'u64, 0'u64)], version = 4)
    let (ok, reason) = exportKeptEveryMember(original, exported)
    check not ok
    check "version 4" in reason
    check "5" in reason

  test "a direct member whose block is null or too small is refused":
    for (size, mapBlock, why) in [(10'u64, CtfsDirect, "null"),
                                  (5000'u64, CtfsDirect or 3, "one block"),
                                  (10'u64, CtfsDirect or 9, "past")]:
      let exported = v5Dir / "bad.ct"
      rawContainer(exported, 4, [
        ("meta.dat", 10'u64, CtfsDirect or 1),
        ("platform.bin", 20'u64, CtfsDirect or 2),
        ("t00000000001", size, mapBlock),
        ("eventlog.idx", 0'u64, 0'u64)])
      let (ok, reason) = exportKeptEveryMember(original, exported)
      check not ok
      check why in reason
      check "t00000000001" in reason
