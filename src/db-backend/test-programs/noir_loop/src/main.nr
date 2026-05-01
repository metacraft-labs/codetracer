// Noir program for flow / loop integration testing.
//
// The body of this program contains a multi-iteration `for` loop, used
// to verify that the db-backend `process_loops` pipeline registers a
// `Loop` entry in the FlowViewUpdate for Noir traces (closing the
// "loop iteration slider tracks remaining shield" / "simple loop
// iteration jump" gap reported in the noir-space-ship suite).

fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        let contribution = (i as Field) * x;
        sum = sum + contribution;
    }
    let final_result = sum;
    assert(final_result == 30);
}
