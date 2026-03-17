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
    let (_python_cmd, version_label) = match test_harness::find_suitable_python() {
        Some(pair) => pair,
        None => {
            eprintln!("SKIPPED: Python 3.10+ not found (needed for the recorder)");
            return;
        }
    };

    let db_backend = find_db_backend();

    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/python/python_flow_test.py");
    assert!(
        source_path.exists(),
        "Python test program not found at {}",
        source_path.display()
    );

    // Record the trace using the existing test_harness recording infrastructure
    let recording = TestRecording::create_db_trace(&source_path, Language::Python, &version_label)
        .expect("Python recording failed");

    // Diagnostic: dump trace files so CI logs reveal what the recorder produced
    let trace_paths_file = recording.trace_dir.join("trace_paths.json");
    if let Ok(paths_json) = std::fs::read_to_string(&trace_paths_file) {
        println!("trace_paths.json: {}", paths_json);
    } else {
        println!("trace_paths.json not found at {}", trace_paths_file.display());
    }
    let trace_metadata_file = recording.trace_dir.join("trace_metadata.json");
    if let Ok(meta_json) = std::fs::read_to_string(&trace_metadata_file) {
        println!("trace_metadata.json: {}", meta_json);
    }

    // The Python recorder stores source paths as bare filenames (relative to its
    // CWD, which is trace_dir). Use the trace-dir copy path for the breakpoint.
    let breakpoint_source = recording.trace_dir.join(source_path.file_name().unwrap());
    println!("breakpoint_source: {}", breakpoint_source.display());
    println!("trace_dir: {}", recording.trace_dir.display());

    // Also check what the canonical path looks like (macOS /var vs /private/var)
    if let Ok(canon) = recording.trace_dir.canonicalize() {
        println!("trace_dir (canonical): {}", canon.display());
    }

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
    let result = runner.run_and_verify(&config);
    // Print db-backend stderr for diagnostics regardless of result
    let stderr = runner.client().recent_stderr(50);
    if !stderr.is_empty() {
        println!("\n=== db-backend stderr ===");
        for line in &stderr {
            println!("  {}", line);
        }
        println!("=== end db-backend stderr ===");
    }
    result.expect("Python flow test failed");
    runner.finish().expect("disconnect failed");
}
