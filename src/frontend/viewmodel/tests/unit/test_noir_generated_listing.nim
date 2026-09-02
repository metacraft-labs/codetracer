## NS4 — the Noir producer against a REAL compile artefact.
##
## `GUI/Debugging-Features/Generated-Code-Listing.md` §0a.3, §4a, §8.4, §10.
##
## LANE: `vm-unit` AND `vm-unit-js`, by the directory glob in
## `ci/lib/test-lane-files.sh`. Nothing here reaches the host or `std/os`.
##
## Compile and run:
##   nim c  -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_noir_generated_listing.nim
##   nim js -r -d:nodejs --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_noir_generated_listing.nim
##
## ## WHY THIS SUITE EXISTS WHEN `test_noir_anchor_producer` IS ALREADY GREEN
##
## That suite's expectations were computed independently — the spec is explicit
## that its line numbers are literals from a hand-built byte-offset table, and
## that is genuinely rigorous. Its ENVELOPE, however, was invented:
## `debugNode(locations)` builds `{"locations": {...}}`, and **no Noir compiler
## has ever emitted that**. A shipped artefact carries
##
##     {"debug_infos": [ {"acir_locations":   {"<opcode>": <callStackId>},
##                        "location_tree":    {"locations": [ ... ]},
##                        "brillig_locations": {...}} ]}
##
## — a CallStackId per opcode, resolved by walking a PARENT CHAIN, not a span
## list. So the producer returns zero locations for every real artefact and the
## pane would render every row `unmapped`: correct per the model, useless to a
## user, and invisible to a suite whose fixture agreed with the parser.
##
## That is `Verification-Harness-Traps.md` trap 4d one level up — the fixture,
## rather than the scan pattern, matched the implementation's own vocabulary.
##
## ## WHERE THE FIXTURE COMES FROM
##
## `DebugSymbolsJson` and the two source texts below are VERBATIM output of
##
##     nargo compile --force        # nargo 1.0.0-beta.26 / noirc 906af2f4
##
## run against the bundled template materialised from
## `viewmodel/platform/noir_template.nim`, on 2026-09-02. `debug_symbols` was
## base64-decoded and raw-inflated (`flate2::write::DeflateEncoder` emits raw
## deflate, no zlib header) and then reduced to the three keys anchoring reads;
## every byte that remains is the compiler's. The only edit is to `file_map`'s
## `path` strings, which were absolute build-machine paths.
##
## That compiler version is the family of `ci/deploy/noir-wasm.pin`'s
## `9d4e40a6`. It matters: the SAME template under 1.0.0-beta.2 reports 15
## opcodes, not 17, and emits a flat `locations: {opcode: [span]}` with no
## call-stack tree at all. A fixture that did not name its compiler would be
## untestable rather than merely imprecise.
##
## ## WHERE THE EXPECTATIONS COME FROM
##
## The line numbers are LITERALS. They were computed by a throwaway Python
## script that read the fixture's source text and counted newlines before each
## span offset — a separate implementation, in a different language, that calls
## nothing in `noir_anchor_producer`. If the producer's span arithmetic is
## wrong, these do not move with it.
##
## `validate` is the cross-check, and it lives in a different module: the
## producer decides what to claim, `generated_code_anchors` decides what may be
## claimed, and neither derives from the other.

import std/[json, strutils, tables, unittest]

import ../../viewmodels/generated_code_anchors
import ../../viewmodels/noir_anchor_producer

# ---------------------------------------------------------------------------
# Counted assertions.
#
# `counted` is a TEMPLATE, and that is load-bearing: `std/unittest`'s `check`
# only marks a case failed where `testStatusIMPL` is in scope, which is inside
# a `test` body. A template is inlined into that body; a proc is not, and every
# `check` inside a proc would print its message and let the case report [OK].
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 81
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# THE FIXTURE — verbatim `nargo compile` output. See the header.
# ---------------------------------------------------------------------------

const DebugSymbolsJson* = """{"debug_infos":[{"acir_locations":{"0":1,"1":1,"2":3,"3":3,"4":3,"5":3,"6":3,"7":3,"8":3,"9":3,"10":3,"11":3,"12":3,"13":4,"14":4,"15":4,"16":5},"location_tree":{"locations":[{"parent":null,"value":{"span":{"start":0,"end":0},"file":0}},{"parent":0,"value":{"span":{"start":263,"end":277},"file":52}},{"parent":0,"value":{"span":{"start":283,"end":308},"file":52}},{"parent":2,"value":{"span":{"start":205,"end":217},"file":54}},{"parent":2,"value":{"span":{"start":205,"end":230},"file":54}},{"parent":2,"value":{"span":{"start":198,"end":231},"file":54}}]},"brillig_locations":{}}]}"""

