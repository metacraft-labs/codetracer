import std/[
  algorithm, terminal, options, strutils, strformat,
  os, httpclient, uri, net, json,
  sequtils, streams, oids, sugar
]
import ../../common/[ trace_index, types ]
import ../utilities/[ zip, types, progress_update ]
import ../../common/[ config, paths ]
import ../cli/interactive_replay
import ../codetracerconf
import ../trace/shell
import remote_config, api_client, file_transfer, tenant_resolver
import mcr_enrichment

proc uploadFile(
  trace: Trace,
  traceZipPath: string,
  org: Option[string],
  token: Option[string] = none(string),
  baseUrl: Option[string] = none(string),
): UploadedInfo {.raises: [KeyError, Exception].} =
  ## Uploads a trace zip file to the CI platform using the native API client.
  ## Returns an UploadedInfo with the exit code and recording id.
  ##
  ## M-REC-8: the local ``recording_id`` (UUIDv7 minted at record-start)
  ## is now the identity shipped to the sharing server.  ``trace`` is
  ## carried in so the recording id (``trace.recordingId``) can be sent
  ## in the upload-url request body.
  result = UploadedInfo(exitCode: 0)
  try:
    let remoteConf = initRemoteConfig()
    let bearerToken = remoteConf.getBearerToken(token.get(""))
    let resolvedBaseUrl = remoteConf.resolveBaseRemoteUrl(baseUrl.get(""))

    var client = initApiClient(resolvedBaseUrl)
    defer: client.close()

    # Resolve the target tenant/organization.
    let defaultOrg = remoteConf.readConfigValue(DefaultOrganizationKey)
    let orgSlug = resolveTenantValueOrSlug(defaultOrg, org.get(""))
    let (tenantId, resolvedSlug) = resolveTenantId(client, orgSlug, bearerToken)

    # Request a presigned upload URL from the server.  The client sends
    # its own UUIDv7 ``recording_id`` so the server can record it as the
    # canonical identity of the uploaded trace.
    let fileSize = getFileSize(traceZipPath)
    let fileName = extractFilename(traceZipPath)
    let uploadResp = client.requestTraceUploadUrl(
      tenantId, trace.recordingId, fileName, "application/zip", fileSize,
      bearerToken)

    # Upload the file to the presigned URL.
    let etag = putFile(uploadResp.uploadUrl, traceZipPath)

    # Confirm the upload with the ETag.
    client.confirmTraceUpload(uploadResp.recordingId, etag, bearerToken)

    result.fileId = uploadResp.recordingId

    let replayUrl = fmt"{resolvedBaseUrl}/{resolvedSlug}/replay/confirm/{uploadResp.recordingId}"
    echo "File uploaded successfully."
    echo "Recording ID: " & uploadResp.recordingId
    echo "You can run the replay in the browser from here:"
    echo "  " & replayUrl

  except CatchableError as e:
    echo "error: uploadFile exception: ", e.msg
    result.exitCode = 1


proc onProgress(ratio, start: int, message: string, lastPercentSent: ref int): proc(progressPercent: int) =
  proc(progressPercent: int) =
    let scaled = start + (progressPercent * ratio) div 100
    if scaled > lastPercentSent[]:
      lastPercentSent[] = scaled
      logUpdate(scaled, message)


proc uploadSplitTraceFallback(trace: Trace, slicesDir: string,
    org: Option[string],
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)): UploadedInfo =
  ## Fallback for servers that do not support the upload-session API.
  ## Zips the slices directory (store-only, no compression since CTFS files
  ## are already internally compressed) and uploads as a single file.
  let sliceCount = countSlices(slicesDir)
  echo "Uploading " & $sliceCount & " pre-split slices (zip fallback) from: " & slicesDir

  let id = $genOid()
  let traceTempUploadZipFolder = codetracerTmpPath / fmt"trace-upload-zips-{id}"
  createDir(traceTempUploadZipFolder)
  let outputZip = traceTempUploadZipFolder / fmt"tmp.zip"

  let lastPercentSent = new int
  zipFolder(slicesDir, outputZip,
    onProgress = onProgress(ratio = 33, start = 0,
      "Zipping slices (store-only, no compression)..", lastPercentSent),
    storeOnly = true)

  var uploadInfo = UploadedInfo()
  try:
    uploadInfo = uploadFile(trace, outputZip, org, token, baseUrl)
  except CatchableError as e:
    echo "uploadSplitTrace fallback error: ", e.msg
    uploadInfo.exitCode = 1
  finally:
    removeFile(outputZip)
    removeDir(traceTempUploadZipFolder)

  return uploadInfo


