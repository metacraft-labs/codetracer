## The CodeTracer artifact model (AS-1).
##
## `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-1, and the
## design that milestone asks for, written up in
## `codetracer-specs/Sharing/Artifact-Store.md`.
##
## ## What this module is
##
## The sharing path in this directory was trace-shaped end to end: its entry
## point took a `Trace`, its URL space was `tenants/{id}/traces/…` and its
## identity was `recordingId`, the UUIDv7 the recorder mints at *record start*.
## A review dataset has no record-start moment and is not a trace, so sharing
## one meant either masquerading as a trace or standing up a second transport.
##
## This module is the kind-neutral middle: an **artifact** is an id, a kind
## CodeTracer understands, metadata suitable to that kind, and a descriptor of
## the bytes.  Everything in `api_client.nim` that used to spell the URL space
## by hand now derives it from the kind registry below, so there is one system
## rather than two.
##
## ## The rule this module enforces
##
## This is **not** a general file store.  `ArtifactKind` is a closed enum and
## `parseArtifactKind` refuses anything outside it, so bytes of an unrecognised
## kind cannot be stored opaquely — there is no "other" arm and no free-form
## `contentType` that would let one in through the side door.  If a proposed
## kind cannot say what CodeTracer would *do* with it, it does not belong; the
## registry makes each kind state that in `whatCodeTracerDoes`.
##
## ## What a new kind owes
##
## `ArtifactKindRegistry` is indexed *by the enum*, so adding a value to
## `ArtifactKind` without adding its registry row is a compile error (a plain
## type mismatch: `array[0..1, ArtifactKindSpec]` where
## `array[ArtifactKind, ArtifactKindSpec]` is wanted), and so is adding one
## without extending the `case` arms in `ArtifactMetadata`,
## `suggestedDisplayName`, `validateArtifact`, `metadataToJson` and
## `metadataFromJson` — five further `not all cases are covered` errors, one
## per obligation.  That is deliberate: the cost of a new kind is paid at the
## point the kind is declared, by the person declaring it, rather than
## discovered later by whoever finds the store holding bytes nothing can open.
##
## The sixth obligation — a sample in the round-trip suite — is enforced the
## same way, one binary further out: `artifact_model_vm_test.nim`'s
## `sampleMetadata` is an exhaustive `case` too, so a kind with no sample does
## not compile either.
##
## ## What this module deliberately does NOT do
##
## There is **no encryption and no password protection** here, because there is
## none anywhere on this path today: access control is a bearer token plus a
## tenant, and nothing else.  `ArtifactProtection` has exactly one value for
## that reason — it is the seam AS-3 extends, not a claim that confidentiality
## already exists.  Reading `apNone` as "no protection beyond transport TLS and
## the bearer token" is the accurate reading.
##
## ## Portability
##
## Pure: no filesystem, no HTTP, no `Trace`, no `langstring`.  It compiles on
## both the C and the JavaScript Nim backends so the model can be asserted in
## the headless ViewModel lane (`just test-vm-native` / `just test-vm-js`),
## which is where `src/tests/gui/tests/sharing/artifact_model_vm_test.nim`
## lives.  Anything that needs an OS CSPRNG (id minting) is behind
## `when not defined(js)`.

import std/[json, options, strutils, tables, uri]

import ../../common/recording_id

# ---------------------------------------------------------------------------
# The closed set of kinds
# ---------------------------------------------------------------------------

