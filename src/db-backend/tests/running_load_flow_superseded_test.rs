//! A `ct/load-flow` that a newer one of the same mode supersedes WHILE IT
//! RUNS is stopped at once and answered as superseded.
//!
//! A client asks for the flow of every stop. A flow of `main` on an MCR
//! recording steps over each call `main` makes, and a step over a large call
//! emulates every instruction of it, so it ran on for tens of seconds (until
//! the flow worker's 10 s read timeout) after the client had moved on, and
//! the flow of the stop the client was looking at waited behind it. Now the
//! running flow ends promptly, even in the middle of a step, is
//! answered `success: false` with a message starting `superseded`, gets no
//! `ct/updated-flow`, and its replay worker is stopped.
//!
//! The scenario, on an MCR recording of `test-programs/c/c_superseded_flow_test.c`:
//!   1. stop at the first line of `main` and in `quick` (which runs first);
//!   2. send the flow of `main` (A). Its walk steps over `spin(...)`, tens of
//!      millions of emulated instructions;
//!   3. wait until A's `flow` replay worker exists and drives its `ct-mcr
//!      debugserver` (polled, not timed), then [`A_HEAD_START`] more, so that
//!      A is in the middle of its walk;
//!   4. send the flow of `quick` (B), which is cheap: `quick` runs before
//!      `spin`.
//!
//! Asserted:
//!   * PREMISE: A had not been answered when B was sent, and its worker was
//!     running (else nothing was running to supersede);
//!   * A is answered `success: false`, `superseded: … (request <B>) … while
//!     this one was running`;
//!   * promptly: A's answer comes within a small multiple of B's own cost (the
//!     time from A's answer to B's `ct/updated-flow`, i.e. B run alone), with
//!     a floor of [`PROMPT_FLOOR`], not after the 10 s read timeout;
//!   * exactly one `ct/updated-flow` arrives, after A's answer and before B's
//!     acknowledgement: B's, not A's;
//!   * A's replay worker and every process under it (its `ct-mcr
//!     debugserver`) are gone within [`REAP_DEADLINE`] of A's answer.
//!
//! Before the change the flow thread ran A to its end: A was answered after
//! the read timeout (and with its own `ct/updated-flow`), so this test fails
//! on the superseded answer.
//!
//! # No mocks
//!
//! The real `replay-server` over DAP stdio, the real `ct-native-replay`
//! worker and the real `ct-mcr` recorder and debugserver, on a program built
//! and recorded by the test. Linux only: the process-tree checks read `/proc`.
//! Needs ct-native-replay and ct-mcr; without them it fails (or, with
//! `CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING`, skips) naming the remedy.
//! `flow_supersession`'s unit tests pin the dispatch rules with no timing.

#![cfg(target_os = "linux")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

mod test_harness;

use db_backend::dap::{self, DapClient, DapMessage, LaunchRequestArguments};
use db_backend::transport::DapTransport;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::io::BufReader;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
use test_harness::{Language, TestRecording};

/// Upper bound for one step of the scenario (launch, a stop, a flow): a bound
/// on a server that stopped answering, not on a slow one.
const STEP_BUDGET: Duration = Duration::from_secs(300);
/// How long A runs, after its worker's debugserver appears, before B is sent:
/// long enough for the walk to be past its jump to `main`'s entry and into
/// its steps. Not load-bearing for the verdict: a B sent earlier still
/// supersedes a running A (the premise checks below make sure A has neither
/// finished nor failed to start), and `spin` keeps A busy for far longer.
const A_HEAD_START: Duration = Duration::from_secs(4);
/// The least time A's answer is allowed, however cheap B turned out to be.
const PROMPT_FLOOR: Duration = Duration::from_secs(3);
/// How long A's worker tree may take to disappear after A is answered.
const REAP_DEADLINE: Duration = Duration::from_secs(10);

/// `replay-server dap-server --stdio` in its own process group, reaped by
/// group when dropped, and the messages it writes.
struct Server {
    child: Child,
    writer: ChildStdin,
    messages: mpsc::Receiver<Result<DapMessage, String>>,
    client: DapClient,
    seen: Vec<String>,
}

