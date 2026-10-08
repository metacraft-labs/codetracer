//! Headless DAP flow test for Solana/SBF traces.
//!
//! Compiles the recorder's Solana flow test program to an SBF ELF with
//! `cargo-build-sbf`, records its execution with `codetracer-solana-recorder`
//! (both through `test_harness::record_solana_trace`), and verifies the DAP
//! server can launch and process the recording.

use std::path::PathBuf;

use ct_dap_client::test_support::FlowTestRunner;

mod test_harness;
use test_harness::{Language, TestRecording, find_solana_flow_test, find_solana_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Record the Solana flow test program and verify the DAP server can launch
/// and process the recording.
#[test]
fn solana_flow_dap_recording_and_launch() {
    if find_solana_recorder().is_none() {
        test_harness::skip_or_fail_missing_prerequisite(
            "solana_flow_dap_test",
            "Solana recorder not found — build codetracer-solana-recorder",
            "check out the recorder sibling and build it (`just build-recorder-siblings`)",
        );
        return;
    }

    let source = find_solana_flow_test().expect("Solana test program not found");
    let db_backend = find_db_backend();

    // Compile the program to SBF and record it (see record_solana_trace).
    let recording = TestRecording::create_db_trace(&source, Language::Solana, "solana-flow")
        .expect("Solana recording failed — check that codetracer-solana-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // The recorder writes one CTFS container, named after the ELF it ran.
    let containers: Vec<PathBuf> = std::fs::read_dir(&recording.trace_dir)
        .expect("read the trace dir")
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "ct"))
        .collect();
    assert_eq!(
        containers.len(),
        1,
        "the recorder must write exactly one .ct container in {}, found {:?}",
        recording.trace_dir.display(),
        containers
    );

    // Verify DAP server launches and reaches stopped state.
    let runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Solana trace");
    runner.finish().expect("disconnect failed");

    println!("Solana DAP recording + launch test passed!");
}
