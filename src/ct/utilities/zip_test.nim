# The commas below are load-bearing: a multi-line `import` is a comma-separated
# list, and without them the second and third lines are read as a continuation
# of the first, which Nim rejects with `invalid indentation` on line 3. The file
# sat in that state because no lane compiled it.
import
  std/[unittest, os, strutils, streams],
  ./zip,
  ../../common/paths

suite "zipFolder / unzipIntoFolder":
  test "zip and unzip with progress":
    let inputDir = codetracerTmpPath / "zip_test_input"
    let outputDir = codetracerTmpPath / "zip_test_output"
    let unzipDir = codetracerTmpPath / "zip_test_unzipped"
    createDir(inputDir)

    let testFile = inputDir / "test.txt"
    writeFile(testFile, "Nim zip test!")

    let zipPath = outputDir / "test.zip"
    createDir(outputDir)

    var progressCalled = false
    proc onProgress(progress: int) =
      echo "Progress: ", progress, "%"
      progressCalled = true

    zipFolder(inputDir, zipPath, onProgress = onProgress)

    check fileExists(zipPath)
    check progressCalled

    unzipIntoFolder(zipPath, unzipDir)

    let unzippedFile = unzipDir / "test.txt"
    check fileExists(unzippedFile)
    check readFile(unzippedFile) == "Nim zip test!"

    removeFile(zipPath)
    removeDir(unzipDir)
    removeDir(outputDir)
    removeDir(inputDir)

  test "storeOnly zip does not compress (avoids double compression)":
    ## Verify that zipFolder with storeOnly=true creates a valid zip
    ## whose files can be extracted, and that the zip is at least as large
    ## as the source (store mode should not shrink highly-compressible data).
    let inputDir = codetracerTmpPath / "zip_test_store_input"
    let outputDir = codetracerTmpPath / "zip_test_store_output"
    let unzipDir = codetracerTmpPath / "zip_test_store_unzipped"
    createDir(inputDir)
    createDir(outputDir)

    # Write a file with repeated content that would compress well under
    # deflate. With storeOnly the zip should be roughly the same size as
    # the source (plus zip overhead), not smaller.
    let compressibleContent = repeat("AAAA", 4096)  # 16 KiB of 'A's
    let testFile = inputDir / "compressible.bin"
    writeFile(testFile, compressibleContent)
    let sourceSize = getFileSize(testFile)

    let storeZip = outputDir / "store.zip"
    let deflateZip = outputDir / "deflate.zip"

    # Create store-only zip (no compression).
    zipFolder(inputDir, storeZip, storeOnly = true)
    check fileExists(storeZip)

    # Create normal (deflate) zip for comparison.
    zipFolder(inputDir, deflateZip, storeOnly = false)
    check fileExists(deflateZip)

    let storeSize = getFileSize(storeZip)
    let deflateSize = getFileSize(deflateZip)

    # The store zip must be larger than the deflate zip for this highly
    # compressible input. This confirms storeOnly actually disables
    # compression.
    check storeSize > deflateSize

    # The store zip should be at least as large as the original file
    # (source size + zip metadata overhead).
    check storeSize >= sourceSize

    # Verify the store-only zip still extracts correctly.
    unzipIntoFolder(storeZip, unzipDir)
    let extracted = unzipDir / "compressible.bin"
    check fileExists(extracted)
    check readFile(extracted) == compressibleContent

    removeFile(storeZip)
    removeFile(deflateZip)
    removeDir(unzipDir)
    removeDir(outputDir)
    removeDir(inputDir)

# ---------------------------------------------------------------------------
# The store-only writer's own layout (`writeStoredZip`)
# ---------------------------------------------------------------------------
#
# The archive is read back by libzip (`unzipIntoFolder`) -- a reader this
# module does not implement -- and its bytes are checked against the ZIP
# specification's fixed values, so neither half grades the writer with the
# writer's own code. No mocks: real files, a real archive, a real reader.

proc le32(s: string; at: int): uint32 =
  for i in countdown(3, 0):
    result = (result shl 8) or uint32(ord(s[at + i]))

proc le16(s: string; at: int): int =
  ord(s[at]) or (ord(s[at + 1]) shl 8)

proc sigAt(s: string; sig: uint32): int =
  ## Offset of the LAST occurrence of a 4-byte little-endian signature.
  var needle = ""
  for i in 0 .. 3: needle.add char((sig shr (8 * i)) and 0xFF)
  s.rfind(needle)

