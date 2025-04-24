import std/[unittest, os, strutils, streams]
import encryption

const placeholder = "the brown fox went into the den!"
let tmpPath = "/tmp"

proc createFile(len: int, filename: string): string =
  let filePath = tmpPath / filename
  let file = newFileStream(filePath, fmWrite)
  if file.isNil:
    raise newException(IOError, "Failed to create file")

  file.writeLine(placeholder)
  for i in 0..<len:
    file.writeLine($i)
  file.close()
  return filePath

suite "Encryption/Decryption Buffer Handling":

  test "Encrypt/Decrypt file larger than buffer size":
    let file = createFile(400, "greater")
    let ecrTarget = tmpPath / "encrypted_400.enc"
    let decrTarget = tmpPath / "decrypted_400.zip"
    let (key, iv) = generateEncryptionKey()

    encryptFile(file, ecrTarget, key, iv, 64)
    decryptFile(ecrTarget, decrTarget, key, iv)

    let decryptedContent = readFile(decrTarget)
    check decryptedContent.contains(placeholder)

    removeFile(ecrTarget)
    removeFile(decrTarget)
    removeFile(file)

  test "Encrypt/Decrypt file smaller than buffer size":
    let file = createFile(18, "smaller")
    let ecrTarget = tmpPath / "encrypted_18.enc"
    let decrTarget = tmpPath / "decrypted_18.zip"
    let (key, iv) = generateEncryptionKey()

    encryptFile(file, ecrTarget, key, iv, 128)
    decryptFile(ecrTarget, decrTarget, key, iv)

    let decryptedContent = readFile(decrTarget)
    check decryptedContent.contains(placeholder)

    removeFile(ecrTarget)
    removeFile(decrTarget)
    removeFile(file)
