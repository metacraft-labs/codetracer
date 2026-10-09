//! DAP-level flow test for an Ada program recorded under the MCR backend.
//!
//! Mirrors `c_mcr_streaming_flow_test.rs`: drives `ct-native-replay record
//! --backend mcr` to produce a `.ct` streaming trace, launches the
//! db-backend DAP server against the trace, sets a breakpoint inside
//! `Calculate_Sum`, continues to it, and verifies local variable names
//! and values.
//!
//! The Ada program is built with `gnatmake` by ct-native-replay; the test
//! goes through `test_harness::skip_or_fail_missing_prerequisite` when
//! `ct-native-replay`, `ct-mcr` or the compiler is missing: a failure under
//! `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false`, otherwise a reported skip.

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording, find_line_containing};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
fn ada_mcr_streaming_flow_variables_and_values() {
    // --- pre-flight: MCR backend must be available ---
    let ct_native_replay = match test_harness::find_ct_native_replay() {
        Some(p) => p,
        None => {
            test_harness::skip_or_fail_missing_prerequisite(
                "ada_mcr_streaming_flow_variables_and_values",
                "ct-native-replay was not found",
                "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
            );
            return;
        }
    };

    if !test_harness::is_mcr_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            "ada_mcr_streaming_flow_variables_and_values",
            "the MCR recorder CLI (ct-mcr / ct_cli / CODETRACER_CT_MCR_CMD) was not found",
            "build the MCR CLI with `just build-ct-mcr` in codetracer-native-recorder, then put ct-mcr/ct_cli on PATH or set CODETRACER_CT_MCR_CMD",
        );
        return;
    }

    if !Language::Ada.compiler_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            "ada_mcr_streaming_flow_variables_and_values",
            "the Ada compiler (gnatmake) is not on PATH",
            "install GNAT (gnatmake)",
        );
        return;
    }

    let db_backend = find_db_backend();

    // --- locate the Ada test program ---
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/ada/ada_flow_test.adb");
    assert!(
        source_path.exists(),
        "Ada test program not found at {}",
        source_path.display()
    );

    // --- record under MCR ---
    let recording =
        TestRecording::create_mcr(&source_path, Language::Ada, "mcr", &ct_native_replay).expect("MCR recording failed");

    println!("MCR trace recorded at: {}", recording.trace_dir.display());

    // Linux: db-backend replays the trace through `ct-mcr debugserver`,
    // whose trace mode refuses it until HS-M2 U4b4, which returns this test
    // to replay; the refusal is asserted on the trace by name.
    if test_harness::mcr_linux_trace_mode_refused("ada_mcr_streaming_flow_variables_and_values", &recording.trace_dir) {
        return;
    }

    // --- configure expected flow data ---
    // Breakpoint on `return Final_Result;` inside Calculate_Sum, where all
    // locals are in scope: A = 10, B = 32, Sum_Val = 42, Doubled = 84,
    // Final_Result = 94.
    //
    // The line is DERIVED from the source rather than hard-coded. The
    // hard-coded value used to be 30, which is `end Calculate_Sum;` — one line
    // past the statement this comment names, and the function's epilogue.
    // Both lines carry DWARF rows here so the breakpoint resolved either way
    // and the drift stayed invisible; see `find_line_containing`.
    //
    // The needle carries the statement's indentation because the bare text
    // also occurs in this fixture's own header comment on line 6, and
    // `find_line_containing` refuses an ambiguous match rather than picking
    // one — which is how that was found.
    //
    // Ada is case-insensitive; GNAT's DWARF typically uses lowercase
    // identifier names — we therefore expect lowercase here.
    let breakpoint_line = find_line_containing(&source_path, "      return Final_Result;");

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "Ada".to_string(),
            "Text_IO".to_string(),
            "Integer_Text_IO".to_string(),
            "Put".to_string(),
            "New_Line".to_string(),
            "Calculate_Sum".to_string(),
        ],
        expected_values,
    };

    // --- run the DAP flow test ---
    let mut runner = FlowTestRunner::new(&db_backend, &recording.trace_dir).expect("DAP init failed for MCR trace");
    runner
        .run_and_verify(&config)
        .expect("Ada MCR streaming flow test failed");
    runner.finish().expect("disconnect failed");
}
