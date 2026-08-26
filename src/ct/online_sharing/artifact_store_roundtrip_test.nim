## AS-2 — a recording and a review dataset round-trip through the generic
## path, over real HTTP, with real files.
##
## Spec: `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-2
## verification items 1, 2, 3 and 4.
##
## ## Why this exists beside the ViewModel suite
##
## `src/tests/gui/tests/sharing/artifact_transfer_vm_test.nim` asserts the
## transfer *plan*: which URLs, which bodies, in which order.  A plan that is
## right and an executor that does not follow it is a green suite and a broken
## upload, and this repository has been bitten by exactly that shape before
## (`online_sharing_test.nim` is a live round-trip nothing could run, and it
## rotted into a file that did not compile).  So this suite runs the **real**
## `ApiClient` — the one `ct upload` links — against a real HTTP server on a
## real socket, PUTs real bytes from real files, and reads them back.
##
## ## On mocking, per the workspace policy
##
## Nothing of CodeTracer's is mocked.  The client, the transfer plan, the
## executor, the file I/O and the HTTP are all the shipped code.  What is
## substituted is the **counterparty**: a small HTTP server standing in for the
## CodeTracer sharing service, in this process, on an ephemeral loopback port.
##
## That substitution is not a convenience, it is the only available option and
## the policy's own preferred one:
##
## * the real counterparty is a production SaaS holding other people's
##   recordings, and a test that uploads to it is a test that must never run —
##   which is precisely how `online_sharing_test.nim` rotted;
## * the boundary being crossed is therefore kept **real**: a socket, HTTP/1.1
##   request framing, presigned-URL PUTs and GETs, files on disk.  Nothing is
##   stubbed at a Nim seam, so a change to the client that breaks the wire
##   breaks this suite.
##
## The server records every request it receives, so the suite can assert what
## actually went over the socket rather than what the planner intended to send.

import std/[algorithm, base64, json, locks, net, options, os, strutils, tables,
  unittest]

import artifact_store, api_client

# ---------------------------------------------------------------------------
# A stand-in for the sharing service
# ---------------------------------------------------------------------------

type
  RecordedRequest = object
    httpMethod: string
    path: string
    headers: string
      ## The raw header block, joined with newlines.
      ##
      ## AS-3 records this, and the reason is verification item 2: "the service
      ## never receives the key" has to be asserted against **everything** the
      ## service received, and a header is the most natural place for a secret
      ## to end up by accident — one line in `bearerHeaders`, one extra field
      ## on a request, and the password is on the wire in a place no
      ## body-only assertion would look.
    body: string

  ServiceMode = enum
    ## Which era of service the client is talking to.  Both are real
    ## deployments the client has to work against, and AS-1 §5.4 asks for a
    ## single code path with a documented degradation rather than two stacks.
    smLegacy
      ## Pre-AS-2: no kind-neutral `artifacts/` collection, no artifact record
      ## on the download response.  This is what is deployed today.
    smArtifactAware
      ## Post-AS-2: serves `artifacts/`, echoes the kind and returns the stored
      ## record.

var
  serviceLock: Lock
  serviceRequests {.guard: serviceLock.}: seq[RecordedRequest]
  serviceObjects {.guard: serviceLock.}: Table[string, string]
    ## object key → local path of the bytes the client PUT
  serviceRecords {.guard: serviceLock.}: Table[string, JsonNode]
    ## artifact id → the record the service assembled from what it was told
  serviceSessions {.guard: serviceLock.}: Table[string, string]
    ## session id → the artifact id the service associates with it
  serviceSessionSlices {.guard: serviceLock.}: Table[string, Table[int, string]]
    ## session id → slice index → the object key that slice was PUT to.
    ##
    ## AS-3: the stand-in now models **reassembly**, because the client's
    ## download path depends on it and nothing was exercising that.  A sliced
    ## upload publishes one object per part; `…/finalize` tells the service how
    ## many of them are *pieces of the payload* (`totalSlices`), and what
    ## `…/download-url` then serves is those pieces concatenated in index
    ## order.  Before this, the stand-in left a session upload with no
    ## downloadable object at all, so a sliced download — encrypted or not —
    ## was tested by nothing.
  serviceMode: ServiceMode
  servicePort: int
  serviceReady: bool
  serviceStop: bool
  serviceBucketDir: string
  serviceNextId: int

proc apiSegments(path: string): seq[string] =
  ## The path segments after `/api/v1/`, or an empty sequence.
  let trimmed = path.split('?')[0].strip(chars = {'/'})
  let parts = trimmed.split('/')
  if parts.len >= 2 and parts[0] == "api" and parts[1] == "v1":
    return parts[2 .. ^1]
  @[]

proc mintedId(prefix: string): string =
  inc serviceNextId
  # A canonical-looking UUIDv7 so `validateArtifact` accepts anything built
  # from it, with the counter in the last group so ids stay distinct.
  "0194a000-" & prefix & "-7abc-8def-" & align($serviceNextId, 12, '0')

