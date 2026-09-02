## low_level_code_browser_probe.nim — mount the Low Level Code pane in a REAL
## browser, from REAL compiler output, and let a probe read what was painted.
##
## WHY THIS EXISTS
##
## `Generated-Code-Listing.md` §0a.2 is a record of a capability that was
## present, correct, tested and unreachable. The headless suites
## (`test_low_level_code_view_anchors`) assert the Mock renderer; the Web
## renderer is a SEPARATE code path in the same file, and a mock-only suite is
## green over a surface nobody sees — `Verification-Harness-Traps.md` trap 3.
##
## So this builds the WEB arm, with `nim js` and no `-d:nodejs`, mounts it into
## a real DOM, and paints. `web_renderer_probe.mjs` (or any browser) then reads
## `document.body.innerText`, which is the artefact — not a `success: true`.
##
## The data is not invented. `DebugSymbolsJson` is verbatim `nargo compile`
## output (nargo 1.0.0-beta.26 / noirc 906af2f4) against the bundled template,
## base64-decoded and raw-inflated; the listing rows are the corresponding
## `nargo compile --print-acir` text. So what paints is what the compiler said.
##
## Build (browser target — NOT -d:nodejs, which would ship a node build):
##   nim js -d:ctWeb --hints:off -o:<out>/probe.js \
##     ci/test/low_level_code_browser_probe.nim

import std/[json, strutils]

import isonim/core/[signals, computation]
import isonim/web/dom_api as dom

import ../../src/frontend/viewmodel/backend/mock_backend
import ../../src/frontend/viewmodel/store/replay_data_store
import ../../src/frontend/viewmodel/store/types
import ../../src/frontend/viewmodel/viewmodels/generated_code_anchors
import ../../src/frontend/viewmodel/viewmodels/low_level_code_vm
import ../../src/frontend/viewmodel/viewmodels/noir_anchor_producer
import ../../src/frontend/viewmodel/views/isonim_low_level_code_view

const DebugSymbolsJson = """{"debug_infos":[{"acir_locations":{"0":1,"1":1,"2":3,"3":3,"4":3,"5":3,"6":3,"7":3,"8":3,"9":3,"10":3,"11":3,"12":3,"13":4,"14":4,"15":4,"16":5},"location_tree":{"locations":[{"parent":null,"value":{"span":{"start":0,"end":0},"file":0}},{"parent":0,"value":{"span":{"start":263,"end":277},"file":52}},{"parent":0,"value":{"span":{"start":283,"end":308},"file":52}},{"parent":2,"value":{"span":{"start":205,"end":217},"file":54}},{"parent":2,"value":{"span":{"start":205,"end":230},"file":54}},{"parent":2,"value":{"span":{"start":198,"end":231},"file":54}}]},"brillig_locations":{}}]}"""

const MainSource = """mod tests;
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

const UtilsSource = """// A second module, because a Noir project is a directory tree and a
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

const AcirListing = """BRILLIG CALL func: 0, predicate: 1, inputs: [w0 - w1], outputs: [w2]
ASSERT 0 = w0*w2 - w1*w2 - 1
BRILLIG CALL func: 1, predicate: 1, inputs: [w0, 4294967296], outputs: [w3, w4]
BLACKBOX::RANGE input: w3, bits: 222
BLACKBOX::RANGE input: w4, bits: 32
ASSERT w4 = w0 - 4294967296*w3
ASSERT w5 = -w3 + 50962536763025622866690172220713633784438400530293663832587665381
BLACKBOX::RANGE input: w5, bits: 222
BRILLIG CALL func: 0, predicate: 1, inputs: [-w3 + 5096253676302562286669017], outputs: [w6]
ASSERT w7 = w3*w6 - 5096253676302562286669017222071363378443840053029366383*w6 + 1
ASSERT 0 = -w3*w7 + 509625367630256228666901722207136337844384005302936638325876653*w7
ASSERT w8 = w4*w7 + 268435455*w7
BLACKBOX::RANGE input: w8, bits: 32
BRILLIG CALL func: 1, predicate: 1, inputs: [w4 + 4294967168, 4294967296], outputs: [w9, w10]
BLACKBOX::RANGE input: w10, bits: 32
ASSERT w10 = w4 - 4294967296*w9 + 4294967168
ASSERT w9 = 0"""

proc fileMapNode(): JsonNode =
  %*{
    "52": {"path": "src/main.nr", "source": MainSource},
    "54": {"path": "src/utils.nr", "source": UtilsSource},
  }

proc listingRows(): seq[LowLevelInstruction] =
  ## One row per ACIR opcode, in opcode order. GCL-D6: `nargo`'s four header
  ## lines (`func 0`, the parameter lists, `return values`) are NOT rows — an
  ## anchor's range is an opcode index, so including them would put every
  ## anchor four rows out.
  result = @[]
  var i = 0
  for line in AcirListing.splitLines():
    if line.strip().len == 0: continue
    let parts = line.split(' ', 1)
    result.add LowLevelInstruction(
      name: parts[0],
      args: (if parts.len > 1: parts[1] else: ""),
      other: "",
      offset: i,
      highLevelPath: "",
      highLevelLine: 0)
    inc i

proc main() =
  let mock = newMockBackendService(autoRespond = true)
  let vm = createLowLevelCodeVM(createReplayDataStore(mock.toBackendService()))

  let rows = listingRows()
  vm.setInstructions(rows)
  vm.setNoirProject(true)

  let read = readArtefact(fileMapNode(), parseJson(DebugSymbolsJson), rows.len)
  let (anchors, support) = produceAnchors(read.artefact)
  let installed = vm.setAnchors(anchors, support)

  # Mount into a container the page already has, so nothing depends on a
  # `document.body` accessor the isonim DOM shim does not expose.
  let container = dom.getElementById(dom.document, cstring"ct-probe-root")
  mountIsoNimLowLevelCode(container, vm)

  # A machine-readable line beside the painted DOM, so a probe can tell "the
  # pane painted the wrong thing" from "the fixture never loaded".
  let summary = dom.getElementById(dom.document, cstring"ct-probe-summary")
  dom.appendChild(dom.Node(summary), dom.createTextNode(dom.document, cstring(
    "rows=" & $rows.len &
    " anchors=" & $anchors.len &
    " installed=" & $installed &
    " ceiling=" & label(claimCeiling(support)) &
    " located=" & $read.artefact.locatedOpcodeCount())))

main()
