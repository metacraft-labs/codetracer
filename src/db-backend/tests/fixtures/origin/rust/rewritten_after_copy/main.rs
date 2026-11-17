// rewritten_after_copy — Rust
// `b` is written again after `c` copies it. `c`'s chain follows `b` back
// from the copy, to `b = a`, and never to the later `b = 7`.
fn main() {
    let a: i32 = 10;
    let mut b: i32 = a;
    let c: i32 = b;
    b = 7;
    std::hint::black_box(&b);
    std::hint::black_box(&c);
    println!("{} {}", c, b);
}
