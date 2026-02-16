//! Integration test for Python flow/omniscience support
//!
//! This test verifies that tree-sitter-python correctly extracts variables
//! and filters out function calls when loading flow data for Python programs.
//!
//! Python programs use DB-based traces (not rr), so this test does NOT require
//! `ct-rr-support` or `rr`. It uses the pure-Python recorder submodule.
//!
//! The test panics (not skips) if the Python recorder submodule is missing.

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{run_db_flow_test, FlowTestConfig, Language};

fn get_python_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/python/python_flow_test.py")
}

fn create_python_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // a=10, b=32, sum_val=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        source_path: get_python_source_path(),
        language: Language::Python,
        breakpoint_line: 14, // First line with local var: sum_val = a + b
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum_val".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        // print() and calculate_sum() should NOT appear as variables
        excluded_identifiers: vec!["print".to_string(), "calculate_sum".to_string()],
        expected_values,
    }
}

#[test]
fn test_python_flow_integration() {
    // Verify recorder is available — panics if submodule is missing
    let source_path = get_python_source_path();
    assert!(
        source_path.exists(),
        "Python test program not found at {}",
        source_path.display()
    );

    let config = create_python_flow_config();

    // Get Python version for labeling
    let version_label = std::process::Command::new("python")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            // Parse "Python 3.12.5"
            s.split_whitespace().nth(1).map(|v| v.to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    match run_db_flow_test(&config, &version_label) {
        Ok(()) => println!("Python flow integration test passed!"),
        Err(e) => panic!("Python flow integration test failed: {}", e),
    }
}
