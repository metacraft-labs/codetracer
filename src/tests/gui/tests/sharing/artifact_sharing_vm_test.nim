## AS-4 — one sharing surface: identical across kinds, distinguishable in a
## listing, and honest about access control.
##
## Spec: `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-4, designed
## in `codetracer-specs/Sharing/Artifact-Store.md` §11.
##
## AS-4's three verification items, and the share of each that is answered here
## — the rest is answered against the **shipped `ct` binary** driven over a real
## socket in `src/tests/cli/sharing_flow_cli_test.nim`, because "in the running
## product" is what the milestone asks for and four milestones in the preceding
## campaign were blocked for reading source instead:
##
## 1. **the sharing flow is identical across kinds** — answered here in the only
##    form that can be checked exhaustively.  `sharingView` is one builder and
##    per-kind variation can enter through exactly three doors (the noun, the
##    facts, the open command), so the suite demands that everything else is
##    *byte-identical* over kind × kind × protection × visibility × stage, and
##    that the one sentence carrying the noun turns into the other kind's by
##    substituting it.  A kind cannot acquire its own sharing flow because there
##    is nowhere to put one.
## 2. **each kind is distinguishable in a listing** — the listing row, and the
##    property that makes it worth having: two kinds' rows differ in their kind
##    label, in their summary, and in the command that opens them, and the
##    summary is drawn from the kind's *own* facts rather than from a template.
## 3. **access-control changes take effect and are observable** — the pure half:
##    a changed visibility changes the rendered view, the machine-readable
##    record and the request body, and an unknown token is refused by name
##    against the closed set rather than coerced.  The half that needs a socket
##    is in the CLI suite.
##
## Headless on both Nim backends, for the same reason `artifact_protection.nim`
## is: every sentence here is something a user reads about who can open what
## they shared and about what encryption does not cover, and a promise whose
## test needs a service is a promise nothing checks on most runs.
##
## `just test-vm-native` and `just test-vm-js` reach this file by globbing
## `src/tests/gui/tests/**/*_test.nim`, and `CoreViewModelGateTests` in
## `src/ct_test/release_gate.nim` is the registry that says it must exist.

import std/[json, options, strutils, unicode, unittest]

import ../../../../ct/online_sharing/artifact_sharing

const
  SampleRecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  SampleDatasetId = "0194a000-1111-7abc-8def-000000000001"
  SampleTenantId = "0194a000-2222-7abc-8def-000000000002"
  SampleLink = "https://web.codetracer.com/acme/" & SampleDatasetId &
    "/download"

proc sampleArtifact(kind: ArtifactKind,
    visibility: ArtifactVisibility = avTenant,
    protection: ArtifactProtection = apNone,
    tenantId: string = SampleTenantId): Artifact =
  ## One artifact per kind, filled in enough that every declared fact has a
  ## value — so an assertion that a fact is missing fails rather than passing
  ## because the sample never had it.
  ##
  ## Exhaustive `case`: a kind added without a sample does not compile, which
  ## is the same enforcement `artifact_model_vm_test.nim` uses.
  case kind
  of akRecording:
    recordingArtifact(
      recordingId = SampleRecordingId,
      tenantId = tenantId,
      program = "sudoku",
      langName = "LangNoir",
      byteSize = 4_194_304,
      platform = "linux-x86_64",
      recordedAtUnixMs = 1_766_000_000_000'i64,
      visibility = visibility,
      protection = protection)
  of akReviewDataset:
    reviewDatasetArtifact(
      artifactId = SampleDatasetId,
      tenantId = tenantId,
      commitSha = "9f1c2d3e4b5a69788796a5b4c3d2e1f009182736",
      baseCommitSha = "0011223344556677889900aabbccddeeff001122",
      byteSize = 4_194_304,
      fileCount = 3,
      recordingCount = 1,
      sessionTitle = "parser cleanup",
      visibility = visibility,
      protection = protection)

proc sampleLocator(kind: ArtifactKind): string =
  case kind
  of akRecording: SampleRecordingId
  of akReviewDataset: "/home/dev/.local/share/codetracer/review-datasets/x"

# ---------------------------------------------------------------------------
# The render layer, and why the equality has to reach it
# ---------------------------------------------------------------------------
#
# `sharingShape` is a function of the VIEW. Independent verification put a
# sixth door in `renderSharingView` instead —
#
#     if view.kind == akRecording and view.stage == assShared:
#       lines.add "  You can run the replay in the browser."
#
# — and every suite in this file and in `sharing_flow_cli_test.nim` stayed
# green, because nothing compared the RENDERED output across kinds. The
# milestone's own removed wording came back on the recording path with 42/42
# OK. So the equality is asserted here on the text a user actually reads, and
# it is asserted in the strong direction: **every line must be accounted for**.
#
# `kindSpecificRenderedLines` reconstructs, from the view's own fields, exactly
# the lines the five doors and the three per-artifact values may produce. A
# line that is none of them is by definition kind-neutral, so it must be equal
# across kinds.
#
# ## What stops the RECONSTRUCTION from becoming the hiding place
#
# Widening it is the obvious next move, and the mechanism has to be stated
# correctly because a maintainer will rely on it. An earlier version of this
# comment claimed "the arithmetic stops adding up"; it does not. That check —
# `kindNeutral.len == rendered.len - doors.len` — is a **tautology** for any
# reconstruction whose lines each appear once, so widening it to swallow the
# share link left the suite green. Independent verification measured that.
#
# What actually protects the guarantee is that the reconstruction is built from
# the view's **own fields**, so it can only absorb a line whose rendered text
# equals the field-derived text. The moment a swallowed line differs per kind —
# which is the only way a door can hide in it — the reconstruction stops
# matching and `line in rendered` fails.
#
# Beside that, a **cardinality** pin that is not a tautology:
# `kindSpecificRenderedLines` must contain exactly as many entries as the view's
# declared doors call for (`expectedDoorLineCount`). Adding the share link to it
# makes that count wrong, which is the case the old arithmetic missed.
#
# The reconstruction lives HERE rather than in the module on purpose: a
# normaliser shipped beside the renderer is a second place to hide the door.

