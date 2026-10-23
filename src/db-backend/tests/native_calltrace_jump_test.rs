//! `ct/calltrace-jump` on a native recording (MCR and rr) must land in the
//! frame the activated row names, not somewhere on the current call stack.
//!
//! codetracer-pm issue
//! `2026-10-21-native-calltrace-jump-moves-only-along-the-current-stack.md`;
//! spec `spec/GUI/Layout-And-Navigation/Click-Navigation.md` §3.3
//! ("Activating a call-trace row moves the session into that frame and marks
//! that row") and §2.2 (the jump carries the frame's identity and must honour
//! it).
//!
//! The program is `test-programs/c/c_flow_test.c`: `main` calls
//! `calculate_sum` and then `with_loops`, two sibling calls. Each scenario
//! stops somewhere, loads the call trace the backend serves there
//! (`ct/load-calltrace-section`, the pane's own request), keeps a row, moves
//! on, and then activates the kept row: it sends `ct/calltrace-jump` with the
//! payload `CalltraceVM.doubleClickEntry` builds from that row
//! (`calltrace_vm.nim` `calltraceJumpArgs`, from the row as
//! `replay_data_store.nim` `callLineOf` decodes it). It then asserts that the
//! moved-to location and the innermost frame of the DAP `stackTrace` are in
//! the row's function.
//!
//! * `..._reaches_a_call_that_is_not_on_the_current_stack`: the
//!   `calculate_sum` row, kept from inside `calculate_sum`, activated from
//!   inside `with_loops`. `calculate_sum` has returned, so it is not on the
//!   current stack. Before the fix `calltrace_jump` ran
//!   `callstack_jump(callstack_depth)`, and `calculate_sum`'s depth is
//!   `with_loops`' depth, so the session stayed in `with_loops`.
//! * `..._to_a_caller_kept_from_an_earlier_stop_lands_in_the_caller`: the
//!   `main` row, kept from inside `calculate_sum` (so it is an OUTER frame of
//!   the stack it was loaded from), activated from inside `with_loops`. It
//!   must land in `main`, not in the innermost frame of the row's moment
//!   (`calculate_sum`).
//! * `..._to_an_ancestor_lands_in_the_ancestor`: the `main` row of the
//!   current stack, activated where it was loaded. The old code served this
//!   case and the new code must keep serving it.
//!
//! * `..._to_the_second_of_two_sibling_calls_lands_in_the_second` (and the
//!   first): `c_sibling_calls_test.c` calls `scale(10)` and `scale(20)` with
//!   nothing recorded and no conditional branch between them, so the two
//!   stops in `scale` share an MCR geid and an rr tick count, and their rows
//!   agree on every coordinate, the depth, the path and the line. The row of
//!   the second call, activated from `main` after both returned, must land
//!   in the second call (`value` == 20). Only the row's `replayPosition`,
//!   the worker's exact identity of the stop it was loaded at, tells them
//!   apart; a jump by coordinate landed in the first call (`value` == 10).
//! * `..._to_the_second_of_two_identical_calls_...`: `c_twin_calls_test.c`
//!   calls `scale(10)` twice, so the two stops also agree on every register
//!   and differ only in memory (`nth`). MCR names a stop by its retired
//!   instruction count and must land in the second call (`nth` == 2). rr
//!   names a stop by its event, tick count and registers, which the two
//!   share, so it must refuse the jump, saying so, and leave the session
//!   where it was.
//!
//! A call-trace search result (`CalltraceVM.jumpToSearchResult`) sends the
//! same request: it builds its payload with the same `calltraceJumpArgs` from
//! the same `callLineOf` decoding of the call, so these requests cover both
//! activations at the backend. (On a native recording `ct/search-calltrace`
//! answers from the trace's database, which holds no calls, so it returns no
//! results to activate today.)
//!
//! Why rows come from an earlier stop: on a native recording the call trace
//! the backend serves is the call stack of the current position
//! (`Handler::load_calltrace_section`'s recreator branch), so a row for a call
//! that is not on the current stack is one the pane loaded at an earlier
//! position. That is the case the issue describes.
//!
//! * `go_rr_...`: a Go recording, which ct-native-replay serves with Delve
//!   rather than LLDB. That worker cannot return to an earlier stop exactly,
//!   so a row of the current stack is served (the `main.main` row activated
//!   from inside `calculateSum`, `test-programs/go/go_flow_program.go`) and a
//!   row loaded at another stop is refused by name, the session staying where
//!   it was, rather than resolved against the current stack.
//!
//! No mocks: the recorders record a real program, db-backend, ct-native-replay,
//! rr, Delve and `ct-mcr debugserver` are the shipping binaries, the client
//! speaks DAP over stdio. Recording under MCR's default attach needs a host
//! with CPUID faulting, and rr needs hardware performance counters (or
//! `CODETRACER_RR_SOFT_MODE=1`); on a host without them the recording fails
//! and so does the test.
//!
//! CI: the `c_mcr_` tests run in the `mcr-dap-flow` lane and the `_rr_` tests
//! in `rr-backend-tests` (`ci/test/non-gui-not-provided.linux.txt`). Both
//! recorders exist only on x86_64 Linux, so the suite is built only there.
#![cfg(all(target_os = "linux", target_arch = "x86_64"))]

