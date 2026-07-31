// Cross-process origin demo — WebAssembly compute tier.
//
// This module is the third recording in the demo: Rust compiled to
// `wasm32-unknown-unknown` and run *inside the browser*, called by the
// page's JavaScript, whose result the page then POSTs to the Node
// backend. Recording it separately from the page's JavaScript is what
// makes the JS -> WASM call a **boundary crossing** rather than an
// ordinary function call, and therefore something a cross-process
// origin chain can walk across.
//
// Deliberately built **without wasm-bindgen**: a plain `cdylib` with C
// ABI exports. wasm-bindgen generates its own JS glue that owns module
// instantiation, which would leave the page no clean seam to supply the
// `__codetracer` import namespace the instrumented module needs. With a
// bare cdylib the page calls `WebAssembly.instantiate` itself and passes
// the recorder's imports directly.
//
// # Why this is ordinary Rust
//
// It is ordinary on purpose, and that is the point being tested.
//
// An earlier version of this file staged its computation through a
// linear-memory "ledger" — four `u32` slots written one at a time —
// because the instrumenter's V1 model recorded memory stores, and a
// module computing in locals produced no values at all. That model is
// withdrawn (see
// `codetracer-specs/Recording-Backends/WASM-Instrumentation-Layer.md`
// §§ 2 and 11): stores cannot capture locals or operand-stack values,
// *which* values reach memory is decided by the optimiser rather than
// by the source, and the measured cost was +2955 % runtime against
// +11 % for boundary capture.
//
// What is recorded now is what crosses the module's boundary with the
// host: the arguments of every exported call and the values it returns
// (spec § 3). Nothing about the code below is arranged to suit that.
// It computes in locals, through ordinary private helpers, the way any
// Rust would — which is exactly why it is the honest test of the
// boundary-capture model. §11 of the spec names the tell for the
// mistake this file used to embody: "the demo module has to be
// rewritten to keep its values in memory in order for anything to be
// recorded."
//
// The step-level interior — locals, the helper calls, per-line steps —
// is not lost; it is materialised offline by re-executing this same
// `.wasm` against the recorded boundary log (spec § 6, milestone M37).
//
// The computation stays pure and deterministic — no clock, no
// randomness, no I/O — so re-recording produces identical values:
//
//     compute_balance(42, 100) == 42 * 10 + 100 * 2 == 620

/// Loyalty points awarded for the account itself.
///
/// A private helper, not an export: nothing about it crosses the host
/// boundary, so the browser recording will not mention it. Re-executing
/// the module from the boundary log is what recovers this frame.
fn loyalty_bonus(user_id: u32) -> u32 {
    user_id * 10
}

/// Credit earned by the transaction amount.
fn amount_credit(amount: u32) -> u32 {
    amount * 2
}

/// Combine a user id and a base amount into an account balance.
///
/// The one export the page calls. Its two arguments and its single
/// result are the module's entire recorded interaction with the host.
#[no_mangle]
pub extern "C" fn compute_balance(user_id: u32, amount: u32) -> u32 {
    let bonus = loyalty_bonus(user_id);
    let credit = amount_credit(amount);
    bonus + credit
}
