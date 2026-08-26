## `ct download` — open a shared artifact from its link.
##
## AS-2 (`codetracer-specs/Sharing/Artifact-Store.milestones.org`): this is the
## **kind-neutral half of the CLI surface**, and it is kind-neutral because it
## can be.  A share link is `/{orgSlug}/{artifactId}/download` and carries no
## kind (AS-1 §5.3 — the property that let every link already handed to a user
## survive the generalisation), so the command cannot be told what it is about
## to fetch and must not guess.  It asks the store, and the store answers; only
## then does anything kind-specific happen, in one `case` at the very end.
##
## AS-3 adds a second axis this command deliberately does **not** branch on:
## whether the payload was encrypted.  ``artifact_store.fetchArtifact`` decides
## that from the downloaded bytes' own magic — not from anything the service
## said — and hands back plaintext either way, so everything below sees a
## payload and not a decision.  That is why encryption did not have to be
## written once per kind here.
##
## Neither ``streams`` nor ``nimcrypto`` is imported here, and the second
## absence is still deliberate: the cryptography lives in
## ``artifact_crypto.nim``, reached through the store, and an import here would
## once again make this file read as the place where it happens.
import std/[ terminal, options, strutils, strformat, os ]
import ../../common/[ config, trace_index, paths, lang, types ]
import ../utilities/[ types, zip, language_detection ]
import ../trace/storage_and_import, ../globals
import remote_config, api_client, artifact_store, artifact_sharing,
  collab_native_session, tenant_resolver

# M-REC-8: the previous private ``parseDownloadUrl`` helper moved to
# ``api_client.parseDownloadShareUrl`` so the M-REC-8 wire-format tests
# can pin the URL grammar without dragging the full download stack into
# the test binary.  The C# ``PageRoutes.Organization.Replay.Download.Deconstruct``
# route template ``/{orgSlug}/{recordingId}/download`` is the reference
# shape.

type
  DownloadedArtifact* = object
    ## What a completed `ct download` produced, before anything kind-specific
    ## is done with it.
    kind*: ArtifactKind
    artifactId*: string
    archivePath*: string
      ## The downloaded archive on disk.  The caller unpacks it where the kind
      ## belongs.
    record*: Artifact
    hasRecord*: bool
      ## Whether the service carried the artifact record — and therefore the
      ## metadata — alongside the download URL.  A service deployed before AS-2
      ## does not, which is not an error.
    protection*: ArtifactProtection
      ## What the downloaded bytes actually carried, read from the bytes rather
      ## than from the record (AS-3).
    wasDecrypted*: bool
      ## Whether `archivePath` had to be decrypted to get here.  `false` for
      ## every artifact stored before AS-3, which is what "an old-format
      ## artifact still downloads" means concretely: no envelope, no prompt,
      ## nothing on this path runs at all.
    sealedForArtifactId*: string
      ## The artifact id the opened envelope named, when there was one.
      ##
      ## **AS-4 carries this the last step.**  AS-3 computed it, reported it on
      ## `ArtifactFetchOutcome` — and it stopped there: nothing propagated it
      ## and nothing printed it, so §8 defect 18's residual (a service serving
      ## artifact B for a link to A, which opens if the password was reused)
      ## was invisible to the one person able to notice it.  `ct download` now
      ## says so when it differs from the id that was asked for.  It is still
      ## *reported* rather than enforced: enforcing it would make an encrypted
      ## sliced recording unopenable through its own share link (§10.3).
    error*: string