proc expectedDoorLineCount(view: ArtifactSharingView): int =
  ## How many rendered lines the declared doors and per-artifact values account
  ## for, counted from the view independently of how they are built.
  1 +                                                   # the heading
    (if view.title.len > 0: 1 else: 0) +
    (if view.artifactId.len > 0: 1 else: 0) +
    view.facts.len +
    (if view.visibleToService.len > 0: 1 else: 0) +
    (if view.openCommand.len > 0: 1 else: 0) +
    view.kindApiNotices.len

proc kindSpecificRenderedLines(view: ArtifactSharingView): seq[string] =
  ## Every rendered line whose text is allowed to differ between two kinds,
  ## rebuilt from the view. Nothing is matched by pattern or prefix.
  result = @[]
  # Door 1 — the noun, which reaches the heading and the title's label.
  result.add view.heading
  if view.title.len > 0:
    result.add "  " & view.kindLabel & ": " & view.title
  # Per-artifact, not per-kind, but different between any two samples.
  if view.artifactId.len > 0:
    result.add "  " & SharingIdLabel & ": " & view.artifactId
  # Door 2 — the kind's own facts.
  for fact in view.facts:
    result.add "    " & fact.label & ": " & fact.value
  # Door 4 — §10.4's per-kind visible-metadata list.
  if view.visibleToService.len > 0:
    result.add "    " & SharingVisibleLabel & ": " & view.visibleToService
  # Door 3 — the command that opens this kind.
  if view.openCommand.len > 0:
    result.add "  " & SharingOpenLabel & ": " & view.openCommand
  # Door 5 — the sentence a kind with frozen request bodies owes.
  for notice in view.kindApiNotices:
    result.add "  " & notice

proc kindNeutralRenderedLines(view: ArtifactSharingView): seq[string] =
  ## The rendered lines that must be identical for every kind: everything
  ## `kindSpecificRenderedLines` does not account for, each such line removed
  ## exactly once so a duplicate cannot be swallowed.
  var allowed = kindSpecificRenderedLines(view)
  result = @[]
  for line in renderSharingView(view).splitLines():
    let at = allowed.find(line)
    if at >= 0:
      allowed.delete(at)
    else:
      result.add line

proc kindSpecificJsonKeys(): seq[string] =
  ## The `sharingViewJson` keys the doors and the per-artifact values own.
  ##
  ## `notices` is on the list because it CONCATENATES `kindApiNotices`
  ## (door 5); the kind-neutral half is compared separately, as `view.notices`.
  @["kind", "artifactId", "displayName", "facts", "openCommand",
    "stillVisibleToService", "notices"]

proc jsonWithoutDoors(node: JsonNode):
    tuple[remainder: JsonNode, presence: seq[string]] =
  ## `node` with the door keys removed, and a **separate** record of which of
  ## them were present.
  ##
  ## The presence record is returned alongside rather than written back into
  ## the object, and that is a correction: an earlier version set
  ## `node[key & "-absent"] = true`, so a per-kind key named after the test's
  ## own suffix — emitted only where the real door key is absent for both
  ## kinds — was absorbed and vanished, 37/37 green. Contrived, but a test's
  ## private naming convention must not be something the subject can collide
  ## with.
  var remainder = copy(node)
  var presence: seq[string] = @[]
  for key in kindSpecificJsonKeys():
    presence.add key & ":" &
      (if remainder.hasKey(key): "present" else: "absent")
    if remainder.hasKey(key):
      remainder.delete(key)
  (remainder, presence)

# ---------------------------------------------------------------------------

