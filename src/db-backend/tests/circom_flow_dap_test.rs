//! Headless DAP flow test for Circom (zero-knowledge circuit) traces.
//!
//! This test verifies that the DAP server correctly handles Circom traces
//! produced by the codetracer-circom-recorder. It follows the same pattern as
//! `masm_flow_dap_test.rs`, but targets the Circom/Wasm witness recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-circom-recorder` binary (set `CODETRACER_CIRCOM_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-circom-recorder/`)
//!
//! ## Test tiers
//!
//! - `circom_flow_dap_variables` (Tier 2): Breakpoint in `FlowTest` template, verifies
//!   basic arithmetic signal values (a, b, sum_val, doubled, out).
//!
//! Run with:
//!   `cargo nextest run circom_flow_dap`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording, find_circom_flow_test, find_circom_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Returns the path to the Circom flow test source file.
fn get_circom_source_path() -> PathBuf {
    find_circom_flow_test().expect(
        "Circom flow test program not found. \
         Check out codetracer-circom-recorder as a sibling repo, or ensure \
         test-programs/circom/flow_test.circom exists locally.",
    )
}

/// Shared helper that records a Circom trace, launches the DAP server, sets a
/// breakpoint at the given line, and verifies that the expected signals appear
/// with the correct values.
fn run_circom_dap_test(
    breakpoint_line: usize,
    expected_variables: Vec<&str>,
    expected_values: HashMap<String, i64>,
    excluded: Vec<&str>,
) {
    assert!(
        find_circom_recorder().is_some(),
        "Circom recorder not found. \
         Set CODETRACER_CIRCOM_RECORDER_PATH or build codetracer-circom-recorder \
         (run `cargo build` inside the codetracer-circom-recorder repo)."
    );

    let db_backend = find_db_backend();
    let source_path = get_circom_source_path();

    assert!(
        source_path.exists(),
        "Circom test program not found at {}",
        source_path.display()
    );

    let recording = TestRecording::create_db_trace(&source_path, Language::Circom, "circom-2.0")
        .expect("Circom recording failed -- check that codetracer-circom-recorder is available");

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
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Circom trace");
    runner.run_and_verify(&config).expect("Circom flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Circom DAP flow test passed!");
}

/// Tier 2 (DAP flow): Breakpoint in the `FlowTest` template after all signal
/// assignments complete.
///
/// Expected signals at line 15 (`out <== doubled + a`):
///   a        = 10
///   b        = 32
///   sum_val  = 42  (a + b)
///   doubled  = 84  (sum_val * 2)
///   out      = 94  (doubled + a)
#[test]
#[ignore = "requires circom-recorder; run via: just test-circom-flow"]
fn circom_flow_dap_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("out".to_string(), 94);

    run_circom_dap_test(
        15,
        vec!["a", "b", "sum_val", "doubled", "out"],
        expected_values,
        vec!["FlowTest"],
    );
}
