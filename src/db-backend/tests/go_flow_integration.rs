//! Integration test for Go flow/omniscience support
//!
//! This test verifies that tree-sitter-go correctly extracts variables
//! and filters out function calls when loading flow data for Go programs.
//! Go programs are debugged through Delve (not LLDB), which is transparent
//! to the DAP flow infrastructure.
//!
//! It needs `ct-native-replay`, rr (or TTD on Windows), go and `dlv`; see the
//! platform gate below.
//!
//! Go uses rr-based traces on Unix and TTD-based traces on Windows.
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
fn test_go_flow_integration() {
    // Check prerequisites
    if find_ct_native_replay().is_none() {
        test_harness::skip_or_fail_missing_prerequisite(
            "test_go_flow_integration",
            "ct-native-replay was not found",
            "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
        );
        return;
    }

    if !is_replay_backend_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            "test_go_flow_integration",
            "no replay backend: rr (Linux) or TTD (Windows, installed and elevated)",
            "install rr on Linux (on AMD Zen it needs the SpecLockMap workaround) or run elevated with Microsoft.TimeTravelDebugging on Windows",
        );
        return;
    }

    if !is_command_available("go") {
        test_harness::skip_or_fail_missing_prerequisite(
            "test_go_flow_integration",
            "go is not on PATH",
            "run inside the codetracer dev shell, which provides it, or install it",
        );
        return;
    }

    if !is_delve_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            "test_go_flow_integration",
            "dlv (Delve), required for Go debugging, is not on PATH",
            "install Delve (`go install github.com/go-delve/delve/cmd/dlv@latest`)",
        );
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