suite "AS-4 — the sharing flow is identical across kinds":
  ## Verification item 1, in the form that can be asserted exhaustively.  The
  ## property is guaranteed by construction — one builder, three doors — and
  ## then checked, so a fourth door added later fails here rather than being
  ## discovered by a user reading two different accounts of one upload.

  test "the view's shape is identical for any two kinds, in every state":
    for stage in ArtifactSharingStage:
      for protection in ArtifactProtection:
        for visibility in ArtifactVisibility:
          for first in ArtifactKind:
            for second in ArtifactKind:
              checkpoint($stage & " " & $protection & " " & $visibility & " " &
                $first & " -> " & $second)
              let a = sharingView(
                sampleArtifact(first, visibility, protection), stage,
                link = SampleLink, locator = sampleLocator(first))
              let b = sharingView(
                sampleArtifact(second, visibility, protection), stage,
                link = SampleLink, locator = sampleLocator(second))
              # Not "is similar": is equal.  The shape carries every access
              # line and every protection line with its VALUE, so a kind that
              # acquired its own wording about encryption or about who can read
              # it fails here.
              check sharingShape(a) == sharingShape(b)

  test "every kind-neutral section is byte-identical for any two kinds":
    for protection in ArtifactProtection:
      for visibility in ArtifactVisibility:
        for first in ArtifactKind:
          for second in ArtifactKind:
            checkpoint($protection & " " & $visibility & " " & $first &
              " -> " & $second)
            let a = sharingView(
              sampleArtifact(first, visibility, protection), assShared,
              link = SampleLink)
            let b = sharingView(
              sampleArtifact(second, visibility, protection), assShared,
              link = SampleLink)
            check a.access == b.access
            # Every SENTENCE about the protection is identical.  §10.4's list
            # of what stays visible is not — it is per kind by necessity, and
            # it is the fourth door, asserted against the registry below.
            check a.protection == b.protection
            check a.notices == b.notices
            check a.link == b.link
            check a.downloadCommand == b.downloadCommand
            check a.stage == b.stage

  test "the door reconstruction removes the doors and nothing else":
    # Pins the normaliser the equalities below depend on, and pins it with a
    # check that actually fires. The arithmetic this used to assert
    # (`kindNeutral.len == rendered.len - doors.len`) is a tautology; adding
    # the share link to the reconstruction left it green. The CARDINALITY —
    # counted from the view's declared doors, independently of how the
    # reconstruction builds them — does not.
    for stage in ArtifactSharingStage:
      for protection in ArtifactProtection:
        for accessKnown in [true, false]:
          for kind in ArtifactKind:
            for prospective in [false, true]:
              checkpoint($stage & " " & $protection & " known=" & $accessKnown &
                " " & $kind & " prospective=" & $prospective)
              # BOTH shapes: the one with a title, an id and facts, and the
              # `assOffered` shape `ct upload` renders for every user before
              # they choose — which has none of the three, and which an
              # earlier version of this loop never reached.
              let view =
                if prospective:
                  sharingView(prospectiveArtifact(kind,
                    initArtifactAccess(SampleTenantId, avTenant,
                      protection = protection)), stage,
                    accessKnown = accessKnown)
                else:
                  sharingView(
                    sampleArtifact(kind, avTenant, protection), stage,
                    link = SampleLink, locator = sampleLocator(kind),
                    accessKnown = accessKnown)
              let rendered = renderSharingView(view).splitLines()
              let doors = kindSpecificRenderedLines(view)
              # Every reconstructed door line is really in the output — this is
              # what stops a widened reconstruction from swallowing a per-kind
              # line, because the swallowed text would have to equal the
              # field-derived text.
              for line in doors:
                checkpoint(line)
                check line in rendered
              # …and there are exactly as many of them as the view's declared
              # doors call for. A reconstruction that grew an extra entry fails
              # here whether or not that entry happens to match a line.
              check doors.len == expectedDoorLineCount(view)
              check doors.len > 0

  test "the offer a user sees before choosing is identical across kinds":
    # `prospectiveArtifact` — no title, no id, no facts — is what `ct upload`
    # renders for EVERY user before they choose, and it was reached by the CLI
    # suite's offer-block comparison and by neither the rendered equality nor
    # the pin. A door gated on "the artifact has no title yet" would have been
    # invisible to both.
    for protection in ArtifactProtection:
      for visibility in ArtifactVisibility:
        for first in ArtifactKind:
          for second in ArtifactKind:
            checkpoint($protection & " " & $visibility & " " & $first &
              " -> " & $second)
            let access = initArtifactAccess(SampleTenantId, visibility,
              protection = protection)
            let a = sharingView(prospectiveArtifact(first, access), assOffered)
            let b = sharingView(prospectiveArtifact(second, access), assOffered)
            check kindNeutralRenderedLines(a) == kindNeutralRenderedLines(b)
            check a.title == "" and a.artifactId == "" and a.facts.len == 0

  test "the RENDERED output is identical across kinds outside the doors":
    # `sharingShape` compares the view; this compares the text a user reads.
    # Independent verification put a sixth door in `renderSharingView` gated on
    # `assShared` and every suite stayed green — the guarantee was true of the
    # value and false of the output. It is now asserted at both layers.
    for stage in ArtifactSharingStage:
      for protection in ArtifactProtection:
        for visibility in ArtifactVisibility:
          for accessKnown in [true, false]:
            for first in ArtifactKind:
              for second in ArtifactKind:
                checkpoint($stage & " " & $protection & " " & $visibility &
                  " known=" & $accessKnown & " " & $first & " -> " & $second)
                let a = sharingView(
                  sampleArtifact(first, visibility, protection), stage,
                  link = SampleLink, locator = sampleLocator(first),
                  accessKnown = accessKnown)
                let b = sharingView(
                  sampleArtifact(second, visibility, protection), stage,
                  link = SampleLink, locator = sampleLocator(second),
                  accessKnown = accessKnown)
                check kindNeutralRenderedLines(a) ==
                  kindNeutralRenderedLines(b)

  test "the MACHINE-READABLE view is identical across kinds outside the doors":
    # The same demand on `sharingViewJson`, because `ct upload`'s
    # non-interactive branch and `ct download`'s stderr line are what a script
    # reads, and a door added there would be as invisible as one in the
    # renderer was.
    for stage in ArtifactSharingStage:
      for protection in ArtifactProtection:
        for visibility in ArtifactVisibility:
          for first in ArtifactKind:
            for second in ArtifactKind:
              checkpoint($stage & " " & $protection & " " & $visibility & " " &
                $first & " -> " & $second)
              var encoded: array[2, JsonNode]
              var presence: array[2, seq[string]]
              for index, kind in [first, second]:
                let view = sharingView(
                  sampleArtifact(kind, visibility, protection), stage,
                  link = SampleLink, locator = sampleLocator(kind))
                # A door key is optional (`openCommand` and
                # `stillVisibleToService` are absent in some states), and its
                # PRESENCE must not differ between kinds either — so it is
                # recorded beside the object rather than written into it.
                let split = jsonWithoutDoors(sharingViewJson(view))
                encoded[index] = split.remainder
                presence[index] = split.presence
              check encoded[0] == encoded[1]
              check presence[0] == presence[1]
              # …and the kind-neutral half of `notices` really is equal, which
              # the deletion above would otherwise hide.
              check sharingView(sampleArtifact(first, visibility, protection),
                  stage, link = SampleLink).notices ==
                sharingView(sampleArtifact(second, visibility, protection),
                  stage, link = SampleLink).notices

  test "the one kind-dependent sentence turns into the other kind's by the noun":
    # The same demand AS-3 makes of the password prompt, one layer out: the
    # heading is the only place the noun appears outside `subject` itself.
    for stage in ArtifactSharingStage:
      for first in ArtifactKind:
        for second in ArtifactKind:
          checkpoint($stage & " " & $first & " -> " & $second)
          let a = sharingView(sampleArtifact(first), stage)
          let b = sharingView(sampleArtifact(second), stage)
          check a.heading.replace(artifactSubjectNoun(first),
            artifactSubjectNoun(second)) == b.heading

  test "the offered stage goes through the same builder as the others":
    # The failure this prevents: an offer screen written separately from the
    # result screen, saying different things about one upload.  `ct upload`'s
    # disclosure IS `sharingView(..., assOffered)`.
    for kind in ArtifactKind:
      checkpoint($kind)
      let offered = sharingView(
        prospectiveArtifact(kind, initArtifactAccess(SampleTenantId,
          protection = apPasswordScryptAes256Gcm)), assOffered)
      let shared = sharingView(
        sampleArtifact(kind, protection = apPasswordScryptAes256Gcm),
        assShared)
      check offered.access == shared.access
      check offered.protection == shared.protection
      # …and nothing is invented for an artifact that does not exist yet.
      check offered.artifactId == ""
      check offered.title == ""
      check offered.facts.len == 0

  test "the three doors are the only differences, and they are all present":
    for first in ArtifactKind:
      for second in ArtifactKind:
        if first == second:
          continue
        checkpoint($first & " vs " & $second)
        let a = sharingView(sampleArtifact(first), assReceived,
          locator = sampleLocator(first))
        let b = sharingView(sampleArtifact(second), assReceived,
          locator = sampleLocator(second))
        check a.subject != b.subject
        check a.facts != b.facts
        check a.openCommand != b.openCommand

