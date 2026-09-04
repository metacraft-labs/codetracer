## constraints_listing_browser_probe.nim — mount the CONSTRAINTS pane in a REAL
## browser, from a REAL compiler's listing, and let a probe read what painted.
##
## ## WHY THIS EXISTS
##
## The pane's headless suites drive the MOCK renderer. The Web renderer is a
## separate code path in the same file — `renderFunctionWeb` and
## `renderOpcodeWeb` are not the procedures `test_noir_live_constraints`
## exercises — and a mock-only suite is green over a surface nobody sees
## (`Verification-Harness-Traps.md` trap 3). This is the same argument, and the
## same shape, as `low_level_code_browser_probe.nim` beside it.
##
## It also answers the question the goal was closed against without: **does a
## user see the generated code?** A count of rows in a ViewModel is not that.
## Painted text is.
##
## ## THE FIXTURE IS THE COMPILER'S
##
## `TemplateAcirListing` is `VfsResponse.acir_listing` VERBATIM, as emitted by
## `noir_wasm.wasm` (15,909,481 bytes) over its own `nv_compile_vfs` against the
## bundled template — the same bytes `test_noir_live_constraints` pins. Nothing
## here is hand-written, so what paints is what the compiler printed.
##
## Build (browser target — NOT -d:nodejs, which would ship a node build):
##   nim js -d:ctWeb --hints:off -o:<out>/probe.js \
##     ci/test/constraints_listing_browser_probe.nim

import std/strutils

import isonim/core/[signals, computation]
import isonim/web/dom_api as dom

import ../../src/common/noir_constraints
import ../../src/frontend/viewmodel/viewmodels/constraints_vm
import ../../src/frontend/viewmodel/views/isonim_constraints_view

# `VfsResponse.acir_listing`, verbatim. Four header lines then 17 opcode rows,
# then the two Brillig functions the template's `assert` lowers to.
const TemplateAcirListing = """func 0
private parameters: [w0]
public parameters: [w1]
return values: []
BRILLIG CALL func: 0, predicate: 1, inputs: [w0 - w1], outputs: [w2]
ASSERT 0 = w0*w2 - w1*w2 - 1
BRILLIG CALL func: 1, predicate: 1, inputs: [w0, 4294967296], outputs: [w3, w4]
BLACKBOX::RANGE input: w3, bits: 222
BLACKBOX::RANGE input: w4, bits: 32
ASSERT w4 = w0 - 4294967296*w3
ASSERT w5 = -w3 + 5096253676302562286669017222071363378443840053029366383258766538131
BLACKBOX::RANGE input: w5, bits: 222
BRILLIG CALL func: 0, predicate: 1, inputs: [-w3 + 5096253676302562286669017222071363378443840053029366383258766538131], outputs: [w6]
ASSERT w7 = w3*w6 - 5096253676302562286669017222071363378443840053029366383258766538131*w6 + 1
ASSERT 0 = -w3*w7 + 5096253676302562286669017222071363378443840053029366383258766538131*w7
ASSERT w8 = w4*w7 + 268435455*w7
BLACKBOX::RANGE input: w8, bits: 32
BRILLIG CALL func: 1, predicate: 1, inputs: [w4 + 4294967168, 4294967296], outputs: [w9, w10]
BLACKBOX::RANGE input: w10, bits: 32
ASSERT w10 = w4 - 4294967296*w9 + 4294967168
ASSERT w9 = 0

unconstrained func 0: directive_invert
0: @21 = const u32 1
1: @20 = const u32 0
2: @0 = calldata copy [@20; @21]
3: @2 = const field 0
4: @3 = field eq @0, @2
5: jump if @3 to 8
6: @1 = const field 1
7: @0 = field field_div @1, @0
8: stop @[@20; @21]
unconstrained func 1: directive_integer_quotient
0: @10 = const u32 2
1: @11 = const u32 0
2: @0 = calldata copy [@11; @10]
3: @2 = field int_div @0, @1
4: @1 = field mul @2, @1
5: @1 = field sub @0, @1
6: @0 = @2
7: stop @[@11; @10]"""

# What the BUNDLE ships, and what the live site is therefore showing: totals
# from `nargo info`, which prints no opcodes at all. Mounted beside the listing
# so a reader can see the two states side by side — the pane as it is today,
# and the pane as this change makes it.
const TemplateNargoInfo = """{"programs":[{"package_name":"hello_noir","functions":[{"name":"main","opcodes":17}],"unconstrained_functions":[{"name":"directive_invert","opcodes":9},{"name":"directive_integer_quotient","opcodes":8}]}]}"""

proc mountInto(containerId: string; report: ConstraintReport) =
  let container = dom.getElementById(dom.document, cstring(containerId))
  let vm = createConstraintsVM()
  vm.setReport(report)
  mountIsoNimConstraintsPanel(container, vm)

proc main() =
  # THE COMPILE'S OWN LISTING — what the pane shows after this change.
  mountInto("ct-listing-pane",
    reportFromAcirListing(TemplateAcirListing, "hello_noir",
                          "compiled in this tab at 14:22:07"))

  # THE BUNDLE'S TOTALS — what the live site shows today, plus the caption
  # that now says which of the two answers it is holding.
  mountInto("ct-counts-pane",
    parseNargoInfoJson(TemplateNargoInfo,
      "Measured by compiling the project."))

  # A SUCCESSFUL BUILD ON AN ENGINE THAT PRINTS NO LISTING. This is the state
  # every build on the current deploy pin lands in, and the one that used to
  # replace the whole pane with the word "unavailable".
  let vm = createConstraintsVM()
  vm.setReport(parseNargoInfoJson(TemplateNargoInfo,
    "Measured by compiling the project."))
  vm.noteListingUnavailable(
    "This build's Noir compiler does not print a constraint listing, so " &
    "the generated code cannot be shown for what it just compiled.")
  let degraded = dom.getElementById(dom.document, cstring"ct-degraded-pane")
  mountIsoNimConstraintsPanel(degraded, vm)

  # A machine-readable line beside the painted DOM, so a probe can tell "the
  # pane painted the wrong thing" from "the fixture never loaded".
  let listing = reportFromAcirListing(
    TemplateAcirListing, "hello_noir", "compiled in this tab")
  let summary = dom.getElementById(dom.document, cstring"ct-probe-summary")
  dom.appendChild(dom.Node(summary), dom.createTextNode(dom.document, cstring(
    "functions=" & $listing.functions.len &
    " rows=" & $listing.totalRows() &
    " acir=" & $listing.acirTotal() &
    " unconstrained=" & $listing.unconstrainedTotal() &
    " hasListing=" & $listing.hasListing())))

main()
