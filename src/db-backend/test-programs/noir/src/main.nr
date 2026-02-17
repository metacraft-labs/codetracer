// Simple Noir program for flow/omniscience integration testing.
//
// Tests that tree-sitter (using the Rust grammar) correctly extracts
// local variables and filters out function calls when loading flow data.
//
// The computation matches the other language flow test programs:
//   a=10, b=32, sum_val=42, doubled=84, final_result=94
//
// Witness values are provided via Prover.toml: x=10, y=32.

fn calculate_sum(a: Field, b: Field) -> Field {
    let sum_val = a + b;
    let doubled = sum_val * 2;
    let final_result = doubled + 10;
    println(f"Sum: {sum_val}");
    println(f"Doubled: {doubled}");
    println(f"Final: {final_result}");
    final_result
}

fn main(x: Field, y: Field) {
    let result = calculate_sum(x, y);
    println(f"Result: {result}");
}
