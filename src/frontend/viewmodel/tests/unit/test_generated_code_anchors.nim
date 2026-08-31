## Headless tests for the Generated Code Listing anchoring model.
##
## NS4 / `GUI/Debugging-Features/Generated-Code-Listing.md` §3.1, §4, §7.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob in
## `ci/lib/test-lane-files.sh` — the subject is a pure module with no host
## reach, so neither lane's rejection list needs to name it. That is
## deliberate: `CONTRIBUTING.md`'s "Code compiled for both backends" entry
## exists because a guard correct under `nim c` crashed the process under
## `nim js`, and `nim js` is the backend the renderer ships on.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_generated_code_anchors.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_generated_code_anchors.nim
##
## ## What this suite is for
##
## §4: "a confidently wrong mapping in this pane sends someone optimising the
## wrong loop." Every case below pins one way of being confidently wrong. The
## two that matter most are the `validate` rejections, because those claims
## are *structurally impossible* rather than merely doubtful — `mfExact` over
## two sources and `mfMerged` over one contradict their own definitions, so
## they can be caught rather than doubted. Each has its own case and its own
## mutation arm.
##
## ## Control arms
##
## Every rejection case is paired with a control: the same call, the same
## shape, one field changed to the legitimate value, asserted CLEAN. Without
## it a rejection would pass for the trivial reason that the path never
## accepts anything.

import std/[strutils, unittest]

import ../../viewmodels/generated_code_anchors

# ---------------------------------------------------------------------------
# Counted assertions.
#
# `counted` is a TEMPLATE, and that is load-bearing: `std/unittest`'s `check`
# only marks a case failed where `testStatusIMPL` is in scope, which is
# inside a `test` body. A template is inlined into that body; a proc is not,
# and every `check` inside a proc would print its message and let the case
# report [OK]. Same reasoning as `noir_providers_test.nim`.
#
# The count exists so the suite's assertion total is a MEASURED number that
# moves when a check is deleted or short-circuited, rather than a number
# claimed in a milestone file and never re-derived.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 176
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const
  Src = "src/main.nr"
  Other = "src/util.nr"

proc region(path: string; startLine, endLine: int): SourceRegion =
  SourceRegion(path: path, startLine: startLine, endLine: endLine)

proc line(path: string; n: int): SourceRegion =
  region(path, n, n)

proc executed(n: int): ExecutedCount =
  ExecutedCount(value: n, provenance: cpExecuted)

proc approximate(n: int): ExecutedCount =
  ExecutedCount(value: n, provenance: cpApproximate)

proc anchor(first, last: int; fidelity: MappingFidelity;
            sources: seq[SourceRegion];
            count: ExecutedCount = ExecutedCount(provenance: cpNone)):
            MappingAnchor =
  MappingAnchor(
    generatedFirst: first,
    generatedLast: last,
    fidelity: fidelity,
    sources: sources,
    count: count)

proc richArtefact(): ArtefactSupport =
  ## An artefact carrying everything: resolved positions, regions, inlining
  ## records, and synthetic-instruction marks. Ceiling `mfExact`.
  ArtefactSupport(
    hasSourcePositions: true,
    hasSourceRegions: true,
    hasInliningRecords: true,
    marksCompilerGenerated: true)

proc regionsOnlyArtefact(): ArtefactSupport =
  ## Statement spans, no resolved positions. Ceiling `mfCoarse`. This is the
  ## Aztec case: real source, and no resolved position to assert.
  ArtefactSupport(
    hasSourcePositions: false,
    hasSourceRegions: true,
    hasInliningRecords: false,
    marksCompilerGenerated: false)

proc barrenArtefact(): ArtefactSupport =
  ## Debug info absent or discarded. Ceiling `mfUnmapped`.
  ArtefactSupport()

proc goodListing(): seq[MappingAnchor] =
  ## The §3 mock, as anchors: a `check` function whose two source lines each
  ## produced one instruction, with a compiler-generated prologue above them
  ## and an unmapped tail below.
  @[
    anchor(0, 0, mfCompilerGenerated, @[]),
    anchor(1, 1, mfExact, @[line(Src, 2)], executed(1024)),
    anchor(2, 4, mfCoarse, @[region(Src, 3, 3)], executed(1024)),
    anchor(5, 5, mfUnmapped, @[]),
  ]

