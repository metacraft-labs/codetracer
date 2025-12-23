// Simple Rust program for flow/omniscience integration testing
// This program tests that local variables inside functions can be loaded.

fn calculate_sum(a: i32, b: i32) -> i32 {
    // Local variables inside a function
    let sum = a + b;
    let doubled = sum * 2;
    let final_result = doubled + 10;
    println!("Sum: {}", sum);
    println!("Doubled: {}", doubled);
    println!("Final: {}", final_result);
    final_result
}

fn main() {
    // Local variables in main
    let x = 10;
    let y = 32;
    let result = calculate_sum(x, y);
    println!("Result: {}", result);
}