suite "AS-4 — the surface never overstates what sharing gives you":
  ## Every string added by this milestone is subject to the reading AS-3's
  ## were.  The service sees metadata and can CHANGE it; only the payload is
  ## authenticated; a password protects against the service and anyone with the
  ## link; recovery is nothing.

  test "no view claims privacy, secrecy or that only the owner can read it":
    # A word list rather than a review, because a review happens once and this
    # runs on every lane.  "private", "secure" and "only you" are the three
    # spellings a sharing UI reaches for and none of them is true here.
    for stage in ArtifactSharingStage:
      for protection in ArtifactProtection:
        for visibility in ArtifactVisibility:
          for kind in ArtifactKind:
            checkpoint($stage & " " & $protection & " " & $visibility & " " &
              $kind)
            let rendered = renderSharingView(sharingView(
              sampleArtifact(kind, visibility, protection), stage,
              link = SampleLink, locator = sampleLocator(kind)))
            let lowered = rendered.toLowerAscii()
            for overstatement in ["private", "secure", "only you", "safe to",
                "nobody else", "no one else"]:
              checkpoint(overstatement)
              check overstatement notin lowered

  test "an unprotected artifact gets no protection section at all":
    # In this direction too: a paragraph about what encryption does not cover,
    # printed for an artifact that is not encrypted, trains a user to skip the
    # one screen where it matters.
    for kind in ArtifactKind:
      checkpoint($kind)
      let view = sharingView(sampleArtifact(kind, protection = apNone),
        assShared, link = SampleLink)
      check view.protection.len == 0
      check "Still visible to the service" notin renderSharingView(view)
      # …and the link is still called sensitive, because it is.
      check view.notices.len == 1
      check "anyone who has it can open" in view.notices[0]

  test "an encrypted artifact says the link alone is not enough, and why":
    for kind in ArtifactKind:
      checkpoint($kind)
      let view = sharingView(
        sampleArtifact(kind, protection = apPasswordScryptAes256Gcm),
        assShared, link = SampleLink)
      check view.notices.len == 1
      check "also needs the password" in view.notices[0]
      check "cannot recover it" in view.notices[0]
      # The recovery answer is the registry's word, not a euphemism.
      var recovery = ""
      for line in view.protection:
        if line.label == "If you lose the password":
          recovery = line.value
      check recovery.startsWith("Nothing.")

  test "the visible-metadata line names the access fields the wire carries":
    # §10.4 grew an access row in AS-4.  This is the half that keeps the
    # sentence and the wire together on the pure side; the round-trip suite
    # compares the same list against the bytes on the socket.
    for kind in ArtifactKind:
      checkpoint($kind)
      let view = sharingView(
        sampleArtifact(kind, protection = apPasswordScryptAes256Gcm),
        assShared)
      check view.visibleToService.len > 0
      check view.visibleToService == describeVisibleToService(kind)
      for field in serviceVisibleMetadataFields(kind):
        checkpoint(field)
        check field in view.visibleToService
      for field in serviceVisibleAccessFields(kind):
        checkpoint(field)
        check field in view.visibleToService
      for fact in serviceVisibleTransferFacts():
        checkpoint(fact)
        check fact in view.visibleToService
      check view.visibleToService in renderSharingView(view)
      # And it is absent, not empty, when nothing is encrypted.
      check sharingView(sampleArtifact(kind, protection = apNone),
        assShared).visibleToService == ""

