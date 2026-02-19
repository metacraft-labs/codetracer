//! Integration test for Nim flow/omniscience support
//!
//! This test verifies that tree-sitter-nim correctly extracts variables
//! and filters out function calls when loading flow data for Nim programs.
//!
//! The test is skipped if `ct-rr-support` or `rr` is not available.

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{find_ct_rr_support, is_rr_available, run_flow_test, FlowTestConfig, Language};

fn get_nim_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/nim/nim_flow_test.nim")
}

fn create_nim_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // a=10, b=32, sum=42, doubled=84, final=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final".to_string(), 94);

    FlowTestConfig {
        source_path: get_nim_source_path(),
        language: Language::Nim,
        breakpoint_line: 7, // First line with local var: let sum = a + b
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum".to_string(),
            "doubled".to_string(),
            "final".to_string(),
        ],
        excluded_identifiers: vec!["echo".to_string()],
        expected_values,
    }
}

#[test]
#[ignore] // requires rr pipeline; can hang in CI — run explicitly with --ignored
fn test_nim_flow_integration() {
    // Check prerequisites
    if find_ct_rr_support().is_none() {
        eprintln!("SKIPPED: ct-rr-support not found in PATH or development locations");
        return;
    }

    if !is_rr_available() {
        eprintln!("SKIPPED: rr is not available");
        return;
    }

    let config = create_nim_flow_config();

    // Get Nim version for labeling
    let version_label = std::process::Command::new("nim")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            // Parse "Nim Compiler Version 1.6.20 [Linux: amd64]"
            s.lines()
                .next()
                .and_then(|line| line.split_whitespace().nth(3))
                .map(|v| v.to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    match run_flow_test(&config, &version_label) {
        Ok(()) => println!("Nim flow integration test passed!"),
        Err(e) => panic!("Nim flow integration test failed: {}", e),
    }
}
