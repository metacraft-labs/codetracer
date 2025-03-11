import std/[ options, strutils, os, osproc, strformat, json ], ../trace/replay, ../codetracerconf, zip/zipfiles, nimcrypto
import ../../common/[ config, trace_index, lang, paths ]
import ../utilities/language_detection
import ../trace/[ storage_and_import, record ]
import security_upload

proc uploadCommand*(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
) =
  discard internalReplayOrUpload(patternArg, traceIdArg, traceFolderArg, interactive, command=StartupCommand.upload)


proc decryptZip(encryptedFile: string, password: string, outputFile: string) =
  var encData = readFile(encryptedFile).toBytes()
  if encData.len < 16:
    raise newException(ValueError, "Invalid encrypted data (too short)")

  let iv = password.toBytes()[0 ..< 16]
  let ciphertext = encData[16 .. ^1]
  let key = password.toBytes()

  var aes: CBC[aes256]
  aes.init(key, iv)

  var decrypted = newSeq[byte](encData.len)
  aes.decrypt(encData, decrypted.toOpenArray(0, len(decrypted) - 1))

  var depaddedData = pkcs7Unpad(decrypted)
  writeFile(outputFile, depaddedData)

proc unzipDecryptedFile(zipFile: string, outputDir: string): (string, int) =
  var zip: ZipArchive
  if not zip.open(zipFile, fmRead):
    raise newException(IOError, "Failed to open decrypted ZIP: " & zipFile)

  let traceId = trace_index.newID(false)
  let outPath = outputDir / "trace-" & $traceId

  createDir(outPath)
  zip.extractAll(outPath)

  zip.close()
  return (outPath, traceId)

proc downloadCommand*(traceRegistryId: string) =
  # We expect a traceRegistryId to have <downloadId>::<passwordKey>
  let stringSplit = traceRegistryId.split("//")
  if stringSplit.len() != 3:
    quit(1)
  else:
    let downloadId = stringSplit[1]
    let password = stringSplit[2]
    let zipPath = codetracerTmpPath / "tmp.zip"
    let config = loadConfig(folder=getCurrentDir(), inTest=false)
    let localPath = codetracerTmpPath / "tmp.zip.enc"
    # TODO: Plug in an http client
    let cmd = &"curl -s -o {localPath} {config.webApiRoot}/download?DownloadId={downloadId}"
    let (output, exitCode) = execCmdEx(cmd)

    decryptZip(localPath, password, zipPath)

    let (traceFolder, traceId) = unzipDecryptedFile(zipPath, codetracerTraceDir)
    let tracePath = traceFolder / "trace.json"
    let traceJson = parseJson(readFile(tracePath))
    let traceMetadataPath = traceFolder / "trace_metadata.json"

    var pathValue = ""

    for item in traceJson:
      if item.hasKey("Path"):
        pathValue = item["Path"].getStr("")
        break

    let lang = detectLang(pathValue, LangUnknown)
    discard importDbTrace(traceMetadataPath, traceId, lang, DB_SELF_CONTAINED_DEFAULT, traceRegistryId)

    removeFile(localPath)
    removeFile(zipPath)

    echo traceId

    quit(exitCode)

proc deleteAndResetFields(id: int, test: bool) =
  updateField(id, "remoteShareDownloadId", "", test)
  updateField(id, "remoteShareControlId", "", test)
  updateField(id, "remoteShareExpireTime", -1, test)

proc deleteTraceCommand*(id: int, controlId: string) =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  let cmd = &"curl -s {config.webApiRoot}/delete?ControlId={controlId}"
  let (output, exitCode) = execCmdEx(cmd)

  if exitCode == 0:
    deleteAndResetFields(id, false)

  quit(exitCode)
