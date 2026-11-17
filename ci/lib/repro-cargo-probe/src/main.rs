//! Prints the rustc Cargo used to build this binary (see build.rs).
fn main() {
    println!("{}", env!("CT_REPRO_CARGO_PROBE_RUSTC"));
}
