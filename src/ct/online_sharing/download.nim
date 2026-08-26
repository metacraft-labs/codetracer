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
## Neither ``streams`` nor ``nimcrypto`` is imported here, and the absence of
## the second one is deliberate rather than incidental: nothing on the sharing
## path encrypts anything, and an unused ``nimcrypto`` import made this file
## read as "there is crypto here" to anyone grepping for it.  If confidentiality
## is ever added, it belongs behind the artifact model's ``ArtifactProtection``
## seam (``artifact.nim``), not behind an import.
import std/[ terminal, options, strutils, strformat, os ]
import ../../common/[ config, trace_index, paths, lang, types ]
import ../utilities/[ types, zip, language_detection ]
import ../trace/storage_and_import, ../globals
import remote_config, api_client, artifact_store, collab_native_session,
  tenant_resolver

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
    error*: string

proc downloadArtifact*(url: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string),
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
    artifactId, bearerToken, archivePath, onProgress = onProgress)
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
    hasRecord: fetched.hasRecord)

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
    baseUrl: Option[string] = none(string)): string =
  ## Download a recording and import it, returning the local recording id.
  ##
  ## Kept as the recording-shaped entry point for callers that want a
  ## recording and nothing else; it refuses when the link names some other
  ## kind rather than unpacking it in the wrong place.
  let downloaded = downloadArtifact(url, token, baseUrl)
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

proc downloadTraceCommand*(traceDownloadUrl: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)) =
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

    let downloaded = downloadArtifact(traceDownloadUrl, token, baseUrl)
    if downloaded.error.len > 0:
      echo downloaded.error
      quit(1)

    case downloaded.kind
    of akRecording:
      let recordingId = importDownloadedRecording(
        downloaded, traceDownloadUrl)
      if isatty(stdout):
        echo fmt"OK: downloaded with recording id {recordingId}"
      else:
        # being parsed by `ct` index code
        echo recordingId
    of akReviewDataset:
      let datasetDir = unpackDownloadedReviewDataset(downloaded)
      if isatty(stdout):
        echo "OK: downloaded review dataset " & downloaded.artifactId
        echo "Open it with: ct review " & datasetDir
      else:
        echo datasetDir

  except CatchableError as e:
    echo fmt"error: downloading file '{e.msg}'"
    quit(1)
