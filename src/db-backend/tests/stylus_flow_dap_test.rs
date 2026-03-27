//! Headless DAP flow test for Stylus (Arbitrum WASM) traces.
//!
//! Uses the pre-recorded fixture at `tests/fixtures/stylus-fund-trace/` to verify
//! that the DAP server correctly handles Stylus traces containing both DWARF-based
//! Step/Call/Function entries and EVM host function Event entries.
//!
//! This test does NOT require a devnode — it works offline with the fixture.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Stylus trace fixture directory.
fn get_stylus_fixture_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("tests/fixtures/stylus-fund-trace")
}

/// Copy the fixture to a temp directory and rewrite `trace_paths.json` so that
/// the hardcoded recording-time paths are replaced with the current checkout's
/// actual source paths. This is necessary because the fixture was recorded on a
/// specific machine and the DAP server resolves breakpoints by matching against
/// `trace_paths.json` entries.
fn prepare_fixture_copy(fixture_dir: &Path, project_path: &Path) -> PathBuf {
    let tmp_dir = std::env::temp_dir().join(format!("stylus-fixture-{}", std::process::id()));
    if tmp_dir.exists() {
        fs::remove_dir_all(&tmp_dir).expect("failed to clean temp fixture dir");
    }
    fs::create_dir_all(&tmp_dir).expect("failed to create temp fixture dir");

    // Copy all fixture files.
    for entry in fs::read_dir(fixture_dir).expect("failed to read fixture dir") {
        let entry = entry.expect("failed to read dir entry");
        let dest = tmp_dir.join(entry.file_name());
        fs::copy(entry.path(), &dest).expect("failed to copy fixture file");
    }

    // Rewrite trace_paths.json: replace the old source path with the current one.
    let trace_paths_file = tmp_dir.join("trace_paths.json");
    let actual_source = project_path.join("src/lib.rs");
    let new_paths =
        serde_json::to_string(&vec![actual_source.to_str().unwrap()]).expect("failed to serialize trace_paths");
    fs::write(&trace_paths_file, new_paths).expect("failed to write trace_paths.json");

    tmp_dir
}

/// Tier 2 (DAP flow): Verify the DAP server can load a Stylus trace fixture,
/// set a breakpoint inside the `fund()` method, hit it, and extract flow data
/// with the expected variables.
///
/// The fixture trace was recorded from a `fund(2)` transaction on a local
/// Arbitrum devnode. The `fund()` method at line 59 of `lib.rs` contains:
///   `let mut new_fund = self.funds.grow();`
///
/// Expected variables at the breakpoint: `pari` (the function parameter, U256=2).
/// `self` and `new_fund` may also appear depending on DWARF scope handling.
#[test]
fn stylus_flow_dap_variables() {
    let db_backend = find_db_backend();
    let fixture_dir = get_stylus_fixture_dir();

    assert!(
        fixture_dir.join("trace.json").exists(),
        "Stylus fixture not found at {}",
        fixture_dir.display()
    );

    // The fixture references lib.rs from the stylus_fund_tracker project.
    let project_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test-programs/stylus_fund_tracker");
    let breakpoint_source = project_path.join("src/lib.rs");
    assert!(
        breakpoint_source.exists(),
        "Stylus source not found at {}",
        breakpoint_source.display()
    );

    // Copy fixture and rewrite trace_paths.json to use current checkout paths.
    let working_fixture = prepare_fixture_copy(&fixture_dir, &project_path);

    // Diagnostic: verify the rewrite happened.
    let rewritten_paths = fs::read_to_string(working_fixture.join("trace_paths.json"))
        .expect("failed to read rewritten trace_paths.json");
    println!("Working fixture: {}", working_fixture.display());
    println!("Rewritten trace_paths.json: {rewritten_paths}");
    println!("Breakpoint source: {}", breakpoint_source.display());

    // We expect `pari` to be visible at line 59 (inside fund()).
    // pari is U256, which the trace encodes as BigInt — FlowTestConfig.expected_values
    // only supports i64, so we verify variable presence but skip value comparison.
    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        breakpoint_line: 59,
        expected_variables: vec!["pari".to_string()],
        // Stylus macros (sol_storage!, #[public]) expand to generated code;
        // no specific identifiers to exclude at this point.
        excluded_identifiers: vec![],
        // Skip value comparison: pari is U256 (BigInt), not representable as i64.
        expected_values: HashMap::new(),
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &working_fixture).expect("DAP init failed for Stylus fixture");

    match runner.run_and_verify(&config) {
        Ok(()) => {
            println!("Stylus flow DAP test passed!");
            println!("  Breakpoint at lib.rs:59, variable 'pari' found in flow data");
        }
        Err(e) => {
            // If the flow test fails, print diagnostic info before panicking.
            eprintln!("Stylus flow DAP test failed: {e}");
            eprintln!("  This may happen if DWARF scope data doesn't expose variables");
            eprintln!("  at the expected breakpoint line. Check the fixture trace.");
            panic!("Stylus flow DAP test failed: {e}");
        }
    }

    runner.finish().expect("disconnect failed");

    // Clean up temp fixture.
    let _ = fs::remove_dir_all(&working_fixture);
}