suite "AS-4 — each kind is distinguishable in a listing":
  ## Verification item 2.  "Recognisable without opening it" is a claim about
  ## what a row carries, so the assertions are about the row.

  test "two kinds' rows differ in label, summary and open command":
    for first in ArtifactKind:
      for second in ArtifactKind:
        if first == second:
          continue
        checkpoint($first & " vs " & $second)
        let a = listingRow(sampleArtifact(first), sampleLocator(first))
        let b = listingRow(sampleArtifact(second), sampleLocator(second))
        check a.kindLabel != b.kindLabel
        check a.summary != b.summary
        check a.openCommand != b.openCommand

  test "every kind has a non-empty label, title and summary":
    for kind in ArtifactKind:
      checkpoint($kind)
      let row = listingRow(sampleArtifact(kind), sampleLocator(kind))
      check row.kindLabel.len > 0
      check row.title.len > 0
      check row.summary.len > 0
      check row.artifactId.len > 0
      check row.shortId.len > 0
      check row.shortId.len <= ArtifactShortIdWidth + 2

  test "a row's summary is drawn from that kind's own facts":
    # Not from a template: the value has to appear in the kind's declared
    # facts, so a summary that stopped describing the artifact fails here.
    for kind in ArtifactKind:
      checkpoint($kind)
      let artifact = sampleArtifact(kind)
      let row = listingRow(artifact, sampleLocator(kind))
      var factValues: seq[string] = @[]
      for fact in artifactFacts(artifact.metadata):
        factValues.add fact.value
      for piece in row.summary.split(" · "):
        checkpoint(piece)
        check piece in factValues
      # …and it does not repeat the column beside it.  A recording's display
      # name IS its program, so a row that put the program in the summary too
      # would spend half its width saying one word twice.
      check artifact.displayName notin row.summary.split(" · ")

  test "the rendered listing shows both kinds, each named":
    var rows: seq[ArtifactListingRow] = @[]
    for kind in ArtifactKind:
      rows.add listingRow(sampleArtifact(kind), sampleLocator(kind))
    let rendered = renderListing(rows)
    check rendered.splitLines().len == rows.len
    for kind in ArtifactKind:
      checkpoint($kind)
      # The kind label is on the row, which is what makes a recording and a
      # review dataset tellable apart at a glance.
      check listingRow(sampleArtifact(kind)).kindLabel in rendered
    check "sudoku" in rendered
    check "parser cleanup" in rendered

  test "every row ends in the full id, copy-pasteable":
    # The pre-AS-4 recording listing appended it deliberately — "so users can
    # copy-paste it without squeezing every column" (M-REC-6) — and AS-4 first
    # dropped it without saying so. The short prefix is for reading; `ct replay`
    # needs the whole thing.
    for kind in ArtifactKind:
      checkpoint($kind)
      let row = listingRow(sampleArtifact(kind), sampleLocator(kind))
      let rendered = renderListing(@[row])
      check rendered.endsWith(row.artifactId)
      check row.artifactId.len == 36

  test "an unshared artifact's row says 'local only' rather than guessing":
    # A local recording has no owning organisation.  Printing the model's
    # default visibility would tell a user their recording is readable by an
    # organisation that has never seen it.
    for kind in ArtifactKind:
      checkpoint($kind)
      let row = listingRow(sampleArtifact(kind, tenantId = ""))
      check row.accessLabel == ListingLocalOnly
      let shared = listingRow(sampleArtifact(kind, avTenantOrInvite))
      check shared.accessLabel == describeVisibility(avTenantOrInvite)

  test "the JSON listing names the kind with the registry's own token":
    for kind in ArtifactKind:
      checkpoint($kind)
      let row = listingRow(sampleArtifact(kind), sampleLocator(kind))
      let encoded = listingRowJson(row)
      check encoded["kind"].getStr == kindSpec(kind).wireToken
      check parseArtifactKind(encoded["kind"].getStr).isSome
      check encoded["artifactId"].getStr == row.artifactId
      check encoded["summary"].getStr == row.summary

