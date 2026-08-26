## `ct upload` — store a local artifact in the CodeTracer artifact store.
##
## AS-2 (`codetracer-specs/Sharing/Artifact-Store.milestones.org`): this module
## no longer *is* the upload path.  It chooses **what** to store — a recording
## selected from the local index, or a review dataset directory — describes it
## as an artifact, and hands it to `artifact_store.storeArtifact`, which is the
## one transport for every kind.  Everything about *how* bytes move, in which
## order, to which URLs, lives there and in `artifact_transfer.nim`.
##
## That division is the milestone: before AS-1 the upload path took a `Trace`
## and spelled `tenants/{id}/traces/…` by hand, so a second kind would have had
## to masquerade as a trace or bring its own transport.  Now the recording kind
## and the review-dataset kind reach the service through the same procedure, and
## a third kind would too.
##
## Nothing on the wire changed for recordings.  The recording kind's registry
## row keeps the `traces` segment and its request bodies are frozen to the keys
## a deployed service already reads, so a client built after this milestone
## talks to a service deployed before it.

import std/[
  algorithm, terminal, options, strutils, strformat,
  os, json, oids, sugar
]
import ../../common/[ trace_index, types ]
import ../utilities/[ zip, types, progress_update ]
import ../../common/[ config, paths ]
import ../cli/interactive_replay
import ../codetracerconf
import ../trace/shell
import remote_config, api_client, artifact_store, tenant_resolver
import mcr_enrichment

const
  ReviewDatasetJsonName = "review.json"
    ## The file `ct review collect` writes inside its output directory.  Named
    ## here rather than imported from `review_cli` so this module does not pull
    ## the DeepReview command surface into every binary that can upload.

type
  UploadTarget* = object
    ## A resolved local artifact, ready to be described and stored.
    artifact*: Artifact
    parts*: seq[ArtifactPart]
    cleanupPaths*: seq[string]
      ## Temporary files and directories to remove once the transfer is over,
      ## whether it succeeded or not.

proc shareUrlFor(baseUrl, orgSlug, artifactId: string): string =
  ## The link a user hands to somebody else.
  ##
  ## `/{orgSlug}/{artifactId}/download` — the same grammar
  ## `artifact.parseArtifactShareUrl` reads back, and deliberately carrying no
  ## kind (AS-1 §5.3): the id is unique across kinds, so the service resolves
  ## the kind from the id and no link already handed to a user needs rewriting.
  baseUrl.strip(chars = {'/'}) & "/" & orgSlug & "/" & artifactId & "/download"

