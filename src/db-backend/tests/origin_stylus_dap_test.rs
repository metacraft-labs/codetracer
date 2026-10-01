//! Per-language headless DAP tests for Stylus `ct/originChain` against
//! materialized traces (M23 of the Value Origin Tracking milestones).
//!
//! The fixture is a real Stylus contract crate
//! (`tests/fixtures/origin/stylus/<scenario>/`). It goes through the
//! Stylus recording pipeline, the same one `ct arb record` drives
//! (`src/ct/stylus/record.nim`):
//!
//! 1. A transaction against the deployed contract is traced on the Nitro
//!    node with `debug_traceTransaction` and the `stylusTracer`
//!    (`cargo stylus trace`), which lists every hostio the contract made
//!    with its arguments and results. That response is committed as the
//!    fixture's `evm_trace.json`, so the test needs no live node;
//!    `regenerate.sh` re-captures it from a Nitro dev node.
//! 2. The contract's debug wasm is built and re-executed by
//!    `wazero run -stylus evm_trace.json`, whose `vm_hooks` host module
//!    answers each hostio from the capture.
//! 3. The replay is the materialized `.ct` trace the origin query runs on.
//!
//! When a prerequisite is missing, the test goes through
//! `common/origin_dap_gate.rs`: a loud "asserted NOTHING" skip on a developer
//! box, and a failure under `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false` or
//! `CT_ORIGIN_DAP_REQUIRED=1`.
//!
//! No mocks: the host interface is answered from a real node's capture of
//! a real transaction, and the contract, replay and query are all real.
//!
//! The shared per-DAP helper lives in `tests/common/origin_dap.rs`.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

#[path = "common/origin_dap_gate.rs"]
mod origin_dap_gate;

use db_backend::task::{OriginKind, TerminatorKind};
use origin_dap::{
    OriginQueryConfig, QueryOutcome, assert_hop_count, assert_hop_kinds, assert_min_confidence, assert_terminator_kind,
    fixture_dir, load_fixture_and_query_or_skip,
};
use origin_dap_gate::{required_mode, unavailable};
use test_harness::Language;

/// The Stylus replay needs the wazero recorder (the `-stylus` replay host)
/// and a Rust toolchain that can build `wasm32-unknown-unknown`.
fn require_stylus_pipeline() -> Option<String> {
    if test_harness::find_wazero().is_none() {
        return unavailable(
            required_mode(),
            "Stylus recorder prerequisite",
            "wazero recorder not found (set CODETRACER_WASM_VM_PATH, or `just build` the sibling \
             codetracer-wasm-recorder)",
        );
    }
    if !test_harness::is_command_available("cargo") {
        return unavailable(
            required_mode(),
            "Stylus recorder prerequisite",
            "cargo is not available on PATH",
        );
    }
    Some("stylus-sdk-0.9".to_string())
}

fn stylus_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    let project_dir = fixture_dir("stylus", scenario);
    let breakpoint_source = project_dir.join("src/lib.rs");
    OriginQueryConfig {
        source_path: project_dir,
        language: Language::Stylus,
        version_label: version.to_string(),
        breakpoint_line: line,
        variable_name: variable.to_string(),
        max_hops: None,
        breakpoint_source_path: Some(breakpoint_source),
    }
}

fn run_or_skip(scenario: &str, config: &OriginQueryConfig) -> Option<Box<origin_dap::OriginQueryResult>> {
    match load_fixture_and_query_or_skip(config) {
        QueryOutcome::Ok(r) => Some(r),
        QueryOutcome::Skipped(reason) => unavailable(required_mode(), &format!("stylus/{scenario}"), &reason),
    }
}

#[test]
fn test_origin_stylus_canonical_chain() {
    let Some(version) = require_stylus_pipeline() else {
        return;
    };
    // `src/lib.rs` line 25 is `core::hint::black_box(&c);`, after `c` is bound; the chain for `c` is
    //   c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
    let config = stylus_config("simple_trivial_chain", &version, 25, "c");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "stylus simple_trivial_chain terminator");
    assert_hop_count(chain, 3, "stylus simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "stylus simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "stylus simple_trivial_chain confidence");

    // Each hop names the contract statement that wrote the value, as the
    // replayed wasm's DWARF line table places it in `src/lib.rs`.
    let observed: Vec<(String, u32, Option<&str>)> = chain
        .hops
        .iter()
        .map(|h| {
            assert!(
                h.location.path.ends_with("simple_trivial_chain/src/lib.rs"),
                "stylus hop for `{}` is located in {}, not the contract source",
                h.target_expr,
                h.location.path
            );
            (
                h.target_expr.clone(),
                h.location.line as u32,
                h.source_variable.as_deref(),
            )
        })
        .collect();
    assert_eq!(
        observed,
        vec![
            ("c".to_string(), 24, Some("b")),
            ("b".to_string(), 23, Some("a")),
            ("a".to_string(), 22, None),
        ],
        "stylus simple_trivial_chain hops (target, line, source variable)"
    );
    assert_eq!(
        chain.terminator.source_line.as_deref().map(str::trim),
        Some("let a: u32 = 10;"),
        "stylus simple_trivial_chain terminator source line"
    );
}
