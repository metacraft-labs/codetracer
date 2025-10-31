import std/[ 
  terminal, options, strutils, strformat,
  os, httpclient, uri, net, json,
  sequtils, streams, oids
]
import ../../common/[ trace_index, types ]
import ../utilities/[ zip, types, progress_update ]
import ../../common/[ config, paths ]
import ../cli/interactive_replay
import ../codetracerconf
import ../trace/shell
import remote

proc uploadFile(
  traceZipPath: string,
  org: Option[string],
  config: Config
): UploadedInfo {.raises: [KeyError, Exception].} =

  result = UploadedInfo(exitCode: 0)
  try:
    var args = @["upload", traceZipPath]
    if org.isSome:
      args.add("--org")
      args.add(org.get)
    result.exitCode = runCtRemote(args)
  except CatchableError as e:
    echo "error: uploadFile exception: ", e.msg

  # TODO: for now ct-remote outputs the info
  #   for integration with welcome-screen we might eventually
  #   get json and process it here again in the future

  # return UploadedInfo(
  #   fileId: fileId,
  #   controlId: controlId,
  #   storedUntilEpochSeconds: storedUntilEpochSeconds
  # )


proc onProgress(ratio, start: int, message: string, lastPercentSent: ref int): proc(progressPercent: int) =
  proc(progressPercent: int) =
    let scaled = start + (progressPercent * ratio) div 100
    if scaled > lastPercentSent[]:
      lastPercentSent[] = scaled
      logUpdate(scaled, message)


proc uploadTrace*(trace: Trace, org: Option[string], config: Config): UploadedInfo =
  # try to generate a unique path, so even if we don't remove it/clean it up
  #   it's not easy to clash with it on a next upload
  # https://nim-lang.org/docs/oids.html
  let id = $genOid()
  let traceTempUploadZipFolder = codetracerTmpPath / fmt"trace-upload-zips-{id}"
  createDir(traceTempUploadZipFolder)
  # alexander: import to be tmp.zip for the codetracer-ci service iirc
  let outputZip = traceTempUploadZipFolder / fmt"tmp.zip"

  let lastPercentSent = new int
  zipFolder(trace.outputFolder, outputZip, onProgress = onProgress(ratio = 33, start = 0, "Zipping files..", lastPercentSent))
  var uploadInfo = UploadedInfo()
  try:
    uploadInfo = uploadFile(outputZip, org, config)
  
    # TODO: after we have link and welcome screen integration again
    #   for now just leave the output to ct-remote: we quit directly in uploadFile for now
    # uploadInfo.downloadKey = trace.program & "//" & uploadInfo.fileId & "//" & key.mapIt((it.uint64).toHex(2)).join("")
    # updateField(trace.id, "remoteShareDownloadKey", uploadInfo.downloadKey, false)
  except CatchableError as e:
    echo "uploadTrace error: ", e.msg
    uploadInfo.exitCode = 1
  finally:
    removeFile(outputZip)
    # TODO: if we start to support directly passed zips: as an argument or because
    #   of multitraces, don't remove such a folder for those cases
    # this one is just a temp one:
    removeDir(traceTempUploadZipFolder)

  quit(uploadInfo.exitCode)

  # TODO: result = uploadInfo?

proc uploadCommand*(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool,
  uploadOrg: Option[string],
) =
  # TODO: re-enable when ready
  echo "command not functional yet"
  quit(1)

  let config: Config = loadConfig(folder=getCurrentDir(), inTest=false)

  if not config.traceSharing.enabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  var uploadInfo: UploadedInfo
  var trace: Trace

  if interactive:
    trace = interactiveTraceSelectMenu(StartupCommand.upload)
  else:
    trace = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)

  if trace.isNil:
    echo "ERROR: can't find trace in local database"
    quit(1)

  try:
    uploadInfo = uploadTrace(trace, uploadOrg, config)
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
