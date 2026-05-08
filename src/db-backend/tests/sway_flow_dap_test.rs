//! Headless DAP flow tests for Sway/FuelVM traces.
//!
//! The recording pipeline compiles the Sway project with `forc build`,
//! then records the compiled bytecode via the Fuel recorder.

use std::path::PathBuf;

use ct_dap_client::test_support::FlowTestRunner;

mod test_harness;
use test_harness::{find_fuel_recorder, find_sway_flow_test, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Verify the full Sway recording + DAP pipeline works.
///
/// Records a trace from the compiled Sway bytecode, launches the DAP
/// server, and verifies the server initializes and reaches a stopped state.
/// The Fuel recorder emits register-level variables (r16, r17, etc.);
/// full source-level variable verification requires debug info support
/// which is tracked separately.
#[test]
#[ignore = "requires fuel-recorder + forc; run via: just test-sway-flow"]
fn sway_flow_dap_recording_and_launch() {
    assert!(
        find_fuel_recorder().is_some(),
        "Fuel recorder not found — set CODETRACER_FUEL_RECORDER_PATH or build codetracer-fuel-recorder"
    );

    let project_path = find_sway_flow_test().expect("Sway test project not found");
    let db_backend = find_db_backend();

    let recording = TestRecording::create_db_trace(&project_path, Language::Sway, "sway-flow")
        .expect("Sway recording failed — check that forc and codetracer-fuel-recorder are available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // Verify trace files exist
    // A modern CTFS bundle (`.ct`) is self-contained — `trace_metadata.json`
    // is no longer emitted (see Trace-Files/CTFS-Migration-Guide.md §3e).
    // The `.ct` container also satisfies the "trace data file" requirement,
    // so we collapse the two assertions into a single accept-either check.
    let trace_dir = &recording.trace_dir;
    let has_ct = trace_dir.join("trace.ct").exists()
        || std::fs::read_dir(trace_dir)
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok())
                    .any(|e| e.path().extension().is_some_and(|ext| ext == "ct"))
            })
            .unwrap_or(false);
    assert!(
        trace_dir.join("trace.bin").exists() || trace_dir.join("trace.json").exists() || has_ct,
        "No trace data file produced (expected trace.bin, trace.json, or *.ct)"
    );
    assert!(
        has_ct || trace_dir.join("trace_metadata.json").exists(),
        "neither *.ct nor trace_metadata.json found in {}",
        trace_dir.display()
    );

    // Verify DAP server launches and reaches stopped state
    let runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Sway trace");
    runner.finish().expect("disconnect failed");

    println!("Sway DAP recording + launch test passed!");
}
