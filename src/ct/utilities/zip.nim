import streams, std/[ os, tables ]
import zip/zipfiles

proc zipFolder*(source, output: string, onProgress: proc(i: int) = nil) =
  var zip: ZipArchive
  discard zip.open(output, fmWrite)

  var totalFiles: int = 0
  for file in walkDirRec(source):
    inc totalFiles

  var currentFile = 0
  var streamList: seq[Stream] = @[]
  var lastPercentsSent = 0

  for file in walkDirRec(source):
    let relPath = file.relativePath(source)
    let fileStream = newFileStream(file, fmRead)
    streamList.add(fileStream)

    zip.addFile(relPath, fileStream)
    inc currentFile

    if onProgress != nil:
      let percent = (currentFile.float / totalFiles.float * 100).int
      if percent > lastPercentsSent:
        onProgress(percent)
        lastPercentsSent = percent

  zip.close()

  for stream in streamList:
    stream.close()

proc unzipIntoFolder*(zipPath, targetDir: string) {.raises: [IOError, OSError, Exception].} =
  var zip: ZipArchive
  if not zip.open(zipPath, fmRead):
    raise newException(IOError, "Failed to open decrypted ZIP: " & zipPath)

  createDir(targetDir)
  zip.extractAll(targetDir)

  zip.close()
