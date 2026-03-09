//! Integration test for WASM flow/omniscience support
//!
//! This test verifies that tree-sitter (using the Rust grammar) correctly
//! extracts variables and filters out function calls when loading flow data
//! for Rust programs compiled to WASM and recorded by wazero.
//!
//! WASM programs use DB-based traces produced by `wazero run --trace-dir`,
//! so this test does NOT require `ct-rr-support` or `rr`.
//!
//! Prerequisites:
//! - `wazero` must be on PATH or set via CODETRACER_WASM_VM_PATH
//! - `wasm32-wasip1` Rust target must be installed (`rustup target add wasm32-wasip1`)

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{find_wazero, run_db_flow_test, FlowTestConfig, Language};

/// Returns the path to the WASM test program Cargo project directory.
///
/// For WASM, `source_path` in FlowTestConfig points to the project root
/// (similar to Noir). The actual source file for breakpoints is `src/main.rs`.
fn get_wasm_project_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/wasm")
}

fn create_wasm_flow_config() -> FlowTestConfig {
    let mut expected_values = HashMap::new();
    // calculate_sum: a=10, b=32, sum_val=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        // For WASM, source_path is the project dir (used by build_wasm_test_program
        // and record_wasm_trace). The breakpoint is set on `src/main.rs`.
        source_path: get_wasm_project_path(),
        language: Language::RustWasm,
        // Line 10: `let sum_val = a + b;` in calculate_sum
        breakpoint_line: 10,
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum_val".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        // println! is a macro — the Rust grammar should filter it out.
        // calculate_sum is a function call in main(), should not appear as a variable.
        excluded_identifiers: vec!["println".to_string(), "calculate_sum".to_string()],
        expected_values,
    }
}

#[test]
fn test_wasm_flow_integration() {
    let project_path = get_wasm_project_path();
    assert!(
        project_path.join("Cargo.toml").exists(),
        "WASM test project not found at {}",
        project_path.display()
    );

    // Check wazero availability
    if find_wazero().is_none() {
        eprintln!("SKIPPED: wazero not found (set CODETRACER_WASM_VM_PATH or add wazero to PATH)");
        return;
    }

    // Check wasm32-wasip1 target is available
    let target_check = std::process::Command::new("rustup")
        .args(["target", "list", "--installed"])
        .output();
    if let Ok(output) = target_check {
        let targets = String::from_utf8_lossy(&output.stdout);
        if !targets.contains("wasm32-wasip1") {
            eprintln!("SKIPPED: wasm32-wasip1 target not installed (run: rustup target add wasm32-wasip1)");
            return;
        }
    }

    let config = create_wasm_flow_config();

    // Get wazero version for labeling
    let wazero_path = find_wazero().unwrap();
    let version_label = std::process::Command::new(&wazero_path)
        .arg("version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    match run_db_flow_test(&config, &version_label) {
        Ok(()) => println!("WASM flow integration test passed!"),
        Err(e) => panic!("WASM flow integration test failed: {}", e),
    }
}
