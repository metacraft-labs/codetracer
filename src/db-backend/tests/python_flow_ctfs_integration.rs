//! Integration test for Python flow using CTFS trace format
//!
//! Same as python_flow_integration but records traces in .ct CTFS format
//! instead of the default Binary (CBOR+Zstd) format.
//!
//! The recorder selects CTFS output when the `CODETRACER_TRACE_FORMAT` environment
//! variable is set to `"ctfs"`. The DAP server auto-detects the format from the
//! trace file header.

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use test_harness::{FlowTestConfig, Language, run_db_flow_test_with_format};

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
fn test_python_flow_ctfs_integration() {
    if test_harness::find_python_recorder().is_none() {
        eprintln!(
            "SKIPPED: Python recorder not found \
             (set CODETRACER_PYTHON_RECORDER_PATH or check out sibling/submodule)"
        );
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

    let source_path = get_python_source_path();
    assert!(
        source_path.exists(),
        "Python test program not found at {}",
        source_path.display()
    );

    let config = create_python_flow_config();

    match run_db_flow_test_with_format(&config, &version_label, "ctfs") {
        Ok(()) => println!("Python flow CTFS integration test passed!"),
        Err(e) => panic!("Python flow CTFS integration test failed: {}", e),
    }
}