suite "AS-4 — access-control changes take effect and are observable":
  ## Verification item 3, the pure half.  "Takes effect" means the artifact
  ## really carries it and the wire really sends it; "observable" means the
  ## surface says so and the machine-readable form reports it.

  test "changing the visibility changes what the surface says":
    for kind in ArtifactKind:
      checkpoint($kind)
      let narrow = sharingView(
        sampleArtifact(kind, avTenant), assShared)
      let wide = sharingView(
        sampleArtifact(kind, avTenantOrInvite), assShared)
      check narrow.access != wide.access
      check describeVisibility(avTenant) in renderSharingView(narrow)
      check describeVisibility(avTenantOrInvite) in renderSharingView(wide)
      # And neither of them calls the wider one "public", because it is not.
      check "public" notin renderSharingView(wide).toLowerAscii()

  test "an access record the service never sent is not invented":
    # Found by running `ct download` and reading the output. No deployed
    # service returns an artifact record (§9.4), so the received view was
    # printing the MODEL'S DEFAULT visibility as though it were this
    # artifact's — a fabricated fact about who can read somebody's data, which
    # is §8 defect 4's failure in another form.
    for kind in ArtifactKind:
      for protection in ArtifactProtection:
        checkpoint($kind & " " & $protection)
        let unknown = sharingView(
          sampleArtifact(kind, avTenantOrInvite, protection), assReceived,
          accessKnown = false)
        for line in unknown.access:
          if line.label == "Protection":
            # Protection survives, and ONLY protection: it is read from the
            # downloaded bytes, not from anything the service said.
            check line.value == protectionSpec(protection).headline
          else:
            check line.value == AccessNotStated
        let rendered = renderSharingView(unknown)
        for visibility in ArtifactVisibility:
          checkpoint($visibility)
          check describeVisibility(visibility) notin rendered
        for role in ArtifactRole:
          check describeWriteRole(role) notin rendered

  test "not knowing the access record is the same non-answer for every kind":
    for first in ArtifactKind:
      for second in ArtifactKind:
        checkpoint($first & " -> " & $second)
        let a = sharingView(sampleArtifact(first), assReceived,
          accessKnown = false)
        let b = sharingView(sampleArtifact(second), assReceived,
          accessKnown = false)
        check a.access == b.access
        check sharingShape(a) == sharingShape(b)

  test "every declared visibility and role has its own sentence":
    var seenVisibility: seq[string] = @[]
    for visibility in ArtifactVisibility:
      checkpoint($visibility)
      let sentence = describeVisibility(visibility)
      check sentence.len > 0
      check sentence notin seenVisibility
      seenVisibility.add sentence
    var seenRole: seq[string] = @[]
    for role in ArtifactRole:
      checkpoint($role)
      let sentence = describeWriteRole(role)
      check sentence.len > 0
      check sentence notin seenRole
      seenRole.add sentence

  test "the access record reaches the wire for a kind whose bodies can carry it":
    for kind in ArtifactKind:
      for visibility in ArtifactVisibility:
        checkpoint($kind & " " & $visibility)
        let artifact = sampleArtifact(kind, visibility)
        let body = buildArtifactUploadUrlBody(artifact, "payload.zip")
        if kindCarriesAccessRecord(kind):
          # `hasKey` first, so a body that dropped the record entirely is a
          # named failure rather than a `KeyError` traceback.
          check body.hasKey("access")
          check body{"access"}{"visibility"}.getStr == $visibility
          check body{"access"}{"minimumWriteRole"}.getStr ==
            $artifact.access.minimumWriteRole
          check serviceVisibleAccessFields(kind) ==
            @["visibility", "minimumWriteRole"]
        else:
          # The recording kind's bodies are frozen (§9.3).  Not sending it is
          # the compatibility guarantee; SAYING it is not sent is AS-4's job.
          check not body.hasKey("access")
          check serviceVisibleAccessFields(kind).len == 0

  test "a kind that cannot carry the access record says so, in the view":
    for kind in ArtifactKind:
      checkpoint($kind)
      let view = sharingView(sampleArtifact(kind), assShared)
      if kindCarriesAccessRecord(kind):
        check view.kindApiNotices.len == 0
      else:
        check view.kindApiNotices.len == 1
        check "the service was told neither" in view.kindApiNotices[0]
        check artifactSubjectNoun(kind) in view.kindApiNotices[0]
        check "the service was told neither" in renderSharingView(view)
        # It names BOTH fields of the access record, not only the one a flag
        # sets: `minimumWriteRole` is not sent either, and a notice that
        # mentions only "who may open" leaves the write role reading as though
        # the service were enforcing the default.
        check "who may open" in view.kindApiNotices[0]
        check "who may change" in view.kindApiNotices[0]

  test "the upload-API notice does not appear after a download":
    # It says what this machine recorded and what the service was not told.
    # After a download neither half is true, and printed there it contradicted
    # the two lines directly above it — which by then read "not stated".
    # Nothing caught it because no test downloaded a recording; the CLI suite
    # now does.
    for kind in ArtifactKind:
      checkpoint($kind)
      let received = sharingView(sampleArtifact(kind), assReceived,
        locator = sampleLocator(kind), accessKnown = false)
      check received.kindApiNotices.len == 0
      let rendered = renderSharingView(received)
      check "upload API" notin rendered
      check "CodeTracer records who may open" notin rendered
      # …and the stages that DO precede or perform an upload still carry it.
      for stage in [assOffered, assShared]:
        checkpoint($stage)
        check sharingView(sampleArtifact(kind), stage).kindApiNotices.len ==
          (if kindCarriesAccessRecord(kind): 0 else: 1)

  test "the access record round-trips through the artifact wire form":
    for visibility in ArtifactVisibility:
      for role in ArtifactRole:
        checkpoint($visibility & " " & $role)
        var artifact = sampleArtifact(akReviewDataset, visibility)
        artifact.access.minimumWriteRole = role
        let restored = parseArtifact(toJson(artifact))
        check restored.error == ""
        check restored.artifact.access.visibility == visibility
        check restored.artifact.access.minimumWriteRole == role

  test "an unknown visibility token is refused, not coerced":
    # The rule AS-2 closed four holes of and AS-3 a fifth, applied to the one
    # new input source this milestone adds.  `--visibility=public` must not
    # read as `tenant`.
    for token in ["public", "Tenant", "tenant ", " tenant", "TENANT",
        "tenant-or-invites", "world", "null", "0", "tenant\n",
        "tenant-or–invite"]:
      checkpoint(token)
      let refused = parseClosedEnumArgument[ArtifactVisibility](
        "visibility", some(token), avTenant)
      check refused.error.len > 0
      check token.strip() in refused.error or token in refused.error
      # The refusal shows the closed set rather than only asserting one.
      for declared in ArtifactVisibility:
        check $declared in refused.error

  test "an option's NEIGHBOUR decides whether it was given a value":
    # The rule `--visibility` is refused by, and the case that matters most is
    # the one an earlier version of this guard broke: `--visibility <VALUE>` is
    # the conventional spelling, it worked, and matching the bare token without
    # looking at the next one refused it with a message that was a false
    # statement about what the user had typed. AS-3's `--password-file -` in
    # mirror image — under-firing on one spelling, over-firing on another, and
    # both times reasoning about a token without reasoning about its
    # neighbour.
    for arguments in [
        @["upload", "--visibility", "tenant"],
        @["upload", "--visibility", "tenant-or-invite"],
        @["upload", "--visibility", "nonsense"],
        @["--visibility", "tenant", "--artifact=x"],
        @["upload", "--visibility=tenant-or-invite"],
        @["upload", "--artifact=x"],
        @["upload", "visibility", "--artifact=x"]]:
      checkpoint(arguments.join(" "))
      check not optionGivenWithoutValue(arguments, "visibility")

    for arguments in [
        @["upload", "--visibility"],
        @["upload", "--visibility="],
        @["upload", "--visibility", "--artifact=x"],
        @["upload", "--visibility", "-x"],
        @["upload", "--visibility=", "tenant"],
        @["--visibility"]]:
      checkpoint(arguments.join(" "))
      check optionGivenWithoutValue(arguments, "visibility")

  test "an ABSENT visibility is the default; an EMPTY one is refused":
    # The distinction `readClosedEnumField` has always made, which the CLI door
    # collapsed: `visibilityToken.get("")` turned `--visibility=` into "not
    # given", so it resolved silently to `tenant` while `{"visibility": ""}` on
    # the wire was refused. AS-3's `--password-file -` in the safe direction —
    # and, being safe, even less likely to be noticed.
    let absent = parseClosedEnumArgument[ArtifactVisibility](
      "visibility", none(string), avTenant)
    check absent.error == ""
    check absent.value == avTenant

    let empty = parseClosedEnumArgument[ArtifactVisibility](
      "visibility", some(""), avTenant)
    check empty.error.len > 0
    check "given with no value" in empty.error
    for declared in ArtifactVisibility:
      check $declared in empty.error

    for visibility in ArtifactVisibility:
      checkpoint($visibility)
      let parsed = parseClosedEnumArgument[ArtifactVisibility](
        "visibility", some($visibility), avTenant)
      check parsed.error == ""
      check parsed.value == visibility

