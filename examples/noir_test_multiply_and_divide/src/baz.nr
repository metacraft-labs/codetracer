pub fn multiply_and_divide(x: Field, y: Field, divisor: Field) -> Field {
    let product = x * y;
    product / divisor
}