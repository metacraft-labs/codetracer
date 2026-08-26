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
## ## Where confidentiality lives (AS-3)
##
## `ArtifactProtection` and everything that states what a protection *claims*
## moved to `artifact_protection.nim`, which this module imports and re-exports
## so every existing caller keeps working.  The seam AS-1 left here is now
## occupied: `apNone` is still the default and still means "no confidentiality
## from the service", and `apPasswordScryptAes256Gcm` means the payload was
## encrypted on this machine under a key the service never receives.
##
## What this module owns of that is the **kind-facing** half: which of a kind's
## metadata fields the service can still read when the payload is encrypted
## (`serviceVisibleMetadataFields`, an exhaustive `case`, so a new kind must
## answer the question AS-1 §3.1 says it owes), and the prompt wiring that
## makes the password dialog identical for every kind.
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
import artifact_protection
export artifact_protection

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

  # `ArtifactProtection` is declared in `artifact_protection.nim` and
  # re-exported above.  It lives there rather than here because it is pure
  # policy — what a protection claims, what it does not, and what recovery
  # exists — and that policy has to be assertable on both Nim backends without
  # dragging the kind registry, the URL grammar or `recording_id` along with it.

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
# Reading any closed set from untrusted input
# ---------------------------------------------------------------------------
#
# AS-2, `Artifact-Store.md` §8 defect 10.  `parseArtifactKind` above was the
# only closed set that was actually *closed* on the way in.  The access-control
# fields were read with the two-argument `parseEnum`, whose second argument is a
# **fallback, not a validator** — so `"public"` read as `avTenant`, `"owner"`
# read as `arMember` and `"aes-256-gcm"` read as `apNone`, none of them with an
# error, and the `try`/`except ValueError` around those calls was unreachable
# because two-argument `parseEnum` does not raise.
#
# Two of those three coercions failed closed; `minimumWriteRole` failed **open**.
# The one with a future is `protection`: the moment AS-3 adds a second
# `ArtifactProtection` value, a client built before it would read a record
# declaring that value as *unprotected* — an encrypted payload presented as
# plaintext-safe — rather than refusing a record it cannot interpret.  The
# refusal therefore has to exist before the second value does.
#
# So every closed set now enters through the same door as the kind: exact
# matching, no fallback arm, and a refusal that names the token and lists what
# is understood.

proc closedEnumTokens*[E: enum](): seq[string] =
  ## Every declared wire token of a closed enum, in declaration order.  Exists
  ## so a refusal can *show* the closed set rather than only assert one.
  result = @[]
  for value in E:
    result.add $value

proc parseClosedEnum*[E: enum](token: string): Option[E] =
  ## Exact-match `token` against `E`'s declared string values.
  ##
  ## The generic form of `parseArtifactKind`, and deliberately not
  ## `std/strutils.parseEnum`: the one-argument overload raises (which reads as
  ## exceptional for input that is merely untrusted) and the two-argument
  ## overload silently substitutes a default, which is the defect this replaces.
  ## Matching is exact, so whitespace padding, case variants and homoglyphs are
  ## all refused rather than normalised.
  for value in E:
    if $value == token:
      return some(value)
  none(E)