proc handleRequest(httpMethod, path, headers, body: string):
    tuple[status: int, payload: string, etag: string] {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock serviceLock:
      serviceRequests.add RecordedRequest(
        httpMethod: httpMethod, path: path, headers: headers, body: body)

    # --- the object store half: presigned PUT / GET -----------------------
    if path.startsWith("/object/"):
      let key = path[len("/object/") .. ^1]
      let objectPath = serviceBucketDir / key
      if httpMethod == "PUT":
        writeFile(objectPath, body)
        withLock serviceLock:
          serviceObjects[key] = objectPath
        return (200, "", "\"etag-" & key & "\"")
      if httpMethod == "GET":
        if fileExists(objectPath):
          return (200, readFile(objectPath), "")
        return (404, "{}", "")

    let segments = apiSegments(path)
    if segments.len == 0:
      return (404, "{}", "")

    let parsedBody =
      if body.len > 0:
        try: parseJson(body) except CatchableError: newJObject()
      else: newJObject()

    # --- POST tenants/{t}/{segment}/upload-url ----------------------------
    if segments.len == 4 and segments[0] == "tenants" and
        segments[3] == "upload-url":
      let collection = segments[2]
      var artifactId = parsedBody{"recordingId"}.getStr()
      if artifactId.len == 0:
        artifactId = parsedBody{"artifactId"}.getStr()
      let key = collection & "-" & artifactId & "-" &
        parsedBody{"fileName"}.getStr("payload")
      var record = %*{
        "artifactId": artifactId,
        "collection": collection,
        "objectKey": key,
      }
      if parsedBody.hasKey("kind"):
        record["kind"] = parsedBody["kind"]
      if parsedBody.hasKey("metadata"):
        record["metadata"] = parsedBody["metadata"]
      withLock serviceLock:
        serviceRecords[artifactId] = record
      let echoed =
        if parsedBody.hasKey("recordingId"): "recordingId" else: "artifactId"
      return (200, $ %*{
        echoed: artifactId,
        "uploadUrl": "http://127.0.0.1:" & $servicePort & "/object/" & key,
        "expiresAt": "",
      }, "")

    # --- POST tenants/{t}/{segment}/upload-session ------------------------
    if segments.len == 4 and segments[0] == "tenants" and
        segments[3] == "upload-session":
      let collection = segments[2]
      let sessionId = mintedId("2222")
      # The recording kind's frozen session body carries no artifact id, so
      # the service names the result itself — exactly as the real one does.
      var artifactId = parsedBody{"artifactId"}.getStr()
      let clientNamedIt = artifactId.len > 0
      if not clientNamedIt:
        artifactId = mintedId("3333")
      var record = %*{
        "artifactId": artifactId,
        "collection": collection,
        "parts": newJArray(),
      }
      if parsedBody.hasKey("kind"):
        record["kind"] = parsedBody["kind"]
      if parsedBody.hasKey("metadata"):
        record["metadata"] = parsedBody["metadata"]
      if parsedBody.hasKey("platform"):
        record["platform"] = parsedBody["platform"]
      withLock serviceLock:
        serviceSessions[sessionId] = artifactId
        serviceRecords[artifactId] = record
      var payload = %*{
        "sessionId": sessionId,
        "s3KeyPrefix": collection & "/" & sessionId & "/",
      }
      if clientNamedIt:
        payload["artifactId"] = %artifactId
      return (200, $payload, "")

    # --- POST {segment}/{sessionId}/slice-upload-url ----------------------
    if segments.len == 3 and segments[2] == "slice-upload-url":
      let sessionId = segments[1]
      let key = segments[0] & "-" & sessionId & "-" &
        parsedBody{"fileName"}.getStr("part")
      let sliceIndex = parsedBody{"sliceIndex"}.getInt()
      withLock serviceLock:
        if not serviceSessionSlices.hasKey(sessionId):
          serviceSessionSlices[sessionId] = initTable[int, string]()
        serviceSessionSlices[sessionId][sliceIndex] = key
      return (200, $ %*{
        "uploadUrl": "http://127.0.0.1:" & $servicePort & "/object/" & key,
        "sliceIndex": sliceIndex,
      }, "")

    # --- POST {segment}/{sessionId}/finalize ------------------------------
    if segments.len == 3 and segments[2] == "finalize":
      let sessionId = segments[1]
      var artifactId = ""
      withLock serviceLock:
        artifactId = serviceSessions.getOrDefault(sessionId, "")
      if artifactId.len == 0:
        return (404, "{}", "")
      # REASSEMBLE, the way the deployed CS-M7 service does: `totalSlices`
      # pieces, in index order, concatenated into one downloadable object. The
      # sidecars were uploaded through the same session and are deliberately
      # NOT part of it — which is the whole reason `totalSlices` is not
      # `parts.len` (§9.1).
      let totalSlices = parsedBody{"totalSlices"}.getInt()
      let reassembledKey = segments[0] & "-" & artifactId & "-reassembled"
      var reassembled = ""
      withLock serviceLock:
        let slices = serviceSessionSlices.getOrDefault(
          sessionId, initTable[int, string]())
        for index in 0 ..< totalSlices:
          let key = slices.getOrDefault(index, "")
          if key.len > 0 and serviceObjects.hasKey(key):
            reassembled.add readFile(serviceObjects[key])
      let reassembledPath = serviceBucketDir / reassembledKey
      writeFile(reassembledPath, reassembled)
      withLock serviceLock:
        serviceObjects[reassembledKey] = reassembledPath
        if serviceRecords.hasKey(artifactId):
          serviceRecords[artifactId]["objectKey"] = %reassembledKey
      return (200, $ %*{"artifactId": artifactId}, "")

    # --- POST {segment}/{artifactId}/confirm-upload -----------------------
    if segments.len == 3 and segments[2] == "confirm-upload":
      var known = false
      withLock serviceLock:
        known = serviceRecords.hasKey(segments[1])
      let status = if known: 200 else: 404
      return (status, "{}", "")

    # --- GET {segment}/{artifactId}/download-url --------------------------
    if segments.len == 3 and segments[2] == "download-url":
      let collection = segments[0]
      let artifactId = segments[1]
      if collection == "artifacts" and serviceMode == smLegacy:
        # A service deployed before AS-2 does not route the kind-neutral
        # family at all.  The client must fall through to the kind's alias.
        return (404, "{}", "")
      var record: JsonNode = nil
      withLock serviceLock:
        if serviceRecords.hasKey(artifactId):
          record = serviceRecords[artifactId]
      if record.isNil:
        return (404, "{}", "")
      if collection != "artifacts" and record{"collection"}.getStr() != collection:
        # The artifact is not in the collection that was asked.
        return (404, "{}", "")
      var payload = %*{
        "downloadUrl": "http://127.0.0.1:" & $servicePort & "/object/" &
          record{"objectKey"}.getStr(),
        "expiresAt": "",
      }
      if serviceMode == smArtifactAware and record.hasKey("storedRecord"):
        payload["artifact"] = record["storedRecord"]
        payload["kind"] = record["storedRecord"]{"kind"}
      return (200, $payload, "")

    (404, "{}", "")

proc serviceThread(unused: int) {.thread.} =
  {.cast(gcsafe).}:
    var listener = newSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    servicePort = listener.getLocalAddr()[1].int
    serviceReady = true
    while not serviceStop:
      var client: Socket
      try:
        listener.accept(client)
      except CatchableError:
        break
      try:
        var requestLine = ""
        client.readLine(requestLine)
        let head = requestLine.strip().split(' ')
        if head.len < 2:
          client.close()
          continue
        var contentLength = 0
        var headerLines: seq[string] = @[]
        while true:
          var header = ""
          client.readLine(header)
          let trimmed = header.strip()
          if trimmed.len == 0:
            break
          headerLines.add trimmed
          if trimmed.toLowerAscii().startsWith("content-length:"):
            contentLength = parseInt(trimmed.split(':')[1].strip())
        var body = ""
        if contentLength > 0:
          body = client.recv(contentLength, timeout = 10_000)
        let answer = handleRequest(
          head[0], head[1], headerLines.join("\n"), body)
        var response = "HTTP/1.1 " & $answer.status & " " &
          (if answer.status == 200: "OK" else: "Not Found") & "\c\L" &
          "Content-Length: " & $answer.payload.len & "\c\L" &
          "Connection: close\c\L"
        if answer.etag.len > 0:
          response &= "ETag: " & answer.etag & "\c\L"
        response &= "\c\L" & answer.payload
        client.send(response)
      except CatchableError:
        discard
      finally:
        client.close()
    listener.close()

var serviceWorker: Thread[int]

proc startService(mode: ServiceMode, scratch: string) =
  serviceMode = mode
  serviceBucketDir = scratch / "bucket"
  createDir(serviceBucketDir)
  serviceReady = false
  serviceStop = false
  initLock(serviceLock)
  withLock serviceLock:
    serviceRequests = @[]
    serviceObjects = initTable[string, string]()
    serviceRecords = initTable[string, JsonNode]()
    serviceSessions = initTable[string, string]()
    serviceSessionSlices = initTable[string, Table[int, string]]()
  createThread(serviceWorker, serviceThread, 0)
  var waited = 0
  while not serviceReady and waited < 5_000:
    sleep(5)
    waited += 5
  doAssert serviceReady, "the stand-in sharing service did not start"

proc stopService() =
  serviceStop = true
  # Unblock the accept loop with one final connection.
  try:
    let poke = newSocket()
    poke.connect("127.0.0.1", Port(servicePort))
    poke.send("GET /shutdown HTTP/1.1\c\LContent-Length: 0\c\L\c\L")
    poke.close()
  except CatchableError:
    discard
  joinThread(serviceWorker)

proc recordedPaths(): seq[string] =
  result = @[]
  {.cast(gcsafe).}:
    withLock serviceLock:
      for entry in serviceRequests:
        result.add entry.httpMethod & " " & entry.path

proc recordedBody(httpMethod, pathSuffix: string): JsonNode =
  {.cast(gcsafe).}:
    withLock serviceLock:
      for entry in serviceRequests:
        if entry.httpMethod == httpMethod and entry.path.endsWith(pathSuffix):
          return
            try: parseJson(entry.body) except CatchableError: newJObject()
  newJObject()

proc recordedHeaders(): seq[string] =
  ## The raw header block of every request the service received.
  result = @[]
  {.cast(gcsafe).}:
    withLock serviceLock:
      for entry in serviceRequests:
        result.add entry.headers

proc everythingTheServiceReceived(): string =
  ## Every byte the stand-in service has been handed: request lines, headers,
  ## bodies, and the objects PUT to the object store.
  ##
  ## AS-3 verification item 2 is asserted against **this**, rather than against
  ## a claim about the source, because "the key never reaches the service" is a
  ## statement about what crossed a socket and the only honest way to check it
  ## is to look at what crossed the socket.
  {.cast(gcsafe).}:
    withLock serviceLock:
      for entry in serviceRequests:
        result.add entry.httpMethod
        result.add " "
        result.add entry.path
        result.add "\n"
        result.add entry.headers
        result.add "\n"
        result.add entry.body
        result.add "\n"
      for _, objectPath in serviceObjects:
        try:
          result.add readFile(objectPath)
        except CatchableError:
          discard
        result.add "\n"

proc storedObjectPath(key: string): string =
  {.cast(gcsafe).}:
    withLock serviceLock:
      return serviceObjects.getOrDefault(key, "")

proc rememberStoredRecord(artifactId: string, record: JsonNode) =
  ## Have the service remember the artifact record, the way an AS-2-aware
  ## deployment would after reading it off the upload request.
  {.cast(gcsafe).}:
    withLock serviceLock:
      if serviceRecords.hasKey(artifactId):
        serviceRecords[artifactId]["storedRecord"] = record

# ---------------------------------------------------------------------------
# The suites
# ---------------------------------------------------------------------------

const
  McrSplitDirectory = [
    ## A `ct-mcr record --split` output directory, named file by file, so the
    ## assertions below can state what the pre-AS-2 client sent *for this
    ## directory* rather than restating what the implementation computes.
    "slice_0000.ct",
    "slice_0001.ct",
    "slice_0002.ct",
    "manifest.smnf",
    "analysis.amnf",
  ]
  McrSplitSliceCount = 3   ## the `.ct` pieces the service reassembles
  McrSplitObjectCount = 5  ## every object the session uploads

  SampleRecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  SampleDatasetId = "0194a000-1111-7abc-8def-000000000001"
  SampleTenantId = "tenant-123"
  SampleToken = "bearer-token"

proc scratchRoot(name: string): string =
  result = getTempDir() / ("ct-artifact-store-" & name)
  removeDir(result)
  createDir(result)

proc writePayload(path, contents: string): string =
  createDir(path.parentDir)
  writeFile(path, contents)
  path

proc serviceBaseUrl(): string =
  "http://127.0.0.1:" & $servicePort

suite "AS-2 — a recording round-trips through the generic path":

  test "single-file: upload, then download by artifact id, over real HTTP":
    let scratch = scratchRoot("recording-single")
    startService(smLegacy, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let payload = writePayload(scratch / "trace.zip", "a recorded run, zipped")
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let part = singleFilePart(payload)
    let recording = recordingArtifact(
      recordingId = SampleRecordingId,
      tenantId = SampleTenantId,
      program = "sudoku",
      langName = "LangNoir",
      byteSize = part.byteSize,
      platform = "linux-x86_64",
      recordedAtUnixMs = 1_700_000_000_000'i64)

    let stored = client.storeArtifact(
      SampleTenantId, recording, @[part], SampleToken)
    check stored.error == ""
    check stored.artifact.artifactId == SampleRecordingId
    check stored.serviceAcknowledgedId
    check stored.partsTransferred == 1
    check stored.bytesTransferred == part.byteSize
    # No session was opened, so none is reported. One field holding whichever
    # of two namespaces the path produced is §8 defect 11.
    check stored.session.sessionId == ""

    # The requests that actually crossed the socket — the legacy trace shape,
    # unchanged.
    let paths = recordedPaths()
    check paths[0] ==
      "POST /api/v1/tenants/tenant-123/traces/upload-url"
    check paths[1].startsWith("PUT /object/traces-" & SampleRecordingId)
    check paths[2] ==
      "POST /api/v1/traces/" & SampleRecordingId & "/confirm-upload"

    # …and the bytes really moved.
    let uploadedKey = "traces-" & SampleRecordingId & "-trace.zip"
    check fileExists(serviceBucketDir / uploadedKey)
    check readFile(serviceBucketDir / uploadedKey) ==
      "a recorded run, zipped"

    # Now fetch it back, by id, WITHOUT telling the store what kind it is —
    # which is the situation a share link puts the client in.
    let landing = scratch / "downloaded" / "trace.zip"
    let fetched = client.fetchArtifact(
      SampleRecordingId, SampleToken, landing)
    check fetched.error == ""
    check fetched.kind == some(akRecording)
    check readFile(landing) == "a recorded run, zipped"
    check fetched.bytesTransferred == part.byteSize

    # The kind-neutral collection was asked FIRST and 404'd on this
    # pre-AS-2 service, then the recording kind's alias answered. One code
    # path with a documented degradation, per AS-1 §5.4.
    let afterFetch = recordedPaths()
    check "GET /api/v1/artifacts/" & SampleRecordingId & "/download-url" in
      afterFetch
    check "GET /api/v1/traces/" & SampleRecordingId & "/download-url" in
      afterFetch

  test "sliced: every part crosses the wire, and finalize counts the SLICES":
    let scratch = scratchRoot("recording-sliced")
    startService(smLegacy, scratch)
    defer:
      stopService()
      removeDir(scratch)

    # A real `ct-mcr record --split` output directory, on disk, named file by
    # file — three `.ct` slices plus the two manifests that travel with them.
    # The payload is then described by `collectSliceParts`, the same call
    # `upload.uploadSplitTrace` makes, so this suite exercises the collector
    # rather than a hand-built stand-in for it.
    let slicesDir = scratch / "slices"
    for name in McrSplitDirectory:
      discard writePayload(slicesDir / name, "bytes of " & name)
    let parts = collectSliceParts(
      slicesDir, sliceExtensions = [".ct"],
      sidecarExtensions = [".smnf", ".amnf"])
    check parts.len == McrSplitObjectCount
    check sliceCount(parts) == McrSplitSliceCount

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let recording = recordingArtifact(
      recordingId = SampleRecordingId,
      tenantId = SampleTenantId,
      program = "sudoku",
      langName = "LangNoir",
      byteSize = totalByteSize(parts),
      layout = aplSliceSet,
      partCount = parts.len,
      platform = "linux-x86_64")

    let stored = client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken,
      recordingMode = "hook")
    check stored.error == ""
    check stored.partsTransferred == McrSplitObjectCount
    check stored.session.sessionId.len > 0
    check stored.session.kind == akRecording

    let paths = recordedPaths()
    check paths[0] ==
      "POST /api/v1/tenants/tenant-123/traces/upload-session"
    check paths[^1] ==
      "POST /api/v1/traces/" & stored.session.sessionId & "/finalize"
    # EVERY object asked for its own presigned URL and then PUT its bytes —
    # the manifests included. The fix for the count must never be "stop
    # sending them".
    var putCount = 0
    for entry in paths:
      if entry.startsWith("PUT /object/"):
        inc putCount
    check putCount == McrSplitObjectCount

    for part in parts:
      let key = "traces-" & stored.session.sessionId & "-" & part.name
      check fileExists(serviceBucketDir / key)
      check readFile(serviceBucketDir / key) == readFile(part.localPath)

    # The slices go first, so no slice's index is at or above the slice count,
    # and the sidecars follow in a deterministic order.
    check parts[0].name == "slice_0000.ct"
    check parts[McrSplitSliceCount - 1].name == "slice_0002.ct"
    check parts[McrSplitSliceCount].name == "manifest.smnf"
    check parts[^1].name == "analysis.amnf"

    # The frozen bodies, as they actually went over the socket, compared whole
    # against the literals the pre-AS-2 client sent FOR THIS DIRECTORY.
    let sessionBody = recordedBody("POST", "/traces/upload-session")
    check $sessionBody ==
      """{"platform":"linux-x86_64","recordingMode":"hook"}"""

    # THE number. `totalSlices` is what the deployed CS-M7 `/finalize`
    # reassembles from: 3 pieces, not 5 uploaded objects. Asserted as a literal
    # against the named directory rather than against `parts.len`, which would
    # be a restatement of the implementation and would have gone green on the
    # regression this replaces.
    let finalizeBody = recordedBody("POST", "/finalize")
    check $finalizeBody ==
      """{"totalSlices":3,"totalEvents":0,"platform":"linux-x86_64"}"""
    check finalizeBody["totalSlices"].getInt != McrSplitObjectCount

  test "a recording's platform is what this machine is, not a constant":
    # §8 defect 4. Asserted against a value that differs per host rather than
    # against the literal, so the test says "it was derived" rather than "it
    # happens to equal the old constant on the machine CI runs on".
    let scratch = scratchRoot("recording-platform")
    startService(smLegacy, scratch)
    defer:
      stopService()
      removeDir(scratch)

    var parts = @[ArtifactPart(
      name: "slice_0000.ct",
      localPath: writePayload(scratch / "s" / "slice_0000.ct", "bytes"),
      index: 0, byteSize: 5, role: aprSlice)]
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "p", langName = "LangC", byteSize = 5,
      layout = aplSliceSet, partCount = 1,
      platform = hostArtifactPlatformToken())
    check client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken).error == ""

    let sessionBody = recordedBody("POST", "/traces/upload-session")
    check sessionBody["platform"].getStr == hostArtifactPlatformToken()
    check hostArtifactPlatformToken().len > 0
    check "-" in hostArtifactPlatformToken()

