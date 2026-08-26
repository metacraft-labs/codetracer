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
## ## "Executor" was an overstatement until AS-3, and now it is not
##
## AS-2's design note called this module "the executor for
## `artifact_transfer.nim`'s plan".  It was not.  It called `planArtifactUpload`
## for its *validation* and then re-derived the same conversation itself, one
## `api_client` call at a time, while `uploadOpenStep` / `uploadPartSteps` /
## `uploadCompletionStep` were consumed only by the test suite.  Two
## implementations of one conversation, agreeing by convention — and the
## measurement that proves it was that mutating the planner to stop publishing
## sidecars left the whole round-trip suite green.
##
## AS-3 makes the coupling real, and it does so **before** adding encryption
## rather than after, because encryption belongs on the transfer path: with two
## implementations it would have had to be written into both, and the one that
## drifted would be the one that silently shipped plaintext.  `storeArtifact`
## now obtains the steps from the planner and sends them; `api_client.nim`'s
## senders take a step and no longer build a URL or a body at all.  The same
## mutation is now red, on the socket, in `artifact_store_roundtrip_test.nim`.
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
## ## Encryption, and exactly where it happens (AS-3)
##
## When an artifact declares a protection other than `apNone`, this module
## seals each part's bytes between reading them from disk and handing them to
## the PUT — and nothing else about the conversation changes.  Two consequences
## are worth stating rather than leaving to be discovered:
##
## * **the secret is a parameter of this procedure and of nothing that talks to
##   the service.**  `api_client.nim` has no parameter it could put a password
##   in and no field that could carry one; the key exists only inside an
##   `ArtifactSeal` here, and is wiped when the upload ends.
## * **the sizes on the wire are the sealed sizes.**  They are computed before
##   planning, from the same header-producing function the sealing uses, so the
##   content length the service is told is the content length it receives.
##
## ## What this module deliberately does NOT do
##
## * **No confidentiality for the metadata.**  The payload is encrypted; the
##   artifact's metadata rides the request bodies in the clear.  That is stated
##   rather than glossed: `artifact.serviceVisibleMetadataFields` is the exact
##   per-kind list, and `artifact_store_roundtrip_test.nim` asserts the keys
##   that actually cross the socket against it.
## * **No retention policy.**  How long a stored copy lives is a property of
##   the copy, not of the artifact (AS-1 §2.1), and it is not modelled.
## * **No streaming of a part's bytes.**  `file_transfer.putBytes` holds a part
##   in memory; see the note on `storeArtifact` for why that bound is the
##   part rather than the payload, and `Artifact-Store.md` §8 defect 7 for what
##   is still open.

import std/[algorithm, json, options, os, strutils]

import artifact_transfer, artifact_crypto, api_client, file_transfer
export artifact_transfer, artifact_crypto

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
      ## Bytes actually sent, which for a protected artifact is the sealed
      ## size — envelope headers and authentication tags included.
    protection*: ArtifactProtection
      ## What was applied to the payload before it left this machine.  A field
      ## rather than something to re-read off `artifact.access`, because the
      ## caller's next act is usually to tell the user what happened, and "what
      ## the record says" and "what was done" must be the same fact here or the
      ## message is a guess.
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
      ## Where the bytes landed — **plaintext**, when the payload was
      ## encrypted and the secret opened it.  A caller unpacks this without
      ## knowing whether anything was encrypted, which is what makes
      ## `download.nim` kind-neutral *and* protection-neutral.
    protection*: ArtifactProtection
      ## What the downloaded bytes actually carried, read from the bytes
      ## themselves rather than from the record — see `protectionOfPayload`.
    wasDecrypted*: bool
      ## Whether this fetch had to open an envelope.  Reported so a caller can
      ## say so, and so a test can assert that an old-format artifact took the
      ## path that does nothing.
    sealedForArtifactId*: string
      ## The artifact id the envelope names, when there was one.
      ##
      ## **Reported, not enforced against the id that was asked for** — see
      ## `openArtifactPayload` for why that check cannot hold on the sliced
      ## recording path, and `Artifact-Store.md` §8 defect 18 for what the
      ## residual is. A caller that DOES know the id it minted can compare.
    bytesTransferred*: int64
      ## Bytes received from the object store, before any decryption.
    error*: string

  ArtifactProgressProc* = proc (message: string) {.closure.}
    ## Optional narration for a long transfer.  `nil` means "say nothing":
    ## this module is a library before it is a command, so progress is the
    ## caller's choice rather than an unconditional `echo`.

