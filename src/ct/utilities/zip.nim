import streams, std/os
import zip/zipfiles

proc zipFolder*(source, output: string, onProgress: proc(progressPercent: int) = nil) =
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
