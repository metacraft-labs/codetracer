import std/[ terminal, options, strutils, strformat, os, httpclient, uri, net, json, sequtils ]
import ../../common/[ trace_index, types ]
import ../utilities/[ encryption, zip, env ]
import ../../common/[ config ]
import ../cli/interactive_replay
import ../codetracerconf
import ../trace/shell

type UploadedInfo = ref object
  fileId: string
  downloadKey: string
  controlId: string
  storedUntilEpochSeconds: int

proc uploadFile(file: string, config: Config): UploadedInfo {.raises: [KeyError, Exception].} =
  var client = newHttpClient()

  try:
    let getUrlResponse = client.getContent(fmt"{parseUri(config.baseUrl) / config.getUploadUrlApi}")
    let getUrlJson = parseJson(getUrlResponse);

    let uploadUrl = getUrlJson["UploadUrl"].getStr("").strip()
    let fileId = getUrlJson["FileId"].getStr("").strip()
    let controlId = getUrlJson["ControlId"].getStr("")
    let storedUntilEpochSeconds = getUrlJson["FileStoredUntil"].getInt()
    if fileId == "" or uploadUrl == "" or controlId == "" or storedUntilEpochSeconds == 0:
      raise newException(KeyError, "error: Can't parse response")
      
    var data = newMultipartData()
    data.addFiles({"file": file}) 
    discard client.putContent(uploadUrl, multipart=data)
    client.close()

    return UploadedInfo(fileId: fileId, controlId: controlId, storedUntilEpochSeconds: storedUntilEpochSeconds)
  except CatchableError as e:
    raise newException(Exception, &"error: can't upload to API: {e.msg}")

proc uploadTrace(trace: Trace, config: Config): UploadedInfo =
  let outputZip = trace.outputFolder / "tmp.zip"
  let outputEncr = trace.outputFolder / "tmp.enc"
  let (key, iv) = generateEncryptionKey()

  try:
    zipFolder(trace.outputFolder, outputZip)
    encryptFile(outputZip, outputEncr, key, iv)
    let uploadInfo: UploadedInfo = uploadFile(outputEncr, config)
    uploadInfo.downloadKey = trace.program & "//" & uploadInfo.fileId & "//" & key.mapIt(it.toHex(2)).join("")

    updateField(trace.id, "remoteShareDownloadKey", uploadInfo.downloadKey, false)
    updateField(trace.id, "remoteShareControlId", uploadInfo.controlId, false)
    updateField(trace.id, "remoteShareExpireTime", uploadInfo.storedUntilEpochSeconds, false)  
    return uploadInfo
  finally:
    removeFile(outputZip)
    removeFile(outputEncr)


proc uploadCommand*(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
) =
  let config: Config = loadConfig(folder=getCurrentDir(), inTest=false)

  if not config.traceSharingEnabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  var uploadInfo: UploadedInfo
  var tracePath: Trace

  if interactive:
    tracePath = interactiveTraceSelectMenu(StartupCommand.upload)
  else:
    tracePath = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)

  try:
    uploadInfo = uploadTrace(tracePath, config)
  except CatchableError as e:
    echo e.msg
    quit(1)

  if isatty(stdout):
    echo fmt"""
      OK: uploaded, you can share the link.
      NB: It's sensitive: everyone with this link can access your trace!

      Download with:
      `ct download {uploadInfo.downloadKey}`
      """
  else:
    echo uploadInfo.downloadKey
    echo uploadInfo.controlId
    echo uploadInfo.storedUntilEpochSeconds
  
  quit(0)

