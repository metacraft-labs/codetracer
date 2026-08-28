// A program with a postcondition the solver cannot discharge, because it is
// false: `quadruple` returns `4 * x1`, and `main` asserts it returned 40 for
// an input of 10 without any postcondition to justify the claim.
//
// Verifying this needs a working `venir`, which is Linux-only.  See
// ../../src/frontend/viewmodel/tests/fixtures/verno/PROVENANCE.md.
#['requires(-32 <= x1 & x1 < 32)]
fn quadruple(x1: i8) -> i8 {
    let x2 = x1 + x1;
    x2 + x2
}

fn main() {
    let n = quadruple(10);
    assert(n == 40);
}
