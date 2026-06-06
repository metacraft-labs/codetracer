// simple_trivial_chain — Sway / FuelVM
// a=10; b=a; c=b — origin chain terminates at Literal.
//
// The Value Origin query targets `c` at the final `log(c)` line.  The
// chain must walk: c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
//
// Sway's surface syntax mirrors Rust's, so the classifier reuses the
// Rust universal-table row from spec §7.1.  The FuelVM-specific overrides
// documented in spec §7.2 (M23 Sway row) only fire when the source line
// touches a storage receiver (e.g. `storage.balance.write(x)`); this
// fixture is local-only so the override path is inert here.
script;

use std::logging::log;

fn compute() -> u64 {
    let a: u64 = 10;
    let b: u64 = a;
    let c: u64 = b;
    c
}

fn main() {
    let result: u64 = compute();
    log(result);
}