suite "AS-2 — a review dataset round-trips through the generic path":
  ## The same executor, the same procedure, a different artifact description.
  ## This is what DS-7 consumes; nothing in the transport knows what a review
  ## dataset is.

  test "single-file: upload, then download by artifact id, over real HTTP":
    let scratch = scratchRoot("dataset-single")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let payload = writePayload(
      scratch / "review-dataset.zip", "a packed review dataset")
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let part = singleFilePart(payload)
    let dataset = reviewDatasetArtifact(
      artifactId = SampleDatasetId,
      tenantId = SampleTenantId,
      commitSha = "9f1c2d3e4b5a69788796a5b4c3d2e1f009182736",
      baseCommitSha = "1122334455667788990011223344556677889900",
      byteSize = part.byteSize,
      fileCount = 7,
      recordingCount = 2,
      sessionTitle = "parser cleanup")

    let stored = client.storeArtifact(
      SampleTenantId, dataset, @[part], SampleToken)
    check stored.error == ""
    check stored.artifact.artifactId == SampleDatasetId
    check stored.serviceAcknowledgedId

    let paths = recordedPaths()
    check paths[0] ==
      "POST /api/v1/tenants/tenant-123/review-datasets/upload-url"
    check paths[^1] ==
      "POST /api/v1/review-datasets/" & SampleDatasetId & "/confirm-upload"
    # No `traces/` anywhere: the second kind did not acquire the first kind's
    # transport, which is the failure AS-1's migration exists to prevent.
    for entry in paths:
      check "/traces/" notin entry

    # The service now serves the record back, as an AS-2-aware one does.
    rememberStoredRecord(SampleDatasetId, dataset.toJson())

    let landing = scratch / "downloaded" / "dataset.zip"
    let fetched = client.fetchArtifact(
      SampleDatasetId, SampleToken, landing)
    check fetched.error == ""
    check fetched.kind == some(akReviewDataset)
    check readFile(landing) == "a packed review dataset"

    # Verification item 4, end to end: the metadata that went up is the
    # metadata that came back.
    check fetched.hasRecord
    check fetched.record.metadata.commitSha == dataset.metadata.commitSha
    check fetched.record.metadata.baseCommitSha ==
      dataset.metadata.baseCommitSha
    check fetched.record.metadata.fileCount == 7
    check fetched.record.metadata.recordingCount == 2
    check fetched.record.metadata.sessionTitle == "parser cleanup"
    check fetched.record.displayName == "parser cleanup"

    # An AS-2-aware service routes the kind-neutral family, so the very first
    # request answers and no alias is needed.
    check "GET /api/v1/artifacts/" & SampleDatasetId & "/download-url" in
      recordedPaths()

  test "the upload carries the dataset's metadata alongside the payload":
    let scratch = scratchRoot("dataset-metadata")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(
      writePayload(scratch / "d.zip", "dataset bytes"))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let dataset = reviewDatasetArtifact(
      artifactId = SampleDatasetId, tenantId = SampleTenantId,
      commitSha = "abc1234def5678", baseCommitSha = "0011223344",
      byteSize = part.byteSize, fileCount = 3, recordingCount = 1,
      sessionTitle = "a title")
    check client.storeArtifact(
      SampleTenantId, dataset, @[part], SampleToken).error == ""

    let body = recordedBody("POST", "/review-datasets/upload-url")
    check body["artifactId"].getStr == SampleDatasetId
    check body["kind"].getStr == "review-dataset"
    check body["metadata"]["commitSha"].getStr == "abc1234def5678"
    check body["metadata"]["baseCommitSha"].getStr == "0011223344"
    check body["metadata"]["fileCount"].getInt == 3
    check body["metadata"]["recordingCount"].getInt == 1
    check body["metadata"]["sessionTitle"].getStr == "a title"

  test "sliced: a large review dataset takes the identical slice transfer":
    # Verification item 3, on the kind that is not the one slicing was built
    # for. `ArtifactPayloadLayout` sits on the payload rather than the kind so
    # that this works without the transport learning anything.
    let scratch = scratchRoot("dataset-sliced")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    var parts: seq[ArtifactPart] = @[]
    for i in 0 ..< 5:
      let name = "part_" & align($i, 4, '0') & ".bin"
      let path = writePayload(scratch / "parts" / name,
        repeat("x", 1024 + i))
      parts.add ArtifactPart(name: name, localPath: path, index: i,
        byteSize: getFileSize(path), role: aprSlice)

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let dataset = reviewDatasetArtifact(
      artifactId = SampleDatasetId, tenantId = SampleTenantId,
      commitSha = "abc", baseCommitSha = "def",
      byteSize = totalByteSize(parts), fileCount = 900,
      layout = aplSliceSet, partCount = parts.len)

    let stored = client.storeArtifact(
      SampleTenantId, dataset, parts, SampleToken)
    check stored.error == ""
    check stored.partsTransferred == parts.len
    check stored.session.kind == akReviewDataset
    check stored.serviceAcknowledgedId
    check stored.artifact.artifactId == SampleDatasetId

    let paths = recordedPaths()
    check paths[0] ==
      "POST /api/v1/tenants/tenant-123/review-datasets/upload-session"
    check paths[^1] ==
      "POST /api/v1/review-datasets/" & stored.session.sessionId & "/finalize"
    # AS-2's decision on `slice-upload-url` / `finalize`, observed on the
    # socket: a session opened in the review-dataset collection publishes its
    # parts there, not under `traces/`.
    for entry in paths:
      check "/traces/" notin entry

    for part in parts:
      let key = "review-datasets-" & stored.session.sessionId & "-" & part.name
      check fileExists(serviceBucketDir / key)
      check readFile(serviceBucketDir / key) == readFile(part.localPath)

    # The dataset's metadata rode the session body, in full.
    let sessionBody = recordedBody("POST", "/review-datasets/upload-session")
    check sessionBody["artifactId"].getStr == SampleDatasetId
    check sessionBody["kind"].getStr == "review-dataset"
    check sessionBody["metadata"]["fileCount"].getInt == 900