proc note(onProgress: ArtifactProgressProc, message: string) =
  if not onProgress.isNil:
    onProgress(message)

proc prepareProtectedPayload(artifact: var Artifact,
    parts: var seq[ArtifactPart], secret: string):
    tuple[seal: ArtifactSeal, error: string] =
  ## Turn an artifact the caller wants protected into one whose descriptor
  ## already describes the *sealed* bytes.
  ##
  ## Three things move, and all three have to move together or the client
  ## tells the service something untrue about what it is sending:
  ##
  ## * each part's `byteSize` becomes the sealed size, computed from the same
  ##   header the sealing will use rather than estimated;
  ## * each part's `protection` records what will happen to it, which is what
  ##   `planArtifactUpload` checks against the artifact's own declaration;
  ## * the payload's `contentType` becomes the envelope media type, because the
  ##   bytes really are an envelope and `application/zip` would be a false
  ##   statement about them.
  ##
  ## Done here, before planning, rather than inside the PUT loop: the plan is
  ## validated against these numbers, and a plan validated against plaintext
  ## sizes would be a plan that passes and then sends more bytes than it
  ## promised.
  let spec = protectionSpec(artifact.access.protection)
  if not spec.encryptsPayload:
    return (ArtifactSeal(), "protection '" & $artifact.access.protection &
      "' does not encrypt a payload, so there is nothing to prepare")
  # `sliceCount(parts)`, not `parts.len`: the reassembled payload is the SLICES
  # (§9.1's `ArtifactPartRole`), and the download has to be able to tell a
  # complete reassembly from a short one.  Sending the object count here would
  # make every sliced recording download report itself incomplete by exactly
  # the number of manifests it carries.
  let sealed = newArtifactSeal(secret, artifact.artifactId,
    kindSpec(artifact.kind).wireToken, sliceCount(parts))
  if sealed.error.len > 0:
    return (ArtifactSeal(), sealed.error)

  var total: int64 = 0
  for i in 0 ..< parts.len:
    parts[i].byteSize = sealedPartSize(sealed.seal, parts[i].index,
      parts.len, parts[i].name, parts[i].byteSize)
    parts[i].protection = artifact.access.protection
    total += parts[i].byteSize
  artifact.payload.byteSize = total
  artifact.payload.contentType = ArtifactEnvelopeContentType
  (sealed.seal, "")

proc partBytesToSend(seal: ArtifactSeal, part: ArtifactPart,
    partCount: int): tuple[bytes: string, error: string] =
  ## The bytes for one `atsPutPart` step: the file, sealed if the part says so.
  ##
  ## The declared length is re-checked against the produced length.  That is
  ## not defensive padding: the length was computed before the seal existed, an
  ## `S3` presigned PUT is rejected outright if `Content-Length` disagrees with
  ## the body, and a mismatch here means the two spellings of the header have
  ## drifted — which is the exact failure `sealedPartSize` exists to prevent
  ## and therefore the exact thing worth asserting.
  var plaintext: string
  try:
    plaintext = readFile(part.localPath)
  except CatchableError as e:
    return ("", "could not read payload part '" & part.name & "': " & e.msg)
  if part.protection == apNone:
    return (plaintext, "")
  let sealed = sealArtifactPart(
    seal, part.index, partCount, part.name, plaintext)
  if sealed.error.len > 0:
    return ("", sealed.error)
  if sealed.frame.len.int64 != part.byteSize:
    return ("", "internal error: payload part '" & part.name &
      "' was declared as " & $part.byteSize & " bytes and sealed to " &
      $sealed.frame.len)
  (sealed.frame, "")

