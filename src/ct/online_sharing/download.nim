proc downloadFile(fileId: string) =
      client.downloadFile(fmt"{parseUri(config.baseUrl) / config.downloadApi}?FileId={fileId}", localPath)

proc downloadTrace(fileId: string): string
  let traceId = trace_index.newID(false)

  let downloadTarget = codetracerTmpPath / &"{fileId}.enc"
  let unencryptedTarget = codetracerTmpPath / &"{fileId}.zip"
  let unzippedLocation = outputDir / "trace-" & $traceId
    downloadFile
    decrtyptFile
      removeFile(localPath)
      removeFile(zipPath)
 
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
  return traceId

proc downloadTraceCommand*(traceRegistryId: string) =
  # We expect a traceRegistryId to have <name>//<fileId>//<passwordKey>
  let stringSplit = traceRegistryId.split("//")
  if not config.traceSharingEnabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)
  if stringSplit.len() != 3:
    echo "error: Invalid download key! Should be <program_name>//<file_id>//<encryption_password>"
    quit(1)

  let fileId = stringSplit[1]
  let password = stringSplit[2]
  let config = loadConfig(folder=getCurrentDir(), inTest=false)

  try:
    let fileId = stringSplit[1]
    let password = stringSplit[2]
    let result = downloadTrace
    if isatty(stdout):
      echo fmt"OK: downloaded with trace id {traceId}"
    else:
      # being parsed by `ct` index code
      echo traceId

  except CatchableError as e:
    echo fmt"error: downloading file '{e.msg}'"
    quit(1)