proc readClosedEnumField*[E: enum](node: JsonNode, fieldName: string,
    whenAbsent: E): tuple[value: E, error: string] =
  ## Read one closed-set token out of `node[fieldName]`.
  ##
  ## Three outcomes, and the difference between the first two is the whole
  ## point of this procedure:
  ##
  ## * **absent** (or JSON `null`) — `whenAbsent`, no error.  A record written
  ##   before the field existed does not declare it, and refusing those would
  ##   make every wire-format addition a breaking change.
  ## * **present but unrecognised** — an error naming the token and listing the
  ##   closed set.  This is the arm that used to silently substitute a default.
  ## * **present but not a string** — also an error.  This was a second way into
  ##   the same hole: `getStr()` on a number returns `""`, which the old code
  ##   fed straight to the fallback, so `{"visibility": 7}` read as `tenant`.
  let field = node{fieldName}
  if field.isNil or field.kind == JNull:
    return (whenAbsent, "")
  if field.kind != JString:
    return (whenAbsent, "artifact field '" & fieldName & "' is not a string")
  let token = field.getStr()
  let parsed = parseClosedEnum[E](token)
  if parsed.isNone:
    return (whenAbsent, "unknown artifact " & fieldName & " '" & token &
      "'; CodeTracer understands only: " & closedEnumTokens[E]().join(", "))
  (parsed.get, "")

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
      ## What confidentiality the *payload* carries before it reaches the
      ## service.  `apNone` unless the user asked for encryption; see
      ## `artifact_protection.ArtifactProtectionRegistry` for what each value
      ## claims, and `serviceVisibleMetadataFields` for what stays readable
      ## even when it is not `apNone`.
      ##
      ## Note what this field is **not**: evidence.  It is what a record says,
      ## and a record comes from the service.  The download path decides
      ## whether bytes are encrypted by looking at the bytes
      ## (`artifact_crypto.protectionOfPayload`), not by trusting this.

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

  ArtifactUploadSession* = object
    ## A server-issued multi-part upload session, **bound to the collection it
    ## was opened in**.
    ##
    ## `sessionId` is not an identity and this type does not pretend otherwise:
    ## it is a handle the service mints at `…/upload-session`, in its own
    ## namespace, and it names a transfer in progress rather than the artifact
    ## the transfer will produce (`Artifact-Store.md` §1, correction 2).  It is
    ## carried in a typed pair rather than as a bare string precisely so it
    ## cannot be mistaken for — or assigned to — an artifact id, which is
    ## exactly what `UploadedInfo.fileId` used to do (§8 defect 11).
    ##
    ## `kind` records which collection the session was opened in, so
    ## `artifactSliceUploadUrlPath` and `artifactFinalizePath` address the same
    ## collection the session belongs to rather than a kind supplied again at
    ## each call.  See those procedures for AS-2's decision on those two paths.
    sessionId*: string
    kind*: ArtifactKind

# ---------------------------------------------------------------------------
# Construction and validation
# ---------------------------------------------------------------------------

proc initArtifactAccess*(tenantId: string,
    visibility: ArtifactVisibility = avTenant,
    minimumWriteRole: ArtifactRole = arMember,
    protection: ArtifactProtection = apNone): ArtifactAccess =
  ## The access record for a freshly stored artifact.
  ##
  ## `protection` became a parameter in AS-3 and defaults to `apNone`, which is
  ## the honest default: an artifact is unprotected unless somebody asked for
  ## protection and supplied the secret it needs.  `artifact_store.storeArtifact`
  ## refuses the two ways this can be got wrong — a protection with no secret,
  ## and a secret with no protection — rather than resolving either silently.
  ArtifactAccess(
    tenantId: tenantId,
    visibility: visibility,
    minimumWriteRole: minimumWriteRole,
    protection: protection)

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
    visibility: ArtifactVisibility = avTenant,
    protection: ArtifactProtection = apNone): Artifact =
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
    access: initArtifactAccess(tenantId, visibility,
      protection = protection),
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
    visibility: ArtifactVisibility = avTenant,
    protection: ArtifactProtection = apNone): Artifact =
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
    access: initArtifactAccess(tenantId, visibility,
      protection = protection),
    createdAtUnixMs: createdAtUnixMs,
    payload: initArtifactPayload(byteSize, layout, partCount,
      kindSpec(akReviewDataset).defaultContentType),
    displayName: suggestedDisplayName(metadata),
    metadata: metadata)

# ---------------------------------------------------------------------------
# What the service can still read when the payload is encrypted (AS-3)
# ---------------------------------------------------------------------------
#
# AS-1 §6 left this question open and named AS-3 as the milestone that owes an
# answer: "a review dataset's metadata names a commit and a file count, and a
# recording's names a program. If the payload is encrypted and the metadata is
# not, that must be said."
#
# It is said here, as a list rather than as a caveat, because a list can be
# compared against the bytes that actually cross the socket — and
# `artifact_store_roundtrip_test.nim` does exactly that, so the documentation
# and the wire cannot drift apart.

proc serviceVisibleMetadataFields*(kind: ArtifactKind): seq[string] =
  ## The metadata keys of `kind` that reach the service **in the clear**, even
  ## when the payload is encrypted.
  ##
  ## Exhaustive `case`, so this is the ninth thing a new kind owes (§3.1): a
  ## kind that cannot say which of its metadata is sensitive does not get to
  ## claim the store's encryption.
  ##
  ## These are metadata keys only.  The *transfer* facts — the artifact id, the
  ## kind, the tenant, each part's file name, each part's byte length and the
  ## number of parts — are visible for every kind by construction, because they
  ## are what addressing and transferring an object consist of.  They are
  ## listed by `serviceVisibleTransferFacts` rather than repeated per kind.
  case kind
  of akRecording:
    # The recording kind's request bodies are frozen (§9.3), and that turns out
    # to be a confidentiality *advantage* here: they have room for two fields
    # and no more.  The program name, the language and the record-start time do
    # not travel at all.
    @["recordingId", "platform"]
  of akReviewDataset:
    # And this is the case AS-3's third deliverable is really about.  A review
    # dataset's metadata names the commit it describes, the commit it is
    # diffed against and the agent session that produced it — any of which may
    # be as sensitive as the diff itself, and none of which is encrypted.
    @["commitSha", "baseCommitSha", "fileCount", "recordingCount",
      "sessionTitle"]

