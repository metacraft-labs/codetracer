## THE OPERATION: on demand, anchored to the cursor, following the active tab.
##
## `GUI/Debugging-Features/Generated-Code-Listing.md` §1, §2 (GCL-D10),
## §3.1 (GCL-D11), §6 (GCL-D14, GCL-D15, GCL-D16), §7, §8 (GCL-D17),
## §9 (GCL-D18), §14.2 (GCL-D23).
##
## LANE: `vm-unit` AND `vm-unit-js`, by the directory glob in
## `ci/lib/test-lane-files.sh`. Nothing here reaches the host or `std/os`.
##
## Compile and run:
##   nim c  -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_generated_code_operation.nim
##   nim js -r -d:nodejs --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_generated_code_operation.nim
##
## ## WHY THIS SUITE EXISTS WHEN `test_noir_generated_listing` IS GREEN
##
## That suite proves the PRODUCER reads a real `nargo compile` artefact and
## that the MODEL refuses claims the artefact cannot support. Both were true
## before this commit, and neither had a production caller: `setAnchors`,
## `syncFromSource`, `syncFromGenerated` and `produceAnchors` were reached only
## from their own suites. A capability nothing reaches has a user-visible face,
## and it is always the same one — a feature that looks present and does
## nothing.
##
## So this suite asserts the three properties the model cannot have on its own,
## each of which has a plausible implementation that gets it wrong:
##
##   1. **On demand.** The failure is a listing recomputed on every cursor
##      move, beside panes that have already caused re-render storms. The
##      assertion is not "we only call it when needed" — that is not
##      checkable — it is that `revision`, which counts ROW REPLACEMENTS,
##      does not move while the cursor does, paired with the twin that shows
##      the cursor really did move. A VM that ignored the cursor entirely
##      satisfies the first clause alone.
##
##   2. **Cursor-anchored, visibly.** The failure is a surface with two
##      states — an answer and nothing — where a broken query and a correct
##      empty one look the same (GCL-D12). So *aligned*, *suspended* and
##      *off* are asserted to render three DIFFERENT texts, and the aligned
##      one is asserted to name BOTH ENDS: a row range with no source line
##      beside it leaves the reader inferring the link.
##
##   3. **Synced tabs.** The failure is a VM reading an ambient "current
##      line": Monaco fires cursor events for models that are not on screen,
##      so a listing would follow a tab nobody is looking at. Both arms are
##      asserted, because taking every event and taking none each satisfy one.
##
## ## THE FIXTURE, AND WHY ITS SHAPE IS PART OF THE ASSERTION
##
## `TwoInstantiations` has a source line — `Main:9` — that produces TWO
## disjoint anchors. That is not decoration: GCL-A15's fixture requirement is
## part of the assertion, because a control specified but only ever exercised
## at `1 of 1` is a control nobody has seen work, and every count-based check
## about a picker passes over a one-element set. `syncFromSource` returns the
## FIRST match by construction, so a surface built on it alone reports one
## where there are two — which is precisely why `anchorsFromSource` exists and
## why the count is read from it rather than from the focused anchor.

import std/[strutils, unittest]

import isonim/core/[signals, computation]

import ../../viewmodels/generated_code_anchors
import ../../viewmodels/generated_code_operation
import ../../viewmodels/generated_code_vm
import ../../viewmodels/edit_mode_toolbar

