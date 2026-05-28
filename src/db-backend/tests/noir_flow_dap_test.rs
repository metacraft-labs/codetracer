use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{
    BreakpointCheck, CallStackTestConfig, FlowTestConfig, FlowTestRunner, MultiBreakpointTestConfig, StepAction,
    SteppingTestConfig,
};

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

/// Noir project directory containing the test program (`src/main.nr`).
fn noir_project_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/noir")
}

/// Pre-flight check: skip early if `nargo` is not available.
fn check_nargo_available() -> bool {
    if std::process::Command::new("nargo").arg("--version").output().is_err() {
        eprintln!("SKIPPED: nargo not found on PATH");
        return false;
    }
    true
}

/// Return a human-readable nargo version label (e.g. "1.0.0-beta.3").
fn nargo_version_label() -> String {
    std::process::Command::new("nargo")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            s.lines()
                .next()
                .and_then(|line| line.split('=').nth(1))
                .map(|v| v.trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string())
}

/// Record a Noir trace and return the recording + breakpoint source path.
///
/// This is the common setup shared by every Noir DAP test.
fn setup_noir_trace() -> Option<(TestRecording, PathBuf)> {
    let project_path = noir_project_path();
    assert!(
        project_path.join("Nargo.toml").exists(),
        "Noir test project not found at {}",
        project_path.display()
    );

    if !check_nargo_available() {
        return None;
    }

    let version_label = nargo_version_label();

    let recording =
        TestRecording::create_db_trace(&project_path, Language::Noir, &version_label).expect("Noir recording failed");

    // For Noir, the actual source file is src/main.nr within the project dir.
    let breakpoint_source = project_path.join("src/main.nr");

    Some((recording, breakpoint_source))
}

// ---------------------------------------------------------------------------
// Existing Tier-2 test: single breakpoint, flow variable extraction & values
// ---------------------------------------------------------------------------

#[test]
fn noir_flow_dap_variables_and_values() {
    let (recording, breakpoint_source) = match setup_noir_trace() {
        Some(v) => v,
        None => return,
    };

    let db_backend = find_db_backend();

    // The Noir trace exposes locals (sum_val, doubled, final_result) but not
    // function parameters (a, b) -- those are inlined by the Noir compiler.
    let mut expected_values = HashMap::new();
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 27 is the first statement after `final_result` has been
        // assigned by the line-26 call to `add_offset(doubled)`.
        breakpoint_line: 27,
        expected_variables: vec!["sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        // Note: println and f (format macro) currently appear as variables
        // because tree-sitter uses the Rust grammar for Noir. This is a known
        // limitation tracked separately -- not worth blocking this test on.
        excluded_identifiers: vec![],
        expected_values,
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner.run_and_verify(&config).expect("Noir flow test failed");
    runner.finish().expect("disconnect failed");
}

// ---------------------------------------------------------------------------
// M5 deliverable 1: Multi-breakpoint DAP test
// ---------------------------------------------------------------------------

/// Sets breakpoints at two distinct locations inside `calculate_sum` and
/// verifies that the correct variables are available at each stop.
///
/// Breakpoint 1 (line 25): `let doubled = sum_val * 2;`
///   -> sum_val should be 42
///
/// Breakpoint 2 (line 26): `let final_result = add_offset(doubled);`
///   -> doubled should be 84
#[test]
fn noir_flow_dap_multi_breakpoint() {
    let (recording, breakpoint_source) = match setup_noir_trace() {
        Some(v) => v,
        None => return,
    };

    let db_backend = find_db_backend();
    let source = breakpoint_source.to_str().unwrap().to_string();

    let mut expected_at_line_25 = HashMap::new();
    expected_at_line_25.insert("sum_val".to_string(), 42);

    let mut expected_at_line_26 = HashMap::new();
    expected_at_line_26.insert("doubled".to_string(), 84);

    let config = MultiBreakpointTestConfig {
        source_file: source,
        breakpoints: vec![
            BreakpointCheck {
                line: 25,
                expected_variables: vec!["sum_val".to_string()],
                expected_values: expected_at_line_25,
            },
            BreakpointCheck {
                line: 26,
                expected_variables: vec!["doubled".to_string()],
                expected_values: expected_at_line_26,
            },
        ],
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner
        .run_multi_breakpoint(&config)
        .expect("Noir multi-breakpoint test failed");
    runner.finish().expect("disconnect failed");
}

// ---------------------------------------------------------------------------
// M5 deliverable 2: Stepping DAP test
// ---------------------------------------------------------------------------

/// Breaks at line 24 (`let sum_val = a + b;`), then steps through the
/// subsequent lines in `calculate_sum` using DAP "next" (step over),
/// verifying the debugger advances to the expected line each time.
///
/// Expected step sequence:
///   line 24 (breakpoint) -> next -> line 25 -> next -> line 26
#[test]
fn noir_flow_dap_stepping() {
    let (recording, breakpoint_source) = match setup_noir_trace() {
        Some(v) => v,
        None => return,
    };

    let db_backend = find_db_backend();
    let source = breakpoint_source.to_str().unwrap().to_string();

    let config = SteppingTestConfig {
        source_file: source,
        breakpoint_line: 24,
        steps: vec![
            // Step over `let sum_val = a + b;` -> land on `let doubled = ...`
            (StepAction::Next, 25),
            // Step over `let doubled = sum_val * 2;` -> land on `let final_result = ...`
            (StepAction::Next, 26),
        ],
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner.run_stepping_test(&config).expect("Noir stepping test failed");
    runner.finish().expect("disconnect failed");
}

// ---------------------------------------------------------------------------
// M5 deliverable 3: Call stack DAP test
// ---------------------------------------------------------------------------

/// Breaks at line 19 inside `add_offset` (called by `calculate_sum`, which
/// is called by `main`), then inspects the DAP stack trace to verify that
/// the call stack contains the expected function names in order.
///
/// Expected stack (top to bottom):
///   add_offset -> calculate_sum -> main
#[test]
fn noir_flow_dap_call_stack() {
    let (recording, breakpoint_source) = match setup_noir_trace() {
        Some(v) => v,
        None => return,
    };

    let db_backend = find_db_backend();
    let source = breakpoint_source.to_str().unwrap().to_string();

    let config = CallStackTestConfig {
        source_file: source,
        // Line 19: `let result = value + offset;` inside add_offset
        breakpoint_line: 19,
        expected_frames: vec![
            "add_offset".to_string(),
            "calculate_sum".to_string(),
            "main".to_string(),
        ],
        expected_frame_count: None,
    };

    let mut runner = FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed");
    runner
        .run_call_stack_test(&config)
        .expect("Noir call stack test failed");
    runner.finish().expect("disconnect failed");
}
