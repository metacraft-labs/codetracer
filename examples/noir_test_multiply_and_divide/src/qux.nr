use crate::baz::multiply_and_divide;

pub fn complex_operation(x: Field, y: Field, z: Field) -> Field {
    let result = multiply_and_divide(x, y, z);
    result + x // Adding `x` for a more complex output
}