proc serviceVisibleTransferFacts*(): seq[string] =
  ## The facts every artifact reveals to the service whatever its kind and
  ## whatever its protection, because they are what a transfer is made of.
  @["artifactId", "kind", "tenantId", "fileName", "contentLength", "partCount"]

proc artifactSubjectNoun*(kind: ArtifactKind): string =
  ## What to call an artifact of `kind` in a sentence addressed to a user:
  ## "recording", "review dataset".
  ##
  ## Derived from the wire token rather than declared, so it cannot drift from
  ## the registry, and so it is not a further per-kind obligation for something
  ## a dialog only uses as a noun.
  kindSpec(kind).wireToken.replace('-', ' ')

proc artifactProtectionPrompt*(kind: ArtifactKind,
    protection: ArtifactProtection): ArtifactProtectionPrompt =
  ## The password dialog for storing an artifact of `kind` under `protection`.
  ##
  ## **This is the whole of "the dialog and the flow are identical whatever the
  ## kind".**  There is one prompt builder, it takes the kind only to fill in a
  ## noun, and `artifact_protection_vm_test.nim` asserts that replacing that
  ## noun is the only difference between any two kinds' prompts.  A kind cannot
  ## acquire its own password flow, because there is no place to put one.
  protectionPrompt(protection, artifactSubjectNoun(kind))

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

proc artifactSliceUploadUrlPath*(baseApiUrl: string,
    session: ArtifactUploadSession): string =
  ## `POST {base}{segment}/{sessionId}/slice-upload-url`.
  ##
  ## **AS-2's decision on the two endpoints AS-1 disclosed as unmigrated.**
  ## `slice-upload-url` and `finalize` were the last literal `traces/…` strings
  ## in the client, and AS-1 flagged them as the one place a second kind could
  ## still acquire a second transport.  They are now derived from the registry
  ## like everything else — but from the segment **the session was opened in**,
  ## carried on `ArtifactUploadSession`, rather than from a kind re-supplied at
  ## each call.
  ##
  ## That is what makes the derivation safe on an id namespace the client does
  ## not own.  The path parameter here is the *session* id, minted server-side
  ## by `…/upload-session`, and the collection was already chosen at that
  ## moment; binding the segment to the session means a session cannot be
  ## opened in one collection and have its slices posted to another.  Leaving
  ## the literal in place would have meant exactly that: a review dataset
  ## uploaded in slices would publish them under `traces/`, which is the
  ## "second kind acquires the first kind's transport" failure in mirror image.
  ##
  ## For `akRecording` the segment is `traces`, so the generated string is
  ## character-identical to the pre-AS-2 one.
  baseApiUrl & kindSpec(session.kind).urlSegment & "/" &
    session.sessionId & "/slice-upload-url"