use std::path::PathBuf;
use std::time::{Duration, Instant};

use ct_dap_client::client::{DapStdioClient, scaled};
use ct_dap_client::protocol::DapMessage;
use ct_dap_client::test_support::{FlowData, FlowTestRunner};
use ct_dap_client::types::navigation::MoveState;
use serde_json::{Value, json};

mod test_harness;
use test_harness::{Language, TestRecording};

/// `return final_result;` in `calculate_sum`.
const CALCULATE_SUM_LINE: usize = 31;
const CALCULATE_SUM_LINES: std::ops::RangeInclusive<i64> = 24..=32;
/// `sum += i;` in `with_loops`' `for` loop.
const WITH_LOOPS_LINE: usize = 37;
const WITH_LOOPS_LINES: std::ops::RangeInclusive<i64> = 34..=56;
const MAIN_LINES: std::ops::RangeInclusive<i64> = 58..=74;
/// The lines of `c_flow_test.c` the scenarios rely on.
const FLOW_TEST_LINES: &[(usize, &str)] = &[
    (CALCULATE_SUM_LINE, "return final_result;"),
    (WITH_LOOPS_LINE, "sum += i;"),
    (24, "int calculate_sum(int a, int b) {"),
    (34, "void with_loops(int n) {"),
    (58, "int main(void) {"),
];

