//! `DapStdioClient::wait_for_stopped` must stop waiting the moment the engine
//! says the launch cannot succeed, and must hand the engine's reason to the
//! caller.
//!
//! db-backend answers `launch` with `success: true` before it opens the trace,
//! so when the trace cannot be opened it reports the failure afterwards as a
//! `ct/launch-failed` event whose `message` body is the sentence that says
//! why (`LAUNCH_FAILED_EVENT` in `src/db-backend/src/dap_server.rs`). Before
//! this test, `wait_for_stopped` kept only the event's *name*, waited out its
//! whole timeout, and reported "Timeout after 30.0s waiting for event
//! 'stopped'" with the reason nowhere in it (codetracer-pm issue
//! `2026-10-26-ct-dap-client-wait-for-stopped-waits-out-its-clock-after-ct-launch-failed.md`).
//!
//! ## Why a scripted peer instead of the real db-backend
//!
//! This is the one fake in the file, and it is deliberate:
//!
//! * The subject is the *client's* reaction to a byte stream, not db-backend's
//!   decision to refuse a trace. That decision is already tested against the
//!   real engine by
//!   `src/db-backend/tests/container_version_refusal_reaches_the_client_test.rs`,
//!   which asserts that a real refusal emits `ct/launch-failed` with the reason
//!   in `message`. This file covers the other half of the contract.
//! * ct-dap-client is a leaf crate (db-backend depends on it, not the other way
//!   round), so its own tests cannot build or locate a `replay-server` binary,
//!   and provoking a real refusal needs a recorded trace in an unreadable
//!   format.
//! * The peer is a real child process speaking real Content-Length-framed DAP
//!   over the real stdout pipe, spawned through the client's own
//!   `spawn_with_envs`. Nothing inside the client is stubbed: framing, the
//!   reader thread, the channel and process-group teardown are all the
//!   production code paths. The peer stays alive after it speaks, exactly as
//!   db-backend does after a refused launch, so a client that ignores the event
//!   really does sit until its deadline.
//!
//! The byte streams the peer plays are built from the same JSON shapes
//! `send_launch_failure_notification` emits (a `ct/notification` of kind Error
//! followed by `ct/launch-failed` with `{ "message": text }`).
//!
//! Controls, so a green run means something (Verification-Harness-Traps §7b):
//! * a peer that sends `stopped` must still yield `Ok` — the fix must not turn
//!   every wait into an error;
//! * a peer that sends a `ct/notification` of kind Error and then `stopped`
//!   must yield `Ok` — db-backend emits such a notification for a trace that
//!   opened perfectly well whose first step carries a recorded error, so only
//!   `ct/launch-failed` may end the wait;
//! * a peer that goes quiet must still time out, and say so — the timeout path
//!   is kept for an engine that really hangs.

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use ct_dap_client::client::DapStdioClient;
use serde_json::{json, Value};

/// The sentence the peer refuses with. Distinctive so the assertion cannot be
/// satisfied by any other text in the error.
const REFUSAL: &str = "meta.dat: version 6 is not readable: this reader reads version 7 only. \
     Re-record the trace with a current recorder";

/// The deadline handed to `wait_for_stopped`. Long enough that a client which
/// waits it out is unmistakable, short enough that the red run is cheap.
const WAIT: Duration = Duration::from_secs(5);

/// How quickly a client that reacts to the event must return. Generous on a
/// loaded machine: the peer speaks within milliseconds of being spawned.
const PROMPT: Duration = Duration::from_millis(2_500);

fn frame(message: &Value) -> Vec<u8> {
    let body = serde_json::to_string(message).expect("serialize DAP message");
    let mut out = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    out.extend_from_slice(body.as_bytes());
    out
}

fn event(seq: i64, name: &str, body: Value) -> Value {
    json!({ "seq": seq, "type": "event", "event": name, "body": body })
}

fn error_notification(seq: i64, text: &str) -> Value {
    // Same shape `task::Notification` serializes to; the client only needs
    // the event name, the body is carried for realism.
    event(
        seq,
        "ct/notification",
        json!({ "kind": "Error", "text": text, "active": false }),
    )
}

