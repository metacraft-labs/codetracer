//! Per-language headless DAP tests for Sway / FuelVM
//! `ct/originChain` against materialized traces (M23 of the Value
//! Origin Tracking milestones).
//!
//! Mirrors the M3 `origin_python_dap_test.rs` shape; the recorder
//! under test is `codetracer-fuel-recorder`.
//!
//! The test SKIPs cleanly when the Fuel recorder isn't available.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

use db_backend::task::{OriginKind, TerminatorKind};
use origin_dap::{
    OriginQueryConfig, QueryOutcome, assert_hop_count, assert_hop_kinds, assert_min_confidence, assert_terminator_kind,
    fixture_source, load_fixture_and_query_or_skip,
};
use test_harness::Language;

fn require_sway_recorder() -> Option<String> {
    if test_harness::find_fuel_recorder().is_none() {
        eprintln!(
            "SKIPPED: Fuel recorder not found (set CODETRACER_FUEL_RECORDER_PATH or build codetracer-fuel-recorder)"
        );
        return None;
    }
    Some("sway-0.65".to_string())
}

fn sway_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("sway", scenario, "main.sw"),
        language: Language::Sway,
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
        QueryOutcome::Skipped(reason) => {
            eprintln!("SKIPPED: sway/{}: {}", scenario, reason);
            None
        }
    }
}

#[test]
fn test_origin_sway_canonical_chain() {
    let Some(version) = require_sway_recorder() else {
        return;
    };
    // `main.sw` line 19 returns `c`; the chain for `c` is
    //   c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
    let config = sway_config("simple_trivial_chain", &version, 19, "c");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "sway simple_trivial_chain terminator");
    assert_hop_count(chain, 3, "sway simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "sway simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "sway simple_trivial_chain confidence");
}
