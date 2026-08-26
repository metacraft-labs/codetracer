## The kind-neutral transfer plan (AS-2).
##
## `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-2, designed in
## `codetracer-specs/Sharing/Artifact-Store.md` §5 and §9.
##
## ## What this module is
##
## AS-1 made the *model* kind-neutral: an artifact is an id, a kind, metadata
## and a descriptor of the bytes.  It left the *transfer* trace-shaped in one
## respect — the client still knew, in prose spread over `upload.nim`, which
## requests a trace upload makes and in which order.  This module is that
## knowledge, written once, as data:
##
##     plan = planArtifactUpload(artifact, parts, …)
##     steps = uploadSteps(plan, session)
##
## `steps` is the whole conversation — every URL, every body, every part, in
## order — as a pure function of the artifact and the local files.  Nothing
## here opens a socket, reads a file or knows what a `Trace` is, which is what
## lets the plan be asserted on both Nim backends without a service, and what
## makes "does the recording kind still send exactly what it used to?" a
## question a test can answer by comparing strings.
##
## The executor is `artifact_store.nim`.  The split is the same one
## `review_cli.nim` uses — a pure planner and a thin executor — and for the same
## reason: the interesting part is the decision, and a decision you can only
## observe by making a network request is a decision nothing asserts.
##
## ## Slicing is a transfer concern
##
## `ArtifactPayloadLayout` sits on the payload rather than on the kind (AS-1
## §2.2), and this module is where that pays off: `aplSliceSet` is planned from
## the parts, not from the fact that recordings happen to be the thing that is
## big today.  A large review dataset takes the identical path, and gets it by
## declaring the layout rather than by any code here naming its kind.
##
## ## What this module deliberately does NOT do
##
## No encryption, no password protection, no integrity check beyond the object
## store's own ETag.  There is none anywhere on this path; AS-3 builds it, and
## the seam it will extend is `ArtifactProtection` in `artifact.nim`, not
## anything here.

import std/[json, options, strutils]

import artifact
export artifact