type
  ArtifactKind* = enum
    ## The file types CodeTracer understands.  Closed by construction: the
    ## wire token is the enum's string value, `parseArtifactKind` is the only
    ## way in, and it refuses everything else.
    akRecording = "recording"
    akReviewDataset = "review-dataset"

  ArtifactIdOrigin* = enum
    ## Where a kind's artifact id comes from.
    ##
    ## The artifact id is kind-neutral and is minted at *store* time — see
    ## `newArtifactId` and the design note there.  One kind deviates, and the
    ## deviation is a *binding* rule rather than a model rule, which is why it
    ## is declared per kind here instead of being hidden in the id minter.
    aioMintedAtStore = "minted-at-store"
      ## The store mints a fresh UUIDv7 when it first sees the artifact.
    aioSeededFromRecordingId = "seeded-from-recording-id"
      ## The recording kind: the artifact id IS the recording's UUIDv7.
      ##
      ## Not because the model wants a recording concept in it, but because
      ## share URLs already issued to users embed that value
      ## (`/{orgSlug}/{recordingId}/download`).  Minting a *different* id for
      ## recordings would require a server-side alias table to keep those URLs
      ## resolving, and an alias table is a second identity namespace — the
      ## thing this milestone exists to avoid.  Both values are canonical
      ## UUIDv7s, so the column stays kind-neutral in type.

  ArtifactPayloadLayout* = enum
    ## The shape of the bytes on the wire.
    ##
    ## A *transfer* concern, not a kind concern: a recording can be one zip or
    ## a set of slices, and a large review dataset could be sliced the same
    ## way.  Keeping it here rather than on the kind is what lets AS-2 express
    ## slice-based transfer once, for any large artifact.
    aplSingleFile = "single-file"
      ## One blob: a zip, a `.ct` container, a `review.json`.
    aplSliceSet = "slice-set"
      ## Many blobs published under one upload session, in index order.

  ArtifactProtection* = enum
    ## Confidentiality applied to the payload *before* it reaches the service.
    ##
    ## Exactly one value today, and that is the honest state of the world:
    ## nothing on this path encrypts anything.  AS-3 adds values here; callers
    ## must not read `apNone` as "protected by the service".
    apNone = "none"

  ArtifactVisibility* = enum
    ## Who may read.  Both values are existing concepts — see `ArtifactAccess`.
    avTenant = "tenant"
      ## Members of the owning tenant.
    avTenantOrInvite = "tenant-or-invite"
      ## Members of the owning tenant, plus holders of a valid collab invite.

  ArtifactRole* = enum
    ## The minimum tenant role required to write.  These are the roles the
    ## tenant listing already returns (`TenantListItem.role`); this enum does
    ## not invent a role system, it names the two rungs the store cares about.
    arMember = "member"
    arAdmin = "admin"

# ---------------------------------------------------------------------------
# The kind registry
# ---------------------------------------------------------------------------

type
  ArtifactKindSpec* = object
    ## One row of the closed registry.  A kind that cannot fill this in does
    ## not belong in the store.
    kind*: ArtifactKind
    wireToken*: string
      ## The kind's spelling on the wire and in JSON.  Equal to `$kind`; held
      ## explicitly so the registry is self-describing when dumped.
    urlSegment*: string
      ## The collection segment in the REST URL space.  `traces` for the
      ## recording kind — unchanged from before this milestone, which is what
      ## keeps every URL already issued valid.
    whatCodeTracerDoes*: string
      ## The rule that keeps this honest, in one sentence per kind.  If this
      ## cannot be written, the kind does not belong.
    idOrigin*: ArtifactIdOrigin
    allowedLayouts*: set[ArtifactPayloadLayout]
      ## Which transfer shapes the kind may legally be stored in.
    defaultContentType*: string

const
  ArtifactKindRegistry*: array[ArtifactKind, ArtifactKindSpec] = [
    akRecording: ArtifactKindSpec(
      kind: akRecording,
      wireToken: "recording",
      # `traces`, not `recordings`: this is the segment already baked into
      # every upload-url / confirm-upload / download-url call the shipped
      # client makes and every URL the service has handed out.  Renaming it
      # would be a migration with no user-visible benefit and a large
      # compatibility bill, so the recording kind keeps it permanently.
      urlSegment: "traces",
      whatCodeTracerDoes:
        "opens it in the time-travelling debugger: step, seek, inspect " &
        "values, and replay the recorded run",
      idOrigin: aioSeededFromRecordingId,
      allowedLayouts: {aplSingleFile, aplSliceSet},
      defaultContentType: "application/zip"),
    akReviewDataset: ArtifactKindSpec(
      kind: akReviewDataset,
      wireToken: "review-dataset",
      urlSegment: "review-datasets",
      whatCodeTracerDoes:
        "opens it as a DeepReview session: the diff, per-line coverage and " &
        "recorded values for the change it describes",
      idOrigin: aioMintedAtStore,
      allowedLayouts: {aplSingleFile, aplSliceSet},
      defaultContentType: "application/zip"),
  ]

  KindNeutralUrlSegment* = "artifacts"
    ## The kind-neutral collection segment.
    ##
    ## The endpoint family `tenants/{tenantId}/artifacts/…` and
    ## `artifacts/{artifactId}/…` is what a client uses when it does not know
    ## the kind (resolving a share link, for instance — see
    ## `parseArtifactShareUrl`, whose URLs carry no kind).  Per-kind segments
    ## remain valid aliases; the recording kind's `traces` alias is permanent.