suite "AS-2 — the store refuses rather than guessing":

  test "an id no collection holds is refused, naming it":
    let scratch = scratchRoot("missing")
    startService(smLegacy, scratch)
    defer:
      stopService()
      removeDir(scratch)

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()
    let fetched = client.fetchArtifact(
      SampleDatasetId, SampleToken, scratch / "nothing.zip")
    check fetched.error.len > 0
    check SampleDatasetId in fetched.error
    check fetched.kind.isNone
    check not fileExists(scratch / "nothing.zip")
    # Every declared collection was asked before giving up — the refusal is
    # exhaustive rather than a single guess that missed.
    let paths = recordedPaths()
    check "GET /api/v1/artifacts/" & SampleDatasetId & "/download-url" in paths
    check "GET /api/v1/traces/" & SampleDatasetId & "/download-url" in paths
    check "GET /api/v1/review-datasets/" & SampleDatasetId &
      "/download-url" in paths

  test "a payload that contradicts its descriptor never reaches the socket":
    let scratch = scratchRoot("refused")
    startService(smLegacy, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(writePayload(scratch / "x.zip", "12345"))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    var recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "p", langName = "LangC", byteSize = part.byteSize)
    recording.payload.byteSize = part.byteSize + 100

    let stored = client.storeArtifact(
      SampleTenantId, recording, @[part], SampleToken)
    check stored.error.len > 0
    check recordedPaths().len == 0

# ---------------------------------------------------------------------------
# AS-3 — encryption, over the same socket, for every kind
# ---------------------------------------------------------------------------
#
# The milestone's four verification items have a headless half
# (`src/tests/gui/tests/sharing/artifact_protection_vm_test.nim`, the claims and
# the wire format) and a primitive half (`artifact_crypto_test.nim`, the
# cryptography).  This is the third half, and it is the one that can answer the
# item the other two cannot: **the service never receives the key** is a claim
# about what crossed a socket, so it is asserted against the bytes that crossed
# the socket and against the objects the service ended up holding.

const
  SamplePassword = "correct horse battery staple"
  SampleSecretPayload =
    "a recorded run containing PROJECT-CONFIDENTIAL customer identifiers"

proc encryptedArtifactFor(kind: ArtifactKind, byteSize: int64): Artifact =
  ## The same artifact the unprotected suites use, plus `--encrypt`.
  ##
  ## Exhaustive `case`, so a kind added to the registry is covered by the loops
  ## below rather than silently skipped — the same device the AS-2 suites use.
  case kind
  of akRecording:
    recordingArtifact(
      recordingId = SampleRecordingId,
      tenantId = SampleTenantId,
      program = "sudoku",
      langName = "LangNoir",
      byteSize = byteSize,
      platform = "linux-x86_64",
      protection = apPasswordScryptAes256Gcm)
  of akReviewDataset:
    reviewDatasetArtifact(
      artifactId = SampleDatasetId,
      tenantId = SampleTenantId,
      commitSha = "9f1c2d3e4b5a69788796a5b4c3d2e1f009182736",
      baseCommitSha = "1122334455667788990011223344556677889900",
      byteSize = byteSize,
      fileCount = 7,
      recordingCount = 2,
      sessionTitle = "parser cleanup",
      protection = apPasswordScryptAes256Gcm)

proc uploadedObjectKeyFor(kind: ArtifactKind): string =
  case kind
  of akRecording: "traces-" & SampleRecordingId & "-payload.bin"
  of akReviewDataset: "review-datasets-" & SampleDatasetId & "-payload.bin"

