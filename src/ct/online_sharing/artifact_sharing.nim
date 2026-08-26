## The one sharing surface (AS-4).
##
## `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-4, designed in
## `codetracer-specs/Sharing/Artifact-Store.md` §11.
##
## ## What this module is
##
## Everything a user is *shown* about sharing — before they share, after they
## share, after they receive, and in a listing — as a **value derived from the
## artifact model**.  It renders nothing to a terminal and opens nothing; it
## produces the view, and `upload.nim`, `download.nim` and `cli/list.nim` print
## it.
##
## ## Why it is one flow rather than two that resemble each other
##
## The failure this milestone exists to prevent is not "the two kinds look a
## bit different".  It is that a recording and a review dataset had **separate
## success paths** — `uploadFile` printed "File uploaded successfully / Recording
## ID / You can run the replay in the browser from here", `uploadReviewDataset`
## printed "Review dataset uploaded / Artifact ID", and `ct download` ended in a
## `case` with two unrelated messages.  Two paths that agree today drift
## tomorrow, and the one that drifts is the one nobody is looking at.
##
## So there is exactly **one** builder, `sharingView`, and per-kind variation
## can enter it through a **closed, enumerated set of doors**, each of them an
## exhaustive `case` or a registry lookup that a new kind must fill in, and each
## of them separately asserted:
##
## 1. `artifactSubjectNoun` (in `artifact.nim`) — the noun.  Derived from the
##    registry, so it is not even a per-kind decision.  It reaches exactly one
##    sentence, `heading`.
## 2. `artifactFacts` — *what the kind genuinely needs*: the handful of facts
##    that make a recording recognisable as a recording and a review dataset as
##    a review dataset, without opening either.  This is AS-4's second
##    deliverable, and it is the only place a kind gets to say anything about
##    itself.
## 3. `artifactOpenCommand` — the one command that opens this kind.
## 4. `visibleToService` — §10.4's per-kind list of the metadata that stays
##    readable when the payload is encrypted.  It is per kind by necessity, and
##    AS-3 already made it a per-kind obligation
##    (`serviceVisibleMetadataFields`); AS-4 adds the access half
##    (`serviceVisibleAccessFields`).  Kept out of the protection *sentences*,
##    which stay identical, so the disclosure and the list can be checked
##    separately.
## 5. `kindApiNotices` — the one sentence a kind whose upload bodies are frozen
##    owes the user, derived from `kindCarriesAccessRecord`.
##
## Everything else — the headings, the order of the sections, every sentence
## about access, every sentence about encryption, the link, the download
## command, the notices — is a function of the *protection* and the *access
## record* and not of the kind at all.  `artifact_sharing_vm_test.nim` asserts
## that exhaustively over kind × kind × protection × visibility × stage, **at
## three layers**: the view, `renderSharingView`'s text and
## `sharingViewJson`'s object.  All three are needed — a door added to the
## renderer alone passed every suite when only the view was compared.  A kind
## cannot acquire its own sharing flow because there is nowhere to put one.
##
## ## Where this module's guarantee stops
##
## At this module.  `upload.nim` also prints lines about *moving the bytes* —
## packing, publishing parts, finalizing, enrichment, progress — and those are
## not part of the view and are not covered by the equalities.  They differ per
## **payload shape** rather than per kind (a review dataset declaring
## `aplSliceSet` gets the same ones), and they are declared in an allowlist
## `src/tests/cli/sharing_flow_cli_test.nim` enforces against a real upload of
## each kind.  Anything printed about the *artifact* belongs here; anything
## printed about the *transfer* belongs there, and has to be declared.
##
## ## Portability
##
## Pure: no filesystem, no HTTP, no `Trace`, no `langstring`, no `std/times`.
## It compiles on both Nim backends so the sharing surface is assertable in the
## headless ViewModel lane, for the same reason `artifact_protection.nim` is —
## the sentences a user reads about who can open what they shared, and about
## what encryption does not cover, are promises, and a promise whose test needs
## a socket is a promise nothing checks on most runs.

import std/[json, strutils]

import artifact
export artifact

# ---------------------------------------------------------------------------
# The view
# ---------------------------------------------------------------------------