const MainSource* = """mod tests;
mod utils;

// The first thing you see, and the first thing you can change.
//
// `x` is private and `y` is public: Noir proves it knows an `x` that
// satisfies every assertion below, without revealing which one.
fn main(x: Field, y: pub Field) {
    assert(x != y);
    utils::assert_in_range(x);
}

#[test]
fn test_main() {
    main(1, 2);
}

#[test(should_fail)]
fn test_equal_inputs_are_rejected() {
    main(3, 3);
}
"""

const UtilsSource* = """// A second module, because a Noir project is a directory tree and a
// single-file playground would misrepresent the language.

global MAX: Field = 128;

pub fn assert_in_range(value: Field) {
    assert(value as u32 < MAX as u32);
}

#[test]
fn test_in_range_accepts_small_values() {
    assert_in_range(7);
}
"""

const
  MainPath = "src/main.nr"
  UtilsPath = "src/utils.nr"
  TemplateOpcodeCount = 17
    ## `nargo info --json` on the same tree, same compiler:
    ## `{"functions":[{"name":"main","opcodes":17}]}`. Taken from the producer
    ## of the number rather than counted off the fixture, because the listing
    ## and the anchor set must agree with `nargo`, not merely with each other.

proc fileMapNode(): JsonNode =
  %*{
    "52": {"path": MainPath, "source": MainSource},
    "54": {"path": UtilsPath, "source": UtilsSource},
  }

proc artefactJson(): string =
  $(%*{"file_map": fileMapNode(), "debug_symbols": parseJson(DebugSymbolsJson)})

proc readTemplateArtefact(): ArtefactRead =
  readArtefact(fileMapNode(), parseJson(DebugSymbolsJson), TemplateOpcodeCount)

proc anchorCovering(anchors: seq[MappingAnchor]; row: int): int =
  result = NoAnchor
  for i, a in anchors:
    if row >= a.generatedFirst and row <= a.generatedLast:
      return i

# ---------------------------------------------------------------------------

