//! A `ct/load-flow` that a newer one overtakes before it starts is not run.
//!
//! Issue: codetracer-pm
//! `issues/2026-11-15-mcr-rust-sudoku-load-flow-takes-19-to-48-seconds.md`
//! ("What still fails, and the decision"). A client asks for the flow of
//! every stop, and the replay server's one `flow` thread served those
//! requests in order, so the flow of the stop the user is looking at waited
//! behind the flows of every stop already left. Spec:
//! `CodeTracer-DAP-Extensions.md`, `ct/load-flow`, "Superseded requests": a
//! queued `ct/load-flow` that a newer one of the same `flowMode` follows is
//! answered `success: false`, naming the newer request, and gets no
//! `ct/updated-flow`.
//!
//! The slow request the flows queue behind is the `flow` thread's own
//! `launch`: it loads the recording before it serves anything, and the four
//! flows are sent right behind it, so they are normally all queued when it
//! finishes and only the newest runs. The dispatcher forwards them one by
//! one, though, so on a loaded host the thread can finish the launch between
//! two of them (measured: 1 run in 30 on two CPUs shared with four busy
//! loops, where flow 1 was superseded by flow 2, flow 2 ran, flow 3 was
//! superseded by flow 4). The assertions therefore hold for every such
//! interleaving: each flow answered once and in order, the newest run, at
//! least one superseded, each superseded answer naming a newer flow of the
//! batch, and one `ct/updated-flow` per flow that ran. Served in order, as
//! before, none is superseded, so the test fails.
//! The location the flows ask for is learned first from a separate run of
//! the server on the same recording.
//!
//! # No mocks
//!
//! The real `replay-server` binary over real DAP stdio framing, launching the
//! committed materialized fixture `trace/trace.ct`. `next_task_request`'s
//! unit tests (`dap_server::tests::stale_load_flow_coalescing`) pin the
//! ordering rules with no timing involved.

#![cfg(unix)]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use db_backend::dap::{self, DapClient, DapMessage};
use db_backend::transport::DapTransport;
use serde_json::{Value, json};
use std::io::BufReader;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// Upper bound for a launch to stop, and for the flows to be answered.
const BUDGET: Duration = Duration::from_secs(90);

/// A `replay-server dap-server --stdio` in its own process group, reaped by
/// group when dropped, and the messages it writes.
struct Server {
    child: Child,
    writer: ChildStdin,
    messages: mpsc::Receiver<Result<DapMessage, String>>,
    client: DapClient,
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
        }
    }

    /// Sends `command` and returns its `seq`.
    fn send(&mut self, command: &str, arguments: Value) -> i64 {
        let request = self.client.request(command, arguments);
        let DapMessage::Request(r) = &request else {
            unreachable!("DapClient::request builds a request")
        };
        let seq = r.base.seq;
        self.writer.send(&request).expect("send DAP request");
        seq
    }

    /// The next message, or `None` once `deadline` passes.
    fn next(&self, deadline: Instant, seen: &[String]) -> Option<DapMessage> {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        match self.messages.recv_timeout(remaining) {
            Ok(Ok(message)) => Some(message),
            Ok(Err(err)) => panic!("DAP stream failed: {err}; messages seen: {seen:?}"),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => panic!("replay-server exited; messages seen: {seen:?}"),
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // The server was started as the leader of its own group, so the
        // group is its pid; anything it started goes with it.
        let pgid = self.child.id() as libc::pid_t;
        // SAFETY: a signal to a process group this test created.
        unsafe {
            libc::killpg(pgid, libc::SIGKILL);
        }
        let _ = self.child.wait();
    }
}

fn fixture() -> PathBuf {
    let trace_folder = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("trace");
    assert!(
        trace_folder.join("trace.ct").is_file(),
        "{} is missing; this test launches the committed materialized fixture",
        trace_folder.display()
    );
    trace_folder
}

