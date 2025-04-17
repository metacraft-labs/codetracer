import nimcrypto, streams
import system
import std/os

proc generateEncryptionKey*(): (array[32, byte], array[16, byte]) {.raises: [ValueError].} =
  var key: array[32, byte]
  var iv: array[16, byte]
  if randomBytes(key) != 32:
    raise newException(ValueError, "Encryption problem: 0x1A")

  copyMem(addr iv, addr key, 16)
  return (key, iv)

proc encryptFile*(source, target: string, key: array[32, byte], iv: array[16, byte], bufferSize: int = 4096, onProgress: proc(i: int) = nil) {.raises: [IOError, OSError, Exception].} =
  var aes: CFB[aes256]
  aes.init(key, iv)

  let inStream = newFileStream(source, fmRead)
  let outStream = newFileStream(target, fmWrite)
  if inStream.isNil or outStream.isNil:
    raise newException(IOError, "Failed to open input ZIP file: " & source)

  let totalSize: int64 = getFileSize(source)

  var processed: int64 = 0
  var buffer = newSeq[byte](bufferSize)
  var encrypted = newSeq[byte](bufferSize)

  while true:
    let bytesRead = inStream.readData(addr buffer[0], bufferSize)
    if bytesRead == 0:
      break

    aes.encrypt(buffer, encrypted)
    outStream.writeData(addr encrypted[0], bytesRead)
    processed += bytesRead


    if not onProgress.isNil:
      let currentProgress = int((processed.float / totalSize.float) * 100)
      onProgress(currentProgress)

  inStream.close()
  outStream.close()

# proc encryptFile*(source, target: string, key: array[32, byte], iv: array[16, byte], bufferSize: int = 4096) {.raises: [IOError, OSError, Exception].} =
#   var aes: CFB[aes256]
#   aes.init(key, iv)

#   let inStream = newFileStream(source, fmRead)
#   let outStream = newFileStream(target, fmWrite)
#   if inStream.isNil or outStream.isNil:
#     raise newException(IOError, "Failed to open input ZIP file: " & source)

#   var buffer = newSeq[byte](bufferSize)
#   var encrypted = newSeq[byte](bufferSize)
#   while true:
#     let bytesRead = inStream.readData(addr buffer[0], bufferSize)
#     if bytesRead == 0:
#       break

#     aes.encrypt(buffer, encrypted)
#     outStream.writeData(addr encrypted[0], bytesRead)

#   inStream.close()
#   outStream.close()

proc decryptFile*(source, target: string, key: array[32, byte], iv: array[16, byte], bufferSize: int = 4096) =
  var aes: CFB[aes256]
  aes.init(key, iv)

  let inStream = newFileStream(source, fmRead)
  let outStream = newFileStream(target, fmWrite)
  if inStream.isNil or outStream.isNil:
    raise newException(IOError, "Failed to open encrypted file: " & source)

  var buffer = newSeq[byte](bufferSize)
  var decrypted = newSeq[byte](bufferSize)

  while true:
    var dataRead = inStream.readData(addr buffer[0], bufferSize)
    if dataRead == 0:
      break;

    aes.decrypt(buffer, decrypted)
    outStream.writeData(addr decrypted[0], dataRead)

  inStream.close()
  outStream.close()
