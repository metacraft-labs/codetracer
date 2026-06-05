// clone_forwarder — Rust
//
// `let b = a.clone();` classifies as TrivialCopy because `.clone()` on
// a primitive is a built-in forwarder in the classifier catalogue
// (spec §7.2 Rust row).
//
// Expected chain for `b` queried at the `println!` line:
//
//   hop 0: target=b   rhs=a.clone()   OriginKind=TrivialCopy   source_variable=a
//   hop 1: target=a   rhs=10          OriginKind=Literal       terminator=Literal(int, value=10)
fn main() {
    let a: i32 = 10;
    let b: i32 = a.clone();
    println!("{}", b);
}
