## REST API client for the CodeTracer CI platform.
##
## Replaces the C# ``MonolithApiClient``. All calls target the ``/api/v1/``
## endpoint group. Authentication is via bearer token in the Authorization header.
##
## Endpoint reference (post M-REC-8 rename — the path parameter is now
## the client-minted UUIDv7 ``recordingId``, not a server-side integer):
## - ``GET  tenants``                                              → list user's tenants
## - ``POST tenants/{tenantId}/traces/upload-url``                 → presigned upload URL
## - ``POST traces/{recordingId}/confirm-upload``                  → confirm upload with etag
## - ``GET  traces/{recordingId}/download-url``                    → presigned download URL
## - ``GET  billing/license``                                      → license info (v2)
## - ``POST license/issue``                                        → signed CTL license blob
## - ``POST tenants/{tenantId}/traces/upload-session`` (M18a)      → create upload session
## - ``POST traces/{sessionId}/slice-upload-url``      (M18a)      → presigned slice URL
## - ``POST traces/{sessionId}/finalize``              (M18a)      → finalize upload session
##
## M-REC-8 wire-format flip (see
## ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``
## §6.7): the previous integer ``traceId`` minted server-side at
## upload-url request time has been replaced by the client's UUIDv7
## ``recording_id``.  The body and path key is ``recordingId``.
## ``controlId`` and ``downloadKey`` keep their pre-existing
## semantics — those are server-issued access tokens for the uploaded
## copy, not recording identities.  The ``sessionId`` family of paths
## (slice-upload / finalize) is a separate server-side identifier for
## the upload session itself and is unaffected by this rename.

## AS-1 (``codetracer-specs/Sharing/Artifact-Store.milestones.org``): every
## URL and request body below is now *derived* from the kind registry in
## ``artifact.nim`` rather than spelled out here.  The recording kind's rows in
## that registry reproduce these paths character for character — that is what
## the migration means, and
## ``src/tests/gui/tests/sharing/artifact_model_vm_test.nim`` pins it against
## the literal pre-AS-1 strings.  The point of routing through the registry is
## that a second kind cannot acquire a second transport by accident: there is
## one grammar, parameterised by kind.

## AS-3: the four upload requests below no longer *build* anything.  They take
## an ``ArtifactTransferStep`` — a URL and a body that ``artifact_transfer.nim``
## produced — and send it.  Before AS-3 they rebuilt the URL and the body from
## the artifact, which made the planner a second, parallel description of the
## same conversation that only the tests consumed; mutating the planner alone
## left the round-trip suite green, which is how it was proved.  See
## ``Artifact-Store.md`` §10.1.

import std/[httpclient, json, net, options, strformat, strutils]
import collab_invite_url
import artifact_transfer

export collab_invite_url
export artifact_transfer