/// `sink = scaled;` in `scale` (`c_sibling_calls_test.c`), and the function.
const SCALE_LINE: usize = 18;
const SCALE_LINES: std::ops::RangeInclusive<i64> = 16..=20;
/// The `printf` in `main`, after both calls of `scale` returned.
const AFTER_CALLS_LINE: usize = 25;
/// The lines of `c_sibling_calls_test.c` the scenarios rely on.
const SIBLING_CALLS_LINES: &[(usize, &str)] = &[
    (16, "static int scale(int value) {"),
    (SCALE_LINE, "sink = scaled;"),
    (23, "int first = scale(10);"),
    (24, "int second = scale(20);"),
    (AFTER_CALLS_LINE, r#"printf("first %d second %d\n", first, second);"#),
];

/// Which native recorder makes the recording.
#[derive(Clone, Copy, Debug)]
enum Recorder {
    Mcr,
    Rr,
}

/// A recording of a test program and a DAP session on it.
struct Session {
    file: String,
    runner: FlowTestRunner,
    _recording: TestRecording,
}

/// Record the C program `test-programs/c/<program>` with `recorder` and open a
/// DAP session on it (`open_session_for`).
fn open_session(name: &str, recorder: Recorder, program: &str, expected_lines: &[(usize, &str)]) -> Option<Session> {
    open_session_for(name, recorder, Language::C, &format!("c/{program}"), expected_lines)
}

/// Record `test-programs/<program>`, a `language` program, with `recorder` and
/// open a DAP session on it. `expected_lines` are `(line, text)` pairs the
/// program must have, so a change to it that moves the lines the scenario
/// relies on fails here. `None` when a prerequisite is missing and the harness
/// allows the test to skip (`CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false`
/// makes it fail).
fn open_session_for(
    name: &str,
    recorder: Recorder,
    language: Language,
    program: &str,
    expected_lines: &[(usize, &str)],
) -> Option<Session> {
    let ct_native_replay = match test_harness::find_ct_native_replay() {
        Some(p) => p,
        None => {
            test_harness::skip_or_fail_missing_prerequisite(
                name,
                "ct-native-replay was not found",
                "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
            );
            return None;
        }
    };
    match recorder {
        Recorder::Mcr if !test_harness::is_mcr_available() => {
            test_harness::skip_or_fail_missing_prerequisite(
                name,
                "the MCR recorder CLI (ct-mcr / ct_cli / CODETRACER_CT_MCR_CMD) was not found",
                "build the MCR CLI with `just build-ct-mcr` in codetracer-native-recorder, then put ct-mcr/ct_cli on PATH or set CODETRACER_CT_MCR_CMD",
            );
            return None;
        }
        Recorder::Rr if !test_harness::is_rr_available() => {
            test_harness::skip_or_fail_missing_prerequisite(
                name,
                "rr was not found",
                "run inside the codetracer dev shell, which provides rr",
            );
            return None;
        }
        _ => {}
    }
    if matches!(language, Language::Go) {
        for (tool, probe) in [("go", "version"), ("dlv", "version")] {
            if std::process::Command::new(tool).arg(probe).output().is_err() {
                test_harness::skip_or_fail_missing_prerequisite(
                    name,
                    &format!("`{tool}`, which a Go recording and its replay (Delve) need, is not on PATH"),
                    "run inside the codetracer dev shell, which provides go and dlv",
                );
                return None;
            }
        }
    }

    let db_backend = PathBuf::from(env!("CARGO_BIN_EXE_replay-server"));
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("test-programs")
        .join(program);
    let source = std::fs::read_to_string(&source_path).unwrap_or_else(|e| panic!("read {program}: {e}"));
    let lines: Vec<&str> = source.lines().collect();
    for (line, text) in expected_lines {
        assert_eq!(lines[line - 1].trim(), *text, "{program}:{line}");
    }

    let recording = match recorder {
        Recorder::Mcr => TestRecording::create_mcr(&source_path, language, name, &ct_native_replay),
        Recorder::Rr => TestRecording::create(&source_path, language, name, &ct_native_replay),
    }
    .unwrap_or_else(|e| panic!("{recorder:?} recording failed: {e}"));
    println!("{recorder:?} trace recorded at: {}", recording.trace_dir.display());
    // An rr recording is the `rr/` directory inside the trace directory,
    // which is what the runner is given for one (it then opens the trace
    // directory around it); an MCR recording is the `.ct` file itself.
    let trace = match recorder {
        Recorder::Mcr => recording.trace_dir.clone(),
        Recorder::Rr => recording.trace_dir.join("rr"),
    };
    let runner = FlowTestRunner::new(&db_backend, &trace)
        .unwrap_or_else(|e| panic!("DAP init failed for the {recorder:?} trace: {e}"));
    Some(Session {
        file: source_path.to_str().unwrap().to_string(),
        runner,
        _recording: recording,
    })
}

/// Continue to the single breakpoint `line` (cleared again afterwards, so it
/// does not stop a later move) and return where the session stopped.
fn continue_to_line(client: &mut DapStdioClient, file: &str, line: usize) -> MoveState {
    client.set_breakpoints(file, &[line]).expect("setBreakpoints");
    let state = client
        .dap_continue_with_timeout(scaled(Duration::from_secs(120)))
        .unwrap_or_else(|e| panic!("continue to line {line}: {e}"));
    client.set_breakpoints(file, &[]).expect("clear breakpoints");
    assert_eq!(
        state.location.line, line as i64,
        "the stop at the breakpoint on line {line}"
    );
    state
}

/// Read messages until the response to request `seq` arrives; returns
/// `(success, message, body)` and the last `ct/complete-move` seen before it.
fn response_to(
    client: &mut DapStdioClient,
    seq: i64,
    command: &str,
) -> ((bool, Option<String>, Value), Option<MoveState>) {
    let deadline = Instant::now() + scaled(Duration::from_secs(180));
    let mut moved = None;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(
            !remaining.is_zero(),
            "no response to {command}; db-backend stderr:\n{}",
            client.recent_stderr(40).join("\n")
        );
        match client.recv_message(remaining) {
            Ok(DapMessage::Response(r)) if r.request_seq == seq => {
                return ((r.success, r.message.clone(), r.body.clone()), moved);
            }
            Ok(DapMessage::Event(e)) if e.event == "ct/complete-move" => {
                moved = Some(serde_json::from_value(e.body).expect("ct/complete-move body"));
            }
            Ok(_) => {}
            Err(e) => panic!(
                "waiting for the response to {command}: {e}; db-backend stderr:\n{}",
                client.recent_stderr(40).join("\n")
            ),
        }
    }
}

