import nimcrypto, streams
import system

proc generateEncryptionKey*(): (array[32, byte], array[16, byte]) {.raises: [ValueError].} =
  var key: array[32, byte]
  var iv: array[16, byte]
  if randomBytes(key) != 32:
    raise newException(ValueError, "Encryption problem: 0x1A")

  copyMem(addr iv, addr key, 16)

  return (key, iv)

proc encryptFile*(source, target: string, key: array[32, byte], iv: array[16, byte]) {.raises: [IOError, OSError, Exception].} =
  const bufferSize: int = 10 * 1024 * 1024 
  var aes: CBC[aes256]
  aes.init(key, iv)

  let inStream = newFileStream(source, fmRead)
  let outStream = newFileStream(target, fmWrite)
  if inStream.isNil or outStream.isNil:
    raise newException(IOError, "Failed to open input ZIP file: " & source)

  var buffer = newSeq[byte](bufferSize)
  var encrypted = newSeq[byte](bufferSize)
  var lastBytesRead: int = 0

  outStream.write(bufferSize)
  while true:
    let bytesRead = inStream.readData(addr buffer[0], bufferSize)
    if bytesRead == 0:
      break

    aes.encrypt(encrypted, encrypted.toOpenArray(0, bufferSize - 1))
    outStream.writeData(addr encrypted[0], bufferSize)
    lastBytesRead = bytesRead

  outStream.write(lastBytesRead) 
  inStream.close()
  outStream.close()
  #aes.clear()?!

proc decryptFile*(source, target: string, key: array[32, byte], iv: array[16, byte]) =
  var aes: CBC[aes256]
  aes.init(key, iv)

  let inStream = newFileStream(source, fmRead)
  let outStream = newFileStream(target, fmWrite)
  if inStream.isNil or outStream.isNil:
    raise newException(IOError, "Failed to open encrypted file: " & source)

  var bufferSize = cast[int](inStream.readUint64())
  var buffer = newSeq[byte](bufferSize)
  var decrypted = newSeq[byte](bufferSize)
  var read: bool = false

  while true:
    let bytesRead = inStream.readData(addr buffer[0], bufferSize)
    if bytesRead < bufferSize or bytesRead == 0:
      raise newException(IOError, "Corrupted or truncated encrypted file")

    if bytesRead == sizeof(uint64):
      let lastBytesWritten = cast[int](outStream.readInt64()) # convertToInt64(buffer[0], bytesRead)
      outStream.writeData(addr decrypted[0], lastBytesWritten)
      break
    
    if read:
      outStream.writeData(addr decrypted[0], bufferSize)

    aes.decrypt(buffer, decrypted.toOpenArray(0, bufferSize - 1)) # this should return somekind of error if it cant decrypt
    read = true

  inStream.close()
  outStream.close()
