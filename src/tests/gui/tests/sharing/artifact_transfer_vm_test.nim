## AS-2 — store and retrieve any declared kind, through one transfer.
##
## Spec: `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-2, designed
## in `codetracer-specs/Sharing/Artifact-Store.md` §9.
##
## AS-2's four verification items and where each is answered:
##
## 1. **a recording round-trips through the generic path** — suites 1 and 2
##    here (the plan a recording produces, and the artifact record it carries),
##    plus `artifact_store_roundtrip_test.nim`, which runs the same code
##    against a real HTTP service over a real socket with real files.
## 2. **a review dataset round-trips through the generic path** — same two
##    places, driven by the same loops.
## 3. **large artifacts still transfer in slices** — suite 3.  Asserted as a
##    property of the *payload layout*, for every kind, which is the claim AS-2
##    makes: slicing is a transfer concern and any large artifact can use it.
## 4. **metadata survives the round trip for each kind** — suite 4, including
##    an explicit statement of what a recording's frozen wire bodies do and do
##    not have room for, so the limit is asserted rather than glossed.
##
## The fifth thing this file guards is not on that list and matters most:
## **the recording kind's conversation with the service is character-identical
## to the pre-AS-2 one.** Real user data sits at real URLs. Every assertion in
## suite 5 is against a *literal* pre-AS-2 string rather than against the new
## code's own output, because a test that asked the new planner to agree with
## itself would pass through any rename.
##
## Headless on both Nim backends — the transfer *plan* is a pure function of the
## artifact and the local file list, with no filesystem, no HTTP and no `Trace`,
## which is exactly why the planner and the executor are separate modules.
## `just test-vm-native` and `just test-vm-js` reach this file by globbing
## `src/tests/gui/tests/**/*_test.nim`, and `CoreViewModelGateTests` in
## `src/ct_test/release_gate.nim` is the registry that says it must exist and
## must not be skip-disabled.

import std/[json, options, strutils, unittest]

import ../../../../ct/online_sharing/artifact_transfer

const
  SampleRecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  SampleDatasetId = "0194a000-1111-7abc-8def-000000000001"
  SampleBaseApiUrl = "https://web.codetracer.com/api/v1/"
  SampleTenantId = "tenant-123"
  SampleSessionId = "01949fcc-7d92-7e9c-bbbb-cccccccccccc"
  SamplePlatform = "linux-x86_64"

