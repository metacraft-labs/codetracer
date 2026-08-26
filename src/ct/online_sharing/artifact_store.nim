## The generic store: upload and download by artifact id (AS-2).
##
## `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-2, designed in
## `codetracer-specs/Sharing/Artifact-Store.md` §9.
##
## ## What this module is
##
## The executor for `artifact_transfer.nim`'s plan, and the **only** place in
## this repository that moves an artifact's bytes to or from the service.  It
## is kind-neutral throughout: it dispatches on the payload's *layout* (one
## blob, or a set of parts) and never on the artifact's kind, so a review
## dataset and a recording take the identical path and a third kind gets that
## path by existing rather than by being added here.
##
## That is the whole point of AS-1's migration and of this milestone.  The
## failure being avoided is two systems, the second of which is the one nobody
## maintains: before AS-1 the trace upload was a path of its own, and adding a
## second kind would have meant either masquerading as a trace or standing up a
## second transport.  `upload.nim` and `download.nim` are now thin: they choose
## *what* to store and what to do with what they got back, and this module is
## *how*.
##
## ## What "metadata carried alongside" means here, precisely
##
## The upload sends the artifact's metadata in the request bodies
## `artifact.nim` builds, and the download reads back whatever record the
## service returned (`parseDownloadedArtifact`).  For a kind with no legacy
## binding that is the metadata in full.  For the recording kind — whose bodies
## are frozen so already-uploaded traces keep working — it is what those frozen
## bodies have room for: the recording id, and the platform.  That limit is
## stated in `artifact.nim` beside the builders rather than glossed here.
##
## ## What this module deliberately does NOT do
##
## * **No encryption, no password protection.**  There is none on this path.
##   AS-3 builds it behind `ArtifactProtection`; nothing here should be read as
##   confidentiality from the service operator.
## * **No retention policy.**  How long a stored copy lives is a property of
##   the copy, not of the artifact (AS-1 §2.1), and it is not modelled.
## * **No streaming of a part's bytes.**  `file_transfer.putFile` reads a part
##   into memory; see the note on `storeArtifact` for why that bound is the
##   part rather than the payload, and `Artifact-Store.md` §8 defect 7 for what
##   is still open.

import std/[algorithm, json, options, os, strutils]

import artifact_transfer, api_client, file_transfer
export artifact_transfer

type
  ArtifactStoreOutcome* = object
    ## What a completed (or refused) store produced.
    ##
    ## Deliberately **not** one string field that means different things
    ## depending on which path ran.  `UploadedInfo.fileId` was exactly that —
    ## the recording id after a single-file upload and the upload-session id
    ## after a slice upload, with nothing telling the caller which
    ## (`Artifact-Store.md` §8 defect 11) — and a caller cannot use a value
    ## whose namespace it has to guess.  Here the artifact id and the session
    ## handle are separate fields of separate types, and the session's is empty
    ## unless a session was actually opened.
    artifact*: Artifact
      ## The artifact as stored, with `artifactId` set to what the service
      ## acknowledged.
    session*: ArtifactUploadSession
      ## The upload session, when the payload went up in parts.  `sessionId`
      ## is empty for a single-file transfer, because none was opened.
    serviceAcknowledgedId*: bool
      ## Whether the service **named the artifact back**, rather than the id in
      ## `artifact` being only what this machine calls it.
      ##
      ## This is not pedantry: for a sliced *recording* the answer is `false`,
      ## because that kind's frozen `…/upload-session` body carries no id, so
      ## the client never tells the service which recording the session is for
      ## and the service names the result itself.  A caller that built a share
      ## link out of the local id in that case would hand a user a link to
      ## something the service has never heard of.  So the flag exists, and
      ## `upload.nim` issues a link only when it is set.
    partsTransferred*: int
    bytesTransferred*: int64
    error*: string
      ## Empty iff the artifact is stored.

  ArtifactFetchOutcome* = object
    ## What a completed (or refused) fetch produced.
    reference*: ArtifactRef
      ## The collection that answered, and the id that was asked for.
    kind*: Option[ArtifactKind]
      ## The kind the service resolved the id to.  `none` only alongside a
      ## non-empty `error`: an artifact whose kind cannot be established is
      ## refused rather than downloaded and guessed at.
    record*: Artifact
    hasRecord*: bool
      ## Whether the service carried an artifact record alongside the URL.  A
      ## service deployed before AS-2 does not, which is not an error.
    localPath*: string
      ## Where the bytes landed.
    bytesTransferred*: int64
    error*: string

  ArtifactProgressProc* = proc (message: string) {.closure.}
    ## Optional narration for a long transfer.  `nil` means "say nothing":
    ## this module is a library before it is a command, so progress is the
    ## caller's choice rather than an unconditional `echo`.