proc downloadArtifact*(url: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string),
    secret: string = "",
    onProgress: ArtifactProgressProc = nil): DownloadedArtifact =
  ## Fetch whatever artifact `url` names, by id, without knowing its kind.
  ##
  ## The kind comes back from the store (`artifact_store.fetchArtifact`), which
  ## takes it from what the service said or from which collection answered, and
  ## refuses rather than assuming when neither settles it.
  let remoteConf = initRemoteConfig()
  let bearerToken = remoteConf.getBearerToken(token.get(""))
  let resolvedBaseUrl = remoteConf.resolveBaseRemoteUrl(baseUrl.get(""))

  var client = initApiClient(resolvedBaseUrl)
  defer: client.close()

  var orgSlug, artifactId: string
  try:
    let parsed = parseArtifactShareUrl(url)
    orgSlug = parsed.orgSlug
    artifactId = parsed.artifactId
  except ValueError as e:
    return DownloadedArtifact(error: "error: " & e.msg)
  if artifactId.len == 0 or orgSlug.len == 0:
    return DownloadedArtifact(error: "error: invalid share link: " & url)

  # Validate the user has access to this organization's tenant.
  discard resolveTenantId(client, orgSlug, bearerToken)

  let archivePath = codetracerTmpPath /
    fmt"downloaded-artifact-{artifactId}.zip"
  let fetched = client.fetchArtifact(
    artifactId, bearerToken, archivePath,
    secret = secret, onProgress = onProgress)
  if fetched.error.len > 0:
    return DownloadedArtifact(error: "error: " & fetched.error)
  if fetched.kind.isNone:
    # Unreachable through `fetchArtifact`, which pairs a `none` kind with an
    # error.  Diagnosed rather than defaulted so a future change that breaks
    # that pairing fails loudly instead of downloading bytes as a recording.
    return DownloadedArtifact(error:
      "error: the service did not say what kind of artifact '" & artifactId &
      "' is, so CodeTracer will not guess.")

  DownloadedArtifact(
    kind: fetched.kind.get,
    artifactId: artifactId,
    archivePath: archivePath,
    record: fetched.record,
    hasRecord: fetched.hasRecord,
    protection: fetched.protection,
    wasDecrypted: fetched.wasDecrypted,
    sealedForArtifactId: fetched.sealedForArtifactId)

proc importDownloadedRecording(downloaded: DownloadedArtifact,
    sourceUrl: string): string =
  ## Unpack a downloaded recording into the local trace directory and return
  ## the UUIDv7 ``recording_id`` of the imported copy.
  ##
  ## M-REC-8: a fresh local UUIDv7 is minted here to name the on-disk
  ## landing folder.  This is intentional: the identifier embedded in the
  ## link is the *uploader's* recording id; the *downloader* treats the
  ## download as the start of a new local recording row in its own
  ## ``trace_index.db``.  A follow-up may align the two ids so
  ## ``preserve-on-import`` behaviour matches §8's "Imported traces" note in
  ## the parent spec, but for now we keep the existing mint-on-import
  ## behaviour.
  let recordingId = trace_index.newID(false)

  # M-REC-7: downloads land at ``<traces>/<recording_id>/`` — the bare
  # UUIDv7 — to match the on-disk layout for locally recorded traces.
  let unzippedLocation = paths.recordingFolder(codetracerTraceDir, recordingId)
  unzipIntoFolder(downloaded.archivePath, unzippedLocation)
  removeFile(downloaded.archivePath)

  # Materialized traces are CTFS-only: the downloaded zip must contain a
  # `.ct` container (legacy JSON sidecar bundles are no longer accepted;
  # see M-REC-1.5).
  var ctPath = ""
  for entry in walkDir(unzippedLocation):
    if entry.kind == pcFile and entry.path.endsWith(".ct"):
      ctPath = entry.path
      break

  if ctPath.len == 0:
    echo "error: downloaded archive contains no `.ct` CTFS container; "
    echo "  legacy 3-file materialized bundles are no longer accepted "
    echo "  (see codetracer-specs/Trace-Files/CTFS-Migration-Guide.md)."
    quit(1)

  # Best-effort language detection from the program name embedded in the
  # `.ct` filename. Recorders typically name the container after the
  # recorded program (e.g. `my_app.ct`).
  #
  # AS-2: when the service carried the artifact's metadata, the recorded
  # language it states is preferred over the filename guess — that is the read
  # half of "metadata carried alongside", used rather than merely stored.
  let programFilename = ctPath.extractFilename.changeFileExt("")
  let isWasm = programFilename.endsWith(".wasm")
  var lang = detectLang(programFilename, LangUnknown, isWasm)
  if downloaded.hasRecord and downloaded.record.kind == akRecording and
      downloaded.record.metadata.langName.len > 0:
    # `langName` is `$Lang` as the uploader wrote it (`LangNoir`, `LangRuby`,
    # …).  An unparseable value is ignored rather than fatal: a wrong guess at
    # the language costs a syntax-highlighting mode, and refusing an otherwise
    # complete download over it would be the wrong trade.
    try:
      lang = parseEnum[Lang](downloaded.record.metadata.langName)
    except ValueError:
      discard
  let recordPid = NO_PID # pid is recoverable from the CTFS metadata block.
  discard importTrace(unzippedLocation, recordingId, recordPid, lang,
    DB_SELF_CONTAINED_DEFAULT, sourceUrl)
  recordingId