impl Server {
    fn start() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_replay-server"))
            .arg("dap-server")
            .arg("--stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap_or_else(|err| panic!("failed to spawn replay-server: {err}"));
        let writer = child.stdin.take().expect("child stdin");
        let stdout = child.stdout.take().expect("child stdout");
        let (tx, messages) = mpsc::channel();
        thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let message = dap::read_dap_message_from_reader(&mut reader).map_err(|err| err.to_string());
                let failed = message.is_err();
                if tx.send(message).is_err() || failed {
                    break;
                }
            }
        });
        Server {
            child,
            writer,
            messages,
            client: DapClient::default(),
            seen: Vec::new(),
        }
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn send_message(&mut self, request: DapMessage) -> i64 {
        let DapMessage::Request(r) = &request else {
            unreachable!("only requests are sent")
        };
        let seq = r.base.seq;
        self.writer.send(&request).expect("send DAP request");
        seq
    }

    fn send(&mut self, command: &str, arguments: Value) -> i64 {
        let request = self.client.request(command, arguments);
        self.send_message(request)
    }

    /// The next message, or `None` once `deadline` passes. Every message is
    /// noted in `seen` for the failure messages.
    fn next(&mut self, deadline: Instant) -> Option<DapMessage> {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        match self.messages.recv_timeout(remaining) {
            Ok(Ok(message)) => {
                self.seen.push(describe(&message));
                Some(message)
            }
            Ok(Err(err)) => panic!("DAP stream failed: {err}; messages seen: {:?}", self.seen),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                panic!("replay-server exited; messages seen: {:?}", self.seen)
            }
        }
    }

    /// Wait for the event `name`, returning its body.
    fn event(&mut self, name: &str) -> Value {
        let deadline = Instant::now() + STEP_BUDGET;
        while let Some(message) = self.next(deadline) {
            if let DapMessage::Event(e) = message
                && e.event == name
            {
                return e.body;
            }
        }
        panic!("no {name} within {STEP_BUDGET:?}; messages seen: {:?}", self.seen);
    }

    /// Wait for the response to `seq`.
    fn response(&mut self, seq: i64) -> dap::Response {
        let deadline = Instant::now() + STEP_BUDGET;
        while let Some(message) = self.next(deadline) {
            if let DapMessage::Response(r) = message
                && r.request_seq == seq
            {
                return r;
            }
        }
        panic!(
            "request {seq} not answered within {STEP_BUDGET:?}; messages seen: {:?}",
            self.seen
        );
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // The server leads its own process group, so the group is its pid,
        // and every worker it started is in it.
        let pgid = self.child.id() as libc::pid_t;
        // SAFETY: a signal to a process group this test created.
        unsafe {
            libc::killpg(pgid, libc::SIGKILL);
        }
        let _ = self.child.wait();
    }
}

fn describe(message: &DapMessage) -> String {
    match message {
        DapMessage::Response(r) => format!(
            "response {} {} success={} {}",
            r.command,
            r.request_seq,
            r.success,
            r.message.clone().unwrap_or_default()
        ),
        DapMessage::Event(e) => format!("event {}", e.event),
        DapMessage::Request(r) => format!("request {}", r.command),
    }
}

/// A live process: its pid and its start time (field 22 of
/// `/proc/<pid>/stat`), so a pid reused after it is gone is not mistaken for
/// it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct Process {
    pid: u32,
    start: u64,
}

fn process(pid: u32) -> Option<Process> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after_comm = &stat[stat.rfind(')')? + 1..];
    // Fields after the command name start at field 3; start time is field 22.
    let start = after_comm.split_whitespace().nth(19)?.parse().ok()?;
    Some(Process { pid, start })
}

fn alive(p: Process) -> bool {
    // A zombie has exited: it is waiting only for its parent to read its
    // status, and holds no replay any more.
    let state = std::fs::read_to_string(format!("/proc/{}/stat", p.pid))
        .ok()
        .and_then(|stat| stat.rfind(')').map(|i| stat[i + 1..].trim_start().chars().next()))
        .flatten();
    process(p.pid) == Some(p) && state != Some('Z')
}

fn children(pid: u32) -> Vec<u32> {
    let mut out = Vec::new();
    if let Ok(tasks) = std::fs::read_dir(format!("/proc/{pid}/task")) {
        for task in tasks.flatten() {
            if let Ok(text) = std::fs::read_to_string(task.path().join("children")) {
                out.extend(text.split_whitespace().filter_map(|c| c.parse::<u32>().ok()));
            }
        }
    }
    out
}

/// `pid` and every process under it.
fn subtree(pid: u32) -> Vec<Process> {
    let mut out = Vec::new();
    let mut pending = vec![pid];
    let mut seen = HashSet::new();
    while let Some(current) = pending.pop() {
        if !seen.insert(current) {
            continue;
        }
        if let Some(p) = process(current) {
            out.push(p);
            pending.extend(children(current));
        }
    }
    out
}

