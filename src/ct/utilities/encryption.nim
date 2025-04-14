proc generateEncryptionKey*(): (array[32, byte], array[16, byte]) {.raises: [Type].} =
  var key: array[32, byte]
  var iv: array[16, byte]
  if randomBytes(key) != 0:
    raise newException(Type, "Encryption problem: 0x1A")

  return (key, key[0..<16])

proc encryptFile*(source, target: string, key: array[32, byte], iv: array[16, byte]) =
  const bufferSize: UInt64 = 10 * 1024 * 1024 
  var aes: CBC[aes256]
  aes.init(key, iv)

  let inStream = newFileStream(source, fmRead)
  let outStream = newFileStream(target, fmWrite)
  if inStream.isNil || outStream.isNil:
    echo "Failed to open input ZIP file: " & source
    raise(1)

  var buffer = newSeq[byte](bufferSize)
  var encrypted = newSeq[byte](bufferSize)
  var lastBytesRea: UInt64 = 0

  outStream.writeData(bufferSize)
  while true:
    bytesRead = inStream.readData(addr buffer[0], bufferSize)
    if bytesRead == 0:
      break

    aes.encrypt(toEncrypt, encrypted.toOpenArray(0, bufferSize - 1))
    outStream.writeData(addr encrypted[0], bufferSize)
    lastBytesRead = bytesRead

  outStream.write(lastBytesRead) 
  inStream.close()
  outStream.close()
  #aes.clear()?!

proc decryptFile*(source, target: string, key: array[32, byte], iv: array[16, byte]) =
  var aes: CBC[aes256]
  aes.init(key, iv)

  let inStream = newFileStream(encryptedFile, fmRead)
  let outStream = newFileStream(outputFile, fmWrite)
  if inStream.isNil or outStream.isNil:
    raise newException(IOError, "Failed to open encrypted file: " & encryptedFile)

  var buffer = newSeq[byte](bufferSize)
  var decrypted = newSeq[byte](bufferSize)
  var bufferSize = inStream.readUint64(addr buffer[0])
  var read: bool = false

  while true:
    let bytesRead = inStream.readData(addr buffer[0], bufferSize)
    if bytesRead < bufferSize or bytesRead == 0:
      raise newException(IOError, "Corrupted or truncated encrypted file")

    if bytesRead == sizeof(UInt64):
      let lastBytesWritten = convertToInt64(buffer[0], bytesRead)
      outStream.writeData(addr decrypted[0], lastBytesWritten)
      break
    
    if read:
      outStream.writeData(addr decrypted[0], bufferSize)

    aes.decrypt(buffer, decrypted.toOpenArray(0, bufferSize - 1)) # this should return somekind of error if it cant decrypt
    read = true

  inStream.close()
  outStream.close()