# ---------------------------------------------------------------------------
# Counted assertions. `counted` is a TEMPLATE for the reason
# `test_noir_generated_listing.nim` records: `std/unittest`'s `check` only
# marks a case failed where `testStatusIMPL` is in scope, which is inside a
# `test` body. A proc would print and pass.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 248
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it — a count edited DOWN to match a short run is a
  ## failed assertion whose identity has been erased.
  ##
  ## WHY IT IS NOT THE NUMBER OF `counted` LINES. Three cases assert inside a
  ## loop over the DECLARED LADDER — every target's id is unique and resolves
  ## back to itself, every declared extension selects a ladder, no two of a
  ## language's commands share a label — so the total is a function of the
  ## ladder's contents. Nine targets across six languages is what produces it,
  ## and `seen.len == 9` in that same case is what pins the multiplier, so a
  ## rung added without updating this number reddens here AND names itself
  ## there. It is deliberately NOT a loop over `SourceLanguage`'s 34 members:
  ## adding an unrelated language must not move this count.
  ##
  ## IT WAS 249 AND IS 248, AND THE DIFFERENCE IS ACCOUNTED FOR RATHER THAN
  ## ABSORBED. This suite's first green run measured 249. Two cases then
  ## changed for the reason recorded in `generated_code_operation.nim`'s
  ## header — `keybindingTarget` was deleted because no key is bound to it,
  ## and the ladder cases were rewritten to address `targetsForPath` instead
  ## of the two internals:
  ##
  ##   −5  `gcl_d11_the_keybinding_resolves_to_the_first_target_…` deleted
  ##   +4  `every_language_with_a_ladder_is_reachable_from_some_path` (6)
  ##       became `every_declared_extension_selects_a_ladder` (10)
  ##   ───
  ##   −1  249 → 248
  ##
  ## A count that moves down and cannot be decomposed like this is a failed
  ## assertion whose identity is unknown, and lowering the constant is how it
  ## gets buried.

const
  MainPath = "src/main.nr"
  OtherPath = "src/utils.nr"

proc region(path: string; line: int): SourceRegion =
  SourceRegion(path: path, startLine: line, endLine: line)

proc exact(first, last: int; path: string; line: int): MappingAnchor =
  MappingAnchor(generatedFirst: first, generatedLast: last,
    fidelity: mfExact, sources: @[region(path, line)],
    count: ExecutedCount(value: 0, provenance: cpNone))

proc unmapped(first, last: int): MappingAnchor =
  MappingAnchor(generatedFirst: first, generatedLast: last,
    fidelity: mfUnmapped, sources: @[],
    count: ExecutedCount(value: 0, provenance: cpNone))

const ExactOnlySupport = ArtefactSupport(
  hasSourcePositions: true, hasSourceRegions: true,
  hasInliningRecords: true, marksCompilerGenerated: false)
  ## `marksCompilerGenerated: false` is the Noir artefact's real ceiling
  ## (§5.1): Noir does not distinguish a synthetic opcode from one whose debug
  ## information was dropped, so `Unmapped` is the honest answer where another
  ## language would say `Compiler-generated`.

proc row(i: int; text: string; annotation = ""): GeneratedRow =
  GeneratedRow(index: i, text: text, annotation: annotation)

proc acirTarget(): GeneratedCodeTarget =
  var t: GeneratedCodeTarget
  doAssert targetById("noir.acir", t)
  t

proc listingFixture(): GeneratedListing =
  ## Rows 0–3 belong to `Main:8`. Rows 4–6 and 9–10 BOTH belong to `Main:9` —
  ## two instantiations of one source line, which is the case GCL-A15 requires
  ## a fixture to contain. Rows 7–8 are unmapped, so a cursor over them has a
  ## correct empty answer rather than a nearest-neighbour guess.
  GeneratedListing(
    targetId: "noir.acir",
    sourcePath: MainPath,
    producer: acirTarget().producer,
    rows: @[
      row(0, "RANGE x, 100"), row(1, "MUL x, 2"), row(2, "ADD t0, 1"),
      row(3, "ASSERT t1"), row(4, "CALL f"),
      row(5, "RANGE y, 8", "y must fit in 8 bits"),
      row(6, "RET"), row(7, "NOP"), row(8, "NOP"),
      row(9, "CALL f"), row(10, "RET"),
    ],
    anchors: @[
      exact(0, 3, MainPath, 8),
      exact(4, 6, MainPath, 9),
      unmapped(7, 8),
      exact(9, 10, MainPath, 9),
    ],
    support: ExactOnlySupport,
    listingAbsence: "")

