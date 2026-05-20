//! Headless DAP flow test for Tolk/TON traces.
//!
//! This test verifies that the DAP server correctly handles Tolk traces
//! produced by the codetracer-ton-recorder. It follows the same pattern as
//! `masm_flow_dap_test.rs`, but targets the Tolk/TVM recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-ton-recorder` binary (set `CODETRACER_TOLK_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-ton-recorder/`)
//!
//! ## Test tiers
//!
//! - `tolk_flow_dap_variables` (Tier 2): Breakpoint in `compute()` fn, verifies
//!   basic arithmetic results across 5 locals.
//!
//! Run with:
//!   `cargo nextest run tolk_flow_dap`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording, find_tolk_flow_test, find_tolk_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Returns the path to the Tolk flow test source file.
fn get_tolk_source_path() -> PathBuf {
    find_tolk_flow_test().expect(
        "Tolk flow test program not found. \
         Check out codetracer-ton-recorder as a sibling repo, or ensure \
         test-programs/tolk/flow_test.tolk exists locally.",
    )
}

/// Shared helper that records a Tolk trace, launches the DAP server, sets a
/// breakpoint at the given line, and verifies that the expected locals appear
/// with the correct values.
fn run_tolk_dap_test(
    breakpoint_line: usize,
    expected_variables: Vec<&str>,
    expected_values: HashMap<String, i64>,
    excluded: Vec<&str>,
) {
    assert!(
        find_tolk_recorder().is_some(),
        "Tolk/TON recorder not found. \
         Set CODETRACER_TOLK_RECORDER_PATH or build codetracer-ton-recorder \
         (run `cargo build` inside the codetracer-ton-recorder repo)."
    );

    let db_backend = find_db_backend();
    let source_path = get_tolk_source_path();

    assert!(
        source_path.exists(),
        "Tolk test program not found at {}",
        source_path.display()
    );

    let recording = TestRecording::create_db_trace(&source_path, Language::Tolk, "tolk-0.6")
        .expect("Tolk recording failed -- check that codetracer-ton-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // Use the original source path — the trace stores the absolute path as recorded,
    // not the trace-dir copy.
    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line,
        expected_variables: expected_variables.into_iter().map(String::from).collect(),
        excluded_identifiers: excluded.into_iter().map(String::from).collect(),
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Tolk trace");
    runner.run_and_verify(&config).expect("Tolk flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Tolk DAP flow test passed!");
}

/// Tier 2 (DAP flow): Breakpoint in the `compute()` function after all 5
/// locals are assigned.
///
/// Expected local variables at line 6 (`var final_result`):
///   a            = 10
///   b            = 32
///   sum_val      = 42  (a + b)
///   doubled      = 84  (sum_val * 2)
///   final_result = 94  (doubled + a)
#[test]
#[ignore = "requires ton-recorder; run via: just test-tolk-flow"]
fn tolk_flow_dap_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    run_tolk_dap_test(
        6,
        vec!["a", "b", "sum_val", "doubled", "final_result"],
        expected_values,
        vec!["compute", "main"],
    );
}
