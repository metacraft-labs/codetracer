//! DAP-level tracepoint test for a C program recorded under the MCR backend.
//!
//! The test:
//! 1. Builds `test-programs/c/c_flow_test.c` and records it with MCR
//!    (`ct-native-replay record --backend mcr`), as the MCR flow tests do.
//! 2. Launches db-backend's DAP server against the recording, which replays
//!    it through `ct-native-replay` and `ct-mcr debugserver` (the stage0
//!    emulator replay of the recording, on Linux).
//! 3. Loads the terminal output (`ct/load-terminal`) and compares it with the
//!    program's own standard output, run here: the recording's event log
//!    also holds generic system calls (logged under the `Write` kind with
//!    `fd` -1 and the call's output bytes, codetracer-specs
//!    `spec/Trace-Files/MCR-Event-Log-Stream.md` §2.2), and only the writes
//!    to descriptors 1 and 2 are terminal output.  Before
//!    `CTFSTraceReader::load_native_terminal_events` checked the descriptor,
//!    a `prlimit64`'s bytes were glued in front of the first line.
//! 4. Runs two tracepoints (`ct/run-tracepoints`): `log(final_result)` on the
//!    `return final_result;` line of `calculate_sum` and `log(i)` on the
//!    `sum += i;` line of `with_loops`' `for` loop, and checks the values in
//!    execution order: 94, then 0 to 9.  The expected values are the
//!    program's arithmetic (`calculate_sum(10, 32)`, `with_loops(10)`), which
//!    its printed output confirms (`Final: 94`, `for sum: 45`).
//!
//! What step 4 guards: `handle_trace_steps` must go to the start of the
//! recording BEFORE it adds the tracepoint breakpoints.  A recreator
//! replay's `jump_to(StepId(0))` is a run-to-entry that ends by deleting
//! every breakpoint of the session (`DeleteBreakpoints`); with the
//! breakpoints added first, they were deleted with it and the run went to
//! the end with no tracepoint hit (zero values).
//!
//! No mocks: the recorder records a real program, db-backend, ct-native-replay
//! and `ct-mcr debugserver` are the shipping binaries, the client speaks DAP
//! over stdio.  Recording under MCR's default attach needs a host with CPUID
//! faulting; on one without it the recording fails and so does this test.

use std::path::PathBuf;
use std::process::Command;

use ct_dap_client::test_support::{
    ExpectedTrace, TracepointTestRunner, assert_tracepoint_results_match, terminal_events_to_string,
};
use ct_dap_client::types::tracepoint::{RunTracepointsArg, TraceSession, Tracepoint, TracepointMode};

mod test_harness;
use test_harness::{Language, TestRecording};

/// `return final_result;` in `calculate_sum`.
const RETURN_LINE: usize = 31;
/// `sum += i;` in `with_loops`' `for` loop.
const FOR_BODY_LINE: usize = 37;

fn tracepoint(id: usize, file: &str, line: usize, expression: &str) -> Tracepoint {
    Tracepoint {
        tracepoint_id: id,
        mode: TracepointMode::TracInlineCode,
        line,
        offset: -1,
        name: file.to_string(),
        expression: expression.to_string(),
        last_render: 0,
        is_disabled: false,
        is_changed: true,
        results: vec![],
        tracepoint_error: String::new(),
    }
}

#[test]
fn c_mcr_tracepoints_hit_every_visit_and_terminal_output_is_the_programs() {
    let name = "c_mcr_tracepoints_hit_every_visit_and_terminal_output_is_the_programs";
    let ct_native_replay = match test_harness::find_ct_native_replay() {
        Some(p) => p,
        None => {
            test_harness::skip_or_fail_missing_prerequisite(
                name,
                "ct-native-replay was not found",
                "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
            );
            return;
        }
    };
    if !test_harness::is_mcr_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            name,
            "the MCR recorder CLI (ct-mcr / ct_cli / CODETRACER_CT_MCR_CMD) was not found",
            "build the MCR CLI with `just build-ct-mcr` in codetracer-native-recorder, then put ct-mcr/ct_cli on PATH or set CODETRACER_CT_MCR_CMD",
        );
        return;
    }

    let db_backend = PathBuf::from(env!("CARGO_BIN_EXE_replay-server"));
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/c/c_flow_test.c");
    let source = std::fs::read_to_string(&source_path).expect("read c_flow_test.c");
    let lines: Vec<&str> = source.lines().collect();
    // The line numbers below are the program's; a change to it must move them.
    assert_eq!(lines[RETURN_LINE - 1].trim(), "return final_result;");
    assert_eq!(lines[FOR_BODY_LINE - 1].trim(), "sum += i;");

    let recording = TestRecording::create_mcr(&source_path, Language::C, "mcr-tracepoint", &ct_native_replay)
        .expect("MCR recording failed");
    println!("MCR trace recorded at: {}", recording.trace_dir.display());

    // The program's own output, run natively: the oracle for the terminal.
    let real = Command::new(&recording.binary_path).output().expect("run the program");
    let real_stdout = String::from_utf8_lossy(&real.stdout).to_string();
    assert!(
        real_stdout.contains("Final: 94\n") && real_stdout.contains("for sum: 45\n"),
        "the program's arithmetic is not what this test expects: {real_stdout:?}"
    );

    let mut runner =
        TracepointTestRunner::new(&db_backend, &recording.trace_dir).expect("DAP init failed for MCR trace");

    // (3) terminal output.
    let terminal = runner.client().load_terminal().expect("ct/load-terminal");
    let captured = terminal_events_to_string(&terminal);
    assert_eq!(
        captured, real_stdout,
        "the recording's terminal output must be the program's standard output"
    );

    // (4) tracepoints, in execution order: calculate_sum runs before with_loops.
    let file = source_path.to_str().unwrap();
    let args = RunTracepointsArg {
        session: TraceSession {
            tracepoints: vec![
                tracepoint(0, file, RETURN_LINE, "log(final_result)"),
                tracepoint(1, file, FOR_BODY_LINE, "log(i)"),
            ],
            found: vec![],
            last_count: 0,
            results: Default::default(),
            id: 1,
        },
        stop_after: -1,
        with_locals: true,
    };
    let results = runner.client().run_tracepoints(args).expect("ct/run-tracepoints");
    let mut expected = vec![ExpectedTrace {
        label: "final_result".to_string(),
        value: "94".to_string(),
    }];
    for i in 0..10 {
        expected.push(ExpectedTrace {
            label: "i".to_string(),
            value: i.to_string(),
        });
    }
    assert_tracepoint_results_match(&results, &expected).expect("tracepoint values");
    runner.finish().expect("disconnect failed");
}
