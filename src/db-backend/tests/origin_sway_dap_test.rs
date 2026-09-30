//! Per-language headless DAP tests for Sway / FuelVM
//! `ct/originChain` against materialized traces (M23 of the Value
//! Origin Tracking milestones).
//!
//! Mirrors the M3 `origin_python_dap_test.rs` shape; the recorder
//! under test is `codetracer-fuel-recorder`.
//!
//! When the Fuel recorder isn't available, the test goes through
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

fn require_sway_recorder() -> Option<String> {
    if test_harness::find_fuel_recorder().is_none() {
        return unavailable(
            required_mode(),
            "Sway recorder prerequisite",
            "Fuel recorder not found (set CODETRACER_FUEL_RECORDER_PATH or build codetracer-fuel-recorder)",
        );
    }
    Some("sway-0.65".to_string())
}

/// `forc build` builds a PROJECT — a directory holding `Forc.toml` and
/// `src/main.sw` — and the Fuel recorder records the bytecode it produces at
/// `<project>/out/debug/<project-name>.bin`. The committed fixture is the bare
/// `main.sw`, so each run wraps it in a scratch project exactly as the
/// fixture's `regenerate.sh` does, named after the scenario so the bytecode
/// path matches.
///
/// Returns the project directory (the recorder's `source_path`) and the
/// `main.sw` inside it (what the trace names, and so what breakpoints must
/// address). The caller keeps `scratch` alive for the length of the test.
fn provision_forc_project(scratch: &std::path::Path, scenario: &str) -> (std::path::PathBuf, std::path::PathBuf) {
    let project = scratch.join(scenario);
    let src = project.join("src");
    std::fs::create_dir_all(&src).expect("create the scratch Forc project");
    let main_sw = src.join("main.sw");
    std::fs::copy(fixture_source("sway", scenario, "main.sw"), &main_sw).expect("copy the fixture into the project");
    std::fs::write(
        project.join("Forc.toml"),
        format!(
            "[project]\nname = \"{scenario}\"\nauthors = [\"CodeTracer\"]\nentry = \"main.sw\"\n\
             license = \"Apache-2.0\"\n\n[dependencies]\n"
        ),
    )
    .expect("write Forc.toml");
    (project, main_sw)
}

fn sway_config(
    project: std::path::PathBuf,
    main_sw: std::path::PathBuf,
    version: &str,
    line: u32,
    variable: &str,
) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: project,
        language: Language::Sway,
        version_label: version.to_string(),
        breakpoint_line: line,
        variable_name: variable.to_string(),
        max_hops: None,
        breakpoint_source_path: Some(main_sw),
    }
}

fn run_or_skip(scenario: &str, config: &OriginQueryConfig) -> Option<Box<origin_dap::OriginQueryResult>> {
    match load_fixture_and_query_or_skip(config) {
        QueryOutcome::Ok(r) => Some(r),
        QueryOutcome::Skipped(reason) => unavailable(required_mode(), &format!("sway/{scenario}"), &reason),
    }
}

#[test]
fn test_origin_sway_canonical_chain() {
    let Some(version) = require_sway_recorder() else {
        return;
    };
    // `main.sw` line 19 returns `c`; the chain for `c` is
    //   c -> b (TrivialCopy) -> a (TrivialCopy) -> Literal(10).
    let scratch = tempfile::tempdir().expect("scratch dir for the Forc project");
    let (project, main_sw) = provision_forc_project(scratch.path(), "simple_trivial_chain");
    let config = sway_config(project, main_sw, &version, 19, "c");
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