proc kindSpec*(kind: ArtifactKind): ArtifactKindSpec =
  ## The registry row for `kind`.  Total: the array is indexed by the enum, so
  ## a kind without a row does not compile.
  ArtifactKindRegistry[kind]

proc parseArtifactKind*(wireToken: string): Option[ArtifactKind] =
  ## The **only** way a kind enters the system from untrusted input.
  ##
  ## Returns `none` for anything outside the closed set — including the empty
  ## string, a differently-cased spelling, and a plausible-looking token for a
  ## kind that has not been declared yet.  There is deliberately no fallback
  ## arm: a store that guesses a kind is a store that holds bytes it cannot
  ## open, which is the failure mode this milestone's third verification item
  ## exists to prevent.
  for kind in ArtifactKind:
    if ArtifactKindRegistry[kind].wireToken == wireToken:
      return some(kind)
  none(ArtifactKind)

# ---------------------------------------------------------------------------
# The artifact
# ---------------------------------------------------------------------------

type
  ArtifactMetadata* = object
    ## Kind-specific metadata.  A variant rather than a `Table[string, string]`
    ## on purpose: a string map would accept a review dataset's keys on a
    ## recording, and "metadata suitable to the kind" would become a comment
    ## rather than a type.
    case kind*: ArtifactKind
    of akRecording:
      recordingId*: string
        ## The UUIDv7 the recorder minted at record start.  **Metadata, not
        ## identity** — see `ArtifactIdOrigin`.  For the recording kind the
        ## artifact id is seeded from this value, which is checked in
        ## `validateArtifact`; the point of keeping the field is that the
        ## *relationship* is then stated rather than assumed by whoever reads
        ## an id and wonders which namespace it is in.
      program*: string
        ## The recorded program, as the trace index knows it.
      langName*: string
        ## The recorded language (`$trace.lang`), for the listing and for
        ## choosing a replay backend.
      platform*: string
        ## e.g. `linux-x86_64`.  A recording is only replayable on a platform
        ## the backend supports, so a listing that cannot say this makes a
        ## user download to find out.
      recordedAtUnixMs*: int64
        ## When the run happened — distinct from `createdAtUnixMs`, which is
        ## when the *store* learned about it.  A recording uploaded a week
        ## later has two different, both meaningful, timestamps.
    of akReviewDataset:
      commitSha*: string
        ## The head commit the review describes.
      baseCommitSha*: string
        ## The commit it is diffed against.
      fileCount*: int
        ## Files in the dataset's diff.
      recordingCount*: int
        ## Recordings the dataset was collected from.
      sessionTitle*: string
        ## The human-readable title `ct review collect` recorded, if any.

  ArtifactPayload* = object
    ## A descriptor of the bytes.  The bytes themselves are never in the model
    ## — they are streamed to and from presigned URLs — so what the model
    ## carries is what transfer and storage need to know about them.
    layout*: ArtifactPayloadLayout
    contentType*: string
    byteSize*: int64
      ## Total size across all parts.  Used for the presigned-URL request and
      ## for the listing; `-1` means "not yet known".
    partCount*: int
      ## 1 for `aplSingleFile`; the number of slices for `aplSliceSet`.

  ArtifactAccess* = object
    ## Who may read, who may write, and how sharing is granted — kind-neutral,
    ## and built out of the two concepts that already exist rather than a third.
    ##
    ## * **Tenant** is the owner.  It is the write scope and the default read
    ##   scope, and it is what `tenant_resolver.nim` already resolves from an
    ##   `--org` slug before any upload.
    ## * **Collab invite** is the grant.  `api_client.exchangeCollabInvite`
    ##   already trades an invite token for bootstrap access to a shared
    ##   replay; extending the same exchange to name an artifact is how a
    ##   non-member gets read access.  There is no third notion of "who can
    ##   see this", and no per-artifact ACL list.
    tenantId*: string
    visibility*: ArtifactVisibility
    minimumWriteRole*: ArtifactRole
    protection*: ArtifactProtection
      ## AS-3's seam.  `apNone` today, for every artifact, always.

  Artifact* = object
    ## An artifact: an id, a kind, kind-specific metadata, and the bytes.
    ##
    ## Every field here is common to *every* kind, and each is common for a
    ## reason that is a property of the store rather than a coincidence
    ## between today's two kinds:
    ##
    ## * `artifactId` — addressing is the store's whole job.  Every URL and
    ##   every grant names it.
    ## * `kind` — refusal needs it.  Without a kind, bytes are opaque and the
    ##   "not a general file store" rule is unenforceable.
    ## * `access` — an artifact with no owner has no answer to "who may
    ##   write", so ownership cannot be per-kind.
    ## * `createdAtUnixMs` — the moment the store learned about the artifact.
    ##   Every kind has one *by definition*: it is created by the act of
    ##   storing.  (Contrast `recordedAtUnixMs`, which only a recording has.)
    ## * `payload` — transfer and storage need the size and shape whatever the
    ##   kind, and slicing must be expressible for any large artifact.
    ## * `displayName` — AS-4 asks for one listing over every kind, and a
    ##   listing needs a label per row.  The field is common because the
    ##   requirement is; its *derivation* is per-kind (`suggestedDisplayName`).
    ## * `metadata` — the variant.  Present on every artifact because "always
    ##   carries metadata suitable to the kind" is the rule, not an option.
    artifactId*: string
    kind*: ArtifactKind
    access*: ArtifactAccess
    createdAtUnixMs*: int64
    payload*: ArtifactPayload
    displayName*: string
    metadata*: ArtifactMetadata

  ArtifactRef* = object
    ## The pair every URL needs: which artifact, and (when the caller knows
    ## it) of which kind.  `kind` is optional because share links carry no
    ## kind — see `parseArtifactShareUrl`.
    artifactId*: string
    kind*: Option[ArtifactKind]

