//! Headless DAP flow test for Erlang materialized traces.
//!
//! Records the canonical Erlang fixture from codetracer-beam-recorder, launches
//! the real db-backend DAP stack, and verifies flow values through
//! ct-dap-client's FlowTestRunner. Companion to `elixir_flow_dap_test.rs`.
//!
//! The fixture lives at
//! `codetracer-beam-recorder/test-programs/erlang/canonical_flow/src/canonical_flow.erl`
//! and uses Erlang variable conventions (capitalized names: `A`, `B`,
//! `SumVal`, `Doubled`, `FinalResult`, `Result`) — the BEAM recorder's
//! manifest carries the language so the trace reader sees these correctly.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ct_dap_client::{
    DapStdioClient,
    test_support::{BreakpointCheck, FlowTestRunner, MultiBreakpointTestConfig},
    types::LaunchRequestArguments,
};

mod test_harness;
use test_harness::{Language, TestRecording, find_beam_recorder, find_erlang_flow_test};

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
fn e2e_codetracer_erlang_run_to_entry_stack_dap() {
    assert!(
        find_beam_recorder().is_some(),
        "codetracer-beam-recorder binary not found; run `just test-beam-flow` or set CODETRACER_BEAM_RECORDER_BIN"
    );

    let project_path = find_erlang_flow_test()
        .expect("canonical Erlang fixture not found; set CODETRACER_BEAM_RECORDER_PATH or CODETRACER_ERLANG_FLOW_TEST");
    let source_file = project_path.join("src/canonical_flow.erl");
    let recording = TestRecording::create_db_trace_with_format(&project_path, Language::Erlang, "erlang-entry", "ctfs")
        .expect("Erlang recording failed");

    let mut client = DapStdioClient::spawn(&find_db_backend()).expect("DAP spawn failed");
    client.initialize().expect("initialize failed");
    client
        .launch(LaunchRequestArguments {
            trace_folder: Some(recording.trace_dir.clone()),
            ..Default::default()
        })
        .expect("launch failed");
    client.configuration_done().expect("configurationDone failed");
    client
        .wait_for_stopped(Duration::from_secs(60))
        .expect("stopped event after run-to-entry");

    let stack = client.stack_trace().expect("stackTrace after run-to-entry");
    let top = stack
        .stack_frames
        .first()
        .expect("run-to-entry should expose at least one stack frame");
    let path = top
        .source
        .as_ref()
        .and_then(|source| source.path.as_deref())
        .unwrap_or("");
    // Compare as `Path`, not as raw strings: on Windows the recorder
    // stores native `\` separators while `source_file` was built with a
    // literal `/` in its last component, and `Path` equality is
    // separator-insensitive there.
    assert_eq!(
        Path::new(path),
        source_file.as_path(),
        "run-to-entry stack frame should point at the Erlang source file",
    );
    assert!(
        top.line > 0,
        "run-to-entry should land on a real Erlang source line, got {:?}",
        top
    );
    client.disconnect().expect("disconnect failed");
}

#[test]
fn e2e_codetracer_erlang_flow_dap() {
    assert!(
        find_beam_recorder().is_some(),
        "codetracer-beam-recorder binary not found; run `just test-beam-flow` or set CODETRACER_BEAM_RECORDER_BIN"
    );

    let project_path = find_erlang_flow_test()
        .expect("canonical Erlang fixture not found; set CODETRACER_BEAM_RECORDER_PATH or CODETRACER_ERLANG_FLOW_TEST");
    let source_file = project_path.join("src/canonical_flow.erl");
    assert!(
        source_file.exists(),
        "Erlang canonical source not found at {}",
        source_file.display()
    );

    let recording = TestRecording::create_db_trace_with_format(&project_path, Language::Erlang, "erlang-flow", "ctfs")
        .expect("Erlang recording failed");

    // The Erlang fixture mirrors the Elixir canonical_flow exactly, but
    // capitalized: A=10, B=32, SumVal=42, Doubled=84, FinalResult=94 inside
    // compute/0 (line 9 is the FinalResult assignment). In main/0, line 14
    // binds Result via `Result = compute()`, line 15 asserts it, line 16
    // formats it via `io:format("~p~n", [Result])`. The BEAM recorder emits
    // the most observable Result-bearing flow step at line 16 (the io:format
    // call), so we anchor the second breakpoint there — the equivalent of
    // the Elixir test's IO.puts/result inspection point.
    let config = MultiBreakpointTestConfig {
        source_file: source_file.to_str().unwrap().to_string(),
        breakpoints: vec![
            BreakpointCheck {
                line: 9,
                expected_variables: vec!["A", "B", "SumVal", "Doubled", "FinalResult"]
                    .into_iter()
                    .map(String::from)
                    .collect(),
                expected_values: expected_values(&[
                    ("A", 10),
                    ("B", 32),
                    ("SumVal", 42),
                    ("Doubled", 84),
                    ("FinalResult", 94),
                ]),
            },
            BreakpointCheck {
                line: 16,
                expected_variables: vec!["Result"].into_iter().map(String::from).collect(),
                expected_values: expected_values(&[("Result", 94)]),
            },
        ],
    };

    let db_backend = find_db_backend();
    let mut runner =
        FlowTestRunner::new_db_trace_with_timeout(&db_backend, &recording.trace_dir, Duration::from_secs(60))
            .expect("DAP init failed for Erlang trace");
    runner
        .run_multi_breakpoint(&config)
        .expect("Erlang flow DAP test failed");
    runner.finish().expect("disconnect failed");
}
