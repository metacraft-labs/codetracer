// Test program for verifying that f64 (double) variable values are
// correctly extracted from DWARF debug info during trace replay.
//
// This program exercises floating-point arithmetic so that the
// trace backend must return non-empty values for f64 locals.

fn compute_area(width: f64, height: f64) -> f64 {
    let area = width * height;
    let perimeter = 2.0 * (width + height);
    println!("area: {area}, perimeter: {perimeter}");
    area
}

fn main() {
    let x: f64 = 3.14;
    let y: f64 = 2.71;
    let sum = x + y;
    println!("x={x}, y={y}, sum={sum}");
    let result = compute_area(x, y);
    println!("result: {result}");
}