proc reviewDatasetTarget*(datasetDir: string, tenantId: string,
    artifactId: string): tuple[target: UploadTarget, error: string] =
  ## Describe a `ct review collect` output directory as an artifact of the
  ## review-dataset kind, packed for transfer.
  ##
  ## This is the constructor DS-7 consumes.  It reads the dataset's own
  ## `review.json` for the metadata the kind declares — the commits it
  ## describes, the files it covers, the recordings it was collected from and
  ## the agent session that produced it — so the metadata travelling with the
  ## payload is the dataset's own facts rather than anything invented here.  A
  ## dataset that names no commit is refused by `validateArtifact` rather than
  ## uploaded with a blank where a commit should be.
  let jsonPath = datasetDir / ReviewDatasetJsonName
  if not fileExists(jsonPath):
    return (UploadTarget(), "no " & ReviewDatasetJsonName & " in '" &
      datasetDir & "': `ct review collect --output " & datasetDir &
      "` writes one")

  var dataset: JsonNode
  try:
    dataset = parseJson(readFile(jsonPath))
  except CatchableError as e:
    return (UploadTarget(), "could not read " & jsonPath & ": " & e.msg)

  let sessionNode = dataset{"session"}
  let sessionTitle =
    if sessionNode.isNil: ""
    else: sessionNode{"title"}.getStr()
  var fileCount = dataset{"files"}.getElems.len
  if fileCount == 0:
    fileCount = dataset{"fileCount"}.getInt()
  var recordingCount = dataset{"recordings"}.getElems.len
  if recordingCount == 0:
    recordingCount = dataset{"recordingCount"}.getInt()

  # Pack the directory. Store-only would be the wrong default here: a review
  # dataset is JSON and compresses well, unlike the already-compressed CTFS
  # containers the recording path zips store-only.
  let scratchId = $genOid()
  let scratchDir = codetracerTmpPath / fmt"artifact-upload-{scratchId}"
  createDir(scratchDir)
  let packed = scratchDir / "review-dataset.zip"
  let lastPercentSent = new int
  zipFolder(datasetDir, packed,
    onProgress = proc(progressPercent: int) =
      if progressPercent > lastPercentSent[]:
        lastPercentSent[] = progressPercent
        logUpdate(progressPercent, "Packing review dataset.."))

  let part = singleFilePart(packed)
  let artifact = reviewDatasetArtifact(
    artifactId = artifactId,
    tenantId = tenantId,
    commitSha = dataset{"commitSha"}.getStr(dataset{"headCommit"}.getStr()),
    baseCommitSha = dataset{"baseCommitSha"}.getStr(
      dataset{"baseCommit"}.getStr()),
    byteSize = part.byteSize,
    fileCount = fileCount,
    recordingCount = recordingCount,
    sessionTitle = sessionTitle)

  (UploadTarget(
    artifact: artifact,
    parts: @[part],
    cleanupPaths: @[packed, scratchDir]), "")