/// The call-trace rows the backend serves at the current position
/// (`ct/load-calltrace-section`, the request the call-trace pane sends).
fn load_calltrace_rows(client: &mut DapStdioClient) -> Vec<Value> {
    let seq = client
        .send_request(
            "ct/load-calltrace-section",
            json!({
                "startCallLineIndex": 0,
                "depth": 10,
                "height": 50,
                "rawIgnorePatterns": "",
                "autoCollapsing": true,
                "optimizeCollapse": false,
                "renderCallLineIndex": 0,
            }),
        )
        .expect("send ct/load-calltrace-section");
    let ((success, message, body), _) = response_to(client, seq, "ct/load-calltrace-section");
    assert!(success, "ct/load-calltrace-section failed: {message:?}");
    body.get("callLines")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_else(|| panic!("ct/load-calltrace-section answered no callLines: {body}"))
}

/// The function a call-trace row draws: the name `callLineOf` shows.
fn row_name(row: &Value) -> String {
    let call = &row["content"]["call"];
    let high = call["location"]["highLevelFunctionName"].as_str().unwrap_or("");
    if high.is_empty() {
        call["rawName"].as_str().unwrap_or("").to_string()
    } else {
        high.to_string()
    }
}

/// The row of `function` in the call trace served at the current position.
fn row_of(client: &mut DapStdioClient, function: &str) -> Value {
    let rows = load_calltrace_rows(client);
    let row = rows
        .iter()
        .find(|row| row_name(row) == function)
        .cloned()
        .unwrap_or_else(|| {
            panic!(
                "the call trace has no `{function}` row; rows: {:?}",
                rows.iter().map(row_name).collect::<Vec<_>>()
            )
        });
    println!("{function} row: {}", row["content"]["call"]["location"]);
    row
}

/// The `ct/calltrace-jump` payload the front end sends for `row`: what
/// `CalltraceVM.doubleClickEntry` (and `jumpToSearchResult`) build with
/// `calltrace_vm.nim` `calltraceJumpArgs(line.location, line.rrTicks,
/// line.codeGeneration)`, where the line is `replay_data_store.nim`
/// `callLineOf` of the row: the high-level path and line when present, else
/// the low-level ones; the row's `rrTicks`, `callstackDepth` and
/// `replayPosition` (the stop the row was loaded at, opaque to the client);
/// the source generation doubling as the code generation.
fn frontend_jump_args(row: &Value) -> Value {
    let location = &row["content"]["call"]["location"];
    let high_path = location["highLevelPath"].as_str().unwrap_or("");
    let (path, line) = if high_path.is_empty() {
        (
            location["path"].as_str().unwrap_or("").to_string(),
            location["line"].as_i64().unwrap_or(0),
        )
    } else {
        (high_path.to_string(), location["highLevelLine"].as_i64().unwrap_or(0))
    };
    // `callLineOf` reads the ticks with `getBiggestInt(0).uint64`.
    let rr_ticks = location["rrTicks"].as_i64().unwrap_or(0).max(0);
    let source_generation = location["sourceGeneration"].as_i64().unwrap_or(0);
    json!({
        "path": path,
        "line": line,
        "highLevelPath": path,
        "highLevelLine": line,
        "rrTicks": rr_ticks,
        "callstackDepth": location["callstackDepth"].as_i64().unwrap_or(0),
        "sourceGeneration": source_generation,
        "sourceDigest": location["sourceDigest"].as_str().unwrap_or(""),
        "codeGeneration": source_generation,
        "replayPosition": location["replayPosition"].as_str().unwrap_or(""),
    })
}

/// Send `ct/calltrace-jump` for `row`: whether it succeeded, the error
/// message, and the move it reported.
fn send_row_jump(client: &mut DapStdioClient, row: &Value) -> (bool, Option<String>, Option<MoveState>) {
    let args = frontend_jump_args(row);
    println!("ct/calltrace-jump {args}");
    let seq = client
        .send_request("ct/calltrace-jump", args)
        .expect("send ct/calltrace-jump");
    let ((success, message, _), moved) = response_to(client, seq, "ct/calltrace-jump");
    println!("ct/calltrace-jump answered success={success} message={message:?}");
    (success, message, moved)
}

/// Send `ct/calltrace-jump` for `row` and return where the session moved.
fn activate_row(client: &mut DapStdioClient, row: &Value) -> MoveState {
    let (success, message, moved) = send_row_jump(client, row);
    assert!(
        success,
        "ct/calltrace-jump failed: {message:?}; db-backend stderr:\n{}",
        client.recent_stderr(40).join("\n")
    );
    moved.expect("ct/calltrace-jump answered without a ct/complete-move")
}