# ===========================================================================
suite "GCL: the operation is on demand — nothing is computed until it is asked":

  test "a fresh vm holds no listing, no anchors and no cursor":
    let vm = createGeneratedCodeVM()
    counted vm.state.val == lsClosed
    counted not vm.isOpen.val
    counted vm.rows.val.len == 0
    counted vm.anchors.val.len == 0
    counted vm.revision.val == 0
    counted vm.cursorLine.val == 0
    counted vm.listingPath.val.len == 0
    counted vm.tabTitle.val.len == 0
    counted vm.producerLine.val.len == 0

  test "gcl_on_demand_a_closed_vm_takes_no_cursor_move_and_an_open_one_does":
    # TWO ARMS. A VM that ignored every cursor move satisfies the first alone
    # and is exactly the "feature that looks present and does nothing" this
    # campaign keeps finding; a VM that took them while closed would be
    # accumulating state for a surface nobody opened.
    let vm = createGeneratedCodeVM()

    var taken = 0
    for line in 1 .. 50:
      if vm.noteCursorMoved(MainPath, line):
        inc taken
    counted taken == 0
    counted vm.cursorLine.val == 0
    counted vm.revision.val == 0
    counted vm.rows.val.len == 0

    # The positive twin, through the same path.
    vm.openListing(listingFixture(), 8)
    counted vm.noteCursorMoved(MainPath, 9)
    counted vm.cursorLine.val == 9

  test "gcl_on_demand_cursor_moves_re_anchor_and_never_replace_rows":
    # THE RE-RENDER STORM ASSERTION. `revision` counts row replacements. A
    # hundred cursor moves must not move it — and the second clause is what
    # stops a VM that simply never re-anchors from passing: the focused rows
    # must actually have changed.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    let revisionAfterOpen = vm.revision.val
    counted revisionAfterOpen == 1
    let focusAt8 = vm.focusRows.val
    counted focusAt8 == (0, 3)

    for i in 0 ..< 50:
      discard vm.noteCursorMoved(MainPath, if i mod 2 == 0: 9 else: 8)

    counted vm.revision.val == revisionAfterOpen
    counted vm.rows.val.len == 11

    discard vm.noteCursorMoved(MainPath, 9)
    counted vm.focusRows.val == (4, 6)
    counted vm.focusRows.val != focusAt8

  test "gcl_on_demand_a_repeated_cursor_line_is_not_taken_twice":
    # `onDidChangeCursorPosition` fires for COLUMN moves too, and this surface
    # is line-granular. Without the guard every horizontal keystroke rewrites
    # a signal with the value it already had and re-runs every memo.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.noteCursorMoved(MainPath, 9)
    counted not vm.noteCursorMoved(MainPath, 9)
    counted not vm.noteCursorMoved(MainPath, 9)

  test "gcl_d7_reopening_the_same_target_reuses_the_listing_and_repositions":
    # §7: "re-invoking the same target for the same file reuses its tab and
    # re-positions it, rather than opening a second one." `revision` is what
    # says which happened, and the second clause — that the position DID
    # move — is what stops a no-op from passing.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.revision.val == 1
    counted vm.focusRows.val == (0, 3)

    vm.openListing(listingFixture(), 9)
    counted vm.revision.val == 1
    counted vm.focusRows.val == (4, 6)

    # A DIFFERENT file is a different listing, and does rebuild.
    var other = listingFixture()
    other.sourcePath = OtherPath
    other.anchors = @[exact(0, 1, OtherPath, 3)]
    vm.openListing(other, 3)
    counted vm.revision.val == 2

  test "gcl_on_demand_closing_returns_the_vm_to_holding_nothing":
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 9)
    counted vm.isOpen.val
    vm.closeListing()
    counted not vm.isOpen.val
    counted vm.rows.val.len == 0
    counted vm.anchors.val.len == 0
    counted vm.cursorLine.val == 0
    # And it is closed for the purpose that matters: it takes no cursor again.
    counted not vm.noteCursorMoved(MainPath, 9)