proc uploadFile(
  trace: Trace,
  traceZipPath: string,
  org: Option[string],
  token: Option[string] = none(string),
  baseUrl: Option[string] = none(string),
): UploadedInfo {.raises: [KeyError, Exception].} =
  ## Uploads a single-file recording payload through the generic store.
  ##
  ## M-REC-8: the local ``recording_id`` (UUIDv7 minted at record-start)
  ## is the identity shipped to the sharing server.  AS-1 re-framed that as the
  ## recording kind's artifact id; AS-2 makes the transfer itself kind-neutral,
  ## so this procedure's whole job is now "describe the trace as an artifact and
  ## hand it over".
  result = UploadedInfo(exitCode: 0, kind: akRecording)
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

    let part = singleFilePart(traceZipPath)
    let artifact = recordingArtifact(
      recordingId = $trace.recordingId,
      tenantId = tenantId,
      program = $trace.program,
      langName = $trace.lang,
      byteSize = part.byteSize,
      layout = aplSingleFile,
      partCount = 1,
      platform = hostArtifactPlatformToken())

    let stored = client.storeArtifact(
      tenantId, artifact, @[part], bearerToken)
    if stored.error.len > 0:
      echo "error: refusing to upload: " & stored.error
      result.exitCode = 1
      return

    result.artifactId = stored.artifact.artifactId
    # The rule §9.5 states, applied uniformly rather than only where it is
    # likely to bite: a link is issued ONLY when the service named the artifact
    # back.  On this path it normally does — the `…/upload-url` body carries the
    # id and the service echoes it — but "normally" is not the rule, and a
    # service that echoed nothing would otherwise get a link built from an id
    # it has never heard of.
    if stored.serviceAcknowledgedId:
      result.shareUrl = shareUrlFor(
        resolvedBaseUrl, resolvedSlug, stored.artifact.artifactId)

    let replayUrl = fmt"{resolvedBaseUrl}/{resolvedSlug}/replay/confirm/{result.artifactId}"
    echo "File uploaded successfully."
    echo "Recording ID: " & result.artifactId
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
  ## Upload a recording that is already split into slices, as a **slice-set
  ## payload** through the generic store.
  ##
  ## AS-2: the chunking is no longer a trace-shaped step written out here.  The
  ## artifact declares `aplSliceSet` and `artifact_store.storeArtifact` opens a
  ## session, publishes the parts in index order and finalizes — a sequence any
  ## large artifact of any kind can ask for by declaring the same layout.  The
  ## `.smnf` / `.amnf` manifests travel as further parts of the same payload
  ## rather than as a special case, because to the transport they are what
  ## every part is: a named blob at a position in the set.
  ##
  ## If the upload-session API is not available (older server), falls back
  ## to the previous zip-based single-file upload with a warning.
  result = UploadedInfo(exitCode: 0, kind: akRecording)
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

    # Slices first, in name order (slice_0000.ct, slice_0001.ct, …), then the
    # manifests that describe them.  The index a part gets here is the position
    # it is reassembled at, so the order is load-bearing rather than tidy.
    #
    # The two lists are separate, and that separation is what the `/finalize`
    # body's `totalSlices` is built from: a `.smnf` / `.amnf` manifest travels
    # through the same session but is NOT a piece of the payload, and the
    # pre-AS-2 client counted only the `.ct` files.  Passing them as one list
    # would tell the service to reassemble two slices that do not exist.
    let parts = collectSliceParts(
      slicesDir, sliceExtensions = [".ct"],
      sidecarExtensions = [".smnf", ".amnf"])
    let sliceTotal = sliceCount(parts)
    echo "Uploading " & $sliceTotal & " pre-split slices from: " & slicesDir

    let artifact = recordingArtifact(
      recordingId = $trace.recordingId,
      tenantId = tenantId,
      program = $trace.program,
      langName = $trace.lang,
      byteSize = totalByteSize(parts),
      layout = aplSliceSet,
      partCount = parts.len,
      platform = hostArtifactPlatformToken())

    # M31 — forward the client-controlled omniscient-DB upload mode on the
    # CS-M7 ``/finalize`` body.  ``off`` is signalled by sending nothing, so a
    # default-mode client round-trips the legacy body unchanged.
    let wireMode =
      if omniscientDbMode == OmniscientDbMode.off: ""
      else: omniscientDbModeToWireString(omniscientDbMode)

    var stored: ArtifactStoreOutcome
    try:
      stored = client.storeArtifact(
        tenantId, artifact, parts, bearerToken,
        recordingMode = "hook",
        omniscientDbMode = wireMode,
        totalEvents = 0,
        onProgress = proc (message: string) = echo message)
    except ApiError as e:
      # Fallback: the server does not support the upload-session API (older
      # version). Fall back to the zip-based single-file upload.
      echo "WARNING: upload-session API not available (" & e.msg & ")"
      echo "Falling back to zip-based single-file upload."
      # M31 — the legacy single-file fallback path has no ``/finalize`` step
      # that could carry the client-controlled omniscient-DB mode.  Warn when
      # the client picked a non-default mode so the silently-dropped signal is
      # at least visible in the recorder log.
      if omniscientDbMode != OmniscientDbMode.off:
        echo "WARNING: --omniscient-db=" &
          omniscientDbModeToWireString(omniscientDbMode) &
          " has no effect on the legacy single-file upload path " &
          "(needs the upload-session API)."
      return uploadSplitTraceFallback(trace, slicesDir, org, token, baseUrl)

    if stored.error.len > 0:
      echo "error: refusing to upload: " & stored.error
      result.exitCode = 1
      return

    echo "Upload finalized: " & $sliceTotal & " slices" &
      (if wireMode.len > 0:
        " (omniscient-db mode: " & wireMode & ")"
      else: "")

    result.artifactId = stored.artifact.artifactId
    # A distinct field, deliberately: the session id names the *transfer*, in
    # the service's own namespace, and is not an identity for the artifact.
    # One field holding whichever of the two the path happened to produce is
    # `Artifact-Store.md` §8 defect 11, and it is closed by keeping them apart.
    result.uploadSessionId = stored.session.sessionId
    # A link is issued only when the service named the artifact back.  The
    # recording kind's frozen `…/upload-session` body carries no artifact id,
    # so on this path the service usually names the result itself; printing a
    # link built from the local recording id would hand the user a link to
    # something the service has never heard of.
    if stored.serviceAcknowledgedId:
      result.shareUrl = shareUrlFor(
        resolvedBaseUrl, resolvedSlug, stored.artifact.artifactId)

  except CatchableError as e:
    echo "error: uploadSplitTrace exception: ", e.msg
    result.exitCode = 1


