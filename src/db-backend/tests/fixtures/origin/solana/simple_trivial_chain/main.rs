// simple_trivial_chain — Solana SBF (sBPF)
// a=10; b=a; c=b — origin chain terminates at Literal.
//
// The Value Origin query targets `c` at the trailing return.  The chain
// must walk: c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
//
// Solana programs are compiled Rust; the classifier uses the Rust
// universal-table row from spec §7.1.  The Solana-specific overrides
// documented in spec §7.2 (M23 Solana SBF row) fire when the source line
// touches an account-data receiver (`AccountInfo::data`,
// `try_borrow_mut_data`); this fixture is local-only so the override
// path is inert here.
fn compute() -> u64 {
    let a: u64 = 10;
    let b: u64 = a;
    let c: u64 = b;
    c
}

fn main() {
    let _ = compute();
}