proc note(onProgress: ArtifactProgressProc, message: string) =
  if not onProgress.isNil:
    onProgress(message)

proc storeArtifact*(client: var ApiClient, tenantId: string,
    artifact: Artifact, parts: seq[ArtifactPart], bearerToken: string,
    recordingMode: string = "",
    omniscientDbMode: string = "",
    totalEvents: int = 0,
    onProgress: ArtifactProgressProc = nil): ArtifactStoreOutcome =
  ## Store `artifact`'s `parts`, by artifact id, whatever kind it is.
  ##
  ## The layout decides the shape of the transfer and the kind decides nothing
  ## about it:
  ##
  ## * `aplSingleFile` — ask for a presigned URL, PUT the blob, confirm.
  ## * `aplSliceSet`   — open a session, then per part ask for a presigned URL
  ##   and PUT it, then finalize.
  ##
  ## Slice transfer is therefore available to *any* large artifact rather than
  ## being a trace-shaped chunking, which is the deliverable this procedure
  ## discharges.  A part's bytes are read into memory by `putFile`, so the
  ## memory bound is the largest **part**, not the payload — which is why a
  ## payload too large to hold at once has an answer (declare it as a slice
  ## set) even though the streaming PUT of §8 defect 7 is still open.
  ##
  ## Errors are returned, not raised, and nothing is uploaded before the plan
  ## validates: a description that does not hold together must not consume an
  ## upload slot, and on a slice set it must not consume the transfer either.
  let planned = planArtifactUpload(
    artifact, parts, client.baseApiUrl, tenantId,
    recordingMode = recordingMode,
    omniscientDbMode = omniscientDbMode,
    totalEvents = totalEvents)
  if planned.error.len > 0:
    return ArtifactStoreOutcome(error: planned.error)
  let plan = planned.plan
  result = ArtifactStoreOutcome(artifact: plan.artifact)

  try:
    case plan.artifact.payload.layout
    of aplSingleFile:
      let part = plan.parts[0]
      let issued = client.requestArtifactUploadUrl(
        tenantId, plan.artifact, part.name, bearerToken)
      let etag = putFile(issued.uploadUrl, part.localPath)
      # The service echoes the id it recorded.  For the recording kind that is
      # the `recordingId` it was sent, and the two are the same value by the
      # `aioSeededFromRecordingId` binding; taking the echo rather than the
      # local value is what makes a divergence visible instead of silent.
      if issued.acknowledgedArtifactId.len > 0:
        result.artifact.artifactId = issued.acknowledgedArtifactId
        result.serviceAcknowledgedId = true
        if result.artifact.kind == akRecording:
          result.artifact.metadata.recordingId = issued.acknowledgedArtifactId
      client.confirmArtifactUpload(
        artifactRef(result.artifact), etag, bearerToken)
      result.partsTransferred = 1
      result.bytesTransferred = part.byteSize
    of aplSliceSet:
      let opened = client.openArtifactUploadSession(
        tenantId, plan.artifact, plan.recordingMode, bearerToken)
      result.session = opened.session
      if opened.acknowledgedArtifactId.len > 0:
        result.artifact.artifactId = opened.acknowledgedArtifactId
        result.serviceAcknowledgedId = true
      note(onProgress, "Upload session created: " & opened.session.sessionId)
      for part in plan.parts:
        note(onProgress, "  Uploading part " & $(part.index + 1) & "/" &
          $plan.parts.len & ": " & part.name &
          " (" & $part.byteSize & " bytes)")
        let issued = client.requestArtifactPartUploadUrl(
          opened.session, part.index, part.name, part.byteSize, bearerToken)
        discard putFile(issued.uploadUrl, part.localPath)
        inc result.partsTransferred
        result.bytesTransferred += part.byteSize
      # `sliceCount`, not `parts.len`: the service reassembles from this
      # number and the sidecars are not pieces to reassemble.
      let acknowledged = client.finalizeArtifactUploadSession(
        opened.session, plan.artifact, sliceCount(plan.parts),
        plan.totalEvents, bearerToken, plan.omniscientDbMode)
      if acknowledged.len > 0:
        result.artifact.artifactId = acknowledged
        result.serviceAcknowledgedId = true
  except ApiError as e:
    # Re-raised rather than swallowed: `uploadSplitTrace` distinguishes "this
    # service does not implement the upload-session API" from every other
    # failure, and it can only do that if the status survives this layer.
    raise e
  except CatchableError as e:
    result.error = e.msg