type
  TenantListItem* = object
    tenantId*: string
    displayName*: string
    slug*: string
    role*: string

  ArtifactUploadUrlResponse* = object
    ## Response from ``POST /tenants/{tenantId}/{segment}/upload-url``.
    ##
    ## M-REC-8: for the recording kind the server echoes back the client-minted
    ## UUIDv7 it was sent, and stores it as the canonical identity of the
    ## uploaded trace.  AS-2 reads the same field for every kind — the
    ## recording kind spells it ``recordingId`` on the wire and every other
    ## kind spells it ``artifactId``, which is a wire spelling rather than two
    ## concepts.
    acknowledgedArtifactId*: string
      ## Empty when the service echoed no id at all.  ``storeArtifact`` treats
      ## that as "the service did not name the artifact back" rather than
      ## substituting the local id — see ``ArtifactStoreOutcome``.
    uploadUrl*: string
    expiresAt*: string

  CollabJoinBootstrapResponse* = object
    replayId*: string
    traceId*: string
    traceIdentity*: string
    roomId*: string
    initialGrants*: seq[string]
    webUiUrl*: string
    nativeJoinUrl*: string
    rendezvousUrl*: string
    transportHints*: seq[string]

  LicenseInfoResponse* = object
    licenseInfo*: string

  UploadSessionResponse* = object
    ## Response from ``POST /tenants/{tenantId}/{segment}/upload-session``.
    ##
    ## AS-2: ``session`` carries the collection the session was opened in
    ## alongside the server-issued id, so the slice and finalize paths address
    ## that same collection.  See ``artifact.ArtifactUploadSession``.
    session*: ArtifactUploadSession
    s3KeyPrefix*: string
    acknowledgedArtifactId*: string
      ## The artifact id the service says this session will produce, when it
      ## says one.
      ##
      ## Empty is the normal answer for the **recording** kind, and that is a
      ## property of the wire rather than an oversight: the recording kind's
      ## `…/upload-session` body is frozen to `platform` and `recordingMode`
      ## and carries no id, so a sliced recording upload genuinely does not
      ## tell the service which recording it is — the service names the result
      ## itself.  That is the fact behind `UploadedInfo.fileId` holding a
      ## session id after a slice upload (`Artifact-Store.md` §8 defect 11).
      ## Kinds whose session body is not frozen send `artifactId` and get it
      ## acknowledged here.

  SliceUploadUrlResponse* = object
    ## Response from ``POST /{segment}/{sessionId}/slice-upload-url``.
    uploadUrl*: string
    sliceIndex*: int

  ArtifactDownloadUrlResponse* = object
    ## Response from ``GET /{segment}/{artifactId}/download-url``.
    ##
    ## There is deliberately **no pre-parsed ``kind`` or ``record`` field
    ## here.**  An earlier draft had both, and the ``kind`` one read
    ## ``parseArtifactKind(token)`` into an ``Option`` — which collapses
    ## *unrecognised* into *absent*, the exact distinction §8 defect 10 exists
    ## to preserve, in a field nothing consumed.  A parser nothing consumes is
    ## how that defect came to exist in the first place, so the fields are gone
    ## rather than fixed: the whole response is carried, and the single layer
    ## that decides what an answer *means*
    ## (``artifact_transfer.resolveDownloadedKind``) refuses an unrecognised
    ## kind by name.
    downloadUrl*: string
    expiresAt*: string
    body*: JsonNode
      ## The whole response, exactly as the service sent it.

  ApiError* = object of CatchableError
    ## Raised when the server returns a non-success HTTP status.
    status*: int
      ## The HTTP status code, held as a number rather than only embedded in
      ## the message.  A caller walking a list of candidate collections has to
      ## distinguish "this collection does not hold it" (404) from "you may not
      ## ask" (401/403) — continuing to the next collection on the second would
      ## turn an authorization failure into a not-found, which is a worse
      ## diagnostic and a slower one.

  ApiClient* = object
    baseApiUrl*: string   ## e.g. "https://web.codetracer.com/api/v1/"
    httpClient*: HttpClient

proc initApiClient*(baseRemoteAddress: string): ApiClient =
  ## Creates an API client pointing at ``baseRemoteAddress``.
  ## The ``/api/v1/`` suffix is appended automatically.
  let baseUrl = baseRemoteAddress.strip(chars = {'/'})
  result.baseApiUrl = baseUrl & "/api/v1/"
  result.httpClient = newHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer))

proc close*(client: var ApiClient) =
  client.httpClient.close()

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc bearerHeaders(bearerToken: string): HttpHeaders =
  newHttpHeaders({
    "Authorization": "Bearer " & bearerToken,
    "Content-Type": "application/json",
  })

proc ensureSuccess(response: Response, context: string) =
  ## Raises ``ApiError`` if the response status is not 2xx.
  ## Matches the C# ``EnsureSuccessAsync`` pattern.
  let code = response.code.int
  if code < 200 or code >= 300:
    let body = response.body
    let error = newException(ApiError,
      fmt"Remote service returned error: {response.status}" &
      (if body.len > 0: " — " & body else: "") &
      " (during " & context & ")")
    error.status = code
    raise error

proc requireStep(step: ArtifactTransferStep,
    expected: ArtifactTransferStepKind) =
  ## Refuse when the executor hands a step to the wrong sender.
  ##
  ## A programming error rather than a service error, and it is checked rather
  ## than assumed because the whole point of AS-3's first change is that the
  ## executor now follows the plan: a sender that quietly accepted whichever
  ## step it was given would let the two drift apart again, one call site at a
  ## time.
  if step.kind != expected:
    raise newException(ValueError,
      "artifact transfer: expected a '" & $expected & "' step, got '" &
      $step.kind & "'")