type
  ArtifactSharingStage* = enum
    ## Which moment of the one flow this view describes.
    ##
    ## A stage rather than three view types on purpose: the sections, their
    ## order and their wording are the same at every stage, and only the
    ## heading and which of `link` / `openCommand` is known differ.  Three
    ## types would be three places for the sections to drift.
    assOffered = "offered"
      ## Before anything is uploaded: what is about to be shared, and under
      ## what protection and access.
    assShared = "shared"
      ## After a successful upload.
    assReceived = "received"
      ## After a successful download.

  ArtifactSharingLine* = object
    ## One labelled line of the view.  A label and a value rather than a
    ## pre-formatted string so a terminal, a dialog and a JSON consumer can
    ## each lay it out their own way without re-deriving the content.
    label*: string
    value*: string

  ArtifactSharingView* = object
    ## Everything the sharing surface shows about one artifact.
    stage*: ArtifactSharingStage
    kind*: ArtifactKind
    subject*: string
      ## The noun: "recording", "review dataset".
    kindLabel*: string
      ## The noun as a column heading would spell it: "Recording",
      ## "Review dataset".
    heading*: string
      ## The one kind-dependent sentence, and it is kind-dependent only in the
      ## noun — which is what the cross-kind substitution test asserts.
    title*: string
      ## The artifact's display name.
    artifactId*: string
    facts*: seq[ArtifactSharingLine]
      ## Kind-appropriate: see `artifactFacts`.
    access*: seq[ArtifactSharingLine]
      ## Kind-NEUTRAL.  Who may read, who may write, and what protection the
      ## payload carries.
    protection*: seq[ArtifactSharingLine]
      ## Kind-NEUTRAL.  Empty unless the protection actually encrypts — an
      ## unprotected upload must not print a paragraph about what encryption
      ## does not cover, which would be a claim about a capability it does not
      ## have.
    visibleToService*: string
      ## §10.4's list, for this kind.  Per kind by necessity, and therefore
      ## held apart from the protection sentences so the sentences can be
      ## demanded identical across kinds while the list is checked against
      ## `serviceVisibleMetadataFields` / `serviceVisibleAccessFields`.
      ## Empty whenever `protection` is.
    link*: string
      ## The share link, when one was issued.
    openCommand*: string
      ## The command that opens this artifact locally, when a locator is known.
    downloadCommand*: string
      ## The command that fetches it from the link, when there is a link.
      ##
      ## Kind-NEUTRAL, and that is the point: `ct download <LINK>` is the same
      ## for every kind because a share link carries no kind (§5.3), so this is
      ## one string built from the link rather than a per-kind instruction.
    notices*: seq[string]
      ## Kind-NEUTRAL sentences that are true only in certain states — a
      ## protected artifact needing its password sent separately, an envelope
      ## sealed for a different id.
    kindApiNotices*: seq[string]
      ## The one place a kind's own limitations are allowed to speak, kept
      ## apart from `notices` so the cross-kind assertion can demand that
      ## everything else is identical.
      ##
      ## Today it holds exactly one sentence and only for kinds whose upload
      ## bodies are frozen: the visibility the user chose was recorded locally
      ## and not sent (`kindCarriesAccessRecord`).  It is derived from the
      ## registry rather than written per kind, so it cannot become a place to
      ## put a second sharing flow.

const
  SharingFactsHeading* = "What it is"
  SharingAccessHeading* = "Who can get at it"
  SharingProtectionHeading* = "Protection"
  SharingVisibleLabel* = "Still visible to the service"
  SharingLinkLabel* = "Share link"
  SharingDownloadLabel* = "Download it with"
  SharingOpenLabel* = "Open it with"
  SharingIdLabel* = "Artifact id"
    ## "Artifact id", for every kind.  It used to be "Recording ID" on one path
    ## and "Artifact ID" on the other for values in the *same* namespace, which
    ## is the cosmetic half of the defect this milestone closes; the id really
    ## is the artifact's, and for a recording it is also its recording id by the
    ## `aioSeededFromRecordingId` binding (§4).

# ---------------------------------------------------------------------------
# Door 2: the facts that make a kind recognisable without opening it
# ---------------------------------------------------------------------------

