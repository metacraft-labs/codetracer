//! Per-language headless DAP tests for Noir `ct/originChain` against
//! materialized traces (M23 of the Value Origin Tracking milestones).
//!
//! Mirrors the M3 `origin_python_dap_test.rs` shape; the recorder is
//! the Noir `nargo`-based DB pipeline already exercised by
//! `noir_flow_dap_test.rs`.
//!
//! The test SKIPs cleanly when the Noir recorder / nargo aren't
//! available.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

use db_backend::task::{OriginKind, TerminatorKind};
use origin_dap::{
    OriginQueryConfig, QueryOutcome, assert_hop_count, assert_hop_kinds, assert_min_confidence, assert_terminator_kind,
    fixture_dir, load_fixture_and_query_or_skip,
};
use test_harness::Language;

fn require_noir_recorder() -> Option<String> {
    // The Noir pipeline is gated on `nargo` being on PATH (the
    // M3-style flow tests use the same gate).
    if !test_harness::is_command_available("nargo") {
        eprintln!("SKIPPED: nargo is not available on PATH");
        return None;
    }
    Some("noir-0.30".to_string())
}

fn noir_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    // The Noir recorder (the `nargo trace` pipeline) expects a
    // project directory containing `Nargo.toml` + `src/main.nr` +
    // `Prover.toml`, not a bare source file.  The fixture ships
    // that layout under `tests/fixtures/origin/noir/<scenario>/`.
    // Breakpoints, however, must address the inner `src/main.nr`
    // file — exactly the split the existing `noir_flow_dap_test.rs`
    // performs.
    let project_dir = fixture_dir("noir", scenario);
    let breakpoint_source = project_dir.join("src/main.nr");
    OriginQueryConfig {
        source_path: project_dir,
        language: Language::Noir,
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
        QueryOutcome::Skipped(reason) => {
            eprintln!("SKIPPED: noir/{}: {}", scenario, reason);
            None
        }
    }
}

#[test]
fn test_origin_noir_canonical_chain() {
    let Some(version) = require_noir_recorder() else {
        return;
    };
    // `main.nr` line 16 is `println(c);`; the chain for `c` is
    //   c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
    let config = noir_config("simple_trivial_chain", &version, 16, "c");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "noir simple_trivial_chain terminator");
    assert_hop_count(chain, 3, "noir simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "noir simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "noir simple_trivial_chain confidence");
}
