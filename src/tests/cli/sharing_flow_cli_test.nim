## AS-4 — the sharing flow, in the running product.
##
## Spec: `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-4, whose
## fourth deliverable is "verified by launching the product and looking at it,
## not by reading source — four milestones in the preceding campaign were
## blocked for exactly that, and two were shipped bugs."
##
## ## Why this exists beside the ViewModel suite
##
## `src/tests/gui/tests/sharing/artifact_sharing_vm_test.nim` asserts the
## surface as a pure function: exhaustively, on both Nim backends, and without
## a socket.  That is the right shape for the *claims*, and it is not evidence
## that a user typing `ct upload` sees them.  AS-3 proved the gap twice inside
## one milestone: every suite was green while `--password-file -` supplied no
## password at all, and while a message named a `--password` flag that does not
## exist.  Both were found by running the shipped binary.
##
## So the subject here is `src/build-debug/bin/ct`, run as a user runs it,
## against a stand-in for the sharing service on a real loopback socket, with a
## scratch `HOME` so the real trace index and the real config are untouched.
##
## ## On mocking, per the workspace policy
##
## Nothing of CodeTracer's is mocked: the binary, the argument parser, the
## classifier, the transfer, the file I/O and the rendering are all shipped
## code.  Two things are substituted, and both are counterparties rather than
## seams:
##
## * **the sharing service** — the real one is a production SaaS holding other
##   people's recordings, and a test that uploads to it is a test that must
##   never run (which is exactly how `online_sharing_test.nim` rotted).  The
##   boundary stays real: a socket, HTTP/1.1 framing, presigned PUTs and GETs.
## * **the local recording row** — one row is written into the scratch trace
##   index with the `sqlite3` CLI, because producing a real one means recording
##   a real program with a real recorder, which is `record_dispatch_e2e_test`'s
##   job and not this suite's.  What is being asserted here is the *sharing
##   surface* over an artifact of the recording kind, and the row is the
##   cheapest honest way to have one.  A missing `sqlite3` fails loudly rather
##   than skipping — it is in the dev shell (`nix/shells/ci-base.nix`), and
##   "the recording arm was silently not exercised" is the condition this file
##   exists to end.
##
## The recording's **container** is not substituted: it is written by the
## production `MultiStreamTraceWriter` (`m1_ctfs_fixture`), because `ct
## download` of a recording runs `importTrace`, which reads `meta.dat` out of
## it.  The first version of this suite used fake bytes — enough to *upload* a
## recording and not enough to download one, which is precisely how the whole
## `assReceived` path for `akRecording` came to be untested.
##
## Runs in `just test-cli-record`, which globs `src/tests/cli`.

import std/[algorithm, json, locks, net, os, osproc, strutils, tables,
  unittest]

import results
# A REAL CTFS container, written by the production writer
# (`codetracer-trace-format-nim`'s `MultiStreamTraceWriter`, the same one the
# native and Ruby recorders use). Reused rather than re-implemented: `ct
# download` of a recording runs `importTrace`, which reads `meta.dat` out of
# the container, so a hand-made file cannot reach the received view at all —
# which is exactly why the recording download path had never been exercised.
import ../../ct_test/incremental/m1_ctfs_fixture

const
  CtBinary = "src/build-debug/bin/ct"
  ServiceTenantId = "0194a000-2222-7abc-8def-000000000002"
    ## A GUID, so `resolveTenantId` returns it directly and the upload path
    ## needs no `/tenants` round trip.  The download path does need one, and
    ## the stand-in serves it.
  ServiceToken = "test-bearer-token"
  SampleRecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  SlicedRecordingId = "01949fcc-7d92-7e9c-8ccc-dddddddddddd"
  SamplePassword = "correct horse battery staple"

# ---------------------------------------------------------------------------
# A stand-in for the sharing service
# ---------------------------------------------------------------------------

type
  RecordedRequest = object
    httpMethod: string
    path: string
    body: string

var
  serviceLock: Lock
  serviceRequests {.guard: serviceLock.}: seq[RecordedRequest]
  serviceRecords {.guard: serviceLock.}: Table[string, JsonNode]
  serviceSessions {.guard: serviceLock.}: Table[string, string]
    ## session id → the artifact id the service associates with it
  serviceSessionSlices {.guard: serviceLock.}: Table[string, Table[int, string]]
    ## session id → slice index → the object key that slice was PUT to
  serviceNextId: int
  servicePort: int
  serviceReady: bool
  serviceStop: bool
  serviceBucketDir: string

proc apiSegments(path: string): seq[string] =
  let trimmed = path.split('?')[0].strip(chars = {'/'})
  let parts = trimmed.split('/')
  if parts.len >= 2 and parts[0] == "api" and parts[1] == "v1":
    return parts[2 .. ^1]
  @[]