type
  ArtifactPartRole* = enum
    ## What a part *is* to the payload, as distinct from where it sits in the
    ## transfer.
    ##
    ## This distinction is load-bearing on the wire and was very nearly lost.
    ## The recording kind's `…/finalize` body carries `totalSlices`, and the
    ## deployed CS-M7 service uses it **to reassemble the payload**: it is a
    ## count of the pieces, not a count of the objects that were uploaded.  A
    ## sliced recording uploads its `.smnf` / `.amnf` manifests *through the
    ## same session*, at indices after the slices — they travel with the
    ## payload but they are not pieces of it, and the pre-AS-2 client
    ## deliberately did not count them.  Collapsing the two counts into
    ## `parts.len` changes `totalSlices` from 3 to 5 on the normal
    ## `ct-mcr record --split` output and tells the service to reassemble two
    ## slices that do not exist.
    ##
    ## So the role is a field on the part rather than a rule in the caller, and
    ## `sliceCount` below is what the finalize body is built from.
    aprSlice = "slice"
      ## A piece of the payload.  Reassembly counts these.
    aprSidecar = "sidecar"
      ## A file that travels with the payload in the same session but is not a
      ## piece of it — a manifest, an index, a checksum list.

  ArtifactPart* = object
    ## One local file that makes up an artifact's payload.
    ##
    ## A single-file artifact has exactly one; a slice set has one per slice
    ## plus one per sidecar that travels with them.  The type is kind-neutral
    ## on purpose: "a named blob at a local path, at a position in the set,
    ## which is or is not a piece of the payload" is everything the transfer
    ## needs to know, and anything more would be a recording concept smuggled
    ## into the transport.
    name*: string
      ## The file name sent to the service.  Taken from the local file rather
      ## than invented, because the service uses it to key the stored object.
    localPath*: string
      ## Where the bytes are on this machine.
    index*: int
      ## 0-based position in the payload.  Always 0 for a single-file payload.
    byteSize*: int64
    role*: ArtifactPartRole
      ## Defaults to `aprSlice`, the enum's zero value, so a caller that has no
      ## sidecars does not have to think about this at all.

  ArtifactTransferStepKind* = enum
    ## The steps a transfer is made of.  Six, and every one of them exists for
    ## both layouts or for exactly one, never for one kind.
    atsRequestUploadUrl = "request-upload-url"
      ## `POST tenants/{tenantId}/{segment}/upload-url` — single-file only.
    atsOpenUploadSession = "open-upload-session"
      ## `POST tenants/{tenantId}/{segment}/upload-session` — slice set only.
    atsRequestPartUploadUrl = "request-part-upload-url"
      ## `POST {segment}/{sessionId}/slice-upload-url` — slice set only.
    atsPutPart = "put-part"
      ## `PUT` of one part's bytes to a presigned URL.  Both layouts.
    atsConfirmUpload = "confirm-upload"
      ## `POST {segment}/{artifactId}/confirm-upload` — single-file only.
    atsFinalizeSession = "finalize-session"
      ## `POST {segment}/{sessionId}/finalize` — slice set only.

  ArtifactTransferStep* = object
    ## One request in a planned transfer.
    kind*: ArtifactTransferStepKind
    urlPath*: string
      ## Empty for `atsPutPart`: the object store's URL is presigned and issued
      ## by the step before it, so it cannot be known at plan time.  Every
      ## other step's URL is fully determined by the artifact, the tenant and
      ## the session, which is what makes the plan comparable against literals.
    body*: JsonNode
      ## `nil` for `atsPutPart` (the body is the file) and for
      ## `atsConfirmUpload` when no ETag is known yet.
    part*: ArtifactPart
      ## Meaningful for `atsPutPart` and `atsRequestPartUploadUrl`.

  ArtifactUploadPlan* = object
    ## A validated description of one upload.  Construct it with
    ## `planArtifactUpload`, which is the only thing that may produce one.
    artifact*: Artifact
    parts*: seq[ArtifactPart]
    baseApiUrl*: string
    tenantId*: string
    recordingMode*: string
      ## Carried on the recording kind's frozen `…/upload-session` body.  Not a
      ## leak of a recording concept into the plan: it is one of the two keys
      ## that body has, and `buildArtifactUploadSessionBody` is what decides
      ## whether a kind sends it.
    omniscientDbMode*: string
    totalEvents*: int

  ArtifactUploadPlanResult* = object
    ## `planArtifactUpload`'s outcome.  A result object rather than an
    ## exception, for the same reason `ArtifactParseResult` is one: a payload
    ## that does not match its descriptor is an expected answer for a store
    ## that refuses before it uploads, and the caller must be made to look.
    plan*: ArtifactUploadPlan
    error*: string
      ## Empty iff the plan is usable.

proc totalByteSize*(parts: openArray[ArtifactPart]): int64 =
  ## The payload's size across every part, sidecars included: transfer and
  ## storage care about every byte that moves.
  result = 0
  for part in parts:
    result += part.byteSize

proc sliceCount*(parts: openArray[ArtifactPart]): int =
  ## How many parts are **pieces of the payload**, which is what reassembly
  ## needs and what the finalize body reports.  Distinct from `parts.len` — see
  ## `ArtifactPartRole`.
  result = 0
  for part in parts:
    if part.role == aprSlice:
      inc result