# ===========================================================================
suite "GCL: the cursor leads, and the correspondence is visible (GCL-D12)":

  test "gcl_a13_a_mapped_line_names_both_ends_of_the_correspondence":
    # A row range with no source line beside it leaves the reader inferring
    # the link from two numbers that happened to move together.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.focus.val.outcome == soAligned
    counted vm.focusRows.val == (0, 3)
    let text = vm.focusText.val
    counted text.len > 0
    counted MainPath in text
    counted ":8" in text
    counted "0" in text and "3" in text

  test "gcl_a13_an_unmapped_line_moves_nothing_and_states_a_reason":
    # BOTH CLAUSES. An implementation that does nothing satisfies the first
    # alone, and is indistinguishable from a broken query.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    let before = vm.focusRows.val
    counted before == (0, 3)

    discard vm.noteCursorMoved(MainPath, 400)
    counted vm.focus.val.outcome == soSuspended
    counted vm.focusRows.val == (NoAnchor, NoAnchor)
    counted vm.focus.val.reason.len > 0
    counted vm.focusText.val.len > 0
    # The listing itself is untouched — the rows still describe a real compile.
    counted vm.rows.val.len == 11
    counted vm.revision.val == 1

  test "gcl_a8_aligned_suspended_and_off_render_three_different_texts":
    # THREE-WAY, because rendering *off* and *suspended* the same way makes
    # "you turned it off" indistinguishable from "the mapping ran out" — which
    # is precisely the distinction the model went to the trouble of encoding.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    let alignedText = vm.focusText.val
    counted vm.focus.val.outcome == soAligned

    discard vm.noteCursorMoved(MainPath, 400)
    let suspendedText = vm.focusText.val
    counted vm.focus.val.outcome == soSuspended

    vm.setSyncEnabled(false)
    let offText = vm.focusText.val
    counted vm.focus.val.outcome == soDisabled

    counted alignedText != suspendedText
    counted suspendedText != offText
    counted alignedText != offText
    counted offText.len > 0

    # And *off* survives a cursor that WOULD have aligned: a suspension
    # reported while the toggle is off would say the mapping ran out when
    # nothing was asked of it.
    discard vm.noteCursorMoved(MainPath, 8)
    counted vm.focus.val.outcome == soDisabled
    vm.setSyncEnabled(true)
    counted vm.focus.val.outcome == soAligned

  test "gcl_d29_the_instantiation_count_is_stated_at_zero_one_and_many":
    # The fixture requirement IS the assertion (GCL-A15): `Main:9` produces
    # two disjoint anchors, and `syncFromSource` returns the first by
    # construction. A count read from the focused anchor would say 1 here and
    # the reader could never tell.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.instantiationCount.val == 1

    discard vm.noteCursorMoved(MainPath, 9)
    counted vm.instantiationCount.val == 2
    counted "2 instantiations" in vm.focusText.val

    discard vm.noteCursorMoved(MainPath, 400)
    counted vm.instantiationCount.val == 0

    # The singular is spelled as a singular — a count that reads
    # "1 instantiations" is a count nobody trusts.
    discard vm.noteCursorMoved(MainPath, 8)
    counted "1 instantiation" in vm.focusText.val
    counted "1 instantiations" notin vm.focusText.val

  test "anchors_from_source_returns_every_range_not_the_first":
    # The model-level twin of the case above, asserted directly, because the
    # VM could satisfy the count by any means and this is the query §13.1's
    # second requirement is about.
    let anchors = listingFixture().anchors
    counted anchorsFromSource(anchors, MainPath, 9) == @[1, 3]
    counted anchorsFromSource(anchors, MainPath, 8) == @[0]
    counted anchorsFromSource(anchors, MainPath, 400).len == 0
    # An unmapped anchor names no source and is never one of the places a
    # line became.
    counted 2 notin anchorsFromSource(anchors, MainPath, 9)
    # And the single-valued query really does drop one, which is why the
    # sequence-valued one had to exist.
    let one = syncFromSource(anchors, MainPath, 9)
    counted one.outcome == soAligned
    counted counterpartRows(anchors, one) == (4, 6)

  test "gcl_d23_the_surface_names_the_producer_that_painted_it":
    # A row count cannot discriminate two producers that agree on every
    # number, so the NAME is the only thing that identifies which route
    # painted what the reader is looking at.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.producerLine.val.len > 0
    counted acirTarget().producer in vm.producerLine.val
    vm.closeListing()
    counted vm.producerLine.val.len == 0

  test "gcl_14_3_a_compiler_annotation_survives_into_the_row":
    # §14.3: it is the single most valuable thing the compiler's own output
    # adds over a bare opcode dump, and a renderer that splits a row into
    # fields must have a field for it.
    let listing = listingFixture()
    counted listing.rows[5].annotation == "y must fit in 8 bits"
    counted listing.rows[4].annotation.len == 0