# ---------------------------------------------------------------------------
# Construction and validation
# ---------------------------------------------------------------------------

proc initArtifactAccess*(tenantId: string,
    visibility: ArtifactVisibility = avTenant,
    minimumWriteRole: ArtifactRole = arMember): ArtifactAccess =
  ## The access record for a freshly stored artifact.  `apNone` is not a
  ## parameter: nothing on this path can produce anything else, and offering
  ## the choice would imply otherwise.
  ArtifactAccess(
    tenantId: tenantId,
    visibility: visibility,
    minimumWriteRole: minimumWriteRole,
    protection: apNone)

proc initArtifactPayload*(byteSize: int64,
    layout: ArtifactPayloadLayout, partCount: int,
    contentType: string): ArtifactPayload =
  ArtifactPayload(
    layout: layout,
    contentType: contentType,
    byteSize: byteSize,
    partCount: partCount)

proc suggestedDisplayName*(metadata: ArtifactMetadata): string =
  ## The per-kind derivation of the common `displayName`.
  ##
  ## Exhaustive `case`: a new kind must say how it names itself in a listing,
  ## or this does not compile.  AS-4 needs each kind recognisable in a list
  ## without opening it, and this is where that obligation is discharged.
  case metadata.kind
  of akRecording:
    if metadata.program.len > 0: metadata.program else: "recording"
  of akReviewDataset:
    if metadata.sessionTitle.len > 0:
      metadata.sessionTitle
    elif metadata.commitSha.len >= 7:
      "review " & metadata.commitSha[0 ..< 7]
    else:
      "review dataset"

proc recordingArtifact*(recordingId, tenantId, program, langName: string,
    byteSize: int64,
    layout: ArtifactPayloadLayout = aplSingleFile,
    partCount: int = 1,
    platform: string = "",
    recordedAtUnixMs: int64 = 0,
    createdAtUnixMs: int64 = 0,
    visibility: ArtifactVisibility = avTenant): Artifact =
  ## Describe a local recording as an artifact of the recording kind.
  ##
  ## This is the constructor the pre-AS-1 upload path now goes through, and it
  ## is where the `aioSeededFromRecordingId` binding is applied: the artifact
  ## id is the recording id, so every URL the service has already issued for
  ## this recording keeps resolving.  `validateArtifact` re-checks that rather
  ## than trusting this line, because the invariant is load-bearing for data
  ## that is already stored.
  ##
  ## `platform` and `recordedAtUnixMs` are optional and default to "unknown"
  ## values: the local trace index does not record either in a form this layer
  ## can read today (the upload session sends a hard-coded platform string —
  ## see the defect note in `upload.nim`), and inventing them would put a
  ## fabricated fact into a listing.  Neither is required by validation for
  ## exactly that reason.
  let metadata = ArtifactMetadata(
    kind: akRecording,
    recordingId: recordingId,
    program: program,
    langName: langName,
    platform: platform,
    recordedAtUnixMs: recordedAtUnixMs)
  Artifact(
    artifactId: recordingId,
    kind: akRecording,
    access: initArtifactAccess(tenantId, visibility),
    createdAtUnixMs: createdAtUnixMs,
    payload: initArtifactPayload(byteSize, layout, partCount,
      kindSpec(akRecording).defaultContentType),
    displayName: suggestedDisplayName(metadata),
    metadata: metadata)

