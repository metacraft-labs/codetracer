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
## NO MOCK: a real crate. `Plat62NargoInfoJson` is what the pinned `nargo
## info --json` printed for it (nargo 1.0.0-beta.26); the native suites run
## the real `nargo` and assert it still prints exactly this, so the constant
## cannot drift from the toolchain silently.

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
