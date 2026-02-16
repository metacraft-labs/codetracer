//! Integration test for Ruby flow/omniscience support
//!
//! This test verifies that tree-sitter-ruby correctly extracts variables
//! and filters out method calls when loading flow data for Ruby programs.
//!
//! Ruby programs use DB-based traces (not rr), so this test does NOT require
//! `ct-rr-support` or `rr`. It uses the pure-Ruby recorder submodule.
//!
//! The test panics (not skips) if the Ruby recorder submodule is missing.

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{run_db_flow_test, FlowTestConfig, Language};

fn get_ruby_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/ruby/ruby_flow_test.rb")
}

fn create_ruby_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // a=10, b=32, sum_val=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        source_path: get_ruby_source_path(),
        language: Language::Ruby,
        breakpoint_line: 10, // First line with local var: sum_val = a + b
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum_val".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        // puts and calculate_sum should NOT appear as variables
        excluded_identifiers: vec!["puts".to_string(), "calculate_sum".to_string()],
        expected_values,
    }
}

#[test]
fn test_ruby_flow_integration() {
    // Verify recorder is available — panics if submodule is missing
    let source_path = get_ruby_source_path();
    assert!(
        source_path.exists(),
        "Ruby test program not found at {}",
        source_path.display()
    );

    let config = create_ruby_flow_config();

    // Get Ruby version for labeling
    let version_label = std::process::Command::new("ruby")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            // Parse "ruby 3.3.0 (2023-12-25 revision 5124f9ac75) [x86_64-linux]"
            s.split_whitespace().nth(1).map(|v| v.to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    match run_db_flow_test(&config, &version_label) {
        Ok(()) => println!("Ruby flow integration test passed!"),
        Err(e) => panic!("Ruby flow integration test failed: {}", e),
    }
}