proc recordingSample(layout: ArtifactPayloadLayout,
    parts: seq[ArtifactPart]): Artifact =
  recordingArtifact(
    recordingId = SampleRecordingId,
    tenantId = SampleTenantId,
    program = "sudoku",
    langName = "LangNoir",
    byteSize = totalByteSize(parts),
    layout = layout,
    partCount = parts.len,
    platform = SamplePlatform,
    recordedAtUnixMs = 1_700_000_000_000'i64)

proc reviewDatasetSample(layout: ArtifactPayloadLayout,
    parts: seq[ArtifactPart]): Artifact =
  reviewDatasetArtifact(
    artifactId = SampleDatasetId,
    tenantId = SampleTenantId,
    commitSha = "9f1c2d3e4b5a69788796a5b4c3d2e1f009182736",
    baseCommitSha = "1122334455667788990011223344556677889900",
    byteSize = totalByteSize(parts),
    fileCount = 7,
    recordingCount = 2,
    sessionTitle = "parser cleanup",
    layout = layout,
    partCount = parts.len)

proc sampleArtifact(kind: ArtifactKind, layout: ArtifactPayloadLayout,
    parts: seq[ArtifactPart]): Artifact =
  ## Exhaustive `case`: a kind added without a sample here does not compile,
  ## which is what makes the `for kind in ArtifactKind` loops below cover it
  ## rather than silently skip it.
  case kind
  of akRecording: recordingSample(layout, parts)
  of akReviewDataset: reviewDatasetSample(layout, parts)

proc singleFileParts(name = "payload.zip", size: int64 = 4242): seq[ArtifactPart] =
  @[ArtifactPart(name: name, localPath: "/tmp/" & name, index: 0,
    byteSize: size)]

const
  McrSplitDirectory = [
    ## A `ct-mcr record --split` output directory, named file by file.
    ##
    ## The suites below are driven by **this shape** rather than by a part
    ## count, and that is a correction rather than a style choice. An earlier
    ## draft asserted `totalSlices == parts.len`, which is a statement about
    ## the implementation and is therefore satisfied by whatever the
    ## implementation does — it turned a real wire regression (`totalSlices`
    ## going from 3 to 5, because the manifests were being counted as slices)
    ## into a green assertion. A test that names the files can state what the
    ## *pre-AS-2 client sent for this directory*, which is a fact the
    ## implementation cannot move.
    "slice_0000.ct",
    "slice_0001.ct",
    "slice_0002.ct",
    "manifest.smnf",
    "analysis.amnf",
  ]
  McrSplitSliceCount = 3
    ## The `.ct` files above: the pieces the service reassembles, and exactly
    ## what the pre-AS-2 client put in `totalSlices` for this directory.
  McrSplitObjectCount = 5
    ## Every file above. The number of objects the session uploads — which the
    ## pre-AS-2 client deliberately did NOT report as `totalSlices`.

proc partsFor(fileNames: openArray[string]): seq[ArtifactPart] =
  ## Describe a directory listing as a slice-set payload, the way
  ## `artifact_store.collectSliceParts` does: slices first, then the sidecars
  ## that travel with them, each part carrying the role that decides whether it
  ## is counted as a piece of the payload.
  result = @[]
  var index = 0
  for wantSlices in [true, false]:
    for name in fileNames:
      let isSlice = name.endsWith(".ct")
      if isSlice != wantSlices:
        continue
      result.add ArtifactPart(
        name: name,
        localPath: "/tmp/slices/" & name,
        index: index,
        byteSize: (if isSlice: 1_000_000'i64 + index.int64 else: 512'i64),
        role: (if isSlice: aprSlice else: aprSidecar))
      inc index

proc mcrSplitParts(): seq[ArtifactPart] =
  partsFor(McrSplitDirectory)

proc sliceParts(count: int): seq[ArtifactPart] =
  ## `count` slices and nothing else, named the way `ct-mcr record --split`
  ## names them.
  result = @[]
  for i in 0 ..< count:
    let name = "slice_" & align($i, 4, '0') & ".ct"
    result.add ArtifactPart(name: name, localPath: "/tmp/slices/" & name,
      index: i, byteSize: 1_000_000'i64 + i.int64, role: aprSlice)

proc planOf(artifact: Artifact,
    parts: seq[ArtifactPart],
    omniscientDbMode = "",
    recordingMode = "hook"): ArtifactUploadPlan =
  let planned = planArtifactUpload(
    artifact, parts, SampleBaseApiUrl, SampleTenantId,
    recordingMode = recordingMode, omniscientDbMode = omniscientDbMode)
  check planned.error == ""
  planned.plan

proc recordingSession(): ArtifactUploadSession =
  ArtifactUploadSession(sessionId: SampleSessionId, kind: akRecording)

suite "AS-2 — every declared kind goes through one transfer, not two":

  test "the same plan shape serves every kind, single-file":
    # The claim: nothing about the *transfer* is per-kind.  A recording and a
    # review dataset produce the same three steps in the same order, differing
    # only in the collection they address — which comes from the registry.
    for kind in ArtifactKind:
      checkpoint($kind)
      let parts = singleFileParts()
      let plan = planOf(sampleArtifact(kind, aplSingleFile, parts), parts)
      let steps = uploadSteps(plan, ArtifactUploadSession(kind: kind))
      check steps.len == 3
      check steps[0].kind == atsRequestUploadUrl
      check steps[1].kind == atsPutPart
      check steps[2].kind == atsConfirmUpload
      # …and each addresses that kind's own collection.
      let segment = kindSpec(kind).urlSegment
      check steps[0].urlPath ==
        SampleBaseApiUrl & "tenants/" & SampleTenantId & "/" & segment &
        "/upload-url"
      check steps[2].urlPath ==
        SampleBaseApiUrl & segment & "/" &
        sampleArtifact(kind, aplSingleFile, parts).artifactId &
        "/confirm-upload"

  test "the same plan shape serves every kind, sliced":
    for kind in ArtifactKind:
      checkpoint($kind)
      let parts = sliceParts(3)
      let plan = planOf(sampleArtifact(kind, aplSliceSet, parts), parts)
      let session = ArtifactUploadSession(
        sessionId: SampleSessionId, kind: kind)
      let steps = uploadSteps(plan, session)
      # open + (request, put) per part + finalize
      check steps.len == 1 + 2 * parts.len + 1
      check steps[0].kind == atsOpenUploadSession
      check steps[^1].kind == atsFinalizeSession
      let segment = kindSpec(kind).urlSegment
      check steps[0].urlPath ==
        SampleBaseApiUrl & "tenants/" & SampleTenantId & "/" & segment &
        "/upload-session"
      check steps[^1].urlPath ==
        SampleBaseApiUrl & segment & "/" & SampleSessionId & "/finalize"

  test "a payload that does not match its descriptor is refused before a byte moves":
    # The plan is what a caller must obtain before any request is made, so
    # refusing here is refusing before an upload slot — or, on a slice set,
    # gigabytes of transfer — has been spent.
    let parts = singleFileParts()
    var artifact = recordingSample(aplSingleFile, parts)

    artifact.payload.byteSize = parts[0].byteSize + 1
    let wrongSize = planArtifactUpload(
      artifact, parts, SampleBaseApiUrl, SampleTenantId)
    check wrongSize.error.len > 0
    check "bytes but its parts total" in wrongSize.error

    var sliced = recordingSample(aplSliceSet, sliceParts(3))
    let mismatched = planArtifactUpload(
      sliced, sliceParts(2), SampleBaseApiUrl, SampleTenantId)
    check mismatched.error.len > 0
    check "part(s) but" in mismatched.error

    let unowned = planArtifactUpload(
      recordingSample(aplSingleFile, parts), parts, SampleBaseApiUrl, "")
    check unowned.error.len > 0
    check "owning tenant" in unowned.error

    let empty = planArtifactUpload(
      recordingSample(aplSingleFile, parts), @[], SampleBaseApiUrl,
      SampleTenantId)
    check empty.error.len > 0
    check "no payload parts" in empty.error

  test "an artifact the model refuses is never planned":
    # `planArtifactUpload` runs `validateArtifact` first, so the invariants the
    # model enforces — the UUIDv7 shape, the recording id binding, the owning
    # tenant — are enforced on the transfer too rather than only at rest.
    let parts = singleFileParts()
    var diverged = recordingSample(aplSingleFile, parts)
    diverged.artifactId = SampleDatasetId
    let planned = planArtifactUpload(
      diverged, parts, SampleBaseApiUrl, SampleTenantId)
    check planned.error.len > 0
    check "does not match its recording id" in planned.error

suite "AS-2 — large artifacts transfer in slices, whatever kind they are":
  ## Verification item 3.  The property under test is that slicing follows the
  ## **payload layout** and not the kind: `ArtifactPayloadLayout` sits on the
  ## payload precisely so a large review dataset can be transferred the way a
  ## large recording is, without the transport learning a second kind.

  test "every kind may declare the sliced layout":
    for kind in ArtifactKind:
      checkpoint($kind)
      check aplSliceSet in kindSpec(kind).allowedLayouts
      check aplSingleFile in kindSpec(kind).allowedLayouts

  test "a sliced payload publishes every part, in index order":
    for kind in ArtifactKind:
      checkpoint($kind)
      let parts = mcrSplitParts()
      check parts.len == McrSplitObjectCount
      let plan = planOf(sampleArtifact(kind, aplSliceSet, parts), parts)
      let session = ArtifactUploadSession(
        sessionId: SampleSessionId, kind: kind)
      let steps = uploadPartSteps(plan, session)
      # EVERY object is published, sidecars included — they travel through the
      # same session. What they are not is *counted* as pieces; see the
      # finalize test below.
      check steps.len == 2 * McrSplitObjectCount

      var expectedIndex = 0
      var i = 0
      while i < steps.len:
        check steps[i].kind == atsRequestPartUploadUrl
        check steps[i].body["sliceIndex"].getInt == expectedIndex
        check steps[i].body["fileName"].getStr == parts[expectedIndex].name
        check steps[i].body["contentLength"].getBiggestInt ==
          parts[expectedIndex].byteSize
        check steps[i + 1].kind == atsPutPart
        check steps[i + 1].part.index == expectedIndex
        check steps[i + 1].part.localPath == parts[expectedIndex].localPath
        inc expectedIndex
        i += 2
      check expectedIndex == parts.len

  test "a manifest travels as a further part, not as a special case":
    # `.smnf` / `.amnf` manifests used to be a second loop in `upload.nim`.
    # To the transport they are what every part is — a named blob at a
    # position — and that is what makes the transport kind-neutral. They still
    # come AFTER every slice, so no slice's index is above the slice count.
    let parts = mcrSplitParts()
    let plan = planOf(recordingSample(aplSliceSet, parts), parts)
    let steps = uploadPartSteps(plan, recordingSession())
    check steps[^1].part.name == "analysis.amnf"
    check steps[^1].kind == atsPutPart
    check steps[^3].part.name == "manifest.smnf"
    check steps[^2].body["sliceIndex"].getInt == McrSplitObjectCount - 1
    for i in 0 ..< McrSplitSliceCount:
      check parts[i].name.endsWith(".ct")
      check parts[i].role == aprSlice
    for i in McrSplitSliceCount ..< McrSplitObjectCount:
      check parts[i].role == aprSidecar

  test "the finalize step counts the SLICES, not the objects uploaded":
    # The wire fact this suite exists to hold. The deployed `/finalize`
    # reassembles the payload from `totalSlices`, and a `.smnf` / `.amnf`
    # manifest is not a piece to reassemble. The pre-AS-2 client sent 3 for the
    # directory named in `McrSplitDirectory`; sending 5 — the number of objects
    # the session uploaded — tells the service to look for two slices that do
    # not exist.
    for kind in ArtifactKind:
      checkpoint($kind)
      let parts = mcrSplitParts()
      let plan = planOf(sampleArtifact(kind, aplSliceSet, parts), parts)
      let final = uploadCompletionStep(plan,
        ArtifactUploadSession(sessionId: SampleSessionId, kind: kind))
      check final.kind == atsFinalizeSession
      check final.body["totalSlices"].getInt == McrSplitSliceCount
      check final.body["totalSlices"].getInt != McrSplitObjectCount
      check final.body["totalSlices"].getInt != parts.len

  test "a payload with no sidecars counts every part, because every part is a slice":
    # The other side of the same rule: `sliceCount` is not "parts minus a
    # constant", it is a count of the parts that are pieces.
    let parts = sliceParts(4)
    let plan = planOf(recordingSample(aplSliceSet, parts), parts)
    let final = uploadCompletionStep(plan, recordingSession())
    check final.body["totalSlices"].getInt == 4
    check sliceCount(parts) == parts.len

  test "a single-file payload opens no session at all":
    # The other half of the same property: a small artifact must not pay for
    # the sliced path, and the session id must not be minted where none is
    # needed — one field meaning two things is the defect this design closes.
    for kind in ArtifactKind:
      checkpoint($kind)
      let parts = singleFileParts()
      let plan = planOf(sampleArtifact(kind, aplSingleFile, parts), parts)
      for step in uploadSteps(plan, ArtifactUploadSession(kind: kind)):
        check step.kind != atsOpenUploadSession
        check step.kind != atsFinalizeSession
        check step.kind != atsRequestPartUploadUrl

suite "AS-2 — metadata survives the round trip, for each kind":
  ## Verification item 4, in two parts, because "metadata survives" has two
  ## honest halves and running them together would blur the second.

  test "the artifact record round-trips through the wire form, every kind":
    for kind in ArtifactKind:
      checkpoint($kind)
      let parts = singleFileParts()
      let original = sampleArtifact(kind, aplSingleFile, parts)
      let restored = parseDownloadedArtifact(
        %*{"downloadUrl": "https://s3.example/x", "artifact": original.toJson()})
      check restored.error == ""
      check restored.artifact.artifactId == original.artifactId
      check restored.artifact.kind == original.kind
      # The kind-specific half compared as its own serialised form, so a new
      # kind's fields are covered without this test naming them.
      check metadataToJson(restored.artifact.metadata) ==
        metadataToJson(original.metadata)
      check restored.artifact.payload.layout == original.payload.layout
      check restored.artifact.payload.partCount == original.payload.partCount
      check restored.artifact.access.tenantId == original.access.tenantId
      check restored.artifact.displayName == original.displayName

  test "a kind with no legacy binding carries its metadata in full":
    let parts = singleFileParts()
    let dataset = reviewDatasetSample(aplSingleFile, parts)

    let uploadBody = buildArtifactUploadUrlBody(dataset, parts[0].name)
    check uploadBody["artifactId"].getStr == SampleDatasetId
    check uploadBody["kind"].getStr == "review-dataset"
    check uploadBody["metadata"] == metadataToJson(dataset.metadata)

    let sessionBody = buildArtifactUploadSessionBody(dataset, "hook")
    check sessionBody["artifactId"].getStr == SampleDatasetId
    check sessionBody["kind"].getStr == "review-dataset"
    check sessionBody["metadata"] == metadataToJson(dataset.metadata)
    # `recordingMode` is a recording concept. A review dataset is not a run,
    # so it is not sent rather than sent empty.
    check not sessionBody.hasKey("recordingMode")
    check not sessionBody.hasKey("platform")

  test "the recording kind carries exactly what its frozen bodies have room for":
    # Stated as an assertion rather than as a caveat in a comment. The
    # recording kind's request bodies cannot grow keys — a service deployed
    # before this milestone reads them — so what travels is the recording id
    # and the platform, and NOT the program, language or record-start time.
    # If someone later adds a key here, this fails, which is the point.
    let parts = singleFileParts()
    let recording = recordingSample(aplSingleFile, parts)

    let uploadBody = buildArtifactUploadUrlBody(recording, parts[0].name)
    check uploadBody["recordingId"].getStr == SampleRecordingId
    check not uploadBody.hasKey("metadata")
    check not uploadBody.hasKey("artifactId")
    check not uploadBody.hasKey("kind")
    check not uploadBody.hasKey("program")

    let sessionBody = buildArtifactUploadSessionBody(recording, "hook")
    check sessionBody.len == 2
    check sessionBody["platform"].getStr == SamplePlatform
    check sessionBody["recordingMode"].getStr == "hook"

  test "the platform is read from the artifact, not fabricated":
    # `Artifact-Store.md` §8 defect 4: both the session and the finalize body
    # used to send the literal "linux-x86_64" whatever machine ran the upload,
    # so a macOS or Windows recording was labelled Linux. `platform` is what a
    # listing uses to tell a user whether a recording is replayable for them,
    # and a fabricated one sends them to download it and find out.
    var recording = recordingSample(aplSliceSet, sliceParts(2))
    recording.metadata.platform = "macos-aarch64"
    check buildArtifactUploadSessionBody(recording, "hook")["platform"].getStr ==
      "macos-aarch64"
    check buildArtifactFinalizeBody(recording, 2, 0)["platform"].getStr ==
      "macos-aarch64"

  test "the platform token is derived, and an unknown host yields no claim":
    check artifactPlatformToken("linux", "amd64") == "linux-x86_64"
    check artifactPlatformToken("linux", "arm64") == "linux-aarch64"
    check artifactPlatformToken("macosx", "arm64") == "macos-aarch64"
    check artifactPlatformToken("macosx", "amd64") == "macos-x86_64"
    check artifactPlatformToken("windows", "amd64") == "windows-x86_64"
    check artifactPlatformToken("windows", "arm64") == "windows-aarch64"
    # An absence, never a guess: a platform nobody taught this function is
    # reported as unknown rather than as the one that happened to be first.
    for unknown in [("js", "js"), ("haiku", "amd64"), ("linux", "riscv64"),
        ("", ""), ("Linux", "amd64")]:
      checkpoint(unknown[0] & "/" & unknown[1])
      check artifactPlatformToken(unknown[0], unknown[1]) == ""

suite "AS-2 — the recording kind's conversation is character-identical":
  ## Every expectation below is a *literal* pre-AS-2 string. Already-uploaded
  ## traces are real user data at real URLs; the properties that would strand
  ## them are the URL grammar, the request bodies and the identity, so all
  ## three are pinned against literals rather than against the planner's own
  ## output.

  test "the single-file conversation is the pre-AS-2 one, step for step":
    let parts = singleFileParts("tmp.zip")
    let plan = planOf(recordingSample(aplSingleFile, parts), parts)
    let steps = uploadSteps(plan, recordingSession())

    check steps[0].urlPath ==
      "https://web.codetracer.com/api/v1/tenants/tenant-123/traces/upload-url"
    check steps[0].body["recordingId"].getStr == SampleRecordingId
    check steps[0].body["fileName"].getStr == "tmp.zip"
    check steps[0].body["contentType"].getStr == "application/zip"
    check steps[0].body["contentLength"].getBiggestInt == 4242
    check not steps[0].body.hasKey("traceId")

    check steps[1].kind == atsPutPart
    check steps[1].urlPath == ""   # presigned; issued by the step before it

    check steps[2].urlPath ==
      "https://web.codetracer.com/api/v1/traces/" & SampleRecordingId &
      "/confirm-upload"
    check $buildArtifactConfirmUploadBody("abc") == """{"etag":"abc"}"""

  test "the sliced conversation is the pre-AS-2 one, step for step":
    # Driven by a NAMED DIRECTORY (`McrSplitDirectory`: three `.ct` slices plus
    # a `.smnf` and a `.amnf` manifest — what `ct-mcr record --split` emits),
    # so every expectation below is what the pre-AS-2 client sent *for that
    # directory* rather than a restatement of what the planner computes.
    let parts = mcrSplitParts()
    let plan = planOf(recordingSample(aplSliceSet, parts), parts,
      omniscientDbMode = "")
    let steps = uploadSteps(plan, recordingSession())

    check steps[0].urlPath ==
      "https://web.codetracer.com/api/v1/tenants/tenant-123/traces/upload-session"
    check steps[0].body["platform"].getStr == "linux-x86_64"
    check steps[0].body["recordingMode"].getStr == "hook"

    # AS-2's decision: `slice-upload-url` and `finalize` are derived from the
    # SESSION's collection rather than from a literal `traces/`. For the
    # recording kind that derivation reproduces the literal exactly.
    check steps[1].urlPath ==
      "https://web.codetracer.com/api/v1/traces/" & SampleSessionId &
      "/slice-upload-url"
    check steps[^1].urlPath ==
      "https://web.codetracer.com/api/v1/traces/" & SampleSessionId &
      "/finalize"

    # THE number. For this directory the pre-AS-2 client sent 3 — the `.ct`
    # slices — and uploaded the two manifests afterwards without counting
    # them. `totalSlices` is what the deployed CS-M7 `/finalize` reassembles
    # from, so 5 would tell the service to look for two slices that do not
    # exist. Written as a literal, and cross-checked against the object count
    # so it cannot be satisfied by a plan that counts uploads.
    check steps[^1].body["totalSlices"].getInt == 3
    check McrSplitObjectCount == 5     # …and it is NOT this number
    check steps[^1].body["totalEvents"].getInt == 0
    check steps[^1].body["platform"].getStr == "linux-x86_64"
    # M31: `off` is signalled by sending nothing, so a default-mode client
    # round-trips the legacy CS-M7 body unchanged.
    check not steps[^1].body.hasKey("omniscientDbMode")

    # The whole frozen body, compared as one string against the literal the
    # pre-AS-2 client produced for this directory. A field-by-field comparison
    # cannot see a key that was ADDED; this can.
    check $steps[^1].body ==
      """{"totalSlices":3,"totalEvents":0,"platform":"linux-x86_64"}"""
    check $steps[0].body ==
      """{"platform":"linux-x86_64","recordingMode":"hook"}"""

    # And the manifests were still uploaded — the fix must be "do not count
    # them", never "do not send them".
    var uploadedNames: seq[string] = @[]
    for step in steps:
      if step.kind == atsPutPart:
        uploadedNames.add step.part.name
    check uploadedNames == @[
      "slice_0000.ct", "slice_0001.ct", "slice_0002.ct",
      "manifest.smnf", "analysis.amnf"]

  test "M31's omniscient-db mode still reaches the finalize body":
    for wireMode in ["on", "lazy", "pre-prepared"]:
      checkpoint(wireMode)
      let parts = sliceParts(2)
      let plan = planOf(recordingSample(aplSliceSet, parts), parts,
        omniscientDbMode = wireMode)
      let final = uploadCompletionStep(plan, recordingSession())
      check final.body["omniscientDbMode"].getStr == wireMode

  test "a second kind's session cannot publish into the recording collection":
    # The failure the AS-2 decision on those two paths exists to prevent, in
    # mirror image: had they stayed literal `traces/…`, a review dataset
    # uploaded in slices would have published them under the recording kind's
    # collection.
    let session = ArtifactUploadSession(
      sessionId: SampleSessionId, kind: akReviewDataset)
    check artifactSliceUploadUrlPath(SampleBaseApiUrl, session) ==
      "https://web.codetracer.com/api/v1/review-datasets/" & SampleSessionId &
      "/slice-upload-url"
    check artifactFinalizePath(SampleBaseApiUrl, session) ==
      "https://web.codetracer.com/api/v1/review-datasets/" & SampleSessionId &
      "/finalize"

suite "AS-3 — the plan refuses what would make encryption unsafe or a lie":
  ## Two refusals, both added by AS-3, both in the *planner* so they are pure
  ## and both observable before a byte moves.

  test "a payload whose part indices repeat is refused":
    # This reads like tidiness and is not. `artifact_protection.partNonce`
    # derives the AEAD nonce from the part index, so two parts sharing an index
    # would be two messages under one (key, nonce) pair — the one failure mode
    # of GCM that loses the key stream outright (NIST SP 800-38D §8.2). Nonce
    # uniqueness is enforced HERE rather than assumed by the sealer.
    #
    # Before AS-3 the check merely bounded the index, so this planned happily.
    for kind in ArtifactKind:
      checkpoint($kind)
      var parts = sliceParts(3)
      parts[2].index = 0
      let planned = planArtifactUpload(
        sampleArtifact(kind, aplSliceSet, parts), parts,
        SampleBaseApiUrl, SampleTenantId)
      check planned.error.len > 0
      check "repeats index 0" in planned.error
      check parts[2].name in planned.error

  test "the indices that ARE 0 ..< len still plan, so the refusal is not blanket":
    for kind in ArtifactKind:
      checkpoint($kind)
      let parts = sliceParts(4)
      check planArtifactUpload(
        sampleArtifact(kind, aplSliceSet, parts), parts,
        SampleBaseApiUrl, SampleTenantId).error == ""

  test "an unprotected part on a protected artifact is refused":
    # The direction people think of: a payload that would go up in the clear
    # under a record claiming it is encrypted.
    for kind in ArtifactKind:
      checkpoint($kind)
      let parts = singleFileParts()
      var artifact = sampleArtifact(kind, aplSingleFile, parts)
      artifact.access.protection = apPasswordScryptAes256Gcm
      let planned = planArtifactUpload(
        artifact, parts, SampleBaseApiUrl, SampleTenantId)
      check planned.error.len > 0
      check "prepared as 'none'" in planned.error
      check "password-scrypt-aes-256-gcm" in planned.error

  test "a protected part on an unprotected artifact is ALSO refused":
    # The direction people do not think of, and it matters just as much: bytes
    # nothing told the reader to decrypt are bytes the reader cannot open.
    for kind in ArtifactKind:
      checkpoint($kind)
      var parts = singleFileParts()
      parts[0].protection = apPasswordScryptAes256Gcm
      let planned = planArtifactUpload(
        sampleArtifact(kind, aplSingleFile, parts), parts,
        SampleBaseApiUrl, SampleTenantId)
      check planned.error.len > 0
      check "the artifact declares protection 'none'" in planned.error

  test "a payload whose parts agree with the artifact plans, for every kind":
    # The refusal must not be so eager that it rejects a correct protected
    # upload — which is what `artifact_store.prepareProtectedPayload` builds.
    for kind in ArtifactKind:
      checkpoint($kind)
      var parts = sliceParts(3)
      for i in 0 ..< parts.len:
        parts[i].protection = apPasswordScryptAes256Gcm
      var artifact = sampleArtifact(kind, aplSliceSet, parts)
      artifact.access.protection = apPasswordScryptAes256Gcm
      let planned = planArtifactUpload(
        artifact, parts, SampleBaseApiUrl, SampleTenantId)
      check planned.error == ""
      # …and the conversation is the same conversation: encryption wraps the
      # payload, not the request, so the steps are step-for-step what an
      # unprotected artifact of the same shape produces.
      let session = ArtifactUploadSession(
        sessionId: SampleSessionId, kind: kind)
      let protectedSteps = uploadSteps(planned.plan, session)
      let plainParts = sliceParts(3)
      let plainSteps = uploadSteps(
        planOf(sampleArtifact(kind, aplSliceSet, plainParts), plainParts),
        session)
      check protectedSteps.len == plainSteps.len
      for i in 0 ..< protectedSteps.len:
        check protectedSteps[i].kind == plainSteps[i].kind
        check protectedSteps[i].urlPath == plainSteps[i].urlPath

  test "the plan re-addressed to the service's id keeps everything else":
    # `addressedTo` exists so the single-file confirmation names the id the
    # SERVICE echoed rather than the local one. It must move that and nothing
    # else, or it would be a second place a plan can be built.
    let parts = singleFileParts()
    let plan = planOf(reviewDatasetSample(aplSingleFile, parts), parts)
    var renamed = plan.artifact
    renamed.artifactId = "0194a000-1111-7abc-8def-000000000099"
    let moved = plan.addressedTo(renamed)
    check moved.artifact.artifactId == renamed.artifactId
    check moved.parts == plan.parts
    check moved.baseApiUrl == plan.baseApiUrl
    check moved.tenantId == plan.tenantId
    check uploadCompletionStep(moved, ArtifactUploadSession(), "e").urlPath ==
      SampleBaseApiUrl & "review-datasets/" & renamed.artifactId &
      "/confirm-upload"

suite "AS-2 — a download resolves the kind, and refuses to guess it":
  ## A share link carries no kind. The client must therefore *ask*, and must
  ## refuse when the answer does not settle it — the same rule
  ## `parseArtifactShareUrl` follows one layer up.

  test "the kind-neutral collection is asked first, then the kind's alias":
    let candidates = artifactDownloadCandidates(
      SampleRecordingId, none(ArtifactKind))
    check candidates[0].kind.isNone
    # Exhaustive over the closed set: a new kind becomes reachable from a
    # share link by existing, without anything naming it here.
    check candidates.len == 1 + 2
    var kindsOffered: seq[string] = @[]
    for candidate in candidates:
      check candidate.artifactId == SampleRecordingId
      if candidate.kind.isSome:
        kindsOffered.add kindSpec(candidate.kind.get).wireToken
    check kindsOffered == @["recording", "review-dataset"]

  test "a caller that knows the kind asks that collection before the others":
    let candidates = artifactDownloadCandidates(
      SampleDatasetId, some(akReviewDataset))
    check candidates[0].kind.isNone
    check candidates[1].kind == some(akReviewDataset)
    check candidates.len == 3

  test "a probe that finds no route moves on; an answer does not":
    # `ct download` now asks the kind-neutral `artifacts/` collection first,
    # and no deployed service routes it. What a service *says* about a path it
    # has no rule for is not under this client's control — an API gateway may
    # answer 400, 403 or 501 as readily as 404 — so treating those as fatal on
    # the probe would abort a download of an artifact that is right there.
    let neutral = ArtifactRef(
      artifactId: SampleRecordingId, kind: none(ArtifactKind))
    for status in [400, 403, 404, 405, 501]:
      checkpoint("neutral " & $status)
      check downloadProbeMayContinue(neutral, status)

    # A kind's own collection is different: its route certainly exists on any
    # service that serves the kind, so a 403 there is an ANSWER — "you may not
    # read this" — and walking past it would report a permission problem as a
    # missing artifact.
    let recordings = recordingArtifactRef(SampleRecordingId)
    check downloadProbeMayContinue(recordings, 404)
    check downloadProbeMayContinue(recordings, 405)
    for status in [400, 403, 501]:
      checkpoint("kind-specific " & $status)
      check not downloadProbeMayContinue(recordings, status)

    # Never, on either: 401 is about the caller's credentials rather than the
    # collection, so every candidate would answer the same and reporting the
    # last one hides the first. A broken service is not one that lacks the
    # artifact.
    for candidate in [neutral, recordings]:
      for status in [401, 500, 502, 503, 429]:
        checkpoint($status)
        check not downloadProbeMayContinue(candidate, status)

  test "the service naming the kind settles it":
    let neutral = ArtifactRef(
      artifactId: SampleDatasetId, kind: none(ArtifactKind))
    let resolved = resolveDownloadedKind(neutral, %*{
      "downloadUrl": "https://s3.example/x",
      "kind": "review-dataset"})
    check resolved.error == ""
    check resolved.kind == some(akReviewDataset)

  test "a full record in the response settles it, and carries the metadata":
    let parts = singleFileParts()
    let dataset = reviewDatasetSample(aplSingleFile, parts)
    let neutral = ArtifactRef(
      artifactId: SampleDatasetId, kind: none(ArtifactKind))
    let body = %*{
      "downloadUrl": "https://s3.example/x",
      "artifact": dataset.toJson()}
    let resolved = resolveDownloadedKind(neutral, body)
    check resolved.error == ""
    check resolved.kind == some(akReviewDataset)
    let record = parseDownloadedArtifact(body)
    check record.error == ""
    check record.artifact.metadata.commitSha == dataset.metadata.commitSha
    check record.artifact.metadata.sessionTitle == "parser cleanup"

  test "a kind-specific collection answering settles it":
    # Not an inference from the URL's shape: the client asked the recording
    # collection and the recording collection said yes.
    let viaRecordings = ArtifactRef(
      artifactId: SampleRecordingId, kind: some(akRecording))
    let resolved = resolveDownloadedKind(viaRecordings, %*{
      "downloadUrl": "https://s3.example/x", "expiresAt": "later"})
    check resolved.error == ""
    check resolved.kind == some(akRecording)

  test "the kind-neutral collection answering without a kind is refused":
    # The one case where guessing would be easy and wrong. A resolver that
    # answered `recording` here would mis-route the first review dataset ever
    # shared this way — which is exactly what `parseArtifactShareUrl` refuses
    # to do from the URL, moved one layer down.
    let neutral = ArtifactRef(
      artifactId: SampleDatasetId, kind: none(ArtifactKind))
    let resolved = resolveDownloadedKind(neutral, %*{
      "downloadUrl": "https://s3.example/x", "expiresAt": "later"})
    check resolved.kind.isNone
    check resolved.error.len > 0
    check SampleDatasetId in resolved.error

  test "a kind the client does not understand is refused, naming the token":
    let neutral = ArtifactRef(
      artifactId: SampleDatasetId, kind: none(ArtifactKind))
    for token in ["heap-dump", "trace", "Recording", "", "video"]:
      checkpoint(token)
      let resolved = resolveDownloadedKind(neutral, %*{
        "downloadUrl": "https://s3.example/x", "kind": token})
      check resolved.kind.isNone
      check resolved.error.len > 0
      check "recording" in resolved.error
      check "review-dataset" in resolved.error

  test "a record whose kind is unknown is refused rather than downloaded":
    let neutral = ArtifactRef(
      artifactId: SampleDatasetId, kind: none(ArtifactKind))
    let resolved = resolveDownloadedKind(neutral, %*{
      "downloadUrl": "https://s3.example/x",
      "artifact": {"kind": "heap-dump", "artifactId": SampleDatasetId}})
    check resolved.kind.isNone
    check "heap-dump" in resolved.error

  test "a pre-AS-2 response carries no record, and that is not an error":
    let record = parseDownloadedArtifact(%*{
      "downloadUrl": "https://s3.example/x", "expiresAt": "later"})
    check record.error == ""
    check record.artifact.artifactId.len == 0

suite "AS-2 — the CLI says the kind only where it must":
  ## `ct upload <PATH>` can recognise most kinds from what is on disk, so it
  ## does; where it cannot, it refuses and asks rather than picking one.

  test "a directory holding a review.json is a review dataset":
    let evidence = LocalArtifactEvidence(
      pathExists: true, isDirectory: true, hasReviewDatasetJson: true)
    let classified = classifyArtifactEvidence("/tmp/review-out", evidence)
    check classified.error == ""
    check classified.kind == some(akReviewDataset)

  test "a directory holding a recording's markers is a recording":
    for evidence in [
        LocalArtifactEvidence(pathExists: true, isDirectory: true,
          hasCtContainer: true),
        LocalArtifactEvidence(pathExists: true, isDirectory: true,
          hasTraceMetadata: true),
        LocalArtifactEvidence(pathExists: true, isDirectory: true,
          hasRrVersionFile: true)]:
      let classified = classifyArtifactEvidence("/tmp/trace-out", evidence)
      check classified.error == ""
      check classified.kind == some(akRecording)

  test "a directory that could be either is refused, and asks":
    let evidence = LocalArtifactEvidence(
      pathExists: true, isDirectory: true,
      hasReviewDatasetJson: true, hasCtContainer: true)
    let classified = classifyArtifactEvidence("/tmp/both", evidence)
    check classified.kind.isNone
    check "--kind" in classified.error
    check "review-dataset" in classified.error
    check "recording" in classified.error

  test "a directory that is neither is refused, naming what was looked for":
    let evidence = LocalArtifactEvidence(pathExists: true, isDirectory: true)
    let classified = classifyArtifactEvidence("/tmp/empty", evidence)
    check classified.kind.isNone
    check "review.json" in classified.error
    check ".ct" in classified.error

  test "a path that is not there is refused before anything else":
    let classified = classifyArtifactEvidence(
      "/tmp/nope", LocalArtifactEvidence())
    check classified.kind.isNone
    check "nothing to upload" in classified.error

  test "an explicit --kind is honoured, and checked against the closed set":
    let evidence = LocalArtifactEvidence(pathExists: true, isDirectory: true)
    for kind in ArtifactKind:
      checkpoint($kind)
      let named = classifyArtifactEvidence(
        "/tmp/whatever", evidence, kindSpec(kind).wireToken)
      check named.error == ""
      check named.kind == some(kind)

    for rejected in ["heap-dump", "trace", "traces", "Recording",
        "review_dataset", "application/zip", " recording"]:
      checkpoint(rejected)
      let refused = classifyArtifactEvidence(
        "/tmp/whatever", evidence, rejected)
      check refused.kind.isNone
      check rejected in refused.error
      check "recording" in refused.error
      check "review-dataset" in refused.error