/// The scenarios the peer can play, keyed by `CT_FAKE_DAP_PEER_MODE`.
fn scenarios() -> Vec<(&'static str, Vec<Value>)> {
    vec![
        (
            // What db-backend sends for a refused launch — twice, as observed in
            // the issue (one per task thread).
            "launch-failed",
            vec![
                error_notification(1, REFUSAL),
                event(2, "ct/launch-failed", json!({ "message": REFUSAL })),
                error_notification(3, REFUSAL),
                event(4, "ct/launch-failed", json!({ "message": REFUSAL })),
            ],
        ),
        (
            "stopped",
            vec![event(
                1,
                "stopped",
                json!({ "reason": "entry", "threadId": 1 }),
            )],
        ),
        (
            "error-notification-then-stopped",
            vec![
                error_notification(1, "recorded error on step #1: boom"),
                event(2, "stopped", json!({ "reason": "entry", "threadId": 1 })),
            ],
        ),
        ("quiet", vec![]),
    ]
}

/// Write the peer script and its scenario streams exactly once per test
/// process, before any test spawns it.
///
/// Doing this once, behind a `OnceLock`, matters: writing an executable while
/// another thread forks a child can leave the write descriptor briefly open in
/// that child and make the exec fail with ETXTBSY. Every test waits here until
/// the files are closed, and only then spawns.
fn peer_script() -> &'static PathBuf {
    static SCRIPT: OnceLock<PathBuf> = OnceLock::new();
    SCRIPT.get_or_init(|| {
        // Under cargo's scratch directory for integration tests, not the
        // system temp directory: nothing removes it at the end of the run, and
        // a per-run directory in `/tmp` would pile up there.
        let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
            .join(format!("ct-dap-client-fake-peer-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create peer dir");
        for (mode, messages) in scenarios() {
            let bytes: Vec<u8> = messages.iter().flat_map(frame).collect();
            std::fs::write(dir.join(format!("{mode}.dap")), bytes).expect("write scenario");
        }
        let script = dir.join("fake-dap-peer.sh");
        // The client invokes it as `<script> dap-server --stdio`; the arguments
        // are ignored. After speaking, the peer stays alive (as db-backend does
        // after a refused launch) until the client's teardown kills its group.
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\ncat \"{}/$CT_FAKE_DAP_PEER_MODE.dap\" || exit 1\nexec sleep 600\n",
                dir.display()
            ),
        )
        .expect("write peer script");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755))
            .expect("chmod peer script");
        script
    })
}

fn run_wait(mode: &str) -> (Result<(), String>, Duration) {
    let mut client =
        DapStdioClient::spawn_with_envs(peer_script(), &[("CT_FAKE_DAP_PEER_MODE", mode)])
            .expect("spawn fake DAP peer");
    let start = Instant::now();
    let result = client.wait_for_stopped(WAIT).map_err(|e| e.to_string());
    let elapsed = start.elapsed();
    drop(client);
    (result, elapsed)
}

#[test]
fn launch_failed_ends_the_wait_at_once_with_the_engines_reason() {
    let (result, elapsed) = run_wait("launch-failed");
    let err = result.expect_err("a refused launch must not be reported as stopped");
    assert!(
        err.contains(REFUSAL),
        "the error must carry the engine's reason verbatim; got after {elapsed:?}:\n{err}"
    );
    assert!(
        err.contains("ct/launch-failed"),
        "the error must name the event that ended the wait; got:\n{err}"
    );
    assert!(
        elapsed < PROMPT,
        "wait_for_stopped took {elapsed:?} (deadline {WAIT:?}); it must return as soon as \
         ct/launch-failed arrives, not wait out its clock. Error was:\n{err}"
    );
}

#[test]
fn control_stopped_still_succeeds() {
    let (result, elapsed) = run_wait("stopped");
    result.expect("a `stopped` event must end the wait successfully");
    assert!(elapsed < PROMPT, "`stopped` took {elapsed:?} to be seen");
}

#[test]
fn control_error_notification_alone_does_not_end_the_wait() {
    let (result, _) = run_wait("error-notification-then-stopped");
    result.expect(
        "a ct/notification of kind Error is emitted for traces that open fine; only \
         ct/launch-failed may abort the wait",
    );
}

#[test]
fn control_quiet_engine_still_times_out() {
    let (result, elapsed) = run_wait("quiet");
    let err = result.expect_err("a silent engine must not be reported as stopped");
    assert!(
        err.contains("Timeout"),
        "a silent engine must still be reported as a timeout; got:\n{err}"
    );
    assert!(
        elapsed >= WAIT,
        "the timeout path returned after {elapsed:?}, before its {WAIT:?} deadline"
    );
}