proc formatUnixMsUtc*(unixMs: int64): string =
  ## `YYYY-MM-DD HH:MM UTC` for a Unix millisecond timestamp.
  ##
  ## Written out rather than taken from `std/times` because this module
  ## compiles on the JavaScript backend, where `std/times` drags in a timezone
  ## database this has no use for.  The civil-date conversion is Howard
  ## Hinnant's `civil_from_days`
  ## (http://howardhinnant.github.io/date_algorithms.html#civil_from_days),
  ## which is exact for the whole proleptic Gregorian range.
  if unixMs <= 0:
    return ""
  let seconds = unixMs div 1000
  var days = seconds div 86_400
  var secondOfDay = seconds mod 86_400
  if secondOfDay < 0:
    secondOfDay += 86_400
    days -= 1
  # Shift the era so that the leap-day is the last day of the (internal) year.
  let z = days + 719_468
  let era = (if z >= 0: z else: z - 146_096) div 146_097
  let doe = z - era * 146_097                            # [0, 146096]
  let yoe = (doe - doe div 1460 + doe div 36_524 - doe div 146_096) div 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)  # [0, 365]
  let mp = (5 * doy + 2) div 153                         # [0, 11]
  let d = doy - (153 * mp + 2) div 5 + 1                 # [1, 31]
  let m = (if mp < 10: mp + 3 else: mp - 9)              # [1, 12]
  let year = (if m <= 2: y + 1 else: y)
  let hour = secondOfDay div 3600
  let minute = (secondOfDay mod 3600) div 60
  $year & "-" & align($m, 2, '0') & "-" & align($d, 2, '0') & " " &
    align($hour, 2, '0') & ":" & align($minute, 2, '0') & " UTC"

proc formatByteSize*(bytes: int64): string =
  ## A size a human can read, or `""` when the size is unknown (`-1`, which is
  ## what `ArtifactPayload.byteSize` carries before a transfer has measured it).
  ##
  ## Powers of 1024 with the IEC spelling, because that is what every other
  ## size in this client uses and mixing the two conventions in one listing is
  ## how a 1.05 GB file and a 1.00 GiB file look like different artifacts.
  if bytes < 0:
    return ""
  if bytes < 1024:
    return $bytes & " B"
  const units = ["KiB", "MiB", "GiB", "TiB", "PiB"]
  var value = float(bytes)
  # `unit` counts DIVISIONS, and `units[unit - 1]` is the name of the unit after
  # that many of them — `bytes >= 1024` above guarantees at least one, so the
  # index is never negative.  (Indexing `units[unit]` reported every size one
  # unit too large; the suite caught it.)
  var unit = 0
  while value >= 1024.0 and unit < units.len:
    value = value / 1024.0
    inc unit
  # One decimal place below 10, none above: "9.4 MiB", "512 MiB".
  let scaled = int(value * 10.0 + 0.5)
  if scaled < 100:
    $(scaled div 10) & "." & $(scaled mod 10) & " " & units[unit - 1]
  else:
    $((scaled + 5) div 10) & " " & units[unit - 1]

proc artifactFacts*(metadata: ArtifactMetadata): seq[ArtifactSharingLine] =
  ## The kind-appropriate facts, in the order a reader wants them.
  ##
  ## **AS-4's second deliverable lives here.**  "A recording and a review
  ## dataset should be recognisable in a list without opening them" is not a
  ## rendering problem — it is a question about which two or three facts
  ## identify an artifact of a kind, and only the kind can answer it.  So this
  ## is an exhaustive `case`, and a kind added without an answer does not
  ## compile.
  ##
  ## A fact whose value is absent is **omitted rather than shown empty**.  An
  ## absent platform means the uploader's host pair was one
  ## `artifactPlatformToken` has not been taught (§8 defect 4); printing
  ## "Platform: " with nothing after it invites the reader to conclude
  ## something about the artifact that is not true.
  result = @[]
  # A template rather than a nested proc: a closure over `result` is a capture
  # the C backend refuses, and this only needs to be a spelling.
  template addFact(factLabel, factValue: string) =
    let value = factValue
    if value.len > 0:
      result.add ArtifactSharingLine(label: factLabel, value: value)

  case metadata.kind
  of akRecording:
    addFact "Program", metadata.program
    addFact "Language", metadata.langName
    addFact "Platform", metadata.platform
    addFact "Recorded", formatUnixMsUtc(metadata.recordedAtUnixMs)
  of akReviewDataset:
    addFact "Session", metadata.sessionTitle
    addFact "Commit", metadata.commitSha
    addFact "Compared with", metadata.baseCommitSha
    if metadata.fileCount > 0:
      addFact "Files", $metadata.fileCount
    if metadata.recordingCount > 0:
      addFact "Recordings", $metadata.recordingCount

