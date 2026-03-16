#![cfg(not(windows))]

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

#[test]
fn python_flow_dap_variables_and_values() {
    if test_harness::find_python_recorder().is_none() {
        eprintln!("SKIPPED: Python recorder not found");
        return;
    }

    // The Python recorder uses PEP 604 union syntax (X | None) which requires Python 3.10+.
    let python_cmd = if std::process::Command::new("python3").arg("--version").output().is_ok() {
        "python3"
    } else {
        "python"
    };
    let python_version = std::process::Command::new(python_cmd)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.split_whitespace().nth(1).map(|v| v.to_string()));
    if let Some(ref ver) = python_version {
        let parts: Vec<u32> = ver.split('.').filter_map(|p| p.parse().ok()).collect();
        if parts.len() >= 2 && (parts[0] < 3 || (parts[0] == 3 && parts[1] < 10)) {
            eprintln!("SKIPPED: Python {} is too old (need 3.10+ for the recorder)", ver);
            return;
        }
    }

    let db_backend = find_db_backend();

    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/python/python_flow_test.py");
    assert!(
        source_path.exists(),
        "Python test program not found at {}",
        source_path.display()
    );

    // Get Python version for labeling
    let version_label = std::process::Command::new(python_cmd)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.split_whitespace().nth(1).map(|v| v.to_string()))
        .unwrap_or_else(|| "unknown".to_string());

    // Record the trace using the existing test_harness recording infrastructure
    let recording = TestRecording::create_db_trace(&source_path, Language::Python, &version_label)
        .expect("Python recording failed");

    // For Python, breakpoint path must be the trace-dir copy (recorder stores relative paths)
    let breakpoint_source = recording.trace_dir.join(source_path.file_name().unwrap());

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        breakpoint_line: 14,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["print".to_string(), "calculate_sum".to_string()],
        expected_values,
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner.run_and_verify(&config).expect("Python flow test failed");
    runner.finish().expect("disconnect failed");
}
