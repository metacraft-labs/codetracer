//! Integration test for Noir flow/omniscience support
//!
//! This test verifies that tree-sitter (using the Rust grammar, since Noir's
//! syntax is Rust-inspired) correctly extracts variables and filters out
//! function calls when loading flow data for Noir programs.
//!
//! Noir programs use DB-based traces produced by `nargo trace`, so this test
//! does NOT require `ct-rr-support` or `rr`.
//!
//! Prerequisites:
//! - `nargo` must be on PATH (provided by the codetracer nix shell)

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{run_db_flow_test, FlowTestConfig, Language};

/// Returns the path to the Noir project directory (not a single source file).
///
/// For Noir, `nargo trace` is run inside the project directory, so the
/// "source_path" in FlowTestConfig points to the project root. The actual
/// source file for breakpoints is `src/main.nr` within this directory.
fn get_noir_project_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/noir")
}

fn create_noir_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // Witness: x=10, y=32
    // calculate_sum: a=10, b=32, sum_val=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        // For Noir, source_path is the project dir (used by record_noir_trace).
        // The breakpoint is set on the actual .nr source file.
        source_path: get_noir_project_path(),
        language: Language::Noir,
        // Line 13: `let sum_val = a + b;` in calculate_sum
        breakpoint_line: 13,
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum_val".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        // TODO: Noir reuses the Rust tree-sitter grammar, but Noir's `println(...)`
        // is a regular function call (not a macro like Rust's `println!(...)`).
        // The Rust grammar parses it as an identifier, so it currently leaks into
        // the variable list. Once Noir-specific filtering is added to
        // expr_loader.rs, add "println" and "calculate_sum" here.
        excluded_identifiers: vec![],
        expected_values,
    }
}

#[test]
#[ignore] // requires nargo (our Noir fork) on PATH; run via `just test-noir-flow`
fn test_noir_flow_integration() {
    let project_path = get_noir_project_path();
    assert!(
        project_path.join("Nargo.toml").exists(),
        "Noir test project not found at {}",
        project_path.display()
    );

    let config = create_noir_flow_config();

    // Get nargo version for labeling
    let version_label = std::process::Command::new("nargo")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            // Parse "nargo version = 1.0.0-beta.2\n..."
            s.lines()
                .next()
                .and_then(|line| line.split('=').nth(1))
                .map(|v| v.trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    match run_db_flow_test(&config, &version_label) {
        Ok(()) => println!("Noir flow integration test passed!"),
        Err(e) => panic!("Noir flow integration test failed: {}", e),
    }
}
