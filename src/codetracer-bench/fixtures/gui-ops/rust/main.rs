// P4 GUI-ops latency fixture (Rust).  Mirrors fixtures/gui-ops/python/main.py.
fn fold(x: i32, y: i32) -> i32 {
    x * 31 + y
}

fn main() {
    let a: i32 = 1;
    let b: i32 = a + 2;
    let c: i32 = b * 3;
    let d: i32 = c + 10;
    let e: i32 = fold(d, 7);
    println!("{}", e);
}
