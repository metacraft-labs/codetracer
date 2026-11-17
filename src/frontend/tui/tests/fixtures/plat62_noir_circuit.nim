## fixtures/plat62_noir_circuit.nim — PLAT-62: the real Noir crate every
## Constraints pane suite measures, on every front-end.
##
## A library the suites import, not a suite. Pure constants, so the ViewModel
## suites can read it on every backend (C, JavaScript, WASM); the native
## suites write it to disk with `writePlat62Circuit` (`plat62_circuit_disk`),
## and the desktop's Electron capture writes the same bytes
## (`src/tests/gui/tests/constraints-pane/plat62-constraints-capture.spec.ts`).
##
## The crate is shaped so each of the pane's four kinds of row is present
## with a distinct answer:
##
##   * `main` — the circuit's ACIR function, declared at `src/main.nr:3`;
##   * `halve` — a user `unconstrained fn` the circuit calls, a Brillig
##     function declared at `src/main.nr:11`;
##   * `directive_invert` and `directive_integer_quotient` — Brillig
##     functions the COMPILER generated (for `x != y` and the division), which
##     no source declares;
##   * `checks::in_range` — a function in another file that `nargo info` does
##     not name at all, because Noir inlines it into `main`.
##
## NO MOCK: a real crate. `Plat62InfoOutput` and `Plat62DebugSymbols` are what
## the pinned `nargo info --json --print-acir` printed for it and left in
## `target/` (nargo 1.0.0-beta.26); the native suites run the real `nargo` and
## assert it still prints exactly this, so the constants cannot drift from the
## toolchain silently.

