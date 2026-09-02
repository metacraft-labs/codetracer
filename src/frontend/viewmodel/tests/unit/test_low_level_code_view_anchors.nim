## NS4 — the anchoring model REACHES THE SCREEN.
##
## `GUI/Debugging-Features/Generated-Code-Listing.md` §0a.2 (GCL-F1), §9.4,
## §10 (GCL-A7, GCL-A8).
##
## LANE: `vm-unit` AND `vm-unit-js`. Mock renderer only — the Web arm is
## asserted by a real browser, because a mock-only suite is green over a surface
## nobody sees (`Verification-Harness-Traps.md` trap 3). See the commit message
## for the browser measurement.
##
## Compile and run:
##   nim c  -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_low_level_code_view_anchors.nim
##   nim js -r -d:nodejs --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_low_level_code_view_anchors.nim
##
## ## WHY THIS SUITE EXISTS
##
## GCL-F1: the anchoring model landed with 336 counted assertions and
## `isonim_low_level_code_view.nim` read NONE of it. Not a bug in the model — a
## correct model with no consumer. Every assertion below is of the form "a
## property the VM already computes correctly is VISIBLE", and every one of them
## would have failed against the view as it stood.
##
## The distinction that matters most here is the one the model went to the
## trouble of encoding and the view collapsed: `soDisabled` ("you turned it
## off"), `soSuspended` ("the mapping ran out") and a REFUSED producer output
## are three different things, and `anchorsRejected` is deliberately not
## `not hasAnchors`.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation]
import isonim/testing/mock_dom
import isonim/viewmodel

import ../../backend/mock_backend
import ../../store/replay_data_store
import ../../store/types
import ../../viewmodels/generated_code_anchors
import ../../viewmodels/low_level_code_vm
import ../../views/isonim_low_level_code_view

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 46

# ---------------------------------------------------------------------------

proc newStore(): ReplayDataStore =
  let mock = newMockBackendService(autoRespond = true)
  createReplayDataStore(mock.toBackendService())

proc instr(offset: int; name: string; line = 0): LowLevelInstruction =
  LowLevelInstruction(name: name, args: "", other: "", offset: offset,
                      highLevelPath: (if line > 0: "src/main.nr" else: ""),
                      highLevelLine: line)

proc region(line: int): SourceRegion =
  SourceRegion(path: "src/main.nr", startLine: line, endLine: line)

const PositionalSupport = ArtefactSupport(
  hasSourcePositions: true, hasSourceRegions: true,
  hasInliningRecords: true, marksCompilerGenerated: false)

proc hasClass(node: MockNode; className: string): bool =
  ## WHOLE-WORD class match. A substring match would conflate
  ## `low-level-code-instruction` with `low-level-code-instruction-offset`,
  ## and every row count below would be five times too large.
  for part in node.attributes.getOrDefault("class", "").split(' '):
    if part == className:
      return true
  false

proc findAll(node: MockNode; className: string; acc: var seq[MockNode]) =
  if node.kind == mnkElement and node.hasClass(className):
    acc.add node
  for child in node.children:
    findAll(child, className, acc)

proc findAll(node: MockNode; className: string): seq[MockNode] =
  result = @[]
  findAll(node, className, result)

proc textOf(node: MockNode; className: string): string =
  let hits = findAll(node, className)
  if hits.len == 0: "" else: hits[0].textContent

proc classOf(node: MockNode; className: string): string =
  let hits = findAll(node, className)
  if hits.len == 0: "" else: hits[0].attributes.getOrDefault("class", "")

# ---------------------------------------------------------------------------

