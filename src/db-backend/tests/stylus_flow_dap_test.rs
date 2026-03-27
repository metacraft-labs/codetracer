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
/// The hardcoded path embedded in the fixture's trace.json and trace_paths.json
/// from the original recording machine.
const FIXTURE_ORIGINAL_SOURCE: &str = "/home/zahary/metacraft/codetracer/test-programs/stylus_fund_tracker/src/lib.rs";

fn prepare_fixture_copy(fixture_dir: &Path, project_path: &Path) -> PathBuf {
    let tmp_dir = std::env::temp_dir().join(format!("stylus-fixture-{}", std::process::id()));
    if tmp_dir.exists() {
        fs::remove_dir_all(&tmp_dir).expect("failed to clean temp fixture dir");
    }
    fs::create_dir_all(&tmp_dir).expect("failed to create temp fixture dir");

    // Compute the canonical actual source path for this checkout.
    let actual_source = project_path
        .join("src/lib.rs")
        .canonicalize()
        .expect("failed to canonicalize source path");
    let actual_source_str = actual_source.to_str().unwrap().to_string();
    // On Windows, canonicalize() produces extended-length paths with a `\\?\`
    // prefix (e.g. `\\?\D:\a\...`) and uses backslashes. Strip the prefix and
    // normalize to forward slashes so the replacement string is valid inside
    // JSON files (raw backslashes like `\t` in `\test-programs` would be
    // interpreted as escape sequences by JSON parsers).
    #[cfg(windows)]
    let actual_source_str = {
        let s = actual_source_str
            .strip_prefix(r"\\?\")
            .unwrap_or(&actual_source_str)
            .replace('\\', "/");
        s
    };

    // Copy fixture files, rewriting any embedded hardcoded paths.
    // Both trace.json (Path entries) and trace_paths.json contain the
    // recording-time absolute path that must match the current checkout.
    for entry in fs::read_dir(fixture_dir).expect("failed to read fixture dir") {
        let entry = entry.expect("failed to read dir entry");
        let dest = tmp_dir.join(entry.file_name());
        let content = fs::read_to_string(entry.path()).unwrap_or_default();
        if content.contains(FIXTURE_ORIGINAL_SOURCE) {
            let rewritten = content.replace(FIXTURE_ORIGINAL_SOURCE, &actual_source_str);
            fs::write(&dest, rewritten).expect("failed to write rewritten fixture file");
        } else {
            fs::copy(entry.path(), &dest).expect("failed to copy fixture file");
        }
    }

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
    let canonical_source = breakpoint_source
        .canonicalize()
        .expect("failed to canonicalize breakpoint source");
    let canonical_source_str = canonical_source.to_str().unwrap().to_string();
    // Strip Windows extended-length path prefix and normalize to forward
    // slashes so the path matches what was written into the fixture files.
    #[cfg(windows)]
    let canonical_source_str = {
        let s = canonical_source_str
            .strip_prefix(r"\\?\")
            .unwrap_or(&canonical_source_str)
            .replace('\\', "/");
        s
    };
    println!("Working fixture: {}", working_fixture.display());
    println!("Rewritten trace_paths.json: {rewritten_paths}");
    println!("Breakpoint source (canonical): {canonical_source_str}");

    // We expect `pari` to be visible at line 59 (inside fund()).
    // pari is U256, which the trace encodes as BigInt — FlowTestConfig.expected_values
    // only supports i64, so we verify variable presence but skip value comparison.
    let config = FlowTestConfig {
        source_file: canonical_source_str.clone(),
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
