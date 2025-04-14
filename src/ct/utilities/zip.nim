import streams, std/os
import zip/zipfiles

proc zipFolder*(source, output: string) =
  var z: ZipArchive
  discard z.open(output, fmWrite)
  var r: seq[Stream] = @[]
  for file in walkDirRec(source):
    let relPath = file.relativePath(source)
    let fileStream = newFileStream(file, fmRead)

    r.add(fileStream)
    z.addFile(relPath, fileStream)

  z.close()

  for r1 in r:
    r1.close()

proc unzipIntoFolder*(zipPath, targetDir: string) {.raises: [IOError, OSError, Exception].} =
  var zip: ZipArchive
  if not zip.open(zipPath, fmRead):
    raise newException(IOError, "Failed to open decrypted ZIP: " & zipPath)

  createDir(targetDir)
  zip.extractAll(targetDir)

  zip.close()