/// The location `ct/complete-move` names when `trace_folder` is launched.
fn entry_location(trace_folder: &Path) -> Value {
    let mut server = Server::start();
    server.send("initialize", json!({}));
    server.send("configurationDone", json!({}));
    server.send("launch", json!({ "traceFolder": trace_folder }));
    let deadline = Instant::now() + BUDGET;
    let mut seen = Vec::new();
    while let Some(message) = server.next(deadline, &seen) {
        if let DapMessage::Event(event) = &message {
            if event.event == "ct/complete-move" {
                return event.body["location"].clone();
            }
            seen.push(format!("event {}", event.event));
        }
    }
    panic!("the launch sent no ct/complete-move within {BUDGET:?}; messages seen: {seen:?}");
}

#[test]
fn only_the_newest_of_the_queued_load_flows_runs() {
    let trace_folder = fixture();
    let location = entry_location(&trace_folder);

    let mut server = Server::start();
    server.send("initialize", json!({}));
    server.send("configurationDone", json!({}));
    server.send("launch", json!({ "traceFolder": trace_folder }));
    let flow = json!({ "flowMode": "call", "location": location });
    let seqs: Vec<i64> = (0..4).map(|_| server.send("ct/load-flow", flow.clone())).collect();
    let newest = *seqs.last().unwrap();

    // Every flow request's answers, and the flow events, until the newest
    // is answered (its response follows its event).
    let deadline = Instant::now() + BUDGET;
    let mut seen: Vec<String> = Vec::new();
    let mut responses: Vec<(i64, bool, String)> = Vec::new();
    let mut flow_events = 0;
    while !responses.iter().any(|(seq, _, _)| *seq == newest) {
        let Some(message) = server.next(deadline, &seen) else {
            panic!("ct/load-flow {newest} was not answered within {BUDGET:?}; messages seen: {seen:?}");
        };
        match message {
            DapMessage::Response(r) if r.command == "ct/load-flow" => {
                seen.push(format!("response ct/load-flow {} success={}", r.request_seq, r.success));
                responses.push((r.request_seq, r.success, r.message.unwrap_or_default()));
            }
            DapMessage::Event(e) if e.event == "ct/updated-flow" => {
                seen.push(format!("event ct/updated-flow error={}", e.body["error"]));
                assert_eq!(
                    e.body["error"],
                    json!(false),
                    "the flow failed: {}",
                    e.body["errorMessage"]
                );
                flow_events += 1;
            }
            DapMessage::Event(e) => seen.push(format!("event {}", e.event)),
            DapMessage::Response(r) => seen.push(format!("response {}", r.command)),
            DapMessage::Request(r) => seen.push(format!("request {}", r.command)),
        }
    }

    // Each flow is answered once, in the order sent: the flow thread takes
    // its requests in order, whether it runs one or answers it superseded.
    let answered: Vec<i64> = responses.iter().map(|(seq, _, _)| *seq).collect();
    assert_eq!(
        answered, seqs,
        "each flow is answered once, in order; messages seen: {seen:?}"
    );
    // The newest runs: nothing is queued behind it.
    assert!(
        responses.last().is_some_and(|(_, ok, _)| *ok),
        "the newest flow runs; messages seen: {seen:?}"
    );
    // Some are superseded: with the flow thread busy loading the recording
    // when they arrive, at least the ones queued together are. Served in
    // order (the plain `recv()` this replaced), all four ran and none was.
    let superseded: Vec<&(i64, bool, String)> = responses.iter().filter(|(_, ok, _)| !ok).collect();
    assert!(
        !superseded.is_empty(),
        "flows queued behind a busy flow thread are superseded; messages seen: {seen:?}"
    );
    // A superseded answer names a newer flow of this batch.
    for (seq, _, message) in &superseded {
        let named = message
            .strip_prefix("superseded: a newer ct/load-flow (request ")
            .and_then(|rest| rest.split(')').next())
            .and_then(|n| n.parse::<i64>().ok());
        assert!(
            named.is_some_and(|n| n > *seq && seqs.contains(&n)),
            "superseded flow {seq} names a newer flow of the batch: {message}"
        );
    }
    // And gets no ct/updated-flow: one event per flow that ran.
    let ran = responses.len() - superseded.len();
    assert_eq!(
        flow_events, ran,
        "one ct/updated-flow per flow that ran, none for a superseded one; messages seen: {seen:?}"
    );
}