proc artifactSummary*(metadata: ArtifactMetadata,
    excluding: string = ""): string =
  ## One line for a listing row.
  ##
  ## Derived from `artifactFacts` rather than written a second time per kind,
  ## so a listing cannot describe an artifact differently from the way the
  ## sharing view does.  The first two facts are the ones that identify it; a
  ## kind with only one gets one.
  ##
  ## `excluding` drops a fact whose value the row already shows in its own
  ## column — a recording's display name IS its program, so without this a row
  ## reads `sudoku | sudoku · LangCpp` and spends half its width saying the
  ## same word twice.
  var pieces: seq[string] = @[]
  for fact in artifactFacts(metadata):
    if pieces.len >= 2:
      break
    if excluding.len > 0 and fact.value == excluding:
      continue
    pieces.add fact.value
  pieces.join(" · ")

# ---------------------------------------------------------------------------
# Door 3: the command that opens a kind
# ---------------------------------------------------------------------------

proc artifactOpenCommand*(kind: ArtifactKind, locator: string): string =
  ## How a user opens an artifact of `kind` that is already on their machine.
  ##
  ## Exhaustive `case`: a kind added without an answer to "what does the user
  ## type to open this" does not compile.  `locator` is whatever names the
  ## local copy — a recording id for a recording, a directory for a review
  ## dataset — and an empty one yields no command rather than a command with a
  ## hole in it.
  if locator.len == 0:
    return ""
  case kind
  of akRecording: "ct replay " & locator
  of akReviewDataset: "ct review " & locator

# ---------------------------------------------------------------------------
# Access control, kind-neutral
# ---------------------------------------------------------------------------

proc describeVisibility*(visibility: ArtifactVisibility): string =
  ## Who may read, in the user's words rather than in the enum's.
  ##
  ## Exhaustive, and deliberately does **not** say "public" for either value:
  ## neither of them is.  `avTenantOrInvite` widens the audience to holders of
  ## an invite link, which is a different sentence from "anyone".
  case visibility
  of avTenant:
    "members of the owning organisation"
  of avTenantOrInvite:
    "members of the owning organisation, and anyone holding an invite link"

proc describeWriteRole*(role: ArtifactRole): string =
  ## Who may replace or delete it.
  case role
  of arMember: "any member of the owning organisation"
  of arAdmin: "administrators of the owning organisation"

const
  AccessNotStated* =
    "not stated — the service did not return this artifact's record, and " &
    "CodeTracer will not guess"
    ## What the read and write lines say when the access record is not
    ## something this client was told.
    ##
    ## It exists because the alternative is a **fabricated fact**, which is the
    ## defect §8 item 4 records in another form: no deployed service returns an
    ## artifact record (§9.4), so a download would otherwise print
    ## "Who can open it: members of the owning organisation" — the model's
    ## default — about an artifact whose owner it does not know. Found by
    ## running `ct download` and reading the output, which is what AS-4's
    ## fourth deliverable is for.
    ##
    ## Kind-NEUTRAL, so both kinds say it identically and the cross-kind
    ## equality still holds.

proc describeArtifactAccess*(access: ArtifactAccess,
    accessKnown: bool = true): seq[ArtifactSharingLine] =
  ## The access section, identical for every kind — it takes the access record
  ## and not the kind, which is the strongest form of "kind-neutral" available:
  ## there is no kind in scope to branch on.
  ##
  ## Three lines, always the same three, in the same order: read, write, and
  ## what the payload itself carries.  `Protection` is here rather than in the
  ## protection section because the protection section is a *disclosure* that
  ## only exists when something is encrypted, and "not encrypted" is a fact
  ## about access that must be visible either way.
  ##
  ## `accessKnown` is false when the record came from nowhere — a download
  ## against a service that returned none. The **protection** line survives
  ## that, and only that, because protection is read from the downloaded bytes
  ## themselves (`protectionOfPayload`) rather than from anything the service
  ## said; who may read and who may write are not, so they are reported as not
  ## stated rather than defaulted.
  @[
    ArtifactSharingLine(
      label: "Who can open it",
      value:
        if accessKnown: describeVisibility(access.visibility)
        else: AccessNotStated),
    ArtifactSharingLine(
      label: "Who can change it",
      value:
        if accessKnown: describeWriteRole(access.minimumWriteRole)
        else: AccessNotStated),
    ArtifactSharingLine(
      label: "Protection",
      value: protectionSpec(access.protection).headline),
  ]