# ===========================================================================
suite "GCL: the listing follows the ACTIVE source tab":

  test "gcl_tabs_a_cursor_move_in_a_background_tab_is_refused":
    # BOTH ARMS. Monaco fires cursor events for models that are not on screen;
    # taking every event and taking none each satisfy one clause.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.activeTabPath.val == MainPath

    counted not vm.noteCursorMoved(OtherPath, 42)
    counted vm.cursorLine.val == 8
    counted vm.focusRows.val == (0, 3)

    counted vm.noteCursorMoved(MainPath, 9)
    counted vm.cursorLine.val == 9

  test "gcl_tabs_switching_to_another_file_suspends_and_names_both":
    # It does NOT keep projecting the old file's anchors against the new
    # file's cursor, which would produce a plausible row range meaning nothing.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.describesActiveTab.val

    discard vm.noteActiveTabChanged(OtherPath, 3)
    counted not vm.describesActiveTab.val
    counted vm.focus.val.outcome == soSuspended
    counted vm.focusRows.val == (NoAnchor, NoAnchor)
    let text = vm.focusText.val
    counted MainPath in text
    counted OtherPath in text
    # The rows are still there: the listing describes a real compilation.
    counted vm.rows.val.len == 11
    counted vm.revision.val == 1

    # Switching back re-aligns, at the position the tab carries.
    discard vm.noteActiveTabChanged(MainPath, 9)
    counted vm.describesActiveTab.val
    counted vm.focus.val.outcome == soAligned
    counted vm.focusRows.val == (4, 6)
    counted vm.revision.val == 1

  test "gcl_tabs_the_cursor_arrives_with_the_tab_not_after_it":
    # A VM that switched tabs and then waited for a cursor event would spend
    # the interval showing the previous tab's line under the new tab's name.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    discard vm.noteActiveTabChanged(OtherPath, 77)
    counted vm.cursorLine.val == 77
    discard vm.noteActiveTabChanged(MainPath, 9)
    counted vm.cursorLine.val == 9
    counted vm.focusRows.val == (4, 6)

  test "gcl_tabs_a_closed_vm_follows_no_tab":
    let vm = createGeneratedCodeVM()
    counted not vm.noteActiveTabChanged(MainPath, 8)
    counted vm.activeTabPath.val.len == 0

  test "gcl_d16_projecting_once_on_reveal_equals_projecting_on_every_move":
    # THE EQUIVALENCE IS THE ASSERTION. A test that only exercised the
    # deferred path could not detect a divergence. Two VMs, the same landing
    # position, one walked there and one dropped there.
    let walked = createGeneratedCodeVM()
    walked.openListing(listingFixture(), 8)
    for line in [1, 2, 3, 8, 9, 400, 7, 9]:
      discard walked.noteCursorMoved(MainPath, line)

    let dropped = createGeneratedCodeVM()
    dropped.openListing(listingFixture(), 9)

    counted walked.cursorLine.val == dropped.cursorLine.val
    counted walked.focus.val.outcome == dropped.focus.val.outcome
    counted walked.focusRows.val == dropped.focusRows.val
    counted walked.focusText.val == dropped.focusText.val
    counted walked.instantiationCount.val == dropped.instantiationCount.val

