## AS-1 — the artifact model, its closed kind registry, and the migration
## that keeps one system.
##
## Spec: `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-1 and the
## design it asks for, `codetracer-specs/Sharing/Artifact-Store.md`.
##
## The three things AS-1 asks to be verified, and what each is really
## guarding:
##
## 1. **the artifact model round-trips every declared kind** — driven by
##    `for kind in ArtifactKind`, so a kind added to the enum without
##    serialisation, validation and a display-name derivation fails here
##    rather than at the first upload of that kind.
##
## 2. **an already-uploaded trace remains downloadable after migration** —
##    real user data sits at real URLs today.  The properties that would break
##    it are the URL grammar, the identity, and the share-link parser, so all
##    three are pinned against the *literal pre-AS-1 strings* rather than
##    against the new code's own output.  A test that asked the new builder to
##    agree with itself would pass through any rename.
##
## 3. **an unknown kind is refused rather than stored opaquely** — the rule
##    that stops this becoming a general file store.  Asserted as behaviour
##    (`parseArtifact` errors, and the error names the token and the closed
##    set), not as the absence of a code path.
##
## Headless on both Nim backends — `just test-vm-native` and `just test-vm-js`
## reach it by globbing `src/tests/gui/tests/**/*_test.nim`, and
## `CoreViewModelGateTests` in `src/ct_test/release_gate.nim` is the registry
## that says it must exist and must not be skip-disabled.  Both are needed: a
## file named only in the gate runs nowhere, and a file reached only by a glob
## has nothing asserting it still exists.

import std/[json, options, strutils, tables, unittest]

import ../../../../ct/online_sharing/artifact

const
  # A canonical UUIDv7, in the exact form the recorder mints at record start.
  SampleRecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  SampleDatasetId = "0194a000-1111-7abc-8def-000000000001"
  SampleBaseApiUrl = "https://web.codetracer.com/api/v1/"
  SampleTenantId = "tenant-123"