proc planArtifactUpload*(artifact: Artifact, parts: seq[ArtifactPart],
    baseApiUrl, tenantId: string,
    recordingMode: string = "",
    omniscientDbMode: string = "",
    totalEvents: int = 0): ArtifactUploadPlanResult =
  ## Describe the upload of `artifact` from `parts`, or say why it cannot be
  ## described.
  ##
  ## Refusing here rather than at the first request is the same trade
  ## `validateArtifact` makes: a client-side refusal names the field that is
  ## wrong, where a server-side one names a status code — and by then an upload
  ## slot, and on a slice set possibly gigabytes of transfer, have been spent.
  let problem = validateArtifact(artifact)
  if problem.isSome:
    return ArtifactUploadPlanResult(error: problem.get)
  if baseApiUrl.len == 0:
    return ArtifactUploadPlanResult(error: "upload has no service base URL")
  if tenantId.len == 0:
    return ArtifactUploadPlanResult(error: "upload names no owning tenant")
  if parts.len == 0:
    return ArtifactUploadPlanResult(error: "upload has no payload parts")

  # The descriptor and the bytes must agree.  They are two statements of the
  # same fact and the service is told the descriptor, so a disagreement means
  # the service is told something untrue about what it is receiving.
  if artifact.payload.partCount != parts.len:
    return ArtifactUploadPlanResult(error:
      "artifact payload declares " & $artifact.payload.partCount &
      " part(s) but " & $parts.len & " were supplied")
  if artifact.payload.byteSize != totalByteSize(parts):
    return ArtifactUploadPlanResult(error:
      "artifact payload declares " & $artifact.payload.byteSize &
      " bytes but its parts total " & $totalByteSize(parts))
  for part in parts:
    if part.name.len == 0:
      return ArtifactUploadPlanResult(error:
        "payload part " & $part.index & " has no name")
    if part.localPath.len == 0:
      return ArtifactUploadPlanResult(error:
        "payload part '" & part.name & "' has no local path")
    if part.index < 0 or part.index >= parts.len:
      return ArtifactUploadPlanResult(error:
        "payload part '" & part.name & "' has index " & $part.index &
        ", outside 0 ..< " & $parts.len)

  ArtifactUploadPlanResult(plan: ArtifactUploadPlan(
    artifact: artifact,
    parts: parts,
    baseApiUrl: baseApiUrl,
    tenantId: tenantId,
    recordingMode: recordingMode,
    omniscientDbMode: omniscientDbMode,
    totalEvents: totalEvents))

proc uploadOpenStep*(plan: ArtifactUploadPlan): ArtifactTransferStep =
  ## The first request: the one that either asks for a presigned URL for the
  ## whole payload, or opens a session the parts are published under.
  ##
  ## Which one is decided by the payload's **layout**, never by its kind.  That
  ## is the sentence AS-2 exists to be able to write.
  case plan.artifact.payload.layout
  of aplSingleFile:
    ArtifactTransferStep(
      kind: atsRequestUploadUrl,
      urlPath: artifactUploadUrlPath(
        plan.baseApiUrl, plan.tenantId, plan.artifact.kind),
      body: buildArtifactUploadUrlBody(plan.artifact, plan.parts[0].name),
      part: plan.parts[0])
  of aplSliceSet:
    ArtifactTransferStep(
      kind: atsOpenUploadSession,
      urlPath: artifactUploadSessionPath(
        plan.baseApiUrl, plan.tenantId, plan.artifact.kind),
      body: buildArtifactUploadSessionBody(plan.artifact, plan.recordingMode))

proc uploadPartSteps*(plan: ArtifactUploadPlan,
    session: ArtifactUploadSession): seq[ArtifactTransferStep] =
  ## The body of the transfer: the parts, in index order.
  ##
  ## A single-file payload is one `atsPutPart` against the URL the open step
  ## returned.  A slice set is a request-then-PUT pair per part, addressed
  ## through `session` — whose `kind` is what keeps the parts in the same
  ## collection the session was opened in (see `artifactSliceUploadUrlPath`).
  result = @[]
  case plan.artifact.payload.layout
  of aplSingleFile:
    result.add ArtifactTransferStep(kind: atsPutPart, part: plan.parts[0])
  of aplSliceSet:
    for part in plan.parts:
      result.add ArtifactTransferStep(
        kind: atsRequestPartUploadUrl,
        urlPath: artifactSliceUploadUrlPath(plan.baseApiUrl, session),
        body: buildArtifactSliceUploadUrlBody(
          part.index, part.name, part.byteSize),
        part: part)
      result.add ArtifactTransferStep(kind: atsPutPart, part: part)

