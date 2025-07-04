import std/[ terminal, options, strutils, strformat, os, httpclient, uri, net, json, sequtils ]
import ../../common/[ trace_index, types ]
import ../utilities/[ encryption, zip, types, progress_update ]
import ../../common/[ config ]
import ../cli/interactive_replay
import ../codetracerconf
import ../trace/shell
import streams

proc uploadFile(
  file: string,
  config: Config,
  onProgress: proc(progressPercent: int) = nil
): UploadedInfo {.raises: [KeyError, Exception].} =

  var client = newHttpClient(sslContext=newContext(verifyMode=CVerifyPeer))
  let totalSize = getFileSize(file)

  try:
    let getUrlResponse = client.getContent(fmt"{parseUri(config.traceSharing.baseUrl) / config.traceSharing.getUploadUrlApi}")
    let getUrlJson = parseJson(getUrlResponse)

    let uploadUrl = getUrlJson[UPLOAD_URL_FIELD].getStr("").strip()
    let fileId = getUrlJson[FILE_ID_FIELD].getStr("").strip()
    let controlId = getUrlJson[CONTROL_ID_FIELD].getStr("")
    let storedUntilEpochSeconds = getUrlJson[FILE_STORED_FIELD].getInt()
    if fileId == "" or uploadUrl == "" or controlId == "" or storedUntilEpochSeconds == 0:
      raise newException(KeyError, "error: Can't parse response")

    let boundary = "----NimUploadBoundary"
    let filename = extractFilename(file)

    var uploadStream = newStringStream()
    proc writeLine(s: string) = uploadStream.write(s & "\r\n")

    # Write multipart headers
    writeLine("--" & boundary)
    writeLine("Content-Disposition: form-data; name=\"file\"; filename=\"" & filename & "\"")
    writeLine("Content-Type: application/octet-stream")
    writeLine("")

    let fileSize = getFileSize(file)

    # Read file and simulate streaming while calling onProgress
    var sent = 0
    var fileStream = open(file, fmRead)
    var buf: array[4096, byte]
    var readBytes: int
    var lastPercentSent = 0
    var currentProgress = 0

    while true:
      readBytes = fileStream.readBuffer(addr buf[0], buf.len)
      if readBytes == 0: break
      uploadStream.writeData(addr buf[0], readBytes)
      if not onProgress.isNil:
        sent += readBytes
        currentProgress = int((sent * 100) div totalSize)
        if currentProgress > lastPercentSent:
          onProgress(currentProgress)
          lastPercentSent = currentProgress

    fileStream.close()

    # End of multipart form
    writeLine("")
    writeLine("--" & boundary & "--")

    # Actually send the request
    client.headers["Content-Type"] = "multipart/form-data; boundary=" & boundary
    discard client.putContent(uploadUrl, uploadStream.data)

    return UploadedInfo(
      fileId: fileId,
      controlId: controlId,
      storedUntilEpochSeconds: storedUntilEpochSeconds
    )

  except CatchableError as e:
    raise newException(Exception, &"error: can't upload to API: {e.msg}")

proc onProgress(ratio, start: int, message: string, lastPercentSent: ref int): proc(progressPercent: int) =
  proc(progressPercent: int) =
    let scaled = start + (progressPercent * ratio) div 100
    if scaled > lastPercentSent[]:
      lastPercentSent[] = scaled
      logUpdate(scaled, message)

proc uploadTrace*(trace: Trace, config: Config): UploadedInfo =
  let outputZip = trace.outputFolder / "tmp.zip"
  let outputEncr = trace.outputFolder / "tmp.enc"
  let (key, iv) = generateEncryptionKey()

  try:
    let lastPercentSent = new int
    zipFolder(trace.outputFolder, outputZip, onProgress = onProgress(ratio = 33, start = 0, "Zipping files..", lastPercentSent))
    encryptFile(outputZip, outputEncr, key, iv, onProgress = onProgress(ratio = 33, start = 34, "Encrypting zip file...", lastPercentSent))
    let uploadInfo: UploadedInfo = uploadFile(outputEncr, config, onProgress = onProgress(ratio = 33, start = 67, "Uploading file to server...", lastPercentSent))
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

  if not config.traceSharing.enabled:
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
    echo "\n"
    echo fmt"""
      OK: uploaded, you can share the link.
      NB: It's sensitive: everyone with this link can access your trace!

      Download with:
      `ct download {uploadInfo.downloadKey}`
      """
  else:
    echo fmt"""{{"downloadKey": "{uploadInfo.downloadKey}", "controlId": "{uploadInfo.controlId}", "storedUntilEpochSeconds": {uploadInfo.storedUntilEpochSeconds}}}"""
  
  quit(0)
