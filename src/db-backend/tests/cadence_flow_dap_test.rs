//! Headless DAP flow test for Cadence/Flow traces.
//!
//! Records a Cadence script via the flow recorder (Go helper + Rust converter),
//! launches the DAP server, and verifies variable extraction.

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{Language, TestRecording, find_cadence_flow_test, find_cadence_recorder};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Full Cadence flow test: record → DAP → breakpoint → verify variables.
///
/// The recording pipeline builds the Go helper (`cadence-trace-helper`) from
/// the flow-recorder's `go-helper/` directory, runs it against the Cadence
/// source, then converts the NDJSON output to CodeTracer trace format.
#[test]
#[ignore = "requires flow-recorder + go helper; run via: just test-cadence-flow"]
fn cadence_flow_dap_variables() {
    assert!(
        find_cadence_recorder().is_some(),
        "Cadence/Flow recorder not found — build codetracer-flow-recorder"
    );

    let source = find_cadence_flow_test()
        .expect("Cadence test program not found — check codetracer-flow-recorder/test-programs/cadence/flow_test.cdc");
    let db_backend = find_db_backend();

    let recording = TestRecording::create_db_trace(&source, Language::Cadence, "cadence-flow")
        .expect("Cadence recording failed — check that codetracer-flow-recorder and go-helper are available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // The Cadence trace should contain variables a, b, sum_val, doubled, final_result
    // with correct values from the compute() function.
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source.to_str().unwrap().to_string(),
        breakpoint_line: 6,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["compute".to_string(), "main".to_string()],
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Cadence trace");
    runner.run_and_verify(&config).expect("Cadence flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Cadence DAP flow test passed!");
}