/// The DAP `stackTrace` frame names, innermost first, and the innermost
/// frame's line.
fn stack(client: &mut DapStdioClient) -> (Vec<String>, i64) {
    let stack = client.stack_trace().expect("stackTrace");
    let names: Vec<String> = stack.stack_frames.iter().map(|f| f.name.clone()).collect();
    let line = stack
        .stack_frames
        .first()
        .unwrap_or_else(|| panic!("stackTrace answered no frames"))
        .line;
    (names, line)
}

fn assert_in_function(
    what: &str,
    client: &mut DapStdioClient,
    moved: &MoveState,
    function: &str,
    lines: &std::ops::RangeInclusive<i64>,
) {
    let (names, top_line) = stack(client);
    println!(
        "{what}: moved to {}:{} ({}), stack {names:?}",
        moved.location.path, moved.location.line, moved.location.function_name
    );
    assert!(
        lines.contains(&moved.location.line) && moved.location.function_name.contains(function),
        "{what}: the session moved to {}:{} in `{}`, not into `{function}` (lines {lines:?}); stack {names:?}",
        moved.location.path,
        moved.location.line,
        moved.location.function_name
    );
    assert!(
        names[0].contains(function) && lines.contains(&top_line),
        "{what}: the innermost frame is `{}` at line {top_line}, not `{function}` (lines {lines:?}); stack {names:?}",
        names[0]
    );
}

/// Stop in `with_loops`, after `calculate_sum` has returned.
fn stop_in_with_loops(client: &mut DapStdioClient, file: &str) {
    continue_to_line(client, file, WITH_LOOPS_LINE);
    let (names, line) = stack(client);
    assert!(
        names[0].contains("with_loops") && WITH_LOOPS_LINES.contains(&line),
        "the stop is in `{}` at line {line}; stack {names:?}",
        names[0]
    );
    assert!(
        !names.iter().any(|frame| frame.contains("calculate_sum")),
        "`calculate_sum` must not be on the stack inside `with_loops`: {names:?}"
    );
}

fn reaches_a_call_that_is_not_on_the_current_stack(name: &str, recorder: Recorder) {
    let Some(mut session) = open_session(name, recorder, "c_flow_test.c", FLOW_TEST_LINES) else {
        return;
    };
    let file = session.file.clone();
    let client = session.runner.client();

    continue_to_line(client, &file, CALCULATE_SUM_LINE);
    let sum_row = row_of(client, "calculate_sum");
    stop_in_with_loops(client, &file);

    let moved = activate_row(client, &sum_row);
    assert_in_function(
        "activating the calculate_sum row from inside with_loops",
        client,
        &moved,
        "calculate_sum",
        &CALCULATE_SUM_LINES,
    );
    session.runner.finish().expect("disconnect failed");
}

fn to_a_caller_kept_from_an_earlier_stop_lands_in_the_caller(name: &str, recorder: Recorder) {
    let Some(mut session) = open_session(name, recorder, "c_flow_test.c", FLOW_TEST_LINES) else {
        return;
    };
    let file = session.file.clone();
    let client = session.runner.client();

    continue_to_line(client, &file, CALCULATE_SUM_LINE);
    let main_row = row_of(client, "main");
    stop_in_with_loops(client, &file);

    let moved = activate_row(client, &main_row);
    assert_in_function(
        "activating the main row kept from inside calculate_sum, from inside with_loops",
        client,
        &moved,
        "main",
        &MAIN_LINES,
    );
    session.runner.finish().expect("disconnect failed");
}

fn to_an_ancestor_lands_in_the_ancestor(name: &str, recorder: Recorder) {
    let Some(mut session) = open_session(name, recorder, "c_flow_test.c", FLOW_TEST_LINES) else {
        return;
    };
    let file = session.file.clone();
    let client = session.runner.client();

    stop_in_with_loops(client, &file);
    let main_row = row_of(client, "main");

    let moved = activate_row(client, &main_row);
    assert_in_function(
        "activating the main row from inside with_loops",
        client,
        &moved,
        "main",
        &MAIN_LINES,
    );
    session.runner.finish().expect("disconnect failed");
}

/// The integer value of the local `name` at the current position
/// (`ct/load-locals`, what the State pane asks for).
fn local_int(client: &mut DapStdioClient, name: &str) -> i64 {
    let body = client.load_locals().expect("ct/load-locals");
    let locals = body
        .get("locals")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("ct/load-locals answered no locals: {body}"));
    let local = locals
        .iter()
        .find(|local| local.get("expression").and_then(Value::as_str) == Some(name))
        .unwrap_or_else(|| panic!("no local `{name}` in {body}"));
    let value = local.get("value").cloned().unwrap_or(Value::Null);
    FlowData::extract_int_value(&value).unwrap_or_else(|| panic!("`{name}` is not an integer: {value}"))
}

