// simple_trivial_chain — Solana SBF (sBPF)
// a=<opaque 10>; b=a; c=b — the origin chain walks the two local copies.
//
// The Value Origin query targets `c` at the trailing `black_box(c)`. The
// chain must walk: c -> b (TrivialCopy) -> a (TrivialCopy) -> the call that
// produced `a`'s value.
//
// Solana programs are compiled Rust; the classifier uses the Rust
// universal-table row from spec §7.1.  The Solana-specific overrides
// documented in spec §7.2 (M23 Solana SBF row) fire when the source line
// touches an account-data receiver (`AccountInfo::data`,
// `try_borrow_mut_data`); this fixture is local-only so the override
// path is inert here.
//
// Why the two `black_box` calls. Both keep the copies VISIBLE in the SBF
// binary; neither changes the chain `let b = a; let c = b;` under test.
//
// - `a = black_box(10)`, not `a = 10`: with a literal, the SBF backend folds
//   the copies even at `opt-level = 0` and `-Zmir-opt-level=0`. It stores the
//   immediate 10 into all three slots, `b`'s store first (measured with
//   llvm-objdump: `stdw [r10-0x10], 0xa` at line `b`, then `a`, then `c`). The
//   binary then contains no copy for the recorder to see, and the chain stops
//   at `b` with "parameter at record start". An opaque value forces `b` and `c`
//   to load what precedes them.
// - The tail is `black_box(c)`, not a bare `c`: a bare trailing `c` becomes
//   the function's return place and has no DWARF location. Passing `c` by
//   value keeps it a local without taking its address (`&c` would read to the
//   origin engine as a possible write to `c`).
//
// The harness also builds with `-Zmir-opt-level=0`, without which rustc's MIR
// optimisations give `b` and `c` one shared stack slot.
fn compute() -> u64 {
    let a: u64 = core::hint::black_box(10);
    let b: u64 = a;
    let c: u64 = b;
    core::hint::black_box(c)
}

fn main() {
    let _ = compute();
}
