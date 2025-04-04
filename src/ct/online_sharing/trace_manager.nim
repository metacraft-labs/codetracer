import std / [ options, strutils, os, strformat, json, httpclient, uri, terminal, net ], ../trace/replay, ../codetracerconf, zip/zipfiles, nimcrypto
import ../../common/[ config, trace_index, lang, paths ]
import ../utilities/language_detection
import ../trace/[ storage_and_import]
import security_upload
import ../globals

const TRACE_SHARING_DISABLED_ERROR_MESSAGE = """
trace sharing disabled in config!
you can enable it by editing `$HOME/.config/codetracer/.config.yaml`
and toggling `traceSharingEnabled` to true
"""

proc uploadCommand*(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
) =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  if config.traceSharingEnabled:
    discard internalReplayOrUpload(patternArg, traceIdArg, traceFolderArg, interactive, command=StartupCommand.upload)
  else:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)


proc decryptZip(encryptedFile: string, password: string, outputFile: string) =
  var encData = readFile(encryptedFile).toBytes()
  if encData.len < 16:
    raise newException(ValueError, "Invalid encrypted data (too short)")

  if password.len < 16:
    raise newException(ValueError, "Invalid password (too short)")

  let iv = password.toBytes()[0 ..< 16]
  let ciphertext = encData[16 .. ^1]
  let key = password.toBytes()

  var aes: CBC[aes256]
  aes.init(key, iv)

  var decrypted = newSeq[byte](encData.len)
  aes.decrypt(encData, decrypted.toOpenArray(0, len(decrypted) - 1))

  var depaddedData = pkcs7Unpad(decrypted)
  writeFile(outputFile, depaddedData)

proc unzipFile(zipFile: string, outputDir: string): (string, int) =
  var zip: ZipArchive
  if not zip.open(zipFile, fmRead):
    raise newException(IOError, "Failed to open decrypted ZIP: " & zipFile)

  let traceId = trace_index.newID(false)
  let outPath = outputDir / "trace-" & $traceId

  createDir(outPath)
  zip.extractAll(outPath)

  zip.close()
  return (outPath, traceId)

proc downloadTraceCommand*(traceRegistryId: string) =
  # We expect a traceRegistryId to have <downloadId>::<passwordKey>
  let stringSplit = traceRegistryId.split("//")
  if stringSplit.len() != 3:
    echo "error: Invalid download key! Should be <program_name>//<download_id>//<encryption_password>"
    quit(1)
  else:
    let downloadId = stringSplit[1]
    let password = stringSplit[2]
    let zipPath = codetracerTmpPath / &"{downloadId}.zip"
    let config = loadConfig(folder=getCurrentDir(), inTest=false)
    if not config.traceSharingEnabled:
      echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
      quit(1)

    # <enabled case>:

    let localPath = codetracerTmpPath / &"{downloadId}.zip.enc"

    var client = newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))
    var exitCode = 0

    try:
      client.downloadFile(fmt"{parseUri(config.baseUrl) / config.downloadApi}?DownloadId={downloadId}", localPath)

      decryptZip(localPath, password, zipPath)

      let (traceFolder, traceId) = unzipFile(zipPath, codetracerTraceDir)
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

      if isatty(stdout):
        echo fmt"OK: downloaded with trace id {traceId}"
      else:
        # being parsed by `ct` index code
        echo traceId

    except CatchableError as e:
      echo fmt"error: downloading file '{e.msg}'"
      exitCode = 1

    finally:
      removeFile(localPath)
      removeFile(zipPath)

    quit(exitCode)

proc deleteTraceCommand*(id: int, controlId: string) =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  if not config.traceSharingEnabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  # <enabled case>:

  let test = false
  var exitCode = 0

  var client = newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))
  
  try:
    discard client.getContent(fmt"{parseUri(config.baseUrl) / config.deleteApi}?ControlId={controlId}")
    
    updateField(id, "remoteShareDownloadId", "", test)
    updateField(id, "remoteShareControlId", "", test)
    updateField(id, "remoteShareExpireTime", -1, test)
    exitCode = 0
  except CatchableError as e:
    echo fmt"error: can't delete trace {e.msg}"
    exitCode = 1
  finally:
    client.close()

  quit(exitCode)
