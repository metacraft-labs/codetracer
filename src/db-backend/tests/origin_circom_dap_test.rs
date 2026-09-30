//! Per-language headless DAP tests for Circom `ct/originChain`
//! against materialized traces (M23 of the Value Origin Tracking
//! milestones).
//!
//! Mirrors the M3 `origin_python_dap_test.rs` shape; the recorder
//! under test is `codetracer-circom-recorder`.  Circom's signal-
//! assignment idiom (`<==`) is the M23 override called out in spec
//! §7.2: a bare-name signal-assignment classifies as `TrivialCopy`,
//! integer-literal signal-assignment classifies as `Literal`.
//!
//! When the Circom recorder isn't available, the test goes through
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

fn require_circom_recorder() -> Option<String> {
    if test_harness::find_circom_recorder().is_none() {
        return unavailable(
            required_mode(),
            "Circom recorder prerequisite",
            "Circom recorder not found (set CODETRACER_CIRCOM_RECORDER_PATH or build codetracer-circom-recorder)",
        );
    }
    Some("circom-2.0".to_string())
}

fn circom_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("circom", scenario, "main.circom"),
        language: Language::Circom,
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
        QueryOutcome::Skipped(reason) => unavailable(required_mode(), &format!("circom/{scenario}"), &reason),
    }
}

#[test]
fn test_origin_circom_canonical_chain() {
    let Some(version) = require_circom_recorder() else {
        return;
    };
    // `main.circom` line 27 assigns `out <== c;`; the chain for `out` is
    //   out -> c (TrivialCopy) -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
    let config = circom_config("simple_trivial_chain", &version, 27, "out");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "circom simple_trivial_chain terminator");
    assert_hop_count(chain, 4, "circom simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[
            OriginKind::TrivialCopy,
            OriginKind::TrivialCopy,
            OriginKind::TrivialCopy,
            OriginKind::Literal,
        ],
        "circom simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "circom simple_trivial_chain confidence");
}
