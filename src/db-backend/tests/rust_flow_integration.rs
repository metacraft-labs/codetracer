//! Integration test for Rust flow/omniscience support
//!
//! This test verifies that tree-sitter correctly extracts variables
//! and filters out function calls when loading flow data for Rust programs.
//!
//! It needs `ct-native-replay` and rr (or TTD on Windows); see the platform
//! gate below.
//!
//! Rust uses rr-based traces on Unix and TTD-based traces on Windows.
//!
//! ## Platform gate
//!
//! The replay backend these tests record with is rr on Linux or TTD on
//! Windows; macOS has neither, so on macOS the target is not compiled (the
//! `cfg` below). Everywhere else a missing tool goes through
//! `test_harness::skip_or_fail_missing_prerequisite`: a failure under
//! `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false`, otherwise a reported skip.

#![cfg(any(target_os = "linux", target_os = "windows"))]

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
#[cfg(unix)]
use test_harness::{DapTestClient, TestRecording, flow_update_error};
use test_harness::{
    FlowTestConfig, Language, find_ct_native_replay, find_line_containing, is_command_available,
    is_replay_backend_available, run_flow_test,
};

fn get_rust_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/rust/rust_flow_test.rs")
}

fn create_rust_flow_config() -> FlowTestConfig {
    let source_path = get_rust_source_path();
    // The breakpoint goes on the first statement of `calculate_sum` that binds
    // a local, so `a` and `b` are in scope and the flow covers `sum`,
    // `doubled` and `final_result`.
    //
    // The line is RESOLVED FROM THE SOURCE. It used to be a literal `6`, which
    // was right while the fixture was 23 lines long. The `mcr_pinned_alloc`
    // preamble later prepended ~410 lines, line 6 became a comment, the
    // breakpoint resolved to no code, `continue` ran to the end of the trace
    // and the flow was requested there. The test then failed as "should find
    // at least some of the expected variables", which reads as a flow defect
    // (codetracer-pm issue 2026-10-21 "Rust rr flow worker segfaults in LLDB,
    // so the flow finds no variables"). See `find_line_containing`.
    let breakpoint_line = u32::try_from(find_line_containing(&source_path, "let sum = a + b;"))
        .expect("the fixture is far shorter than u32::MAX lines");

    let mut expected_values = HashMap::new();
    // a=10, b=32, sum=42, doubled=84, final_result=94
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    FlowTestConfig {
        source_path,
        language: Language::Rust,
        breakpoint_line,
        expected_variables: vec![
            "a".to_string(),
            "b".to_string(),
            "sum".to_string(),
            "doubled".to_string(),
            "final_result".to_string(),
        ],
        excluded_identifiers: vec!["println".to_string()],
        expected_values,
    }
}

#[test]
fn test_rust_flow_integration() {
    let Some(_ct_native_replay) = rust_rr_flow_prerequisites("test_rust_flow_integration") else {
        return;
    };

    let config = create_rust_flow_config();

    match run_flow_test(&config, &rustc_version_label()) {
        Ok(()) => println!("Rust flow integration test passed!"),
        Err(e) => panic!("Rust flow integration test failed: {}", e),
    }
}