proc sampleMetadata(kind: ArtifactKind): ArtifactMetadata =
  ## A fully populated metadata record for each declared kind.  Exhaustive
  ## `case`: a new kind must supply a sample here, which is what makes the
  ## round-trip loop below cover it rather than silently skip it.
  case kind
  of akRecording:
    ArtifactMetadata(
      kind: akRecording,
      recordingId: SampleRecordingId,
      program: "sudoku",
      langName: "LangNoir",
      platform: "linux-x86_64",
      recordedAtUnixMs: 1_700_000_000_000'i64)
  of akReviewDataset:
    ArtifactMetadata(
      kind: akReviewDataset,
      commitSha: "9f1c2d3e4b5a69788796a5b4c3d2e1f009182736",
      baseCommitSha: "1122334455667788990011223344556677889900",
      fileCount: 7,
      recordingCount: 2,
      sessionTitle: "parser cleanup")

proc sampleArtifactId(kind: ArtifactKind): string =
  ## The recording kind's artifact id is *seeded from* its recording id (the
  ## `aioSeededFromRecordingId` binding); every other kind's is minted at
  ## store time and is unrelated to anything the payload contains.
  case kind
  of akRecording: SampleRecordingId
  of akReviewDataset: SampleDatasetId

proc sampleArtifact(kind: ArtifactKind): Artifact =
  let metadata = sampleMetadata(kind)
  Artifact(
    artifactId: sampleArtifactId(kind),
    kind: kind,
    access: initArtifactAccess(SampleTenantId),
    createdAtUnixMs: 1_700_000_500_000'i64,
    payload: ArtifactPayload(
      layout: aplSingleFile,
      contentType: kindSpec(kind).defaultContentType,
      byteSize: 4242,
      partCount: 1),
    displayName: suggestedDisplayName(metadata),
    metadata: metadata)

suite "AS-1 — the artifact model round-trips every declared kind":

  test "every declared kind survives a JSON round trip unchanged":
    var kindsCovered = 0
    for kind in ArtifactKind:
      checkpoint($kind)
      let original = sampleArtifact(kind)
      # The model must consider its own sample storable — otherwise the round
      # trip below would be proving that malformed records survive.
      check validateArtifact(original).isNone

      let parsed = parseArtifact(original.toJson())
      check parsed.error == ""
      let restored = parsed.artifact

      check restored.artifactId == original.artifactId
      check restored.kind == original.kind
      check restored.createdAtUnixMs == original.createdAtUnixMs
      check restored.displayName == original.displayName
      check restored.access.tenantId == original.access.tenantId
      check restored.access.visibility == original.access.visibility
      check restored.access.minimumWriteRole == original.access.minimumWriteRole
      check restored.access.protection == original.access.protection
      check restored.payload.layout == original.payload.layout
      check restored.payload.contentType == original.payload.contentType
      check restored.payload.byteSize == original.payload.byteSize
      check restored.payload.partCount == original.payload.partCount

      # The kind-specific half, compared as its own serialised form so a new
      # kind's fields are covered without this test naming them.
      check metadataToJson(restored.metadata) ==
        metadataToJson(original.metadata)
      check restored.metadata.kind == kind

      # Re-serialising a parsed record reproduces the wire form byte for byte;
      # this is what makes the round trip a fixed point rather than a one-way
      # decode that happens to look right.
      check $restored.toJson() == $original.toJson()
      inc kindsCovered

    # A loop over an enum cannot go vacuous, but a future refactor that made
    # `ArtifactKind` dynamic could. Two kinds exist as of AS-1.
    check kindsCovered == 2

  test "every declared kind carries metadata suitable to it":
    # The rule the store is built on: an artifact ALWAYS carries metadata for
    # its kind. A kind whose registry row cannot say what the product does
    # with it does not belong, so that string is asserted non-empty too.
    for kind in ArtifactKind:
      checkpoint($kind)
      let spec = kindSpec(kind)
      check spec.kind == kind
      check spec.wireToken == $kind
      check spec.whatCodeTracerDoes.len > 0
      check spec.urlSegment.len > 0
      check spec.allowedLayouts.len > 0
      check spec.defaultContentType.len > 0
      # A listing must be able to name the row without opening it (AS-4).
      check suggestedDisplayName(sampleMetadata(kind)).len > 0

    let summary = kindRegistrySummary()
    check summary.len == 2
    check summary.hasKey("recording")
    check summary.hasKey("review-dataset")

  test "a recording whose program the local index does not know is storable":
    # An imported recording — one downloaded from the store and re-shared —
    # may reach this layer with no program name. Refusing a real upload in
    # order to enforce a nicer listing label would be the wrong trade, so the
    # program is optional; the listing requirement is met by the common
    # `displayName`, which falls back rather than inventing a name.
    var nameless = sampleArtifact(akRecording)
    nameless.metadata.program = ""
    nameless.displayName = suggestedDisplayName(nameless.metadata)
    check validateArtifact(nameless).isNone
    check nameless.displayName == "recording"

  test "an artifact whose metadata contradicts its kind is refused":
    # The variant makes the mismatch constructible only deliberately; the
    # model must still refuse it rather than serialise a record whose `kind`
    # and `metadata` disagree.
    var mismatched = sampleArtifact(akRecording)
    mismatched.metadata = sampleMetadata(akReviewDataset)
    let problem = validateArtifact(mismatched)
    check problem.isSome
    check "does not match its metadata kind" in problem.get

suite "AS-1 — an already-uploaded trace remains downloadable after migration":
  ## Every assertion in this suite compares against a *literal* pre-AS-1
  ## string. That is the point: the recording kind's URL space and identity
  ## are load-bearing for data that is already on the service, and a test that
  ## regenerated the expectation from the same registry it is testing would
  ## agree with any rename.

  test "the recording kind still lives under the legacy traces/ segment":
    check kindSpec(akRecording).urlSegment == "traces"

  test "upload-url path is character-identical to the pre-AS-1 path":
    check artifactUploadUrlPath(SampleBaseApiUrl, SampleTenantId, akRecording) ==
      "https://web.codetracer.com/api/v1/tenants/tenant-123/traces/upload-url"

  test "upload-session path is character-identical to the pre-AS-1 path":
    check artifactUploadSessionPath(
        SampleBaseApiUrl, SampleTenantId, akRecording) ==
      "https://web.codetracer.com/api/v1/tenants/tenant-123/traces/upload-session"

  test "confirm-upload path is character-identical to the pre-AS-1 path":
    check artifactConfirmUploadPath(
        SampleBaseApiUrl, recordingArtifactRef(SampleRecordingId)) ==
      "https://web.codetracer.com/api/v1/traces/" &
        SampleRecordingId & "/confirm-upload"

  test "download-url path is character-identical to the pre-AS-1 path":
    check artifactDownloadUrlPath(
        SampleBaseApiUrl, recordingArtifactRef(SampleRecordingId)) ==
      "https://web.codetracer.com/api/v1/traces/" &
        SampleRecordingId & "/download-url"

  test "the upload-url body still carries recordingId, not artifactId":
    # M-REC-8 put `recordingId` on this body and the deployed service reads
    # it. For recordings the artifact id IS the recording id, so renaming the
    # key would be a wire break for no gain — and would strand every trace
    # uploaded before the rename.
    let body = buildArtifactUploadUrlBody(
      recordingArtifactRef(SampleRecordingId),
      fileName = "trace.zip",
      contentType = "application/zip",
      contentLength = 4242)
    check body["recordingId"].getStr == SampleRecordingId
    check body["fileName"].getStr == "trace.zip"
    check body["contentType"].getStr == "application/zip"
    check body["contentLength"].getInt == 4242
    check not body.hasKey("artifactId")
    check not body.hasKey("traceId")

  test "a share URL issued before AS-1 still resolves to its artifact":
    # The exact shape the service hands out: /{orgSlug}/{recordingId}/download.
    # It carries NO kind, which is precisely why it survives — the id is
    # unique across kinds, so nothing about the link has to be rewritten.
    let issued = "https://web.codetracer.com/acme/" &
      SampleRecordingId & "/download"
    let resolved = parseArtifactShareUrl(issued)
    check resolved.orgSlug == "acme"
    check resolved.artifactId == SampleRecordingId

  test "a share URL without the trailing /download still resolves":
    let issued = "https://web.codetracer.com/acme/" & SampleRecordingId
    let resolved = parseArtifactShareUrl(issued)
    check resolved.orgSlug == "acme"
    check resolved.artifactId == SampleRecordingId

  test "the recording id is the artifact id, and a mismatch is refused":
    # The `aioSeededFromRecordingId` binding, checked rather than assumed. If
    # these two ever diverge, every share URL already issued for the recording
    # resolves to nothing — so the model refuses the divergence at the point
    # it is constructed.
    check kindSpec(akRecording).idOrigin == aioSeededFromRecordingId
    let sound = sampleArtifact(akRecording)
    check validateArtifact(sound).isNone

    var diverged = sound
    diverged.artifactId = SampleDatasetId
    let problem = validateArtifact(diverged)
    check problem.isSome
    check "does not match its recording id" in problem.get

  test "a kind with no record-start moment mints its id at store time":
    # The other half of the id decision: a review dataset has no equivalent of
    # record start, so its id comes from the store.
    check kindSpec(akReviewDataset).idOrigin == aioMintedAtStore
    let dataset = sampleArtifact(akReviewDataset)
    check validateArtifact(dataset).isNone
    check dataset.artifactId != SampleRecordingId

  test "a caller that does not know the kind addresses the neutral segment":
    # Resolving a share link yields an id and no kind. That case must not fall
    # back to `traces/` — a resolver that guessed `recording` from the URL
    # shape would mis-route the first review dataset shared this way.
    let unknownKind = ArtifactRef(
      artifactId: SampleDatasetId, kind: none(ArtifactKind))
    check artifactDownloadUrlPath(SampleBaseApiUrl, unknownKind) ==
      "https://web.codetracer.com/api/v1/artifacts/" &
        SampleDatasetId & "/download-url"

suite "AS-1 — an unknown kind is refused rather than stored opaquely":
  ## The rule that keeps the store from becoming a general file service. These
  ## are behavioural assertions: the refusal happens, and it says enough to be
  ## acted on.

  test "parseArtifactKind admits exactly the declared tokens":
    check parseArtifactKind("recording") == some(akRecording)
    check parseArtifactKind("review-dataset") == some(akReviewDataset)

  test "parseArtifactKind refuses everything else":
    # Plausible-looking neighbours, near misses and outright junk. None of
    # these may resolve, and in particular none may fall back to a default.
    for rejected in [
        "", " ", "trace", "traces", "Recording", "RECORDING", "recordings",
        "review", "reviewdataset", "review_dataset", "screenshot", "video",
        "application/zip", "zip", "profile", "heap-dump", "other", "unknown"]:
      checkpoint(rejected)
      check parseArtifactKind(rejected).isNone

  test "an artifact record of an unknown kind is refused, not kept":
    # A well-formed record in every respect EXCEPT its kind. A general file
    # store would keep the bytes; this one must not, because nothing could
    # ever open them.
    let smuggled = %*{
      "artifactId": SampleDatasetId,
      "kind": "heap-dump",
      "createdAtUnixMs": 1_700_000_500_000'i64,
      "displayName": "a heap dump",
      "access": {
        "tenantId": SampleTenantId,
        "visibility": "tenant",
        "minimumWriteRole": "member",
        "protection": "none",
      },
      "payload": {
        "layout": "single-file",
        "contentType": "application/octet-stream",
        "byteSize": 999,
        "partCount": 1,
      },
      "metadata": {"anything": "at all"},
    }
    let parsed = parseArtifact(smuggled)
    check parsed.error.len > 0
    # The refusal must name the offending token and the closed set, so the
    # answer to "why was this rejected" does not require reading the source.
    check "heap-dump" in parsed.error
    check "recording" in parsed.error
    check "review-dataset" in parsed.error
    # Nothing was retained: the returned artifact is the zero value, not the
    # smuggled record with its kind quietly dropped.
    check parsed.artifact.artifactId.len == 0

  test "a record with no kind at all is refused":
    let kindless = %*{
      "artifactId": SampleDatasetId,
      "displayName": "no kind here",
    }
    let parsed = parseArtifact(kindless)
    check parsed.error.len > 0
    check "no kind" in parsed.error

  test "a record whose kind is not a string is refused":
    check parseArtifact(%*{"artifactId": SampleDatasetId, "kind": 7}).error.len > 0
    check parseArtifact(%*{"kind": ["recording"]}).error.len > 0

  test "a non-object record is refused":
    check parseArtifact(%*"recording").error.len > 0
    check parseArtifact(newJArray()).error.len > 0

  test "an unknown payload layout is refused":
    # The other door into "store anything": a declared kind with a transfer
    # shape the store does not implement.
    var record = sampleArtifact(akRecording).toJson()
    record["payload"]["layout"] = %"torrent"
    let parsed = parseArtifact(record)
    check parsed.error.len > 0
    check "torrent" in parsed.error

  test "a layout the kind does not allow is refused by validation":
    var artifact = sampleArtifact(akRecording)
    artifact.payload.layout = aplSliceSet
    artifact.payload.partCount = 0
    let problem = validateArtifact(artifact)
    check problem.isSome
    check "no parts" in problem.get

suite "AS-1 — the access model is kind-neutral and reuses what exists":

  test "an artifact always names an owning tenant":
    for kind in ArtifactKind:
      checkpoint($kind)
      var orphan = sampleArtifact(kind)
      orphan.access.tenantId = ""
      let problem = validateArtifact(orphan)
      check problem.isSome
      check "owning tenant" in problem.get

  test "sharing is granted by the existing invite concept, not a new ACL":
    # Two visibilities and nothing else: the tenant (who already owns the
    # artifact) and the holder of a collab invite (the grant CodeTracer
    # already exchanges). There is deliberately no per-artifact user list.
    var visibilities = 0
    for visibility in ArtifactVisibility:
      inc visibilities
    check visibilities == 2
    check $avTenant == "tenant"
    check $avTenantOrInvite == "tenant-or-invite"

  test "protection defaults to 'none', and 'none' claims nothing":
    # AS-1 asserted this enum had exactly ONE value, so that AS-3 would have to
    # widen it deliberately rather than quietly. AS-3 widened it — deliberately,
    # by editing this test — and the cardinality assertion moved to
    # `artifact_protection_vm_test.nim`, where it now sits beside a stronger
    # guard: the protection registry is indexed by the enum, so a value without
    # a row stating what it protects against, what it does not, and what
    # recovery exists does not compile.
    #
    # What stays HERE is the property this suite is about: an artifact is
    # unprotected unless somebody asked for protection, and `apNone` must not
    # be read as a claim.
    check $apNone == "none"
    check not protectionSpec(apNone).encryptsPayload
    check not protectionSpec(apNone).requiresSecretToRead
    for kind in ArtifactKind:
      checkpoint($kind)
      # The default construction, and the one every pre-AS-3 caller gets.
      check sampleArtifact(kind).access.protection == apNone
      check initArtifactAccess(SampleTenantId).protection == apNone

  test "the access record round-trips for every kind":
    for kind in ArtifactKind:
      checkpoint($kind)
      var artifact = sampleArtifact(kind)
      artifact.access = initArtifactAccess(
        SampleTenantId, avTenantOrInvite, arAdmin)
      let restored = parseArtifact(artifact.toJson()).artifact
      check restored.access.visibility == avTenantOrInvite
      check restored.access.minimumWriteRole == arAdmin
      check restored.access.protection == apNone
      # AS-3: and the protection the caller asked for survives too, rather
      # than the round trip only being exercised on the default.
      var protected = sampleArtifact(kind)
      protected.access = initArtifactAccess(SampleTenantId,
        protection = apPasswordScryptAes256Gcm)
      check parseArtifact(protected.toJson()).artifact.access.protection ==
        apPasswordScryptAes256Gcm

suite "AS-2 — unknown access-control tokens are refused, as unknown kinds are":
  ## `Artifact-Store.md` §8 defect 10.  Before AS-2, `parseArtifact` read
  ## `visibility`, `minimumWriteRole` and `protection` with the **two-argument**
  ## `parseEnum`, whose second argument is a *fallback* rather than a validator:
  ## `"public"` read as `avTenant`, `"owner"` read as `arMember`, and
  ## `"aes-256-gcm"` read as `apNone`, all silently.  Two of those coercions
  ## fail closed; `minimumWriteRole` fails **open**.
  ##
  ## The one that matters most is `protection`, and it matters to AS-3 rather
  ## than to today: once a second `ArtifactProtection` value exists, a client
  ## built before it that meets a record declaring that value would read an
  ## *encrypted* artifact as unprotected — plaintext-safe — instead of refusing
  ## it.  So the refusal has to be in place BEFORE the second value is, which
  ## is why it lands here and not in AS-3.
  ##
  ## The kind field was already exact-matched and refused with no coercion, so
  ## these suites deliberately mirror the shape of the kind suites above: the
  ## refusal happens, and the error names the offending token and the closed
  ## set.

  test "an unknown visibility is refused, naming the token and the closed set":
    var record = sampleArtifact(akRecording).toJson()
    record["access"]["visibility"] = %"public"
    let parsed = parseArtifact(record)
    check parsed.error.len > 0
    check "public" in parsed.error
    check "tenant" in parsed.error
    check "tenant-or-invite" in parsed.error
    # Nothing retained: the record is refused, not accepted with the field
    # quietly narrowed to a value the sender did not send.
    check parsed.artifact.artifactId.len == 0

  test "an unknown write role is refused rather than read as 'member'":
    # This is the fail-OPEN one: `"owner"` silently became `arMember`, the
    # weaker of the two rungs, so a record asking for a stricter write scope
    # was honoured as the looser one.
    var record = sampleArtifact(akRecording).toJson()
    record["access"]["minimumWriteRole"] = %"owner"
    let parsed = parseArtifact(record)
    check parsed.error.len > 0
    check "owner" in parsed.error
    check "member" in parsed.error
    check "admin" in parsed.error
    check parsed.artifact.artifactId.len == 0

  test "an unknown protection is refused rather than read as 'none'":
    # AS-3's seam, guarded before AS-3 widens it.  A record that declares a
    # protection this client does not implement must be REFUSED — reading it as
    # `none` would present an encrypted payload as plaintext-safe.
    for token in ["aes-256-gcm", "password", "client-side", "None", "NONE",
        "none ", " none"]:
      checkpoint(token)
      var record = sampleArtifact(akReviewDataset).toJson()
      record["access"]["protection"] = %token
      let parsed = parseArtifact(record)
      check parsed.error.len > 0
      check token in parsed.error
      check "none" in parsed.error
      check parsed.artifact.artifactId.len == 0

  test "access-control matching is exact, the way kind matching is":
    # The same adversarial shapes the kind suite refuses: whitespace padding,
    # case variants, near misses and separators.  None may resolve, and none
    # may fall back to a default.
    for token in ["", " ", "Tenant", "TENANT", "tenant ", " tenant",
        "tenant\n", "tenant\t", "tenant_or_invite", "tenantOrInvite",
        "tenant–or–invite",  # en-dash homoglyphs
        "invite", "public", "private", "everyone", "null", "undefined", ".."]:
      checkpoint(token)
      var record = sampleArtifact(akRecording).toJson()
      record["access"]["visibility"] = %token
      check parseArtifact(record).error.len > 0

    for token in ["", " ", "Member", "MEMBER", "member ", "owner", "root",
        "administrator", "Admin", "admin\n", "null", "undefined"]:
      checkpoint(token)
      var record = sampleArtifact(akRecording).toJson()
      record["access"]["minimumWriteRole"] = %token
      check parseArtifact(record).error.len > 0

  test "an access field that is not a string is refused":
    # The other half of the same hole: `getStr()` on a number returns "", which
    # the old code fed straight into the fallback.  A record whose visibility
    # is `7` is malformed, not "tenant".
    for badValue in [%7, %true, %(%*{"a": 1}), %(newJArray())]:
      checkpoint($badValue)
      for field in ["visibility", "minimumWriteRole", "protection"]:
        var record = sampleArtifact(akRecording).toJson()
        record["access"][field] = badValue
        let parsed = parseArtifact(record)
        check parsed.error.len > 0
        check field in parsed.error

  test "a payload layout that is not a string is refused":
    # Same shape, same cause, on the payload half: an empty `getStr()` fell
    # through to `aplSingleFile` instead of being refused.
    for badValue in [%7, %true, %(newJArray())]:
      checkpoint($badValue)
      var record = sampleArtifact(akRecording).toJson()
      record["payload"]["layout"] = badValue
      let parsed = parseArtifact(record)
      check parsed.error.len > 0
      check "layout" in parsed.error

  test "the pre-AS-3 wire form — no protection key at all — still reads":
    # Absence is not the same as an unknown value.  A record written before
    # protection existed genuinely has none, so an absent key keeps its
    # documented default; only a token this client cannot interpret is refused.
    var record = sampleArtifact(akRecording).toJson()
    record["access"].delete("protection")
    let parsed = parseArtifact(record)
    check parsed.error == ""
    check parsed.artifact.access.protection == apNone

  test "every declared access-control token still round-trips":
    # The refusal must not be so eager that it rejects what the model itself
    # writes.  Every value of every access enum, through the wire form.
    for visibility in ArtifactVisibility:
      for role in ArtifactRole:
        for protection in ArtifactProtection:
          checkpoint($visibility & "/" & $role & "/" & $protection)
          var artifact = sampleArtifact(akReviewDataset)
          artifact.access = ArtifactAccess(
            tenantId: SampleTenantId, visibility: visibility,
            minimumWriteRole: role, protection: protection)
          let parsed = parseArtifact(artifact.toJson())
          check parsed.error == ""
          check parsed.artifact.access.visibility == visibility
          check parsed.artifact.access.minimumWriteRole == role
          check parsed.artifact.access.protection == protection

suite "AS-1 — the artifact id is a kind-neutral UUIDv7":

  test "a non-UUIDv7 id is refused for every kind":
    for kind in ArtifactKind:
      checkpoint($kind)
      for bad in ["", "42", "not-a-uuid",
          "01949FCC-7D92-7E9C-AAAA-BBBBBBBBBBBB",  # uppercase
          "01949fcc-7d92-4e9c-aaaa-bbbbbbbbbbbb"]: # UUIDv4, not v7
        checkpoint(bad)
        var artifact = sampleArtifact(kind)
        artifact.artifactId = bad
        if kind == akRecording:
          # Keep the seeding invariant satisfied so the failure under test is
          # the id's shape rather than the recording binding.
          artifact.metadata.recordingId = bad
        check validateArtifact(artifact).isSome