proc artifactFinalizePath*(baseApiUrl: string,
    session: ArtifactUploadSession): string =
  ## `POST {base}{segment}/{sessionId}/finalize` — the sibling of
  ## `artifactSliceUploadUrlPath`, derived the same way and for the same
  ## reason.  Character-identical to the pre-AS-2 string for `akRecording`.
  baseApiUrl & kindSpec(session.kind).urlSegment & "/" &
    session.sessionId & "/finalize"

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

  # The defaults below apply **only when the key is absent**, which is not the
  # same thing as an unrecognised value and must not be treated as one: a record
  # written before a field existed genuinely does not declare it, whereas a
  # record declaring a token this client cannot interpret is a record this
  # client must not act on.  Each default is the safe reading of an absence:
  #
  #   * `avTenant` — the narrower of the two visibilities.
  #   * `arMember` — the client does not enforce writes; the service does. This
  #     value drives presentation, and the rung the tenant listing returns for
  #     an ordinary member is the one to assume when nothing is said.
  #   * `apNone` — a record with no `protection` key is one written before
  #     protection existed, and those payloads really are unprotected.  An
  #     unknown protection *token* is refused; see `readClosedEnumField`.
  #     AS-3 note: this default is safe in the direction that matters because
  #     the download path does not trust it either way — it decides whether it
  #     is holding ciphertext by looking at the payload's own magic bytes
  #     (`artifact_crypto.protectionOfPayload`).  A service that omitted the
  #     key for an encrypted artifact therefore gets a decryption prompt, not
  #     a corrupt unzip.
  var visibility = avTenant
  var minimumWriteRole = arMember
  var protection = apNone
  var tenantId = ""
  if not accessNode.isNil and accessNode.kind == JObject:
    tenantId = accessNode{"tenantId"}.getStr()
    let readVisibility = readClosedEnumField[ArtifactVisibility](
      accessNode, "visibility", avTenant)
    if readVisibility.error.len > 0:
      return ArtifactParseResult(error: readVisibility.error)
    visibility = readVisibility.value

    let readRole = readClosedEnumField[ArtifactRole](
      accessNode, "minimumWriteRole", arMember)
    if readRole.error.len > 0:
      return ArtifactParseResult(error: readRole.error)
    minimumWriteRole = readRole.value

    let readProtection = readClosedEnumField[ArtifactProtection](
      accessNode, "protection", apNone)
    if readProtection.error.len > 0:
      return ArtifactParseResult(error: readProtection.error)
    protection = readProtection.value

  var layout = aplSingleFile
  var contentType = kindSpec(kind).defaultContentType
  var byteSize: int64 = -1
  var partCount = 1
  if not payloadNode.isNil and payloadNode.kind == JObject:
    let readLayout = readClosedEnumField[ArtifactPayloadLayout](
      payloadNode, "layout", aplSingleFile)
    if readLayout.error.len > 0:
      return ArtifactParseResult(error: readLayout.error)
    layout = readLayout.value
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

# ---------------------------------------------------------------------------
# The transfer wire bodies (AS-2)
# ---------------------------------------------------------------------------
#
# "Metadata carried alongside" is AS-2's first deliverable, and this is where it
# is discharged.  Every request body the transfer sends is built here, from the
# artifact, so a kind cannot invent its own spelling of the same request.
#
# ## Where a recording's metadata actually goes, stated plainly
#
# The recording kind is bound to a collection a service already serves, and
# AS-1's compatibility guarantee is that its bodies do not change.  So the
# recording arms below are **frozen** to the pre-AS-2 key set, and what they
# carry is what those keys have room for:
#
#   * `recordingId` on `…/upload-url` — the recording kind's identity, which for
#     this kind IS the artifact id;
#   * `platform` on `…/upload-session` and `…/finalize` — which AS-2 stops
#     fabricating (§8 defect 4) and now reads from the artifact's metadata.
#
# A recording's `program`, `lang` and `recordedAtUnixMs` are **not** sent, and
# this document does not claim they are: adding keys to a body a deployed
# service already reads is the wire change AS-1 forbids, and a listing that
# needs them can read them from the container.  Every kind that is *not* bound
# to a legacy collection carries its metadata in full, as a `metadata` object
# beside the artifact id and the kind — which is the shape a new kind gets, and
# the shape the recording kind would have had if it were being designed today.

proc artifactPlatformToken*(osName, cpuName: string): string =
  ## The platform token for a `hostOS` / `hostCPU` pair, or `""` when the pair
  ## is one this function has not been taught.
  ##
  ## `Artifact-Store.md` §8 defect 4: the upload session used to send the
  ## literal `"linux-x86_64"` whatever machine it ran on, so a macOS or Windows
  ## recording was uploaded labelled Linux.  That is worse than an absent
  ## field — `platform` is what a listing uses to tell a user whether a
  ## recording is replayable for them, and a fabricated one sends them to
  ## download it and find out.  An unrecognised pair therefore yields the empty
  ## string, which is an absence, rather than a guess.
  ##
  ## Pure in its arguments (rather than reading `hostOS` directly) so the
  ## mapping is assertable on the JavaScript backend too, where `hostOS` is
  ## `"js"` and describes nothing.
  let normalisedOs =
    case osName
    of "linux": "linux"
    of "macosx": "macos"
    of "windows": "windows"
    else: ""
  let normalisedCpu =
    case cpuName
    of "amd64": "x86_64"
    of "arm64": "aarch64"
    else: ""
  if normalisedOs.len == 0 or normalisedCpu.len == 0:
    return ""
  normalisedOs & "-" & normalisedCpu

when not defined(js):
  proc hostArtifactPlatformToken*(): string =
    ## The platform token for the machine this build of `ct` runs on.
    ##
    ## On linux/amd64 — every machine that can run the rr-based recorder whose
    ## pre-split slices reach the upload-session path today — this is
    ## `"linux-x86_64"`, character-identical to the constant it replaces.
    artifactPlatformToken(hostOS, hostCPU)