proc uploadSplitTrace*(trace: Trace, slicesDir: string,
    org: Option[string],
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string),
    omniscientDbMode: OmniscientDbMode = OmniscientDbMode.off): UploadedInfo =
  ## Upload each pre-split slice individually using the upload-session API.
  ## No zip/tar — each .ct file is uploaded directly to S3 via a presigned URL.
  ##
  ## Flow:
  ## 1. Request an upload session from the server
  ## 2. For each slice .ct file:
  ##    a. Request a presigned URL for this slice
  ##    b. PUT the .ct file directly to the presigned URL
  ## 3. Upload the manifest (if present) using the same mechanism
  ## 4. Finalize the session with total slice count
  ##
  ## If the upload-session API is not available (older server), falls back
  ## to the previous zip-based single-file upload with a warning.
  result = UploadedInfo(exitCode: 0)
  try:
    let remoteConf = initRemoteConfig()
    let bearerToken = remoteConf.getBearerToken(token.get(""))
    let resolvedBaseUrl = remoteConf.resolveBaseRemoteUrl(baseUrl.get(""))

    var client = initApiClient(resolvedBaseUrl)
    defer: client.close()

    # Resolve the target tenant/organization.
    let defaultOrg = remoteConf.readConfigValue(DefaultOrganizationKey)
    let orgSlug = resolveTenantValueOrSlug(defaultOrg, org.get(""))
    let (tenantId, _) = resolveTenantId(client, orgSlug, bearerToken)

    # Collect and sort slice .ct files so they upload in the correct order
    # (slice_0000.ct, slice_0001.ct, ...).
    let sliceFiles = algorithm.sorted(collect(
      for f in walkDir(slicesDir):
        if f.kind == pcFile and f.path.endsWith(".ct"):
          f.path), SortOrder.Ascending)

    let sliceCount = sliceFiles.len
    echo "Uploading " & $sliceCount & " pre-split slices from: " & slicesDir

    # 1. Create upload session.
    var session: UploadSessionResponse
    try:
      session = client.requestUploadSession(
        tenantId, "linux-x86_64", "hook", bearerToken)
    except ApiError as e:
      # Fallback: the server does not support the upload-session API (older
      # version). Fall back to the zip-based single-file upload.
      echo "WARNING: upload-session API not available (" & e.msg & ")"
      echo "Falling back to zip-based single-file upload."
      # M31 — the legacy single-file fallback path has no
      # ``/finalize`` step that could carry the client-controlled
      # omniscient-DB mode.  Warn when the client picked a non-default
      # mode so the silently-dropped signal is at least visible in
      # the recorder log.
      if omniscientDbMode != OmniscientDbMode.off:
        echo "WARNING: --omniscient-db=" &
          omniscientDbModeToWireString(omniscientDbMode) &
          " has no effect on the legacy single-file upload path " &
          "(needs the upload-session API)."
      return uploadSplitTraceFallback(trace, slicesDir, org, token, baseUrl)

    echo "Upload session created: " & session.sessionId

    # 2. Upload each slice .ct file individually.
    for i, slicePath in sliceFiles:
      let fileName = extractFilename(slicePath)
      let fileSize = getFileSize(slicePath)
      echo "  Uploading slice " & $(i + 1) & "/" & $sliceCount &
        ": " & fileName & " (" & $fileSize & " bytes)"

      let sliceUrl = client.requestSliceUploadUrl(
        session.sessionId, i, fileName, fileSize, bearerToken)

      discard putFile(sliceUrl.uploadUrl, slicePath)

    # 3. Upload manifest files (.smnf, .amnf) if present. These are not
    # .ct slice files but belong to the same upload session.
    var manifestIndex = sliceCount
    for f in walkDir(slicesDir):
      if f.kind == pcFile and
          (f.path.endsWith(".smnf") or f.path.endsWith(".amnf")):
        let fileName = extractFilename(f.path)
        let fileSize = getFileSize(f.path)
        echo "  Uploading manifest: " & fileName &
          " (" & $fileSize & " bytes)"
        let manifestUrl = client.requestSliceUploadUrl(
          session.sessionId, manifestIndex, fileName, fileSize, bearerToken)
        discard putFile(manifestUrl.uploadUrl, f.path)
        inc manifestIndex

    # 4. Finalize the upload session. The server will mark the trace as
    # complete and begin any post-upload processing.
    #
    # M31 — forward the client-controlled omniscient-DB upload mode on
    # the CS-M7 ``/finalize`` camelCase body so the cluster knows how
    # to prepare the omniscient artefacts for this slice.  When the
    # client picks ``off`` we omit the field entirely so legacy
    # recorders continue to round-trip unchanged (the server's CS-M7
    # default is also ``off``).
    let wireMode =
      if omniscientDbMode == OmniscientDbMode.off: ""
      else: omniscientDbModeToWireString(omniscientDbMode)
    client.finalizeUploadSession(
      session.sessionId, sliceCount, 0, "linux-x86_64", bearerToken,
      wireMode)
    echo "Upload finalized: " & $sliceCount & " slices" &
      (if wireMode.len > 0:
        " (omniscient-db mode: " & wireMode & ")"
      else: "")

    result.fileId = session.sessionId

  except CatchableError as e:
    echo "error: uploadSplitTrace exception: ", e.msg
    result.exitCode = 1