proc downloadTrace*(url: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string),
    secret: string = ""): string =
  ## Download a recording and import it, returning the local recording id.
  ##
  ## Kept as the recording-shaped entry point for callers that want a
  ## recording and nothing else; it refuses when the link names some other
  ## kind rather than unpacking it in the wrong place.
  let downloaded = downloadArtifact(url, token, baseUrl, secret)
  if downloaded.error.len > 0:
    echo downloaded.error
    quit(1)
  if downloaded.kind != akRecording:
    echo "error: '" & url & "' names a " &
      kindSpec(downloaded.kind).wireToken & ", not a recording."
    quit(1)
  importDownloadedRecording(downloaded, url)

proc unpackDownloadedReviewDataset(downloaded: DownloadedArtifact): string =
  ## Unpack a downloaded review dataset and return the directory holding it.
  let destination = paths.reviewDatasetFolder(
    codetracerTraceDir, downloaded.artifactId)
  unzipIntoFolder(downloaded.archivePath, destination)
  removeFile(downloaded.archivePath)
  destination

proc receivedArtifact(downloaded: DownloadedArtifact): Artifact =
  ## The artifact record AS-4's "received" view is rendered from.
  ##
  ## The service's record when it carried one, and a prospective artifact of
  ## the resolved kind when it did not (every deployment today).  Two facts are
  ## taken from **this machine** rather than from the record in either case:
  ##
  ## * the id, which is the id the link named and the one that was asked for —
  ##   the record's is something the service says;
  ## * the protection, which is read from the downloaded bytes' own magic
  ##   (`protectionOfPayload`) and not from an access record the service
  ##   controls.  A record claiming `none` for an envelope, or the reverse, must
  ##   not change what the user is told about what they just opened.
  if downloaded.hasRecord:
    result = downloaded.record
  else:
    result = prospectiveArtifact(downloaded.kind, initArtifactAccess(""))
  result.artifactId = downloaded.artifactId
  result.access.protection = downloaded.protection