suite "NS4 view: fidelity reaches the rows (GCL-A7)":

  test "gcl_a7_every_row_carries_its_own_fidelity_and_the_counts_match":
    # The model already answers `fidelityAtRow` correctly for every row. This
    # asserts the ANSWER IS ON SCREEN, per row, and that the number of rows
    # carrying each rung equals what the model says.
    #
    # WHY COUNTS AND NOT "AT LEAST ONE UNMAPPED ROW". A view that stamped
    # `unmapped` on every row would satisfy an existence check and be a total
    # loss of information. Three rungs, three counts.
    let vm = createLowLevelCodeVM(newStore())
    defer: vm.dispose()
    vm.setInstructions(@[instr(0, "ASSERT", 9), instr(1, "ASSERT", 9),
                         instr(2, "RANGE", 10), instr(3, "BRILLIG"),
                         instr(4, "BRILLIG")])
    counted vm.setAnchors(@[
      MappingAnchor(generatedFirst: 0, generatedLast: 1, fidelity: mfExact,
                    sources: @[region(9)],
                    count: ExecutedCount(provenance: cpNone)),
      MappingAnchor(generatedFirst: 2, generatedLast: 2, fidelity: mfMerged,
                    sources: @[region(10), region(3)],
                    count: ExecutedCount(provenance: cpNone)),
    ], PositionalSupport)

    let r = MockRenderer()
    let panel = renderLowLevelCodePanel(r, vm)

    let rows = findAll(panel, "low-level-code-instruction")
    counted rows.len == 5

    var exact, merged, unmapped = 0
    for row in rows:
      let badge = textOf(row, "low-level-code-instruction-fidelity")
      counted badge.len > 0        # every row says SOMETHING
      case badge
      of "exact": inc exact
      of "merged": inc merged
      of "unmapped": inc unmapped
      else: discard

    # Rows 0,1 exact; row 2 merged; rows 3,4 are past the anchors -> unmapped.
    counted exact == 2
    counted merged == 1
    counted unmapped == 2
    # And they agree with the model rather than with each other.
    counted vm.fidelityAtRow(0) == mfExact
    counted vm.fidelityAtRow(2) == mfMerged
    counted vm.fidelityAtRow(4) == mfUnmapped

  test "gcl_a7_control_with_no_anchors_every_row_reads_unmapped":
    # The control for the above: if the counts came from somewhere other than
    # the anchors, this would not go all-unmapped.
    let vm = createLowLevelCodeVM(newStore())
    defer: vm.dispose()
    vm.setInstructions(@[instr(0, "ASSERT", 9), instr(1, "RANGE", 10)])
    let r = MockRenderer()
    let panel = renderLowLevelCodePanel(r, vm)
    for row in findAll(panel, "low-level-code-instruction"):
      counted textOf(row, "low-level-code-instruction-fidelity") == "unmapped"

suite "NS4 view: a count is never a bare zero (GCL-D3)":

  test "cpnone_renders_no_count_column_at_all":
    # A rendered `0` would read as "never ran" — a measurement the pane did not
    # make. `countLabel` returns "" for `cpNone`, and the row must then omit the
    # span rather than emit an empty one.
    let vm = createLowLevelCodeVM(newStore())
    defer: vm.dispose()
    vm.setInstructions(@[instr(0, "ASSERT", 9)])
    counted vm.setAnchors(@[
      MappingAnchor(generatedFirst: 0, generatedLast: 0, fidelity: mfExact,
                    sources: @[region(9)],
                    count: ExecutedCount(value: 0, provenance: cpNone)),
    ], PositionalSupport)
    let r = MockRenderer()
    let panel = renderLowLevelCodePanel(r, vm)
    counted findAll(panel, "low-level-code-instruction-count").len == 0

  test "an_executed_count_renders_and_an_approximate_one_is_distinguishable":
    # The positive twin, and §7's requirement that an inverted count be
    # LABELLED approximate — the two must not be confusable at a glance,
    # because the pane's whole commercial argument is that its numbers are
    # facts about the run.
    let vm = createLowLevelCodeVM(newStore())
    defer: vm.dispose()
    vm.setInstructions(@[instr(0, "ASSERT", 9), instr(1, "RANGE", 10)])
    counted vm.setAnchors(@[
      MappingAnchor(generatedFirst: 0, generatedLast: 0, fidelity: mfExact,
                    sources: @[region(9)],
                    count: ExecutedCount(value: 1024, provenance: cpExecuted)),
      MappingAnchor(generatedFirst: 1, generatedLast: 1, fidelity: mfExact,
                    sources: @[region(10)],
                    count: ExecutedCount(value: 1024,
                                         provenance: cpApproximate)),
    ], PositionalSupport)
    let r = MockRenderer()
    let panel = renderLowLevelCodePanel(r, vm)
    let counts = findAll(panel, "low-level-code-instruction-count")
    counted counts.len == 2
    counted counts[0].textContent == "×1024"
    counted counts[1].textContent == "≈×1024"
    counted counts[0].textContent != counts[1].textContent

