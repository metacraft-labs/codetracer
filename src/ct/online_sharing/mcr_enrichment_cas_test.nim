## The upload replacement guard must admit self-contained page-CAS exports.
##
## The filesystem, CTFS writer and zstd codec are real. The exporter alone is
## a shell stub through CODETRACER_CT_MCR_CMD: this suite tests the upload
## client's decision over the two containers, independently of the recorder's
## own tests for resolving system-cache pages. Its output models that contract:
## cppages gains pages, and a fixed-width cache-id rewrite changes a compressed
## CAS stream's stored size without changing its decoded length.

import std/[os, osproc, strutils, unittest]
import results
import codetracer_ctfs/[container, types, chunked_compressed_table]
import codetracer_ctfs/zstd_bindings
import mcr_enrichment

# Generate one otherwise-valid zstd frame without Frame_Content_Size using
# the codec itself. CCT readers require that field even though zstd does not.
proc ZSTD_CCtx_setParameter(ctx: pointer, param, value: cint): csize_t
    {.importc, header: "<zstd.h>".}
proc ZSTD_compress2(ctx: pointer, dst: pointer, capacity: csize_t,
    src: pointer, size: csize_t): csize_t {.importc, header: "<zstd.h>".}
var zstdContentSizeFlag {.importc: "ZSTD_c_contentSizeFlag", header: "<zstd.h>".}: cint

proc bytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc noise(n: int): string =
  result = newString(n)
  var state = 123456789'u32
  for i in 0 ..< n:
    state = state xor (state shl 13)
    state = state xor (state shr 17)
    state = state xor (state shl 5)
    result[i] = char(state and 255)

proc addRaw(c: var Ctfs, name, content: string) =
  var f = c.addFile(name).get()
  doAssert c.writeToFile(f, bytes(content)).isOk