proc sendPlannedStep(client: ApiClient, step: ArtifactTransferStep,
    httpMethod: HttpMethod, bearerToken, context: string): JsonNode =
  ## Send one planned request, exactly as planned, and return its parsed body.
  ##
  ## **The URL and the body come from `step` and are not touched here.**  That
  ## is the whole of AS-3's executor/planner unification: there is one
  ## description of what an upload says to the service, it lives in
  ## ``artifact_transfer.nim``, it is pure, and it is asserted headlessly
  ## against the literal strings the pre-AS-1 client sent.  This procedure's
  ## only job is the socket.
  if step.urlPath.len == 0:
    raise newException(ValueError,
      "artifact transfer: the planned '" & $step.kind & "' step has no URL")
  let body = if step.body.isNil: "" else: $step.body
  let response = client.httpClient.request(
    step.urlPath, httpMethod = httpMethod,
    headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, context)
  try:
    parseJson(response.body)
  except CatchableError:
    newJObject()

# ---------------------------------------------------------------------------
# Tenant endpoints
# ---------------------------------------------------------------------------

proc getTenants*(client: ApiClient, bearerToken: string): seq[TenantListItem] =
  ## ``GET /api/v1/tenants`` → list of tenants the user belongs to.
  let url = client.baseApiUrl & "tenants"
  let response = client.httpClient.request(
    url, httpMethod = HttpGet, headers = bearerHeaders(bearerToken))
  ensureSuccess(response, "getTenants")

  let jsonBody = parseJson(response.body)
  let tenantsArray = jsonBody["tenants"]
  result = @[]
  for item in tenantsArray:
    result.add(TenantListItem(
      tenantId: item["tenantId"].getStr(),
      displayName: item["displayName"].getStr(),
      slug: item["slug"].getStr(),
      role: item["role"].getStr(),
    ))

# ---------------------------------------------------------------------------
# Trace upload endpoints
# ---------------------------------------------------------------------------

proc buildUploadUrlPath*(baseApiUrl, tenantId: string): string =
  ## URL builder for ``POST /api/v1/tenants/{tenantId}/traces/upload-url``.
  ## Extracted as a pure helper so the M-REC-8 wire-format tests can
  ## assert the URL shape without going through the HTTP transport.
  ##
  ## AS-1: the ``traces`` segment is now the *recording kind's* registry entry
  ## rather than a literal.  Identical output; one grammar.
  artifactUploadUrlPath(baseApiUrl, tenantId, akRecording)

proc buildUploadUrlBody*(recordingId, fileName, contentType: string,
    contentLength: int64): JsonNode =
  ## Request-body builder for ``POST .../traces/upload-url``.
  ## M-REC-8: the body carries the client-minted UUIDv7 ``recordingId``.
  ##
  ## AS-1: for the recording kind the artifact id *is* the recording id, so
  ## the body keeps the ``recordingId`` key the deployed service reads.  See
  ## ``artifact.buildArtifactUploadUrlBody`` for why the key is per kind.
  buildArtifactUploadUrlBody(
    recordingArtifactRef(recordingId), fileName, contentType, contentLength)

proc buildConfirmUploadPath*(baseApiUrl, recordingId: string): string =
  ## URL builder for ``POST /api/v1/traces/{recordingId}/confirm-upload``.
  ## M-REC-8: the path segment is the UUIDv7 ``recordingId``.
  artifactConfirmUploadPath(baseApiUrl, recordingArtifactRef(recordingId))

proc buildDownloadUrlPath*(baseApiUrl, recordingId: string): string =
  ## URL builder for ``GET /api/v1/traces/{recordingId}/download-url``.
  ## M-REC-8: the path segment is the UUIDv7 ``recordingId``.
  artifactDownloadUrlPath(baseApiUrl, recordingArtifactRef(recordingId))

