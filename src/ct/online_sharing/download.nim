import streams, nimcrypto, zip/zipfiles, std/[ enumerate, terminal, options, sequtils, strutils, strformat, os, httpclient, mimetypes, uri, net, json ]
import ../../common/[ config, trace_index, paths, lang ]
from stew / byteutils import toBytes
import ../utilities/[ env, encryption, zip, language_detection ]
import ../trace/storage_and_import, ../globals

proc downloadFile(fileId, localPath: string, config: Config) =
  let client = newHttpClient()
  client.downloadFile(fmt"{parseUri(config.baseUrl) / config.downloadApi}?FileId={fileId}", localPath)

proc downloadTrace(fileId, traceDownloadKey: string, key: array[32, byte], config: Config): int =
  var iv: array[16, byte]
  copyMem(addr iv, unsafeAddr key, 16)

  let traceId = trace_index.newID(false)

  let downloadTarget = codetracerTmpPath / &"{fileId}.enc"
  let decryptedTarget = codetracerTmpPath / &"{fileId}.zip"
  let unzippedLocation = codetracerTraceDir / "trace-" & $traceId

  downloadFile(fileId, downloadTarget, config)
  decryptFile(downloadTarget, decryptedTarget, key, iv)
  removeFile(downloadTarget)

  unzipIntoFolder(decryptedTarget, unzippedLocation)
  removeFile(decryptedTarget)

  let tracePath = unzippedLocation / "trace.json"
  let traceJson = parseJson(readFile(tracePath))
  let traceMetadataPath = unzippedLocation / "trace_metadata.json"
  var pathValue = ""
  for item in traceJson:
    if item.hasKey("Path"):
      pathValue = item["Path"].getStr("")
      break

  let lang = detectLang(pathValue, LangUnknown)
  discard importDbTrace(traceMetadataPath, traceId, lang, DB_SELF_CONTAINED_DEFAULT, traceDownloadKey)
  return traceId

proc downloadTraceCommand*(traceDownloadKey: string) =
  # We expect a traceDownloadKey to have <name>//<fileId>//<passwordKey>
  let stringSplit = traceDownloadKey.split("//")
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  if not config.traceSharingEnabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)
  if stringSplit.len() != 3:
    echo "error: Invalid download key! Should be <program_name>//<file_id>//<encryption_password>"
    quit(1)

  let fileId = stringSplit[1]
  let password = stringSplit[2]

  try:
    let fileId = stringSplit[1]
    let passwordHex = stringSplit[2]

    var password: array[32, byte]
    hexToBytes(passwordHex, password)

    let traceId = downloadTrace(fileId, traceDownloadKey, password, config)
    if isatty(stdout):
      echo fmt"OK: downloaded with trace id {traceId}"
    else:
      # being parsed by `ct` index code
      echo traceId

  except CatchableError as e:
    echo fmt"error: downloading file '{e.msg}'"
    quit(1)