proc reviewDatasetArtifact*(artifactId, tenantId, commitSha,
    baseCommitSha: string,
    byteSize: int64,
    fileCount: int = 0,
    recordingCount: int = 0,
    sessionTitle: string = "",
    layout: ArtifactPayloadLayout = aplSingleFile,
    partCount: int = 1,
    createdAtUnixMs: int64 = 0,
    visibility: ArtifactVisibility = avTenant): Artifact =
  ## Describe an exported review dataset (`ct review collect`'s output
  ## directory, packed for transfer) as an artifact of the review-dataset kind.
  ##
  ## `artifactId` is a store-time id — a review dataset has no record-start
  ## moment to seed one from — so callers mint it with `newArtifactId`.  This
  ## is the constructor DS-7 consumes through AS-2.
  let metadata = ArtifactMetadata(
    kind: akReviewDataset,
    commitSha: commitSha,
    baseCommitSha: baseCommitSha,
    fileCount: fileCount,
    recordingCount: recordingCount,
    sessionTitle: sessionTitle)
  Artifact(
    artifactId: artifactId,
    kind: akReviewDataset,
    access: initArtifactAccess(tenantId, visibility),
    createdAtUnixMs: createdAtUnixMs,
    payload: initArtifactPayload(byteSize, layout, partCount,
      kindSpec(akReviewDataset).defaultContentType),
    displayName: suggestedDisplayName(metadata),
    metadata: metadata)

proc validateArtifact*(artifact: Artifact): Option[string] =
  ## Returns the first problem with `artifact`, or `none` if it is storable.
  ##
  ## Refusing here rather than at the HTTP boundary is deliberate: an artifact
  ## that cannot be validated locally must never consume an upload slot, and a
  ## client-side refusal names the missing field, where a server-side one
  ## names a status code.
  if artifact.artifactId.len == 0:
    return some("artifact has no id")
  if not isCanonicalUuidV7(artifact.artifactId):
    return some("artifact id '" & artifact.artifactId &
      "' is not a canonical UUIDv7")
  if artifact.metadata.kind != artifact.kind:
    return some("artifact kind '" & $artifact.kind &
      "' does not match its metadata kind '" & $artifact.metadata.kind & "'")
  if artifact.access.tenantId.len == 0:
    return some("artifact has no owning tenant")
  if artifact.payload.layout notin kindSpec(artifact.kind).allowedLayouts:
    return some("layout '" & $artifact.payload.layout &
      "' is not allowed for kind '" & $artifact.kind & "'")
  if artifact.payload.partCount < 1:
    return some("artifact payload has no parts")
  if artifact.payload.layout == aplSingleFile and artifact.payload.partCount != 1:
    return some("single-file payload declares " &
      $artifact.payload.partCount & " parts")
  if artifact.displayName.len == 0:
    return some("artifact has no display name")

  # Per-kind obligations.  Exhaustive on purpose: a new kind cannot be added
  # without stating what its metadata must contain.
  case artifact.metadata.kind
  of akRecording:
    if not isCanonicalUuidV7(artifact.metadata.recordingId):
      return some("recording metadata has no canonical UUIDv7 recording id")
    # The binding declared by `aioSeededFromRecordingId`, checked rather than
    # assumed: if these two ever diverge, every share URL already issued for
    # this recording resolves to nothing.
    if artifact.artifactId != artifact.metadata.recordingId:
      return some("recording artifact id '" & artifact.artifactId &
        "' does not match its recording id '" &
        artifact.metadata.recordingId & "'")
    # `program` is deliberately NOT required.  An imported recording — one
    # downloaded from the store and re-shared, say — may reach this layer with
    # no program name the local index knows, and refusing a real upload in
    # order to enforce a nicer listing label is the wrong trade.  The listing
    # requirement is met by the common `displayName`, whose recording-kind
    # derivation falls back when the program is unknown.  Nothing here
    # invents a name: an absent fact is left absent.
  of akReviewDataset:
    if artifact.metadata.commitSha.len == 0:
      return some("review-dataset metadata names no commit")
    if artifact.metadata.baseCommitSha.len == 0:
      return some("review-dataset metadata names no base commit")
    if artifact.metadata.fileCount < 0:
      return some("review-dataset metadata has a negative file count")

  none(string)

