import streams, nimcrypto, zip/zipfiles, std/[ sequtils, strutils, strformat, os, httpclient, mimetypes, uri, net, json ]
from stew / byteutils import toBytes
import ../../common/[ config ]

type UploadedInfo = object
  fileId: string
  downloadKey: string
  controlId: string
  storedUntilEpochSeconds: int

proc uploadFile(file: string, config: Config): UploadedInfo =
  var client = newHttpClient()
  try:
    let getUrlResponse = client.getContent(fmt"{parseUri(config.baseUrl) / config.getUploadUrlApi}")
    let getUrlJson = parseJson(getUrlResponse);

    let uploadUrl = getUrlJson["UploadUrl"].getStr("").strip()
    let fileId = getUrlJson["FileId"].getStr("").strip()
    let controlId = getUrlJson["ControlId"].getStr("")
    let storedUntilEpochSeconds = jsonMessage["StoredUntilEpochSeconds"].getInt()
    if downloadId == "" or uploadUrl == "" or controlId == "" or storedUntilEpochSeconds == 0:
      raise "error: can't upload to API: {e.msg}"
      
    var data = newMultipartData()
    data.addFiles({"file": file}) 
    client.putContent(uploadUrl, multipart=data)
    client.close()
    return UploadedInfo(fileId: fileId, controlId: controlId, storedUntilEpochSeconds: storedUntilEpochSeconds)
  except CatchableError as e:
    raise "error: can't upload to API: {e.msg}"

proc uploadTrace(trace: Trace, config: Config): UploadedInfo =
  let outputZip = trace.outputFolder / "tmp.zip"
  let outputEncr = trace.outputFolder / "tmp.enc"
  let (key, iv) = generateSecurePassword()

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
  if config.traceSharingEnabled:
    echo const TRACE_SHARING_DISABLED_ERROR_MESSAGE = """
trace sharing disabled in config!
you can enable it by editing `$HOME/.config/codetracer/.config.yaml`
and toggling `traceSharingEnabled` to true
"""
    quit(1)

  var tracePath: string
  if interactive:
    tracePath = interactiveTraceSelectMenu()
  else 
    tracePath = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)
  try:
  let uploadInfo: UploadInfo = uploadTrace(tracePath, config)
  except:
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

