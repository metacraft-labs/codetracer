mod baz;
mod qux;

use crate::qux::complex_operation;

fn main(x: Field, y: pub Field, z: Field) {
    let result = complex_operation(x, y, z);
    let expected_result = calculate_expected(x, y, z);
    assert(result == expected_result);
}

fn calculate_expected(x: Field, y: Field, z: Field) -> Field {
    let product = x * y;
    let divided = product / z;
    divided + x
}