proc handleRequest(httpMethod, path, body: string):
    tuple[status: int, payload: string, etag: string] {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock serviceLock:
      serviceRequests.add RecordedRequest(
        httpMethod: httpMethod, path: path, body: body)

    if path.startsWith("/object/"):
      let key = path[len("/object/") .. ^1]
      let objectPath = serviceBucketDir / key
      if httpMethod == "PUT":
        writeFile(objectPath, body)
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

    if segments == @["tenants"]:
      return (200, $ %*{"tenants": [{
        "tenantId": ServiceTenantId,
        "displayName": "Acme",
        "slug": "acme",
        "role": "member"}]}, "")

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
      if parsedBody.hasKey("access"):
        record["access"] = parsedBody["access"]
      withLock serviceLock:
        serviceRecords[artifactId] = record
      let echoed =
        if parsedBody.hasKey("recordingId"): "recordingId" else: "artifactId"
      return (200, $ %*{
        echoed: artifactId,
        "uploadUrl": "http://127.0.0.1:" & $servicePort & "/object/" & key,
        "expiresAt": "",
      }, "")

    # --- the slice-set conversation ---------------------------------------
    #
    # Modelled on the deployed CS-M7 service, and present so the SLICED
    # recording upload — the normal shape for an MCR recording, and the one
    # whose narration is recording-only — actually runs through the shipped
    # binary. Without these three endpoints the client falls back to the
    # single-file zip path and the sliced narration is never emitted, which is
    # how it came to be unexercised.
    if segments.len == 4 and segments[0] == "tenants" and
        segments[3] == "upload-session":
      let collection = segments[2]
      inc serviceNextId
      let sessionId = "0194a000-2222-7abc-8def-" & align($serviceNextId, 12, '0')
      # The recording kind's frozen session body carries no artifact id, so the
      # service names the result itself — exactly as the real one does.
      var artifactId = parsedBody{"artifactId"}.getStr()
      let clientNamedIt = artifactId.len > 0
      if not clientNamedIt:
        inc serviceNextId
        artifactId = "0194a000-3333-7abc-8def-" & align($serviceNextId, 12, '0')
      var record = %*{
        "artifactId": artifactId,
        "collection": collection,
        "objectKey": collection & "-" & artifactId & "-reassembled",
      }
      if parsedBody.hasKey("kind"):
        record["kind"] = parsedBody["kind"]
      withLock serviceLock:
        serviceSessions[sessionId] = artifactId
        serviceSessionSlices[sessionId] = initTable[int, string]()
        serviceRecords[artifactId] = record
      var payload = %*{
        "sessionId": sessionId,
        "s3KeyPrefix": collection & "/" & sessionId & "/",
      }
      if clientNamedIt:
        payload["artifactId"] = %artifactId
      return (200, $payload, "")

    if segments.len == 3 and segments[2] == "slice-upload-url":
      let sessionId = segments[1]
      let key = segments[0] & "-" & sessionId & "-" &
        parsedBody{"fileName"}.getStr("part")
      withLock serviceLock:
        if not serviceSessionSlices.hasKey(sessionId):
          serviceSessionSlices[sessionId] = initTable[int, string]()
        serviceSessionSlices[sessionId][parsedBody{"sliceIndex"}.getInt()] = key
      return (200, $ %*{
        "uploadUrl": "http://127.0.0.1:" & $servicePort & "/object/" & key,
        "sliceIndex": parsedBody{"sliceIndex"}.getInt(),
      }, "")

    if segments.len == 3 and segments[2] == "finalize":
      let sessionId = segments[1]
      var artifactId = ""
      withLock serviceLock:
        artifactId = serviceSessions.getOrDefault(sessionId, "")
      if artifactId.len == 0:
        return (404, "{}", "")
      # REASSEMBLE from `totalSlices`, which is a count of the PIECES and not
      # of the objects the session uploaded (§9.1) — the sidecars travel
      # through the same session and are not put back together.
      let totalSlices = parsedBody{"totalSlices"}.getInt()
      var reassembled = ""
      withLock serviceLock:
        let slices = serviceSessionSlices.getOrDefault(
          sessionId, initTable[int, string]())
        for index in 0 ..< totalSlices:
          let key = slices.getOrDefault(index, "")
          if key.len > 0 and fileExists(serviceBucketDir / key):
            reassembled.add readFile(serviceBucketDir / key)
      let reassembledKey = segments[0] & "-" & artifactId & "-reassembled"
      writeFile(serviceBucketDir / reassembledKey, reassembled)
      return (200, $ %*{"artifactId": artifactId}, "")

    if segments.len == 3 and segments[2] == "confirm-upload":
      var known = false
      withLock serviceLock:
        known = serviceRecords.hasKey(segments[1])
      let status = if known: 200 else: 404
      return (status, "{}", "")

    if segments.len == 3 and segments[2] == "download-url":
      let collection = segments[0]
      let artifactId = segments[1]
      if collection == "artifacts":
        # Modelled on what is deployed today: the kind-neutral family is not
        # routed, so the client must fall through to the kind's alias (§9.4).
        return (404, "{}", "")
      var record: JsonNode = nil
      withLock serviceLock:
        if serviceRecords.hasKey(artifactId):
          record = serviceRecords[artifactId]
      if record.isNil or record{"collection"}.getStr() != collection:
        return (404, "{}", "")
      return (200, $ %*{
        "downloadUrl": "http://127.0.0.1:" & $servicePort & "/object/" &
          record{"objectKey"}.getStr(),
        "expiresAt": "",
      }, "")

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
          body = client.recv(contentLength, timeout = 20_000)
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

proc startService(bucketDir: string) =
  serviceBucketDir = bucketDir
  createDir(serviceBucketDir)
  serviceNextId = 0
  withLock serviceLock:
    serviceRequests = @[]
    serviceRecords = initTable[string, JsonNode]()
    serviceSessions = initTable[string, string]()
    serviceSessionSlices = initTable[string, Table[int, string]]()
  serviceReady = false
  serviceStop = false
  createThread(serviceWorker, serviceThread, 0)
  var waited = 0
  while not serviceReady and waited < 5000:
    sleep(10)
    waited += 10
  doAssert serviceReady, "the stand-in sharing service did not start"

proc stopService() =
  serviceStop = true
  try:
    # One connection to break the blocking `accept`.
    var poke = newSocket()
    poke.connect("127.0.0.1", Port(servicePort))
    poke.close()
  except CatchableError:
    discard
  joinThread(serviceWorker)

proc serviceBaseUrl(): string = "http://127.0.0.1:" & $servicePort

proc recordedBodies(httpMethod, pathSuffix: string): seq[string] =
  result = @[]
  {.cast(gcsafe).}:
    withLock serviceLock:
      for request in serviceRequests:
        if request.httpMethod == httpMethod and
            request.path.endsWith(pathSuffix):
          result.add request.body

# ---------------------------------------------------------------------------
# Driving the shipped binary
# ---------------------------------------------------------------------------

proc runCt(arguments: openArray[string]): tuple[output: string, code: int] =
  doAssert fileExists(CtBinary),
    CtBinary & " is missing — run `just build-once` first. This suite drives " &
    "the real CLI on purpose and must not be skipped when it cannot."
  var quoted: seq[string] = @[]
  for argument in arguments:
    quoted.add "'" & argument.replace("'", "'\\''") & "'"
  let outcome = execCmdEx(CtBinary & " " & quoted.join(" "))
  (output: outcome.output, code: outcome.exitCode)

proc runCtSplit(arguments: openArray[string]):
    tuple[stdout: string, stderr: string, code: int] =
  ## Like `runCt`, but with the two streams kept apart.
  ##
  ## `ct download`'s contract differs between them and the difference is
  ## load-bearing: **stdout is the locator and nothing else**, because the
  ## Electron handler takes the whole of it, stripped, as the imported
  ## recording id; the sharing view and its notices go to stderr. A merged
  ## capture cannot assert that separation, so this exists to assert it.
  doAssert fileExists(CtBinary), CtBinary & " is missing"
  var quoted: seq[string] = @[]
  for argument in arguments:
    quoted.add "'" & argument.replace("'", "'\\''") & "'"
  let errPath = getTempDir() / "ct-as4-stderr.txt"
  removeFile(errPath)
  let outcome = execCmdEx(
    CtBinary & " " & quoted.join(" ") & " 2>'" & errPath & "'",
    options = {poUsePath, poEvalCommand})
  let errText = if fileExists(errPath): readFile(errPath) else: ""
  removeFile(errPath)
  (stdout: outcome.output, stderr: errText, code: outcome.exitCode)

proc sharingViewLine(text: string): JsonNode =
  ## The `ct download` sharing view, from the stream it is written to.
  ## `newJObject()` when there is none, so a caller can say which.
  for line in text.splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("{"):
      continue
    try:
      let parsed = parseJson(trimmed)
      if parsed{"stage"}.getStr() == "received":
        return parsed
    except CatchableError:
      discard
  newJObject()

proc lastJsonLine(output: string): JsonNode =
  ## `ct upload`'s machine-readable result is the last non-empty line.  Read
  ## the way the Electron handler reads it (`src/frontend/index/online_sharing.nim`),
  ## so a change that breaks that consumer breaks this too.
  var lastLine = ""
  for line in output.splitLines():
    if line.strip().len > 0:
      lastLine = line.strip()
  try:
    parseJson(lastLine)
  except CatchableError:
    checkpoint("last line was not JSON: " & lastLine)
    newJObject()

proc offerBlock(output: string): seq[string] =
  ## The `assOffered` view as the binary printed it: from the heading to the
  ## first blank line after it.  Printed on every run, tty or not, because the
  ## disclosure has to reach a script too (AS-3's fourth deliverable).
  result = @[]
  var inside = false
  for line in output.splitLines():
    if line.startsWith("About to share this "):
      inside = true
    if inside:
      if line.strip().len == 0:
        break
      result.add line

# ---------------------------------------------------------------------------

var scratch: string
var home: string
var datasetDir: string
var recordingDir: string
var slicedRecordingDir: string
var passwordFile: string

proc writeReviewDataset(directory: string) =
  createDir(directory)
  writeFile(directory / "review.json", """{
    "commitSha": "9f1c2d3e4b5a69788796a5b4c3d2e1f009182736",
    "baseCommitSha": "0011223344556677889900aabbccddeeff001122",
    "files": ["parser.nim", "lexer.nim", "ast.nim"],
    "recordings": ["r1"],
    "session": {"title": "parser cleanup"}
  }""")

proc writeRecordingFolder(directory: string) =
  ## A folder holding a **real** CTFS container, which is what
  ## `classifyLocalArtifact` recognises as a recording.
  ##
  ## It has to be real, and the first version of this suite got that wrong:
  ## nothing on the *upload* path opens the bytes, so fake ones sufficed to
  ## share a recording — and so the recording's **download** was never tested,
  ## because `importTrace` reads `meta.dat` out of the container and refuses
  ## anything else. A fixture that is only good enough for half the flow is how
  ## the whole `assReceived` path for `akRecording` went unexercised.
  createDir(directory)
  let built = buildM1Fixture(directory / "sudoku.ct")
  doAssert built.isOk,
    "could not write the CTFS fixture container: " & built.error

proc writeSlicedRecordingFolder(directory: string) =
  ## The shape `ct-mcr record --split` leaves behind: a `.ct` beside a
  ## `<name>.ct_slices/` directory of slice files and their manifests, which is
  ## what `findSlicesDir` recognises and what sends the upload down the
  ## **session** path.
  ##
  ## This exists so the three narration lines that are recording-only —
  ## `MCR trace with pre-split slices detected`, `Uploading N pre-split
  ## slices…` and `Upload finalized: N slices` — are actually emitted by the
  ## binary under test. Listing them in an allowlist that nothing drives would
  ## be the "test exercising a path the product does not take" shape this
  ## campaign keeps finding.
  createDir(directory)
  let container = directory / "sudoku.ct"
  let built = buildM1Fixture(container)
  doAssert built.isOk, "could not write the CTFS fixture: " & built.error
  let slices = container & "_slices"
  createDir(slices)
  for index in 0 ..< 3:
    writeFile(slices / ("slice_" & align($index, 4, '0') & ".ct"),
      "slice-" & $index & "-bytes")
  writeFile(slices / "manifest.smnf", "smnf")
  writeFile(slices / "analysis.amnf", "amnf")

proc registerRecordingRow(traceIndexDb, outputFolder: string,
    recordingId: string = SampleRecordingId) =
  ## One row in the scratch trace index, so `ct upload --artifact <FOLDER>`
  ## can resolve the folder to a recording.  See the header on why this is the
  ## one substituted fixture.
  let insert = "INSERT OR REPLACE INTO recordings (recording_id, program, " &
    "args, compile_command, env, workdir, output, source_folders, " &
    "low_level_folder, output_folder, lang, imported, shell_id, rr_pid, " &
    "exit_code, calltrace, calltrace_mode, recorded_at, " &
    "remote_share_download_key) VALUES ('" & recordingId &
    "', 'sudoku', '', '', '', '/tmp', '', '', '', '" & outputFolder &
    "', 1, 0, 0, 0, 0, 0, 'FullRecord', '2026/08/26', '');"
  let outcome = execCmdEx("sqlite3 '" & traceIndexDb & "' \"" & insert & "\"")
  doAssert outcome.exitCode == 0,
    "could not write the recording fixture row with sqlite3 (it is in the " &
    "dev shell, nix/shells/ci-base.nix): " & outcome.output

suite "AS-4 — one sharing flow, driven through the shipped ct binary":

  setup:
    scratch = getTempDir() / "ct-as4-sharing-flow"
    removeDir(scratch)
    createDir(scratch)
    home = scratch / "home"
    createDir(home)
    putEnv("HOME", home)
    putEnv("XDG_CONFIG_HOME", home / ".config")
    datasetDir = scratch / "dataset"
    recordingDir = scratch / "recording"
    slicedRecordingDir = scratch / "recording-sliced"
    passwordFile = scratch / "password.txt"
    writeReviewDataset(datasetDir)
    writeRecordingFolder(recordingDir)
    writeSlicedRecordingFolder(slicedRecordingDir)
    writeFile(passwordFile, SamplePassword)
    startService(scratch / "bucket")
    # `ct list` on an empty scratch home creates the trace index with the
    # current schema; the fixture row goes in afterwards.
    discard runCt(["list"])
    let traceIndexDb = home / ".local" / "share" / "codetracer" / "trace_index.db"
    registerRecordingRow(traceIndexDb, recordingDir)
    registerRecordingRow(traceIndexDb, slicedRecordingDir,
      recordingId = SlicedRecordingId)

  teardown:
    stopService()
    removeDir(scratch)

  test "the disclosure a user reads before choosing is identical across kinds":
    # Verification item 1, at the moment it matters most: before the password
    # is chosen, and before a byte moves.  Every line except the noun and
    # §10.4's per-kind list must be the same for both kinds.
    var blocks: seq[seq[string]] = @[]
    for target in [datasetDir, recordingDir]:
      let run = runCt(["upload", "--artifact=" & target, "--encrypt",
        "--password-file=" & passwordFile, "--org=" & ServiceTenantId,
        "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
      checkpoint(run.output)
      let offer = offerBlock(run.output)
      check offer.len > 0
      blocks.add offer
    check blocks.len == 2
    # The noun is the only substitution allowed in the heading; the
    # "Still visible to the service" line is the per-kind list.
    # The kind-API notice is the fifth and last door: a kind whose upload
    # bodies are frozen owes the user that sentence and no other kind gets one.
    # It is normalised out here and asserted on its own below.
    proc normalised(lines: seq[string]): seq[string] =
      result = @[]
      for line in lines:
        if line.contains("Still visible to the service"):
          result.add "    Still visible to the service: <per-kind list>"
        elif line.startsWith("About to share this "):
          result.add "About to share this <noun>:"
        elif line.contains("the service was told neither"):
          result.add "  <kind-api notice>"
        else:
          result.add line
    proc withoutKindNotice(lines: seq[string]): seq[string] =
      result = @[]
      for line in normalised(lines):
        if line != "  <kind-api notice>":
          result.add line
    check withoutKindNotice(blocks[0]) == withoutKindNotice(blocks[1])
    # Exactly one of the two kinds carries the notice, and it is the one whose
    # request bodies cannot hold an access record.
    check "<kind-api notice>" notin normalised(blocks[0]).join("\n")
    check "<kind-api notice>" in normalised(blocks[1]).join("\n")
    # …and the disclosure really is a disclosure: the recovery answer is in it.
    check blocks[0].join("\n").contains("If you lose the password: Nothing.")

  test "the disclosure names each kind by its own noun":
    for (target, noun) in [(datasetDir, "review dataset"),
        (recordingDir, "recording")]:
      checkpoint(noun)
      let run = runCt(["upload", "--artifact=" & target, "--encrypt",
        "--password-file=" & passwordFile, "--org=" & ServiceTenantId,
        "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
      check offerBlock(run.output)[0] == "About to share this " & noun & ":"

  test "an upload of either kind reports the same sharing view":
    # The machine-readable half of `ct upload` carries the SAME view the
    # rendered half does, so this compares what a user is told, from the
    # shipped binary, for one artifact of each kind.
    var views: seq[JsonNode] = @[]
    for target in [datasetDir, recordingDir]:
      let run = runCt(["upload", "--artifact=" & target,
        "--org=" & ServiceTenantId, "--token=" & ServiceToken,
        "--base-url=" & serviceBaseUrl()])
      checkpoint(run.output)
      check run.code == 0
      let result = lastJsonLine(run.output)
      check result.hasKey("view")
      views.add result["view"]
    check views.len == 2

    # Kind-neutral: identical, key for key and value for value.
    check views[0]["stage"] == views[1]["stage"]
    check views[0]["access"] == views[1]["access"]
    check views[0]["notices"] != nil
    var keys0: seq[string] = @[]
    for key, _ in views[0].pairs: keys0.add key
    var keys1: seq[string] = @[]
    for key, _ in views[1].pairs: keys1.add key
    check keys0 == keys1

    # Per-kind, and only where a kind genuinely differs.
    check views[0]["kind"].getStr == "review-dataset"
    check views[1]["kind"].getStr == "recording"
    check views[0]["facts"] != views[1]["facts"]
    check views[0]["displayName"].getStr == "parser cleanup"
    check views[1]["displayName"].getStr == "sudoku"

  test "each kind is distinguishable in ct list, without opening it":
    # Verification item 2, in the running product.  Before AS-4 `ct list`
    # showed recordings and nothing else, so a downloaded review dataset was
    # on the machine, openable with `ct review`, and invisible to the only
    # listing the CLI has.
    let uploaded = runCt(["upload", "--artifact=" & datasetDir,
      "--org=" & ServiceTenantId, "--token=" & ServiceToken,
      "--base-url=" & serviceBaseUrl()])
    check uploaded.code == 0
    let shareUrl = lastJsonLine(uploaded.output){"shareUrl"}.getStr()
    check shareUrl.len > 0
    let downloaded = runCt(["download", shareUrl,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint(downloaded.output)
    check downloaded.code == 0

    let listed = runCt(["list"])
    checkpoint(listed.output)
    check listed.code == 0
    check "Recording" in listed.output
    check "Review dataset" in listed.output
    # …and each row carries the facts that identify it.
    check "sudoku" in listed.output
    check "parser cleanup" in listed.output
    # One row per artifact, and both kinds present. Counted by kind rather
    # than by a fixed total, so adding a fixture does not silently weaken it.
    var recordings = 0
    var datasets = 0
    for row in listed.output.strip().splitLines():
      if " | Recording " in row: inc recordings
      elif " | Review dataset " in row: inc datasets
    check recordings >= 1
    check datasets == 1
    check recordings + datasets == listed.output.strip().splitLines().len

    let asJson = parseJson(runCt(["list", "--format=json"]).output)
    check asJson.kind == JArray
    var kinds: seq[string] = @[]
    for row in asJson:
      kinds.add row["kind"].getStr()
    check "recording" in kinds
    check "review-dataset" in kinds

  test "an access-control change takes effect and is observable":
    # Verification item 3, in the running product, at all three places it has
    # to be true: what the user is told, what a script reads, and what the
    # service is sent.
    for visibility in ["tenant", "tenant-or-invite"]:
      checkpoint(visibility)
      let run = runCt(["upload", "--artifact=" & datasetDir,
        "--visibility=" & visibility, "--org=" & ServiceTenantId,
        "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
      checkpoint(run.output)
      check run.code == 0
      let result = lastJsonLine(run.output)
      check result["visibility"].getStr == visibility
      check result["accessRecordSentToService"].getBool
      # What the user reads, in the offer the binary printed.
      let offer = offerBlock(run.output).join("\n")
      if visibility == "tenant-or-invite":
        check "invite link" in offer
      else:
        check "invite link" notin offer

    # …and what actually crossed the socket, which is the half a rendered
    # sentence cannot vouch for.
    var sentVisibilities: seq[string] = @[]
    for body in recordedBodies("POST", "/review-datasets/upload-url"):
      sentVisibilities.add parseJson(body){"access"}{"visibility"}.getStr()
    check sentVisibilities == @["tenant", "tenant-or-invite"]

  test "a recording's access setting is recorded locally and said not to be sent":
    # The honest half.  The recording kind's request bodies are frozen (§9.3),
    # so `--visibility` cannot reach the service — and the surface says so
    # rather than showing a setting the service was never told.
    let run = runCt(["upload", "--artifact=" & recordingDir,
      "--visibility=tenant-or-invite", "--org=" & ServiceTenantId,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint(run.output)
    check run.code == 0
    let result = lastJsonLine(run.output)
    check result["visibility"].getStr == "tenant-or-invite"
    check not result["accessRecordSentToService"].getBool
    var notices = ""
    for notice in result["view"]["notices"]:
      notices &= notice.getStr() & "\n"
    check "the service was told neither" in notices
    # And the wire really does not carry it.
    for body in recordedBodies("POST", "/traces/upload-url"):
      checkpoint(body)
      check "visibility" notin body

  test "an unknown --visibility is refused by name, against the closed set":
    # The rule AS-2 closed four holes of and AS-3 a fifth, on the one new input
    # this milestone adds.  `--visibility=public` must not read as `tenant`.
    let refused = runCt(["upload", "--artifact=" & datasetDir,
      "--visibility=public", "--org=" & ServiceTenantId,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint(refused.output)
    check refused.code != 0
    check "unknown visibility 'public'" in refused.output
    check "tenant-or-invite" in refused.output
    # Nothing was uploaded: the refusal comes before the transfer.
    check recordedBodies("POST", "/review-datasets/upload-url").len == 0

  test "--visibility <VALUE>, space-separated, works and takes effect":
    # The conventional spelling, and a REGRESSION this suite did not have a
    # case for: the first version of the argv guard matched the bare
    # `--visibility` token without looking at the next one, so a perfectly good
    # invocation was refused with a message that was a false statement about
    # what the user had typed. `--visibility=` was covered; this was not.
    for form in [@["--visibility", "tenant-or-invite"],
                 @["--visibility=tenant-or-invite"]]:
      checkpoint(form.join(" "))
      let run = runCt(@["upload", "--artifact=" & datasetDir] & form &
        @["--org=" & ServiceTenantId, "--token=" & ServiceToken,
          "--base-url=" & serviceBaseUrl()])
      checkpoint(run.output)
      check run.code == 0
      check lastJsonLine(run.output){"visibility"}.getStr == "tenant-or-invite"
      check "no value" notin run.output
      # …and it reached the socket, not just the message.
      check "invite link" in offerBlock(run.output).join("\n")
    var sent: seq[string] = @[]
    for body in recordedBodies("POST", "/review-datasets/upload-url"):
      sent.add parseJson(body){"access"}{"visibility"}.getStr()
    check sent == @["tenant-or-invite", "tenant-or-invite"]

  test "--visibility with no value is refused, not read as the default":
    # `visibilityToken.get("")` collapsed "not given" into "given as empty", so
    # `--visibility=` resolved silently to `tenant` — while `{"visibility": ""}`
    # on the wire was refused by `readClosedEnumField`. AS-3's
    # `--password-file -` in the safe direction, which is why nobody noticed.
    for arguments in [
        @["upload", "--artifact=" & datasetDir, "--visibility=",
          "--org=" & ServiceTenantId, "--token=" & ServiceToken,
          "--base-url=" & serviceBaseUrl()],
        @["upload", "--artifact=" & datasetDir, "--visibility", "",
          "--org=" & ServiceTenantId, "--token=" & ServiceToken,
          "--base-url=" & serviceBaseUrl()]]:
      checkpoint(arguments.join(" "))
      let refused = runCt(arguments)
      checkpoint(refused.output)
      check refused.code != 0
      check "no value" in refused.output
      check "tenant-or-invite" in refused.output
      # Whatever else happens, it must not have got as far as uploading.
      check "uploaded" notin refused.output.toLowerAscii()
    check recordedBodies("POST", "/review-datasets/upload-url").len == 0

  test "an encrypted artifact of either kind needs its password to come back":
    # The end-to-end shape AS-3 built and AS-4 renders: upload encrypted,
    # download without a password (refused, and told CodeTracer cannot recover
    # it), then download with it.
    let uploaded = runCt(["upload", "--artifact=" & datasetDir, "--encrypt",
      "--password-file=" & passwordFile, "--org=" & ServiceTenantId,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint(uploaded.output)
    check uploaded.code == 0
    let shareUrl = lastJsonLine(uploaded.output){"shareUrl"}.getStr()
    check shareUrl.len > 0

    let withoutPassword = runCt(["download", shareUrl,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint(withoutPassword.output)
    check withoutPassword.code != 0
    check "is encrypted" in withoutPassword.output
    check "cannot recover it" in withoutPassword.output

    let withPassword = runCt(["download", shareUrl,
      "--password-file=" & passwordFile,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint(withPassword.output)
    check withPassword.code == 0
    let landed = withPassword.output.strip().splitLines()[^1]
    check dirExists(landed)
    check fileExists(landed / "review.json")
    # …and what came back is what went up, byte for byte.
    check readFile(landed / "review.json") ==
      readFile(datasetDir / "review.json")

  test "a recording downloads, and its received view is about a download":
    # **No test downloaded a recording** until this one, so the whole
    # `assReceived` path for `akRecording` had never run end to end — and the
    # first thing it turned up was that `ct download` of a recording printed
    #
    #   Who can open it: not stated — the service did not return this
    #     artifact's record …
    #   CodeTracer records who may open this recording … so the service was
    #     not told.
    #
    # two lines apart and contradicting each other, about an upload that had
    # not happened. Same structural hole as §8 defect 26, one kind over.
    let uploaded = runCt(["upload", "--artifact=" & recordingDir,
      "--org=" & ServiceTenantId, "--token=" & ServiceToken,
      "--base-url=" & serviceBaseUrl()])
    checkpoint(uploaded.output)
    check uploaded.code == 0
    let shareUrl = lastJsonLine(uploaded.output){"shareUrl"}.getStr()
    check shareUrl.len > 0

    let downloaded = runCtSplit(["download", shareUrl,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint("stdout: " & downloaded.stdout)
    checkpoint("stderr: " & downloaded.stderr)
    check downloaded.code == 0

    # stdout is the locator and nothing else — the Electron contract. For a
    # recording the locator is the imported RECORDING ID, not a path: that is
    # what `ct replay` takes, and what the Electron handler feeds to
    # `loadExistingRecord`.
    let locator = downloaded.stdout.strip()
    check locator.splitLines().len == 1
    check locator.len == 36
    check locator.count('-') == 4

    # …and the recording really landed: `importTrace` accepted the container
    # rather than the run stopping at the "no `.ct`" refusal, so the folder it
    # allocated holds one.
    let landed = home / ".local" / "share" / "codetracer" / locator
    check dirExists(landed)
    var containers = 0
    for entry in walkDir(landed):
      if entry.kind == pcFile and entry.path.endsWith(".ct"):
        inc containers
    check containers == 1

    let view = sharingViewLine(downloaded.stderr)
    check view{"stage"}.getStr == "received"
    check view{"kind"}.getStr == "recording"
    var notices = ""
    for notice in view{"notices"}:
      notices &= notice.getStr() & "\n"
    check "upload API" notin notices
    check "CodeTracer records who may open" notin notices
    check "upload API" notin downloaded.stderr

  test "the id the listing prints is one ct replay resolves":
    # The listing's trailing full id and the row's `openCommand` are only worth
    # having if `ct replay` accepts the value. Independent verification could
    # not confirm it — in a scratch `HOME` with no imported recording, a good
    # id, its prefix and a garbage id all failed identically, so the run proved
    # nothing. With a recording actually imported, they separate.
    #
    # The signal is deliberate: `ct replay` goes on to launch the GUI, so a
    # RESOLVED id runs until the timeout kills it, while an unresolved one
    # exits immediately with a named refusal. The assertion is on the refusal,
    # not on the exit status.
    let uploaded = runCt(["upload", "--artifact=" & recordingDir,
      "--org=" & ServiceTenantId, "--token=" & ServiceToken,
      "--base-url=" & serviceBaseUrl()])
    check uploaded.code == 0
    let shareUrl = lastJsonLine(uploaded.output){"shareUrl"}.getStr()
    let downloaded = runCtSplit(["download", shareUrl,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    check downloaded.code == 0
    let recordingId = downloaded.stdout.strip()
    check recordingId.len == 36

    # The row prints that id, whole, and offers it as `ct replay <id>`.
    let listed = runCt(["list", "--format=json"])
    var offered = ""
    for row in parseJson(listed.output):
      if row{"artifactId"}.getStr() == recordingId:
        offered = row{"openCommand"}.getStr()
    check offered == "ct replay " & recordingId
    check recordingId in runCt(["list"]).output

    proc replayRefusal(id: string): string =
      # `timeout` rather than `execCmdEx` alone: a resolved id proceeds to
      # launch and would hang the suite.
      let outcome = execCmdEx(
        "timeout 20 " & CtBinary & " replay --id='" & id & "' 2>&1",
        options = {poUsePath, poEvalCommand})
      outcome.output
    check "no recording matches" notin replayRefusal(recordingId)
    check "no recording matches" in
      replayRefusal("01949fcc-0000-7000-8000-000000000000")
    check "no recording matches" in replayRefusal("not-an-id")

  test "the received view is identical across kinds outside the doors":
    # `assReceived` was compared for neither kind: the CLI suite's line-for-line
    # comparison ran only at `assOffered`, and `assShared` only as JSON. A door
    # gated on this stage would have been invisible in the product.
    var views: seq[JsonNode] = @[]
    var presences: seq[seq[string]] = @[]
    for target in [recordingDir, datasetDir]:
      let uploaded = runCt(["upload", "--artifact=" & target,
        "--org=" & ServiceTenantId, "--token=" & ServiceToken,
        "--base-url=" & serviceBaseUrl()])
      check uploaded.code == 0
      let shareUrl = lastJsonLine(uploaded.output){"shareUrl"}.getStr()
      check shareUrl.len > 0
      let downloaded = runCtSplit(["download", shareUrl,
        "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
      checkpoint(downloaded.stderr)
      check downloaded.code == 0
      var view = sharingViewLine(downloaded.stderr)
      check view.len > 0
      # The doors and the per-artifact values, removed by name — with their
      # presence recorded BESIDE the object rather than written into it as a
      # sibling key, which the subject could name and thereby hide inside.
      var present: seq[string] = @[]
      for key in ["kind", "artifactId", "displayName", "facts",
          "openCommand", "stillVisibleToService", "notices"]:
        present.add key & ":" & (if view.hasKey(key): "present" else: "absent")
        if view.hasKey(key):
          view.delete(key)
      views.add view
      presences.add present
    check views.len == 2
    check views[0] == views[1]
    check presences[0] == presences[1]

  test "a download does not invent an access record the service never sent":
    # The stand-in returns no artifact record, which is what every deployed
    # service does today (§9.4). The received view must not fill the gap with
    # the model's default visibility — "members of the owning organisation"
    # about an artifact whose owner the client was never told is a fabricated
    # fact, and this test exists because reading the real output is what
    # caught it.
    let uploaded = runCt(["upload", "--artifact=" & datasetDir,
      "--visibility=tenant-or-invite", "--org=" & ServiceTenantId,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    check uploaded.code == 0
    let shareUrl = lastJsonLine(uploaded.output){"shareUrl"}.getStr()
    check shareUrl.len > 0
    # A tty renders the view; a pipe prints the locator. Assert on the view
    # the binary would render by asking the same code the same question is not
    # enough here — so drive the binary and look at what it says on stderr and
    # stdout together.
    let downloaded = runCt(["download", shareUrl,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint(downloaded.output)
    check downloaded.code == 0
    check "members of the owning organisation" notin downloaded.output
    check "anyone holding an invite link" notin downloaded.output

  test "everything printed outside the sharing view is declared narration":
    # **Where the one-flow guarantee stops, written down and enforced.**
    #
    # The equalities cover the sharing VIEW — what a user is told about the
    # artifact, its access, its protection and what to do next — at three
    # layers. They do not cover the lines `ct upload` prints about moving the
    # bytes, and those really are per-payload-shape: a slice set is packed,
    # published and finalized; a single file is zipped. Independent
    # verification named this as the remaining place a recording and a review
    # dataset read differently, and it is a real edge, so it is declared here
    # rather than left implied.
    #
    # Declared AND driven: the sliced recording is uploaded for real, so the
    # three recording-only lines are emitted by the binary rather than merely
    # listed. A fourth line on one path only fails this test until somebody
    # adds it with a reason — which is the point, and is the same shape as
    # `sharing_cli_surface_test.nim`'s flag allowlist.
    # Numbers, ids and paths vary run to run, so a line is matched with its
    # digit runs collapsed to `N`, against the longest STABLE head of the line.
    # Long heads are the point: `"Uploading "` would have quietly admitted a
    # future `Uploading review dataset…`, while `"Uploading N pre-split slices
    # from: "` and `"Uploading part N/N: "` cannot.
    const DeclaredNarration = [
      # Progress. Emitted for both kinds — but the MESSAGE inside differs, and
      # naming both spellings here is the point. This is what "the narration is
      # per payload shape" looks like when it is written down instead of
      # implied.
      "{\"progress\": N, \"message\": \"Packing review dataset..\"}",
      "{\"progress\": N, \"message\": \"Zipping files..\"}",
      # Slice-set transfer. A review dataset declaring `aplSliceSet` gets these
      # too — they belong to the SHAPE, not to the recording kind (§9.1).
      "MCR trace with pre-split slices detected",
      "Uploading N pre-split slices from: ",
      "Upload session created: ",
      "Uploading part N/N: ",
      "Upload finalized: N slices",   # plus an omniscient-db suffix, when set
      # Encryption, either kind.
      "Encrypting on this computer before upload (the password is never sent).",
      # MCR enrichment, which happens before anything is described as an
      # artifact at all. The WARNING arm fires when `ct-mcr` is not on PATH,
      # which is the case in this suite's environment and in plenty of users'.
      "MCR trace detected: added portable payload (binaries + symbols)",
      "WARNING: MCR trace detected but ct-mcr binary not found.",
      "The trace will be uploaded without portable binaries/symbols.",
      "Install ct-mcr or set CODETRACER_CT_MCR_CMD to enable enrichment.",
    ]

    proc digitsCollapsed(line: string): string =
      result = ""
      var inNumber = false
      for c in line:
        if c.isDigit:
          if not inNumber:
            result.add 'N'
            inNumber = true
        else:
          inNumber = false
          result.add c

    var offenders: seq[string] = @[]
    # Both kinds, both protection states, and the SLICED shape — so every entry
    # above is emitted by the binary rather than listed on trust. An entry that
    # stops being produced is not caught here, but one that is produced and not
    # declared is, which is the direction that matters.
    for target in [datasetDir, slicedRecordingDir]:
      for encrypt in [false, true]:
        var arguments = @["upload", "--artifact=" & target,
          "--org=" & ServiceTenantId, "--token=" & ServiceToken,
          "--base-url=" & serviceBaseUrl()]
        if encrypt:
          arguments.add "--encrypt"
          arguments.add "--password-file=" & passwordFile
        let run = runCt(arguments)
        checkpoint(run.output)
        check run.code == 0
        let offer = offerBlock(run.output)
        check lastJsonLine(run.output).hasKey("view")
        for line in run.output.splitLines():
          let trimmed = line.strip()
          if trimmed.len == 0 or line in offer:
            continue
          if trimmed.startsWith("{") and trimmed.contains("\"artifactId\""):
            continue                                 # the result line itself
          let normalised = digitsCollapsed(trimmed)
          var declared = false
          for entry in DeclaredNarration:
            if normalised.startsWith(entry):
              declared = true
          if not declared:
            offenders.add extractFilename(target) & ": " & trimmed
    offenders.sort()
    check offenders == newSeq[string]()

  test "the sliced recording upload really takes the session path":
    # Guards the case above from going vacuous: if the sliced fixture stopped
    # being recognised, the upload would fall back to the single-file zip and
    # the recording-only narration would silently stop being exercised.
    let run = runCt(["upload", "--artifact=" & slicedRecordingDir,
      "--org=" & ServiceTenantId, "--token=" & ServiceToken,
      "--base-url=" & serviceBaseUrl()])
    checkpoint(run.output)
    check run.code == 0
    check "MCR trace with pre-split slices detected" in run.output
    check "Upload finalized: 3 slices" in run.output
    check "upload-session API not available" notin run.output
    # …and the session conversation really happened, on the socket.
    check recordedBodies("POST", "/traces/upload-session").len == 1
    let finalize = recordedBodies("POST", "/finalize")
    check finalize.len == 1
    if finalize.len == 1:
      # 3, the slices — not 5, the objects (§9.1).
      check parseJson(finalize[0]){"totalSlices"}.getInt == 3

  test "a service that serves another artifact's payload is called out":
    # `Artifact-Store.md` §8 defect 18, the residual AS-3 disclosed and could
    # not close: a service can serve artifact B's payload for a link to A, and
    # if the same password sealed both, it opens and every tag verifies.
    # Enforcing the envelope's id on download is not possible (§10.3 — it would
    # make an encrypted sliced recording unopenable through its own link), so
    # the whole defence is TELLING the one person who can tell it is wrong.
    #
    # AS-3 computed the value and stopped at `ArtifactFetchOutcome`. This drives
    # the substitution through the shipped binary and asserts the user is told.
    let secondDataset = scratch / "dataset-two"
    writeReviewDataset(secondDataset)
    writeFile(secondDataset / "marker.txt", "the OTHER artifact's contents")

    var links: seq[string] = @[]
    var ids: seq[string] = @[]
    for target in [datasetDir, secondDataset]:
      let uploaded = runCt(["upload", "--artifact=" & target, "--encrypt",
        "--password-file=" & passwordFile, "--org=" & ServiceTenantId,
        "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
      check uploaded.code == 0
      let result = lastJsonLine(uploaded.output)
      links.add result{"shareUrl"}.getStr()
      ids.add result{"artifactId"}.getStr()
    check links[0].len > 0 and links[1].len > 0
    check ids[0] != ids[1]

    # The service now answers the FIRST link with the SECOND artifact's bytes.
    # Nothing about the transfer is malformed; both really were sealed by this
    # user, under this password.
    withLock serviceLock:
      serviceRecords[ids[0]]["objectKey"] =
        serviceRecords[ids[1]]["objectKey"]

    let substituted = runCt(["download", links[0],
      "--password-file=" & passwordFile,
      "--token=" & ServiceToken, "--base-url=" & serviceBaseUrl()])
    checkpoint(substituted.output)
    # It opens — that is the residual, and pretending otherwise would be the
    # overstatement this campaign exists to avoid.
    check substituted.code == 0
    # …and the user is told, by both ids.
    check "was sealed as artifact " & ids[1] in substituted.output
    check "not " & ids[0] in substituted.output
    check "served something other than what the link asked for" in
      substituted.output