proc downloadTraceCommand*(traceDownloadUrl: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string),
    passwordStdin: bool = false,
    passwordFile: Option[string] = none(string)) =
  ## `ct download <LINK>`.
  ##
  ## Kind-neutral until the last step: fetch by id, then do the one thing the
  ## resolved kind calls for.  The `case` is exhaustive, so a kind added to the
  ## registry without an answer to "what does `ct download` do with it" is a
  ## compile error rather than an artifact that lands somewhere arbitrary.
  try:
    var inviteBaseUrl = ""
    var inviteToken = ""
    try:
      let invite = parseCollabInviteUrl(traceDownloadUrl)
      inviteBaseUrl = invite.baseUrl
      inviteToken = invite.inviteToken
    except ValueError:
      discard

    if inviteToken.len > 0:
      var client = initApiClient(baseUrl.get(inviteBaseUrl))
      defer: client.close()
      let bootstrap = client.exchangeCollabInvite(inviteToken)
      let runtime = startNativeCollabRuntime(NativeCollabBootstrap(
        replayId: bootstrap.replayId,
        traceId: bootstrap.traceId,
        traceIdentity: bootstrap.traceIdentity,
        roomId: bootstrap.roomId,
        initialGrants: bootstrap.initialGrants,
        webUiUrl: bootstrap.webUiUrl,
        nativeJoinUrl: bootstrap.nativeJoinUrl,
        rendezvousUrl: bootstrap.rendezvousUrl,
        transportHints: bootstrap.transportHints))
      if not runtime.isActive:
        raise newException(ValueError,
          "collaboration invite did not start an active native session")
      echo fmt"OK: joined collaboration room {runtime.activeSession.roomId} " &
        fmt"via {runtime.transport.kind}"
      return

    # AS-3.  The password is read up front when one was named, and NOT asked
    # for otherwise: whether this artifact is encrypted is something only the
    # downloaded bytes can say, so prompting before the fetch would ask every
    # user for a password most artifacts do not have.  When it turns out one is
    # needed and none was given, `fetchArtifact` says so by name and says that
    # CodeTracer cannot recover it.
    let source = secretSource(
      passwordStdin, passwordFile.get(""), bareDashInArgv())
    if source.error.len > 0:
      echo "error: " & source.error
      quit(1)
    var secret = ""
    if source.path.len > 0:
      let supplied = readSecretFromFile(source.path)
      if supplied.error.len > 0:
        echo "error: " & supplied.error
        quit(1)
      secret = supplied.secret

    let downloaded = downloadArtifact(
      traceDownloadUrl, token, baseUrl, secret)
    if downloaded.error.len > 0:
      echo downloaded.error
      quit(1)

    # The ONE per-kind step: put the bytes where that kind belongs, and say
    # what names the local copy.  Exhaustive, so a kind added to the registry
    # without an answer to "what does `ct download` do with it" is a compile
    # error rather than an artifact that lands somewhere arbitrary.
    #
    # AS-4: it no longer decides what the user is *told*.  Both arms used to
    # print their own success message — "OK: downloaded with recording id X"
    # against "OK: downloaded review dataset X / Open it with: ct review DIR" —
    # which is the same two-flows-that-resemble-each-other shape `ct upload`
    # had.  Now the arm produces a locator and the one sharing view is
    # rendered from the artifact model below.
    let locator =
      case downloaded.kind
      of akRecording:
        importDownloadedRecording(downloaded, traceDownloadUrl)
      of akReviewDataset:
        unpackDownloadedReviewDataset(downloaded)

    # `accessKnown = downloaded.hasRecord`: no deployed service returns an
    # artifact record (§9.4), so without this the view would print the model's
    # DEFAULT visibility as though it were this artifact's — telling a user
    # that "members of the owning organisation" can open something whose owner
    # the client was never told. A fabricated fact is worse than an absent one
    # (§8 defect 4, in another form).
    let received = sharingView(
      receivedArtifact(downloaded), assReceived, locator = locator,
      sealedForArtifactId = downloaded.sealedForArtifactId,
      accessKnown = downloaded.hasRecord)
    if isatty(stdout):
      echo renderSharingView(received)
    else:
      # The SAME view a human is shown, machine-readable, on **stderr** — which
      # is where it has to go: the Electron download handler takes the WHOLE of
      # stdout, stripped, as the imported recording id, so stdout carries the
      # locator and nothing else.  `ct upload`'s non-interactive branch puts its
      # view on stdout because its consumer scans back for the last non-empty
      # line; the two contracts differ and this is the one that cannot.
      #
      # It is emitted for the same reason `ct upload` emits one: a script that
      # only sees a path is not told whether the payload was encrypted, who can
      # read it, or that the service served a different artifact than the link
      # asked for.  That last is the whole of §8 defect 18's defence.
      stderr.writeLine sharingViewJsonLine(received)
      # The notices are ALSO written as plain lines, because a human reading a
      # piped run's stderr should not have to parse JSON to be warned.  They
      # must still be said: the cross-artifact
      # substitution notice is the only thing standing between a user and a
      # payload the service swapped (§10.3).
      for notice in received.notices & received.kindApiNotices:
        stderr.writeLine notice
      echo locator

  except CatchableError as e:
    echo fmt"error: downloading file '{e.msg}'"
    quit(1)