# ---------------------------------------------------------------------------

suite "generated code listing anchors (NS4)":

  test "the_fidelity_ladder_has_five_rungs_ordered_by_claim_strength":
    # §4's table is five rows. The ordinal order is the module's contract:
    # `claimCeiling` is a `<=` over it, so a reordering here silently
    # changes what is claimable.
    counted ord(low(MappingFidelity)) == 0
    counted ord(high(MappingFidelity)) == 4
    counted ord(mfUnmapped) < ord(mfCompilerGenerated)
    counted ord(mfCompilerGenerated) < ord(mfMerged)
    counted ord(mfMerged) < ord(mfCoarse)
    counted ord(mfCoarse) < ord(mfExact)

    # The words §4's table uses, so the badge cannot drift from the spec.
    counted label(mfExact) == "exact"
    counted label(mfCoarse) == "coarse"
    counted label(mfMerged) == "merged"
    counted label(mfCompilerGenerated) == "compiler-generated"
    counted label(mfUnmapped) == "unmapped"

    # Only three rungs attribute generated code to user source. The other
    # two are what suspends synchronisation, so this partition is what §4's
    # last row rests on.
    counted claimsUserSource(mfExact)
    counted claimsUserSource(mfCoarse)
    counted claimsUserSource(mfMerged)
    counted not claimsUserSource(mfCompilerGenerated)
    counted not claimsUserSource(mfUnmapped)

  test "exact_over_two_sources_is_rejected_as_structurally_impossible":
    # THE TRAP: a producer that found two contributing positions and labelled
    # the result `exact`. The pane would then pick one and present it as THE
    # source line — a confident answer that is sometimes wrong, and there is
    # no way for a reader to tell which time.
    let bad = @[anchor(0, 0, mfExact, @[line(Src, 2), line(Other, 9)])]
    let defects = validate(bad, richArtefact())

    counted defects.len == 1
    counted defects[0].kind == adkExactOverManySources
    counted defects[0].anchorIndex == 0
    counted "2 sources" in defects[0].message
    # The message names the rung it SHOULD have been, so the producer author
    # is told the fix and not merely that something is wrong.
    counted "merged" in defects[0].message

    # Zero sources is the same defect: `exact` means exactly one.
    let none = @[anchor(0, 0, mfExact, @[])]
    let noneDefects = validate(none, richArtefact())
    counted noneDefects.len == 1
    counted noneDefects[0].kind == adkExactOverManySources

    # CONTROL ARM: the identical anchor with ONE source. It must validate
    # clean — otherwise the rejection above would pass because this path
    # never accepts an exact mapping at all.
    let good = @[anchor(0, 0, mfExact, @[line(Src, 2)])]
    counted validate(good, richArtefact()).len == 0

  test "merged_over_one_source_is_rejected_as_structurally_impossible":
    # THE TRAP, and it is the mirror image: a producer labelling a mapping
    # `merged` when it has one source. §4's presentation rule for merged is
    # "all contributing sources shown, none claimed as *the* source" — so
    # this SUPPRESSES a claim the producer was entitled to make. The pane
    # shows a hedge over a mapping that was exact, which teaches the reader
    # to distrust the hedge everywhere else.
    let bad = @[anchor(0, 3, mfMerged, @[line(Src, 2)])]
    let defects = validate(bad, richArtefact())

    counted defects.len == 1
    counted defects[0].kind == adkMergedUnderTwoSources
    counted defects[0].anchorIndex == 0
    counted "1 sources" in defects[0].message
    counted "exact" in defects[0].message

    # Zero sources is the same defect.
    let none = @[anchor(0, 3, mfMerged, @[])]
    let noneDefects = validate(none, richArtefact())
    counted noneDefects.len == 1
    counted noneDefects[0].kind == adkMergedUnderTwoSources

    # CONTROL ARM: the identical anchor with TWO sources — a genuine merge.
    let good = @[anchor(0, 3, mfMerged, @[line(Src, 2), line(Other, 9)])]
    counted validate(good, richArtefact()).len == 0

    # And three, so the rule is "at least two" and not "exactly two".
    let three = @[anchor(0, 3, mfMerged,
      @[line(Src, 2), line(Other, 9), line(Other, 14)])]
    counted validate(three, richArtefact()).len == 0

  test "the_two_rungs_that_claim_no_source_may_not_carry_one":
    # §4: compiler-generated is "labelled as such, NEVER attributed to a
    # nearby line", and unmapped means the debug info is absent — so there
    # is nothing to attribute. An anchor carrying a source under either
    # label is a nearby line smuggled in behind an honest word.
    let unmapped = @[anchor(0, 0, mfUnmapped, @[line(Src, 2)])]
    let unmappedDefects = validate(unmapped, richArtefact())
    counted unmappedDefects.len == 1
    counted unmappedDefects[0].kind == adkUnmappedClaimsSource

    let synthetic = @[anchor(0, 0, mfCompilerGenerated, @[line(Src, 2)])]
    let syntheticDefects = validate(synthetic, richArtefact())
    counted syntheticDefects.len == 1
    counted syntheticDefects[0].kind == adkCompilerGeneratedClaimsSource
    counted "never be attributed" in syntheticDefects[0].message

    # CONTROL ARM: both rungs with no sources, which is their correct shape.
    let clean = @[
      anchor(0, 0, mfUnmapped, @[]),
      anchor(1, 1, mfCompilerGenerated, @[]),
    ]
    counted validate(clean, richArtefact()).len == 0

  test "a_rung_is_not_claimable_beyond_what_the_artefact_supports":
    # The Aztec precedent: that campaign declared rung 3 and refused to
    # assert resolved source positions, because the artefact did not carry
    # them. Same rule here, and it is why this module hard-codes no rung for
    # any language — Noir included. A `noirArtefactSupport` constant would
    # be the confident-but-sometimes-wrong shape the pane exists to avoid.
    counted claimCeiling(richArtefact()) == mfExact
    counted claimCeiling(regionsOnlyArtefact()) == mfCoarse
    counted claimCeiling(barrenArtefact()) == mfUnmapped

    let inliningOnly = ArtefactSupport(hasInliningRecords: true)
    counted claimCeiling(inliningOnly) == mfMerged

    # An artefact with statement spans and no resolved positions cannot
    # support `exact`, however good the language's debug story is in
    # principle.
    let overclaim = @[anchor(0, 0, mfExact, @[line(Src, 2)])]
    let defects = validate(overclaim, regionsOnlyArtefact())
    counted defects.len == 1
    counted defects[0].kind == adkFidelityAboveArtefactCeiling
    counted "at most coarse" in defects[0].message
    counted "claims exact" in defects[0].message

    # CONTROL ARM: the same anchor at the rung the artefact DOES support.
    let atCeiling = @[anchor(0, 0, mfCoarse, @[region(Src, 2, 4)])]
    counted validate(atCeiling, regionsOnlyArtefact()).len == 0

    # And the same anchor against the richer artefact, unchanged. The
    # rejection above is about the artefact, not about the anchor.
    counted validate(overclaim, richArtefact()).len == 0

  test "compiler_generated_needs_its_own_evidence_not_a_high_ceiling":
    # `mfCompilerGenerated` is off the ordinal ceiling axis on purpose: it is
    # not a weaker `mfMerged`, it is the positive claim "there is no user
    # source here", and an artefact that does not mark synthetic
    # instructions cannot support it. Without this, an artefact with rich
    # positions would license the label by ordinal accident.
    let claim = @[anchor(0, 0, mfCompilerGenerated, @[])]

    let unmarked = ArtefactSupport(
      hasSourcePositions: true,
      hasSourceRegions: true,
      hasInliningRecords: true,
      marksCompilerGenerated: false)
    counted claimCeiling(unmarked) == mfExact
    let defects = validate(claim, unmarked)
    counted defects.len == 1
    counted defects[0].kind == adkFidelityAboveArtefactCeiling
    counted "does not mark compiler-generated" in defects[0].message

    # CONTROL ARM: the same claim over an artefact that DOES mark them —
    # note the ceiling is unchanged at `mfExact` in both, so the difference
    # is the mark and nothing else.
    counted validate(claim, richArtefact()).len == 0

  test "every_row_inside_one_anchor_gets_the_same_answer":
    # §3.1's core rule. A five-row anchor over a three-line region must NOT
    # hand row 2 a source line two-fifths of the way down: there is no
    # evidence for that line, and it is "plausibly wrong in the worst
    # cases", which is the failure mode §3.1 names by name.
    let anchors = @[
      anchor(0, 4, mfCoarse, @[region(Src, 10, 12)]),
      anchor(5, 9, mfCoarse, @[region(Src, 20, 22)]),
    ]

    var seen: seq[int] = @[]
    for row in 0 .. 4:
      let d = syncFromGenerated(anchors, row)
      counted d.outcome == soAligned
      seen.add d.anchorIndex
    counted seen == @[0, 0, 0, 0, 0]

    # The counterpart is the anchor's WHOLE region, identical for every row.
    for row in 0 .. 4:
      let d = syncFromGenerated(anchors, row)
      counted counterpartSources(anchors, d) == @[region(Src, 10, 12)]
      counted counterpartRows(anchors, d) == (0, 4)

    # CONTROL ARM: rows in the OTHER anchor give a different answer. Without
    # this, "every row gives the same answer" would also be satisfied by a
    # function that ignored its argument entirely.
    let second = syncFromGenerated(anchors, 7)
    counted second.outcome == soAligned
    counted second.anchorIndex == 1
    counted counterpartSources(anchors, second) == @[region(Src, 20, 22)]
    counted counterpartRows(anchors, second) == (5, 9)

  test "a_gap_between_anchors_suspends_rather_than_snapping_to_the_nearest":
    # §3.1 sends the no-anchor case to §4, and §4 says the panes stop
    # pretending. A row one past the end of an anchor is exactly where
    # "nearest anchor" would quietly produce a wrong-but-plausible answer.
    let anchors = @[
      anchor(0, 2, mfExact, @[line(Src, 10)]),
      anchor(8, 10, mfExact, @[line(Src, 20)]),
    ]

    for row in [3, 5, 7, 11, 400]:
      let d = syncFromGenerated(anchors, row)
      counted d.outcome == soSuspended
      counted d.anchorIndex == NoAnchor
      # "and say so": a suspension the user cannot see is drift.
      counted d.reason.len > 0
      counted "interpolated" in d.reason
      counted counterpartSources(anchors, d).len == 0
      counted counterpartRows(anchors, d) == (NoAnchor, NoAnchor)

    # Row 3 is adjacent to anchor 0 and row 7 is adjacent to anchor 1; both
    # suspend. Proximity is not evidence.
    counted syncFromGenerated(anchors, 3).anchorIndex == NoAnchor
    counted syncFromGenerated(anchors, 7).anchorIndex == NoAnchor

    # CONTROL ARM: the rows that ARE covered align, so the suspension above
    # is about the gap and not about the function refusing everything.
    counted syncFromGenerated(anchors, 2).outcome == soAligned
    counted syncFromGenerated(anchors, 2).anchorIndex == 0
    counted syncFromGenerated(anchors, 8).outcome == soAligned
    counted syncFromGenerated(anchors, 8).anchorIndex == 1

  test "unmapped_and_compiler_generated_regions_suspend_and_say_which":
    # §4's last row, and the deliverable "Unmapped regions suspend
    # synchronisation and say so rather than drifting".
    let anchors = goodListing()

    let synthetic = syncFromGenerated(anchors, 0)
    counted synthetic.outcome == soSuspended
    counted "compiler-generated" in synthetic.reason
    counted "suspended" in synthetic.reason

    let unmapped = syncFromGenerated(anchors, 5)
    counted unmapped.outcome == soSuspended
    counted "unmapped" in unmapped.reason
    counted "suspended" in unmapped.reason

    # The two reasons are DIFFERENT. "There is no user source here" and "we
    # have no information here" are different things to show a developer,
    # and collapsing them loses the more useful of the two.
    counted synthetic.reason != unmapped.reason

    # CONTROL ARM: the mapped rows of the same listing align.
    counted syncFromGenerated(anchors, 1).outcome == soAligned
    counted syncFromGenerated(anchors, 3).outcome == soAligned

  test "source_to_generated_follows_the_same_rule_in_the_other_direction":
    # §3's table is bidirectional, and the deliverable says "in both
    # directions". A source line with no anchor over it must suspend rather
    # than scrolling the listing somewhere plausible.
    let anchors = @[
      anchor(0, 0, mfCompilerGenerated, @[]),
      anchor(1, 3, mfExact, @[line(Src, 2)]),
      anchor(4, 6, mfMerged, @[line(Src, 3), line(Other, 9)]),
    ]

    let exact = syncFromSource(anchors, Src, 2)
    counted exact.outcome == soAligned
    counted exact.anchorIndex == 1
    counted counterpartRows(anchors, exact) == (1, 3)

    # A merge is reachable from EITHER contributing source, and both land on
    # the same anchor — §4: none is *the* source.
    let viaSrc = syncFromSource(anchors, Src, 3)
    let viaOther = syncFromSource(anchors, Other, 9)
    counted viaSrc.outcome == soAligned
    counted viaOther.outcome == soAligned
    counted viaSrc.anchorIndex == viaOther.anchorIndex
    counted counterpartSources(anchors, viaSrc).len == 2

    # An unanchored line suspends, and a line in a DIFFERENT file at the
    # same number does not borrow the first file's anchor.
    let gap = syncFromSource(anchors, Src, 99)
    counted gap.outcome == soSuspended
    counted gap.anchorIndex == NoAnchor
    counted "no anchor" in gap.reason

    let wrongFile = syncFromSource(anchors, Other, 2)
    counted wrongFile.outcome == soSuspended
    counted wrongFile.anchorIndex == NoAnchor

  test "counts_carry_their_provenance_and_approximate_says_so":
    # §2's argument is executed counts rather than static ones; §7 requires
    # an inverted count be LABELLED approximate. The trap is a pane that
    # renders both as `×1024`, which turns "a fact about the run" into a
    # number the reader cannot grade.
    counted countLabel(executed(1024)) == "×1024"
    counted countLabel(approximate(1024)) == "≈×1024"
    counted countLabel(executed(1024)) != countLabel(approximate(1024))
    counted isApproximate(approximate(1024))
    counted not isApproximate(executed(1024))

    # No count at all renders nothing — not `×0`, which reads as "never
    # ran" over an anchor whose count is simply unavailable.
    counted countLabel(ExecutedCount(provenance: cpNone)) == ""
    counted not isApproximate(ExecutedCount(provenance: cpNone))

    # A number on screen with no provenance is the defect: it cannot say
    # whether it was measured or inferred.
    let unprovenanced = @[anchor(0, 0, mfExact, @[line(Src, 2)],
      ExecutedCount(value: 1024, provenance: cpNone))]
    let defects = validate(unprovenanced, richArtefact())
    counted defects.len == 1
    counted defects[0].kind == adkCountWithoutProvenance
    counted "measured or inferred" in defects[0].message

    # CONTROL ARM: the same anchor with each real provenance, both clean.
    counted validate(
      @[anchor(0, 0, mfExact, @[line(Src, 2)], executed(1024))],
      richArtefact()).len == 0
    counted validate(
      @[anchor(0, 0, mfExact, @[line(Src, 2)], approximate(1024))],
      richArtefact()).len == 0
    # And a genuine zero with a provenance is not a defect: "ran zero times"
    # is a real measurement and the pane should be able to say it.
    counted validate(
      @[anchor(0, 0, mfExact, @[line(Src, 2)], executed(0))],
      richArtefact()).len == 0

  test "synchronisation_is_a_toggle_defaulting_on":
    # §3: "a toggle, defaulting to on, and unlocking is a deliberate act with
    # a visible state."
    counted DefaultSyncSettings.enabled

    let anchors = goodListing()
    let off = SyncSettings(enabled: false)

    let d = syncFromGenerated(anchors, 1, off)
    counted d.outcome == soDisabled
    counted d.anchorIndex == NoAnchor
    counted d.reason.len > 0

    let s = syncFromSource(anchors, Src, 2, off)
    counted s.outcome == soDisabled

    # `soDisabled` is NOT `soSuspended`. "You turned it off" and "the mapping
    # ran out here" are different states with different remedies, and a pane
    # that showed one badge for both would teach the user to ignore it.
    counted soDisabled != soSuspended
    counted syncFromGenerated(anchors, 5, off).outcome == soDisabled
    counted syncFromGenerated(anchors, 5).outcome == soSuspended

    # CONTROL ARM: the default settings, same anchors, same row — aligned.
    counted syncFromGenerated(anchors, 1).outcome == soAligned
    counted syncFromGenerated(anchors, 1, DefaultSyncSettings).outcome ==
      soAligned

  test "an_anchor_covering_no_row_is_a_defect_not_a_silent_gap":
    # An inverted range matches nothing, so every lookup over it becomes a
    # gap and the pane quietly reports "no mapping" for code that HAS one.
    # That failure is invisible, which is the kind §4 says this pane must
    # not have.
    let bad = @[anchor(5, 2, mfExact, @[line(Src, 2)])]
    let defects = validate(bad, richArtefact())
    counted defects.len == 1
    counted defects[0].kind == adkEmptyGeneratedRange
    counted "covers no generated row" in defects[0].message

    # It really does swallow lookups, which is why it must be caught here.
    for row in [2, 3, 4, 5]:
      counted syncFromGenerated(bad, row).outcome == soSuspended

    # CONTROL ARM: a single-row anchor (`first == last`) is legal and does
    # cover its row. The rule is "last < first", not "last <= first".
    let single = @[anchor(5, 5, mfExact, @[line(Src, 2)])]
    counted validate(single, richArtefact()).len == 0
    counted syncFromGenerated(single, 5).outcome == soAligned

  test "a_well_formed_listing_produces_no_defects_and_reports_all_of_a_bad_one":
    # OVERALL CONTROL ARM: the §3 mock as anchors, validated clean. If this
    # reddened, every rejection case above would be passing vacuously.
    let good = goodListing()
    counted validate(good, richArtefact()).len == 0
    counted good.len == 4

    # `validate` returns EVERY defect, not the first, so a producer's test
    # sees its whole delta in one run rather than one defect per fix cycle.
    let bad = @[
      anchor(0, 0, mfExact, @[line(Src, 2), line(Other, 9)]),
      anchor(1, 1, mfMerged, @[line(Src, 3)]),
      anchor(5, 2, mfCoarse, @[region(Src, 4, 6)]),
    ]
    let defects = validate(bad, richArtefact())
    counted defects.len == 3
    # In anchor order, one defect each — not three reports of the first.
    counted kinds(defects) == @[
      adkExactOverManySources,
      adkMergedUnderTwoSources,
      adkEmptyGeneratedRange,
    ]

    # Each defect names WHICH anchor, so a listing with hundreds of them is
    # actionable.
    counted defects[0].anchorIndex == 0
    counted defects[1].anchorIndex == 1
    counted defects[2].anchorIndex == 2

    let text = describe(defects)
    counted "anchor 0" in text
    counted "anchor 1" in text
    counted "anchor 2" in text
    counted text.splitLines().len == 3

    # An empty listing is not a defect — a language with no producer simply
    # has no pane (§5), and that must not surface as an error.
    counted validate(@[], richArtefact()).len == 0
    counted validate(@[], barrenArtefact()).len == 0

  test "generated_code_anchors_assertion_count_is_measured":
    # The count is asserted so that deleting or short-circuiting a check
    # above cannot pass silently: it has to move this number in the same
    # commit. This case's own two checks are not counted, which is why the
    # comparison is against the value after every preceding case has run.
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