when not defined(js):
  import std/strformat
  import results

  proc newArtifactId*(): string =
    ## Mint a kind-neutral artifact id: a fresh UUIDv7, at **store** time.
    ##
    ## Store time rather than creation time, because there is no kind-neutral
    ## creation moment.  A recording has one (record start, where the recorder
    ## mints `recordingId`); a review dataset does not — `ct review collect`
    ## produces a directory, and the moment it becomes shareable is the moment
    ## it is stored.  An id defined as "minted when the thing came into
    ## existence" therefore has no definition that spans kinds, so the store
    ## mints its own.
    ##
    ## The recording kind is the documented exception (`aioSeededFromRecordingId`):
    ## its stored id is its `recordingId`, so URLs already handed to users keep
    ## resolving.  Callers storing a recording pass that value instead of
    ## calling this.
    let minted = newRecordingId()
    if minted.isErr:
      raise newException(IOError,
        fmt"artifact: could not mint an artifact id: {minted.error}")
    minted.value

# ---------------------------------------------------------------------------
# The URL space
# ---------------------------------------------------------------------------
#
# One grammar, parameterised by kind, so the recording kind's legacy paths and
# any future kind's paths cannot drift apart.  `api_client.nim` derives its
# path builders from these; the assertions that the recording kind's output is
# character-identical to the pre-AS-1 strings live in
# `src/tests/gui/tests/sharing/artifact_model_vm_test.nim`.

proc artifactCollectionSegment*(kind: Option[ArtifactKind]): string =
  ## The collection segment for `kind`, or the kind-neutral one when the
  ## caller does not know the kind.
  if kind.isSome: kindSpec(kind.get).urlSegment else: KindNeutralUrlSegment

proc artifactUploadUrlPath*(baseApiUrl, tenantId: string,
    kind: ArtifactKind): string =
  ## `POST {base}tenants/{tenantId}/{segment}/upload-url`.
  ##
  ## For `akRecording` this is byte-for-byte the pre-AS-1
  ## `tenants/{tenantId}/traces/upload-url`.
  baseApiUrl & "tenants/" & tenantId & "/" &
    kindSpec(kind).urlSegment & "/upload-url"

proc artifactUploadSessionPath*(baseApiUrl, tenantId: string,
    kind: ArtifactKind): string =
  ## `POST {base}tenants/{tenantId}/{segment}/upload-session` — the
  ## slice-based transfer's entry point.  Slicing is a transfer concern, so
  ## the session endpoint is per-collection like the rest, not per-kind logic.
  baseApiUrl & "tenants/" & tenantId & "/" &
    kindSpec(kind).urlSegment & "/upload-session"

proc artifactConfirmUploadPath*(baseApiUrl: string,
    reference: ArtifactRef): string =
  ## `POST {base}{segment}/{artifactId}/confirm-upload`.
  baseApiUrl & artifactCollectionSegment(reference.kind) & "/" &
    reference.artifactId & "/confirm-upload"

proc artifactDownloadUrlPath*(baseApiUrl: string,
    reference: ArtifactRef): string =
  ## `GET {base}{segment}/{artifactId}/download-url`.
  ##
  ## When the caller knows the kind the per-kind segment is used, which for
  ## recordings is the legacy `traces/{recordingId}/download-url` an already
  ## deployed service answers.  When it does not — the share-link case — the
  ## kind-neutral `artifacts/` segment is used and the service resolves the
  ## kind from the id.
  baseApiUrl & artifactCollectionSegment(reference.kind) & "/" &
    reference.artifactId & "/download-url"

proc buildArtifactUploadUrlBody*(reference: ArtifactRef,
    fileName, contentType: string, contentLength: int64): JsonNode =
  ## Request body for `…/upload-url`.
  ##
  ## The recording kind keeps sending `recordingId`, because that is the key
  ## the deployed service reads and the value it stores as the trace's
  ## identity; sending `artifactId` instead would be a wire break for zero
  ## gain, since for recordings the two are the same value.  Every other kind
  ## sends `artifactId` and `kind`, which is what lets the service route
  ## without guessing.
  result = %*{
    "fileName": fileName,
    "contentType": contentType,
    "contentLength": contentLength,
  }
  if reference.kind.isSome and reference.kind.get == akRecording:
    result["recordingId"] = newJString(reference.artifactId)
  else:
    result["artifactId"] = newJString(reference.artifactId)
    if reference.kind.isSome:
      result["kind"] = newJString(kindSpec(reference.kind.get).wireToken)

