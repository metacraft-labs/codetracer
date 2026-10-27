//! Every request is answered: a client-supplied id that names nothing is
//! refused by name, and a handler that panics is answered too.
//!
//! The Debug Adapter Protocol requires a response to every request
//! (<https://microsoft.github.io/debug-adapter-protocol/overview#requests>):
//! a request that cannot be carried out is answered with `success: false`
//! and a `message`. The replay server dispatches each request on a task
//! thread. A panic inside a handler used to end that thread: the request that
//! panicked got no response at all, so its client waited out its own timeout,
//! and only *later* requests were refused (by `handle_message`'s dead-channel
//! arm). `scopes` with a `frameId` no call has was one way to get there: the
//! handler `expect()`ed the frame to exist.
//!
//! The contract these tests hold the shipping `replay-server` to:
//!
//! * a request carrying an id that names nothing (a frame, a call key) is
//!   refused with a message that names the id, and the session goes on
//!   serving as before;
//! * a request that succeeds is answered exactly once even when it has
//!   nothing to return, including the ones whose outcome travels in events
//!   (the moves, the tracepoint commands, the call-trace expansions);
//! * a request whose handler panics is answered `success: false` with a
//!   message naming the command, its `seq` and the panic. The panic may have
//!   left the thread's session half-changed, so the thread refuses every later
//!   request by name until a `launch` loads the trace again, after which it
//!   serves exactly as it did before the panic;
//! * a `launch` whose setup panics reports the failure with the
//!   `ct/launch-failed` event, as a failed launch does, and the requests after
//!   it are answered rather than left waiting.
//!
//! # The panic path
//!
//! Every panic a client could provoke with a bad argument is now refused
//! before it happens, so no real request is guaranteed to panic. The panic
//! tests therefore set `CODETRACER_REPLAY_SERVER_TEST_PANIC_ON_COMMAND`, which
//! makes the shipping binary panic inside the handler run of the command it
//! names (`dap_server::TEST_PANIC_ON_COMMAND_ENV`). The panic is raised under
//! the same `catch_unwind` the real handlers run under, so it exercises the
//! code path a defect in any handler would take. Without that variable the
//! binary never panics on purpose, which `named_refusals_*` relies on.
//!
//! # No mocks
//!
//! The server is the `replay-server` binary this crate builds, spoken to over
//! stdio by the shipping `ct-dap-client`, and the trace is the committed
//! materialized fixture
//! `tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct`, so this
//! runs on any host. Its entry stop has a non-empty call stack, which is what
//! makes "answers exactly as before" a comparison of something.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::PathBuf;
use std::time::{Duration, Instant};

use ct_dap_client::client::DapStdioClient;
use ct_dap_client::protocol::{DapMessage, Event, Response};
use ct_dap_client::types::launch::LaunchRequestArguments;
use serde_json::json;

/// The variable that makes the binary panic on purpose in one command's
/// handler. Spelled out rather than imported so a rename on the server side
/// fails here by name instead of silently disarming the panic tests.
const TEST_PANIC_ON_COMMAND_ENV: &str = "CODETRACER_REPLAY_SERVER_TEST_PANIC_ON_COMMAND";

/// A frame id / call key no call in the fixture has: the fixture records a
/// few hundred calls at most.
const UNKNOWN_ID: i64 = 987_654_321;

/// How long an answer may take. A refusal or a panic answers at once; the
/// bound only has to be far below the 20-120 s client timeouts a missing
/// answer used to run into, and far above scheduling noise.
const ANSWER_BUDGET: Duration = Duration::from_secs(15);

fn fixture() -> PathBuf {
    let trace =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct");
    assert!(trace.is_file(), "the committed fixture {} is missing", trace.display());
    trace
}

fn launch_args() -> LaunchRequestArguments {
    LaunchRequestArguments {
        trace_folder: Some(fixture()),
        ..Default::default()
    }
}

