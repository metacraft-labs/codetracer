//! Per-language headless DAP tests for Solana SBF (sBPF)
//! `ct/originChain` against materialized traces (M23 of the Value
//! Origin Tracking milestones).
//!
//! Mirrors the M3 `origin_python_dap_test.rs` shape; the recorder
//! under test is `codetracer-solana-recorder`.
//!
//! When the Solana recorder isn't available, the test goes through
//! `common/origin_dap_gate.rs`: a loud "asserted NOTHING" skip on a developer
//! box, and a failure under `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false` or
//! `CT_ORIGIN_DAP_REQUIRED=1`.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

#[path = "common/origin_dap_gate.rs"]
mod origin_dap_gate;

use db_backend::task::{OriginKind, TerminatorKind};
use origin_dap::{
    OriginQueryConfig, QueryOutcome, assert_hop_count, assert_hop_kinds, assert_min_confidence, assert_terminator_kind,
    fixture_line, fixture_source, load_fixture_and_query_or_skip,
};
use origin_dap_gate::{required_mode, unavailable};
use test_harness::Language;

fn require_solana_recorder() -> Option<String> {
    if test_harness::find_solana_recorder().is_none() {
        return unavailable(
            required_mode(),
            "Solana recorder prerequisite",
            "Solana recorder not found (set CODETRACER_SOLANA_RECORDER_PATH or build codetracer-solana-recorder)",
        );
    }
    Some("solana-1.18".to_string())
}

fn solana_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("solana", scenario, "main.rs"),
        language: Language::Solana,
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
        QueryOutcome::Skipped(reason) => unavailable(required_mode(), &format!("solana/{scenario}"), &reason),
    }
}

#[test]
fn test_origin_solana_sbf_canonical_chain() {
    let Some(version) = require_solana_recorder() else {
        return;
    };
    // The query is at the trailing `black_box(c)`. The chain for `c` is
    //   c -> b (TrivialCopy) -> a (TrivialCopy) -> black_box(10) (call),
    // ending as `Computational`. The fixture's header says why `a` is
    // `black_box(10)` and not the literal `10`: with a literal the SBF binary
    // holds no copy to record, and the chain cannot get past `b`.
    let line = fixture_line("solana", "simple_trivial_chain", "main.rs", "core::hint::black_box(c)");
    let config = solana_config("simple_trivial_chain", &version, line, "c");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(
        chain,
        TerminatorKind::Computational,
        "solana simple_trivial_chain terminator",
    );
    assert_hop_count(chain, 3, "solana simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[
            OriginKind::TrivialCopy,
            OriginKind::TrivialCopy,
            OriginKind::FunctionCall,
        ],
        "solana simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "solana simple_trivial_chain confidence");
}
