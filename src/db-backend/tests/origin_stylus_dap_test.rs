//! Per-language headless DAP tests for Stylus / EVM `ct/originChain`
//! against materialized traces (M23 of the Value Origin Tracking
//! milestones).
//!
//! Mirrors the M3 `origin_python_dap_test.rs` shape; the recorder
//! under test is `codetracer-evm-recorder`, which records EVM
//! execution of a compiled Stylus contract.
//!
//! When the EVM recorder isn't available, the test goes through
//! `common/origin_dap_gate.rs`: a loud "asserted NOTHING" skip on a developer
//! box, and a failure under `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false` or
//! `CT_ORIGIN_DAP_REQUIRED=1`.
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
    fixture_source, load_fixture_and_query_or_skip,
};
use origin_dap_gate::{required_mode, unavailable};
use test_harness::Language;

/// Skip reason emitted when the EVM recorder is missing. Stylus
/// fixtures are driven through the EVM recorder pipeline because
/// Stylus contracts compile to EVM bytecode under the hood.
fn require_stylus_recorder() -> Option<String> {
    if test_harness::find_evm_recorder().is_none() {
        return unavailable(
            required_mode(),
            "Stylus recorder prerequisite",
            "EVM recorder not found (set CODETRACER_EVM_RECORDER_PATH or build codetracer-evm-recorder)",
        );
    }
    Some("stylus-1.0".to_string())
}

fn stylus_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        // Stylus contracts are Rust source; the M23 fixture ships
        // `main.rs` as the canonical source program.
        source_path: fixture_source("stylus", scenario, "main.rs"),
        language: Language::Solidity,
        version_label: version.to_string(),
        breakpoint_line: line,
        variable_name: variable.to_string(),
        max_hops: None,
        breakpoint_source_path: None,
    }
}

fn run_or_skip(scenario: &str, config: &OriginQueryConfig) -> Option<Box<origin_dap::OriginQueryResult>> {
    match load_fixture_and_query_or_skip(config) {
        QueryOutcome::Ok(r) => Some(r),
        QueryOutcome::Skipped(reason) => unavailable(required_mode(), &format!("stylus/{scenario}"), &reason),
    }
}

#[test]
fn test_origin_stylus_evm_canonical_chain() {
    let Some(version) = require_stylus_recorder() else {
        return;
    };
    // `main.rs` line 15 returns `c`; the chain for `c` is
    //   c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
    let config = stylus_config("simple_trivial_chain", &version, 15, "c");
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
}