proc fetchArtifact*(client: var ApiClient, artifactId: string,
    bearerToken: string, destinationPath: string,
    kindHint: Option[ArtifactKind] = none(ArtifactKind),
    onProgress: ArtifactProgressProc = nil): ArtifactFetchOutcome =
  ## Fetch the artifact named `artifactId` into `destinationPath`, whatever
  ## kind it is.
  ##
  ## The caller usually does **not** know the kind: a share link carries none
  ## (AS-1 §5.3, and `parseArtifactShareUrl` refuses to infer one from the
  ## URL's shape).  So this asks — the kind-neutral collection first, then the
  ## kind's alias, per `artifactDownloadCandidates` — and takes the kind from
  ## the answer.  It never guesses one: a service that resolves the id without
  ## saying what kind it resolved to is an error, because downloading bytes
  ## nothing can open is the failure the whole closed-kind design exists to
  ## prevent.
  ##
  ## Only a 404 or a 405 moves on to the next candidate.  A 401 or a 403 is
  ## *an answer* — "you may not ask" — and continuing past it would report a
  ## permission problem as a missing artifact.
  result = ArtifactFetchOutcome(kind: none(ArtifactKind))
  if artifactId.len == 0:
    result.error = "no artifact id to fetch"
    return

  var lastError = ""
  for candidate in artifactDownloadCandidates(artifactId, kindHint):
    var issued: ArtifactDownloadUrlResponse
    try:
      issued = client.requestArtifactDownloadUrl(candidate, bearerToken)
    except ApiError as e:
      # Whether a failure means "ask the next collection" is a rule, stated
      # once and asserted, not an inline pair of status codes — see
      # `downloadProbeMayContinue` for why the kind-neutral probe tolerates
      # more shapes than a kind's own collection does.
      if downloadProbeMayContinue(candidate, e.status):
        lastError = e.msg
        continue
      result.error = e.msg
      return
    except CatchableError as e:
      result.error = e.msg
      return

    result.reference = candidate
    # One source of truth for "what kind is this", and it fails closed: a
    # response this client cannot interpret ends the fetch rather than falling
    # through to a weaker reading of the same response.
    let resolved = resolveDownloadedKind(candidate, issued.body)
    if resolved.error.len > 0:
      result.error = resolved.error
      return
    result.kind = resolved.kind

    let parsedRecord = parseDownloadedArtifact(issued.body)
    if parsedRecord.error.len > 0:
      result.error = parsedRecord.error
      return
    if parsedRecord.artifact.artifactId.len > 0:
      result.record = parsedRecord.artifact
      result.hasRecord = true

    note(onProgress, "Downloading artifact " & artifactId &
      (if result.kind.isSome: " (" & kindSpec(result.kind.get).wireToken & ")"
       else: ""))
    try:
      downloadToFile(issued.downloadUrl, destinationPath)
    except CatchableError as e:
      result.error = e.msg
      return
    result.localPath = destinationPath
    if fileExists(destinationPath):
      result.bytesTransferred = getFileSize(destinationPath)
    return

  result.error = "no collection holds artifact '" & artifactId & "'" &
    (if lastError.len > 0: " — " & lastError else: "")

