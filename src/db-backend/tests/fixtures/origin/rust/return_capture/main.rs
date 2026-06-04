// return_capture — Rust
fn compute() -> i32 {
    let a: i32 = 3;
    let b: i32 = 4;
    a + b
}

fn main() {
    let captured = compute();
    println!("{}", captured);
}