# ===========================================================================
suite "GCL: build states and staleness (§8, GCL-D18)":

  test "gcl_a10_a_failed_build_clears_the_previous_successful_rows":
    # It never leaves the previous build's rows on screen as though they were
    # current: a developer reading a listing that does not correspond to the
    # source in front of them is worse off than one reading nothing.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.rows.val.len == 11

    vm.noteBuildFailed("main.nr:9:5: expected Field, found bool")
    counted vm.rows.val.len == 0
    counted vm.state.val == lsFailed
    counted vm.failure.val.len > 0
    counted "expected Field" in vm.failure.val
    counted vm.focus.val.outcome == soSuspended
    counted vm.focus.val.reason.len > 0

  test "a failed build with no diagnostic still says something":
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    vm.noteBuildFailed("")
    counted vm.failure.val.len > 0

  test "gcl_8_a_running_build_is_a_state_of_its_own":
    let vm = createGeneratedCodeVM()
    vm.noteBuildStarted(acirTarget(), MainPath, 8)
    counted vm.state.val == lsBuilding
    counted vm.isOpen.val
    counted vm.rows.val.len == 0
    counted vm.focus.val.outcome == soSuspended
    counted vm.focus.val.reason != ""
    # The tab exists and carries its identity while the build runs.
    counted MainPath in vm.tabTitle.val
    counted "ACIR" in vm.tabTitle.val

  test "gcl_a20_an_invalidating_edit_does_all_three_and_another_does_none":
    # THE NEGATIVE CONTROL IS IN THE SAME TEST. Making every edit invalidate
    # must redden exactly the second half.
    let vm = createGeneratedCodeVM()
    vm.openListing(listingFixture(), 8)
    counted vm.focus.val.outcome == soAligned

    vm.noteSourceEdited("Prover.toml")
    counted not vm.stale.val
    counted vm.focus.val.outcome == soAligned
    counted "(stale)" notin vm.tabTitle.val

    vm.noteSourceEdited(MainPath)
    counted vm.stale.val
    counted vm.focus.val.outcome == soSuspended
    counted vm.rows.val.len == 11
    counted "(stale)" in vm.tabTitle.val
    counted vm.revision.val == 1

  test "gcl_8_totals_with_no_rows_is_not_an_empty_listing":
    # §8's fourth state, and the one that must never be rendered as an empty
    # listing: totals with no rows is a different answer from a listing that
    # came back empty.
    var listing = listingFixture()
    listing.rows = @[]
    listing.listingAbsence =
      "this compiler build predates the printed ACIR listing"
    let vm = createGeneratedCodeVM()
    vm.openListing(listing, 8)
    counted vm.rows.val.len == 0
    counted vm.listingAbsence.val.len > 0
    counted vm.state.val == lsReady
    # The anchors survive, so the correspondence is still real.
    counted vm.focus.val.outcome == soAligned

# ===========================================================================
suite "GCL: the ladder is declared data, one command per target (GCL-D11)":

  test "gcl_d11_a_language_declares_named_targets_and_noir_declares_three":
    # Addressed through `targetsForPath`, which is the composition production
    # calls. `targetsFor` and `ladderLanguageOfPath` are internal precisely so
    # that this suite cannot exercise a surface no product module reaches.
    counted targetsForPath("src/main.nr").len == 3
    counted targetsForPath("src/main.nr")[0].displayName == "ACIR"
    counted targetsForPath("src/main.nim").len == 2
    counted targetsForPath("script.py").len == 0
    counted targetsForPath("README.md").len == 0

  test "gcl_d11_the_ladder_is_a_chain_for_nim_and_flat_for_noir":
    # Nim's assembly is generated from the C, not from the Nim — which is
    # what `openAlternativeView` already reflects by taking `cLocation
    # .asmName`. A consumer that could not tell a one-rung correspondence from
    # a composed two-rung one could not state §5.2's fidelity rule.
    let nim = targetsForPath("src/main.nim")
    counted nim[0].generatedFrom == ""
    counted nim[1].generatedFrom == nim[0].id
    for t in targetsForPath("src/main.nr"):
      counted t.generatedFrom == ""

  test "gcl_d11_the_language_is_read_per_file_from_the_path":
    # The observable of "which language is this file" is which ladder it gets,
    # since that is the only thing any caller does with the answer.
    counted targetsForPath("src/main.nr")[0].id == "noir.acir"
    counted targetsForPath("src/main.nim")[0].id == "nim.c"
    counted targetsForPath("a/b/c.rs")[0].id == "rust.asm"
    counted targetsForPath("README.md").len == 0
    counted targetsForPath("Nargo.toml").len == 0
    counted targetsForPath("noextension").len == 0
    counted targetsForPath("").len == 0
    # The dot must come after the last separator, or `src.v2/main` reads as
    # extension `v2/main`.
    counted targetsForPath("src.v2/main").len == 0
    counted targetsForPath("src.v2/main.nr")[0].id == "noir.acir"
    # Case does not decide a language.
    counted targetsForPath("src/MAIN.NR")[0].id == "noir.acir"

  test "every_target_id_is_unique_and_resolves_back_to_itself":
    # GCL-D26 one level up: the ID is the identity a saved layout persists, so
    # a collision would silently address another language's rung.
    #
    # The paths below are the ladder's own extensions, one per language. That
    # is the same list `LadderRows` carries, written independently here — if a
    # language is added and this list is not, `seen.len == 9` fails and names
    # the omission rather than quietly checking fewer targets.
    const LadderPaths = ["f.nr", "f.nim", "f.c", "f.cpp", "f.rs", "f.go"]
    var seen: seq[string] = @[]
    for path in LadderPaths:
      for t in targetsForPath(path):
        counted t.id notin seen
        seen.add t.id
        var back: GeneratedCodeTarget
        counted targetById(t.id, back)
        counted back.id == t.id
        counted back.displayName == t.displayName
        counted t.producer.len > 0
    counted seen.len == 9
    var missing: GeneratedCodeTarget
    counted not targetById("noir.wasm", missing)

  test "every_declared_extension_selects_a_ladder":
    # A language that declares targets no path can select is a feature nobody
    # can invoke — the shape this whole commit exists to fix, one level up.
    for ext in ["nr", "nim", "c", "h", "cpp", "cc", "cxx", "hpp", "rs", "go"]:
      counted targetsForPath("f." & ext).len > 0

  test "a_command_label_carries_the_target_own_name_and_no_two_collide":
    # "Show Assembly Code" cannot be the operation's name: one name cannot
    # mean ACIR, Brillig, SSA, generated C and assembly.
    counted commandLabel(acirTarget()) == "Show ACIR"
    for path in ["f.nr", "f.nim", "f.c", "f.cpp", "f.rs", "f.go"]:
      var labels: seq[string] = @[]
      for t in targetsForPath(path):
        counted commandLabel(t) notin labels
        labels.add commandLabel(t)

