//! Integration test for Bash flow/omniscience support
//!
//! This test verifies that tree-sitter-bash correctly extracts variables
//! and filters out command names when loading flow data for Bash scripts.
//!
//! Bash programs use DB-based traces (not rr), so this test does NOT require
//! `ct-rr-support` or `rr`. It uses the codetracer-shell-recorders sibling repo.
//!
//! The test panics (not skips) if the Bash recorder is missing or not built.

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{run_db_flow_test, FlowTestConfig, Language};

fn get_bash_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/bash/bash_flow_test.sh")
}

fn create_bash_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // a=10, b=32, sum_val=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        source_path: get_bash_source_path(),
        language: Language::Bash,
        breakpoint_line: 13, // First line with local var: local sum_val=$(( a + b ))
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum_val".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        // Function names and command names should NOT appear as variables
        excluded_identifiers: vec!["echo".to_string(), "calculate_sum".to_string()],
        expected_values,
    }
}

#[test]
fn test_bash_flow_integration() {
    let source_path = get_bash_source_path();
    assert!(
        source_path.exists(),
        "Bash test program not found at {}",
        source_path.display()
    );

    let config = create_bash_flow_config();

    let version_label = std::process::Command::new("bash")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            s.lines()
                .next()
                .and_then(|l| l.split_whitespace().nth(3))
                .map(|v| v.to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    match run_db_flow_test(&config, &version_label) {
        Ok(()) => println!("Bash flow integration test passed!"),
        Err(e) => panic!("Bash flow integration test failed: {}", e),
    }
}