suite "AS-3 — an encrypted artifact is unreadable without the key, on the wire":
  ## Verification items 1 and 3 together: driven by `for kind in ArtifactKind`,
  ## so "the flow is identical across kinds" is not a claim about the source but
  ## the same loop body producing the same conversation for every declared kind.

  test "every kind encrypts through the identical path, and the service holds only ciphertext":
    for kind in ArtifactKind:
      # An explicit `block` per iteration, so the `defer` below is unambiguously
      # scoped to ONE kind: `startService` reuses a single global `Thread`, and
      # starting a second before the first is joined is undefined rather than
      # merely untidy.
      block:
        checkpoint($kind)
        let scratch = scratchRoot("encrypted-" & $kind)
        startService(smArtifactAware, scratch)
        defer:
          stopService()
          removeDir(scratch)

        let payload = writePayload(
          scratch / "payload.bin", SampleSecretPayload)
        var client = initApiClient(serviceBaseUrl())
        defer: client.close()

        let part = singleFilePart(payload)
        let artifact = encryptedArtifactFor(kind, part.byteSize)
        let stored = client.storeArtifact(
          SampleTenantId, artifact, @[part], SampleToken,
          secret = SamplePassword)
        check stored.error == ""
        check stored.protection == apPasswordScryptAes256Gcm

        # The conversation is the SAME conversation.  Encryption wraps the
        # payload, not the request, so a protected upload of either kind makes
        # the three requests an unprotected one makes, to the same collection.
        let paths = recordedPaths()
        let segment = kindSpec(kind).urlSegment
        check paths[0] ==
          "POST /api/v1/tenants/tenant-123/" & segment & "/upload-url"
        check paths[1].startsWith("PUT /object/")
        check paths[2].endsWith("/confirm-upload")
        check paths.len == 3

        # What the service is holding is an envelope, not the payload.
        let objectPath = storedObjectPath(uploadedObjectKeyFor(kind))
        check objectPath.len > 0
        let storedBytes = readFile(objectPath)
        check protectionOfPayload(storedBytes) == apPasswordScryptAes256Gcm
        check SampleSecretPayload notin storedBytes
        check "PROJECT-CONFIDENTIAL" notin storedBytes
        # …at the SHIPPED work factor, pinned on the bytes that actually moved
        # rather than on a default somewhere in the source.
        let opened = openArtifactPart(SamplePassword, storedBytes,
          expectedArtifactId = stored.artifact.artifactId,
          expectedPartIndex = 0)
        check opened.error == ""
        check opened.plaintext == SampleSecretPayload
        check opened.header.envelope.scryptN == 131072
        check opened.header.envelope.cipher == "AES-256-GCM"

        # And the number the service was told is the number it received: an S3
        # presigned PUT rejects a body whose length disagrees with the declared
        # `Content-Length`, so this is a real failure mode and not arithmetic.
        let body = recordedBody("POST", "/" & segment & "/upload-url")
        check body["contentLength"].getBiggestInt == storedBytes.len.int64
        check body["contentLength"].getBiggestInt >
          SampleSecretPayload.len.int64
        check body["contentType"].getStr == ArtifactEnvelopeContentType

        # Now fetch it back through the shipped path, with the password.
        rememberStoredRecord(
          stored.artifact.artifactId, stored.artifact.toJson())
        let landing = scratch / "downloaded" / "payload.bin"
        let fetched = client.fetchArtifact(
          stored.artifact.artifactId, SampleToken, landing,
          secret = SamplePassword)
        check fetched.error == ""
        check fetched.kind == some(kind)
        check fetched.protection == apPasswordScryptAes256Gcm
        check fetched.wasDecrypted
        # The caller gets plaintext without having branched on anything.
        check readFile(landing) == SampleSecretPayload

  test "a sliced encrypted payload seals every part under its own position":
    # Verification item 3 on the layout that was built for one kind: a large
    # artifact takes the slice path, and each part is sealed at its own index —
    # which is what makes the deterministic nonce schedule safe.
    let scratch = scratchRoot("encrypted-sliced")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    var parts: seq[ArtifactPart] = @[]
    for i in 0 ..< 4:
      let name = "part_" & align($i, 4, '0') & ".bin"
      let path = writePayload(scratch / "parts" / name,
        "slice " & $i & " of something private")
      parts.add ArtifactPart(name: name, localPath: path, index: i,
        byteSize: getFileSize(path), role: aprSlice)

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let dataset = reviewDatasetArtifact(
      artifactId = SampleDatasetId, tenantId = SampleTenantId,
      commitSha = "abc", baseCommitSha = "def",
      byteSize = totalByteSize(parts), fileCount = 900,
      layout = aplSliceSet, partCount = parts.len,
      protection = apPasswordScryptAes256Gcm)

    let stored = client.storeArtifact(
      SampleTenantId, dataset, parts, SampleToken, secret = SamplePassword)
    check stored.error == ""
    check stored.partsTransferred == parts.len

    for i in 0 ..< parts.len:
      checkpoint("part " & $i)
      let key = "review-datasets-" & stored.session.sessionId & "-" &
        parts[i].name
      let objectPath = storedObjectPath(key)
      check objectPath.len > 0
      let sealed = readFile(objectPath)
      check protectionOfPayload(sealed) == apPasswordScryptAes256Gcm
      check "of something private" notin sealed
      let opened = openArtifactPart(SamplePassword, sealed,
        expectedArtifactId = SampleDatasetId, expectedPartIndex = i)
      check opened.error == ""
      check opened.plaintext == "slice " & $i & " of something private"
      check opened.header.partCount == parts.len
      check opened.header.partName == parts[i].name
      # A part cannot be served in place of another: the index is in the AAD.
      check openArtifactPart(SamplePassword, sealed,
        expectedArtifactId = SampleDatasetId,
        expectedPartIndex = (i + 1) mod parts.len).error.len > 0

