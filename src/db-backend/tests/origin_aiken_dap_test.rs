//! Per-language headless DAP tests for Aiken / Cardano
//! `ct/originChain` against materialized traces (M23 of the Value
//! Origin Tracking milestones).
//!
//! Mirrors the M3 `origin_python_dap_test.rs` shape; the recorder
//! under test is `codetracer-cardano-recorder`.
//!
//! When the Cardano recorder isn't available, the test goes through
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
    fixture_source, load_fixture_and_query_or_skip,
};
use origin_dap_gate::{required_mode, unavailable};
use test_harness::Language;

fn require_aiken_recorder() -> Option<String> {
    if test_harness::find_aiken_recorder().is_none() {
        return unavailable(
            required_mode(),
            "Aiken / Cardano recorder prerequisite",
            "Aiken / Cardano recorder not found (set CODETRACER_AIKEN_RECORDER_PATH or build codetracer-cardano-recorder)",
        );
    }
    Some("aiken-1.0".to_string())
}

fn aiken_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("aiken", scenario, "main.ak"),
        language: Language::Aiken,
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
        QueryOutcome::Skipped(reason) => unavailable(required_mode(), &format!("aiken/{scenario}"), &reason),
    }
}

#[test]
fn test_origin_aiken_canonical_chain() {
    let Some(version) = require_aiken_recorder() else {
        return;
    };
    // `main.ak` line 16 returns `c`; the chain for `c` is
    //   c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
    let config = aiken_config("simple_trivial_chain", &version, 16, "c");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "aiken simple_trivial_chain terminator");
    assert_hop_count(chain, 3, "aiken simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "aiken simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "aiken simple_trivial_chain confidence");
}