# ===========================================================================
suite "GCL: availability follows the build proposal (GCL-D17)":

  test "gcl_a19_a_non_canonical_proposal_disables_with_its_own_reason":
    # BOTH ARMS, since either alone is satisfied by a blanket policy.
    let ambiguous = CommandProposal(command: "", args: @[],
      confidence: pcAmbiguous,
      reason: "several build files match and none is conventional")
    let commands = commandsForPath("src/main.nr", ambiguous)
    counted commands.len == 3
    for c in commands:
      counted c.availability == gaDisabled
      counted c.reason == ambiguous.reason
      counted c.reason.len > 0

    # A language with no target yields NO command — absent, not disabled,
    # because there is nothing to explain.
    counted commandsForPath("README.md", ambiguous).len == 0

  test "gcl_a19_a_canonical_proposal_enables_and_carries_no_reason":
    let canonical = CommandProposal(command: "nargo", args: @["compile"],
      confidence: pcCanonical, reason: "")
    let commands = commandsForPath("src/main.nr", canonical)
    counted commands.len == 3
    for c in commands:
      counted c.availability == gaEnabled
      counted c.reason.len == 0

  test "gcl_d17_the_platform_refusal_outranks_the_proposal":
    # A canonical command the platform cannot run is still a command that
    # cannot run, and reporting the proposal's silence there would tell the
    # user to fix a build file that is already correct.
    let canonical = CommandProposal(command: "nargo", args: @["compile"],
      confidence: pcCanonical, reason: "")
    let commands = commandsForPath("src/main.nr", canonical,
      "this browser build carries no `nargo` module")
    counted commands.len == 3
    for c in commands:
      counted c.availability == gaDisabled
      counted "nargo" in c.reason

  test "a_disabled_command_always_carries_a_sentence":
    # An action whose refusal cannot be explained is one whose refusal was a
    # guess. `CommandProposal.reason` is non-empty for a non-canonical
    # confidence by EMT-A48, and the fallback covers a hand-built proposal.
    let silent = CommandProposal(command: "", args: @[],
      confidence: pcUnknown, reason: "")
    for c in commandsForPath("src/main.nr", silent):
      counted c.availability == gaDisabled
      counted c.reason.len > 0

# ===========================================================================
suite "GCL operation suite self-check":

  test "generated_code_operation_assertion_count_is_measured":
    # A suite that returned early — a moved fixture, a lane missing a module —
    # would go red HERE rather than passing quietly with fewer checks.
    check countedAssertions == ExpectedAssertions