suite "AS-3 — a sliced encrypted artifact comes back, through ct download":
  ## The gap the suite above could not see, and the reason it could not.
  ##
  ## "a sliced encrypted payload seals every part under its own position" opens
  ## each frame *individually, by index*, and never goes through
  ## `fetchArtifact` — so it passed while the product's own download path was
  ## broken for the recording kind's **normal** shape. A sliced upload publishes
  ## one envelope per part and the service reassembles the payload by
  ## concatenating the slices; reading that back as a single frame produced
  ##
  ##     this artifact's encrypted payload failed its integrity check:
  ##     the stored bytes have been altered since they were uploaded
  ##
  ## for an artifact nobody had touched. Every assertion below therefore runs
  ## through `client.fetchArtifact` — the procedure `ct download` calls — and
  ## reads the file it leaves on disk.

  test "a sliced encrypted recording round-trips through fetchArtifact":
    # The shape this milestone is really about: `ct-mcr record --split` output,
    # three `.ct` slices plus two manifests, encrypted. The manifests travel
    # through the session and are NOT part of the reassembly, so this also
    # pins that `sliceCount` and `partCount` are different numbers doing
    # different jobs.
    let scratch = scratchRoot("sliced-encrypted-recording")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let slicesDir = scratch / "slices"
    for name in McrSplitDirectory:
      discard writePayload(slicesDir / name, "bytes of " & name & "; ")
    let parts = collectSliceParts(
      slicesDir, sliceExtensions = [".ct"],
      sidecarExtensions = [".smnf", ".amnf"])
    check parts.len == McrSplitObjectCount
    check sliceCount(parts) == McrSplitSliceCount

    # What a pre-AS-3 client would have downloaded: the slices, concatenated.
    var expectedPayload = ""
    for i in 0 ..< McrSplitSliceCount:
      expectedPayload.add readFile(parts[i].localPath)

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "sudoku", langName = "LangNoir",
      byteSize = totalByteSize(parts), layout = aplSliceSet,
      partCount = parts.len, platform = "linux-x86_64",
      protection = apPasswordScryptAes256Gcm)
    let stored = client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken,
      recordingMode = "hook", secret = SamplePassword)
    check stored.error == ""
    check stored.partsTransferred == McrSplitObjectCount

    # `…/finalize` still counts the SLICES, encrypted or not.
    check recordedBody("POST", "/finalize")["totalSlices"].getInt ==
      McrSplitSliceCount

    # §9.5, observed rather than restated: the recording kind's frozen
    # `…/upload-session` body carries no artifact id, so the client never tells
    # the service which recording this is and the service names the result
    # ITSELF. The download is therefore addressed by the service's id, while
    # the envelope carries the id the client sealed with — which is exactly why
    # `openArtifactPayload` reports that id rather than enforcing it (§8
    # defect 18).
    check stored.serviceAcknowledgedId
    check stored.artifact.artifactId != SampleRecordingId
    rememberStoredRecord(stored.artifact.artifactId, stored.artifact.toJson())

    let landing = scratch / "downloaded" / "recording.ct"
    let fetched = client.fetchArtifact(
      stored.artifact.artifactId, SampleToken, landing,
      secret = SamplePassword)
    check fetched.error == ""
    check fetched.protection == apPasswordScryptAes256Gcm
    check fetched.wasDecrypted
    # The envelope names the id the CLIENT sealed with, and it is reported.
    check fetched.sealedForArtifactId == SampleRecordingId
    # THE assertion: the plaintext the caller gets is the reassembled payload,
    # byte for byte — the same bytes an unencrypted upload of this directory
    # would have produced.
    check readFile(landing) == expectedPayload
    check "bytes of slice_0000.ct" in readFile(landing)
    check "bytes of slice_0002.ct" in readFile(landing)
    # …and the manifests are not in it, because they are not pieces of it.
    check "bytes of manifest.smnf" notin readFile(landing)

  test "a sliced encrypted review dataset round-trips through fetchArtifact":
    # Verification item 3 on the kind slicing was NOT built for, through the
    # product's download path rather than beside it.
    let scratch = scratchRoot("sliced-encrypted-dataset")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    var parts: seq[ArtifactPart] = @[]
    var expectedPayload = ""
    for i in 0 ..< 4:
      let name = "part_" & align($i, 4, '0') & ".bin"
      let contents = "slice " & $i & " of something private; "
      let path = writePayload(scratch / "parts" / name, contents)
      expectedPayload.add contents
      parts.add ArtifactPart(name: name, localPath: path, index: i,
        byteSize: getFileSize(path), role: aprSlice)

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let dataset = reviewDatasetArtifact(
      artifactId = SampleDatasetId, tenantId = SampleTenantId,
      commitSha = "abc", baseCommitSha = "def",
      byteSize = totalByteSize(parts), fileCount = 900,
      layout = aplSliceSet, partCount = parts.len,
      protection = apPasswordScryptAes256Gcm)
    let stored = client.storeArtifact(
      SampleTenantId, dataset, parts, SampleToken, secret = SamplePassword)
    check stored.error == ""
    rememberStoredRecord(stored.artifact.artifactId, stored.artifact.toJson())

    let landing = scratch / "downloaded" / "dataset.zip"
    let fetched = client.fetchArtifact(
      stored.artifact.artifactId, SampleToken, landing,
      secret = SamplePassword)
    check fetched.error == ""
    check fetched.wasDecrypted
    check readFile(landing) == expectedPayload

  test "a sliced UNENCRYPTED artifact still round-trips through fetchArtifact":
    # The control, and it was untested before AS-3 too: the stand-in service
    # left a session upload with no downloadable object at all, so nothing
    # exercised the reassembled download in either direction.
    let scratch = scratchRoot("sliced-plain")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let slicesDir = scratch / "slices"
    for name in McrSplitDirectory:
      discard writePayload(slicesDir / name, "bytes of " & name & "; ")
    let parts = collectSliceParts(
      slicesDir, sliceExtensions = [".ct"],
      sidecarExtensions = [".smnf", ".amnf"])
    var expectedPayload = ""
    for i in 0 ..< McrSplitSliceCount:
      expectedPayload.add readFile(parts[i].localPath)

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()
    let recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "sudoku", langName = "LangNoir",
      byteSize = totalByteSize(parts), layout = aplSliceSet,
      partCount = parts.len, platform = "linux-x86_64")
    let stored = client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken, recordingMode = "hook")
    check stored.error == ""
    rememberStoredRecord(stored.artifact.artifactId, stored.artifact.toJson())

    let landing = scratch / "downloaded" / "recording.ct"
    let fetched = client.fetchArtifact(
      stored.artifact.artifactId, SampleToken, landing)
    check fetched.error == ""
    check fetched.protection == apNone
    check not fetched.wasDecrypted
    check readFile(landing) == expectedPayload

  test "a WITHHELD slice is refused, not reassembled short":
    # §10.3's sentence, made true rather than aspirational. Every surviving
    # frame is individually perfect — right artifact, right password, valid
    # tag — so only the authenticated slice COUNT distinguishes "the payload"
    # from "most of the payload".
    let scratch = scratchRoot("withheld-slice")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let slicesDir = scratch / "slices"
    for name in ["slice_0000.ct", "slice_0001.ct", "slice_0002.ct"]:
      discard writePayload(slicesDir / name, "bytes of " & name & "; ")
    let parts = collectSliceParts(slicesDir, sliceExtensions = [".ct"])

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()
    let recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "sudoku", langName = "LangNoir",
      byteSize = totalByteSize(parts), layout = aplSliceSet,
      partCount = parts.len, platform = "linux-x86_64",
      protection = apPasswordScryptAes256Gcm)
    let stored = client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken,
      recordingMode = "hook", secret = SamplePassword)
    check stored.error == ""

    # Drop the LAST slice from the stored reassembly — the case a
    # contiguous-index check alone cannot catch, because what is left is a
    # perfectly well-formed shorter payload.
    rememberStoredRecord(stored.artifact.artifactId, stored.artifact.toJson())
    let objectPath = storedObjectPath(
      "traces-" & stored.artifact.artifactId & "-reassembled")
    check objectPath.len > 0
    let whole = readFile(objectPath)
    let firstTwo = decodeEnvelopeFrame(whole, decodeEnvelopeFrame(whole).nextOffset)
    writeFile(objectPath, whole[0 ..< firstTwo.nextOffset])

    let fetched = client.fetchArtifact(
      stored.artifact.artifactId, SampleToken,
      scratch / "downloaded" / "recording.ct", secret = SamplePassword)
    check fetched.error.len > 0
    check "incomplete" in fetched.error
    check "3 slice(s)" in fetched.error
    check "2 arrived" in fetched.error
    check not fetched.wasDecrypted
    check not fileExists(scratch / "downloaded" / "recording.ct")

  test "a MIX-AND-MATCH reassembly from two uploads is refused":
    # The residual each frame's self-containment leaves: nothing in the AEAD
    # alone binds a part to a particular *sealing operation*, and for the
    # recording kind `artifactId == recordingId`, which is stable across
    # re-uploads. So a service holding two uploads of one recording could
    # interleave their slices and every tag would verify — the user really did
    # seal all of them. Requiring ONE envelope across the payload is the
    # binding the frames do not have.
    let scratch = scratchRoot("frankenstein")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let slicesDir = scratch / "slices"
    for name in ["slice_0000.ct", "slice_0001.ct"]:
      discard writePayload(slicesDir / name, "bytes of " & name & "; ")
    let parts = collectSliceParts(slicesDir, sliceExtensions = [".ct"])

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()
    let recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "sudoku", langName = "LangNoir",
      byteSize = totalByteSize(parts), layout = aplSliceSet,
      partCount = parts.len, platform = "linux-x86_64",
      protection = apPasswordScryptAes256Gcm)

    # Upload the same recording twice. Both are genuine; the second overwrites
    # the first's reassembled object, as a re-upload would.
    let firstStore = client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken,
      recordingMode = "hook", secret = SamplePassword)
    check firstStore.error == ""
    let firstUpload = readFile(storedObjectPath(
      "traces-" & firstStore.artifact.artifactId & "-reassembled"))

    let secondStore = client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken,
      recordingMode = "hook", secret = SamplePassword)
    check secondStore.error == ""
    rememberStoredRecord(
      secondStore.artifact.artifactId, secondStore.artifact.toJson())
    let objectPath = storedObjectPath(
      "traces-" & secondStore.artifact.artifactId & "-reassembled")
    let secondUpload = readFile(objectPath)
    # Two uploads of the same bytes under the same password are different
    # ciphertext — a fresh content key each time — which is what makes the
    # substitution detectable at all.
    check firstUpload != secondUpload

    # Slice 0 from the first upload, slice 1 from the second. Both genuine,
    # both perfectly authenticated, and together they are not an artifact.
    let firstFrameEnd = decodeEnvelopeFrame(firstUpload).nextOffset
    let secondFrameStart = decodeEnvelopeFrame(secondUpload).nextOffset
    writeFile(objectPath,
      firstUpload[0 ..< firstFrameEnd] & secondUpload[secondFrameStart .. ^1])

    let fetched = client.fetchArtifact(
      secondStore.artifact.artifactId, SampleToken,
      scratch / "downloaded" / "recording.ct", secret = SamplePassword)
    check fetched.error.len > 0
    check "different upload" in fetched.error
    check not fetched.wasDecrypted

  test "the password is stretched ONCE for a whole sliced payload":
    # Not a micro-optimisation: scrypt at the shipped work factor is ~0.3 s and
    # 128 MiB, so per-frame derivation would make a twenty-slice recording take
    # six seconds and look like a hang. The content key is shared across the
    # payload, so one derivation serves it.
    let scratch = scratchRoot("one-derivation")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let slicesDir = scratch / "slices"
    for i in 0 ..< 6:
      discard writePayload(
        slicesDir / ("slice_" & align($i, 4, '0') & ".ct"), "bytes; ")
    let parts = collectSliceParts(slicesDir, sliceExtensions = [".ct"])
    check parts.len == 6

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()
    let recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "sudoku", langName = "LangNoir",
      byteSize = totalByteSize(parts), layout = aplSliceSet,
      partCount = parts.len, platform = "linux-x86_64",
      protection = apPasswordScryptAes256Gcm)
    let stored = client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken,
      recordingMode = "hook", secret = SamplePassword)
    check stored.error == ""

    # Every frame carries the SAME salt and wrapped key, which is both what
    # makes one derivation sufficient and what `sameSealingOperation` checks.
    let whole = readFile(storedObjectPath(
      "traces-" & stored.artifact.artifactId & "-reassembled"))
    var offset = 0
    var seen = 0
    var firstSalt = ""
    while offset < whole.len:
      let frame = decodeEnvelopeFrame(whole, offset)
      check frame.error == ""
      check frame.header.partIndex == seen
      check frame.header.envelope.sliceCount == 6
      check frame.header.partCount == 6
      if seen == 0:
        firstSalt = frame.header.envelope.salt
      else:
        check frame.header.envelope.salt == firstSalt
      inc seen
      offset = frame.nextOffset
    check seen == 6

