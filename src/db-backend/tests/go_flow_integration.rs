//! Integration test for Go flow/omniscience support
//!
//! This test verifies that tree-sitter-go correctly extracts variables
//! and filters out function calls when loading flow data for Go programs.
//! Go programs are debugged through Delve (not LLDB), which is transparent
//! to the DAP flow infrastructure.
//!
//! The test is skipped if `ct-rr-support`, `rr`, or `dlv` is not available.

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{find_ct_rr_support, is_rr_available, run_flow_test, FlowTestConfig, Language};

fn get_go_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // Note: the file must NOT end in `_test.go` because Go treats such files
    // as test sources and excludes them from `go build`.
    manifest_dir.join("test-programs/go/go_flow_program.go")
}

fn create_go_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // a=10, b=32, sum=42, doubled=84, finalResult=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("finalResult".to_string(), 94);

    FlowTestConfig {
        source_path: get_go_source_path(),
        language: Language::Go,
        breakpoint_line: 14, // First line with local var: sum := a + b
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum".to_string(),
            "doubled".to_string(),
            "finalResult".to_string(),
        ],
        // fmt.Println is a function call and should NOT appear as a variable
        excluded_identifiers: vec!["Println".to_string(), "fmt".to_string()],
        expected_values,
    }
}

/// Check if Delve (dlv) is available — required for Go debugging.
fn is_delve_available() -> bool {
    std::process::Command::new("dlv").arg("version").output().is_ok()
}

#[test]
#[ignore] // requires rr+dlv pipeline; can hang in CI — run explicitly with --ignored
fn test_go_flow_integration() {
    // Check prerequisites
    if find_ct_rr_support().is_none() {
        eprintln!("SKIPPED: ct-rr-support not found in PATH or development locations");
        return;
    }

    if !is_rr_available() {
        eprintln!("SKIPPED: rr is not available");
        return;
    }

    if !is_delve_available() {
        eprintln!("SKIPPED: dlv (Delve) is not available — required for Go debugging");
        return;
    }

    let config = create_go_flow_config();

    // Get Go version for labeling
    let version_label = std::process::Command::new("go")
        .arg("version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            // Parse "go version go1.23.4 linux/amd64"
            s.split_whitespace()
                .nth(2)
                .map(|v| v.strip_prefix("go").unwrap_or(v).to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());

    match run_flow_test(&config, &version_label) {
        Ok(()) => println!("Go flow integration test passed!"),
        Err(e) => panic!("Go flow integration test failed: {}", e),
    }
}
