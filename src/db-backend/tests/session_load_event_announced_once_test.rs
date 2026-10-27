//! A launch announces its session to the client exactly once.
//!
//! Spec reference: `Value-Origin-Tracking.milestones.org` § M29 §5.2 (the
//! `ct/listProcesses` event dispatched at session-load is a total snapshot
//! of the session the client is talking to).
//!
//! # The defect
//!
//! `replay-server` runs three task threads — `stable`, `flow` and
//! `tracepoint` — and each loads the launched trace into a session of its
//! own. All three dispatched the session-load `ct/listProcesses` event, so
//! the client received three copies of one snapshot. That was only noise
//! while the snapshot was a hard-coded single thread per trace. Once the
//! snapshot asks each trace for its recorded processes, building it starts
//! the thread's replay worker; the `flow` thread's worker then took the
//! worker name (`flow`, index 0) that the first `ct/load-flow` gives its own
//! worker, the two collided on one socket, and every first flow of an rr
//! trace waited out the 10 s replay-query timeout before a restarted worker
//! answered (measured on `codetracer-native-backend`'s
//! `test_rr_multiprocess_parent_variables`: 2.2 s before, 12.3 s after).
//!
//! Only the `stable` thread serves the client's requests, so only its
//! session is announced, and the other threads start no worker they do not
//! use. The collision itself is removed at its source — worker indices are
//! reserved process-wide (`paths::reserve_worker_index`, pinned by
//! `dap_handler::tests::flow_workers_never_reuse_the_handlers_own_worker_identity`).
//! This test pins the observable half — one event per launch — against the
//! real binary.
//!
//! # No mocks
//!
//! The real `replay-server` binary over real DAP stdio framing, launching the
//! committed materialized fixture `trace/trace.ct`.

#![cfg(unix)]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use db_backend::dap::{self, DapClient, DapMessage};
use db_backend::transport::DapTransport;
use serde_json::json;
use std::io::BufReader;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// How long to keep listening after `stopped`. The auxiliary task threads
/// finish their own `launch` handling within milliseconds of the `stable`
/// one, so a duplicate announcement would arrive well inside this window.
const SETTLE_AFTER_STOPPED: Duration = Duration::from_secs(3);

/// Upper bound for the launch to reach `stopped`.
const LAUNCH_BUDGET: Duration = Duration::from_secs(90);

#[test]
fn a_launch_announces_its_session_exactly_once() {
    let trace_folder = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("trace");
    assert!(
        trace_folder.join("trace.ct").is_file(),
        "{} is missing; this test launches the committed materialized fixture",
        trace_folder.display()
    );

    let mut child = Command::new(env!("CARGO_BIN_EXE_replay-server"))
        .arg("dap-server")
        .arg("--stdio")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap_or_else(|err| panic!("failed to spawn replay-server: {err}"));
    let mut writer = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<Result<DapMessage, String>>();
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

    let mut client = DapClient::default();
    for request in [
        client.request("initialize", json!({})),
        client.request("configurationDone", json!({})),
        client.request("launch", json!({ "traceFolder": trace_folder })),
    ] {
        writer.send(&request).expect("send DAP request");
    }

    let started = Instant::now();
    let mut stopped_at: Option<Instant> = None;
    let mut seen: Vec<String> = Vec::new();
    let mut announcements: Vec<serde_json::Value> = Vec::new();
    loop {
        let deadline = match stopped_at {
            Some(at) => at + SETTLE_AFTER_STOPPED,
            None => started + LAUNCH_BUDGET,
        };
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            break;
        };
        let message = match rx.recv_timeout(remaining) {
            Ok(Ok(message)) => message,
            Ok(Err(err)) => panic!("DAP stream failed: {err}; messages seen: {seen:?}"),
            Err(mpsc::RecvTimeoutError::Timeout) => break,
            Err(mpsc::RecvTimeoutError::Disconnected) => panic!("replay-server exited; messages seen: {seen:?}"),
        };
        if let DapMessage::Event(event) = &message {
            seen.push(format!("event {}", event.event));
            if event.event == "ct/listProcesses" {
                announcements.push(event.body.clone());
            }
            if event.event == "stopped" && stopped_at.is_none() {
                stopped_at = Some(Instant::now());
            }
        }
    }
    child.kill().ok();
    child.wait().ok();

    assert!(
        stopped_at.is_some(),
        "the fixture never reached `stopped` within {LAUNCH_BUDGET:?}; messages seen: {seen:?}"
    );
    assert_eq!(
        announcements.len(),
        1,
        "one launch must announce its session once, from the thread that serves the client; \
         got {} `ct/listProcesses` events: {announcements:?}",
        announcements.len()
    );
    // The fixture is a single-process materialized recording, so the one
    // snapshot carries the legacy single thread.
    assert_eq!(announcements[0]["processes"][0]["threadIds"], json!([1]));
}
