pub fn multiply_many_times(x: Field, y: Field, iterations: u32) -> Field {
    let mut result = x;
    for i in 0..iterations {
        result = result * y;
    }
    result
}