suite "NS4 view: the three not-aligned states are told apart (GCL-A8, §9.4)":

  test "gcl_a8_off_and_ran_out_and_refused_render_three_different_texts":
    # The distinction the model encodes and the view used to discard.
    let vm = createLowLevelCodeVM(newStore())
    defer: vm.dispose()
    vm.setInstructions(@[instr(0, "ASSERT", 9)])

    # 1. ALIGNED — anchors installed, sync on. No notice at all.
    counted vm.setAnchors(@[
      MappingAnchor(generatedFirst: 0, generatedLast: 0, fidelity: mfExact,
                    sources: @[region(9)],
                    count: ExecutedCount(provenance: cpNone)),
    ], PositionalSupport)
    let aligned = mappingNotice(vm)
    counted aligned == ""
    counted "hidden" in noticeClass(vm)

    # 2. DISABLED — "you turned it off".
    vm.setSyncEnabled(false)
    let disabled = mappingNotice(vm)
    counted disabled.len > 0
    counted "notice-disabled" in noticeClass(vm)
    vm.setSyncEnabled(true)

    # 3. REFUSED — the producer emitted a mapping `validate` rejects. NOT the
    # same as having no mapping, which is why `anchorsRejected` exists.
    let bad = MappingAnchor(generatedFirst: 0, generatedLast: 0,
                            fidelity: mfExact,
                            sources: @[region(9), region(10)],
                            count: ExecutedCount(provenance: cpNone))
    counted not vm.setAnchors(@[bad], PositionalSupport)
    let refused = mappingNotice(vm)
    counted refused.len > 0
    counted "notice-refused" in noticeClass(vm)

    # 4. SUSPENDED — a clean artefact that simply carries no mapping.
    vm.clearAnchors()
    let suspended = mappingNotice(vm)
    counted suspended.len > 0
    counted "notice-suspended" in noticeClass(vm)

    # THE ASSERTION THIS CASE EXISTS FOR: all three are DIFFERENT, and none is
    # the empty aligned state. Pairwise, because "not equal to one of them"
    # would be satisfied by two of the three collapsing.
    counted disabled != refused
    counted disabled != suspended
    counted refused != suspended
    counted aligned != disabled

  test "the_notice_is_rendered_into_the_header_not_merely_computed":
    # `mappingNotice` being right is not the property. Its text being IN THE
    # DOM is — GCL-F1 is precisely a correct function nobody called.
    let vm = createLowLevelCodeVM(newStore())
    defer: vm.dispose()
    vm.setInstructions(@[instr(0, "ASSERT", 9)])
    vm.setSyncEnabled(false)
    let r = MockRenderer()
    let panel = renderLowLevelCodePanel(r, vm)
    let notice = findAll(panel, "low-level-code-notice")
    counted notice.len == 1
    counted notice[0].textContent == mappingNotice(vm)
    counted notice[0].textContent.len > 0

suite "NS4 view: the sync toggle has a visible state (§3, §9.4)":

  test "the_toggle_renders_its_state_and_flipping_it_changes_the_text":
    # §3: "unlocking is a deliberate act with a visible state." The model
    # provided `DefaultSyncSettings.enabled` and `setSyncEnabled`; nothing drew
    # them.
    let vm = createLowLevelCodeVM(newStore())
    defer: vm.dispose()
    let r = MockRenderer()
    let panel = renderLowLevelCodePanel(r, vm)

    counted vm.syncSettings.val.enabled          # defaults ON, per §3
    let onText = textOf(panel, "low-level-code-sync")
    counted onText.len > 0
    counted "sync-on" in classOf(panel, "low-level-code-sync")

    vm.setSyncEnabled(false)
    let offText = textOf(panel, "low-level-code-sync")
    counted offText.len > 0
    # The text CHANGED. A toggle whose label is constant has no visible state,
    # which is the failure §3 is guarding against.
    counted offText != onText
    counted "sync-off" in classOf(panel, "low-level-code-sync")

    # And it is reactive rather than snapshotted: back on, back to the first.
    vm.setSyncEnabled(true)
    counted textOf(panel, "low-level-code-sync") == onText

suite "NS4 view suite self-check":

  test "low_level_code_view_anchors_assertion_count_is_measured":
    check countedAssertions == ExpectedAssertions