fn cmdline(pid: u32) -> Vec<String> {
    std::fs::read(format!("/proc/{pid}/cmdline"))
        .map(|bytes| {
            bytes
                .split(|b| *b == 0)
                .filter(|a| !a.is_empty())
                .map(|a| String::from_utf8_lossy(a).into_owned())
                .collect()
        })
        .unwrap_or_default()
}

/// The `flow` replay workers among the server's children.
fn flow_workers(server: u32) -> Vec<u32> {
    children(server)
        .into_iter()
        .filter(|pid| {
            let args = cmdline(*pid);
            args.iter().any(|a| a == "replay-worker") && args.windows(2).any(|w| w[0] == "--name" && w[1] == "flow")
        })
        .collect()
}

fn line_of(source: &Path, marker: &str) -> u32 {
    let text = std::fs::read_to_string(source).expect("read the test program");
    let index = text
        .lines()
        .position(|line| line.contains(marker))
        .unwrap_or_else(|| panic!("{marker} not found in {}", source.display()));
    u32::try_from(index + 1).expect("line number")
}

/// Set the only breakpoint at `line` of `source`, continue to it, and return
/// the location the stop names.
fn stop_at(server: &mut Server, source: &Path, line: u32) -> Value {
    let bps = server.send(
        "setBreakpoints",
        json!({ "source": { "path": source }, "breakpoints": [ { "line": line } ] }),
    );
    let response = server.response(bps);
    assert!(response.success, "setBreakpoints failed: {:?}", response.message);
    server.send("continue", json!({ "threadId": 1 }));
    server.event("stopped");
    let location = server.event("ct/complete-move")["location"].clone();
    assert_eq!(
        location["line"].as_i64(),
        Some(i64::from(line)),
        "stopped at the wrong line: {location}"
    );
    location
}

