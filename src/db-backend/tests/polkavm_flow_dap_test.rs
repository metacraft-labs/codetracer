//! Headless DAP flow test for PolkaVM traces.
//!
//! This test verifies that the DAP server correctly handles PolkaVM traces
//! produced by the codetracer-polkavm-recorder. It follows the same pattern as
//! `masm_flow_dap_test.rs`, but targets the PolkaVM/RISC-V recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-polkavm-recorder` binary (set `CODETRACER_POLKAVM_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-polkavm-recorder/`)
//!
//! ## Test tiers
//!
//! - `polkavm_flow_dap_variables` (Tier 2): Breakpoint in `compute()` fn, verifies
//!   basic arithmetic results across 5 locals (a, b, sum_val, doubled, final_result).
//!
//! Run with:
//!   `cargo nextest run polkavm_flow_dap`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording, find_polkavm_flow_test, find_polkavm_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Returns the path to the PolkaVM flow test source file.
///
/// Discovers the test program from the sibling `codetracer-polkavm-recorder` repo
/// (canonical location), falling back to the local `test-programs/` directory if
/// the sibling is not available.
fn get_polkavm_source_path() -> PathBuf {
    find_polkavm_flow_test().expect(
        "PolkaVM flow test program not found. \
         Check out codetracer-polkavm-recorder as a sibling repo, or ensure \
         test-programs/polkavm/flow_test.rs exists locally.",
    )
}

/// Shared helper that records a PolkaVM trace, launches the DAP server, sets a
/// breakpoint at the given line, and verifies that the expected locals appear
/// with the correct values.
fn run_polkavm_dap_test(
    breakpoint_line: usize,
    expected_variables: Vec<&str>,
    expected_values: HashMap<String, i64>,
    excluded: Vec<&str>,
) {
    assert!(
        find_polkavm_recorder().is_some(),
        "PolkaVM recorder not found. \
         Set CODETRACER_POLKAVM_RECORDER_PATH or build codetracer-polkavm-recorder \
         (run `cargo build` inside the codetracer-polkavm-recorder repo)."
    );

    let db_backend = find_db_backend();
    let source_path = get_polkavm_source_path();

    assert!(
        source_path.exists(),
        "PolkaVM test program not found at {}",
        source_path.display()
    );

    let recording = TestRecording::create_db_trace(&source_path, Language::PolkaVM, "polkavm-0.1")
        .expect("PolkaVM recording failed -- check that codetracer-polkavm-recorder is available");

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
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for PolkaVM trace");
    runner.run_and_verify(&config).expect("PolkaVM flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("PolkaVM DAP flow test passed!");
}

/// Tier 2 (DAP flow): Breakpoint at the last instruction step where all
/// computed values are visible in registers.
///
/// The PolkaVM recorder traces at the instruction level (no DWARF source-level
/// debug info from ProgramBlobBuilder blobs). Register names are used instead
/// of source-level variable names:
///
///   arg0 = 94  (final_result = doubled + a)
///   arg1 = 32  (b, unchanged after initial load)
///   S0   = 42  (sum_val = a + b)
///   S1   = 84  (doubled = sum_val * 2)
///
/// The breakpoint line (16) corresponds to the last `add_32` instruction
/// in the blob, where arg0 has been updated to the final result.
#[test]
#[ignore = "requires polkavm-recorder; run via: just test-polkavm-flow"]
fn polkavm_flow_dap_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("arg0".to_string(), 94);
    expected_values.insert("arg1".to_string(), 32);
    expected_values.insert("S0".to_string(), 42);
    expected_values.insert("S1".to_string(), 84);

    run_polkavm_dap_test(16, vec!["arg0", "arg1", "S0", "S1"], expected_values, vec!["main"]);
}
