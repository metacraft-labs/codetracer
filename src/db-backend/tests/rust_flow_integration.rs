//! Integration test for Rust flow/omniscience support
//!
//! This test verifies that tree-sitter correctly extracts variables
//! and filters out function calls when loading flow data for Rust programs.
//!
//! It needs `ct-native-replay` and rr (or TTD on Windows); see the platform
//! gate below.
//!
//! Rust uses rr-based traces on Unix and TTD-based traces on Windows.
//!
//! ## Platform gate
//!
//! The replay backend these tests record with is rr on Linux or TTD on
//! Windows; macOS has neither, so on macOS the target is not compiled (the
//! `cfg` below). Everywhere else a missing tool goes through
//! `test_harness::skip_or_fail_missing_prerequisite`: a failure under
//! `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false`, otherwise a reported skip.

#![cfg(any(target_os = "linux", target_os = "windows"))]

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{
    FlowTestConfig, Language, find_ct_native_replay, is_command_available, is_replay_backend_available, run_flow_test,
};

fn get_rust_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/rust/rust_flow_test.rs")
}

fn create_rust_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // a=10, b=32, sum=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        source_path: get_rust_source_path(),
        language: Language::Rust,
        breakpoint_line: 6, // First line with local var: let sum = a + b;
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        excluded_identifiers: vec!["println".to_string()],
        expected_values: expected_values.into(),
    }
}

#[test]
fn test_rust_flow_integration() {
    // Check prerequisites
    if find_ct_native_replay().is_none() {
        test_harness::skip_or_fail_missing_prerequisite(
            "test_rust_flow_integration",
            "ct-native-replay was not found",
            "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
        );
        return;
    }

    if !is_replay_backend_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            "test_rust_flow_integration",
            "no replay backend: rr (Linux) or TTD (Windows, installed and elevated)",
            "install rr on Linux (on AMD Zen it needs the SpecLockMap workaround) or run elevated with Microsoft.TimeTravelDebugging on Windows",
        );
        return;
    }

    if !is_command_available("rustc") {
        test_harness::skip_or_fail_missing_prerequisite(
            "test_rust_flow_integration",
            "rustc is not on PATH",
            "run inside the codetracer dev shell, which provides it, or install it",
        );
        return;
    }

    let config = create_rust_flow_config();

    // Get Rust version for labeling
    let version_label = std::process::Command::new("rustc")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.split_whitespace().nth(1).unwrap_or("unknown").to_string())
        .unwrap_or_else(|| "unknown".to_string());

    match run_flow_test(&config, &version_label) {
        Ok(()) => println!("Rust flow integration test passed!"),
        Err(e) => panic!("Rust flow integration test failed: {}", e),
    }
}
