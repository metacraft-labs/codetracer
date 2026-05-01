//! Integration test for the duplicate-launch deduplication path in the
//! DAP server's task threads.
//!
//! In the production `ct host` (web mode) and Electron flows, two `launch`
//! requests reach the replay-server back-to-back: the first one comes from
//! `backend-manager`'s `dap_init` handshake, and the second one from the
//! renderer's `dap-replay-selected` IPC handler.  Both target the same
//! trace folder.
//!
//! Before this fix, every materialized (CTFS) DB trace paid the full
//! Db-population cost twice — once per launch — which can stretch
//! ct-host startup to 80+ seconds for moderately sized traces and starve
//! `ct/event-load` / `ct/load-calltrace-section` requests that arrive
//! while the second reload is still in progress.  The Playwright tests
//! `tests/browser-materialized-replay.spec.ts` failed for exactly this
//! reason.
//!
//! This test exercises the same handshake at the DAP protocol layer:
//!   1. `initialize`
//!   2. `launch` (run-to-entry → `stopped` event #1)
//!   3. `configurationDone`
//!   4. `launch` again with the SAME arguments
//!   5. drain incoming messages for a few seconds and assert that the
//!      stable thread did NOT emit a second `stopped` event for the
//!      duplicate launch.
//!
//! Without the fix, the stable thread re-runs `setup()` on the duplicate
//! launch and emits a second `stopped` (entry) event.  With the fix in
//! place the duplicate launch is recognised and short-circuited, so only
//! the original `stopped` event reaches the client.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use ct_dap_client::client::DapStdioClient;
use ct_dap_client::protocol::DapMessage;
use ct_dap_client::types::launch::LaunchRequestArguments;

mod test_harness;
use test_harness::{Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

#[test]
fn duplicate_launch_does_not_emit_second_stopped() {
    if test_harness::find_python_recorder().is_none() {
        eprintln!("SKIPPED: Python recorder not found");
        return;
    }
    let (_python_cmd, version_label) = match test_harness::find_suitable_python() {
        Some(pair) => pair,
        None => {
            eprintln!("SKIPPED: Python 3.10+ not found (needed for the recorder)");
            return;
        }
    };

    let db_backend = find_db_backend();

    // Use the existing python_flow_test.py fixture — small enough to keep
    // the test fast.
    let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/python/python_flow_test.py");
    assert!(
        source_path.exists(),
        "Python test program not found at {}",
        source_path.display()
    );

    let recording = TestRecording::create_db_trace(&source_path, Language::Python, &version_label)
        .expect("Python recording failed");

    let mut client = DapStdioClient::spawn(&db_backend).expect("spawn db-backend");
    let _caps = client.initialize().expect("initialize");

    // First launch: the equivalent of backend-manager's dap_init send.
    client
        .launch(LaunchRequestArguments {
            trace_folder: Some(recording.trace_dir.clone()),
            ..Default::default()
        })
        .expect("first launch");
    client.configuration_done().expect("configurationDone");

    // First stopped event (run_to_entry on the stable thread).
    client
        .wait_for_stopped(Duration::from_secs(60))
        .expect("first stopped event");

    // Now send the same launch again — this is what the renderer's
    // `dap-replay-selected` handler does in production.
    client
        .launch(LaunchRequestArguments {
            trace_folder: Some(recording.trace_dir.clone()),
            ..Default::default()
        })
        .expect("duplicate launch");

    // Drain incoming messages for a generous window.  With the fix the
    // stable thread short-circuits the duplicate launch so no `stopped`
    // event arrives from it.  Without the fix, the stable thread re-runs
    // setup() and emits a second `stopped` (reason=entry) event.
    let drain_window = Duration::from_secs(8);
    let deadline = Instant::now() + drain_window;
    let mut second_stopped_seen = false;
    let mut events_seen: Vec<String> = Vec::new();
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match client.recv_message(remaining) {
            Ok(DapMessage::Event(e)) => {
                events_seen.push(e.event.clone());
                if e.event == "stopped" {
                    second_stopped_seen = true;
                    break;
                }
            }
            Ok(_) => continue,
            Err(_) => break,
        }
    }

    assert!(
        !second_stopped_seen,
        "duplicate launch produced a second `stopped` event — \
         dedup short-circuit regressed (events seen during drain: {:?})",
        events_seen
    );

    let _ = client.disconnect();
}