proc uploadReviewDataset*(datasetDir: string,
    org: Option[string],
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)): UploadedInfo =
  ## Store a `ct review collect` output directory as an artifact of the
  ## review-dataset kind.
  ##
  ## **This is the deliverable DS-7 consumes.**  It is the same transport the
  ## recording kind takes — `storeArtifact` — reached with a different artifact
  ## description, which is the whole content of "one system, not two".  Nothing
  ## about the review-dataset kind appears in the transport; what appears here
  ## is only how a dataset on disk becomes an artifact.
  result = UploadedInfo(exitCode: 0, kind: akReviewDataset)
  var cleanup: seq[string] = @[]
  try:
    let remoteConf = initRemoteConfig()
    let bearerToken = remoteConf.getBearerToken(token.get(""))
    let resolvedBaseUrl = remoteConf.resolveBaseRemoteUrl(baseUrl.get(""))

    var client = initApiClient(resolvedBaseUrl)
    defer: client.close()

    let defaultOrg = remoteConf.readConfigValue(DefaultOrganizationKey)
    let orgSlug = resolveTenantValueOrSlug(defaultOrg, org.get(""))
    let (tenantId, resolvedSlug) = resolveTenantId(client, orgSlug, bearerToken)

    # A review dataset has no record-start moment to seed an id from, so the
    # store mints one (AS-1 §4).  This is the common case; the recording kind
    # is the documented exception, not the rule.
    let described = reviewDatasetTarget(
      datasetDir, tenantId, newArtifactId())
    if described.error.len > 0:
      echo "error: refusing to upload: " & described.error
      result.exitCode = 1
      return
    cleanup = described.target.cleanupPaths

    let stored = client.storeArtifact(
      tenantId, described.target.artifact, described.target.parts, bearerToken,
      onProgress = proc (message: string) = echo message)
    if stored.error.len > 0:
      echo "error: refusing to upload: " & stored.error
      result.exitCode = 1
      return

    result.artifactId = stored.artifact.artifactId
    # Same rule as every other path — see `uploadFile`.
    if stored.serviceAcknowledgedId:
      result.shareUrl = shareUrlFor(
        resolvedBaseUrl, resolvedSlug, stored.artifact.artifactId)
    echo "Review dataset uploaded."
    echo "Artifact ID: " & result.artifactId

  except CatchableError as e:
    echo "error: uploadReviewDataset exception: ", e.msg
    result.exitCode = 1
  finally:
    for path in cleanup:
      try:
        if fileExists(path): removeFile(path)
        elif dirExists(path): removeDir(path)
      except CatchableError:
        discard


proc uploadTrace*(trace: Trace, org: Option[string],
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string),
    noPortable: bool = false,
    noSplitUpload: bool = false,
    omniscientDbMode: OmniscientDbMode = OmniscientDbMode.off): UploadedInfo =
  ## Store a recording selected from the local trace index.
  ##
  ## **Returns** rather than `quit`s.  Every path through this procedure used
  ## to end in `quit(...)`, which made `uploadCommand`'s success output — both
  ## the human-readable block and the machine-readable JSON line beside it —
  ## unreachable, so a non-interactive caller got no structured result at all
  ## (`Artifact-Store.md` §8 defect 2).  Exiting is the command's decision, and
  ## it is taken in `uploadCommand`; this procedure is a library call.
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
        return uploadSplitTrace(
          trace, slicesDir, org, token, baseUrl, omniscientDbMode)

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
  var uploadInfo = UploadedInfo(kind: akRecording)
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

  uploadInfo