proc storedFixture(name: string): string =
  result = codetracerTmpPath / name
  removeDir(result)
  createDir(result / "nested" / "deeper")
  # "123456789" is the CRC-32 check input: its CRC is 0xCBF43926 by
  # definition (the ISO-HDLC parameters every ZIP reader uses).
  writeFile(result / "check.txt", "123456789")
  writeFile(result / "nested" / "a.bin", repeat("abc", 200))
  writeFile(result / "nested" / "deeper" / "b.txt", "deep file\n")

suite "writeStoredZip — the store-only layout":
  test "nested files round-trip through libzip, and the CRC is the standard one":
    let input = storedFixture("zip_test_layout_input")
    let zipPath = codetracerTmpPath / "zip_test_layout.zip"
    let unzipDir = codetracerTmpPath / "zip_test_layout_unzipped"
    removeDir(unzipDir)
    writeStoredZip(input, zipPath)

    unzipIntoFolder(zipPath, unzipDir)
    for rel in ["check.txt", "nested/a.bin", "nested/deeper/b.txt"]:
      check fileExists(unzipDir / rel)
      check readFile(unzipDir / rel) == readFile(input / rel)

    let bytes = readFile(zipPath)
    # Below the limit: no ZIP64 end records at all.
    check sigAt(bytes, 0x06064b50'u32) < 0
    check sigAt(bytes, 0x07064b50'u32) < 0
    let eocd = sigAt(bytes, 0x06054b50'u32)
    check eocd >= 0
    check le16(bytes, eocd + 10) == 3          # total entries
    # The central directory entry for `check.txt` carries the check CRC.
    let cdStart = int(le32(bytes, eocd + 16))
    var at = cdStart
    var sawCheck = false
    for _ in 0 ..< 3:
      check le32(bytes, at) == 0x02014b50'u32
      let nameLen = le16(bytes, at + 28)
      let extraLen = le16(bytes, at + 30)
      let name = bytes[at + 46 ..< at + 46 + nameLen]
      check le16(bytes, at + 10) == 0          # method: stored
      if name == "check.txt":
        sawCheck = true
        check le32(bytes, at + 16) == 0xCBF43926'u32
        check le32(bytes, at + 24) == 9'u32    # uncompressed size
      at += 46 + nameLen + extraLen
    check sawCheck

    removeFile(zipPath)
    removeDir(unzipDir)
    removeDir(input)

  test "the ZIP64 form: entries and end records past the limit still round-trip":
    ## `zip64At = 64` puts every entry larger than 64 bytes, every offset past
    ## 64 and the central directory itself into the ZIP64 form -- the layout a
    ## >4 GiB slice set produces, exercised without 4 GiB of fixture.
    let input = storedFixture("zip_test_zip64_input")
    let zipPath = codetracerTmpPath / "zip_test_zip64.zip"
    let unzipDir = codetracerTmpPath / "zip_test_zip64_unzipped"
    removeDir(unzipDir)
    writeStoredZip(input, zipPath, zip64At = 64)

    unzipIntoFolder(zipPath, unzipDir)
    for rel in ["check.txt", "nested/a.bin", "nested/deeper/b.txt"]:
      check fileExists(unzipDir / rel)
      check readFile(unzipDir / rel) == readFile(input / rel)

    let bytes = readFile(zipPath)
    let eocd64 = sigAt(bytes, 0x06064b50'u32)
    let locator = sigAt(bytes, 0x07064b50'u32)
    let eocd = sigAt(bytes, 0x06054b50'u32)
    check eocd64 >= 0
    check locator == eocd64 + 56               # the record is 12 + 44 bytes
    check eocd == locator + 20
    # The locator points at the ZIP64 record, and the classic record defers.
    check int(le32(bytes, locator + 8)) == eocd64
    check le16(bytes, eocd + 10) == 0xFFFF
    check le32(bytes, eocd + 16) == 0xFFFF_FFFF'u32
    # `nested/a.bin` (600 bytes) has its sizes in the ZIP64 extra field.
    let local = bytes.find("nested/a.bin")
    check local >= 30
    let hdr = local - 30
    check le32(bytes, hdr) == 0x04034b50'u32
    check le16(bytes, hdr + 4) == 45           # version needed: ZIP64
    check le32(bytes, hdr + 18) == 0xFFFF_FFFF'u32
    check le16(bytes, hdr + 28) == 20
    check le16(bytes, hdr + 30 + 12) == 0x0001 # the ZIP64 extra's id
    check le32(bytes, hdr + 30 + 12 + 4) == 600'u32

    removeFile(zipPath)
    removeDir(unzipDir)
    removeDir(input)
