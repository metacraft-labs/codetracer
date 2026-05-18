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

import std/[httpclient, json, net, strformat, strutils, uri]

type
  TenantListItem* = object
    tenantId*: string
    displayName*: string
    slug*: string
    role*: string

  TraceUploadUrlResponse* = object
    ## M-REC-8: ``recordingId`` is the client-minted UUIDv7 the upload
    ## flow echoes back from the server.  The server now stores this
    ## value as the canonical identity of the uploaded trace; the
    ## ``controlId`` / ``downloadKey`` pair (separate types) remain the
    ## server-issued access tokens for the uploaded copy.
    recordingId*: string
    uploadUrl*: string
    expiresAt*: string

  TraceDownloadUrlResponse* = object
    downloadUrl*: string
    expiresAt*: string

  LicenseInfoResponse* = object
    licenseInfo*: string

  UploadSessionResponse* = object
    ## Response from ``POST /tenants/{tenantId}/traces/upload-session``.
    sessionId*: string
    s3KeyPrefix*: string

  SliceUploadUrlResponse* = object
    ## Response from ``POST /traces/{sessionId}/slice-upload-url``.
    uploadUrl*: string
    sliceIndex*: int

  ApiError* = object of CatchableError
    ## Raised when the server returns a non-success HTTP status.

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
    raise newException(ApiError,
      fmt"Remote service returned error: {response.status}" &
      (if body.len > 0: " — " & body else: "") &
      " (during " & context & ")")

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
  baseApiUrl & fmt"tenants/{tenantId}/traces/upload-url"

proc buildUploadUrlBody*(recordingId, fileName, contentType: string,
    contentLength: int64): JsonNode =
  ## Request-body builder for ``POST .../traces/upload-url``.
  ## M-REC-8: the body carries the client-minted UUIDv7 ``recordingId``.
  %*{
    "recordingId": recordingId,
    "fileName": fileName,
    "contentType": contentType,
    "contentLength": contentLength,
  }

proc buildConfirmUploadPath*(baseApiUrl, recordingId: string): string =
  ## URL builder for ``POST /api/v1/traces/{recordingId}/confirm-upload``.
  ## M-REC-8: the path segment is the UUIDv7 ``recordingId``.
  baseApiUrl & fmt"traces/{recordingId}/confirm-upload"

proc buildDownloadUrlPath*(baseApiUrl, recordingId: string): string =
  ## URL builder for ``GET /api/v1/traces/{recordingId}/download-url``.
  ## M-REC-8: the path segment is the UUIDv7 ``recordingId``.
  baseApiUrl & fmt"traces/{recordingId}/download-url"

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
  let parsed = parseUri(url)
  let parts = parsed.path.strip(chars = {'/'}).split('/')
  if parts.len >= 2:
    let candidateId = parts[^1]
    if candidateId.toLowerAscii() == "download" and parts.len >= 3:
      result.orgSlug = parts[^3]
      result.recordingId = parts[^2]
    else:
      result.orgSlug = parts[^2]
      result.recordingId = parts[^1]
    return
  raise newException(ValueError, "Invalid download URL: " & url)

proc requestTraceUploadUrl*(client: ApiClient, tenantId: string,
    recordingId: string, fileName: string, contentType: string,
    contentLength: int64, bearerToken: string): TraceUploadUrlResponse =
  ## ``POST /api/v1/tenants/{tenantId}/traces/upload-url``
  ## Returns a presigned S3 upload URL.
  ##
  ## M-REC-8: the client-minted UUIDv7 ``recordingId`` is now sent in
  ## the request body so the server can persist it as the trace's
  ## canonical identity (rather than minting a fresh server-side
  ## integer).  The response echoes back the same ``recordingId``.
  let url = buildUploadUrlPath(client.baseApiUrl, tenantId)
  let body = $ buildUploadUrlBody(
    recordingId, fileName, contentType, contentLength)
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "requestTraceUploadUrl")

  let jsonBody = parseJson(response.body)
  result = TraceUploadUrlResponse(
    recordingId: jsonBody["recordingId"].getStr(),
    uploadUrl: jsonBody["uploadUrl"].getStr(),
    expiresAt: jsonBody["expiresAt"].getStr(),
  )

