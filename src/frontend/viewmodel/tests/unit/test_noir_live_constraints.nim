## The counts the pane COMPUTES, against the artefacts a real compiler produced.
##
## `Generated-Code-Listing.md` §15.4 records why this suite exists. The web pane
## shipped a compile-time `nargo info` constant because a browser has no
## `nargo`. That constant was measured by the NATIVE toolchain and rendered by
## the WEB engine — 3,699 commits apart in the ACIR-generating paths — so it was
## wrong by two opcodes for every visitor, while a gate comparing it against the
## wrong `nargo` certified it as correct. There is no correct constant to write
## while one compiler measures the number and another renders it.
##
## So the counts are taken from the compile the pane is describing, and this
## suite pins that against MEASURED artefacts rather than invented ones.
##
## ## Provenance of the fixtures, because a fixture that was never produced by a
## ## compiler tests only itself
##
## `TemplateAcirListing` is `VfsResponse.acir_listing` **verbatim**, read out of
## the wasm module (`noir_wasm.wasm`, 15,909,481 bytes) driven over its real
## `nv_compile_vfs` entry point with `mode: "program"` on the bundled template,
## on 2026-09-02. It is the browser's own compiler answering, not `nargo`.
##
## The numbers asserted below were cross-checked three ways on that same
## compiler — `nargo info` total, `--print-acir` rows, and `acir_locations`
## entries — and all three said 17. The same three said 15 under the flake pin's
## older compiler. The IDENTITY is what this suite pins; the VALUE moves with
## the pin and is deliberately not asserted anywhere outside this file.

import std/[json, strutils]
import std/unittest

import ../../../../common/noir_constraints
import ../../viewmodels/constraints_vm

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

proc denseLocations(n: int): JsonNode =
  result = newJObject()
  for i in 0 ..< n:
    result[$i] = %i

suite "Live constraints — the pane computes what it compiled":

  test "live_the_listing_row_count_is_the_opcode_count_nargo_info_reports":
    # THE IDENTITY, pinned. `nargo info` reported main: 17 opcodes for this
    # program on the same compiler that printed this listing, and the listing
    # has 17 opcode rows, because they count the same thing. This is the whole
    # of §15.3, and it is what makes the constant unnecessary rather than
    # merely wrong.
    let report = reportFromAcirListing(
      TemplateAcirListing, "hello_noir", "compiled here")
    check report.absence.len == 0
    check report.acirTotal() == 17

  test "live_the_four_header_lines_are_not_counted_as_opcodes":
    # GCL-D6. `func 0`, `private parameters:`, `public parameters:` and
    # `return values:` precede the opcodes. Counting them would give 21 and
    # still look exactly like an opcode count — wrong by a constant is the
    # most plausible failure available here.
    let report = reportFromAcirListing(
      TemplateAcirListing, "hello_noir", "compiled here")
    check report.acirTotal() != 21
    check report.acirTotal() == 17

  test "live_unconstrained_functions_keep_their_names_and_their_own_counts":
    # The listing answers the Brillig half too, and `nargo info` reports
    # exactly these two names with exactly these two counts for this program.
    # So the listing replaces `nargo info` entirely rather than partly.
    let report = reportFromAcirListing(
      TemplateAcirListing, "hello_noir", "compiled here")
    var byName: seq[(string, int)] = @[]
    for fn in report.functions:
      if fn.kind == cfkUnconstrained:
        byName.add (fn.name, fn.opcodes)
    check byName.len == 2
    check byName[0] == ("directive_invert", 9)
    check byName[1] == ("directive_integer_quotient", 8)
    check report.unconstrainedTotal() == 17

  test "live_the_two_currencies_are_still_never_summed":
    # 17 ACIR and 17 unconstrained is a COINCIDENCE on this program, and it is
    # the most dangerous shape available for a test of this: a total that
    # summed across the kinds would read 34, and one that returned either half
    # would read 17 and look right. Both are checked.
    let report = reportFromAcirListing(
      TemplateAcirListing, "hello_noir", "compiled here")
    check report.acirTotal() == 17
    check report.unconstrainedTotal() == 17
    check report.acirTotal() + report.unconstrainedTotal() == 34
    check headlineFor(report).contains("17 ACIR opcodes")
    check headlineFor(report).contains("17 unconstrained")

  test "live_the_provenance_names_the_compile_and_is_carried_onto_the_report":
    # GCL-D10: the provenance must name the compile, not a command. The report
    # carries whatever the caller measured, so the pane can say WHICH compile.
    let report = reportFromAcirListing(
      TemplateAcirListing, "hello_noir",
      "compiled in this tab by noir_wasm.wasm @ fd96a7d4")
    check report.provenance.contains("fd96a7d4")
    check not report.provenance.contains("build time")

  test "live_an_empty_listing_is_a_stated_absence_and_never_a_zero":
    # A compile with no listing must not render as "0 ACIR opcodes", which is
    # a confident wrong answer about a circuit that exists.
    let report = reportFromAcirListing("", "hello_noir", "compiled here")
    check report.absence.len > 10
    check not report.hasCounts()

  test "live_a_dense_debug_map_counts_and_a_sparse_one_refuses":
    # The fallback for a module older than `acir_listing`. `acir_locations` is
    # a MAP and permits gaps; a gap makes `len` the count of ATTRIBUTABLE
    # opcodes, which is smaller than the circuit and looks identical to the
    # right answer. Density is therefore checked, not assumed.
    let dense = %*{"debug_infos": [{"acir_locations": denseLocations(17)}]}
    let readDense = acirCountFromDebugInfo(dense)
    check readDense.ok
    check readDense.count == 17

    # The same map with opcode 7 unlocated: 16 entries numbered 0..16 skipping
    # 7. Counting keys would answer 16 — plausible, and wrong.
    var holed = newJObject()
    for i in 0 .. 16:
      if i != 7: holed[$i] = %i
    let sparse = %*{"debug_infos": [{"acir_locations": holed}]}
    let readSparse = acirCountFromDebugInfo(sparse)
    check not readSparse.ok
    check readSparse.count == 0
    check readSparse.reason.contains("7")

  test "live_the_legacy_locations_spelling_is_still_counted":
    # Compilers before the call-stack tree emit `locations`. The flake pin's
    # own `nargo` still does, and it was measured dense at 15 on this template.
    let legacy = %*{"debug_infos": [{"locations": denseLocations(15)}]}
    let read = acirCountFromDebugInfo(legacy)
    check read.ok
    check read.count == 15

  test "live_a_debug_mode_artefact_reports_zero_rather_than_faulting":
    # MEASURED through the wasm module: `mode: "debug"` sets `force_brillig`
    # and yields ZERO located ACIR opcodes (GCL-D9). That is a true fact about
    # that artefact, not a protocol fault, so it is reported as a count of
    # zero and the caller decides what to say about it.
    let debugArtefact = %*{"debug_infos": [{"acir_locations": newJObject()}]}
    let read = acirCountFromDebugInfo(debugArtefact)
    check read.ok
    check read.count == 0

  test "live_an_unreadable_debug_node_is_an_absence_not_a_zero":
    check not acirCountFromDebugInfo(nil).ok
    check not acirCountFromDebugInfo(newJArray()).ok
    check acirCountFromDebugInfo(nil).reason.len > 10
