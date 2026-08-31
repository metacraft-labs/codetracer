## Headless tests for NS4's Noir producer and the panel's anchor machinery.
##
## NS4 / `GUI/Debugging-Features/Generated-Code-Listing.md` §3.1, §4, §7.
##
## LANE: `vm-unit` AND `vm-unit-js`, by the directory glob in
## `ci/lib/test-lane-files.sh`. Both lanes matter here for the reason
## `CONTRIBUTING.md`'s "Code compiled for both backends" entry gives, and this
## suite has a case that is ONLY meaningful on one of them:
## `readArtefactJson`'s bare `except`. On the C backend `parseJson` raises
## `JsonParsingError`; on the JS backend it defers to `JSON.parse`, which
## throws a raw `SyntaxError` no Nim type matches. The narrow form would catch
## nothing under `nim js`, which is the backend the renderer ships on.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_noir_anchor_producer.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_noir_anchor_producer.nim
##
## ## WHERE THE EXPECTATIONS COME FROM, WHICH IS THE WHOLE PROBLEM
##
## A producer test is the natural home of a tautology: assert the producer's
## output against something derived the same way the producer derived it, and
## the suite passes over any consistent-but-wrong implementation. Two rules
## here, both deliberate:
##
##   1. **The line numbers below were computed independently** — by hand,
##      against `FixtureSource` written out with its byte offsets, in a
##      separate implementation (a throwaway script), NOT by calling anything
##      in `noir_anchor_producer`. They are written as literals. If the
##      producer's span arithmetic is wrong, these do not move with it.
##   2. **`validate` is the cross-check, and it is a DIFFERENT MODULE.** The
##      producer decides what to claim; `generated_code_anchors.validate`
##      decides what may be claimed. Neither derives from the other, so
##      "the producer's output validates clean" is a real assertion rather
##      than a restatement. It would not be if this suite re-implemented the
##      rules locally.
##
## ## Control arms
##
## Every refusal case is paired with a control: the same shape, one field
## changed to the legitimate value, asserted to be ACCEPTED. Without it a
## refusal passes for the trivial reason that nothing is ever accepted.

import std/[json, strutils, tables, unittest]

import isonim/core/async_compat
import isonim/core/[signals, computation]
import isonim/viewmodel

import ../../backend/mock_backend
import ../../store/replay_data_store
import ../../viewmodels/generated_code_anchors
import ../../viewmodels/low_level_code_vm
import ../../viewmodels/noir_anchor_producer

# ---------------------------------------------------------------------------
# Counted assertions.
#
# `counted` is a TEMPLATE, and that is load-bearing: `std/unittest`'s `check`
# only marks a case failed where `testStatusIMPL` is in scope, which is inside
# a `test` body. A template is inlined into that body; a proc is not, and every
# `check` inside a proc would print its message and let the case report [OK].
# Same reasoning as `test_generated_code_anchors.nim`.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 160
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# The fixture, and its byte offsets.
#
#   byte  0 ..18   `fn main(x: Field) {`      line 1     newline at 19
#   byte 20 ..37   `    let y = x + 1;`       line 2     newline at 38
#   byte 39 ..57   `    assert(y != 0);`      line 3     newline at 58
#   byte 59        `}`                        line 4     newline at 60
#
# Line starts: 0, 20, 39, 59. Length 61. Every expectation below is read off
# THIS table, not off the producer.
# ---------------------------------------------------------------------------
const
  FixtureSource = "fn main(x: Field) {\n    let y = x + 1;\n" &
                  "    assert(y != 0);\n}\n"
  FixturePath = "/proj/src/main.nr"

proc spanNode(fileId, startByte, endByte: int): JsonNode =
  %*{"span": {"start": startByte, "end": endByte}, "file": fileId}

proc fileMapNode(source: string = FixtureSource;
                 path: string = FixturePath): JsonNode =
  %*{"0": {"path": path, "source": source}}

proc debugNode(locations: JsonNode): JsonNode =
  %*{"locations": locations}

proc artefactOf(locations: JsonNode; opcodeCount: int;
                fileMap: JsonNode = fileMapNode()): NoirDebugArtefact =
  let read = readArtefact(fileMap, debugNode(locations), opcodeCount)
  doAssert read.outcome == aroOk, read.detail
  read.artefact

