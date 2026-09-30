//! Per-language headless DAP tests for Cairo `ct/originChain` against
//! materialized traces (M23 of the Value Origin Tracking milestones).
//!
//! Mirrors the M3 `origin_python_dap_test.rs` shape:
//!
//! 1. Drives the real Cairo recorder (`codetracer-cairo-recorder`)
//!    against the M23 `simple_trivial_chain` fixture.
//! 2. Spawns `replay-server dap-server --stdio` and sets a breakpoint
//!    at the fixture's query line.
//! 3. Issues a real `ct/originChain` DAP request for `c`.
//! 4. Asserts the response shape matches the per-fixture `ANSWERS.md`
//!    (3 hops: TrivialCopy → TrivialCopy → Literal, terminator
//!    `Literal(felt252, value=10)`, all hops confidence ≥ 0.7).
//!
//! When the Cairo recorder isn't available, the test goes through
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

/// Skip reason emitted when the Cairo recorder is missing. Returns the
/// version label used for the trace-dir name on success.
fn require_cairo_recorder() -> Option<String> {
    if test_harness::find_cairo_recorder().is_none() {
        return unavailable(
            required_mode(),
            "Cairo recorder prerequisite",
            "Cairo recorder not found (set CODETRACER_CAIRO_RECORDER_PATH or build codetracer-cairo-recorder)",
        );
    }
    Some("cairo-2.0".to_string())
}

fn cairo_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("cairo", scenario, "main.cairo"),
        language: Language::Cairo,
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
        QueryOutcome::Skipped(reason) => unavailable(required_mode(), &format!("cairo/{scenario}"), &reason),
    }
}

#[test]
fn test_origin_cairo_canonical_chain() {
    let Some(version) = require_cairo_recorder() else {
        return;
    };
    // `main.cairo` line 14 returns `c`; the chain for `c` is
    //   c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
    let config = cairo_config("simple_trivial_chain", &version, 14, "c");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "cairo simple_trivial_chain terminator");
    assert_hop_count(chain, 3, "cairo simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "cairo simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "cairo simple_trivial_chain confidence");
}
