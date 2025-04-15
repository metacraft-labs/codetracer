import encryption
import filesystem

const placeholder = "wserdtfyguhijokpl;2345678"
var createdFiles = @newSeq[string]
proc createFile(len: int, callerName: string = instantiationInfo().name): string =
  // getTmpPath
  // createFile (tmoPath+callerName)
  // for i 0..inf write i\n until len
  // return filename

proc onExitHook() =
  // remove all from createdFiles

atexit(onExitHook)


proc validateForFilesLargerThanBufferSize() =
  let file = createFile(400)
  let ecrTarget =
  let decrTarget
  createdFiles.add(ecrTarget)
  createdFiles.add(decrTarget)
  (key,iv) = generateEncryptionKey()
  encryptFile(file, ecrTarget, key, iv, 64)
  decryptFile(ecrTarget, decrTarget, key, iv)
  // readfile, validate placeholder

proc validateForFilesLargerThanBufferSize() =
  let file = createFile(18)
  let ecrTarget =
  let decrTarget
  createdFiles.add(ecrTarget)
  createdFiles.add(decrTarget)
  (key,iv) = generateEncryptionKey()
  encryptFile(file, ecrTarget, key, iv, 128)
  decryptFile(ecrTarget, decrTarget, key, iv)
  try:
  // readfile, validate placeholder
  // if not corret or err -> errors.push("messasge")

proc validate*() =
  runSafe(validateForFilesLargerThanBufferSize)
  runSafe(validateForFilesLargerThanBufferSize)
  throwErrorsIfAny

when isMainModule:
  validate()

// new file somewhere
var errors = newSeq[]string
proc pushError*(msg: string) =
  erros.push(msg)
proc throwErrorsIfAny*() =
  if errors.any:
    raise //formated meesage
proc runSafe*(action: proc (), cleanup: proc() = nil, string = instantiationInfo().name) =
  try:
    action()
  except:
    errors.push("formated error + caller name")
  finally
    cleanup?.()
