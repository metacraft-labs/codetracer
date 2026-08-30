// A correct program Verno cannot verify, because it uses a construct the
// translator does not implement: a lambda.  Verno's `docs/src/limitations.md`
// lists this as `UNSUPPORTED: function types (lambdas, function values)`.
//
// Nothing here is wrong.  The point of the fixture is that meeting a
// limitation must not be reported as an unproven obligation, or the developer
// goes looking for a bug in code that has none.
#['ensures(result == x / 2)]
fn main(x: u32) -> pub u32 {
    let halve = |v: u32| v / 2;
    halve(x)
}
