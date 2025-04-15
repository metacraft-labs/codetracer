import error_handler
import encryption
import os
import streams
import std/strutils

const placeholder = "the brown fox went into the den!"
var createdFiles = newSeq[string]()

proc createFile(len: int, callerName: string): string =
  let tmpPath = "/tmp/"
  let filename = tmpPath & callerName
  let file = newFileStream(filename, fmWrite)
  if file.isNil:
    raise newException(IOError, "Failed to create file")

  file.writeLine(placeholder)
  for i in 0..len-1:
    file.writeLine($i)

  file.close()
  return filename

proc validateForFilesLargerThanBufferSize() =
  let file = createFile(400, "greater")
  let ecrTarget = "/tmp/encrypted_400.enc"
  let decrTarget = "/tmp/decrypted_400.zip"
  createdFiles.add(ecrTarget)
  createdFiles.add(decrTarget)

  let (key, iv) = generateEncryptionKey()

  runSafe(
    proc() =
      encryptFile(file, ecrTarget, key, iv, 64)
      decryptFile(ecrTarget, decrTarget, key, iv)

      let decryptedContent = readFile(decrTarget)
      if not decryptedContent.contains(placeholder):
        pushError("Decryption failed for file: " & file),
    proc() = 
      removeFile(ecrTarget)
      removeFile(decrTarget),
    "validateForFilesLargerThanBufferSize"
  )

proc validateForFilesSmallerThanBufferSize() =
  let file = createFile(18, "smaller")
  let ecrTarget = "/tmp/encrypted_18.enc"
  let decrTarget = "/tmp/decrypted_18.zip"
  createdFiles.add(ecrTarget)
  createdFiles.add(decrTarget)

  let (key, iv) = generateEncryptionKey()

  runSafe(
    proc() =
      encryptFile(file, ecrTarget, key, iv, 128)
      decryptFile(ecrTarget, decrTarget, key, iv)

      let decryptedContent = readFile(decrTarget)
      if not decryptedContent.contains(placeholder):
        pushError("Decryption failed for file: " & file),
    proc() = 
      removeFile(ecrTarget)
      removeFile(decrTarget),
    "validateForFilesSmallerThanBufferSize"
  )

proc validate*() =
  validateForFilesLargerThanBufferSize()
  validateForFilesSmallerThanBufferSize()
  throwErrorsIfAny()

when isMainModule:
  validate()
