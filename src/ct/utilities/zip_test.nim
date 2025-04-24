import std/[unittest, os, strutils, streams]
import ../utilities/zip

suite "zipFolder / unzipIntoFolder":
  test "zip and unzip with progress":
    let tmp = getTempDir()
    let inputDir = tmp / "zip_test_input"
    let outputDir = tmp / "zip_test_output"
    let unzipDir = tmp / "zip_test_unzipped"
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