proc confirmTraceUpload*(client: ApiClient, recordingId: string, etag: string,
    bearerToken: string) =
  ## ``POST /api/v1/traces/{recordingId}/confirm-upload``
  ## Confirms that the file was uploaded successfully with the given ETag.
  ##
  ## M-REC-8: the path parameter is the UUIDv7 ``recordingId`` returned
  ## from ``requestTraceUploadUrl``.
  let url = buildConfirmUploadPath(client.baseApiUrl, recordingId)
  let body = $ %*{"etag": etag}
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "confirmTraceUpload")

# ---------------------------------------------------------------------------
# Trace download endpoints
# ---------------------------------------------------------------------------

proc requestTraceDownloadUrl*(client: ApiClient, recordingId: string,
    bearerToken: string): TraceDownloadUrlResponse =
  ## ``GET /api/v1/traces/{recordingId}/download-url``
  ## Returns a presigned S3 download URL.
  ##
  ## M-REC-8: the path parameter is the UUIDv7 ``recordingId`` (the
  ## same identity the recorder minted at record-start and the client
  ## sent during upload).
  let url = buildDownloadUrlPath(client.baseApiUrl, recordingId)
  let response = client.httpClient.request(
    url, httpMethod = HttpGet, headers = bearerHeaders(bearerToken))
  ensureSuccess(response, "requestTraceDownloadUrl")

  let jsonBody = parseJson(response.body)
  result = TraceDownloadUrlResponse(
    downloadUrl: jsonBody["downloadUrl"].getStr(),
    expiresAt: jsonBody["expiresAt"].getStr(),
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

proc requestUploadSession*(client: ApiClient, tenantId: string,
    platform: string, recordingMode: string,
    bearerToken: string): UploadSessionResponse =
  ## ``POST /api/v1/tenants/{tenantId}/traces/upload-session``
  ## Creates a new upload session for per-slice streaming upload.
  ## Returns a session ID and S3 key prefix for the upload.
  let url = client.baseApiUrl & fmt"tenants/{tenantId}/traces/upload-session"
  let body = $ %*{
    "platform": platform,
    "recordingMode": recordingMode,
  }
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "requestUploadSession")

  let jsonBody = parseJson(response.body)
  result = UploadSessionResponse(
    sessionId: jsonBody["sessionId"].getStr(),
    s3KeyPrefix: jsonBody["s3KeyPrefix"].getStr(),
  )

proc requestSliceUploadUrl*(client: ApiClient, sessionId: string,
    sliceIndex: int, fileName: string, contentLength: int64,
    bearerToken: string): SliceUploadUrlResponse =
  ## ``POST /api/v1/traces/{sessionId}/slice-upload-url``
  ## Requests a presigned S3 URL for uploading a single slice file.
  let url = client.baseApiUrl & fmt"traces/{sessionId}/slice-upload-url"
  let body = $ %*{
    "sliceIndex": sliceIndex,
    "fileName": fileName,
    "contentLength": contentLength,
  }
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "requestSliceUploadUrl")

  let jsonBody = parseJson(response.body)
  result = SliceUploadUrlResponse(
    uploadUrl: jsonBody["uploadUrl"].getStr(),
    sliceIndex: jsonBody["sliceIndex"].getInt(),
  )

proc finalizeUploadSession*(client: ApiClient, sessionId: string,
    totalSlices: int, totalEvents: int, platform: string,
    bearerToken: string) =
  ## ``POST /api/v1/traces/{sessionId}/finalize``
  ## Marks the upload session as complete after all slices have been uploaded.
  ## The server will process the uploaded slices and make the trace available.
  let url = client.baseApiUrl & fmt"traces/{sessionId}/finalize"
  let body = $ %*{
    "totalSlices": totalSlices,
    "totalEvents": totalEvents,
    "platform": platform,
  }
  let response = client.httpClient.request(
    url, httpMethod = HttpPost, headers = bearerHeaders(bearerToken), body = body)
  ensureSuccess(response, "finalizeUploadSession")