proc accessApiNotices*(kind: ArtifactKind,
    stage: ArtifactSharingStage): seq[string] =
  ## The honest footnote on the access section, for a kind whose upload API
  ## cannot carry the access record.
  ##
  ## One today, and it is the one AS-1's compatibility guarantee forces: the
  ## recording kind's request bodies are frozen (§9.3), so the access record —
  ## **both** of its fields, who may open and who may change — is recorded on
  ## this machine and **is not sent**.  Saying so is the difference between an
  ## access-control surface and a decorative one: a user who reads "Who can
  ## open it: members of the owning organisation" and is not told the service
  ## was never asked has been misled by omission.
  ##
  ## **Gated on the stage, and that is a correction.**  The notice is about an
  ## *upload*: it says what this machine recorded and what the service was not
  ## told.  After a download neither half is true — nothing was recorded here
  ## and no upload API was involved — and printed there it contradicted the two
  ## lines directly above it, which by then read "not stated" (§8 defect 26's
  ## sibling). It belongs to the stages that precede or perform an upload.
  ##
  ## Derived from `kindCarriesAccessRecord`, so it appears exactly when the
  ## wire says it should and cannot drift into a per-kind message.
  if kindCarriesAccessRecord(kind) or stage == assReceived:
    @[]
  else:
    @["CodeTracer records who may open this " & artifactSubjectNoun(kind) &
      " and who may change it on this computer only: this kind's upload API " &
      "cannot carry an access record, so the service was told neither. " &
      "Change them in the CodeTracer web app."]

# ---------------------------------------------------------------------------
# The protection disclosure
# ---------------------------------------------------------------------------

proc describeArtifactProtection*(kind: ArtifactKind,
    protection: ArtifactProtection): seq[ArtifactSharingLine] =
  ## The protection disclosure, every sentence of it from
  ## `ArtifactProtectionRegistry` (AS-3 §10.5) rather than written here — and
  ## therefore **identical for every kind**, which is what the cross-kind
  ## equality demands.  The per-kind list of what stays visible is
  ## `describeVisibleToService`, deliberately not folded in here.
  ##
  ## **Empty when nothing is encrypted.**  An unprotected artifact must not
  ## display a paragraph about which parts of it are not encrypted, because
  ## none of it is, and a notice that appears everywhere is a notice nobody
  ## reads on the one screen where it matters.
  result = @[]
  if not protectionSpec(protection).encryptsPayload:
    return
  let prompt = artifactProtectionPrompt(kind, protection)
  result.add ArtifactSharingLine(
    label: "Protects against", value: prompt.protectsAgainst)
  result.add ArtifactSharingLine(
    label: "Does NOT protect", value: prompt.doesNotProtect)
  result.add ArtifactSharingLine(
    label: "If you lose the password", value: prompt.recoveryNotice)

proc describeVisibleToService*(kind: ArtifactKind): string =
  ## §10.4's list for `kind`: exactly what the service can still read when the
  ## payload is encrypted.
  ##
  ## Assembled from `serviceVisibleMetadataFields`,
  ## `serviceVisibleAccessFields` and `serviceVisibleTransferFacts` — the three
  ## lists §10.4 keeps compared against the bytes that actually cross the
  ## socket — so this surface cannot claim less is visible than is.  It is the
  ## fourth and last per-kind door, and it is one a kind is *obliged* to walk
  ## through: a kind that cannot say which of its metadata is sensitive does
  ## not get to claim the store's encryption.
  var visible = serviceVisibleMetadataFields(kind)
  visible.add serviceVisibleAccessFields(kind)
  describeVisibleMetadata(visible) & " (and " &
    describeVisibleMetadata(serviceVisibleTransferFacts()) & ")"

# ---------------------------------------------------------------------------
# The one builder
# ---------------------------------------------------------------------------

proc stageHeading(stage: ArtifactSharingStage, subject: string): string =
  ## The heading, and the ONE place the noun appears outside `subject` itself.
  case stage
  of assOffered: "About to share this " & subject & ":"
  of assShared: "Shared this " & subject & ":"
  of assReceived: "Downloaded this " & subject & ":"