proc compressedPayload(content: string, chunkSize = 4096'u32):
    tuple[data, index: seq[byte]] =
  # The production chunked-table writer, with byte records as snapshot
  # payloads use. The caller stores its generic .dat/.idx under the real
  # snapshot member names, without leaking the temporary pair into the trace.
  var c = createCtfs(4096, 32)
  var w = initChunkedCompressedTableWriter(c, "payload", 1, chunkSize).get()
  for b in bytes(content):
    doAssert c.append(w, [b]).isOk
  doAssert c.flush(w).isOk
  (readInternalFile(c.data, "payload.dat").get(),
   readInternalFile(c.data, "payload.idx").get())

proc writeTrace(path, pages, cas: string, pagesCompressed = true,
                casCompressed = true, casName = "cp.entry.cas",
                extra: seq[(string, string)] = @[], pagesChunkSize = 4096'u32,
                fragmented = false) =
  var c = createCtfs(4096, 32)
  c.addRaw("meta.dat", "unchanged metadata")
  # Build compressed payloads separately, so their temporary generic pair
  # never leaks into the recording whose preservation is being checked.
  for (name, content, compressed) in [
      ("cppages.ns", pages, pagesCompressed), (casName, cas, casCompressed)]:
    if not compressed:
      c.addRaw(name, content)
    else:
      let payload = compressedPayload(content,
        if name == "cppages.ns": pagesChunkSize else: 4096'u32)
      let dot = name.rfind('.')
      let stem = name[0 ..< dot] & "." & name[dot + 1] & "z"
      for (suffix, data) in [("d", payload.data), ("i", payload.index)]:
        let member = stem & suffix
        var f = c.addFile(member).get()
        if fragmented and name == "cppages.ns" and suffix == "d":
          # Interleave another member's blocks with this frame's bytes: the
          # reader must follow the production mapping runs across the frame.
          var padding = c.addFile("padding.bin").get()
          let blank = newSeq[byte](4096)
          for at in countup(0, data.len - 1, 2048):
            doAssert c.writeToFile(f,
              data.toOpenArray(at, min(data.len - 1, at + 2047))).isOk
            doAssert c.writeToFile(padding, blank).isOk
        else:
          doAssert c.writeToFile(f, data).isOk
  for (name, content) in extra: c.addRaw(name, content)
  doAssert c.writeCtfsToFile(path).isOk

proc storedSize(path, name: string): int =
  readInternalFile(readCtfsFromFile(path).get(), name).get().len

proc rewriteMember(path, changed: string, replacement: seq[byte], omit = false) =
  let original = readCtfsFromFile(path).get()
  var c = createCtfs(4096, 32)
  for name in ["meta.dat", "cppages.nzd", "cppages.nzi", "cp.entry.czd",
               "cp.entry.czi"]:
    if name == changed and omit: continue
    var f = c.addFile(name).get()
    doAssert c.writeToFile(f,
      if name == changed: replacement else: readInternalFile(original, name).get()).isOk
  doAssert c.writeCtfsToFile(path).isOk

proc stubExporter(dir, source: string): string =
  result = dir / "ct-mcr-stub.sh"
  writeFile(result, "#!/usr/bin/env bash\nset -euo pipefail\n" &
    "# export --portable -o <output> <input>\ncp " & source.quoteShell & " \"$4\"\n")
  when not defined(windows):
    doAssert execCmdEx("chmod +x " & result.quoteShell).exitCode == 0

suite "MCR enrichment — portable page-CAS payloads":
  setup:
    let dir = getTempDir() / "mcr-enrichment-cas"
    removeDir(dir)
    createDir(dir / "exports")
    let original = dir / "trace.ct"
    let exported = dir / "exports" / "portable.ct"
    let oldPages = noise(8192)
    let oldCas = noise(8192)

  teardown:
    delEnv("CODETRACER_CT_MCR_CMD")
    removeDir(dir)

  test "a growing compressed page store and rewritten CAS replace the original":
    writeTrace(original, oldPages, oldCas)
    # Fixed-width cache ids become zero; the real exporter makes this sort of
    # in-place rewrite. Its physical size is no longer a preservation metric.
    var newCas = oldCas
    for i in countup(0, newCas.len - 8, 64):
      for j in 0 ..< 8: newCas[i + j] = '\0'
    writeTrace(exported, oldPages & noise(8192), newCas)
    check storedSize(exported, "cppages.nzd") > storedSize(original, "cppages.nzd")
    check storedSize(exported, "cp.entry.czd") != storedSize(original, "cp.entry.czd")
    putEnv("CODETRACER_CT_MCR_CMD", stubExporter(dir, exported))
    check enrichMcrTraceIfNeeded(dir)
    check readFile(original) == readFile(exported)
    check not fileExists(original & ".portable")

  test "raw page store crossing one block can become a compressed pair":
    writeTrace(original, noise(4096), oldCas, pagesCompressed = false)
    writeTrace(exported, noise(4096) & noise(8192), oldCas)
    let kept = exportKeptEveryMember(original, exported)
    check kept.reason == ""
    check kept.ok

  test "raw stores can grow and raw CAS streams keep their decoded length":
    writeTrace(original, "page", "cacheid1", false, false)
    writeTrace(exported, "page plus resolved page", "cacheid0", false, false)
    check exportKeptEveryMember(original, exported).ok

  test "a logically growing store may become smaller when recompressed":
    let pages = repeat(noise(4096), 2)
    writeTrace(original, pages, oldCas)
    # A different legal frame size can preserve the original prefix, add
    # pages, and still store fewer compressed bytes.
    writeTrace(exported, pages & repeat("\0", 8192), oldCas,
      pagesChunkSize = 16384)
    check storedSize(exported, "cppages.nzd") < storedSize(original, "cppages.nzd")
    check exportKeptEveryMember(original, exported).ok

  test "compressed and raw forms of a fixed-length CAS stream are equivalent":
    for (oldCompressed, newCompressed) in [(true, false), (false, true)]:
      writeTrace(original, oldPages, oldCas, casCompressed = oldCompressed)
      writeTrace(exported, oldPages, oldCas, casCompressed = newCompressed)
      check exportKeptEveryMember(original, exported).ok

  test "a compressed page store can be emitted raw without losing bytes":
    writeTrace(original, oldPages, oldCas)
    writeTrace(exported, oldPages, oldCas, pagesCompressed = false)
    check exportKeptEveryMember(original, exported).ok

  test "all boundary and canonical periodic CAS stream names allow rewrites":
    for name in ["cp.prein.cas", "cp.entry.cas", "cp.postl.cas", "cp0.cas",
                 "cpa.cas", "cpzzzzz.cas"]:
      writeTrace(original, oldPages, oldCas, casName = name)
      writeTrace(exported, oldPages, repeat("\0", oldCas.len), casName = name)
      check exportKeptEveryMember(original, exported).ok

  test "a decoded page store shrink is refused even when stored bytes grow":
    let pages = repeat(noise(4096), 4)
    writeTrace(original, pages, oldCas, pagesChunkSize = 16384)
    writeTrace(exported, pages[0 ..< 8192], oldCas)
    check storedSize(exported, "cppages.nzd") > storedSize(original, "cppages.nzd")
    let before = readFile(original)
    putEnv("CODETRACER_CT_MCR_CMD", stubExporter(dir, exported))
    check not enrichMcrTraceIfNeeded(dir)
    check readFile(original) == before
    check not fileExists(original & ".portable")

  test "a CAS stream cannot shrink or grow when decoded":
    writeTrace(original, oldPages, oldCas)
    for n in [4096, 12288]:
      writeTrace(exported, oldPages, noise(n))
      let kept = exportKeptEveryMember(original, exported)
      check not kept.ok
      check "cp.entry.cas" in kept.reason

  test "similar names and other snapshot members retain strict size checks":
    for name in ["cppages.bin", "cppages.mem", "cp.entry.mem", "cp.fake.cas",
                 "cp00.cas", "cp000000.cas", "cp-1.cas"]:
      writeTrace(original, oldPages, oldCas, extra = @[(name, "original bytes")])
      writeTrace(exported, oldPages, oldCas, extra = @[(name, "short")])
      let kept = exportKeptEveryMember(original, exported)
      check not kept.ok
      check name in kept.reason

  test "either missing half of a compressed payload is refused":
    writeTrace(original, oldPages, oldCas)
    for missing in ["cppages.nzd", "cppages.nzi", "cp.entry.czd", "cp.entry.czi"]:
      writeTrace(exported, oldPages, oldCas)
      rewriteMember(exported, missing, @[], omit = true)
      let kept = exportKeptEveryMember(original, exported)
      check not kept.ok
      check (if missing.startsWith("cppages"): "cppages" else: "cp.entry") in kept.reason

  test "both raw and compressed forms are ambiguous and refused":
    writeTrace(original, oldPages, oldCas)
    writeTrace(exported, oldPages, oldCas, extra = @[("cppages.ns", oldPages)])
    let kept = exportKeptEveryMember(original, exported)
    check not kept.ok
    check "cppages" in kept.reason

  test "malformed indices are refused rather than trusted for decoded sizes":
    writeTrace(original, oldPages, oldCas)
    let valid = readInternalFile(readCtfsFromFile(original).get(), "cppages.nzi").get()
    for bad in 0 ..< 7:
      var index = valid
      case bad
      of 0: index[0 .. 3] = [0'u8, 0, 0, 0] # zero chunk size
      of 1: index[4] = 1 # first frame does not start at zero
      of 2: index.setLen(index.len - 1) # trailing partial offset
      of 3:
        for i in 12 ..< 20: index[i] = 0 # duplicate offset
      of 4:
        for i in 12 ..< 20: index[i] = 255 # offset beyond the data
      of 5: index[1] = 32 # chunk size 8192, but the first frame holds 4096
      else: index[1] = 8 # chunk size 2048, less than the frame's decoded size
      writeTrace(exported, oldPages, oldCas)
      rewriteMember(exported, "cppages.nzi", index)
      let kept = exportKeptEveryMember(original, exported)
      check not kept.ok
      check "cppages" in kept.reason

  test "a damaged zstd frame cannot satisfy the length check":
    writeTrace(original, oldPages, oldCas)
    let valid = readInternalFile(readCtfsFromFile(original).get(), "cppages.nzd").get()
    for truncated in [false, true]:
      var data = valid
      if truncated: data.setLen(data.len - 1)
      else: data[0] = data[0] xor 255
      writeTrace(exported, oldPages, oldCas)
      rewriteMember(exported, "cppages.nzd", data)
      let kept = exportKeptEveryMember(original, exported)
      check not kept.ok
      check "cppages" in kept.reason

  test "empty compressed payloads have a real zero decoded length":
    writeTrace(original, "", "")
    writeTrace(exported, "", "", pagesCompressed = false, casCompressed = false)
    check exportKeptEveryMember(original, exported).ok
    check exportKeptEveryMember(exported, original).ok

  test "an original with ambiguous snapshot storage is refused":
    writeTrace(original, oldPages, oldCas, extra = @[("cppages.ns", oldPages)])
    writeTrace(exported, oldPages, oldCas)
    let kept = exportKeptEveryMember(original, exported)
    check not kept.ok
    check "cppages" in kept.reason

  test "unindexed data and bytes after an indexed frame are refused":
    writeTrace(original, oldPages, oldCas)
    let image = readCtfsFromFile(original).get()
    let validData = readInternalFile(image, "cppages.nzd").get()
    let validIndex = readInternalFile(image, "cppages.nzi").get()
    for bad in 0 ..< 3:
      writeTrace(exported, oldPages, oldCas)
      if bad == 0:
        rewriteMember(exported, "cppages.nzi", validIndex[0 .. 3])
      elif bad == 1:
        rewriteMember(exported, "cppages.nzd", validData & @[0'u8])
      else:
        rewriteMember(exported, "cppages.nzd", validData & validData)
      let kept = exportKeptEveryMember(original, exported)
      check not kept.ok
      check "cppages" in kept.reason

  test "large frames drain across output buffers and fragmented CTFS runs":
    for compressible in [false, true]:
      writeTrace(original,
        if compressible: repeat("\0", 524288) else: noise(524288), oldCas,
        pagesChunkSize = 262144, fragmented = true)
      let image = readCtfsFromFile(original).get()
      let entry = findFileEntry(image, "cppages.nzd", 32)
      let runs = memberRuns(image, "cppages.nzd", entry.size, entry.mapBlock, 4096).get()
      if compressible:
        # This input fits one span; output needs repeated buffer drains.
        check entry.size < 65536
      else:
        check runs.len > 2
      copyFile(original, exported)
      check exportKeptEveryMember(original, exported).ok

  test "a zstd frame without declared content size is not a readable CCT":
    let ctx = ZSTD_createCCtx()
    doAssert ctx != nil
    defer: discard ZSTD_freeCCtx(ctx)
    doAssert ZSTD_isError(ZSTD_CCtx_setParameter(ctx, zstdContentSizeFlag, 0)) == 0
    var data = newSeq[byte](int(ZSTD_compressBound(csize_t(oldPages.len))))
    let stored = ZSTD_compress2(ctx, addr data[0], csize_t(data.len),
      unsafeAddr oldPages[0], csize_t(oldPages.len))
    doAssert ZSTD_isError(stored) == 0
    data.setLen(int(stored))
    check ZSTD_getFrameContentSize(addr data[0], stored) == ZSTD_CONTENTSIZE_UNKNOWN
    writeTrace(original, oldPages, oldCas)
    writeTrace(exported, oldPages, oldCas)
    rewriteMember(exported, "cppages.nzd", data)
    rewriteMember(exported, "cppages.nzi", compressedPayload(oldPages, 8192).index)
    let kept = exportKeptEveryMember(original, exported)
    check not kept.ok
    check "cppages" in kept.reason
