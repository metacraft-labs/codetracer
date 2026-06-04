// destructuring_or_index — Rust
// Tuple destructuring + index access (using array since Rust tuple
// indexing is `pair.0` and the spec wants both forms exercised).
fn main() {
    let pair: (i32, i32) = (11, 22);
    let (first, second) = pair;        // destructuring
    let arr: [i32; 2] = [11, 22];
    let indexed = arr[1];               // index access
    println!("{} {} {}", first, second, indexed);
}
