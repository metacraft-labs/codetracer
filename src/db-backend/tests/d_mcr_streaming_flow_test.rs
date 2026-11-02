//! DAP-level flow test for a D program recorded under the MCR backend.
//!
//! Mirrors `c_mcr_streaming_flow_test.rs`: drives `ct-native-replay record
//! --backend mcr` to produce a `.ct` streaming trace, launches the
//! db-backend DAP server against the trace, sets a breakpoint inside
//! `calculate_sum`, continues to it, and verifies local variable names
//! and values.
//!
//! The D program is built with `ldc2` by ct-native-replay; the test
//! goes through `test_harness::skip_or_fail_missing_prerequisite` when
//! `ct-native-replay`, `ct-mcr` or the compiler is missing: a failure under
//! `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false`, otherwise a reported skip.

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
fn d_mcr_streaming_flow_variables_and_values() {
    // --- pre-flight: MCR backend must be available ---
    let ct_native_replay = match test_harness::find_ct_native_replay() {
        Some(p) => p,
        None => {
            test_harness::skip_or_fail_missing_prerequisite(
                "d_mcr_streaming_flow_variables_and_values",
                "ct-native-replay was not found",
                "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
            );
            return;
        }
    };

    if !test_harness::is_mcr_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            "d_mcr_streaming_flow_variables_and_values",
            "the MCR recorder CLI (ct-mcr / ct_cli / CODETRACER_CT_MCR_CMD) was not found",
            "build the MCR CLI with `just build-ct-mcr` in codetracer-native-recorder, then put ct-mcr/ct_cli on PATH or set CODETRACER_CT_MCR_CMD",
        );
        return;
    }

    if !Language::D.compiler_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            "d_mcr_streaming_flow_variables_and_values",
            "no D compiler (gdc/ldc2/dmd) on PATH",
            "install gdc, ldc2 or dmd",
        );
        return;
    }

    let db_backend = find_db_backend();

    // --- locate the D test program ---
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/d/d_flow_test.d");
    assert!(
        source_path.exists(),
        "D test program not found at {}",
        source_path.display()
    );

    // --- record under MCR ---
    let recording =
        TestRecording::create_mcr(&source_path, Language::D, "mcr", &ct_native_replay).expect("MCR recording failed");

    println!("MCR trace recorded at: {}", recording.trace_dir.display());

    // --- configure expected flow data ---
    // Breakpoint at line 19 (`return final_result;`) inside calculate_sum().
    // At this point all locals should be in scope:
    //   a = 10, b = 32, sum = 42, doubled = 84, final_result = 94
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 19,
        expected_variables: vec!["a", "b", "sum", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["writeln".to_string(), "calculate_sum".to_string()],
        expected_values,
    };

    // --- run the DAP flow test ---
    let mut runner = FlowTestRunner::new(&db_backend, &recording.trace_dir).expect("DAP init failed for MCR trace");
    runner
        .run_and_verify(&config)
        .expect("D MCR streaming flow test failed");
    runner.finish().expect("disconnect failed");
}
