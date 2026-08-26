// Fixture for src/tests/gui/tests/flow/flow-loop-controls.spec.ts.
// One top-level loop, ten iterations, one conditional in the body.
// See the spec header for why this is a Noir program and not a Python or
// JavaScript one.
fn main(x: Field) {
    let mut sum: Field = 0;
    let mut even_count: Field = 0;
    for i in 0..10 {
        let contribution = (i as Field) * x;
        sum = sum + contribution;
        if i % 2 == 0 {
            even_count = even_count + 1;
        } else {
            even_count = even_count + 0;
        }
    }
    assert(sum == 45);
    assert(even_count == 5);
}