const
  Plat62PackageName* = "plat62_circuit"
  Plat62NargoToml* =
    "[package]\nname = \"" & Plat62PackageName & "\"\ntype = \"bin\"\n" &
    "authors = [\"\"]\n\n[dependencies]\n"
  Plat62MainNr* = """mod checks;

fn main(x: Field, y: pub Field) {
    assert(x != y);
    // Safety: the hint is checked right below.
    let half = unsafe { halve(y) };
    assert(half * 2 == y);
    checks::in_range(x);
}

unconstrained fn halve(v: Field) -> Field {
    v / 2
}

#[test]
fn test_main() {
    main(1, 4);
}
"""
  Plat62ChecksNr* = """pub fn in_range(v: Field) {
    assert(v as u8 < 200);
}
"""
  Plat62Files* = [("src/main.nr", Plat62MainNr),
                  ("src/checks.nr", Plat62ChecksNr)]
    ## The crate's sources by project-relative path, in the order a host's
    ## walk reads them (path order).
  Plat62NargoInfoJson* = """{"programs":[{"package_name":"plat62_circuit","functions":[{"name":"main","opcodes":18}],"unconstrained_functions":[{"name":"halve","opcodes":16},{"name":"directive_invert","opcodes":9},{"name":"directive_integer_quotient","opcodes":8}]}]}"""
  Plat62Headline* = "18 ACIR opcodes, 33 unconstrained"
  Plat62Rows* = [
    ("main", "acir", "18", "src/main.nr:3"),
    ("halve", "unconstrained", "16", "src/main.nr:11"),
    ("directive_invert", "unconstrained", "9", ""),
    ("directive_integer_quotient", "unconstrained", "8", "")]
    ## The pane's rows: name, kind, count, where it is declared.
  Plat62MainLine* = 3
  Plat62HalveLine* = 11
  Plat62PrintedListing* = """Compiled ACIR for main:
func 0
private parameters: [w0]
public parameters: [w1]
return values: []
BRILLIG CALL func: 1, predicate: 1, inputs: [w0 - w1], outputs: [w2]
ASSERT 0 = w0*w2 - w1*w2 - 1
BRILLIG CALL func: 0, predicate: 1, inputs: [w1], outputs: [w3]
ASSERT w1 = 2*w3
BRILLIG CALL func: 2, predicate: 1, inputs: [w0, 256], outputs: [w4, w5]
BLACKBOX::RANGE input: w4, bits: 246
BLACKBOX::RANGE input: w5, bits: 8
ASSERT w5 = w0 - 256*w4
ASSERT w6 = -w4 + 85500948718122168836900022442411230814642048439125134155071110103811751936
BLACKBOX::RANGE input: w6, bits: 246
BRILLIG CALL func: 1, predicate: 1, inputs: [-w4 + 85500948718122168836900022442411230814642048439125134155071110103811751936], outputs: [w7]
ASSERT w8 = w4*w7 - 85500948718122168836900022442411230814642048439125134155071110103811751936*w7 + 1
ASSERT 0 = -w4*w8 + 85500948718122168836900022442411230814642048439125134155071110103811751936*w8
ASSERT 0 = w5*w8
BRILLIG CALL func: 2, predicate: 1, inputs: [w5 + 56, 256], outputs: [w10, w11]
BLACKBOX::RANGE input: w11, bits: 8
ASSERT w11 = w5 - 256*w10 + 56
ASSERT w10 = 0

unconstrained func 0: halve
 0: @2 = const u32 1
 1: @1 = const u32 32837
 2: @0 = const u32 69
 3: sp[3] = const u32 1
 4: sp[4] = const u32 0
 5: @67 = calldata copy [sp[4]; sp[3]]
 6: sp[2] = @67
 7: call 12
 8: @68 = sp[2]
 9: sp[3] = const u32 68
10: sp[4] = const u32 1
11: stop @[sp[3]; sp[4]]
12: sp[3] = const field 10944121435919637611123202872628637544274182200208017171849102093287904247809
13: sp[4] = field mul sp[2], sp[3]
14: sp[2] = sp[4]
15: return
unconstrained func 1: directive_invert
0: @21 = const u32 1
1: @20 = const u32 0
2: @0 = calldata copy [@20; @21]
3: @2 = const field 0
4: @3 = field eq @0, @2
5: jump if @3 to 8
6: @1 = const field 1
7: @0 = field field_div @1, @0
8: stop @[@20; @21]
unconstrained func 2: directive_integer_quotient
0: @10 = const u32 2
1: @11 = const u32 0
2: @0 = calldata copy [@11; @10]
3: @2 = field int_div @0, @1
4: @1 = field mul @2, @1
5: @1 = field sub @0, @1
6: @0 = @2
7: stop @[@11; @10]

"""
    ## What `--print-acir` printed for the crate, ahead of the JSON.
  Plat62InfoOutput* = Plat62PrintedListing & Plat62NargoInfoJson
    ## The whole of what `NargoInfoArgs` prints, whitespace at its end aside.
  Plat62CheckFileId = 52
  Plat62MainFileId = 53
  Plat62DebugSymbols* = "nZPdioUgFIXfZV97kZb28yrDEFaegyAWnjowRO8+W80mGIKZbtbK3N92GbsVBtUtz1bbx/iC5mOFzmlj9LM1Yy9nPVp8u0LmhTJoKAGao20bgVTRzk4pX3BCsNEknbIzNHYxhsBbmiUUvSZpg8/S4W5GQNkBHRs+tFH+aSM/dHaNMl7sMOP1gfP8rzynOy74DZrm9Y7TorzDC5b4MrvDc37w4g5fpfNZRq94cc0f1y9Op7N/04jcoFN0jHumP3Ele+1+DS/W06A4wjkBnGD8eAU0JQEeVAQtg1ZB66A0i0ajsWh5NGxQofFoIhr28MP4lk7LziifwGdcbJ8C4XL+mtJO+t8mN/ZqWJzy4cMeXucb"
    ## `debug_symbols` of the program the command left at
    ## `target/plat62_circuit.json`: base64 of raw deflate of JSON, whose spans
    ## name the file ids above.
  Plat62RowTotal* = 55
    ## Four functions and their 51 opcodes.
  Plat62HalveRow* = 19
  Plat62InvertRow* = 36
  Plat62QuotientRow* = 46
    ## Where each function's row is, with its opcodes above it (`main` is 0).
  Plat62RangeOpcodeRow* = 5
    ## `main`'s opcode 4, inlined from `checks::in_range`: the innermost frame
    ## in the project is `src/checks.nr:2`, not the call at `src/main.nr:8`.
  Plat62RangeLine* = 2
  Plat62OpcodePlaces* = [
    (1, "src/main.nr:4"), (2, "src/main.nr:4"),  # assert(x != y)
    (3, "src/main.nr:6"),                         # the call of `halve`
    (4, "src/main.nr:7"),                         # assert(half * 2 == y)
    (5, "src/checks.nr:2"), (18, "src/checks.nr:2"),  # the inlined assert
    (32, "src/main.nr:12"), (33, "src/main.nr:12"),   # `v / 2` in `halve`
    (20, ""), (35, ""), (37, ""), (47, "")]
    ## (row, where it leads): worked out by hand from the crate's text, so the
    ## suites hold the decoding to what the source says. A Brillig function's
    ## set-up rows and the directives' rows carry no position.
  Plat62UnlocatedOpcodeRow* = 20

proc plat62Artefact*(mainPath = "/crate/src/main.nr";
                     checksPath = "/crate/src/checks.nr"): string =
  ## The fields of `target/plat62_circuit.json` the placement reads, the paths
  ## spelled as the compiler spells them: absolute, under the project.
  proc quoted(text: string): string =
    result = "\""
    for c in text:
      case c
      of '\n': result.add "\\n"
      of '"': result.add "\\\""
      of '\\': result.add "\\\\"
      else: result.add c
    result.add "\""
  "{\"debug_symbols\":" & quoted(Plat62DebugSymbols) & ",\"file_map\":{\"" &
    $Plat62CheckFileId & "\":{\"path\":" & quoted(checksPath) &
    ",\"source\":" & quoted(Plat62ChecksNr) & "},\"" & $Plat62MainFileId &
    "\":{\"path\":" & quoted(mainPath) & ",\"source\":" &
    quoted(Plat62MainNr) & "}}}"
