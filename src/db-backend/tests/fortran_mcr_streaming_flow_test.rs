//! DAP-level flow test for a Fortran program recorded under the MCR backend.
//!
//! Mirrors `c_mcr_streaming_flow_test.rs`: drives `ct-native-replay record
//! --backend mcr` to produce a `.ct` streaming trace, launches the
//! db-backend DAP server against the trace, sets a breakpoint inside
//! `calculate_sum`, continues to it, and verifies local variable names
//! and values.
//!
//! The Fortran program is built with `gfortran` by ct-native-replay; the
//! test skips cleanly if either `ct-native-replay` or `ct-mcr` is missing.

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
fn fortran_mcr_streaming_flow_variables_and_values() {
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

    if !Language::Fortran.compiler_available() {
        eprintln!("SKIPPED: Fortran compiler (gfortran) not found on PATH");
        return;
    }

    let db_backend = find_db_backend();

    // --- locate the Fortran test program ---
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/fortran/fortran_flow_test.f90");
    assert!(
        source_path.exists(),
        "Fortran test program not found at {}",
        source_path.display()
    );

    // --- record under MCR ---
    let recording = TestRecording::create_mcr(&source_path, Language::Fortran, "mcr", &ct_rr_support)
        .expect("MCR recording failed");

    println!("MCR trace recorded at: {}", recording.trace_dir.display());

    // --- configure expected flow data ---
    // Breakpoint at line 31 (`print *, "Final:", final_result`) inside
    // calculate_sum(). At this point all locals should be in scope:
    //   a = 10, b = 32, sum_val = 42, doubled = 84, final_result = 94
    //
    // Note: Fortran is case-insensitive but debug info typically lowercases
    // identifiers; we expect the lowercase forms here.
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line: 31,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["print".to_string(), "calculate_sum".to_string()],
        expected_values,
    };

    // --- run the DAP flow test ---
    let mut runner = FlowTestRunner::new(&db_backend, &recording.trace_dir).expect("DAP init failed for MCR trace");
    runner
        .run_and_verify(&config)
        .expect("Fortran MCR streaming flow test failed");
    runner.finish().expect("disconnect failed");
}
