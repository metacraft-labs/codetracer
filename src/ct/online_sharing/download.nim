import streams, nimcrypto, std/[ terminal, options, strutils, strformat, os, httpclient, uri, net, json ]
import ../../common/[ config, trace_index, paths, lang, types ]
import ../utilities/[ types, zip, language_detection ]
import ../trace/storage_and_import, ../globals
import remote_config, api_client, collab_native_session, file_transfer as ft, tenant_resolver

# M-REC-8: the previous private ``parseDownloadUrl`` helper moved to
# ``api_client.parseDownloadShareUrl`` so the M-REC-8 wire-format tests
# can pin the URL grammar without dragging the full download stack into
# the test binary.  The C# ``PageRoutes.Organization.Replay.Download.Deconstruct``
# route template ``/{orgSlug}/{recordingId}/download`` is the reference
# shape.

proc downloadFile(url: string, outputPath: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)): int =
  ## Downloads a trace archive from a CI platform URL.
  ## Uses the native API client instead of shelling out to ct-remote.
  let remoteConf = initRemoteConfig()
  let bearerToken = remoteConf.getBearerToken(token.get(""))
  let resolvedBaseUrl = remoteConf.resolveBaseRemoteUrl(baseUrl.get(""))

  var client = initApiClient(resolvedBaseUrl)
  defer: client.close()

  let (orgSlug, recordingId) = parseDownloadShareUrl(url)
  if recordingId.len == 0 or orgSlug.len == 0:
    echo "error: invalid download URL"
    return 1

  # Validate the user has access to this organization's tenant.
  discard resolveTenantId(client, orgSlug, bearerToken)

  let downloadResp = client.requestTraceDownloadUrl(recordingId, bearerToken)
  ft.downloadToFile(downloadResp.downloadUrl, outputPath)
  return 0

proc downloadTrace*(url: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)): string =
  ## Downloads a remote trace archive into the local trace directory and
  ## returns the UUIDv7 ``recording_id`` of the imported trace.
  ##
  ## M-REC-8: a fresh local UUIDv7 is minted here to name the on-disk
  ## landing folder (and the tmp download zip).  This is intentional:
  ## the server-side identifier embedded in the URL ("``recordingId``"
  ## on the wire) is the *uploader's* recording-id; the *downloader*
  ## treats the download as the start of a new local recording row in
  ## its own ``trace_index.db``.  A follow-up may align the two ids so
  ## ``preserve-on-import`` behaviour matches §8's "Imported traces"
  ## note in the parent spec, but for M-REC-8 we keep the existing
  ## mint-on-import behaviour.
  let recordingId = trace_index.newID(false)

  let downloadTarget = codetracerTmpPath / fmt"downloaded-trace-{recordingId}.zip"

  # M-REC-7: downloads land at ``<traces>/<recording_id>/`` — the bare
  # UUIDv7 — to match the on-disk layout for locally recorded traces.
  let unzippedLocation = paths.recordingFolder(codetracerTraceDir, recordingId)

  let downloadExitCode = downloadFile(url, downloadTarget, token, baseUrl)
  if downloadExitCode != 0:
    echo "error: problem: download failed"
    quit(downloadExitCode)

  unzipIntoFolder(downloadTarget, unzippedLocation)
  removeFile(downloadTarget)

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
  let programFilename = ctPath.extractFilename.changeFileExt("")
  let isWasm = programFilename.endsWith(".wasm")
  let lang = detectLang(programFilename, LangUnknown, isWasm)
  let recordPid = NO_PID # pid is recoverable from the CTFS metadata block.
  discard importTrace(unzippedLocation, recordingId, recordPid, lang, DB_SELF_CONTAINED_DEFAULT, url)
  return recordingId

proc downloadTraceCommand*(traceDownloadUrl: string,
    token: Option[string] = none(string),
    baseUrl: Option[string] = none(string)) =
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

    let recordingId = downloadTrace(traceDownloadUrl, token, baseUrl)
    if isatty(stdout):
      echo fmt"OK: downloaded with recording id {recordingId}"
    else:
      # being parsed by `ct` index code
      echo recordingId

  except CatchableError as e:
    echo fmt"error: downloading file '{e.msg}'"
    quit(1)
