// Simple Rust/WASM program for flow/omniscience integration testing.
//
// Compiled with `cargo build --target wasm32-wasip1` (debug mode with DWARF).
// Recorded by wazero: `wazero run --out-dir <dir> <wasm>`.
//
// The computation matches the other language flow test programs:
//   a=10, b=32, sum_val=42, doubled=84, final_result=94

fn calculate_sum(a: i32, b: i32) -> i32 {
    let sum_val = a + b;
    let doubled = sum_val * 2;
    let final_result = doubled + 10;
    println!("Sum: {}", sum_val);
    println!("Doubled: {}", doubled);
    println!("Final: {}", final_result);
    final_result
}

fn main() {
    let x = 10;
    let y = 32;
    let result = calculate_sum(x, y);
    println!("Result: {}", result);
}