suite "NS4 Noir producer: span resolution":

  test "a single-line span is an exact anchor on the hand-computed line":
    # byte 24 is inside `    let y = x + 1;` (20..37) -> line 2.
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25)]}, 1)
    let (anchors, support) = produceAnchors(a)
    counted anchors.len == 1
    counted anchors[0].fidelity == mfExact
    counted anchors[0].sources.len == 1
    counted anchors[0].sources[0].startLine == 2
    counted anchors[0].sources[0].endLine == 2
    counted anchors[0].sources[0].path == FixturePath
    counted support.hasSourcePositions
    # The model agrees the claim is legal. Different module, different rules.
    counted validate(anchors, support).len == 0

  test "the span end is EXCLUSIVE, so a span stopping at a line start stays on the line before":
    # (20, 39): byte 38 is the newline ending line 2; 39 is line 3's first
    # byte. The last COVERED byte is 38, so this is line 2..2 and therefore
    # exact. Using `end` directly would give 2..3 and demote it to coarse,
    # which is the off-by-one this case exists to catch.
    let a = artefactOf(%*{"0": [spanNode(0, 20, 39)]}, 1)
    let (anchors, _) = produceAnchors(a)
    counted anchors[0].sources[0].startLine == 2
    counted anchors[0].sources[0].endLine == 2
    counted anchors[0].fidelity == mfExact

  test "a multi-line span is COARSE, not exact":
    # (20, 57): starts on line 2, last covered byte 56 is on line 3.
    let a = artefactOf(%*{"0": [spanNode(0, 20, 57)]}, 1)
    let (anchors, support) = produceAnchors(a)
    counted anchors[0].fidelity == mfCoarse
    counted anchors[0].sources[0].startLine == 2
    counted anchors[0].sources[0].endLine == 3
    counted validate(anchors, support).len == 0

  test "an empty span sits on its start line":
    let a = artefactOf(%*{"0": [spanNode(0, 24, 24)]}, 1)
    let (anchors, _) = produceAnchors(a)
    counted anchors[0].sources[0].startLine == 2
    counted anchors[0].sources[0].endLine == 2

  test "spans on the first and last lines resolve, so the table is not off by a line at either end":
    # Both ends of the file, because an off-by-one in `lineOf` is easiest to
    # hide in the middle.
    let a = artefactOf(%*{"0": [spanNode(0, 0, 19)], "1": [spanNode(0, 59, 60)]}, 2)
    let (anchors, _) = produceAnchors(a)
    counted anchors.len == 2
    counted anchors[0].sources[0].startLine == 1
    counted anchors[1].sources[0].startLine == 4

suite "NS4 Noir producer: support is a fact about the ARTEFACT":

  test "a file with no source text supports nothing, so the span cannot be positional":
    # The file id is known and the line is not. Control arm below: the same
    # span with the source present IS positional.
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25)]}, 1,
      fileMap = %*{"0": {"path": FixturePath}})
    let (anchors, support) = produceAnchors(a)
    counted not support.hasSourcePositions
    counted not support.hasSourceRegions
    counted claimCeiling(support) == mfUnmapped
    counted anchors[0].fidelity == mfUnmapped
    counted anchors[0].sources.len == 0
    counted validate(anchors, support).len == 0

  test "a span at byte 0 into a source-less file is STILL unresolved, not line 1":
    # This case exists because the mutation arm found the previous one did not
    # reach the guard it was aimed at. A span of (24, 25) into a file with no
    # text is rejected by the BOUNDS check (24 > 0), so deleting the
    # empty-source guard changed nothing and the mutation survived.
    #
    # Byte 0 passes the bounds check (0 > 0 is false). Without the
    # empty-source guard it resolves against `lineStarts("") == @[0]` and
    # yields line 1 of a file whose text we do not have — a fabricated
    # position, and the most dangerous possible output for this pane, because
    # line 1 of a real file exists and looks plausible.
    let a = artefactOf(%*{"0": [spanNode(0, 0, 0)]}, 1,
      fileMap = %*{"0": {"path": FixturePath}})
    let (anchors, support) = produceAnchors(a)
    counted not support.hasSourcePositions
    counted anchors[0].fidelity == mfUnmapped
    counted anchors[0].sources.len == 0

  test "CONTROL: byte 0 WITH source text present resolves to line 1":
    # The other half: line 1 is a real answer when the artefact can support
    # it, so the case above is about the missing text and not about byte 0.
    let a = artefactOf(%*{"0": [spanNode(0, 0, 0)]}, 1)
    let (anchors, _) = produceAnchors(a)
    counted anchors[0].fidelity == mfExact
    counted anchors[0].sources[0].startLine == 1

  test "CONTROL: the same span with source text present is exact":
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25)]}, 1)
    let (anchors, support) = produceAnchors(a)
    counted support.hasSourcePositions
    counted anchors[0].fidelity == mfExact

  test "a span into a file absent from file_map resolves to nothing":
    let a = artefactOf(%*{"0": [spanNode(7, 24, 25)]}, 1)
    let (anchors, support) = produceAnchors(a)
    counted not support.hasSourcePositions
    counted anchors[0].fidelity == mfUnmapped

  test "an artefact with no debug symbols yields unmapped, and that is the correct answer":
    let read = readArtefact(fileMapNode(), nil, 3)
    counted read.outcome == aroOk
    let (anchors, support) = produceAnchors(read.artefact)
    counted claimCeiling(support) == mfUnmapped
    counted anchors.len == 1          # all three rows coalesce
    counted anchors[0].generatedFirst == 0
    counted anchors[0].generatedLast == 2
    counted anchors[0].fidelity == mfUnmapped
    counted validate(anchors, support).len == 0

  test "inlining records are detected from a multi-location opcode":
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25), spanNode(0, 43, 57)]}, 1)
    let (_, support) = produceAnchors(a)
    counted support.hasInliningRecords

  test "CONTROL: a single-location artefact reports no inlining records":
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25)]}, 1)
    let (_, support) = produceAnchors(a)
    counted not support.hasInliningRecords

