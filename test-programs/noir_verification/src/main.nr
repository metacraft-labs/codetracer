// The worked example from Verno's own documentation
// (docs/src/specifications/pre_and_postconditions.md): `quadruple` carries a
// precondition strong enough to rule out the two possible overflows, and a
// postcondition that lets `main` reason about the call without inspecting the
// body.
#['requires(-32 <= x1 & x1 < 32)]
#['ensures(result == 4 * x1)]
fn quadruple(x1: i8) -> i8 {
    let x2 = x1 + x1;
    x2 + x2
}

fn main(x: i8) -> pub i8 {
    quadruple(x / 4)
}