proc singleFilePart*(localPath: string): ArtifactPart =
  ## The one part of a single-file payload, described from the file itself.
  ## The name is the file's own rather than something derived, because the
  ## service keys the stored object on it.
  ArtifactPart(
    name: extractFilename(localPath),
    localPath: localPath,
    index: 0,
    byteSize: getFileSize(localPath))

proc collectSliceParts*(directory: string,
    sliceExtensions: openArray[string],
    sidecarExtensions: openArray[string] = []): seq[ArtifactPart] =
  ## Every file in `directory` whose extension is listed, as a slice-set
  ## payload: the slices first (in the order their extensions are given, then
  ## by name), then the sidecars that travel with them.
  ##
  ## The two lists are separate because the distinction survives onto the wire:
  ## only the slices are pieces of the payload, and only they are counted in
  ## the finalize body the service reassembles from (`ArtifactPartRole`).  A
  ## single list with a rule in the caller is how that count silently became a
  ## count of uploaded objects.
  ##
  ## Ordering is not cosmetic: a slice set is reassembled by index, so the
  ## index a part is given here is the position it will be read back at.
  ## Sorting by name within an extension is what makes `slice_0000.ct`,
  ## `slice_0001.ct`, … land in their recorded order, and putting the sidecars
  ## last is what keeps every slice's index below the slice count.
  ##
  ## The sort also makes the sidecars' own order **deterministic**, which the
  ## pre-AS-2 client's `walkDir` loop was not — it published them in whatever
  ## order the filesystem enumerated. That is a change, and an intentional one:
  ## it is not a regression because there was no order to regress from, and a
  ## reproducible upload is worth more than bug-compatibility with an
  ## unspecified one.
  result = @[]
  # Two passes rather than one over a merged list, so the ROLE cannot be
  # derived from the extension at the point of use — the two lists are what the
  # caller declared, and the slice/sidecar distinction is what the finalize
  # count depends on.
  for role in [aprSlice, aprSidecar]:
    let extensions =
      if role == aprSlice: @sliceExtensions else: @sidecarExtensions
    for extension in extensions:
      var matching: seq[string] = @[]
      for entry in walkDir(directory):
        if entry.kind == pcFile and entry.path.endsWith(extension):
          matching.add entry.path
      matching.sort()
      for path in matching:
        result.add ArtifactPart(
          name: extractFilename(path),
          localPath: path,
          index: result.len,
          byteSize: getFileSize(path),
          role: role)

proc observeLocalArtifact*(path: string): LocalArtifactEvidence =
  ## Look at `path` and report what is there.
  ##
  ## Observation only — the conclusion is `classifyArtifactEvidence`'s, which
  ## is pure and therefore assertable on both Nim backends.  The markers are
  ## the ones CodeTracer already recognises elsewhere: `review.json` for a
  ## dataset (`ct review`), a `.ct` container or `trace_metadata.json` for a
  ## materialized recording, and rr's `version` file for a native one (the same
  ## two shapes `ct review collect` surveys for).
  result = LocalArtifactEvidence(
    pathExists: fileExists(path) or dirExists(path),
    isDirectory: dirExists(path))
  if not result.isDirectory:
    # A bare file can still be a recording container.
    result.hasCtContainer = result.pathExists and path.endsWith(".ct")
    return
  for entry in walkDir(path):
    if entry.kind != pcFile:
      continue
    let name = extractFilename(entry.path)
    if name == "review.json":
      result.hasReviewDatasetJson = true
    elif name == "trace_metadata.json":
      result.hasTraceMetadata = true
    elif name == "version":
      result.hasRrVersionFile = true
    elif name.endsWith(".ct"):
      result.hasCtContainer = true

proc classifyLocalArtifact*(path: string, explicitKind: string = ""):
    tuple[kind: Option[ArtifactKind], error: string] =
  ## What kind of artifact is at `path`, or why that cannot be answered.
  ## Observation plus the pure decision; see `classifyArtifactEvidence`.
  classifyArtifactEvidence(path, observeLocalArtifact(path), explicitKind)
