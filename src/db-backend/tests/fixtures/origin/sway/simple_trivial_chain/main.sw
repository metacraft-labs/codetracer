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
//
// `#[inline(never)]` keeps `compute` a function of its own, with its own frame
// and source-map entries; inlined into `main`, nothing of it is left to step
// into. It is not enough to make `a`, `b` and `c` observable: forc 0.70.3
// emits no variable debug information at all and folds the body's statements
// away. tests/origin_sway_dap_test.rs says what a recording can support today.
script;

use std::logging::log;

#[inline(never)]
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