proc parseArtifactShareUrl*(url: string):
    tuple[orgSlug: string, artifactId: string] =
  ## Parse a sharing-server share URL of the form
  ## `https://<host>/{orgSlug}/{artifactId}/download` (trailing `/download`
  ## optional).
  ##
  ## **Share URLs carry no kind, and that is the point.**  It is what makes
  ## every link already handed to a user survive this milestone: the id is
  ## globally unique across kinds, so the service can resolve the kind from
  ## the id and no already-issued URL needs rewriting.  It is also why a kind
  ## must never be inferred from the URL shape here — a resolver that guesses
  ## `recording` because the path *looks* like the old one would silently
  ## mis-route the first review dataset shared this way.
  let parsed = parseUri(url)
  let parts = parsed.path.strip(chars = {'/'}).split('/')
  if parts.len >= 2:
    let candidateId = parts[^1]
    if candidateId.toLowerAscii() == "download" and parts.len >= 3:
      result.orgSlug = parts[^3]
      result.artifactId = parts[^2]
    else:
      result.orgSlug = parts[^2]
      result.artifactId = parts[^1]
    return
  raise newException(ValueError, "Invalid share URL: " & url)

# ---------------------------------------------------------------------------
# JSON round trip
# ---------------------------------------------------------------------------

proc metadataToJson*(metadata: ArtifactMetadata): JsonNode =
  ## Serialise the kind-specific half.  Exhaustive `case`: a new kind that
  ## does not say how it serialises does not compile.
  case metadata.kind
  of akRecording:
    %*{
      "recordingId": metadata.recordingId,
      "program": metadata.program,
      "lang": metadata.langName,
      "platform": metadata.platform,
      "recordedAtUnixMs": metadata.recordedAtUnixMs,
    }
  of akReviewDataset:
    %*{
      "commitSha": metadata.commitSha,
      "baseCommitSha": metadata.baseCommitSha,
      "fileCount": metadata.fileCount,
      "recordingCount": metadata.recordingCount,
      "sessionTitle": metadata.sessionTitle,
    }

proc metadataFromJson*(kind: ArtifactKind, node: JsonNode): ArtifactMetadata =
  ## Deserialise the kind-specific half for an already-validated `kind`.
  ## Missing keys read as their zero value; `validateArtifact` is what decides
  ## whether a zero is acceptable, so the two responsibilities stay separate.
  case kind
  of akRecording:
    ArtifactMetadata(
      kind: akRecording,
      recordingId: node{"recordingId"}.getStr(),
      program: node{"program"}.getStr(),
      langName: node{"lang"}.getStr(),
      platform: node{"platform"}.getStr(),
      recordedAtUnixMs: node{"recordedAtUnixMs"}.getBiggestInt())
  of akReviewDataset:
    ArtifactMetadata(
      kind: akReviewDataset,
      commitSha: node{"commitSha"}.getStr(),
      baseCommitSha: node{"baseCommitSha"}.getStr(),
      fileCount: node{"fileCount"}.getInt(),
      recordingCount: node{"recordingCount"}.getInt(),
      sessionTitle: node{"sessionTitle"}.getStr())

proc toJson*(artifact: Artifact): JsonNode =
  ## The artifact's wire form.  `kind` is a token from the closed set, never a
  ## MIME type or a file extension: those are attacker- and accident-supplied
  ## and would reopen the "store anything" door `parseArtifactKind` closes.
  %*{
    "artifactId": artifact.artifactId,
    "kind": kindSpec(artifact.kind).wireToken,
    "createdAtUnixMs": artifact.createdAtUnixMs,
    "displayName": artifact.displayName,
    "access": {
      "tenantId": artifact.access.tenantId,
      "visibility": $artifact.access.visibility,
      "minimumWriteRole": $artifact.access.minimumWriteRole,
      "protection": $artifact.access.protection,
    },
    "payload": {
      "layout": $artifact.payload.layout,
      "contentType": artifact.payload.contentType,
      "byteSize": artifact.payload.byteSize,
      "partCount": artifact.payload.partCount,
    },
    "metadata": metadataToJson(artifact.metadata),
  }

type
  ArtifactParseResult* = object
    ## The outcome of reading an artifact record.  A result object rather than
    ## an exception because "this is a kind we do not understand" is an
    ## expected answer for a store that refuses unknown kinds, not an
    ## exceptional one — and because the caller must be forced to look.
    artifact*: Artifact
    error*: string
      ## Empty iff the parse succeeded.