proc sharingView*(artifact: Artifact, stage: ArtifactSharingStage,
    link: string = "", locator: string = "",
    sealedForArtifactId: string = "",
    accessKnown: bool = true): ArtifactSharingView =
  ## **The** sharing surface.  One builder, every kind, every stage.
  ##
  ## `sealedForArtifactId` is the id the downloaded envelope named, when there
  ## was one.  It is reported here — and only when it *differs* from the id
  ## that was asked for — because §10.3's cross-artifact substitution residual
  ## is only observable to the one person who could notice it, and until AS-4
  ## the value reached `ArtifactFetchOutcome` and stopped there.  A service can
  ## serve artifact B for a link to A, and with a reused password it opens; the
  ## user is now told.
  let subject = artifactSubjectNoun(artifact.kind)
  result = ArtifactSharingView(
    stage: stage,
    kind: artifact.kind,
    subject: subject,
    kindLabel: (if subject.len == 0: subject
                else: subject[0].toUpperAscii & subject[1 .. ^1]),
    heading: stageHeading(stage, subject),
    title: artifact.displayName,
    artifactId: artifact.artifactId,
    facts: artifactFacts(artifact.metadata),
    access: describeArtifactAccess(artifact.access, accessKnown),
    protection: describeArtifactProtection(
      artifact.kind, artifact.access.protection),
    visibleToService:
      (if protectionSpec(artifact.access.protection).encryptsPayload:
         describeVisibleToService(artifact.kind)
       else: ""),
    link: link,
    openCommand: artifactOpenCommand(artifact.kind, locator),
    downloadCommand: (if link.len > 0: "ct download " & link else: ""),
    notices: @[],
    kindApiNotices: accessApiNotices(artifact.kind, stage))

  let size = formatByteSize(artifact.payload.byteSize)
  if size.len > 0:
    result.facts.add ArtifactSharingLine(label: "Size", value: size)

  # Kind-neutral notices, in a fixed order so two kinds' views cannot differ in
  # which notice came first.
  if protectionSpec(artifact.access.protection).encryptsPayload and
      link.len > 0:
    result.notices.add "The link on its own is not enough to read it: " &
      "whoever opens it also needs the password. Send the password by some " &
      "other means — CodeTracer cannot recover it for either of you."
  elif link.len > 0 and stage == assShared:
    result.notices.add "The link is sensitive: anyone who has it can open " &
      "what you shared."
  if sealedForArtifactId.len > 0 and
      sealedForArtifactId != artifact.artifactId:
    # §8 defect 18's residual, made visible. The envelope's id is reported
    # rather than enforced on download — enforcing it would make an encrypted
    # sliced recording unopenable through its own share link (§10.3) — so the
    # only defence left is telling the person who can tell whether it is wrong.
    result.notices.add "This payload was sealed as artifact " &
      sealedForArtifactId & ", not " & artifact.artifactId &
      ". CodeTracer opened it because your password did, but the service " &
      "served something other than what the link asked for. Treat the " &
      "contents as coming from that other artifact."

# ---------------------------------------------------------------------------
# The shape, for the cross-kind assertion
# ---------------------------------------------------------------------------

proc prospectiveArtifact*(kind: ArtifactKind,
    access: ArtifactAccess): Artifact =
  ## The artifact that does not exist yet: a kind and an access decision, and
  ## nothing observed about the bytes.
  ##
  ## This is what makes the `assOffered` stage go through the **same** builder
  ## as the other two.  The alternative — a second builder taking
  ## `(kind, protection)` — is how the offer screen and the result screen come
  ## to say different things about the same upload, which is the failure this
  ## module exists to prevent.  Nothing is invented: there is no id, no display
  ## name and no metadata yet, and `sharingView` omits absent values rather
  ## than printing empty ones.
  Artifact(
    artifactId: "",
    kind: kind,
    access: access,
    payload: ArtifactPayload(byteSize: -1, partCount: 1),
    displayName: "",
    metadata: ArtifactMetadata(kind: kind))