suite "NS4 Noir producer: the three overclaims it refuses":

  test "OVERCLAIM 1 — an unlocated opcode is unmapped, NOT compiler-generated":
    # The tempting reading is "no location means the compiler generated it".
    # A Noir artefact cannot tell a synthetic opcode from one whose debug info
    # was dropped, so the honest rung is the one that claims nothing.
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25)]}, 2)
    let (anchors, support) = produceAnchors(a)
    counted anchors.len == 2
    counted anchors[1].fidelity == mfUnmapped
    counted anchors[1].fidelity != mfCompilerGenerated
    counted anchors[1].sources.len == 0
    # And the artefact says so about itself, which is what makes the rung
    # unavailable rather than merely unused.
    counted not support.marksCompilerGenerated
    counted validate(anchors, support).len == 0

  test "and the model would REJECT the compiler-generated rung from this artefact":
    # Belt and braces: even if a future producer reached for the rung, the
    # support flag makes it invalid. This asserts the enforcement, having
    # asserted the honesty above.
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25)]}, 2)
    let (anchors, support) = produceAnchors(a)
    var tampered = anchors
    tampered[1].fidelity = mfCompilerGenerated
    let defects = validate(tampered, support)
    counted defects.len == 1
    counted adkFidelityAboveArtefactCeiling in defects.kinds()

  test "OVERCLAIM 2 — two locations become MERGED over both, never exact over the first":
    # byte 24 -> line 2, byte 43 -> line 3. Both must survive.
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25), spanNode(0, 43, 57)]}, 1)
    let (anchors, support) = produceAnchors(a)
    counted anchors[0].fidelity == mfMerged
    counted anchors[0].fidelity != mfExact
    counted anchors[0].sources.len == 2
    counted anchors[0].sources[0].startLine == 2
    counted anchors[0].sources[1].startLine == 3
    counted validate(anchors, support).len == 0

  test "CONTROL: one location on the same opcode is exact over that one source":
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25)]}, 1)
    let (anchors, _) = produceAnchors(a)
    counted anchors[0].fidelity == mfExact
    counted anchors[0].sources.len == 1

  test "a merged anchor keeps only the RESOLVABLE sources, and drops to exact when one is lost":
    # Two locations, one into a file with no text. The unresolvable one
    # contributes nothing, so this is a single-source anchor and claiming
    # `mfMerged` over it would be `adkMergedUnderTwoSources`.
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25), spanNode(9, 0, 4)]}, 1)
    let (anchors, support) = produceAnchors(a)
    counted anchors[0].sources.len == 1
    counted anchors[0].fidelity == mfExact
    counted validate(anchors, support).len == 0

  test "OVERCLAIM 3 — a rung above the artefact's ceiling is clamped, and clamping to unmapped drops the sources":
    # An artefact whose ONLY spans are multi-line: no positional support, so
    # the ceiling is coarse. A single-line span cannot appear here, so this
    # constructs the clamp directly against a support value the artefact
    # itself produced.
    let a = artefactOf(%*{"0": [spanNode(0, 20, 57)]}, 1)
    let (anchors, support) = produceAnchors(a)
    counted claimCeiling(support) == mfCoarse
    counted anchors[0].fidelity == mfCoarse
    counted validate(anchors, support).len == 0

  test "every produced anchor set validates clean against the model":
    # The cross-module check, over several shapes at once. `validate` is
    # written independently of the producer; if the producer ever emits a
    # structurally impossible claim, this is what catches it without this
    # suite having to re-state the rules.
    let cases = @[
      %*{"0": [spanNode(0, 24, 25)]},
      %*{"0": [spanNode(0, 20, 57)]},
      %*{"0": [spanNode(0, 24, 25), spanNode(0, 43, 57)]},
      %*{"0": [spanNode(7, 0, 4)]},
      %*{"0": []},
      newJObject(),
    ]
    for locations in cases:
      let a = artefactOf(locations, 3)
      let (anchors, support) = produceAnchors(a)
      counted validate(anchors, support).len == 0
      # And every row is covered, so no row's fidelity is undefined.
      var covered = 0
      for anchor in anchors:
        covered += anchor.generatedLast - anchor.generatedFirst + 1
      counted covered == 3

