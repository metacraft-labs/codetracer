#![cfg(not(windows))]

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_wazero, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

#[test]
fn wasm_flow_dap_variables_and_values() {
    let db_backend = find_db_backend();

    let project_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/wasm");
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

    // Get wazero version for labeling
    let wazero_path = find_wazero().unwrap();
    let version_label = std::process::Command::new(&wazero_path)
        .arg("version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    // Record the trace — for WASM, source_path is the Cargo project directory
    let recording = TestRecording::create_db_trace(&project_path, Language::RustWasm, &version_label)
        .expect("WASM recording failed");

    // For WASM, the actual source file is src/main.rs within the project dir.
    // wazero stores absolute source paths, so suffix-match works.
    let breakpoint_source = project_path.join("src/main.rs");

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        breakpoint_line: 10,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["println".to_string(), "calculate_sum".to_string()],
        expected_values,
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner.run_and_verify(&config).expect("WASM flow test failed");
    runner.finish().expect("disconnect failed");
}