proc sharingShape*(view: ArtifactSharingView): seq[string] =
  ## The view's **structure**, with every kind-dependent value removed.
  ##
  ## Exists so "the flow is identical across kinds" can be asserted as an
  ## equality rather than argued.  What survives is the stage, the section
  ## headings that are present, every access and protection line's label AND
  ## value (both are kind-neutral), every notice, and whether a link, an id, a
  ## title and an open command are present.  What is removed is exactly the
  ## three doors: the noun, the facts, and the open command's text.
  result = @["stage:" & $view.stage]
  result.add "title:" & (if view.title.len > 0: "present" else: "absent")
  result.add "id:" & (if view.artifactId.len > 0: "present" else: "absent")
  result.add "facts:" & (if view.facts.len > 0: "present" else: "absent")
  for line in view.access:
    result.add "access:" & line.label & "=" & line.value
  for line in view.protection:
    result.add "protection:" & line.label & "=" & line.value
  # Present/absent only: the VALUE is §10.4's per-kind list, which is the
  # fourth door and is asserted against `serviceVisibleMetadataFields` and
  # `serviceVisibleAccessFields` separately.
  result.add "visible:" &
    (if view.visibleToService.len > 0: "present" else: "absent")
  result.add "link:" & (if view.link.len > 0: "present" else: "absent")
  result.add "open:" & (if view.openCommand.len > 0: "present" else: "absent")
  for notice in view.notices:
    result.add "notice:" & notice
  # `kindApiNotices` is deliberately NOT in the shape: it is the one difference
  # a kind is allowed, it is derived from `kindCarriesAccessRecord`, and the
  # suite asserts that derivation separately.  Folding it in here would make
  # the cross-kind equality vacuously false and hide everything else.

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc renderSharingView*(view: ArtifactSharingView): string =
  ## The view as a terminal block.
  ##
  ## One renderer, so `ct upload` and `ct download` cannot lay the same
  ## information out differently — which they did before this milestone, in
  ## four places.
  var lines: seq[string] = @[]
  lines.add view.heading
  if view.title.len > 0:
    lines.add "  " & view.kindLabel & ": " & view.title
  if view.artifactId.len > 0:
    lines.add "  " & SharingIdLabel & ": " & view.artifactId
  if view.facts.len > 0:
    lines.add "  " & SharingFactsHeading & ":"
    for fact in view.facts:
      lines.add "    " & fact.label & ": " & fact.value
  if view.access.len > 0:
    lines.add "  " & SharingAccessHeading & ":"
    for line in view.access:
      lines.add "    " & line.label & ": " & line.value
  if view.protection.len > 0:
    lines.add "  " & SharingProtectionHeading & ":"
    for line in view.protection:
      lines.add "    " & line.label & ": " & line.value
  if view.visibleToService.len > 0:
    lines.add "    " & SharingVisibleLabel & ": " & view.visibleToService
  if view.link.len > 0:
    lines.add "  " & SharingLinkLabel & ": " & view.link
  if view.downloadCommand.len > 0:
    lines.add "  " & SharingDownloadLabel & ": " & view.downloadCommand
  if view.openCommand.len > 0:
    lines.add "  " & SharingOpenLabel & ": " & view.openCommand
  for notice in view.notices:
    lines.add "  " & notice
  for notice in view.kindApiNotices:
    lines.add "  " & notice
  lines.join("\n")

proc sharingViewJson*(view: ArtifactSharingView): JsonNode =
  ## The view for a non-interactive caller.  Same fields, same names, so a
  ## script and a human are told the same things.
  var facts = newJObject()
  for fact in view.facts:
    facts[fact.label] = %fact.value
  var access = newJObject()
  for line in view.access:
    access[line.label] = %line.value
  result = %*{
    "stage": $view.stage,
    "kind": kindSpec(view.kind).wireToken,
    "artifactId": view.artifactId,
    "displayName": view.title,
    "facts": facts,
    "access": access,
    "notices": %(view.notices & view.kindApiNotices),
  }
  if view.visibleToService.len > 0:
    result["stillVisibleToService"] = %view.visibleToService
  if view.link.len > 0:
    result["shareUrl"] = %view.link
    result["downloadCommand"] = %view.downloadCommand
  if view.openCommand.len > 0:
    result["openCommand"] = %view.openCommand

proc sharingViewJsonLine*(view: ArtifactSharingView): string =
  ## The machine-readable view as one line.
  ##
  ## Exists so a caller can emit it without importing `std/json` — which
  ## `download.nim` deliberately does not, for the same reason it does not
  ## import `nimcrypto`: the file should not read as the place where the thing
  ## happens.
  $sharingViewJson(view)

# ---------------------------------------------------------------------------
# The listing
# ---------------------------------------------------------------------------

type
  ArtifactListingRow* = object
    ## One row of a listing over artifacts of every kind.
    ##
    ## AS-4's second deliverable in its narrowest form: this record has to make
    ## a recording distinguishable from a review dataset **without opening
    ## either**, so it carries the kind explicitly and a kind-appropriate
    ## summary beside it.  A listing that showed only ids and dates would meet
    ## the letter of "one listing" and none of the point.
    kind*: ArtifactKind
    kindLabel*: string
    artifactId*: string
    shortId*: string
    title*: string
    summary*: string
      ## The kind-appropriate identifying facts, from `artifactSummary`.
    protectionLabel*: string
    accessLabel*: string
    openCommand*: string