proc uploadCompletionStep*(plan: ArtifactUploadPlan,
    session: ArtifactUploadSession, etag: string = ""): ArtifactTransferStep =
  ## The last request: the one that tells the service the payload is whole.
  ##
  ## `etag` is the object store's receipt for a single-file PUT and is
  ## therefore only known at run time; passing `""` yields the step with no
  ## body, which is the form a plan comparison uses.
  case plan.artifact.payload.layout
  of aplSingleFile:
    ArtifactTransferStep(
      kind: atsConfirmUpload,
      urlPath: artifactConfirmUploadPath(
        plan.baseApiUrl, artifactRef(plan.artifact)),
      body:
        if etag.len > 0: buildArtifactConfirmUploadBody(etag)
        else: nil)
  of aplSliceSet:
    ArtifactTransferStep(
      kind: atsFinalizeSession,
      urlPath: artifactFinalizePath(plan.baseApiUrl, session),
      # `sliceCount`, NOT `parts.len`.  The service reassembles from this
      # number, and sidecars are not pieces to reassemble — see
      # `ArtifactPartRole` for what counting objects here would tell it.
      body: buildArtifactFinalizeBody(
        plan.artifact, sliceCount(plan.parts), plan.totalEvents,
        plan.omniscientDbMode))

proc uploadSteps*(plan: ArtifactUploadPlan,
    session: ArtifactUploadSession): seq[ArtifactTransferStep] =
  ## The whole conversation, in order.  Exists so a test can assert the
  ## sequence a kind produces rather than assert each builder in isolation and
  ## hope they are called in the order it assumed.
  result = @[uploadOpenStep(plan)]
  result.add uploadPartSteps(plan, session)
  result.add uploadCompletionStep(plan, session)

proc describeStep*(step: ArtifactTransferStep): string =
  ## One line per step: the verb and what it addresses.  For diagnostics, and
  ## for tests that want to compare a whole conversation as text.
  result = $step.kind
  if step.urlPath.len > 0:
    result &= " " & step.urlPath
  elif step.kind == atsPutPart:
    result &= " part " & $step.part.index & " (" & step.part.name & ")"

# ---------------------------------------------------------------------------
# Download: resolving an artifact whose kind the caller may not know
# ---------------------------------------------------------------------------

proc artifactDownloadCandidates*(artifactId: string,
    kindHint: Option[ArtifactKind]): seq[ArtifactRef] =
  ## The collections to ask for `artifactId`, in order.
  ##
  ## A share link carries no kind (`parseArtifactShareUrl`, and AS-1 §5.3 for
  ## why that is the property that made the migration cheap), so the client
  ## reaching a link has an id and nothing else.  It must not *guess* a kind
  ## from the URL's shape; what it may do is **ask**, and accept only an
  ## answer.  That is what this list is: an ordered, exhaustive set of
  ## collections to ask, ending in a definite refusal rather than a fallback.
  ##
  ## The order follows AS-1 §5.4 — the kind-neutral `artifacts/` family first,
  ## then the kind's alias — so a new client works against an old service and
  ## an old client works against a new one.  It costs a client that reaches a
  ## deployed service one 404 before the request that works, until a service
  ## serves `artifacts/`; against a transfer that then moves the payload itself
  ## that is not a cost worth reordering the design for.
  ##
  ## Exhaustive over `ArtifactKind`, so a new kind becomes reachable from a
  ## share link by existing, without anything here naming it.
  result = @[ArtifactRef(artifactId: artifactId, kind: none(ArtifactKind))]
  if kindHint.isSome:
    result.add ArtifactRef(artifactId: artifactId, kind: kindHint)
  for kind in ArtifactKind:
    if kindHint.isSome and kindHint.get == kind:
      continue
    result.add ArtifactRef(artifactId: artifactId, kind: some(kind))