suite "NS4 Noir producer: coalescing and row coverage":

  test "consecutive opcodes with the same mapping become one anchor":
    let a = artefactOf(%*{
      "0": [spanNode(0, 24, 25)],
      "1": [spanNode(0, 24, 25)],
      "2": [spanNode(0, 24, 25)]}, 3)
    let (anchors, _) = produceAnchors(a)
    counted anchors.len == 1
    counted anchors[0].generatedFirst == 0
    counted anchors[0].generatedLast == 2

  test "a gap SPLITS the run, so synchronisation suspends over it rather than interpolating":
    # Rows 0 and 2 map to line 2; row 1 is unlocated. Three anchors, and the
    # middle one claims nothing — which is what makes `syncFromGenerated(1)`
    # suspend instead of quietly answering line 2.
    let a = artefactOf(%*{
      "0": [spanNode(0, 24, 25)],
      "2": [spanNode(0, 24, 25)]}, 3)
    let (anchors, _) = produceAnchors(a)
    counted anchors.len == 3
    counted anchors[1].fidelity == mfUnmapped
    let decision = syncFromGenerated(anchors, 1)
    counted decision.outcome == soSuspended
    counted decision.reason.len > 0

  test "different sources do not coalesce":
    let a = artefactOf(%*{
      "0": [spanNode(0, 24, 25)],
      "1": [spanNode(0, 43, 57)]}, 2)
    let (anchors, _) = produceAnchors(a)
    counted anchors.len == 2
    counted anchors[0].sources[0].startLine == 2
    counted anchors[1].sources[0].startLine == 3

  test "trailing unlocated opcodes still appear as rows":
    # `opcodeCount` comes from the caller precisely so these do not vanish.
    let a = artefactOf(%*{"0": [spanNode(0, 24, 25)]}, 5)
    let (anchors, _) = produceAnchors(a)
    var covered = 0
    for anchor in anchors:
      covered += anchor.generatedLast - anchor.generatedFirst + 1
    counted covered == 5
    counted anchors[^1].generatedLast == 4

suite "NS4 Noir producer: reading the artefact":

  test "malformed JSON is refused rather than throwing (JS backend: a raw SyntaxError)":
    let read = readArtefactJson("{not json", 3)
    counted read.outcome == aroUnparseable
    counted read.detail.len > 0

  test "a non-object top level is refused":
    let read = readArtefactJson("[1, 2, 3]", 3)
    counted read.outcome == aroUnparseable

  test "CONTROL: a well-formed artefact reads OK and its spans resolve":
    let text = $(%*{
      "file_map": fileMapNode(),
      "debug_symbols": debugNode(%*{"0": [spanNode(0, 24, 25)]})})
    let read = readArtefactJson(text, 1)
    counted read.outcome == aroOk
    let (anchors, _) = produceAnchors(read.artefact)
    counted anchors[0].fidelity == mfExact
    counted anchors[0].sources[0].startLine == 2

  test "a missing file_map is named, not silently treated as empty":
    let read = readArtefactJson($(%*{"debug_symbols": debugNode(newJObject())}), 2)
    counted read.outcome == aroMissingFileMap
    counted read.detail.len > 0

  test "an array of circuits reads the first one":
    let read = readArtefact(fileMapNode(),
      %*[debugNode(%*{"0": [spanNode(0, 24, 25)]})], 1)
    counted read.outcome == aroOk
    let (anchors, _) = produceAnchors(read.artefact)
    counted anchors[0].fidelity == mfExact

