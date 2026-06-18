// Cross-Tracer Origin E2E — Fixture A' WASM compute module
// (three-tracer variant per Cross-Tracer-Origin-Test.audit.md
// § TCT-M4).
//
// The `balance-calc` crate compiles to `wasm32-unknown-unknown` and
// is loaded into the front-end JavaScript bundle through
// wasm-bindgen's generated JS glue under
// `frontend/pkg/balance_calc.js`. The exported `compute_balance`
// function is the middle hop in the three-trace value-origin chain
// the fixture documents in ../ANSWERS.md: the front-end JS
// captures the two source-line literals `userId = 42` + `amount =
// 100`, calls into this module, and the return value feeds the
// HTTP POST that the Python backend stores in its local `balance`.
//
// The recorder side: the codetracer-wasm-instrumenter
// (see codetracer-specs/Recording-Backends/WASM-Instrumentation-Layer.md)
// rewrites every import/export edge to emit a
// `__ct_emit_realm_boundary(direction, fn_kind, fn_index, token)`
// tuple — at replay time the M25 PairIndex's `js-wasm-realm` family
// resolves the JS side to this WASM side by the token's decimal
// rendering. No manual marker annotation is required inside the
// Rust source.
//
// The computation itself is deterministic so the integration test
// can assert against a known number:
//   compute_balance(42, 100) == 42 * 10 + 100 * 2 == 620
// — which gives ../ANSWERS.md a concrete expected payload value
// for the round-trip smoke.

use wasm_bindgen::prelude::*;

/// Compute the user's account balance from their id and a base
/// amount. The computation is intentionally trivial — two
/// multiplications + one addition — so the value-origin chain
/// classifier emits a single `Computational` hop with two operand
/// snapshots (one per arithmetic operand) at this site.
#[wasm_bindgen]
pub fn compute_balance(user_id: u32, amount: u32) -> u64 {
    let user_term: u64 = (user_id as u64) * 10;
    let amount_term: u64 = (amount as u64) * 2;
    user_term + amount_term
}
