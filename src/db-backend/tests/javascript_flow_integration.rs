//! Integration test for JavaScript flow/omniscience support
//!
//! This test verifies that tree-sitter-javascript correctly extracts variables
//! and filters out function calls when loading flow data for JavaScript programs.
//!
//! JavaScript programs use DB-based traces (not rr), so this test does NOT require
//! `ct-rr-support` or `rr`. It uses the codetracer-js-recorder sibling repo.
//!
//! The test panics (not skips) if the JavaScript recorder is missing or not built.

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{run_db_flow_test, FlowTestConfig, Language};

fn get_javascript_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/javascript/javascript_flow_test.js")
}

fn create_javascript_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // a=10, b=32, sum_val=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        source_path: get_javascript_source_path(),
        language: Language::JavaScript,
        breakpoint_line: 11, // First line with local var: var sum_val = a + b;
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum_val".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        // console and calculate_sum should NOT appear as variables
        excluded_identifiers: vec!["console".to_string(), "calculate_sum".to_string()],
        expected_values,
    }
}

#[test]
fn test_javascript_flow_integration() {
    // Verify recorder is available -- panics if missing or not built
    let source_path = get_javascript_source_path();
    assert!(
        source_path.exists(),
        "JavaScript test program not found at {}",
        source_path.display()
    );

    let config = create_javascript_flow_config();

    // Get Node.js version for labeling
    let version_label = std::process::Command::new("node")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    match run_db_flow_test(&config, &version_label) {
        Ok(()) => println!("JavaScript flow integration test passed!"),
        Err(e) => panic!("JavaScript flow integration test failed: {}", e),
    }
}
