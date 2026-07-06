// simple_trivial_chain — Rust
// let a = 10; let b = a; let c = b — terminates at Literal.
fn main() {
    let a: i32 = 10;
    let b: i32 = a;
    let c: i32 = b;
    std::hint::black_box(&c);
    println!("{}", c);
}