proc uploadResultJson*(info: UploadedInfo): string =
  ## The machine-readable result of an upload, for a non-interactive caller.
  ##
  ## Kind-neutral in shape and explicit about the kind, which is AS-2's rule
  ## for the CLI surface: the id and the link are the same fields whatever was
  ## uploaded, and `kind` says what it was rather than leaving the caller to
  ## infer it.
  ##
  ## Every field here is one the modern path can actually fill.  The retired
  ## `downloadKey` / `controlId` / `storedUntilEpochSeconds` triple was not:
  ## those are the pre-M-REC-8 sharing service's tokens, no code assigned them
  ## on this path, and printing them meant printing empty strings and a zero
  ## (`Artifact-Store.md` §8 defect 3).
  var body = %*{
    "artifactId": info.artifactId,
    "kind": kindSpec(info.kind).wireToken,
  }
  if info.shareUrl.len > 0:
    body["shareUrl"] = newJString(info.shareUrl)
  if info.uploadSessionId.len > 0:
    # Present only when a multi-part transfer actually opened a session, and
    # named for what it is: a handle on the transfer, in the service's own
    # namespace, not an identity for the artifact.
    body["uploadSessionId"] = newJString(info.uploadSessionId)
  $body

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
  # AS-2 — the kind-neutral half of the CLI surface: a local path to store,
  # whatever kind of artifact it is, and an optional explicit kind for when
  # the path cannot be classified on its own.
  artifactPath: Option[string] = none(string),
  artifactKind: Option[string] = none(string),
) =
  let config: Config = loadConfig(folder=getCurrentDir(), inTest=false)

  if not config.traceSharing.enabled:
    echo TRACE_SHARING_DISABLED_ERROR_MESSAGE
    quit(1)

  var uploadInfo: UploadedInfo

  if artifactPath.isSome and artifactPath.get.len > 0:
    let path = artifactPath.get
    let classified = classifyLocalArtifact(path, artifactKind.get(""))
    if classified.error.len > 0:
      echo classified.error
      quit(1)
    case classified.kind.get
    of akReviewDataset:
      uploadInfo = uploadReviewDataset(
        path, uploadOrg, uploadToken, uploadBaseUrl)
    of akRecording:
      # A recording named by path is the existing `--trace-folder` selection;
      # routing it there rather than duplicating the lookup keeps one way of
      # turning a folder into a `Trace`.
      let trace = findTraceForArgs(
        none(string), none(string), some(path))
      if trace.isNil:
        echo "ERROR: can't find trace in local database"
        quit(1)
      try:
        uploadInfo = uploadTrace(trace, uploadOrg, uploadToken, uploadBaseUrl,
          noPortable, noSplitUpload, omniscientDbMode)
      except CatchableError as e:
        echo e.msg
        quit(1)
  else:
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

  if uploadInfo.isNil:
    echo "error: the upload produced no result"
    quit(1)
  if uploadInfo.exitCode != 0:
    quit(uploadInfo.exitCode)

  if isatty(stdout):
    echo ""
    if uploadInfo.shareUrl.len > 0:
      echo "OK: uploaded. You can share this link:"
      echo "  " & uploadInfo.shareUrl
      echo ""
      echo "NB: it is sensitive — anyone with this link can open what you " &
        "shared."
      echo ""
      echo "Download it with:"
      echo "  ct download " & uploadInfo.shareUrl
    else:
      # No link is printed when the service did not name the artifact back.
      # Printing one built from the local id would send a user to something
      # the service has never heard of, which is worse than saying less.
      echo "OK: uploaded " & kindSpec(uploadInfo.kind).wireToken & " " &
        uploadInfo.artifactId & "."
      echo "Open the CodeTracer web app to get its sharing link."
  else:
    echo uploadResultJson(uploadInfo)

  quit(0)
