// Simple Rust/WASM example for CodeTracer GUI (Playwright) tests.
//
// Compiled with `cargo build --target wasm32-wasip1` (debug mode).
// The WASM binary is recorded by `ct record <wasm_example.wasm>`.

fn add(a: i32, b: i32) -> i32 {
    a + b
}

fn main() {
    let x = 3;
    let y = 4;
    let result = add(x, y);
    println!("result: {}", result);
}
