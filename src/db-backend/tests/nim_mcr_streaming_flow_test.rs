//! DAP-level flow test for a Nim program recorded under the MCR backend.
//!
//! This mirrors the RR-based Nim flow test but uses `ct-native-replay record --backend mcr`
//! to produce a `.ct` streaming trace instead of an rr trace directory.
//!
//! The test:
//! 1. Builds a Nim test program via `ct-native-replay build`
//! 2. Records it with MCR (`--backend mcr`), producing a `.ct` trace
//! 3. Launches db-backend's DAP server against the `.ct` trace
//! 4. Sets a breakpoint inside `calculateSum`, continues to it
//! 5. Loads flow data and verifies local variable names and values

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
fn nim_mcr_streaming_flow_variables_and_values() {
    // --- pre-flight: MCR backend must be available ---
    let ct_native_replay = match test_harness::find_ct_native_replay() {
        Some(p) => p,
        None => {
            test_harness::skip_or_fail_missing_prerequisite(
                "nim_mcr_streaming_flow_variables_and_values",
                "ct-native-replay was not found",
                "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
            );
            return;
        }
    };

    if !test_harness::is_mcr_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            "nim_mcr_streaming_flow_variables_and_values",
            "the MCR recorder CLI (ct-mcr / ct_cli / CODETRACER_CT_MCR_CMD) was not found",
            "build the MCR CLI with `just build-ct-mcr` in codetracer-native-recorder, then put ct-mcr/ct_cli on PATH or set CODETRACER_CT_MCR_CMD",
        );
        return;
    }

    let db_backend = find_db_backend();

    // --- locate the Nim test program ---
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/nim/nim_flow_test.nim");
    assert!(
        source_path.exists(),
        "Nim test program not found at {}",
        source_path.display()
    );

    // --- record under MCR ---
    let recording =
        TestRecording::create_mcr(&source_path, Language::Nim, "mcr", &ct_native_replay).expect("MCR recording failed");

    println!("MCR trace recorded at: {}", recording.trace_dir.display());

    // Linux: db-backend replays the trace through `ct-mcr debugserver`,
    // whose trace mode refuses it until HS-M2 U4b4, which returns this test
    // to replay; the refusal is asserted on the trace by name.
    if test_harness::mcr_linux_trace_mode_refused("nim_mcr_streaming_flow_variables_and_values", &recording.trace_dir) {
        return;
    }

    // --- configure expected flow data ---
    // Breakpoint at line 13 (`return final`) inside calculateSum().
    // At this point all locals should be in scope:
    //   a = 10, b = 32, sum = 42, doubled = 84, final = 94
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 13,
        expected_variables: vec!["a", "b", "sum", "doubled", "final"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["echo".to_string(), "calculateSum".to_string()],
        expected_values,
    };

    // --- run the DAP flow test ---
    let mut runner = FlowTestRunner::new(&db_backend, &recording.trace_dir).expect("DAP init failed for MCR trace");
    runner
        .run_and_verify(&config)
        .expect("Nim MCR streaming flow test failed");
    runner.finish().expect("disconnect failed");
}