proc parseDownloadShareUrl*(url: string):
    tuple[orgSlug: string, recordingId: string] =
  ## Parses sharing-server download URLs of the form
  ## ``https://<host>/{orgSlug}/{recordingId}/download`` (with the
  ## trailing ``/download`` optional).
  ##
  ## M-REC-8: the path component that previously carried the
  ## server-side integer ``traceGuid`` now carries the UUIDv7
  ## ``recording_id``.  The parser is otherwise structurally identical
  ## to the pre-M-REC-8 version; only the returned field name flipped
  ## to track the new wire semantics.  Exported (rather than kept
  ## private to ``download.nim``) so the M-REC-8 wire-format tests can
  ## pin the URL grammar without dragging the full download stack into
  ## the test binary.
  ##
  ## AS-1: share URLs carry **no kind**, and that is what makes every link
  ## already handed to a user survive the generalisation — the id is unique
  ## across kinds, so the service resolves the kind from the id.  This wrapper
  ## keeps the recording-shaped field name for the callers that only ever deal
  ## in recordings; ``artifact.parseArtifactShareUrl`` is the kind-neutral form.
  let resolved = parseArtifactShareUrl(url)
  result.orgSlug = resolved.orgSlug
  result.recordingId = resolved.artifactId

proc exchangeCollabInvite*(client: ApiClient, inviteToken: string):
    CollabJoinBootstrapResponse =
  ## ``POST /api/v1/collab/invites/exchange`` for standalone load-trace URL
  ## joins. CI returns bootstrap metadata only; ViewOps are not sent here.
  let url = buildCollabInviteExchangePath(client.baseApiUrl)
  let response = client.httpClient.request(
    url,
    httpMethod = HttpPost,
    headers = newHttpHeaders({"Content-Type": "application/json"}),
    body = $ %*{"token": inviteToken})
  ensureSuccess(response, "exchangeCollabInvite")

  let body = parseJson(response.body)
  result = CollabJoinBootstrapResponse(
    replayId: body{"replayId"}.getStr(),
    traceId: body{"traceId"}.getStr(),
    traceIdentity: body{"traceIdentity"}.getStr(),
    roomId: body{"roomId"}.getStr(),
    initialGrants: @[],
    webUiUrl: body{"webUiUrl"}.getStr(),
    nativeJoinUrl: body{"nativeJoinUrl"}.getStr(),
    rendezvousUrl: body{"rendezvousUrl"}.getStr(),
    transportHints: @[],
  )
  for grant in body{"initialGrants"}.getElems:
    result.initialGrants.add grant.getStr()
  for hint in body{"transportHints"}.getElems:
    result.transportHints.add hint.getStr()

proc requestArtifactUploadUrl*(client: ApiClient,
    step: ArtifactTransferStep,
    bearerToken: string): ArtifactUploadUrlResponse =
  ## Send the plan's ``atsRequestUploadUrl`` step —
  ## ``POST /api/v1/tenants/{tenantId}/{segment}/upload-url``.
  ##
  ## AS-2 derived this URL and body from the artifact *here*; AS-3 takes them
  ## from the step the planner produced, so there is one description of the
  ## request rather than two that agree by convention.  For the recording kind
  ## the planner's output is character-identical to the pre-AS-1 strings, and
  ## `artifact_transfer_vm_test.nim` pins that against literals.
  ##
  ## ``recordingId`` is echoed back by the service for the recording kind and
  ## ``artifactId`` for every other kind; a service that echoes neither leaves
  ## ``acknowledgedArtifactId`` empty rather than having the local id
  ## substituted for it, so "the service named this back" stays a fact the
  ## caller can test.
  requireStep(step, atsRequestUploadUrl)
  let jsonBody = client.sendPlannedStep(
    step, HttpPost, bearerToken, "requestArtifactUploadUrl")
  var echoed = jsonBody{"recordingId"}.getStr()
  if echoed.len == 0:
    echoed = jsonBody{"artifactId"}.getStr()
  result = ArtifactUploadUrlResponse(
    acknowledgedArtifactId: echoed,
    uploadUrl: jsonBody["uploadUrl"].getStr(),
    expiresAt: jsonBody{"expiresAt"}.getStr(),
  )

proc confirmArtifactUpload*(client: ApiClient, step: ArtifactTransferStep,
    bearerToken: string) =
  ## Send the plan's ``atsConfirmUpload`` step —
  ## ``POST /api/v1/{segment}/{artifactId}/confirm-upload``.
  ##
  ## The step's body carries the ETag, which is only known once the object
  ## store has answered the PUT; `uploadCompletionStep` takes it as an argument
  ## for exactly that reason, so the run-time value still enters through the
  ## planner rather than around it.
  requireStep(step, atsConfirmUpload)
  discard client.sendPlannedStep(
    step, HttpPost, bearerToken, "confirmArtifactUpload")