suite "NS4: the producer reads a real artefact (GCL-A1..A6)":

  test "gcl_a1_a_real_artefact_envelope_yields_locations":
    # GCL-A1. The assertion §0a.3 says does not exist today: the fixture is
    # compiler output, so a producer that only understands the invented
    # envelope reads NOTHING here and every check below fails.
    let read = readTemplateArtefact()
    counted read.outcome == aroOk
    counted read.detail == ""
    counted read.artefact.files.len == 2
    counted read.artefact.opcodeCount == TemplateOpcodeCount
    # The whole point: seventeen located opcodes, not zero.
    counted read.artefact.locatedOpcodeCount() == TemplateOpcodeCount

  test "gcl_a1_the_same_artefact_read_from_whole_json_text":
    # The `readArtefactJson` path, which is what a caller holding a compile
    # response actually has. Same artefact, different entry point.
    let read = readArtefactJson(artefactJson(), TemplateOpcodeCount)
    counted read.outcome == aroOk
    counted read.artefact.locatedOpcodeCount() == TemplateOpcodeCount

  test "gcl_a2_every_row_is_covered_and_nothing_validates_as_defective":
    # GCL-A2. Two clauses, and the pairing is deliberate: a producer that
    # emitted NOTHING would satisfy "no defects" on its own. Coverage is what
    # makes the emptiness unrepresentable (trap 4b).
    let read = readTemplateArtefact()
    let (anchors, support) = produceAnchors(read.artefact)

    for row in 0 ..< TemplateOpcodeCount:
      counted anchorCovering(anchors, row) != NoAnchor

    let defects = validate(anchors, support)
    counted defects.len == 0
    if defects.len > 0:
      echo describe(defects)

  test "gcl_a3_opcode_0_is_exact_on_one_frame_and_opcode_2_is_an_ordered_merge":
    # GCL-A3 and §4a. The line numbers are LITERALS computed by a separate
    # script; see the header.
    #
    #   main.nr:9   `    assert(x != y);`
    #   main.nr:10  `    utils::assert_in_range(x);`
    #   utils.nr:7  `    assert(value as u32 < MAX as u32);`
    let read = readTemplateArtefact()
    let (anchors, _) = produceAnchors(read.artefact)

    let a0 = anchors[anchorCovering(anchors, 0)]
    counted a0.fidelity == mfExact
    counted a0.sources.len == 1
    counted a0.sources[0].path == MainPath
    counted a0.sources[0].startLine == 9
    counted a0.sources[0].endLine == 9

    let a2 = anchors[anchorCovering(anchors, 2)]
    counted a2.fidelity == mfMerged
    counted a2.sources.len == 2
    # ORDER IS THE CONTRACT (GCL-D1). Outermost first: `main.nr:10` is WHY the
    # code is here, `utils.nr:7` is WHERE it is. A producer that returned these
    # as an unordered set, or sorted them, would pass a length check and fail
    # this one — which is the whole reason the assertion names both positions.
    counted a2.sources[0].path == MainPath
    counted a2.sources[0].startLine == 10
    counted a2.sources[1].path == UtilsPath
    counted a2.sources[1].startLine == 7
    # And the innermost frame is the LAST element, which is what lets the pane
    # highlight where the code is rather than where the call was written.
    counted a2.sources[^1].path == UtilsPath

  test "gcl_a4_the_root_call_stack_node_is_never_a_source":
    # GCL-A4. `location_tree.locations[0]` is a sentinel — span 0..0, file 0 —
    # and file 0 is not even in `file_map`. Including it would attribute every
    # opcode to byte 0 of a file that does not exist, which resolves to
    # nothing and would silently DEGRADE every merge to an exact.
    let read = readTemplateArtefact()
    let (anchors, _) = produceAnchors(read.artefact)
    for a in anchors:
      for s in a.sources:
        counted s.path == MainPath or s.path == UtilsPath
      # No anchor may carry three frames: the deepest real stack here is two
      # deep, so a third would be the root leaking in.
      counted a.sources.len <= 2

  test "gcl_a4_the_root_is_excluded_by_the_WALK_not_by_a_missing_file":
    # THE CASE ABOVE WAS VACUOUS, AND A MUTATION ARM PROVED IT. Moving
    # `result.add node.span` above the root check — the exact off-by-one this
    # is meant to catch — changed NO result, because the root's `file` is 0,
    # file 0 is absent from the template's `file_map`, and `resolve` therefore
    # discards it anyway. The assertion was passing for a reason that had
    # nothing to do with the property.
    #
    # So this arm puts file 0 IN the file map. Now the root sentinel's
    # `span 0..0` resolves cleanly to line 1, and a walk that includes it
    # prepends a phantom frame to EVERY opcode: every `mfExact` becomes
    # `mfMerged` over two, and every two-frame merge becomes three. The
    # fixture is otherwise untouched compiler output; only the file map is
    # extended, which is a legitimate perturbation because it tests the WALK
    # rather than the compiler's shape.
    let mapWithFileZero = %*{
      "0": {"path": "src/phantom.nr", "source": "// not a real frame\n"},
      "52": {"path": MainPath, "source": MainSource},
      "54": {"path": UtilsPath, "source": UtilsSource},
    }
    let read = readArtefact(mapWithFileZero, parseJson(DebugSymbolsJson),
                            TemplateOpcodeCount)
    counted read.outcome == aroOk
    let (anchors, _) = produceAnchors(read.artefact)

    # No source may come from the phantom file — that is the root leaking in.
    for a in anchors:
      for s in a.sources:
        counted s.path != "src/phantom.nr"

    # And the frame counts are unchanged by the file map growing, which is the
    # positive statement of the same property.
    counted anchors[anchorCovering(anchors, 0)].sources.len == 1
    counted anchors[anchorCovering(anchors, 0)].fidelity == mfExact
    counted anchors[anchorCovering(anchors, 2)].sources.len == 2
    counted anchors[anchorCovering(anchors, 2)].fidelity == mfMerged

  test "gcl_a5_the_seventeen_opcodes_coalesce_into_exactly_two_anchors":
    # GCL-A5, and the number is the assertion.
    #
    # THIS NUMBER WAS FOUR IN THE SPEC'S FIRST DRAFT, AND THE DRAFT WAS WRONG.
    # There ARE four distinct call stacks — 1, 3, 4, 5 — but stacks 3, 4 and 5
    # resolve to the IDENTICAL pair of line-granular regions (main.nr:10 and
    # utils.nr:7); they differ only in byte spans inside line 7, and
    # `SourceRegion` carries no columns. So `sameSources` coalesces rows 2..16
    # into one anchor, and that is the right answer: three anchors highlighting
    # the same two lines would be noise dressed as structure.
    #
    # The assertion is an exact count rather than `>= 1` because every
    # implementation satisfies `>= 1`, including one that emitted a single
    # anchor over all seventeen rows and lost the exact/merged boundary.
    let read = readTemplateArtefact()
    let (anchors, _) = produceAnchors(read.artefact)
    counted anchors.len == 2

    counted anchors[0].generatedFirst == 0
    counted anchors[0].generatedLast == 1
    counted anchors[0].fidelity == mfExact
    counted anchors[1].generatedFirst == 2
    counted anchors[1].generatedLast == 16
    counted anchors[1].fidelity == mfMerged

  test "gcl_a5b_control_one_source_line_reaches_fifteen_of_seventeen_rows":
    # GCL-A5b, and the measurement §9.5 is built on: the honest answer is NOT
    # that the highlight becomes small. `main.nr:10` really does produce
    # fifteen of seventeen opcodes. If a future producer made this number
    # small, §9.5's reasoning would no longer apply and should be revisited
    # rather than silently satisfied — which is why the bound is asserted from
    # BELOW rather than as an inequality that shrinking would keep passing.
    let read = readTemplateArtefact()
    let (anchors, _) = produceAnchors(read.artefact)
    var rowsForLine10 = 0
    for a in anchors:
      for s in a.sources:
        if s.path == MainPath and s.startLine <= 10 and s.endLine >= 10:
          rowsForLine10 += a.generatedLast - a.generatedFirst + 1
          break
    counted rowsForLine10 == 15
    counted rowsForLine10 * 100 div TemplateOpcodeCount >= 85

  test "gcl_a6_an_artefact_with_no_debug_infos_is_unmapped_not_an_error":
    # GCL-A6. An artefact compiled without debug information reads FINE and
    # produces unmapped rows — the honest answer, and distinguishable from a
    # parse failure.
    let empty = %*{"debug_infos": []}
    let read = readArtefact(fileMapNode(), empty, 3)
    counted read.outcome == aroOk
    let (anchors, support) = produceAnchors(read.artefact)
    counted anchors.len == 1
    counted anchors[0].fidelity == mfUnmapped
    counted anchors[0].generatedFirst == 0
    counted anchors[0].generatedLast == 2
    counted claimCeiling(support) == mfUnmapped
    counted validate(anchors, support).len == 0
    # Positive twin through the same path: the populated artefact is NOT
    # unmapped, so the assertion above cannot be passing for a trivial reason.
    let real = readTemplateArtefact()
    let (realAnchors, realSupport) = produceAnchors(real.artefact)
    counted realAnchors[0].fidelity != mfUnmapped
    counted claimCeiling(realSupport) == mfExact

  test "gcl_a6_a_malformed_envelope_is_refused_rather_than_thrown":
    # The bare-`except` path, meaningful only on the JS backend where
    # `JSON.parse` throws a foreign `SyntaxError` no Nim type matches.
    let read = readArtefactJson("{not json", 3)
    counted read.outcome == aroUnparseable
    counted read.detail.len > 0
    # And a shape that parses but is not an artefact.
    let read2 = readArtefactJson("[1, 2, 3]", 3)
    counted read2.outcome == aroUnparseable

  test "gcl_a3_synchronisation_over_the_real_artefact_runs_both_ways":
    # The property the pane exists for, over compiler output rather than a
    # fixture: a generated row finds its source, and the source finds its rows.
    let read = readTemplateArtefact()
    let (anchors, _) = produceAnchors(read.artefact)

    let fromRow = syncFromGenerated(anchors, 5)
    counted fromRow.outcome == soAligned
    let sources = counterpartSources(anchors, fromRow)
    counted sources.len == 2
    counted sources[^1].path == UtilsPath

    let fromSource = syncFromSource(anchors, UtilsPath, 7)
    counted fromSource.outcome == soAligned
    let (first, last) = counterpartRows(anchors, fromSource)
    counted first == 2
    # 16, not 12: rows 2..16 are ONE anchor, because call stacks 3, 4 and 5
    # resolve to identical line-granular sources. See GCL-D8.
    counted last == 16

    # A row past the listing suspends, and SAYS SO.
    let past = syncFromGenerated(anchors, TemplateOpcodeCount + 5)
    counted past.outcome == soSuspended
    counted past.reason.len > 0
    # Off is not the same as ran-out, in both directions.
    let off = SyncSettings(enabled: false)
    counted syncFromGenerated(anchors, 5, off).outcome == soDisabled
    counted syncFromSource(anchors, UtilsPath, 7, off).outcome == soDisabled

suite "NS4 suite self-check":

  test "noir_generated_listing_assertion_count_is_measured":
    # A suite that returned early — a moved fixture, a lane without the
    # producer — would go red HERE rather than passing quietly with fewer
    # checks. `Verification-Harness-Traps.md` §4c: assert the fingerprint,
    # do not diff it.
    check countedAssertions == ExpectedAssertions