suite "AS-4 — the cross-artifact substitution residual is now visible":
  ## `Artifact-Store.md` §8 defect 18.  A service can serve artifact B for a
  ## link to A, and with a reused password it opens.  AS-3 computed the
  ## envelope's own artifact id and reported it on `ArtifactFetchOutcome`,
  ## where it stopped.  Enforcing it is not possible on the sliced recording
  ## path (§10.3), so telling the user is the whole of the defence.

  test "a payload sealed for another artifact is called out by both ids":
    for kind in ArtifactKind:
      checkpoint($kind)
      let artifact = sampleArtifact(kind)
      let view = sharingView(artifact, assReceived,
        locator = sampleLocator(kind),
        sealedForArtifactId = "0194a000-9999-7abc-8def-000000000009")
      check view.notices.len == 1
      check "0194a000-9999-7abc-8def-000000000009" in view.notices[0]
      check artifact.artifactId in view.notices[0]
      check "served something other than what the link asked for" in
        view.notices[0]

  test "a payload sealed for the artifact that was asked for says nothing":
    # The check must not fire on the normal case, or it becomes noise and is
    # ignored on the one download where it matters.
    for kind in ArtifactKind:
      checkpoint($kind)
      let artifact = sampleArtifact(kind)
      let view = sharingView(artifact, assReceived,
        sealedForArtifactId = artifact.artifactId)
      check view.notices.len == 0
      let unencrypted = sharingView(artifact, assReceived)
      check unencrypted.notices.len == 0