suite "AS-3 — the service never receives the key":
  ## Verification item 2, as an observable property of the conversation.
  ##
  ## The stand-in service records every request line, every header block, every
  ## body and every object it is asked to store.  The assertions below are
  ## against that recording, not against a reading of the source: "we do not
  ## send it" is exactly the kind of claim that is true of the code as written
  ## and false of the code as linked.

  test "nothing the service received contains the password or the plaintext":
    for kind in ArtifactKind:
      block:
        checkpoint($kind)
        let scratch = scratchRoot("no-key-" & $kind)
        startService(smArtifactAware, scratch)
        defer:
          stopService()
          removeDir(scratch)

        let part = singleFilePart(
          writePayload(scratch / "payload.bin", SampleSecretPayload))
        var client = initApiClient(serviceBaseUrl())
        defer: client.close()

        let stored = client.storeArtifact(
          SampleTenantId, encryptedArtifactFor(kind, part.byteSize),
          @[part], SampleToken, secret = SamplePassword)
        check stored.error == ""

        let received = everythingTheServiceReceived()
        check received.len > 0
        # The password, in every spelling somebody might have leaked it in.
        check SamplePassword notin received
        check "correct horse" notin received
        check "battery staple" notin received
        check encode(SamplePassword) notin received
        # And the plaintext, which is the other thing "encrypted" must mean.
        check SampleSecretPayload notin received
        check "PROJECT-CONFIDENTIAL" notin received

        # The operational statement of the same property: a party holding
        # EVERYTHING the service was handed, and no password, cannot open it.
        let storedBytes = readFile(storedObjectPath(uploadedObjectKeyFor(kind)))
        check openArtifactPart("", storedBytes).error.len > 0
        check openArtifactPart("some other password", storedBytes).error.len > 0
        check openArtifactPart(SamplePassword, storedBytes).plaintext ==
          SampleSecretPayload

  test "the password is not in a header, which is where it would hide":
    let scratch = scratchRoot("no-key-headers")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(
      writePayload(scratch / "payload.bin", SampleSecretPayload))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()
    check client.storeArtifact(
      SampleTenantId, encryptedArtifactFor(akReviewDataset, part.byteSize),
      @[part], SampleToken, secret = SamplePassword).error == ""

    # Asserted separately from the bulk check above so that a future change
    # which stopped recording headers cannot make the bulk check vacuously
    # pass. Two guards, because "no password in the headers" is trivially true
    # of no headers at all: one counts the blocks, and one finds a secret the
    # service IS meant to receive.
    #
    # Matched case-insensitively on the name: Nim's `httpclient` lowercases
    # header names on the way out, so what actually crosses the socket is
    # `authorization: Bearer …` and not the spelling `bearerHeaders` writes.
    var sawBearerToken = false
    var headerBlocks = 0
    for headers in recordedHeaders():
      inc headerBlocks
      check SamplePassword notin headers
      if "authorization:" in headers.toLowerAscii() and SampleToken in headers:
        sawBearerToken = true
    # upload-url, the PUT, and confirm-upload.
    check headerBlocks >= 3
    check sawBearerToken

  test "an encrypted upload refuses to start without the password":
    # The other direction, and the more dangerous one: a caller that declared
    # protection and supplied no secret must NOT fall back to an unencrypted
    # upload.  Asserted on the socket — nothing crossed it.
    let scratch = scratchRoot("no-key-refused")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(
      writePayload(scratch / "payload.bin", SampleSecretPayload))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let stored = client.storeArtifact(
      SampleTenantId, encryptedArtifactFor(akReviewDataset, part.byteSize),
      @[part], SampleToken)
    check stored.error.len > 0
    check "no password was supplied" in stored.error
    check recordedPaths().len == 0

  test "a password with no protection is refused, not silently ignored":
    # The worst outcome this milestone can produce is a user who believes they
    # encrypted something and did not.  So a secret supplied for an artifact
    # that declares `apNone` stops the upload rather than being dropped.
    let scratch = scratchRoot("no-key-mismatch")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(
      writePayload(scratch / "payload.bin", SampleSecretPayload))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let unprotected = reviewDatasetArtifact(
      artifactId = SampleDatasetId, tenantId = SampleTenantId,
      commitSha = "abc", baseCommitSha = "def", byteSize = part.byteSize)
    let stored = client.storeArtifact(
      SampleTenantId, unprotected, @[part], SampleToken,
      secret = SamplePassword)
    check stored.error.len > 0
    check "would upload the payload unencrypted" in stored.error
    check recordedPaths().len == 0

suite "AS-3 — what metadata remains visible is exactly what is documented":
  ## Verification item 4, compared against the documented list rather than
  ## against a re-reading of the implementation.  This is the half that catches
  ## the documentation drifting away from the wire: if a kind's metadata grows a
  ## key, the assertion fails until `serviceVisibleMetadataFields` says so — and
  ## that list is what the CLI prints to the user before they choose to encrypt.

  test "a review dataset's visible metadata is the documented set, exactly":
    let scratch = scratchRoot("visible-dataset")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(
      writePayload(scratch / "payload.bin", SampleSecretPayload))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()
    check client.storeArtifact(
      SampleTenantId, encryptedArtifactFor(akReviewDataset, part.byteSize),
      @[part], SampleToken, secret = SamplePassword).error == ""

    let body = recordedBody("POST", "/review-datasets/upload-url")
    var visible: seq[string] = @[]
    for key, _ in body["metadata"].pairs:
      visible.add key
    check visible == serviceVisibleMetadataFields(akReviewDataset)
    # And the values really are in the clear — the point of documenting it.
    check body["metadata"]["commitSha"].getStr ==
      "9f1c2d3e4b5a69788796a5b4c3d2e1f009182736"
    check body["metadata"]["sessionTitle"].getStr == "parser cleanup"

  test "a recording's visible metadata is the documented set, exactly":
    let scratch = scratchRoot("visible-recording")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    var parts = @[ArtifactPart(
      name: "slice_0000.ct",
      localPath: writePayload(scratch / "s" / "slice_0000.ct", "bytes"),
      index: 0, byteSize: 5, role: aprSlice)]
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    var recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "sudoku", langName = "LangNoir", byteSize = 5,
      layout = aplSliceSet, partCount = 1, platform = "linux-x86_64",
      protection = apPasswordScryptAes256Gcm)
    check client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken,
      recordingMode = "hook", secret = SamplePassword).error == ""

    # The recording kind's frozen bodies are a confidentiality ADVANTAGE: they
    # have room for two fields and no more, so the program name, the language
    # and the record-start time do not travel at all — encrypted or not.
    let received = everythingTheServiceReceived()
    for absent in ["sudoku", "LangNoir", "program", "recordedAtUnixMs"]:
      checkpoint(absent)
      check absent notin received
    check "recordingId" in serviceVisibleMetadataFields(akRecording)
    check "platform" in serviceVisibleMetadataFields(akRecording)
    check SampleRecordingId in received
    check "linux-x86_64" in received