/// A `replay-server` over stdio, with a scratch `CODETRACER_HOME` (kept alive
/// by the returned guard) and, when `panic_on` names a command, the test
/// panic armed for it.
fn spawn(panic_on: Option<&str>) -> (DapStdioClient, tempfile::TempDir) {
    let home = tempfile::tempdir().expect("scratch CODETRACER_HOME");
    let home_str = home.path().to_string_lossy().to_string();
    let mut envs: Vec<(&str, &str)> = vec![("CODETRACER_HOME", home_str.as_str())];
    if let Some(command) = panic_on {
        envs.push((TEST_PANIC_ON_COMMAND_ENV, command));
    }
    let mut client = DapStdioClient::spawn_with_envs(&PathBuf::from(env!("CARGO_BIN_EXE_replay-server")), &envs)
        .expect("spawn replay-server");
    client.initialize().expect("initialize");
    (client, home)
}

/// `spawn`, then launch the fixture and wait for the entry stop.
fn launched(panic_on: Option<&str>) -> (DapStdioClient, tempfile::TempDir) {
    let (mut client, home) = spawn(panic_on);
    client.launch(launch_args()).expect("launch");
    client.configuration_done().expect("configurationDone");
    client
        .wait_for_stopped(Duration::from_secs(120))
        .expect("the launch stops at the entry");
    (client, home)
}

/// Read until the response to `seq` arrives, or fail after `ANSWER_BUDGET`.
fn response_to(client: &mut DapStdioClient, seq: i64, what: &str) -> Response {
    let deadline = Instant::now() + ANSWER_BUDGET;
    loop {
        let now = Instant::now();
        if now >= deadline {
            panic!(
                "no response to {what} (seq {seq}) within {ANSWER_BUDGET:?}; server stderr:\n{}",
                client.recent_stderr(40).join("\n")
            );
        }
        match client.recv_message(deadline - now) {
            Ok(DapMessage::Response(r)) if r.request_seq == seq => return r,
            Ok(_) => {}
            Err(e) => panic!(
                "no response to {what} (seq {seq}): {e}; server stderr:\n{}",
                client.recent_stderr(40).join("\n")
            ),
        }
    }
}

/// Send `command` and wait for its response.
fn ask(client: &mut DapStdioClient, command: &str, arguments: serde_json::Value, what: &str) -> Response {
    let seq = client
        .send_request(command, arguments)
        .unwrap_or_else(|e| panic!("send {command}: {e}"));
    response_to(client, seq, what)
}

/// `stackTrace` and `threads`, which the stable task thread serves: what the
/// session answers, to compare before and after.
fn control_answers(client: &mut DapStdioClient, when: &str) -> Vec<Response> {
    let answers = vec![
        ask(
            client,
            "stackTrace",
            json!({ "threadId": 1 }),
            &format!("`stackTrace` {when}"),
        ),
        ask(client, "threads", json!({}), &format!("`threads` {when}")),
    ];
    for answer in &answers {
        assert!(answer.success, "{} {when} failed: {:?}", answer.command, answer.message);
    }
    assert!(
        answers[0].body["stackFrames"].as_array().is_some_and(|f| !f.is_empty()),
        "the fixture's session reports no stack frames: {}",
        answers[0].body
    );
    assert!(
        answers[1].body["threads"].as_array().is_some_and(|t| !t.is_empty()),
        "the fixture's session reports no threads: {}",
        answers[1].body
    );
    answers
}

fn assert_same_answers(before: &[Response], after: &[Response], when: &str) {
    for (b, a) in before.iter().zip(after) {
        assert_eq!(
            a.body, b.body,
            "{} must answer {when} exactly as it did before",
            a.command
        );
    }
}

/// A failed answer, with its message.
fn refusal(answer: &Response, what: &str) -> String {
    assert!(
        !answer.success,
        "{what} must be refused, but succeeded: {}",
        answer.body
    );
    answer.message.clone().unwrap_or_default()
}