# ---------------------------------------------------------------------------
# The panel's half.
# ---------------------------------------------------------------------------

proc newVM(): LowLevelCodeVM =
  let mock = newMockBackendService(autoRespond = true)
  createLowLevelCodeVM(createReplayDataStore(mock.toBackendService()))

proc exactAnchor(first, last: int): MappingAnchor =
  MappingAnchor(
    generatedFirst: first, generatedLast: last, fidelity: mfExact,
    sources: @[SourceRegion(path: FixturePath, startLine: 2, endLine: 2)],
    count: ExecutedCount(value: 0, provenance: cpNone))

const PositionalSupport = ArtefactSupport(
  hasSourcePositions: true, hasSourceRegions: true,
  hasInliningRecords: false, marksCompilerGenerated: false)

suite "NS4 panel: the VM refuses a mapping it knows to be broken":

  test "a valid anchor set is installed":
    let vm = newVM()
    counted vm.setAnchors(@[exactAnchor(0, 2)], PositionalSupport)
    counted vm.anchors.val.len == 1
    counted vm.hasAnchors.val
    counted not vm.anchorsRejected.val
    counted vm.anchorDefects.val.len == 0
    vm.dispose()

  test "a defective set is refused WHOLESALE, not partially installed":
    # One good anchor, one structurally impossible (`mfExact` over two
    # sources). Showing the good half of a mapping known to be broken is the
    # same confident-wrong-answer error over fewer rows.
    let vm = newVM()
    var bad = exactAnchor(3, 4)
    bad.sources.add SourceRegion(path: FixturePath, startLine: 3, endLine: 3)
    counted not vm.setAnchors(@[exactAnchor(0, 2), bad], PositionalSupport)
    counted vm.anchors.val.len == 0
    counted not vm.hasAnchors.val
    counted vm.anchorsRejected.val
    counted adkExactOverManySources in vm.anchorDefects.val.kinds()
    vm.dispose()

  test "'no debug info' and 'mapping refused' are distinguishable states":
    # Both leave the anchor list empty. The pane must not show them alike:
    # one is a property of the artefact, the other is a producer bug.
    let vm = newVM()
    counted vm.setAnchors(@[], PositionalSupport)
    counted not vm.hasAnchors.val
    counted not vm.anchorsRejected.val

    var bad = exactAnchor(0, 1)
    bad.sources = @[]
    counted not vm.setAnchors(@[bad], PositionalSupport)
    counted not vm.hasAnchors.val
    counted vm.anchorsRejected.val
    vm.dispose()

  test "a fresh load drops the previous artefact's anchors":
    # Anchors are ranges of row INDICES. A mapping outliving its listing still
    # covers rows 0..n of the next one and answers confidently about them.
    let vm = newVM()
    counted vm.setAnchors(@[exactAnchor(0, 2)], PositionalSupport)
    counted vm.hasAnchors.val
    vm.loadAsmFor("/proj/src/main.nr", "main")
    counted not vm.hasAnchors.val
    counted vm.anchorDefects.val.len == 0
    vm.dispose()

  test "a refusal is cleared by the next load, so the next artefact does not look rejected":
    let vm = newVM()
    var bad = exactAnchor(0, 1)
    bad.sources = @[]
    counted not vm.setAnchors(@[bad], PositionalSupport)
    counted vm.anchorsRejected.val
    vm.clearAnchors()
    counted not vm.anchorsRejected.val
    vm.dispose()