proc buildArtifactUploadUrlBody*(artifact: Artifact,
    fileName: string): JsonNode =
  ## Request body for `…/upload-url`, built from the whole artifact.
  ##
  ## The recording arm is the frozen four-key body `buildArtifactUploadUrlBody`
  ## already produced from an `ArtifactRef`; every other kind adds its metadata.
  result = buildArtifactUploadUrlBody(artifactRef(artifact), fileName,
    artifact.payload.contentType, artifact.payload.byteSize)
  if artifact.kind != akRecording:
    result["metadata"] = metadataToJson(artifact.metadata)

proc buildArtifactConfirmUploadBody*(etag: string): JsonNode =
  ## Request body for `…/confirm-upload`.  Kind-neutral already, and the ETag
  ## is issued by the object store at PUT time rather than planned.
  %*{"etag": etag}

proc buildRecordingUploadSessionBody*(platform, recordingMode: string):
    JsonNode =
  ## The recording kind's **frozen** `…/upload-session` body: exactly the two
  ## keys the deployed service reads, in the same spelling.  Held apart from
  ## the kind-dispatching builder below so `api_client.nim`'s recording-named
  ## wrapper and the generic path cannot drift into two spellings of one body.
  %*{
    "platform": platform,
    "recordingMode": recordingMode,
  }

proc buildRecordingFinalizeBody*(totalSlices, totalEvents: int,
    platform: string, omniscientDbMode: string = ""): JsonNode =
  ## The recording kind's **frozen** `…/finalize` body (CS-M7, plus M31's
  ## `omniscientDbMode`, which is omitted entirely when the client has no
  ## preference so a default-mode client round-trips the legacy body
  ## unchanged).  The single source for both callers, as above.
  result = %*{
    "totalSlices": totalSlices,
    "totalEvents": totalEvents,
    "platform": platform,
  }
  if omniscientDbMode.len > 0:
    result["omniscientDbMode"] = newJString(omniscientDbMode)

proc buildArtifactUploadSessionBody*(artifact: Artifact,
    recordingMode: string): JsonNode =
  ## Request body for `…/upload-session`.
  ##
  ## Exhaustive `case`: a new kind must say how it introduces a multi-part
  ## transfer of itself, or this does not compile.  That is the seventh
  ## obligation a kind owes (`Artifact-Store.md` §3.1) and it exists because
  ## slice transfer is the path large artifacts take — the one a new kind is
  ## most likely to reach for and least likely to have thought about.
  case artifact.kind
  of akRecording:
    buildRecordingUploadSessionBody(
      artifact.metadata.platform, recordingMode)
  of akReviewDataset:
    # No legacy binding, so the kind-neutral envelope: who this is, what kind
    # it is, and its metadata in full.  `recordingMode` has no meaning here —
    # a review dataset is not a run — so it is not sent rather than sent empty.
    %*{
      "artifactId": artifact.artifactId,
      "kind": kindSpec(artifact.kind).wireToken,
      "metadata": metadataToJson(artifact.metadata),
    }

proc buildArtifactSliceUploadUrlBody*(sliceIndex: int, fileName: string,
    contentLength: int64): JsonNode =
  ## Request body for `…/slice-upload-url`.  Kind-neutral in every kind's case:
  ## it describes one part of a payload and nothing about what the payload is.
  %*{
    "sliceIndex": sliceIndex,
    "fileName": fileName,
    "contentLength": contentLength,
  }

proc buildArtifactFinalizeBody*(artifact: Artifact, totalSlices: int,
    totalEvents: int, omniscientDbMode: string = ""): JsonNode =
  ## Request body for `…/finalize`.
  ##
  ## `totalSlices` is the number of **pieces of the payload**, which is what
  ## the deployed CS-M7 service reassembles from.  It is deliberately *not* the
  ## number of objects the session uploaded: a sliced recording publishes its
  ## `.smnf` / `.amnf` manifests through the same session, and the pre-AS-2
  ## client did not count them.  See `artifact_transfer.ArtifactPartRole`.
  ##
  ## Exhaustive `case`, for the same reason as the session body above.
  case artifact.kind
  of akRecording:
    result = buildRecordingFinalizeBody(totalSlices, totalEvents,
      artifact.metadata.platform, omniscientDbMode)
  of akReviewDataset:
    # `totalEvents` and `omniscientDbMode` are recording concepts — an event
    # count and an instruction about omniscient-DB artefacts — and a review
    # dataset has neither, so neither is sent.
    result = %*{
      "artifactId": artifact.artifactId,
      "kind": kindSpec(artifact.kind).wireToken,
      "totalSlices": totalSlices,
    }