proc uploadTrace*(trace: Trace, org: Option[string],
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string),
    noPortable: bool = false,
    noSplitUpload: bool = false,
    omniscientDbMode: OmniscientDbMode = OmniscientDbMode.off): UploadedInfo =
  # Detect and enrich MCR traces before upload. This adds binaries and
  # debug symbols to the .ct container so the trace is self-contained
  # and can be replayed on a different machine (e.g. the CI server).
  let enriched = enrichMcrTraceIfNeeded(trace.outputFolder, noPortable)
  if enriched:
    echo "MCR trace detected: added portable payload (binaries + symbols)"

  # Check for pre-split slices. When ct-mcr record --split is used, the trace
  # output contains a _slices/ directory with individual .ct files. Uploading
  # just the slices directory avoids duplicating data (the full .ct is the
  # concatenation of all slices) and gives the server pre-split files.
  if not noSplitUpload:
    let slicesDir = findSlicesDir(trace.outputFolder)
    if slicesDir.len > 0:
      let sliceCount = countSlices(slicesDir)
      if sliceCount > 0:
        echo "MCR trace with pre-split slices detected"
        let uploadInfo = uploadSplitTrace(
          trace, slicesDir, org, token, baseUrl, omniscientDbMode)
        quit(uploadInfo.exitCode)

  # Full upload: zip the entire outputFolder and upload as one file.
  # try to generate a unique path, so even if we don't remove it/clean it up
  #   it's not easy to clash with it on a next upload
  # https://nim-lang.org/docs/oids.html
  #
  # M31 — the full-zip single-file path uploads via the legacy
  # ``upload-url`` + ``confirm-upload`` flow and has no ``/finalize``
  # step.  Warn so the silently-dropped client-controlled mode is at
  # least visible in the recorder log.
  if omniscientDbMode != OmniscientDbMode.off:
    echo "WARNING: --omniscient-db=" &
      omniscientDbModeToWireString(omniscientDbMode) &
      " has no effect on the single-file upload path " &
      "(needs ct-mcr --split + the upload-session API)."
  let id = $genOid()
  let traceTempUploadZipFolder = codetracerTmpPath / fmt"trace-upload-zips-{id}"
  createDir(traceTempUploadZipFolder)
  # alexander: import to be tmp.zip for the codetracer-ci service iirc
  let outputZip = traceTempUploadZipFolder / fmt"tmp.zip"

  let lastPercentSent = new int
  zipFolder(trace.outputFolder, outputZip, onProgress = onProgress(ratio = 33, start = 0, "Zipping files..", lastPercentSent))
  var uploadInfo = UploadedInfo()
  try:
    uploadInfo = uploadFile(trace, outputZip, org, token, baseUrl)
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
  # M-REC-3: UUIDv7 recording-id string.
  recordingIdArg: Option[string],
  traceFolderArg: Option[string],
  interactive: bool,
  uploadOrg: Option[string],
  uploadToken: Option[string] = none(string),
  uploadBaseUrl: Option[string] = none(string),
  noPortable: bool = false,
  noSplitUpload: bool = false,
  # M31 — client-controlled omniscient-DB upload mode.  Forwarded to
  # the CS-M7 ``/finalize`` body as the camelCase ``omniscientDbMode``
  # field.  Default ``off`` round-trips legacy CS-M7 behaviour
  # unchanged.
  omniscientDbMode: OmniscientDbMode = OmniscientDbMode.off,
) =
  let config: Config = loadConfig(folder=getCurrentDir(), inTest=false)

  if not config.traceSharing.enabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  var uploadInfo: UploadedInfo
  var trace: Trace

  if interactive:
    trace = interactiveTraceSelectMenu(StartupCommand.upload)
  else:
    trace = findTraceForArgs(patternArg, recordingIdArg, traceFolderArg)

  if trace.isNil:
    echo "ERROR: can't find trace in local database"
    quit(1)

  try:
    uploadInfo = uploadTrace(trace, uploadOrg, uploadToken, uploadBaseUrl,
      noPortable, noSplitUpload, omniscientDbMode)
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
