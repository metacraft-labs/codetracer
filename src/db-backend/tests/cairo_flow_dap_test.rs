//! Headless DAP flow test for Cairo/StarkNet traces.
//!
//! This test verifies that the DAP server correctly handles Cairo traces
//! produced by the codetracer-cairo-recorder. It follows the same pattern as
//! `masm_flow_dap_test.rs`, but targets the Cairo/Sierra recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-cairo-recorder` binary (set `CODETRACER_CAIRO_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-cairo-recorder/`)
//!
//! ## Test tiers
//!
//! - `cairo_flow_dap_variables` (Tier 2): Breakpoint in `compute()` fn, verifies
//!   basic arithmetic results across 5 locals (a, b, sum_val, doubled, final_result).
//!
//! Run with:
//!   `cargo nextest run cairo_flow_dap`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner, StepAction, SteppingTestConfig};

mod test_harness;
use test_harness::{Language, TestRecording, find_cairo_flow_test, find_cairo_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Returns the path to the Cairo flow test source file.
fn get_cairo_source_path() -> PathBuf {
    find_cairo_flow_test().expect(
        "Cairo flow test program not found. \
         Check out codetracer-cairo-recorder as a sibling repo, or ensure \
         test-programs/cairo/flow_test.cairo exists locally.",
    )
}

/// Shared helper that records a Cairo trace, launches the DAP server, sets a
/// breakpoint at the given line, and verifies that the expected locals appear
/// with the correct values.
fn run_cairo_dap_test(
    breakpoint_line: usize,
    expected_variables: Vec<&str>,
    expected_values: HashMap<String, i64>,
    excluded: Vec<&str>,
) {
    assert!(
        find_cairo_recorder().is_some(),
        "Cairo recorder not found. \
         Set CODETRACER_CAIRO_RECORDER_PATH or build codetracer-cairo-recorder \
         (run `cargo build` inside the codetracer-cairo-recorder repo)."
    );

    let db_backend = find_db_backend();
    let source_path = get_cairo_source_path();

    assert!(
        source_path.exists(),
        "Cairo test program not found at {}",
        source_path.display()
    );

    let recording = TestRecording::create_db_trace(&source_path, Language::Cairo, "cairo-2.0")
        .expect("Cairo recording failed -- check that codetracer-cairo-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // Use the original source path for breakpoints — the trace stores the
    // absolute path of the source file as recorded, not the trace-dir copy.
    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line,
        expected_variables: expected_variables.into_iter().map(String::from).collect(),
        excluded_identifiers: excluded.into_iter().map(String::from).collect(),
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Cairo trace");
    runner.run_and_verify(&config).expect("Cairo flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Cairo DAP flow test passed!");
}

/// Tier 2 (DAP stepping): Verify that "next" advances the line in Cairo traces.
///
/// Sets a breakpoint at line 2 (let a), steps twice, and verifies the
/// debugger advances to lines 3 and 4 respectively.
/// This is the headless equivalent of the GUI "next" button test.
#[test]
#[ignore = "requires cairo-recorder; run via: just test-cairo-flow"]
fn cairo_flow_dap_stepping() {
    assert!(find_cairo_recorder().is_some(), "Cairo recorder not found.");

    let db_backend = find_db_backend();
    let source_path = get_cairo_source_path();

    let recording =
        TestRecording::create_db_trace(&source_path, Language::Cairo, "cairo-step").expect("Cairo recording failed");

    let config = SteppingTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 2,
        steps: vec![
            (StepAction::Next, 3), // let a → let b
            (StepAction::Next, 4), // let b → let sum_val
        ],
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Cairo trace");
    runner.run_stepping_test(&config).expect("Cairo stepping test failed");
    runner.finish().expect("disconnect failed");

    println!("Cairo DAP stepping test passed!");
}

/// Tier 2 (DAP flow): Breakpoint in the `compute()` function after all 5
/// locals are assigned.
///
/// Expected local variables at line 6 (`let final_result`):
///   a            = 10
///   b            = 32
///   sum_val      = 42  (a + b)
///   doubled      = 84  (sum_val * 2)
///   final_result = 94  (doubled + a)
#[test]
#[ignore = "requires cairo-recorder; run via: just test-cairo-flow"]
fn cairo_flow_dap_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    run_cairo_dap_test(
        6,
        vec!["a", "b", "sum_val", "doubled", "final_result"],
        expected_values,
        vec!["compute", "main"],
    );
}