/// The row of `scale` kept from inside its `nth` call (1 or 2) of
/// `c_sibling_calls_test.c`, activated from `main` after both calls returned,
/// must land in that call: `value` is 10 in the first and 20 in the second.
///
/// The two calls run at the same depth with nothing recorded between them
/// and no conditional branch either, so their stops share an MCR geid and an
/// rr tick count: a jump that resolves a row by that coordinate (and the
/// row's line, function and depth) reaches the FIRST call whichever row was
/// activated. The second call's row is the case that tells them apart.
fn sibling_call_row_lands_in_its_own_call(name: &str, recorder: Recorder, nth: usize) {
    let Some(mut session) = open_session(name, recorder, "c_sibling_calls_test.c", SIBLING_CALLS_LINES) else {
        return;
    };
    let file = session.file.clone();
    let client = session.runner.client();
    let expected_value = [10, 20][nth - 1];

    let mut kept = None;
    for call in 1..=2 {
        continue_to_line(client, &file, SCALE_LINE);
        assert_eq!(
            local_int(client, "value"),
            [10, 20][call - 1],
            "stop in call {call} of scale"
        );
        let row = row_of(client, "scale");
        if call == nth {
            kept = Some(row);
        }
    }
    let row = kept.expect("the kept row");
    continue_to_line(client, &file, AFTER_CALLS_LINE);
    let (names, _) = stack(client);
    assert!(
        names[0].contains("main") && !names.iter().any(|frame| frame.contains("scale")),
        "both calls of scale must have returned; stack {names:?}"
    );

    let moved = activate_row(client, &row);
    let what = format!("activating the row of call {nth} of scale from main");
    assert_in_function(&what, client, &moved, "scale", &SCALE_LINES);
    assert_eq!(
        local_int(client, "value"),
        expected_value,
        "{what}: the session is in another call of scale"
    );
    session.runner.finish().expect("disconnect failed");
}

/// `sink = scaled;` in `scale` (`c_twin_calls_test.c`), and the function.
const TWIN_LINE: usize = 23;
const TWIN_SCALE_LINES: std::ops::RangeInclusive<i64> = 19..=25;
/// The `printf` in `main`, after both calls of `scale` returned.
const TWIN_AFTER_CALLS_LINE: usize = 30;
/// The lines of `c_twin_calls_test.c` the scenario relies on.
const TWIN_CALLS_LINES: &[(usize, &str)] = &[
    (19, "static int scale(int value) {"),
    (TWIN_LINE, "sink = scaled;"),
    (28, "int first = scale(10);"),
    (29, "int second = scale(10);"),
    (
        TWIN_AFTER_CALLS_LINE,
        r#"printf("first %d second %d calls %d\n", first, second, calls);"#,
    ),
];

/// The row of the SECOND of two `scale(10)` calls (`c_twin_calls_test.c`)
/// whose kept stops agree on the event, the tick count and every register,
/// and differ only in memory (`nth`, 1 then 2).
///
/// * MCR names the stop by the served thread's retired instruction count, so
///   the jump lands in the second call: `nth` is 2.
/// * rr names a stop by its event, tick count and registers, which the two
///   stops share, so the jump is refused, naming why, and the session stays
///   where it was (in `main`, after both calls), as the move event the
///   refusal reports says too.
fn twin_call_row_lands_in_the_second_or_is_refused(name: &str, recorder: Recorder) {
    let Some(mut session) = open_session(name, recorder, "c_twin_calls_test.c", TWIN_CALLS_LINES) else {
        return;
    };
    let file = session.file.clone();
    let client = session.runner.client();

    let mut kept = None;
    for call in 1..=2 {
        continue_to_line(client, &file, TWIN_LINE);
        assert_eq!(local_int(client, "nth"), call, "stop in call {call} of scale");
        assert_eq!(local_int(client, "value"), 10, "both calls are scale(10)");
        kept = Some(row_of(client, "scale"));
    }
    let row = kept.expect("the second call's row");
    continue_to_line(client, &file, TWIN_AFTER_CALLS_LINE);

    let (success, message, moved) = send_row_jump(client, &row);
    match recorder {
        Recorder::Mcr => {
            assert!(success, "MCR must serve the row exactly: {message:?}");
            let moved = moved.expect("ct/calltrace-jump answered without a ct/complete-move");
            let what = "activating the row of the second scale(10) call from main";
            assert_in_function(what, client, &moved, "scale", &TWIN_SCALE_LINES);
            assert_eq!(local_int(client, "nth"), 2, "{what}: the session is in the first call");
        }
        Recorder::Rr => {
            let message = message.unwrap_or_default();
            assert!(
                !success
                    && message.contains("cannot tell which one")
                    && message.contains("the session is where it was"),
                "rr cannot tell the two stops apart and must refuse, saying so: success \
                 {success}, {message:?}"
            );
            let moved = moved.expect("a refused jump still reports where the session is");
            assert_eq!(
                moved.location.line, TWIN_AFTER_CALLS_LINE as i64,
                "the refusal must leave the session where it was"
            );
            let (names, line) = stack(client);
            assert!(
                names[0].contains("main") && line == TWIN_AFTER_CALLS_LINE as i64,
                "the refusal must leave the session where it was: {names:?} line {line}"
            );
        }
    }
    session.runner.finish().expect("disconnect failed");
}

