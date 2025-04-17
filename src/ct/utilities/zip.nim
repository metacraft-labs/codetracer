import streams, std/[ os, tables ]
import zip/zipfiles

proc zipFolder*(source, output: string, onProgress: proc(i: int) = nil) =
  var zip: ZipArchive
  discard zip.open(output, fmWrite)
  var streamList: seq[Stream] = @[]

  var totalBytes: int64 = 0
  var fileSizes: Table[string, int64]
  for file in walkDirRec(source):
    let size = getFileSize(file)
    fileSizes[$file] = size
    totalBytes += size

  var zippedBytes = 0

  for file in walkDirRec(source):
    let relPath = file.relativePath(source)
    let fileStream = newFileStream(file, fmRead)
    streamList.add(fileStream)

    var countingStream = newFileStream(file, fmRead)
    var buffer: array[4096, byte]
    var tempStream = newStringStream("")

    # Update progress for zipped files
    while true:
      let readBytes = countingStream.readData(addr buffer, buffer.len)
      if readBytes == 0: break
      tempStream.writeData(addr buffer, readBytes)
      zippedBytes += readBytes

      if not onProgress.isNil:
        let percent = int((float(zippedBytes) / float(totalBytes)) * 100)
        onProgress(percent)

    zip.addFile(relPath, newStringStream(tempStream.data))

    countingStream.close()
    tempStream.close()

  zip.close()

  for stream in streamList:
    stream.close()

# proc zipFolder*(source, output: string) =
#   var zip: ZipArchive
#   discard zip.open(output, fmWrite)
#   var streamList: seq[Stream] = @[]
#   for file in walkDirRec(source):
#     let relPath = file.relativePath(source)
#     let fileStream = newFileStream(file, fmRead)

#     streamList.add(fileStream)
#     zip.addFile(relPath, fileStream)

#   zip.close()

#   for stream in streamList:
#     stream.close()

proc unzipIntoFolder*(zipPath, targetDir: string) {.raises: [IOError, OSError, Exception].} =
  var zip: ZipArchive
  if not zip.open(zipPath, fmRead):
    raise newException(IOError, "Failed to open decrypted ZIP: " & zipPath)

  createDir(targetDir)
  zip.extractAll(targetDir)

  zip.close()