proc requestArtifactDownloadUrl*(client: ApiClient, reference: ArtifactRef,
    bearerToken: string): ArtifactDownloadUrlResponse =
  ## ``GET /api/v1/{segment}/{artifactId}/download-url`` — kind-neutral.
  ##
  ## Addresses the kind's own collection when the caller knows the kind, and
  ## the kind-neutral ``artifacts/`` collection when it does not.  The response
  ## is returned whole, including any artifact record it carried, because
  ## deciding what an answer *means* — in particular what kind the bytes are —
  ## is `artifact_transfer.resolveDownloadedKind`'s job, not this layer's.
  let url = artifactDownloadUrlPath(client.baseApiUrl, reference)
  let response = client.httpClient.request(
    url, httpMethod = HttpGet, headers = bearerHeaders(bearerToken))
  ensureSuccess(response, "requestArtifactDownloadUrl")

  let jsonBody = parseJson(response.body)
  result = ArtifactDownloadUrlResponse(
    downloadUrl: jsonBody["downloadUrl"].getStr(),
    expiresAt: jsonBody{"expiresAt"}.getStr(),
    body: jsonBody,
  )

# ---------------------------------------------------------------------------
# License endpoints
# ---------------------------------------------------------------------------

proc getLicenseInfo*(client: ApiClient,
    bearerToken: string): LicenseInfoResponse =
  ## ``GET /api/v1/billing/license`` → license tier info.
  ## Falls back to the legacy ``POST /api/trace-storage/get-user-license-info``
  ## endpoint if the modern one returns 404 or 405, matching the C#
  ## ``GetLicenseInfoAsync`` implementation.
  let url = client.baseApiUrl & "billing/license"
  let response = client.httpClient.request(
    url, httpMethod = HttpGet, headers = bearerHeaders(bearerToken))

  let code = response.code.int
  if code == 404 or code == 405:
    # Legacy fallback: POST to a different path with token in the body.
    # The legacy endpoint is NOT under /api/v1/ — it's at /api/trace-storage/.
    let baseUrl = client.baseApiUrl.replace("/api/v1/", "/")
    let legacyUrl = baseUrl & "api/trace-storage/get-user-license-info"
    let legacyBody = $ %*{"bearerToken": bearerToken}
    let legacyResponse = client.httpClient.request(
      legacyUrl, httpMethod = HttpPost,
      headers = bearerHeaders(bearerToken), body = legacyBody)
    ensureSuccess(legacyResponse, "getLicenseInfo (legacy)")
    let jsonBody = parseJson(legacyResponse.body)
    return LicenseInfoResponse(licenseInfo: jsonBody["licenseInfo"].getStr())

  ensureSuccess(response, "getLicenseInfo")
  let jsonBody = parseJson(response.body)
  result = LicenseInfoResponse(licenseInfo: jsonBody["licenseInfo"].getStr())

proc issueLicense*(client: ApiClient, bearerToken: string): string =
  ## ``POST /api/v1/license/issue`` → raw binary CTL license blob.
  ## Returns the response body as a raw string (binary data).
  ## The caller should validate the CTL format (magic bytes, minimum size).
  let url = client.baseApiUrl & "license/issue"
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken))
  ensureSuccess(response, "issueLicense")
  result = response.body

# ---------------------------------------------------------------------------
# Upload-session endpoints (M18a per-slice upload)
# ---------------------------------------------------------------------------

proc openArtifactUploadSession*(client: ApiClient,
    step: ArtifactTransferStep, kind: ArtifactKind,
    bearerToken: string): UploadSessionResponse =
  ## Send the plan's ``atsOpenUploadSession`` step —
  ## ``POST /api/v1/tenants/{tenantId}/{segment}/upload-session``.
  ##
  ## AS-1 made this URL registry-derived; AS-2 returned the session as an
  ## ``ArtifactUploadSession`` — the id **and** the collection it was opened in
  ## — so the slice and finalize requests that follow address the collection
  ## this session belongs to rather than a literal.  ``kind`` is passed
  ## alongside the step for that pairing only: the session's collection is not
  ## recoverable from the server-issued id, and the step's URL is a string.
  requireStep(step, atsOpenUploadSession)
  let jsonBody = client.sendPlannedStep(
    step, HttpPost, bearerToken, "openArtifactUploadSession")
  result = UploadSessionResponse(
    session: ArtifactUploadSession(
      sessionId: jsonBody["sessionId"].getStr(),
      kind: kind),
    s3KeyPrefix: jsonBody{"s3KeyPrefix"}.getStr(),
    acknowledgedArtifactId: jsonBody{"artifactId"}.getStr(),
  )