#[test]
fn c_mcr_calltrace_jump_reaches_a_call_that_is_not_on_the_current_stack() {
    reaches_a_call_that_is_not_on_the_current_stack(
        "c_mcr_calltrace_jump_reaches_a_call_that_is_not_on_the_current_stack",
        Recorder::Mcr,
    );
}

#[test]
fn c_mcr_calltrace_jump_to_a_caller_kept_from_an_earlier_stop_lands_in_the_caller() {
    to_a_caller_kept_from_an_earlier_stop_lands_in_the_caller(
        "c_mcr_calltrace_jump_to_a_caller_kept_from_an_earlier_stop_lands_in_the_caller",
        Recorder::Mcr,
    );
}

#[test]
fn c_mcr_calltrace_jump_to_an_ancestor_lands_in_the_ancestor() {
    to_an_ancestor_lands_in_the_ancestor(
        "c_mcr_calltrace_jump_to_an_ancestor_lands_in_the_ancestor",
        Recorder::Mcr,
    );
}

#[test]
fn c_rr_calltrace_jump_reaches_a_call_that_is_not_on_the_current_stack() {
    reaches_a_call_that_is_not_on_the_current_stack(
        "c_rr_calltrace_jump_reaches_a_call_that_is_not_on_the_current_stack",
        Recorder::Rr,
    );
}

#[test]
fn c_rr_calltrace_jump_to_a_caller_kept_from_an_earlier_stop_lands_in_the_caller() {
    to_a_caller_kept_from_an_earlier_stop_lands_in_the_caller(
        "c_rr_calltrace_jump_to_a_caller_kept_from_an_earlier_stop_lands_in_the_caller",
        Recorder::Rr,
    );
}

#[test]
fn c_rr_calltrace_jump_to_an_ancestor_lands_in_the_ancestor() {
    to_an_ancestor_lands_in_the_ancestor("c_rr_calltrace_jump_to_an_ancestor_lands_in_the_ancestor", Recorder::Rr);
}

#[test]
fn c_mcr_calltrace_jump_to_the_second_of_two_sibling_calls_lands_in_the_second() {
    sibling_call_row_lands_in_its_own_call(
        "c_mcr_calltrace_jump_to_the_second_of_two_sibling_calls_lands_in_the_second",
        Recorder::Mcr,
        2,
    );
}

#[test]
fn c_mcr_calltrace_jump_to_the_first_of_two_sibling_calls_lands_in_the_first() {
    sibling_call_row_lands_in_its_own_call(
        "c_mcr_calltrace_jump_to_the_first_of_two_sibling_calls_lands_in_the_first",
        Recorder::Mcr,
        1,
    );
}

#[test]
fn c_rr_calltrace_jump_to_the_second_of_two_sibling_calls_lands_in_the_second() {
    sibling_call_row_lands_in_its_own_call(
        "c_rr_calltrace_jump_to_the_second_of_two_sibling_calls_lands_in_the_second",
        Recorder::Rr,
        2,
    );
}

#[test]
fn c_rr_calltrace_jump_to_the_first_of_two_sibling_calls_lands_in_the_first() {
    sibling_call_row_lands_in_its_own_call(
        "c_rr_calltrace_jump_to_the_first_of_two_sibling_calls_lands_in_the_first",
        Recorder::Rr,
        1,
    );
}

