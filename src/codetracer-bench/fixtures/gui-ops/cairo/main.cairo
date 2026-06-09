// P4 GUI-ops latency fixture (Cairo).  Mirrors fixtures/gui-ops/python/main.py:
// a small assignment chain so the headless DAP harness can drive a
// recorded Cairo trace.  Shape mirrors codetracer-cairo-recorder
// test-programs/cairo/flow_test.cairo so the cairo recorder's
// run_function_with_starknet_context (empty args, no gas) accepts it.
fn compute() -> (felt252, felt252, felt252, felt252, felt252) {
    let a: felt252 = 1;
    let b: felt252 = a + 2;
    let c: felt252 = b * 3;
    let d: felt252 = c + 10;
    let e: felt252 = d * 31 + 7;
    (a, b, c, d, e)
}

fn main() -> (felt252, felt252, felt252, felt252, felt252) {
    compute()
}