suite "AS-3 — a stored copy that has been altered is refused":

  test "flipping a byte in the stored object fails the download, loudly":
    let scratch = scratchRoot("tampered")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(
      writePayload(scratch / "payload.bin", SampleSecretPayload))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let stored = client.storeArtifact(
      SampleTenantId, encryptedArtifactFor(akReviewDataset, part.byteSize),
      @[part], SampleToken, secret = SamplePassword)
    check stored.error == ""
    rememberStoredRecord(stored.artifact.artifactId, stored.artifact.toJson())

    # Rewrite the bytes the way an attacker with access to the bucket would.
    let objectPath = storedObjectPath(uploadedObjectKeyFor(akReviewDataset))
    var sealed = readFile(objectPath)
    let target = sealed.len - ArtifactEnvelopeTagBytes - 4
    sealed[target] = chr(int(uint8(sealed[target])) xor 0x40)
    writeFile(objectPath, sealed)

    let landing = scratch / "downloaded" / "payload.bin"
    let fetched = client.fetchArtifact(
      stored.artifact.artifactId, SampleToken, landing,
      secret = SamplePassword)
    check fetched.error.len > 0
    check "altered" in fetched.error
    check not fetched.wasDecrypted
    # Nothing is left behind for a caller to unpack by mistake.
    check not fileExists(landing)

  test "a wrong password fails cleanly, and says CodeTracer cannot recover it":
    let scratch = scratchRoot("wrong-password")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(
      writePayload(scratch / "payload.bin", SampleSecretPayload))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let stored = client.storeArtifact(
      SampleTenantId, encryptedArtifactFor(akReviewDataset, part.byteSize),
      @[part], SampleToken, secret = SamplePassword)
    check stored.error == ""
    rememberStoredRecord(stored.artifact.artifactId, stored.artifact.toJson())

    let wrong = client.fetchArtifact(
      stored.artifact.artifactId, SampleToken,
      scratch / "downloaded" / "payload.bin",
      secret = "not the right password")
    check wrong.error.len > 0
    check "wrong password" in wrong.error
    check not wrong.wasDecrypted
    check not fileExists(scratch / "downloaded" / "payload.bin")

    # …and no password at all says so, and says the thing a user most needs to
    # hear at that moment: nobody can get it back for them.
    let withoutPassword = client.fetchArtifact(
      stored.artifact.artifactId, SampleToken,
      scratch / "downloaded2" / "payload.bin")
    check withoutPassword.error.len > 0
    check "is encrypted" in withoutPassword.error
    check "cannot recover it" in withoutPassword.error
    check withoutPassword.protection == apPasswordScryptAes256Gcm

suite "AS-3 — an old-format artifact still downloads":
  ## The compatibility item.  Everything stored before this milestone is an
  ## unprotected payload with no envelope, and the download path must not have
  ## acquired a prompt, a failure or a behaviour change for any of it.

  test "an unprotected artifact downloads with no password and no envelope":
    for kind in ArtifactKind:
      block:
        checkpoint($kind)
        let scratch = scratchRoot("old-format-" & $kind)
        startService(smArtifactAware, scratch)
        defer:
          stopService()
          removeDir(scratch)

        let payload = writePayload(scratch / "payload.bin", "a plain old zip")
        var client = initApiClient(serviceBaseUrl())
        defer: client.close()

        let part = singleFilePart(payload)
        let artifact =
          case kind
          of akRecording:
            recordingArtifact(
              recordingId = SampleRecordingId, tenantId = SampleTenantId,
              program = "sudoku", langName = "LangNoir",
              byteSize = part.byteSize, platform = "linux-x86_64")
          of akReviewDataset:
            reviewDatasetArtifact(
              artifactId = SampleDatasetId, tenantId = SampleTenantId,
              commitSha = "abc", baseCommitSha = "def",
              byteSize = part.byteSize)

        let stored = client.storeArtifact(
          SampleTenantId, artifact, @[part], SampleToken)
        check stored.error == ""
        check stored.protection == apNone
        rememberStoredRecord(stored.artifact.artifactId, artifact.toJson())

        # The stored bytes are the payload, unchanged and unwrapped — which is
        # the whole of "nothing on the encryption path runs".
        let objectPath = storedObjectPath(uploadedObjectKeyFor(kind))
        check readFile(objectPath) == "a plain old zip"
        check protectionOfPayload(readFile(objectPath)) == apNone
        # …and the declared content type is still the kind's own, byte for byte.
        let body = recordedBody(
          "POST", "/" & kindSpec(kind).urlSegment & "/upload-url")
        check body["contentType"].getStr == "application/zip"
        check body["contentLength"].getBiggestInt ==
          "a plain old zip".len.int64

        let landing = scratch / "downloaded" / "payload.bin"
        let fetched = client.fetchArtifact(
          stored.artifact.artifactId, SampleToken, landing)
        check fetched.error == ""
        check fetched.protection == apNone
        check not fetched.wasDecrypted
        check readFile(landing) == "a plain old zip"

  test "a password supplied for an unencrypted artifact changes nothing":
    # Somebody who habitually passes `--password-file` should not be told their
    # download failed because the artifact did not need one.
    let scratch = scratchRoot("old-format-with-password")
    startService(smArtifactAware, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let part = singleFilePart(
      writePayload(scratch / "payload.bin", "a plain old zip"))
    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let stored = client.storeArtifact(
      SampleTenantId,
      reviewDatasetArtifact(
        artifactId = SampleDatasetId, tenantId = SampleTenantId,
        commitSha = "abc", baseCommitSha = "def", byteSize = part.byteSize),
      @[part], SampleToken)
    check stored.error == ""
    rememberStoredRecord(stored.artifact.artifactId, stored.artifact.toJson())

    let landing = scratch / "downloaded" / "payload.bin"
    let fetched = client.fetchArtifact(
      stored.artifact.artifactId, SampleToken, landing,
      secret = SamplePassword)
    check fetched.error == ""
    check not fetched.wasDecrypted
    check readFile(landing) == "a plain old zip"

suite "AS-3 — the executor runs the planner's steps, on the socket":
  ## The change AS-3 had to make **before** adding encryption, and the test that
  ## keeps it made.
  ##
  ## Until AS-3, `artifact_transfer.nim`'s `uploadOpenStep` / `uploadPartSteps`
  ## / `uploadCompletionStep` were consumed only by the ViewModel suite:
  ## `storeArtifact` re-derived the same conversation itself, one `api_client`
  ## call at a time.  The proof was a mutation — making the planner stop
  ## publishing sidecars left this whole file green, and the executor had to be
  ## mutated separately to make it red.
  ##
  ## The assertions below are what turns that mutation red.  Each one states a
  ## decision that lives in the PLANNER and is observable only on the socket, so
  ## an executor that stopped following the plan would break it.

  test "the sliced conversation on the socket is the planner's, step for step":
    let scratch = scratchRoot("planner-coupling")
    startService(smLegacy, scratch)
    defer:
      stopService()
      removeDir(scratch)

    let slicesDir = scratch / "slices"
    for name in McrSplitDirectory:
      discard writePayload(slicesDir / name, "bytes of " & name)
    let parts = collectSliceParts(
      slicesDir, sliceExtensions = [".ct"],
      sidecarExtensions = [".smnf", ".amnf"])

    var client = initApiClient(serviceBaseUrl())
    defer: client.close()

    let recording = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "sudoku", langName = "LangNoir",
      byteSize = totalByteSize(parts), layout = aplSliceSet,
      partCount = parts.len, platform = "linux-x86_64")
    let stored = client.storeArtifact(
      SampleTenantId, recording, parts, SampleToken, recordingMode = "hook")
    check stored.error == ""

    # The whole conversation, as one list, compared against what the PLANNER
    # says it should be — `describeStep` on the plan, resolved against the
    # session the service actually issued.  A `PUT` has no planned URL (it is
    # presigned at run time), so those rows are compared by part name, which is
    # exactly the decision — which parts, in which order — that the mutation
    # this test exists for would change.
    let planned = planArtifactUpload(
      recording, parts, client.baseApiUrl, SampleTenantId,
      recordingMode = "hook")
    check planned.error == ""
    let plannedSteps = uploadSteps(planned.plan, stored.session)

    let actual = recordedPaths()
    check actual.len == plannedSteps.len
    # Bounded by both, so a length mismatch reports as the failed length check
    # above rather than as an index-out-of-range crash that hides it.
    for i in 0 ..< min(plannedSteps.len, actual.len):
      checkpoint($i & ": " & describeStep(plannedSteps[i]))
      case plannedSteps[i].kind
      of atsPutPart:
        check actual[i].startsWith("PUT /object/")
        check actual[i].endsWith(plannedSteps[i].part.name)
      else:
        check actual[i] ==
          "POST " & plannedSteps[i].urlPath.replace(serviceBaseUrl(), "")

    # …and the bodies too, for the two the planner fully determines.
    check $recordedBody("POST", "/traces/upload-session") ==
      $plannedSteps[0].body
    check $recordedBody("POST", "/finalize") == $plannedSteps[^1].body
