//! DAP-level flow test for a Go program recorded under the MCR backend.
//!
//! Mirrors `c_mcr_streaming_flow_test.rs`: drives `ct-native-replay record
//! --backend mcr` to produce a `.ct` streaming trace, launches the
//! db-backend DAP server against the trace, sets a breakpoint inside
//! `calculateSum`, continues to it, and verifies local variable names
//! and values.
//!
//! The Go program is built with `go build` by ct-native-replay; the test
//! skips cleanly if either `ct-native-replay` or `ct-mcr` is missing.

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
fn go_mcr_streaming_flow_variables_and_values() {
    // --- pre-flight: MCR backend must be available ---
    let ct_rr_support = match test_harness::find_ct_rr_support() {
        Some(p) => p,
        None => {
            eprintln!("SKIPPED: ct-native-replay not found");
            return;
        }
    };

    if !test_harness::is_mcr_available() {
        eprintln!("SKIPPED: MCR backend not available (ct-mcr not found)");
        return;
    }

    let db_backend = find_db_backend();

    // --- locate the Go test program ---
    // Note: the file must NOT end in `_test.go` because Go treats such
    // files as test sources and excludes them from `go build`.
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/go/go_flow_program.go");
    assert!(
        source_path.exists(),
        "Go test program not found at {}",
        source_path.display()
    );

    // --- record under MCR ---
    let recording = TestRecording::create_mcr(&source_path, Language::Go, "mcr", &ct_rr_support)
        .expect("MCR recording failed");

    println!("MCR trace recorded at: {}", recording.trace_dir.display());

    // --- configure expected flow data ---
    // Breakpoint at line 20 (`return finalResult`) inside calculateSum().
    // At this point all locals should be in scope:
    //   a = 10, b = 32, sum = 42, doubled = 84, finalResult = 94
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("finalResult".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 20,
        expected_variables: vec!["a", "b", "sum", "doubled", "finalResult"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["fmt".to_string(), "Println".to_string(), "calculateSum".to_string()],
        expected_values,
    };

    // --- run the DAP flow test ---
    let mut runner = FlowTestRunner::new(&db_backend, &recording.trace_dir).expect("DAP init failed for MCR trace");
    runner
        .run_and_verify(&config)
        .expect("Go MCR streaming flow test failed");
    runner.finish().expect("disconnect failed");
}