proc downloadProbeMayContinue*(candidate: ArtifactRef, status: int): bool =
  ## Whether a failed `…/download-url` means "ask the next collection" rather
  ## than "stop and report this".
  ##
  ## The distinction matters because `ct download` now asks the kind-neutral
  ## `artifacts/` collection **before** the recording kind's `traces/` alias
  ## (§5.4), and no deployed service routes `artifacts/` yet. Every existing
  ## user's download therefore begins with a request that fails, and what the
  ## service *says* when a route does not exist is not under this client's
  ## control: the API itself answers 404, but an API gateway, a WAF or a
  ## reverse proxy in front of it may answer 400, 403 or 501 for a path it has
  ## no rule for. Treating any of those as fatal would abort a download that
  ## would have worked, for an artifact that is right there — the exact
  ## regression this milestone must not ship.
  ##
  ## So the rule is asymmetric, and the asymmetry is the point:
  ##
  ## * For the **kind-neutral probe**, whose route genuinely may not exist,
  ##   every "this route is not here" shape continues: 400, 403, 404, 405, 501.
  ## * For a **kind-specific collection**, whose route certainly exists on any
  ##   service that serves that kind, only 404 and 405 continue. A 403 there is
  ##   an answer — "you may not read this" — and walking past it would report a
  ##   permission problem as a missing artifact.
  ## * **401 never continues**, on either. It is about the caller's credentials
  ##   rather than about the collection, so every candidate would give the same
  ##   answer and reporting the last one hides the first.
  ## * **5xx other than 501 never continues.** A service that is broken is not
  ##   a service that does not hold the artifact.
  if status == 401:
    return false
  if status in [404, 405]:
    return true
  if candidate.kind.isNone:
    return status in [400, 403, 501]
  false

proc resolveDownloadedKind*(answering: ArtifactRef,
    responseBody: JsonNode): tuple[kind: Option[ArtifactKind], error: string] =
  ## What kind the artifact behind a `…/download-url` response is.
  ##
  ## Two sources, in this order, and no third:
  ##
  ## 1. **The service said so** — a `kind` token, or a full `artifact` record,
  ##    in the response.  Refused if the token is not one of the declared
  ##    kinds, exactly as `parseArtifact` refuses an unknown kind: a client
  ##    that cannot open the bytes must say so rather than download them.
  ## 2. **A kind-specific collection answered** — the request went to
  ##    `traces/{id}/download-url` and succeeded, so the artifact is in the
  ##    recording collection.  This is an observation, not an inference from
  ##    the URL's shape: the client asked that collection and it said yes.
  ##
  ## If neither holds — the kind-neutral endpoint answered without naming a
  ## kind — the answer is an **error**.  Guessing "recording" there is the
  ## mis-routing `parseArtifactShareUrl` refuses to do, moved one layer down.
  if not responseBody.isNil and responseBody.kind == JObject:
    let artifactNode = responseBody{"artifact"}
    if not artifactNode.isNil and artifactNode.kind == JObject:
      let parsed = parseArtifact(artifactNode)
      if parsed.error.len > 0:
        return (none(ArtifactKind), parsed.error)
      return (some(parsed.artifact.kind), "")
    let kindNode = responseBody{"kind"}
    if not kindNode.isNil and kindNode.kind != JNull:
      if kindNode.kind != JString:
        return (none(ArtifactKind),
          "download response declares a kind that is not a string")
      let token = kindNode.getStr()
      let parsedKind = parseArtifactKind(token)
      if parsedKind.isNone:
        var known: seq[string] = @[]
        for kind in ArtifactKind:
          known.add ArtifactKindRegistry[kind].wireToken
        return (none(ArtifactKind),
          "unknown artifact kind '" & token & "'; CodeTracer stores only: " &
          known.join(", "))
      return (parsedKind, "")

  if answering.kind.isSome:
    return (answering.kind, "")

  (none(ArtifactKind),
    "the service resolved artifact '" & answering.artifactId &
    "' but did not say what kind it is, and the kind-neutral collection " &
    "cannot be read as any one kind")

proc parseDownloadedArtifact*(responseBody: JsonNode): ArtifactParseResult =
  ## The artifact record a `…/download-url` response carried, if it carried
  ## one.  This is the other half of "metadata carried alongside": what the
  ## upload sent is what the download reads back.
  ##
  ## A response with no record is not an error here — a service deployed
  ## before AS-2 answers with `downloadUrl` and `expiresAt` and nothing else —
  ## so the caller gets an empty artifact and an empty error, and decides.
  if responseBody.isNil or responseBody.kind != JObject:
    return ArtifactParseResult()
  let artifactNode = responseBody{"artifact"}
  if artifactNode.isNil or artifactNode.kind != JObject:
    return ArtifactParseResult()
  parseArtifact(artifactNode)

