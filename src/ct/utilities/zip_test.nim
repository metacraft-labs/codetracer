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
