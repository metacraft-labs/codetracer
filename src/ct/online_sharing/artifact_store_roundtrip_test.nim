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

import std/[algorithm, json, locks, net, options, os, strutils, tables,
  unittest]

import artifact_store, api_client

# ---------------------------------------------------------------------------
# A stand-in for the sharing service
# ---------------------------------------------------------------------------

type
  RecordedRequest = object
    httpMethod: string
    path: string
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

proc handleRequest(httpMethod, path, body: string):
    tuple[status: int, payload: string, etag: string] {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock serviceLock:
      serviceRequests.add RecordedRequest(
        httpMethod: httpMethod, path: path, body: body)

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
      return (200, $ %*{
        "uploadUrl": "http://127.0.0.1:" & $servicePort & "/object/" & key,
        "sliceIndex": parsedBody{"sliceIndex"}.getInt(),
      }, "")

    # --- POST {segment}/{sessionId}/finalize ------------------------------
    if segments.len == 3 and segments[2] == "finalize":
      let sessionId = segments[1]
      var artifactId = ""
      withLock serviceLock:
        artifactId = serviceSessions.getOrDefault(sessionId, "")
      if artifactId.len == 0:
        return (404, "{}", "")
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
        while true:
          var header = ""
          client.readLine(header)
          let trimmed = header.strip()
          if trimmed.len == 0:
            break
          if trimmed.toLowerAscii().startsWith("content-length:"):
            contentLength = parseInt(trimmed.split(':')[1].strip())
        var body = ""
        if contentLength > 0:
          body = client.recv(contentLength, timeout = 10_000)
        let answer = handleRequest(head[0], head[1], body)
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