# ---------------------------------------------------------------------------
# Recognising a local artifact, without guessing
# ---------------------------------------------------------------------------
#
# AS-2's CLI surface is "kind-neutral where it can be, and says the kind where
# it must".  `ct download` can be wholly kind-neutral because the link carries
# no kind and the service resolves it.  `ct upload <PATH>` is the other half:
# the kind is a property of what is on disk, so it can be *recognised* — and
# where it cannot be recognised unambiguously, the user must say.
#
# Recognition here is by the markers each kind leaves in its own output
# directory, which is the same evidence `ct review` and `ct replay` already
# use.  The decision is a pure function of the evidence so the whole table is
# assertable on both Nim backends with nothing on disk; only the *observation*
# touches the filesystem (`artifact_store.observeLocalArtifact`).

type
  LocalArtifactEvidence* = object
    ## What was found at a local path.  Facts, not conclusions.
    pathExists*: bool
    isDirectory*: bool
    hasReviewDatasetJson*: bool
      ## a `review.json` — what `ct review collect --output <DIR>` writes.
    hasCtContainer*: bool
      ## a `.ct` CTFS container — what a materialized recording is.
    hasTraceMetadata*: bool
      ## a `trace_metadata.json` — a materialized recording folder.
    hasRrVersionFile*: bool
      ## a `version` file — an rr (native) trace directory.

proc recordingMarkersPresent*(evidence: LocalArtifactEvidence): bool =
  ## Whether anything at the path says "recording".  Three markers rather than
  ## one because CodeTracer has two recording shapes (materialized CTFS and
  ## native rr) and a folder may carry either.
  evidence.hasCtContainer or evidence.hasTraceMetadata or
    evidence.hasRrVersionFile

proc classifyArtifactEvidence*(path: string,
    evidence: LocalArtifactEvidence,
    explicitKind: string = ""):
    tuple[kind: Option[ArtifactKind], error: string] =
  ## Which kind the artifact at `path` is, or why that cannot be answered.
  ##
  ## Four outcomes, and the last two are refusals rather than a default:
  ##
  ## * the user said which kind — honoured, after being checked against the
  ##   closed set, so `--kind heap-dump` is refused the same way a stored
  ##   record of an unknown kind is;
  ## * exactly one kind's markers are present — that kind;
  ## * more than one kind's markers are present — refused, and the user is
  ##   asked which.  Picking one would be the "store it and hope" behaviour the
  ##   closed-kind design exists to prevent, one layer up;
  ## * no kind's markers are present — refused, naming what was looked for, so
  ##   the far more likely cause (a mistyped path) is diagnosable with `ls`.
  if explicitKind.len > 0:
    let named = parseArtifactKind(explicitKind)
    if named.isNone:
      var known: seq[string] = @[]
      for kind in ArtifactKind:
        known.add ArtifactKindRegistry[kind].wireToken
      return (none(ArtifactKind),
        "error: unknown artifact kind '" & explicitKind &
        "'.\n  CodeTracer stores only: " & known.join(", ") & ".")
    if not evidence.pathExists:
      return (none(ArtifactKind), "error: nothing to upload at '" & path & "'.")
    return (named, "")

  if not evidence.pathExists:
    return (none(ArtifactKind), "error: nothing to upload at '" & path & "'.")

  let looksLikeReview = evidence.hasReviewDatasetJson
  let looksLikeRecording = recordingMarkersPresent(evidence)

  if looksLikeReview and looksLikeRecording:
    return (none(ArtifactKind),
      "error: '" & path & "' holds both a review dataset and a recording, " &
      "so CodeTracer cannot tell\n  which one you meant to share. Name it " &
      "with --kind recording or --kind review-dataset.")
  if looksLikeReview:
    return (some(akReviewDataset), "")
  if looksLikeRecording:
    return (some(akRecording), "")

  (none(ArtifactKind),
    "error: '" & path & "' is not something CodeTracer can share.\n" &
    "  A review dataset is a directory holding a review.json (`ct review " &
    "collect --output <DIR>` writes one).\n" &
    "  A recording is a directory holding a `.ct` container, a " &
    "trace_metadata.json, or an rr `version` file.\n" &
    "  Name the kind explicitly with --kind if you know it.")