#[test]
fn named_refusals_for_ids_that_name_nothing_leave_the_session_serving() {
    let (mut client, _home) = launched(None);
    let before = control_answers(&mut client, "before the refusals");

    let key = UNKNOWN_ID.to_string();
    let cases = [
        (
            "scopes",
            json!({ "frameId": UNKNOWN_ID }),
            format!("no frame has frameId {UNKNOWN_ID}"),
        ),
        (
            "ct/load-asm-function",
            json!({ "path": "", "name": "", "key": key, "forceReload": false }),
            format!("no call has key {UNKNOWN_ID}"),
        ),
        (
            "ct/expand-calls",
            json!({ "callKey": key, "nonExpandedKind": 1, "count": 1 }),
            format!("no call has key {UNKNOWN_ID}"),
        ),
        (
            "ct/expand-calls",
            json!({ "callKey": "-5", "nonExpandedKind": 4, "count": 1 }),
            "no call has key -5".to_string(),
        ),
        (
            "ct/collapse-calls",
            json!({ "callKey": key, "nonExpandedKind": 1, "count": 0 }),
            format!("no call has key {UNKNOWN_ID}"),
        ),
    ];
    // Each case runs against a server of its own, and every failing case is
    // reported, so one case that panics (and poisons its thread) cannot hide
    // what the others do.
    let _ = client.disconnect();
    let mut failures: Vec<String> = Vec::new();
    for (command, arguments, expected) in cases {
        let what = format!("`{command}` {arguments}");
        let (mut client, _home) = launched(None);
        let answer = ask(&mut client, command, arguments, &what);
        let message = answer.message.clone().unwrap_or_default();
        if answer.success || !message.contains(&expected) || message.contains("panicked") {
            failures.push(format!(
                "{what} must be refused naming the id ({expected:?}), before anything panics. \
                 Got success={} {message:?}",
                answer.success
            ));
            let _ = client.disconnect();
            continue;
        }
        let after = control_answers(&mut client, &format!("after {what}"));
        for (b, a) in before.iter().zip(&after) {
            if a.body != b.body {
                failures.push(format!(
                    "{} after {what} answered differently: {} (before: {})",
                    a.command, a.body, b.body
                ));
            }
        }
        let _ = client.disconnect();
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn a_handler_panic_is_answered_and_the_thread_refuses_until_relaunched() {
    let (mut client, _home) = launched(Some("scopes"));
    let before = control_answers(&mut client, "before the panic");

    // The request whose handler panics is answered, naming what panicked.
    let seq = client
        .send_request("scopes", json!({ "frameId": 0 }))
        .expect("send scopes");
    let answer = response_to(&mut client, seq, "the panicking `scopes`");
    assert_eq!(answer.command, "scopes", "the answer names the request's command");
    let message = refusal(&answer, "the panicking `scopes`");
    assert!(
        message.contains("panicked") && message.contains("scopes") && message.contains(&format!("seq {seq}")),
        "the answer must say that the handler for this command and seq panicked. Got: {message:?}"
    );

    // The session may be half-changed: every later request is refused by
    // name, and told how to recover, instead of being served from it.
    for (command, arguments) in [("stackTrace", json!({ "threadId": 1 })), ("threads", json!({}))] {
        let what = format!("`{command}` after the panic");
        let answer = ask(&mut client, command, arguments, &what);
        let message = refusal(&answer, &what);
        assert!(
            message.contains("panicked") && message.contains(&format!("seq {seq}")) && message.contains("launch"),
            "{what} must be refused naming the panic and the relaunch. Got: {message:?}"
        );
    }

    // A launch of the same trace reloads it, and the thread serves again,
    // exactly as before the panic.
    client.launch(launch_args()).expect("relaunch");
    client
        .wait_for_stopped(Duration::from_secs(120))
        .expect("the relaunch stops at the entry");
    let after = control_answers(&mut client, "after the relaunch");
    assert_same_answers(&before, &after, "after the relaunch");
    let _ = client.disconnect();
}

#[test]
fn a_launch_whose_setup_panics_is_reported_and_later_requests_are_answered() {
    let (mut client, _home) = spawn(Some("launch"));
    client
        .launch(launch_args())
        .expect("the protocol-level launch response");
    client.configuration_done().expect("configurationDone");
    let failed = client
        .recv_event("ct/launch-failed", ANSWER_BUDGET)
        .unwrap_or_else(|e| {
            panic!(
                "a launch whose setup panicked must be reported with ct/launch-failed: {e}; stderr:\n{}",
                client.recent_stderr(40).join("\n")
            )
        });
    let text = failed.body["message"].as_str().unwrap_or_default().to_string();
    assert!(
        text.contains("panicked") && text.contains("launch"),
        "the launch failure must say that the launch handler panicked. Got: {text:?}"
    );

    let answer = ask(&mut client, "threads", json!({}), "`threads` after the failed launch");
    let message = refusal(&answer, "`threads` after the failed launch");
    assert!(
        message.contains("panicked"),
        "a request after a panicked launch must be refused naming the panic. Got: {message:?}"
    );
    let _ = client.disconnect();
}

/// How long to keep listening after the last answer for a second answer to
/// any request. A duplicate would be sent by the same handler call that sent
/// the first, so it follows at once; the window only has to outlast pipe and
/// scheduling latency.
const SECOND_ANSWER_WINDOW: Duration = Duration::from_secs(2);

/// One request sent by an exactly-once check, and what its answer must be.
struct Sent {
    seq: i64,
    what: String,
    command: &'static str,
    /// `None`: the request must succeed. `Some(text)`: it must be refused
    /// with a message containing `text`, and not by a panic.
    refusal: Option<&'static str>,
}

/// Everything the server sent while an exactly-once check ran: every
/// response, whichever request it answers, and every event.
#[derive(Default)]
struct Transcript {
    sent: Vec<Sent>,
    answers: Vec<Response>,
    events: Vec<Event>,
}

impl Transcript {
    /// Send one request and read until it is answered (within
    /// `ANSWER_BUDGET`), keeping every message seen on the way, an extra
    /// answer to an earlier request among them.
    fn send(
        &mut self,
        client: &mut DapStdioClient,
        command: &'static str,
        arguments: serde_json::Value,
        refusal: Option<&'static str>,
    ) {
        let what = format!("`{command}` {arguments}");
        let seq = client
            .send_request(command, arguments)
            .unwrap_or_else(|e| panic!("send {what}: {e}"));
        let deadline = Instant::now() + ANSWER_BUDGET;
        loop {
            let now = Instant::now();
            assert!(
                now < deadline,
                "no response to {what} (seq {seq}) within {ANSWER_BUDGET:?}; server stderr:\n{}",
                client.recent_stderr(40).join("\n")
            );
            match client.recv_message(deadline - now) {
                Ok(DapMessage::Response(r)) => {
                    let done = r.request_seq == seq;
                    self.answers.push(r);
                    if done {
                        break;
                    }
                }
                Ok(DapMessage::Event(e)) => self.events.push(e),
                Ok(_) => {}
                Err(e) => panic!(
                    "no response to {what} (seq {seq}): {e}; server stderr:\n{}",
                    client.recent_stderr(40).join("\n")
                ),
            }
        }
        self.sent.push(Sent {
            seq,
            what,
            command,
            refusal,
        });
    }

    /// The body of the latest event named `name`.
    fn last_event(&self, name: &str) -> serde_json::Value {
        self.events
            .iter()
            .rev()
            .find(|e| e.event == name)
            .map(|e| e.body.clone())
            .unwrap_or_else(|| panic!("no `{name}` event was sent"))
    }

    /// Read on for `SECOND_ANSWER_WINDOW` (anything still to come is a
    /// second answer), then check that every request was answered exactly
    /// once, as its case says.
    fn assert_each_answered_once(mut self, client: &mut DapStdioClient) {
        let quiet_until = Instant::now() + SECOND_ANSWER_WINDOW;
        loop {
            let now = Instant::now();
            if now >= quiet_until {
                break;
            }
            match client.recv_message(quiet_until - now) {
                Ok(DapMessage::Response(r)) => self.answers.push(r),
                Ok(_) => {}
                Err(_) => break,
            }
        }

        let mut failures: Vec<String> = Vec::new();
        for sent in &self.sent {
            let Sent {
                seq,
                what,
                command,
                refusal,
            } = sent;
            let mine: Vec<&Response> = self.answers.iter().filter(|r| r.request_seq == *seq).collect();
            if mine.len() != 1 {
                failures.push(format!(
                    "{what} (seq {seq}) was answered {} times, not once",
                    mine.len()
                ));
                continue;
            }
            let answer = mine[0];
            let message = answer.message.clone().unwrap_or_default();
            if answer.command != *command {
                failures.push(format!("{what}: the answer names `{}`", answer.command));
            }
            match refusal {
                None if !answer.success => failures.push(format!("{what} must succeed, but was refused: {message:?}")),
                Some(expected) if answer.success || !message.contains(expected) || message.contains("panicked") => {
                    failures.push(format!(
                        "{what} must be refused, naming {expected:?}. Got success={} {message:?}",
                        answer.success
                    ))
                }
                _ => {}
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }
}

/// `ct/expand-calls` and `ct/collapse-calls` are answered exactly once, on
/// success as well as on refusal.
///
/// Both commands change the call trace's expansion state and carry no data
/// back, and until this test they answered nothing when they succeeded: the
/// handler changed the state and returned, so a client that awaited the
/// response (the native `BackendService.send`, which blocks on it) never got
/// one. A call key that does not parse as an integer was only logged, and
/// was not answered either; an expansion kind the command does not make is
/// refused rather than answered as a success that changed nothing.
///
/// Every response the server sends is recorded, keyed by `request_seq`, and
/// the stream is read on for `SECOND_ANSWER_WINDOW` after the last one, so a
/// second answer to any request fails the test as surely as a missing one.
#[test]
fn calltrace_expand_and_collapse_are_answered_exactly_once() {
    let (mut client, _home) = launched(None);
    let mut transcript = Transcript::default();

    // Key 0 is the fixture's first call, which every recording with calls
    // has; the session's own call stack is non-empty (`control_answers`).
    let cases: [(&'static str, serde_json::Value, Option<&'static str>); 7] = [
        (
            "ct/collapse-calls",
            json!({ "callKey": "0", "nonExpandedKind": 1, "count": 0 }),
            None,
        ),
        (
            "ct/expand-calls",
            json!({ "callKey": "0", "nonExpandedKind": 1, "count": 0 }),
            None,
        ),
        (
            "ct/expand-calls",
            json!({ "callKey": "0", "nonExpandedKind": 4, "count": 1 }),
            None,
        ),
        (
            "ct/collapse-calls",
            json!({ "callKey": "not-a-key", "nonExpandedKind": 1, "count": 0 }),
            Some("not-a-key"),
        ),
        (
            "ct/expand-calls",
            json!({ "callKey": "not-a-key", "nonExpandedKind": 1, "count": 0 }),
            Some("not-a-key"),
        ),
        (
            "ct/expand-calls",
            json!({ "callKey": "", "nonExpandedKind": 1, "count": 0 }),
            Some("call key"),
        ),
        // A kind that names no expansion `ct/expand-calls` makes (`Siblings`).
        (
            "ct/expand-calls",
            json!({ "callKey": "0", "nonExpandedKind": 2, "count": 0 }),
            Some("Siblings"),
        ),
    ];
    for (command, arguments, refusal) in cases {
        transcript.send(&mut client, command, arguments, refusal);
    }
    transcript.assert_each_answered_once(&mut client);

    // The session goes on serving.
    control_answers(&mut client, "after the expansions");
    let _ = client.disconnect();
}

/// The arguments of `ct/setup-trace-session` / `ct/run-tracepoints` for one
/// tracepoint, `tracepoint_id`, logging at `path:line`.
fn session_with_tracepoint(path: &str, line: i64, tracepoint_id: u64) -> serde_json::Value {
    json!({
        "session": {
            "id": 1,
            "tracepoints": [{
                "tracepointId": tracepoint_id,
                "mode": 0,
                "line": line.max(1),
                "offset": 0,
                "name": path,
                "expression": "log(1)",
                "lastRender": 0,
                "isDisabled": false,
                "isChanged": true,
                "results": [],
                "tracepointError": "",
            }],
            "found": [],
            "lastCount": 0,
            "results": {},
        },
        "stopAfter": -1,
        "withLocals": false,
    })
}

/// The commands that move the session or change its tracepoints are each
/// answered exactly once, after the events that report what they did.
///
/// `restart`, `ct/run-to-entry`, `ct/history-jump` and `ct/local-step-jump`
/// report the move with `stopped` / `ct/complete-move`; the tracepoint
/// commands report with `ct/updated-trace` (and `ct/run-tracepoints` with
/// `ct/tracepoint-results`). Until this test none of them answered the
/// request itself when it succeeded, so a client that awaited the response
/// (a DAP client's `restart`, which the server advertises with
/// `supportsRestartRequest`) waited out its own timeout. A tracepoint id
/// with no table panicked `ct/tracepoint-delete`; it is refused by name now.
///
/// The arguments are the ones the front ends send: the location a
/// `ct/history-jump` or `ct/local-step-jump` names is the stop `restart`
/// reported, so it is a step the fixture has.
#[test]
fn moves_and_tracepoint_commands_are_answered_exactly_once() {
    let (mut client, _home) = launched(None);
    let mut transcript = Transcript::default();

    transcript.send(&mut client, "restart", json!({}), None);
    transcript.send(&mut client, "ct/run-to-entry", json!({}), None);
    let entry = transcript.last_event("ct/complete-move")["location"].clone();
    let rr_ticks = entry["rrTicks"].as_i64().expect("the entry stop names its rrTicks");
    let path = entry["path"].as_str().unwrap_or("").to_string();
    let line = entry["line"].as_i64().unwrap_or(0);

    transcript.send(&mut client, "ct/history-jump", entry.clone(), None);
    transcript.send(
        &mut client,
        "ct/local-step-jump",
        json!({
            "path": path,
            "line": line,
            "stepCount": 0,
            "targetIteration": 0,
            "firstLoopLine": line,
            "rrTicks": rr_ticks,
            "reverse": false,
            "activeIteration": 0,
        }),
        None,
    );

    let session = session_with_tracepoint(&path, line, 0);
    transcript.send(&mut client, "ct/setup-trace-session", session.clone(), None);
    transcript.send(&mut client, "ct/run-tracepoints", session, None);
    transcript.send(&mut client, "ct/tracepoint-toggle", json!({ "id": 0 }), None);
    transcript.send(&mut client, "ct/tracepoint-toggle", json!({ "id": 0 }), None);
    transcript.send(&mut client, "ct/tracepoint-delete", json!({ "id": 0 }), None);

    // Refusals, each named and each before anything changes.
    transcript.send(
        &mut client,
        "ct/tracepoint-delete",
        json!({ "id": UNKNOWN_ID }),
        Some("no tracepoint has id 987654321"),
    );
    // A tracepoint id is a label, not a position: the largest one is as
    // good as any, and costs one table, made for it alone. It used to be
    // refused as out of range by `ct/tracepoint-toggle`, and to overflow
    // `ct/setup-trace-session`, which made a table for every smaller id.
    transcript.send(
        &mut client,
        "ct/setup-trace-session",
        session_with_tracepoint(&path, line, u64::MAX),
        None,
    );
    transcript.send(&mut client, "ct/tracepoint-toggle", json!({ "id": u64::MAX }), None);
    transcript.send(&mut client, "ct/history-jump", json!({ "rrTicks": -5 }), Some("-5"));
    // `ct/run-tracepoints` reported its results before it answered.
    transcript.last_event("ct/tracepoint-results");
    transcript.assert_each_answered_once(&mut client);

    // The session goes on serving.
    control_answers(&mut client, "after the moves and the tracepoint commands");
    let _ = client.disconnect();
}