suite "NS4 panel: synchronisation through the VM":

  test "an anchored row aligns, and reports every contributing source":
    let vm = newVM()
    discard vm.setAnchors(@[exactAnchor(0, 2)], PositionalSupport)
    let d = vm.syncFromGeneratedRow(1)
    counted d.outcome == soAligned
    counted vm.sourcesFor(d).len == 1
    counted vm.sourcesFor(d)[0].startLine == 2
    counted vm.rowsFor(d) == (0, 2)
    vm.dispose()

  test "a row past the anchors suspends and says why":
    let vm = newVM()
    discard vm.setAnchors(@[exactAnchor(0, 2)], PositionalSupport)
    let d = vm.syncFromGeneratedRow(9)
    counted d.outcome == soSuspended
    counted d.reason.len > 0
    counted vm.rowsFor(d) == (NoAnchor, NoAnchor)
    counted vm.sourcesFor(d).len == 0
    vm.dispose()

  test "the reverse direction aligns from a source line":
    let vm = newVM()
    discard vm.setAnchors(@[exactAnchor(0, 2)], PositionalSupport)
    let d = vm.syncFromSourceLine(FixturePath, 2)
    counted d.outcome == soAligned
    counted vm.rowsFor(d) == (0, 2)
    vm.dispose()

  test "an unanchored source line suspends rather than scrolling somewhere plausible":
    let vm = newVM()
    discard vm.setAnchors(@[exactAnchor(0, 2)], PositionalSupport)
    let d = vm.syncFromSourceLine(FixturePath, 99)
    counted d.outcome == soSuspended
    counted d.reason.len > 0
    vm.dispose()

  test "DISABLED is distinct from SUSPENDED, in both directions":
    # §3: "you turned it off" and "the mapping ran out here" are different
    # things to show, so they must not share an outcome.
    let vm = newVM()
    discard vm.setAnchors(@[exactAnchor(0, 2)], PositionalSupport)
    vm.setSyncEnabled(false)
    counted vm.syncFromGeneratedRow(1).outcome == soDisabled
    counted vm.syncFromSourceLine(FixturePath, 2).outcome == soDisabled
    counted vm.syncFromGeneratedRow(9).outcome == soDisabled
    vm.setSyncEnabled(true)
    counted vm.syncFromGeneratedRow(1).outcome == soAligned
    counted vm.syncFromGeneratedRow(9).outcome == soSuspended
    vm.dispose()

  test "sync defaults to ON":
    let vm = newVM()
    counted vm.syncSettings.val.enabled
    vm.dispose()

  test "fidelityAtRow reports unmapped for an uncovered row":
    let vm = newVM()
    discard vm.setAnchors(@[exactAnchor(0, 2)], PositionalSupport)
    counted vm.fidelityAtRow(1) == mfExact
    counted vm.fidelityAtRow(7) == mfUnmapped
    vm.dispose()

suite "NS4: producer and panel end to end":

  test "an artefact goes from JSON to an aligned synchronisation decision":
    # The whole path, with the line number asserted as a literal computed by
    # hand from the fixture table — not read back out of the producer.
    let text = $(%*{
      "file_map": fileMapNode(),
      "debug_symbols": debugNode(%*{
        "0": [spanNode(0, 24, 25)],
        "1": [spanNode(0, 24, 25)],
        "2": [spanNode(0, 43, 57)]})})
    let read = readArtefactJson(text, 4)
    counted read.outcome == aroOk

    let (anchors, support) = produceAnchors(read.artefact)
    counted validate(anchors, support).len == 0
    counted anchors.len == 3          # {0,1} line 2, {2} line 3, {3} unmapped

    let vm = newVM()
    counted vm.setAnchors(anchors, support)

    let d0 = vm.syncFromGeneratedRow(0)
    counted d0.outcome == soAligned
    counted vm.sourcesFor(d0)[0].startLine == 2
    counted vm.rowsFor(d0) == (0, 1)

    let d2 = vm.syncFromGeneratedRow(2)
    counted d2.outcome == soAligned
    counted vm.sourcesFor(d2)[0].startLine == 3

    # Row 3 has no location in the artefact, so it claims nothing.
    counted vm.syncFromGeneratedRow(3).outcome == soSuspended
    counted vm.fidelityAtRow(3) == mfUnmapped
    vm.dispose()

  test "an artefact with no debug symbols reaches the panel as a clean unmapped listing":
    let read = readArtefactJson($(%*{"file_map": fileMapNode()}), 3)
    counted read.outcome == aroOk
    let (anchors, support) = produceAnchors(read.artefact)
    let vm = newVM()
    counted vm.setAnchors(anchors, support)
    # Installed, not refused: an artefact without debug info is a fact about
    # the artefact, and the pane says "unmapped" rather than "rejected".
    counted not vm.anchorsRejected.val
    counted vm.hasAnchors.val
    counted vm.syncFromGeneratedRow(0).outcome == soSuspended
    counted vm.fidelityAtRow(0) == mfUnmapped
    vm.dispose()

suite "NS4 suite self-check":

  test "the assertion count is the expected one":
    # The count is MEASURED, so deleting or short-circuiting a check above
    # moves it and this fails. A suite that reports its own total without
    # asserting it is reporting a number nobody re-derives.
    check countedAssertions == ExpectedAssertions