proc parseArtifact*(node: JsonNode): ArtifactParseResult =
  ## Read an artifact record.
  ##
  ## **Refuses an unknown kind rather than storing it opaquely.**  There is no
  ## arm that keeps the bytes and shrugs at the kind: an unrecognised token is
  ## an error naming the token and listing what is understood, so the failure
  ## is actionable and the store never ends up holding something nothing can
  ## open.
  if node.isNil or node.kind != JObject:
    return ArtifactParseResult(error: "artifact record is not a JSON object")

  let kindNode = node{"kind"}
  if kindNode.isNil or kindNode.kind != JString:
    return ArtifactParseResult(error: "artifact record declares no kind")

  let wireToken = kindNode.getStr()
  let parsedKind = parseArtifactKind(wireToken)
  if parsedKind.isNone:
    var known: seq[string] = @[]
    for kind in ArtifactKind:
      known.add ArtifactKindRegistry[kind].wireToken
    return ArtifactParseResult(error:
      "unknown artifact kind '" & wireToken & "'; CodeTracer stores only: " &
      known.join(", "))

  let kind = parsedKind.get
  let accessNode = node{"access"}
  let payloadNode = node{"payload"}

  var visibility = avTenant
  var minimumWriteRole = arMember
  var protection = apNone
  var tenantId = ""
  if not accessNode.isNil and accessNode.kind == JObject:
    tenantId = accessNode{"tenantId"}.getStr()
    try:
      visibility = parseEnum[ArtifactVisibility](
        accessNode{"visibility"}.getStr(), avTenant)
      minimumWriteRole = parseEnum[ArtifactRole](
        accessNode{"minimumWriteRole"}.getStr(), arMember)
      protection = parseEnum[ArtifactProtection](
        accessNode{"protection"}.getStr(), apNone)
    except ValueError:
      return ArtifactParseResult(error: "artifact access record is malformed")

  var layout = aplSingleFile
  var contentType = kindSpec(kind).defaultContentType
  var byteSize: int64 = -1
  var partCount = 1
  if not payloadNode.isNil and payloadNode.kind == JObject:
    let layoutToken = payloadNode{"layout"}.getStr()
    if layoutToken.len > 0:
      try:
        layout = parseEnum[ArtifactPayloadLayout](layoutToken)
      except ValueError:
        return ArtifactParseResult(error:
          "unknown artifact payload layout '" & layoutToken & "'")
    if payloadNode{"contentType"}.getStr().len > 0:
      contentType = payloadNode{"contentType"}.getStr()
    byteSize = payloadNode{"byteSize"}.getBiggestInt(-1)
    partCount = payloadNode{"partCount"}.getInt(1)

  ArtifactParseResult(artifact: Artifact(
    artifactId: node{"artifactId"}.getStr(),
    kind: kind,
    access: ArtifactAccess(
      tenantId: tenantId,
      visibility: visibility,
      minimumWriteRole: minimumWriteRole,
      protection: protection),
    createdAtUnixMs: node{"createdAtUnixMs"}.getBiggestInt(),
    payload: ArtifactPayload(
      layout: layout,
      contentType: contentType,
      byteSize: byteSize,
      partCount: partCount),
    displayName: node{"displayName"}.getStr(),
    metadata: metadataFromJson(kind, node{"metadata"})))

proc artifactRef*(artifact: Artifact): ArtifactRef =
  ## The addressing pair for an artifact whose kind is known.
  ArtifactRef(artifactId: artifact.artifactId, kind: some(artifact.kind))

proc recordingArtifactRef*(recordingId: string): ArtifactRef =
  ## The addressing pair for a recording, from the id the recorder minted.
  ##
  ## The one place the `aioSeededFromRecordingId` binding is spelled out for
  ## callers that hold a `recordingId` and nothing else — which is every
  ## pre-AS-1 caller in this directory.
  ArtifactRef(artifactId: recordingId, kind: some(akRecording))

proc kindRegistrySummary*(): OrderedTable[string, string] =
  ## The registry as a dumpable table: wire token → what the product does.
  ## Exists so the closed set can be *shown* (in a diagnostic, a `--help`, or
  ## a test that pins it) rather than only asserted.
  result = initOrderedTable[string, string]()
  for kind in ArtifactKind:
    let spec = ArtifactKindRegistry[kind]
    result[spec.wireToken] = spec.whatCodeTracerDoes
