import streams, nimcrypto, zip/zipfiles, std/[ enumerate, terminal, options, sequtils, strutils, strformat, os, httpclient, mimetypes, uri, net, json ]
import ../../common/[ config, trace_index, paths, lang ]
from stew / byteutils import toBytes
import ../utilities/[ types, encryption, zip, language_detection ]
import ../trace/storage_and_import, ../globals

proc downloadFile(fileId, localPath: string, config: Config) =
  let client = newHttpClient()
  client.downloadFile(fmt"{parseUri(config.baseUrl) / config.downloadApi}?FileId={fileId}", localPath)

proc downloadTrace*(fileId, traceDownloadKey: string, key: array[32, byte], config: Config): int =
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
  let metadataJson = parseJson(readFile(traceMetadataPath))
  let tracePathsMetadata = parseJson(readFile(unzippedLocation / "trace_paths.json"))
  let isWasm = metadataJson{"program"}.getStr("").split("/")[^1].split(".")[^1] == "wasm" # Check if language is wasm

  var pathValue = ""
  for item in tracePathsMetadata:
    if item.getStr("") != "":
      pathValue = item.getStr("")
      break

  let lang = detectLang(pathValue.split("/")[^1], LangUnknown, isWasm)
  discard importDbTrace(traceMetadataPath, traceId, lang, DB_SELF_CONTAINED_DEFAULT, traceDownloadKey)
  return traceId

proc extractInfoFromKey*(downloadKey: string, config: Config): (string, array[32, byte]) =
  # We expect a traceDownloadKey to have <name>//<fileId>//<passwordKey>
  let stringSplit = downloadKey.split("//")
  if not config.traceSharingEnabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)
  if stringSplit.len() != 3:
    echo "error: Invalid download key! Should be <program_name>//<file_id>//<encryption_password>"
    quit(1)

  let fileId = stringSplit[1]
  let passwordHex = stringSplit[2]

  var password: array[32, byte]
  hexToBytes(passwordHex, password)
  (fileId, password)


proc downloadTraceCommand*(traceDownloadKey: string) =
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  let (fileId, password) = extractInfoFromKey(traceDownloadKey, config)
  try:
    let traceId = downloadTrace(fileId, traceDownloadKey, password, config)
    if isatty(stdout):
      echo fmt"OK: downloaded with trace id {traceId}"
    else:
      # being parsed by `ct` index code
      echo traceId

  except CatchableError as e:
    echo fmt"error: downloading file '{e.msg}'"
    quit(1)