proc storeArtifact*(client: var ApiClient, tenantId: string,
    artifact: Artifact, parts: seq[ArtifactPart], bearerToken: string,
    recordingMode: string = "",
    omniscientDbMode: string = "",
    totalEvents: int = 0,
    secret: string = "",
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
  ## discharges.  A part's bytes are held in memory by `putBytes`, so the
  ## memory bound is the largest **part**, not the payload — which is why a
  ## payload too large to hold at once has an answer (declare it as a slice
  ## set) even though the streaming PUT of §8 defect 7 is still open.  A
  ## protected part is held twice over for the moment it is sealed, plaintext
  ## and ciphertext, which raises that bound by a factor of two and no more.
  ##
  ## Errors are returned, not raised, and nothing is uploaded before the plan
  ## validates: a description that does not hold together must not consume an
  ## upload slot, and on a slice set it must not consume the transfer either.
  ##
  ## `secret` is the password for a protected artifact and must be empty for an
  ## unprotected one.  **Both mismatches are refusals**, and the second is the
  ## one worth spelling out: a caller that supplied a password but left the
  ## artifact's protection at `apNone` believes it is encrypting, and quietly
  ## uploading the payload in the clear is the worst outcome this milestone can
  ## produce.  So it does not happen — the upload stops before a byte moves.
  var prepared = artifact
  var preparedParts = parts
  var seal = ArtifactSeal()
  let requiresSecret = protectionRequiresSecret(prepared.access.protection)

  if requiresSecret and secret.len == 0:
    return ArtifactStoreOutcome(error:
      "artifact declares protection '" & $prepared.access.protection &
      "' but no password was supplied")
  if not requiresSecret and secret.len > 0:
    return ArtifactStoreOutcome(error:
      "a password was supplied but the artifact declares protection '" &
      $prepared.access.protection &
      "', which would upload the payload unencrypted; refusing")

  if requiresSecret:
    note(onProgress, "Encrypting on this computer before upload " &
      "(the password is never sent).")
    let readied = prepareProtectedPayload(prepared, preparedParts, secret)
    if readied.error.len > 0:
      return ArtifactStoreOutcome(error: readied.error)
    seal = readied.seal
  defer: wipe(seal)

  let planned = planArtifactUpload(
    prepared, preparedParts, client.baseApiUrl, tenantId,
    recordingMode = recordingMode,
    omniscientDbMode = omniscientDbMode,
    totalEvents = totalEvents)
  if planned.error.len > 0:
    return ArtifactStoreOutcome(error: planned.error)
  let plan = planned.plan
  result = ArtifactStoreOutcome(
    artifact: plan.artifact, protection: plan.artifact.access.protection)

  try:
    # THE PLAN IS THE CONVERSATION.  Every request below is a step
    # `artifact_transfer.nim` produced; nothing here builds a URL or a body.
    # Before AS-3 this loop re-derived them, which made the planner a parallel
    # description that only the tests read — see the module comment.
    let openStep = uploadOpenStep(plan)
    case plan.artifact.payload.layout
    of aplSingleFile:
      let issued = client.requestArtifactUploadUrl(openStep, bearerToken)
      # The service echoes the id it recorded.  For the recording kind that is
      # the `recordingId` it was sent, and the two are the same value by the
      # `aioSeededFromRecordingId` binding; taking the echo rather than the
      # local value is what makes a divergence visible instead of silent.
      if issued.acknowledgedArtifactId.len > 0:
        result.artifact.artifactId = issued.acknowledgedArtifactId
        result.serviceAcknowledgedId = true
        if result.artifact.kind == akRecording:
          result.artifact.metadata.recordingId = issued.acknowledgedArtifactId

      let putSteps = uploadPartSteps(plan, ArtifactUploadSession())
      var etag = ""
      for step in putSteps:
        let payload = partBytesToSend(seal, step.part, plan.parts.len)
        if payload.error.len > 0:
          result.error = payload.error
          return
        etag = putBytes(issued.uploadUrl, payload.bytes)
        inc result.partsTransferred
        result.bytesTransferred += step.part.byteSize

      # The confirmation is a planned step too, built with the ETag the object
      # store has just issued — which is why `uploadCompletionStep` takes one.
      # It is addressed to the id the SERVICE named, not the local one, which
      # is why the plan is re-addressed rather than reused as-is.
      client.confirmArtifactUpload(
        uploadCompletionStep(
          plan.addressedTo(result.artifact), ArtifactUploadSession(), etag),
        bearerToken)
    of aplSliceSet:
      let opened = client.openArtifactUploadSession(
        openStep, plan.artifact.kind, bearerToken)
      result.session = opened.session
      if opened.acknowledgedArtifactId.len > 0:
        result.artifact.artifactId = opened.acknowledgedArtifactId
        result.serviceAcknowledgedId = true
      note(onProgress, "Upload session created: " & opened.session.sessionId)

      let partSteps = uploadPartSteps(plan, opened.session)
      var issuedUrl = ""
      for step in partSteps:
        case step.kind
        of atsRequestPartUploadUrl:
          note(onProgress, "  Uploading part " & $(step.part.index + 1) &
            "/" & $plan.parts.len & ": " & step.part.name &
            " (" & $step.part.byteSize & " bytes)")
          issuedUrl = client.requestArtifactPartUploadUrl(
            step, bearerToken).uploadUrl
        of atsPutPart:
          let payload = partBytesToSend(seal, step.part, plan.parts.len)
          if payload.error.len > 0:
            result.error = payload.error
            return
          discard putBytes(issuedUrl, payload.bytes)
          inc result.partsTransferred
          result.bytesTransferred += step.part.byteSize
        else:
          result.error = "artifact transfer: unexpected '" & $step.kind &
            "' step in the body of a sliced upload"
          return

      # `sliceCount`, not `parts.len`: the service reassembles from this
      # number and the sidecars are not pieces to reassemble.  That decision
      # lives in `uploadCompletionStep`, once, rather than here.
      let acknowledged = client.finalizeArtifactUploadSession(
        uploadCompletionStep(plan, opened.session), bearerToken)
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

proc openDownloadedPayload(path, secret, artifactId: string,
    onProgress: ArtifactProgressProc):
    tuple[protection: ArtifactProtection, decrypted: bool,
      sealedForArtifactId: string, error: string] =
  ## Decrypt `path` in place if it holds an envelope; otherwise leave it alone.
  ##
  ## **The bytes decide, not the record.**  A service deployed before AS-3
  ## returns no artifact record at all, and a record — when there is one — is
  ## something the service says.  So this looks at the file's own magic
  ## (`protectionOfPayload`), which is also what makes an old-format artifact
  ## download unchanged: no magic, nothing happens, not even a prompt.
  var downloaded: string
  try:
    downloaded = readFile(path)
  except CatchableError as e:
    return (apNone, false, "",
      "could not read the downloaded payload: " & e.msg)

  let carried = protectionOfPayload(downloaded)
  if carried == apNone:
    return (apNone, false, "", "")

  if secret.len == 0:
    # The flag names here must be flags that EXIST.  An earlier draft named
    # `ct download --password`, which does not — a user following the message
    # got a parse error.  `src/tests/cli/sharing_cli_surface_test.nim` now
    # drives the built binary's help and refuses any `--flag` this directory's
    # messages mention that the CLI does not accept.
    return (carried, false, "",
      "artifact '" & artifactId & "' is encrypted. Supply the password it " &
      "was encrypted with (`ct download --password-stdin`, or " &
      "`--password-file <PATH>`).\n" &
      "  CodeTracer cannot recover it: the password is never sent anywhere " &
      "and no copy of the key is kept.")

  note(onProgress, "Decrypting on this computer.")
  # `openArtifactPayload`, NOT `openArtifactPart`.  What `…/download-url` hands
  # back for a sliced artifact is the payload the service REASSEMBLED — one
  # frame per slice, end to end — and the recording kind's normal shape is the
  # sliced one.  Reading that as a single frame produced "the stored bytes have
  # been altered since they were uploaded" for an artifact nobody had touched.
  # A single-file artifact is the one-frame case of the same walk, so there is
  # one path here rather than a branch on layout.
  #
  # The envelope's own artifact id is REPORTED, not enforced, and
  # `openArtifactPayload` says why at length: the sealing happens before the
  # upload, so the envelope carries the id the client knows, and for a sliced
  # recording the service may name the artifact something else (§9.5).
  # Refusing on the mismatch would make an encrypted sliced recording
  # unopenable through its own share link.
  let opened = openArtifactPayload(secret, downloaded)
  if opened.error.len > 0:
    # The ciphertext stays on disk only if it can be removed; leaving an
    # unopenable file where a caller expects a payload has caused a
    # "downloaded archive contains no .ct container" further up before.
    try: removeFile(path) except CatchableError: discard
    return (carried, false, "", opened.error)
  try:
    writeFile(path, opened.plaintext)
  except CatchableError as e:
    return (carried, false, "",
      "could not write the decrypted payload: " & e.msg)
  (carried, true, opened.header.envelope.artifactId, "")

proc fetchArtifact*(client: var ApiClient, artifactId: string,
    bearerToken: string, destinationPath: string,
    kindHint: Option[ArtifactKind] = none(ArtifactKind),
    secret: string = "",
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
    if fileExists(destinationPath):
      result.bytesTransferred = getFileSize(destinationPath)

    # Decryption is the last step of the fetch rather than the caller's job, so
    # every consumer of `localPath` — `ct download`, the Electron handler, a
    # future listing preview — gets plaintext without knowing whether there was
    # anything to decrypt.  That is what makes protection, like kind, something
    # the callers above do not branch on.
    let opened = openDownloadedPayload(
      destinationPath, secret, artifactId, onProgress)
    result.protection = opened.protection
    result.wasDecrypted = opened.decrypted
    result.sealedForArtifactId = opened.sealedForArtifactId
    if opened.error.len > 0:
      result.error = opened.error
      return
    result.localPath = destinationPath
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
