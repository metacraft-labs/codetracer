//! Headless DAP flow test for Elixir materialized traces.
//!
//! Records the canonical Mix fixture from codetracer-elixir-recorder, launches
//! the real db-backend DAP stack, and verifies flow values through
//! ct-dap-client's FlowTestRunner.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use ct_dap_client::test_support::{BreakpointCheck, FlowTestRunner, MultiBreakpointTestConfig};

mod test_harness;
use test_harness::{find_elixir_flow_test, find_elixir_recorder, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

fn expected_values(values: &[(&str, i64)]) -> HashMap<String, i64> {
    values
        .iter()
        .map(|(name, value)| ((*name).to_string(), *value))
        .collect()
}

#[test]
fn e2e_codetracer_elixir_flow_dap() {
    assert!(
        find_elixir_recorder().is_some(),
        "codetracer-elixir-recorder binary not found; run `just test-elixir-flow` or set CODETRACER_ELIXIR_RECORDER_BIN"
    );

    let project_path = find_elixir_flow_test().expect(
        "canonical Elixir fixture not found; set CODETRACER_ELIXIR_RECORDER_PATH or CODETRACER_ELIXIR_FLOW_TEST",
    );
    let source_file = project_path.join("lib/canonical_flow.ex");
    assert!(
        source_file.exists(),
        "Elixir canonical source not found at {}",
        source_file.display()
    );

    let recording = TestRecording::create_db_trace_with_format(&project_path, Language::Elixir, "elixir-flow", "ctfs")
        .expect("Elixir recording failed");

    let config = MultiBreakpointTestConfig {
        source_file: source_file.to_str().unwrap().to_string(),
        breakpoints: vec![
            BreakpointCheck {
                line: 9,
                expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
                    .into_iter()
                    .map(String::from)
                    .collect(),
                expected_values: expected_values(&[
                    ("a", 10),
                    ("b", 32),
                    ("sum_val", 42),
                    ("doubled", 84),
                    ("final_result", 94),
                ]),
            },
            BreakpointCheck {
                line: 16,
                expected_variables: vec!["result"].into_iter().map(String::from).collect(),
                expected_values: expected_values(&[("result", 94)]),
            },
        ],
    };

    let db_backend = find_db_backend();
    let mut runner =
        FlowTestRunner::new_db_trace_with_timeout(&db_backend, &recording.trace_dir, Duration::from_secs(60))
            .expect("DAP init failed for Elixir trace");
    runner
        .run_multi_breakpoint(&config)
        .expect("Elixir flow DAP test failed");
    runner.finish().expect("disconnect failed");
}
