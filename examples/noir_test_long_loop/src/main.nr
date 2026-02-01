mod multiplier;

use crate::multiplier::multiply_many_times;

fn main(x: Field, y: pub Field, z: Field) {
    let iterations: u32 = 100; // Specify the number of loop iterations
    let computed_result = multiply_many_times(x, y, iterations);

    assert(computed_result == z); // Check if the result matches the expected output
}