#[test]
fn c_mcr_calltrace_jump_to_the_second_of_two_identical_calls_lands_in_the_second() {
    twin_call_row_lands_in_the_second_or_is_refused(
        "c_mcr_calltrace_jump_to_the_second_of_two_identical_calls_lands_in_the_second",
        Recorder::Mcr,
    );
}

#[test]
fn c_rr_calltrace_jump_to_the_second_of_two_identical_calls_is_refused_in_place() {
    twin_call_row_lands_in_the_second_or_is_refused(
        "c_rr_calltrace_jump_to_the_second_of_two_identical_calls_is_refused_in_place",
        Recorder::Rr,
    );
}

/// `finalResult := doubled + 10` in `calculateSum`
/// (`test-programs/go/go_flow_program.go`), and the function.
const GO_SUM_LINE: usize = 16;
const GO_SUM_LINES: std::ops::RangeInclusive<i64> = 12..=21;
/// `fmt.Println("Result:", result)` in `main`, after `calculateSum` returned.
const GO_AFTER_CALL_LINE: usize = 28;
const GO_MAIN_LINES: std::ops::RangeInclusive<i64> = 23..=29;
/// The lines of `go_flow_program.go` the scenarios rely on.
const GO_FLOW_LINES: &[(usize, &str)] = &[
    (12, "func calculateSum(a, b int) int {"),
    (GO_SUM_LINE, "finalResult := doubled + 10"),
    (23, "func main() {"),
    (27, "result := calculateSum(x, y)"),
    (GO_AFTER_CALL_LINE, r#"fmt.Println("Result:", result)"#),
];

fn open_go_session(name: &str) -> Option<Session> {
    open_session_for(name, Recorder::Rr, Language::Go, "go/go_flow_program.go", GO_FLOW_LINES)
}

/// Stop in `calculateSum`, called from `main.main`.
fn stop_in_calculate_sum(client: &mut DapStdioClient, file: &str) {
    continue_to_line(client, file, GO_SUM_LINE);
    let (names, line) = stack(client);
    assert!(
        names[0].contains("main.calculateSum")
            && GO_SUM_LINES.contains(&line)
            && names.iter().any(|frame| frame.contains("main.main")),
        "the stop is in `{}` at line {line}; stack {names:?}",
        names[0]
    );
}

/// A Go row of the CURRENT stack is served by the Delve worker: the
/// `main.main` row, loaded and activated inside `calculateSum`, lands in
/// `main.main`.
#[test]
fn go_rr_calltrace_jump_to_an_ancestor_lands_in_the_ancestor() {
    let name = "go_rr_calltrace_jump_to_an_ancestor_lands_in_the_ancestor";
    let Some(mut session) = open_go_session(name) else {
        return;
    };
    let file = session.file.clone();
    let client = session.runner.client();

    stop_in_calculate_sum(client, &file);
    let main_row = row_of(client, "main.main");
    let moved = activate_row(client, &main_row);
    assert_in_function(
        "activating the main.main row from inside calculateSum",
        client,
        &moved,
        "main.main",
        &GO_MAIN_LINES,
    );
    session.runner.finish().expect("disconnect failed");
}

/// A Go row loaded at another stop is refused by name: the Delve worker has
/// no exact way back to that stop, and moving along the current stack to the
/// row's depth would land in another frame. The session stays where it was.
#[test]
fn go_rr_calltrace_jump_to_a_row_of_an_earlier_stop_is_refused_in_place() {
    let name = "go_rr_calltrace_jump_to_a_row_of_an_earlier_stop_is_refused_in_place";
    let Some(mut session) = open_go_session(name) else {
        return;
    };
    let file = session.file.clone();
    let client = session.runner.client();

    stop_in_calculate_sum(client, &file);
    let sum_row = row_of(client, "main.calculateSum");
    continue_to_line(client, &file, GO_AFTER_CALL_LINE);

    let (success, message, moved) = send_row_jump(client, &sum_row);
    let message = message.unwrap_or_default();
    assert!(
        !success && message.contains("cannot return to that stop exactly"),
        "the Delve worker cannot return to the row's stop and must refuse, saying so: success \
         {success}, {message:?}"
    );
    let moved = moved.expect("a refused jump still reports where the session is");
    assert_eq!(
        moved.location.line, GO_AFTER_CALL_LINE as i64,
        "the refusal must leave the session where it was"
    );
    let (names, line) = stack(client);
    assert!(
        names[0].contains("main.main") && line == GO_AFTER_CALL_LINE as i64,
        "the refusal must leave the session where it was: {names:?} line {line}"
    );
    session.runner.finish().expect("disconnect failed");
}
