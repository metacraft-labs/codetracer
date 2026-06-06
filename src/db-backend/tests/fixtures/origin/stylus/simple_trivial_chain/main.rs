// simple_trivial_chain — Stylus (EVM via Arbitrum Stylus)
// a=10; b=a; c=b — origin chain terminates at Literal.
//
// The Value Origin query targets `c` at the trailing return.  The chain
// must walk: c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
//
// Stylus contracts are compiled Rust; the classifier uses the Rust
// universal-table row from spec §7.1.  The EVM-specific overrides
// documented in spec §7.2 (Solidity storage-write vs memory-write) only
// fire when the source line touches a contract-storage attribute (e.g.
// `self.balance.set(x)`); this fixture is local-only so the override
// path is inert here and the chain matches the Rust shape exactly.
fn compute() -> u32 {
    let a: u32 = 10;
    let b: u32 = a;
    let c: u32 = b;
    c
}

fn main() {
    let _ = compute();
}