#[test]
fn a_running_flow_is_stopped_and_answered_superseded_by_a_newer_one() {
    let name = "a_running_flow_is_stopped_and_answered_superseded_by_a_newer_one";
    let Some(ct_native_replay) = test_harness::find_ct_native_replay() else {
        test_harness::skip_or_fail_missing_prerequisite(
            name,
            "ct-native-replay was not found",
            "build it with `just ensure-ct-native-replay` (codetracer-native-backend sibling) or set CT_NATIVE_REPLAY_PATH",
        );
        return;
    };
    if !test_harness::is_mcr_available() {
        test_harness::skip_or_fail_missing_prerequisite(
            name,
            "the MCR recorder CLI (ct-mcr / ct_cli / CODETRACER_CT_MCR_CMD) was not found",
            "build it with `just build-ct-mcr` in codetracer-native-recorder, or set CODETRACER_CT_MCR_CMD",
        );
        return;
    }
    // Exported for the worker this server starts, which starts the debugserver.
    test_harness::find_ct_mcr();

    let source: PathBuf = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/c/c_superseded_flow_test.c");
    let recording =
        TestRecording::create_mcr(&source, Language::C, "superseded", &ct_native_replay).expect("MCR recording");
    let main_line = line_of(&source, "BREAKPOINT main");
    let quick_line = line_of(&source, "BREAKPOINT quick");

    let mut server = Server::start();
    let init = server.send("initialize", json!({}));
    server.response(init);
    server.send("configurationDone", json!({}));
    let launch = server
        .client
        .launch(LaunchRequestArguments {
            trace_folder: Some(recording.trace_dir.clone()),
            recreator_exe: Some(ct_native_replay.clone()),
            ..LaunchRequestArguments::default()
        })
        .expect("build launch");
    server.send_message(launch);
    server.event("stopped");
    let entry = server.event("ct/complete-move")["location"].clone();

    // A's location: the first line of `main` (the launch may already stop
    // there). B's: inside `quick`, which `main` calls next.
    let main_location = if entry["line"].as_i64() == Some(i64::from(main_line)) {
        entry
    } else {
        stop_at(&mut server, &source, main_line)
    };
    let quick_location = stop_at(&mut server, &source, quick_line);

    // A: the flow of `main`, which steps over `spin(...)`.
    let a = server.send("ct/load-flow", json!({ "flowMode": "call", "location": main_location }));
    let worker_deadline = Instant::now() + STEP_BUDGET;
    let a_worker = loop {
        if let Some(worker) = flow_workers(server.pid()).first() {
            break *worker;
        }
        assert!(
            Instant::now() < worker_deadline,
            "flow A's replay worker did not start within {STEP_BUDGET:?}; messages seen: {:?}",
            server.seen
        );
        thread::sleep(Duration::from_millis(20));
    };
    // PREMISE: A's worker drives a debugserver. Polled rather than assumed
    // after a fixed delay: on a loaded host the worker can take seconds to
    // start it.
    let debugserver_deadline = Instant::now() + STEP_BUDGET;
    while subtree(a_worker).len() < 2 {
        assert!(
            Instant::now() < debugserver_deadline,
            "PREMISE: flow A's worker {a_worker} started no debugserver within {STEP_BUDGET:?}; its tree is {:?}",
            subtree(a_worker)
        );
        thread::sleep(Duration::from_millis(20));
    }
    thread::sleep(A_HEAD_START);
    // Every process of A's worker tree, while A runs: the worker and the
    // ct-mcr debugserver it drives.
    let a_tree = subtree(a_worker);
    assert!(
        a_tree.len() >= 2,
        "PREMISE: flow A's worker {a_worker} still drives a debugserver; its tree is {a_tree:?}"
    );
    // PREMISE: A is still running. Nothing it sent may be its answer.
    let premise_deadline = Instant::now();
    while let Some(message) = server.next(premise_deadline) {
        if let DapMessage::Response(r) = &message {
            assert_ne!(
                r.request_seq, a,
                "PREMISE: flow A was answered before B was sent (it is not slow enough to supersede): {:?}",
                server.seen
            );
        }
    }

    // B: the flow of `quick`.
    let b_sent = Instant::now();
    let b = server.send(
        "ct/load-flow",
        json!({ "flowMode": "call", "location": quick_location }),
    );

    let deadline = b_sent + STEP_BUDGET;
    let mut a_answer: Option<(Instant, dap::Response)> = None;
    let mut flow_events: Vec<(Instant, bool)> = Vec::new();
    let b_answer = loop {
        let Some(message) = server.next(deadline) else {
            panic!(
                "flow B was not answered within {STEP_BUDGET:?}; messages seen: {:?}",
                server.seen
            );
        };
        match message {
            DapMessage::Response(r) if r.request_seq == a => a_answer = Some((Instant::now(), r)),
            DapMessage::Response(r) if r.request_seq == b => break (Instant::now(), r),
            DapMessage::Event(e) if e.event == "ct/updated-flow" => {
                flow_events.push((Instant::now(), a_answer.is_some()));
            }
            _ => {}
        }
    };
    let seen = server.seen.clone();

    let (a_answered, a_response) = a_answer.unwrap_or_else(|| panic!("flow A was not answered before B; {seen:?}"));
    let a_latency = a_answered.duration_since(b_sent);
    eprintln!(
        "flow A answered {a_latency:?} after B was sent (success={}); {} ct/updated-flow event(s)",
        a_response.success,
        flow_events.len()
    );
    let message = a_response.message.clone().unwrap_or_default();
    assert!(
        !a_response.success
            && message.starts_with(&format!("superseded: a newer ct/load-flow (request {b})"))
            && message.ends_with("while this one was running"),
        "flow A is answered as superseded by B while it ran, got success={} {message:?}; messages seen: {seen:?}",
        a_response.success
    );
    assert!(b_answer.1.success, "flow B runs: {:?}; {seen:?}", b_answer.1.message);

    // Exactly one flow event: B's, after A's answer.
    assert_eq!(
        flow_events.len(),
        1,
        "only the newest flow's ct/updated-flow is sent; messages seen: {seen:?}"
    );
    let (b_event, after_a) = flow_events[0];
    assert!(after_a, "the ct/updated-flow follows A's answer: it is B's; {seen:?}");

    // Promptly: within a small multiple of B's own cost (B ran alone, from
    // A's answer to its event), not after the worker's read timeout.
    let b_cost = b_event.duration_since(a_answered);
    let bound = (b_cost * 2).max(PROMPT_FLOOR);
    eprintln!("flow A answered {a_latency:?} after B was sent; B's own cost {b_cost:?}; bound {bound:?}");
    assert!(
        a_latency <= bound,
        "flow A was answered {a_latency:?} after B was sent; B's own cost was {b_cost:?}, so the bound is {bound:?}"
    );

    // A's worker and its debugserver are gone, not orphaned.
    let reap_deadline = a_answered + REAP_DEADLINE;
    loop {
        let left: Vec<Process> = a_tree.iter().copied().filter(|p| alive(*p)).collect();
        if left.is_empty() {
            break;
        }
        assert!(
            Instant::now() < reap_deadline,
            "flow A's replay processes are still running {REAP_DEADLINE:?} after it was answered: {:?}",
            left.iter().map(|p| (p.pid, cmdline(p.pid))).collect::<Vec<_>>()
        );
        thread::sleep(Duration::from_millis(50));
    }
}