proc requestArtifactPartUploadUrl*(client: ApiClient,
    step: ArtifactTransferStep,
    bearerToken: string): SliceUploadUrlResponse =
  ## Send the plan's ``atsRequestPartUploadUrl`` step —
  ## ``POST /api/v1/{segment}/{sessionId}/slice-upload-url``.
  ##
  ## AS-2: the segment comes from the session, not from a literal — see
  ## ``artifact.artifactSliceUploadUrlPath`` for the decision and why the
  ## *session* rather than a re-supplied kind is what carries it.  AS-3: the
  ## whole URL and body come from the step, so this procedure can no longer
  ## build a request the plan did not describe.
  requireStep(step, atsRequestPartUploadUrl)
  let jsonBody = client.sendPlannedStep(
    step, HttpPost, bearerToken, "requestArtifactPartUploadUrl")
  result = SliceUploadUrlResponse(
    uploadUrl: jsonBody["uploadUrl"].getStr(),
    sliceIndex: jsonBody{"sliceIndex"}.getInt(step.part.index),
  )

proc buildFinalizePath*(baseApiUrl, sessionId: string): string =
  ## URL builder for ``POST /api/v1/traces/{sessionId}/finalize``.
  ## Extracted as a pure helper so unit tests can pin the URL shape
  ## without going through the HTTP transport.
  ##
  ## AS-2: derived from the recording kind's registry segment rather than
  ## spelled out.  Identical output; one grammar.
  artifactFinalizePath(baseApiUrl,
    ArtifactUploadSession(sessionId: sessionId, kind: akRecording))

proc buildFinalizeBody*(totalSlices: int, totalEvents: int,
    platform: string, omniscientDbMode: string = ""): JsonNode =
  ## Request-body builder for ``POST .../traces/{sessionId}/finalize``.
  ##
  ## M31 (Value-Origin-Tracking spec §M31 and CS-M7 §Finalize) — the
  ## recording client picks how the cluster prepares the M18 / M19
  ## omniscient artefacts (``memwrites.tc`` / ``linehits.tc`` /
  ## ``originmeta.tc`` / ``varwrites.tc`` / ``source_exprs.tc``) by
  ## signalling on the camelCase ``omniscientDbMode`` field.  Legal
  ## wire values are ``off`` | ``on`` | ``lazy`` | ``pre-prepared``.
  ##
  ## When ``omniscientDbMode`` is the empty string the field is
  ## *omitted* so a default-mode client (or one that pre-dates M31)
  ## continues to round-trip the legacy CS-M7 body unchanged — the
  ## server treats a missing field as ``off`` per the spec.
  ##
  ## AS-2: the body itself now lives in ``artifact.nim`` beside the kind that
  ## owns it, so the generic finalize and this recording-named wrapper cannot
  ## become two spellings of one request.
  buildRecordingFinalizeBody(
    totalSlices, totalEvents, platform, omniscientDbMode)

proc finalizeArtifactUploadSession*(client: ApiClient,
    step: ArtifactTransferStep, bearerToken: string): string =
  ## Send the plan's ``atsFinalizeSession`` step —
  ## ``POST /api/v1/{segment}/{sessionId}/finalize``.
  ##
  ## Marks the session complete once every part has been published.  The
  ## body's ``totalSlices`` counts the **pieces of the payload**, not the
  ## objects the session uploaded — sidecars travel through the same session
  ## and are not reassembled — and it is `uploadCompletionStep` that decides
  ## that, once, rather than each caller.  See
  ## ``artifact_transfer.ArtifactPartRole``.
  ##
  ## Returns the artifact id the service acknowledged, or ``""`` when it
  ## acknowledged none — see ``UploadSessionResponse.acknowledgedArtifactId``
  ## for why an empty answer is the normal one for the recording kind.
  requireStep(step, atsFinalizeSession)
  let jsonBody = client.sendPlannedStep(
    step, HttpPost, bearerToken, "finalizeArtifactUploadSession")
  jsonBody{"artifactId"}.getStr()