/// A call flow requested where the replay stops at the END of the trace must
/// be refused by name, and the refusal must not cost a worker.
///
/// A `continue` with no breakpoint runs off the end of the recording and stops
/// at a location with no source position (`<unknown>:-1`). That is exactly
/// where the old `rust_flow_integration` asked for its flow once its anchor
/// went stale, and asking there killed the `flow` replay worker: the worker
/// seeked to the end-of-trace ticks and single-stepped into the exited
/// process, and LLDB's private state thread recursed through
/// `Process::UpdateThreadListIfNeeded` until its stack overflowed (SIGSEGV).
/// The db-backend then respawned the worker without saying so, ran the new
/// one to the program entry and answered with a seven-step flow of `main`
/// holding no variables — a "successful" flow that was wrong in every
/// particular (codetracer-pm issue 2026-10-21 "Rust rr flow worker segfaults
/// in LLDB, so the flow finds no variables").
///
/// The contract asserted here: the update is an error update whose reason
/// says the location has no source position, and it is that refusal rather
/// than a report of a dead worker — so a regression back to seeking the
/// worker into the exit fails this test either way it shows up.
///
/// Unix only: it drives the Unix-socket `DapTestClient`, the client
/// `run_flow_test` uses for rr recordings.
#[cfg(unix)]
#[test]
fn test_rust_flow_at_end_of_trace_is_refused_by_name() {
    const TEST_NAME: &str = "test_rust_flow_at_end_of_trace_is_refused_by_name";
    let Some(ct_native_replay) = rust_rr_flow_prerequisites(TEST_NAME) else {
        return;
    };

    let recording = TestRecording::create(
        &get_rust_source_path(),
        Language::Rust,
        &rustc_version_label(),
        &ct_native_replay,
    )
    .unwrap_or_else(|e| panic!("recording failed: {e}"));
    let mut client =
        DapTestClient::start(&recording.temp_dir, &ct_native_replay).unwrap_or_else(|e| panic!("DAP start: {e}"));
    client
        .initialize_and_launch(&recording, &ct_native_replay)
        .unwrap_or_else(|e| panic!("DAP launch: {e}"));

    // No breakpoint: the continue runs to the end of the recording.
    let end_of_trace = client
        .continue_to_breakpoint()
        .unwrap_or_else(|e| panic!("continue to the end of the trace: {e}"));
    println!(
        "Stopped at: {}:{} (rr_ticks {})",
        end_of_trace.path, end_of_trace.line, end_of_trace.rr_ticks.0
    );
    // The precondition this test is about. If a future backend reports a
    // source position at the end of the trace, the test no longer exercises
    // the refusal and must be rethought rather than pass vacuously.
    assert!(
        end_of_trace.line <= 0,
        "expected the end-of-trace stop to carry no source line, got {}:{}",
        end_of_trace.path,
        end_of_trace.line
    );

    let body = client
        .request_flow_update_body(end_of_trace)
        .unwrap_or_else(|e| panic!("no ct/updated-flow answered the flow request: {e}"));
    let reason = flow_update_error(&body)
        .unwrap_or_else(|| panic!("a flow at a location with no source position must be an error update, got: {body}"));
    println!("Flow refused: {reason}");
    assert!(
        reason.contains("no source position"),
        "the refusal must say why (no source position), got: {reason}"
    );
    assert!(
        !reason.contains("died"),
        "the flow must be refused before any worker is driven, not after one died: {reason}"
    );
}

/// Every prerequisite the rr Rust flow tests share, checked through
/// `skip_or_fail_missing_prerequisite`. Returns the `ct-native-replay` to use,
/// or `None` when the test was (gracefully) skipped.
fn rust_rr_flow_prerequisites(test_name: &str) -> Option<PathBuf> {
    let Some(ct_native_replay) = find_ct_native_replay() else {
        test_harness::skip_or_fail_missing_prerequisite(
            test_name,
            "ct-native-replay was not found",
            "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
        );
        return None;
    };

    if !is_replay_backend_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            test_name,
            "no replay backend: rr (Linux) or TTD (Windows, installed and elevated)",
            "install rr on Linux (on AMD Zen it needs the SpecLockMap workaround) or run elevated with Microsoft.TimeTravelDebugging on Windows",
        );
        return None;
    }

    if !is_command_available("rustc") {
        test_harness::skip_or_fail_missing_prerequisite(
            test_name,
            "rustc is not on PATH",
            "run inside the codetracer dev shell, which provides it, or install it",
        );
        return None;
    }
    Some(ct_native_replay)
}

/// The `rustc` version, used to label the recording directory.
fn rustc_version_label() -> String {
    std::process::Command::new("rustc")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.split_whitespace().nth(1).unwrap_or("unknown").to_string())
        .unwrap_or_else(|| "unknown".to_string())
}