suite "AS-4 — the surface's own formatting is exact":
  ## Small, pure, and asserted because both of these end up in front of a user
  ## as a fact about their artifact.

  test "a timestamp renders as UTC, and an absent one renders as nothing":
    check formatUnixMsUtc(0) == ""
    check formatUnixMsUtc(-1) == ""
    check formatUnixMsUtc(1'i64) == "1970-01-01 00:00 UTC"
    # 1766000000 s = 20439 whole days + 70400 s, i.e. 19:33:20 UTC.
    check formatUnixMsUtc(1_766_000_000_000'i64) == "2025-12-17 19:33 UTC"
    # A leap day, because the civil-date conversion is the part worth checking.
    check formatUnixMsUtc(1_709_164_800_000'i64) == "2024-02-29 00:00 UTC"

  test "a truncated column never emits half a code point":
    # The summary's separator is `·` and its values can be 40-character commit
    # shas, so a naive byte slice would put half a UTF-8 sequence into a
    # terminal.  Checked over every cut position of a string built to put a
    # multi-byte character at each of them.
    let text = "aaa · bbb · ccc · ddd"
    for budget in 1 .. text.len + 3:
      checkpoint($budget)
      let cut = truncateForColumn(text, budget)
      # Valid UTF-8, always — that is the property.  The ellipsis is itself
      # three bytes, so a truncated result can exceed the byte budget by two;
      # the budget is a column hint, not a hard limit.
      check cut.validateUtf8() == -1
      check cut.len <= max(budget + 2, 4)
    check truncateForColumn("short", 40) == "short"

  test "a size renders in the same units the rest of the client uses":
    check formatByteSize(-1) == ""
    check formatByteSize(0) == "0 B"
    check formatByteSize(1023) == "1023 B"
    check formatByteSize(1024) == "1.0 KiB"
    check formatByteSize(4_194_304) == "4.0 MiB"
    check formatByteSize(536_870_912) == "512 MiB"

  test "an unknown fact is omitted rather than shown empty":
    # A fabricated platform sends a user to download a recording to find out it
    # will not replay (§8 defect 4); a blank one invites the same conclusion.
    let bare = recordingArtifact(
      recordingId = SampleRecordingId, tenantId = SampleTenantId,
      program = "", langName = "", byteSize = -1)
    let view = sharingView(bare, assShared)
    for fact in view.facts:
      checkpoint(fact.label)
      check fact.value.len > 0
    check "Platform" notin renderSharingView(view)

  test "the id is called the same thing whatever the kind":
    # It used to be "Recording ID" on one path and "Artifact ID" on the other,
    # for values in the same namespace.
    for kind in ArtifactKind:
      checkpoint($kind)
      let rendered = renderSharingView(
        sharingView(sampleArtifact(kind), assShared))
      check SharingIdLabel & ": " in rendered
      check "Recording ID" notin rendered

  test "the machine-readable view says the same things as the rendered one":
    for kind in ArtifactKind:
      checkpoint($kind)
      let view = sharingView(sampleArtifact(kind), assShared,
        link = SampleLink, locator = sampleLocator(kind))
      let encoded = sharingViewJson(view)
      check encoded["kind"].getStr == kindSpec(kind).wireToken
      check encoded["artifactId"].getStr == view.artifactId
      check encoded["shareUrl"].getStr == view.link
      check encoded["downloadCommand"].getStr == view.downloadCommand
      check encoded["openCommand"].getStr == view.openCommand
      for line in view.access:
        checkpoint(line.label)
        check encoded["access"][line.label].getStr == line.value
      for fact in view.facts:
        checkpoint(fact.label)
        check encoded["facts"][fact.label].getStr == fact.value