const
  ArtifactShortIdWidth* = 12
    ## The same width `interactive_replay.shortRecordingId` uses for a
    ## recording id, so one listing does not truncate two kinds' ids
    ## differently.

  ArtifactListingSummaryWidth* = 40
    ## How much of a row's summary a fixed-width listing shows.
    ##
    ## What this buys is a **stable layout**, not a narrow one: a session title
    ## and a pair of commit shas are unbounded, so without a budget the access
    ## column's position depends on the data. It does not make the row fit an
    ## eighty-column terminal and §11.7 no longer claims it does — the row is
    ## about 143 columns, the same order as the pre-AS-4 recording row.
    ##
    ## The JSON form carries the summary whole; this is a terminal-column
    ## budget, not a fact about the artifact.

  ListingLocalOnly* = "local only"
    ## What the access column says for an artifact that has not been shared.
    ##
    ## An honest absence rather than a guess: a local artifact has no owning
    ## tenant, so there is no visibility to report, and reporting the model's
    ## default (`tenant`) would tell a user their recording is visible to an
    ## organisation that has never seen it.

proc shortArtifactId*(artifactId: string): string =
  if artifactId.len <= ArtifactShortIdWidth:
    artifactId
  else:
    artifactId[0 ..< ArtifactShortIdWidth] & ".."

proc listingRow*(artifact: Artifact, locator: string = ""):
    ArtifactListingRow =
  ## One listing row, from the artifact model and nothing else.
  let view = sharingView(artifact, assOffered, locator = locator)
  ArtifactListingRow(
    kind: artifact.kind,
    kindLabel: view.kindLabel,
    artifactId: artifact.artifactId,
    shortId: shortArtifactId(artifact.artifactId),
    title: artifact.displayName,
    summary: artifactSummary(artifact.metadata, artifact.displayName),
    protectionLabel:
      (if protectionSpec(artifact.access.protection).encryptsPayload:
         "encrypted"
       else: "not encrypted"),
    accessLabel:
      (if artifact.access.tenantId.len == 0: ListingLocalOnly
       else: describeVisibility(artifact.access.visibility)),
    openCommand: view.openCommand)

proc truncateForColumn*(text: string, budget: int): string =
  ## `text`, shortened to at most `budget` bytes with an ellipsis.
  ##
  ## The cut is moved back off a UTF-8 continuation byte before it is made: the
  ## summary's separator is `·` and a commit sha can be followed by one, so a
  ## naive byte slice would emit half a code point into a terminal.
  if text.len <= budget:
    return text
  var cut = budget - 1
  while cut > 0 and (uint8(text[cut]) and 0b1100_0000'u8) == 0b1000_0000'u8:
    dec cut
  text[0 ..< cut] & "…"

proc renderListing*(rows: seq[ArtifactListingRow]): string =
  ## The listing as aligned columns: id, kind, title, the kind's own facts,
  ## access.
  ##
  ## The **kind column is not optional and is not last**.  It is what makes the
  ## two kinds distinguishable at a glance, which is the deliverable; putting
  ## it after a variable-width title would put it in a different place on every
  ## row.
  if rows.len == 0:
    return ""
  var kindWidth = 0
  var titleWidth = 0
  for row in rows:
    kindWidth = max(kindWidth, row.kindLabel.len)
    titleWidth = max(titleWidth, row.title.len)
  var lines: seq[string] = @[]
  for row in rows:
    var line = alignLeft(row.shortId, ArtifactShortIdWidth + 2) & " | " &
      alignLeft(row.kindLabel, kindWidth) & " | " &
      alignLeft(row.title, titleWidth)
    if row.summary.len > 0:
      # Truncated rather than wrapped, and truncated HERE rather than in the
      # summary itself: the full values belong in the detail view, and a
      # review dataset's two 40-character commit shas would otherwise push the
      # access column off the right of an eighty-column terminal.
      line &= " | " & alignLeft(
        truncateForColumn(row.summary, ArtifactListingSummaryWidth),
        ArtifactListingSummaryWidth)
    line &= " | " & row.accessLabel
    # The FULL id last, which is what the pre-AS-4 recording listing did and
    # said why: "we append the full UUIDv7 at the end of the line so users can
    # copy-paste it without squeezing every column" (M-REC-6). Dropping it was
    # an undisclosed removal — the short prefix is for reading, not for typing
    # into `ct replay` — so it is back, and now for every kind.
    line &= " | " & row.artifactId
    lines.add line
  lines.join("\n")

proc listingRowJson*(row: ArtifactListingRow): JsonNode =
  %*{
    "kind": kindSpec(row.kind).wireToken,
    "artifactId": row.artifactId,
    "displayName": row.title,
    "summary": row.summary,
    "protection": row.protectionLabel,
    "access": row.accessLabel,
    "openCommand": row.openCommand,
  }

proc listingJson*(rows: seq[ArtifactListingRow]): JsonNode =
  result = newJArray()
  for row in rows:
    result.add listingRowJson(row)
